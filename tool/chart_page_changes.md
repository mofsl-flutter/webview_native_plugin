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

Loads `js/core/net_retry.js` before `static_config.js`.

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

`fetchWith401Retry`'s one `fetch` now goes through `ChartApp.netRetry.fetch` (next section).

`RemoveLegendHiddenClasses` re-armed itself with `this.RemoveLegendHiddenClasses()`, so every poll
started again at the default of 10 and the polling never stopped (the 32 and 133 calls recorded
under "Looked at and left alone" were that, not ten polls per change). It now passes `retries - 1`:
the first call and ten re-polls, 500 ms apart, then it stops. Tested by running the real function
(cut out of the file by brace matching) against fake timers: `tool/js_test/legend_poll.test.mjs`.
The 0.1 ms per call figure below still holds, so this is a tidy-up, not a speed-up.

## `js/core/net_retry.js` (new file)

**The problem (the rollout blocker).** The bundled page's API calls are cross-origin. Production's
cacheable GETs, `Symbols` (`max-age=7200`) and `Config` (`max-age=21600`), carry
`access-control-allow-origin` only when the request has an Origin header, and the server sends no
`Vary: Origin`. A copy stored by a same-origin request has no such header. The hosted page stores
one that way, and so does the hosted **Peak** page, which requests both endpoints and shares the
app's one WebView. The bundled page's request is then served that copy from the HTTP cache, fails
the CORS check (`net::ERR_FAILED`), and the chart reports `SymbolNotFound` with no candles.

Observed on an Android 16 emulator (case `L5`, one APK, hosted page first and then the bundled page
in the same profile): the hosted open drew 300 candles, the bundled open ended in `SymbolNotFound`
with 0 bars, on a clean profile and on a used one, every run. Every existing user's WebView is in
that state, for up to 2 and 6 hours after the last hosted or Peak open, and this WebView did not
partition its HTTP cache by top-level site (otherwise it could not have happened). Clearing the
cache once is not a fix: the next Peak open refills it.

**The fix.** `ChartApp.netRetry.fetch(target, options)` runs the request, and if it fails with a
network error (`TypeError`) and is a GET and the caller chose no `cache` mode and was not aborted,
asks again once with `cache: 'reload'`. That goes to the server and stores a copy that has the
header, so later requests (this page's, and the hosted page's) are served a copy the bundled page
can read. Never a write (it may have reached the server), never a second retry, never an HTTP status
(that is an answer). The caller's options are copied, not changed (the 401 queue keeps the same
object). `window.fetch` is looked up at call time because the harness replaces it for case `N1`.
The log line carries the path only.

There is one request call site in the page, `fetchWith401Retry`, so one edit covers every endpoint,
and `tool/js_test/net_retry.test.mjs` fails if any script gains a request that bypasses the module
or if `net_retry.js` stops loading before `static_config.js`. The prefetch hand-off (Dart's
`HttpClient`) never touches the WebView cache and is unaffected.

**Measured** (Android emulator, production API, client `T029342`):

| Page | `L5` result |
|---|---|
| Retry disabled (deliberately) | FAIL, twice: bundled open `SymbolNotFound`, 0 bars |
| Retry enabled, clean profile (3 runs) | PASS, 300 candles; `retried: 2, recovered: 2` (Symbols and Config) |
| Retry enabled, used profile (3 runs) | PASS; `retried: 0`: the earlier recovery left healthy entries |

`L1` to `L4`, `O1`, `P1` and `N1` still pass. `N1` (every `fetch` fails) shows `retried: 1, failed: 1`
and still ends in `rejected`, so an outage is not hidden.

iOS simulator (correctness only, one run each): `L5` passes **without** the retry, so the hosted
page did not poison the bundled page there. Why is not established (WebKit may key its cache by
site; nothing here shows it), and a simulator is not a device. With the retry, `L5` passes and `N1` shows WebKit's failed fetch is a
`TypeError` too (`retried: 1, failed: 1`), so the retry is live on iOS and harmless.

**Still wanted from the API owners:** `access-control-allow-origin: *` on every response and
`Vary: Origin` on the cacheable GETs. With that the retry is a safety net, and the hosted Peak page
stops being able to poison anything. (`Access-Control-Max-Age: 7200` on OPTIONS would save repeat
preflights of the same URL, which are rare here.) `Peak`'s own `fetchWith401Retry` is the old
version with no `try`/`catch`, so a network error leaves its promise hanging; that is the server's
page, not ours.

**Not the fix:** `IosWebViewPlugin.resetCache()`. On iOS it removes every website data type, cookies
and localStorage included (see its corrected doc); on Android it clears the HTTP disk cache only.

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

## Candles a gap in live ticks leaves behind (`stream.js`, `datafeed.js`, `main.js`)

**The problem.** The page builds candles from ticks: a tick either updates the last bar or, when it is
at or past the next bar's time, opens one new bar at its own time. While the app is in the background
no ticks arrive, so the first tick after returning opens one bar and every bar in between is missing
(the chart draws a straight line across). The page had no way to ask for history once the chart was up;
loading the chart again was the only repair. `getBarTimeForTick` in `stream.js` was never called.

**What the page does now.** The missing bars are fetched on their own and fed to the library as live
bars, in order: one `HistoryV3` request for the window from the last bar to now, through the same
adapter the chart's own history uses (so it carries the auth, base URL and 401 handling). No widget
rebuild, no `Symbols`, `GetChartSavedInfo` or `Config` request, no library parse. Three triggers, one
mechanism (`stream.fillGaps`):

- `window.FillMissingCandles(symbol?)` (also `v1.fillMissingCandles` and a `FillMissingCandles` web
  message), for the host to call on resume. Resolves with one result per subscription, never rejects.
  Plugin side: `ChartSession.fillMissingCandles()`.
- The page's own `visibilitychange`: hidden for 5 s or more, then visible, fills.
- A tick that skips at least one whole bar is held while the bars are fetched, then applied, because
  the library refuses a bar older than its last one: if ticks resume before the host asks, the first
  tick would otherwise open a bar past the gap and make the missing ones impossible to add.

**Telling the host.** When a fill could not close the gap the page posts one
`{context:'GapFill', error:{source:'stream', reason, symbol}}` (the same envelope as `sendError`, which
hosts already parse), so a host can fall back to loading the page again. `reason` is `too-large` (more
than 1000 new bars; a retry changes nothing) always, and `failed` (history errored or timed out) only for
a fill the host or the page becoming visible asked for. A fill a tick started that fails is routine on a
slow network, and the held tick has already been applied as before, so it is not reported. Nothing is
posted for `filled`, `nothing-new` or `current`.

**Fail-safe.** If history is slow (3 s for a held tick, 10 s for a host call), empty or failing, held
ticks are applied exactly as before, and a tick-triggered fill is not tried again for 20 s. The worst
case is today's behaviour. More than 1000 new bars is reported as `too-large` and not fed; the host
reloads the chart in that case.

**What it asks.** Only bars at or after the chart's last bar count, because the server answers an empty
window with older bars. When only the current bar comes back, its high and low are widened and what the
ticks established is kept (history lags ticks by seconds). Nothing is asked while the last bar is still
the current one. Monthly charts are left alone (their bars are not a fixed length). Results are kept in
`ChartApp.stream.data.fills` for probes.

**Measured** (Android emulator, production API, client `T029342`, SENSEX 1m, last 8 of 2,625 bars hidden
from the first history answer so the server really has them; cases `L3` and `L4`, `example/`):

| | |
| --- | --- |
| fill as the host sees it (`ChartSession.fillMissingCandles`) | 89, 92, 95, 102 ms |
| full open of the same chart, end to end | 905 to 1,065 ms |
| requests during a fill | one `HistoryV3` (9 bars); none of `Symbols`, `GetChartSavedInfo`, `Config` |
| the chart afterwards | 300 rows became 308 (the 8 hidden), times strictly increasing, last row the real last bar |
| first tick after the gap, no fill asked for (`L4`) | the page fetched and fed the 9 bars itself, then applied the tick |
| backgrounded 9 s, then resumed | `visibilitychange` fired both ways and the page filled on its own |

L3 passed in 7 runs and L4 in 3 on the emulator (earlier runs failed on mistakes in the cases, not in the page; they are not counted). The account's saved layout was identical before and
after (every field), because the cases open `CHART_SYMBOL`.

**Not verified.** Live ticks and a real market: the market was closed, so the gap was made by hiding
bars and the "tick" was synthetic (stamped outside the session, so the library draws no candle for it;
the case checks the page applied it after the fill). Whether `visibilitychange` fires in the iOS
WebView, on a screen lock, or on a physical phone. The `LightWeightChart` mode (`compactChart`). Bars
the server returns for the minutes of a real session boundary. For those, call
`ChartSession.fillMissingCandles()` from the app's resume handler as well; it asks for nothing when no
bar is due.

`chart.resetData()` is not an alternative here: in this library build it re-requested nothing from the
datafeed (no `getBars`, no `subscribeBars`), so it cannot repair a chart.

Tests: `gap_fill.test.mjs` (20 cases against the real `stream.js` with a fake history source; five
behaviours were broken one at a time and each was caught) and `test/chart_session_fill_test.dart`.

## Looked at and left alone

- `RemoveLegendHiddenClasses` polled every 500 ms and never stopped (a bug, fixed above): 32 calls
  for one interval change, 133 for one symbol change. All 184 calls in a run took 22 ms in total
  (about 0.1 ms each), so it was not a cost worth the risk of replacing it with a CSS override.
- `getQuote` reads the library's private `bars()._items`. It is O(1), so not slow, but it is a
  private API that a library upgrade can break. Not changed.
- A bar opened by a tick takes the tick's raw `tradeTime`, not the start of its period, and the next
  bar is computed from that (`computeNextBarTime` rounds to the minute, so a 5-minute chart drifts off
  its grid). The datafeed already snaps history's last bar for the same reason. Not changed: the
  library accepts it today, and a fill's bars come from history, which is on the grid.
