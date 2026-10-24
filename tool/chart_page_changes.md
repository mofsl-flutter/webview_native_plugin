# How `assets/chart/v4/` differs from the hosted page

`assets/chart/v4/` is this plugin's own copy of the chart page and its scripts. The first
`dart tool/sync_chart_bundle.dart` created it from the server; later syncs never touch it and write
the server's current files to `assets/chart/upstream/v4/` (git-ignored) so you can diff and merge.

When you merge from `upstream/v4/`, these are the places where our copy is deliberately different.
`assets/chart/manifest.json` records `upstreamSha256` for every owned file, so
`sha256 != upstreamSha256` is the machine-readable form of this list.

Everything below is covered by `tool/js_test/*.test.mjs` (run by `flutter test`) unless it says
otherwise, and `S1` / `L1` / `L2` in the example app check it on a device.

## Environments: which code, which API

The bundle was mirrored from **UAT** (`https://tradingapi.motilaloswaluat.com/chart/`, page version
`20260724_01`). The host app chooses the API separately, through `apiBase`, so the same bundled code
can call UAT or production. Production's chart root is
`https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/` (note `/charts/`, plural).

What was compared on 2026-10-24:

- **Endpoints: identical.** Both define the same 34 endpoints with the same methods. `Config` returns
  a byte-identical body, the read endpoints answer 401 without a token on both, and both allow the
  bundled origins (`https://appassets.androidplatform.net`, `mochart://app`) for GET and for POST
  with `authorization, content-type`, including on the 401 response.
- **TradingView library: the same build.** The loader, `runtime.js` and `library.js` are identical
  once line endings are normalised (UAT's files use CRLF, production's LF).
- **App scripts: different.** Production is page `20260921_01` (`static_config.js` v6, `main.js` v7);
  all four app scripts differ from UAT's. UAT is the one with extra code: the colour-blind-friendly
  buy/sell palette (`isColorBlindFriendly`, a SEBI requirement), the `getBars` last-bar alignment
  fix, and calendar-aware bar timing in `stream.js`. So bundling UAT's page ships those to anyone
  using it.
- **Transport differs.** Production serves the 2.7 MB library uncompressed (UAT: gzip, 0.9 MB) and
  sends no cache headers on the page; UAT's page is `no-store`.

`dart tool/sync_chart_bundle.dart` mirrors `/chart/` on a UAT-shaped host only; it cannot sync from
production's `/charts/` yet. The edits listed below were made against UAT's scripts, so a production
bundle would need them re-applied to production's.

Running the example against another environment: `--dart-define=CHART_LOCAL=true
--dart-define=CHART_API_ROOT=<root ending in />  --dart-define=CHART_TOKEN=<token for that
environment>`. **A bundled page writes as soon as it opens a chart** (`SaveChartData`,
`SaveSettings`, `SaveInterval`), and the `S1` case adds and removes indicators, so a real token
changes that user's saved layout. Use a dedicated test client.

## `RiseApp_Mobile.html`

- The Akamai mPulse (boomerang) analytics snippet is removed. It phones home on every open.
- Three scripts are added before `static_config.js`: `js/core/api_base.js`,
  `js/core/save_scheduler.js` and `js/core/preload.js`.

## `js/core/api_base.js` (new file)

Decides where API calls go. A page served from the app has no API next to it, so the host passes the
server in the URL (`?apiBase=https://server/chart/`). Missing or invalid is an error, never a guess.
Tests: `api_base.test.mjs`.

## `js/core/static_config.js`

`fetchWith401Retry` resolves the URL through `ChartApp.apiBase` before `fetch`. The relative form
(`../api/...`) is still what the host is told on a 401 and what the retry queue stores.

`fetchWith401Retry` now rejects when `fetch` itself fails (offline, DNS, TLS, blocked). It used to
`await fetch` inside an `async` promise executor, so the throw escaped the executor, nothing settled
the promise, and every caller waited forever; the chart spun with nothing to tell the host. Now the
caller's own `.catch` runs (`getBars` reports no data, `LoadChart` falls through to the symbol
error). Measured with case `N1`: the adapter went from `hung` to `rejected: Failed to fetch`.

The four adapter calls that open a chart (`config`, `symbolInfo`, `GetChartSavedInfo`, `getData`)
first ask `ChartApp.preload` for a response the host already fetched; see the next section.

## `js/core/preload.js` (new file)

Opening a chart is a chain: Symbols, then GetChartSavedInfo, then (once the widget exists) Config and
the first HistoryV3. The page cannot start any of it before it has loaded, but the host can
(`ChartPrefetch` in the plugin). The host hands the raw response bodies to this store and the
adapter takes them instead of calling the network, parsing them with the same code as before.

Rules, each pinned by `preload.test.mjs`:

- Entries are single-use, taken by the first reader whether or not it was usable.
- Symbols, the layout and Config are waited for while in flight (bounded). They are exact-key
  lookups, so a response that arrives is always usable and waiting is never worse than asking.
- **History is never waited for.** Whether it is usable depends on what the server sent: UAT's
  `HistoryV3` returns an older window for a wide range (observed: bars from 13-19 Oct for a request
  ending 24 Oct), which the guards correctly refuse. Waiting for it and then refusing it doubled the
  chart's open time on UAT (11.8 s to 20.8 s) before this rule. Now it is used only if it has
  already arrived, and the page asks itself otherwise.
- History is served only for the first request, and only when all of these hold:
  - the prefetch reaches back past the library's `from`;
  - its `to` trails **now** by no more than 15 s or the bar length, whichever is less. It is
    measured against now, not against the library's `to`, because the library asks up to the END of
    the current bar (a full minute ahead for one-minute bars) and no bars exist in that future;
  - its slice to `[from, to]` is **non-empty**.
  The server's answer, as observed on production: a window with bars in it comes back as exactly
  those bars, however few (1, 2, 4, 10 and 12 bars, with `countBack` 300 and 1, two symbols, three
  resolutions) and however many; a window with **no** bars in it (the market is closed) comes back
  as a long run of older bars from outside the window. So a non-empty slice is the server's answer
  and an empty one is refused. There is no `countBack` condition: the library's window starts at
  the previous close, so before about 14:15 it holds fewer than 300 bars all morning, and such a
  short slice is still exactly what the server returns.
  Checked against real production data at five moments from 09:20 to 15:20, for two symbols and
  one- and five-minute bars (20 cases): 4,418 older bars compared, none differing, and the newest
  bars identical too. The only bars a slice lacks are ones that did not exist yet at that moment.
  UAT is not consistent about any of this (it can return an older window whatever was asked), so
  nothing is served from a UAT response that does not cover the window.
- The store keeps why it last refused something (`stats().lastReject`): a refusal otherwise looks
  exactly like a miss, which is how a wrong guard hid behind a green run during development.
- The history key uses the interval the chart really opens at. With a saved layout that is the
  layout's main series' interval, not the `interval` field of the saved-info response (on a real
  account the field said `1D` while the layout, and so the chart, was at `1`). A drawing in the same
  layout carries an `interval` of its own, which is not the chart's. `D`/`1D` (and `W`, `M`) are one
  key.
- Every other doubt returns "not here" and the page makes the request.

Measured with case `P1` (the same chart opened without, then with, the prefetch):

- **Production** (the bundled page against the production API, Android emulator, six runs): the page
  made 4 requests itself then 1 (history refused because the market was closed, see above) and 0 of
  symbol, layout and config; end to end 0.97 / 1.19 / 0.90 / 0.94 / 0.88 / 1.29 s without, 0.41 /
  0.54 / 0.40 / 0.41 / 0.53 / 0.55 s with: median about 0.96 s down to 0.47 s. Both arms show the
  same 307 candles. This is without the history prefetch, which cannot be exercised on a device
  while the market is closed: it is verified by replaying real production data (above), and in
  session it should save roughly another 0.1-0.2 s.
- **UAT** (Android emulator, three runs): 11.9 / 11.3 / 11.6 s down to 10.6 / 11.0 / 10.7 s; iOS
  simulator, one run, 12.1 s to 10.7 s. UAT's slow `HistoryV3` dominates both, and its response is
  refused (it does not cover the window).

## `js/core/save_scheduler.js` (new file) and `js/main.js`

The page used to POST the whole chart (about 24 KB with two indicators) on every visible-range
change, and its `panes_order_changed` handler subscribed to range changes again each time it ran.
Measured on the same 10 s pan (40 range events): 0 saves with no indicator, 40 with one, 80 with two.
Now 2, 2 and 2.

- `saveChartData()` requests a save from the scheduler instead of scheduling its own. Saves are taken
  1 s after the last request, and never more than 5 s after the first one still waiting, so a pan that
  never pauses still saves.
- The range handler is one named function, unsubscribed before each subscribe, so it cannot stack.

Behaviour kept on purpose: range changes are still only saved after the first pane change (a fresh
chart panned without ever adding an indicator saves nothing, as before), and the `chartReady` /
`isSymbolChanged` gates are unchanged.

Trade-off: a save waiting when the app is killed mid-pan is lost. Before, the exposure was 1 s of
changes; now it is up to 5 s. Lower `maxWaitMs` in `main.js` to tighten it.

## `js/core/stream.js`

Live-tick lookup is by exact ticker. It used `key.startsWith(ticker)`, so a tick for `NSE:ACC` also
moved `NSE:ACCELYA`. Subscriptions are indexed by ticker, which also makes a tick's cost independent
of how many subscriptions exist (about 500 ns whether there is one or a thousand; it was 24 µs at a
thousand). Tests: `stream.test.mjs`.

## `js/datafeeds/datafeed.js`

The two `console.log` calls in `getBars` (raw bar arrays, on every first history request) are
`logger.debug`, behind a level check so the objects are not built unless debug logging is on.

## Looked at and left alone

- `RemoveLegendHiddenClasses` polls up to every 500 ms after an interval or symbol change: 32 calls
  for one interval change, 133 for one symbol change. All 184 calls in a run took 22 ms in total
  (about 0.1 ms each), so it is not a cost worth the risk of replacing it with a CSS override.
- `getQuote` reads the library's private `bars()._items`. It is O(1), so not slow, but it is a
  private API that a library upgrade can break. Not changed.
