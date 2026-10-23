# How `assets/chart/v4/` differs from the hosted page

`assets/chart/v4/` is this plugin's own copy of the chart page and its scripts. The first
`dart tool/sync_chart_bundle.dart` created it from the server; later syncs never touch it and write
the server's current files to `assets/chart/upstream/v4/` (git-ignored) so you can diff and merge.

When you merge from `upstream/v4/`, these are the places where our copy is deliberately different.
`assets/chart/manifest.json` records `upstreamSha256` for every owned file, so
`sha256 != upstreamSha256` is the machine-readable form of this list.

Everything below is covered by `tool/js_test/*.test.mjs` (run by `flutter test`) unless it says
otherwise, and `S1` / `L1` / `L2` in the example app check it on a device.

## `RiseApp_Mobile.html`

- The Akamai mPulse (boomerang) analytics snippet is removed. It phones home on every open.
- Two scripts are added before `static_config.js`: `js/core/api_base.js` and
  `js/core/save_scheduler.js`.

## `js/core/api_base.js` (new file)

Decides where API calls go. A page served from the app has no API next to it, so the host passes the
server in the URL (`?apiBase=https://server/chart/`). Missing or invalid is an error, never a guess.
Tests: `api_base.test.mjs`.

## `js/core/static_config.js`

`fetchWith401Retry` resolves the URL through `ChartApp.apiBase` before `fetch`. The relative form
(`../api/...`) is still what the host is told on a 401 and what the retry queue stores.

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
- `fetchWith401Retry` never settles if `fetch` itself rejects (a network failure): the promise
  executor is `async`, so the throw is unhandled and nothing rejects. The chart then waits forever
  instead of reporting no data. Not changed; it is the web team's behaviour and a fix changes what
  callers see.
