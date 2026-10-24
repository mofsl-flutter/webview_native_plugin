## Unreleased

* The chart page and the TradingView charting library (29.1.0) now ship inside the plugin
  (`assets/chart/`, 516 files, 11.6 MB, 3.7 MB stored in a debug APK; release size not measured)
  and are served locally, so opening
  the chart fetches no code from the network. Nothing changes unless the host asks for it.
  * New `ChartBundle.localUrl(apiBase:, theme:)` returns the URL to load: Android serves it from
    `https://appassets.androidplatform.net/chart/` (`WebViewAssetLoader`), iOS from
    `mochart://app/chart/` (`WKURLSchemeHandler`). `apiBase` is required and is the server's chart
    root (`https://tradingapi.motilaloswaluat.com/chart/`): the page keeps calling the real API for
    symbols, history and saved layouts, it just no longer finds it next to itself.
  * New `IosWebViewPlugin.chartBundleInfo()` reports whether this build carries the bundle, so a
    host can fall back to the hosted page. It never throws.
  * iOS: a navigation that fails on the bundled scheme no longer falls back to tradingview.com.
  * The page and its app scripts are the plugin's own copy (`assets/chart/v4/`), refreshed with
    `dart tool/sync_chart_bundle.dart`, which never overwrites edits made there; see the file header.
* The bundled page (`assets/chart/v4/`, the plugin's own copy; `tool/chart_page_changes.md` lists
  every difference from the hosted page) fixes what measurement showed to be wrong:
  * Saving: the page POSTed the whole chart on every visible-range change, and stacked another range
    listener each time panes changed. The same 10 s pan now saves 2 times where it saved 40 (one
    indicator added) or 80 (two). A save is taken 1 s after the last change and at most 5 s after the
    first one waiting; a save pending when the app is killed mid-pan is lost (up to 5 s of changes,
    before 1 s).
  * Live ticks are matched to their symbol exactly. A tick for `NSE:ACC` used to also move
    `NSE:ACCELYA`, because the lookup compared key prefixes.
  * The raw bar arrays `getBars` wrote to `console.log` on every first request are debug-level.
* The bundled code is UAT's, and the API it calls is whatever the host passes as `apiBase`, so the
  same bundle can call production: `https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/`.
  Both environments define the same 34 endpoints and the TradingView library is the same build;
  their app scripts differ (UAT is ahead). `tool/chart_page_changes.md` has the comparison.
* New `ChartPrefetch` (`package:ios_webview_plugin/chart_prefetch.dart`) fetches a chart's opening
  data (symbol, saved layout, config and the first candles) from Dart while the page loads, and
  `handoff`s it to the bundled page, which takes it instead of requesting it. It is read-only (`GET`s),
  uses the host's own token, and is a shortcut only: anything missing, late, stale, or not covering
  what the chart asks for is requested by the page as before. The page asks for the symbol, layout and
  config no longer (measured on UAT: 4 requests, then 1) and the chart ends up with the same candles.
  History is used only if it has already arrived (UAT can return a wrong window and waiting for it
  made the open slower), only for a non-empty window (the server answers an empty one with older
  bars), and at the interval the chart really opens at, which is the saved layout's, not the
  `interval` field. On production, with a real account, an open went from a median of about 0.96 s
  to 0.47 s (six runs, emulator); history itself could not be exercised on a device while the market
  was closed and is verified against real production data instead. See `tool/chart_page_changes.md`.
* The bundled page now rejects when a request fails outright (offline, DNS, TLS) instead of never
  settling, so the chart reports no data and the host gets the symbol error rather than silence.
* Example app: `--dart-define=CHART_SYMBOL=<symbol>` and case `O1` open a chosen chart through the
  page's own save path. Opening a chart records it as the account's last-viewed one, so that is also
  how to put an account back after a run.
* Example app: `--dart-define=CHART_API_ROOT=<root>` and `--dart-define=CHART_TOKEN=<token>` point the
  bundled page at another environment's API. `--dart-define=CHART_LOCAL=true` loads the bundled chart, `--dart-define=SCENARIO=L1`
  starts a regression case on iOS, cases `L1`/`L2` check the bundled chart on both platforms, and `S1`/`S2`
  record save traffic and legend-poll cost.
* Candles that live ticks missed are filled in without reloading the chart. While the app is in the
  background no ticks arrive, so the first tick after returning used to open one candle and leave every
  one in between missing; the only repair was to load the chart again. New
  `ChartSession.fillMissingCandles({symbol})` (page side `window.FillMissingCandles`) asks for just the
  missing candles (one `HistoryV3` request, no symbol, layout or config requests, no widget rebuild) and
  feeds them to the chart as live bars. The bundled page also does it by itself when it becomes visible
  again after 5 s or more, and when a tick arrives that skips a whole candle (the tick is held while the
  candles are fetched, because the library refuses a candle older than its last). If history is slow
  (3 s for a held tick), empty or failing, ticks are applied as before; more than 1000 new candles are
  not fed one by one (`too-large`). On an emulator against production, with 8 candles hidden from the
  first history answer, a fill took about 95 ms as the host sees it, against about 1 s for a full open,
  and the chart ended with the 8 candles in order. Only the bundled page has it. Live ticks, iOS, a
  screen lock and a physical phone are not verified; see `tool/chart_page_changes.md`.
* New `ChartBundle.apiBaseOf(hostedPageUrl)` derives the `apiBase` for `ChartBundle.localUrl` from the
  hosted page URL a host app already knows (`<root>/v4/RiseApp_Mobile.html` gives `<root>/`), and returns
  null for any other shape so the host keeps loading the hosted page. `localUrl` and `apiBaseOf` share
  one validator.
* Example app: cases `L3` (the host asks for a fill) and `L4` (the first tick after a gap triggers it)
  open a chart with its last 8 candles hidden from the first history answer and check what the
  library's own export holds afterwards. `OpenChart(hideLastBars:)` and the `FillGap` step are the
  tools; both cases run on production.
* Example app: it now defaults to production (`https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/`,
  client `T029342`), with a banner that names the environment and the client. `--dart-define=CHART_ENV=uat`
  restores the previous behaviour (UAT page, UAT API, client `T06794`), and `CHART_CLIENT_CODE` picks the
  client. Production runs only the regression cases whose every step opens a chart and observes
  (`A1 A5 E3 E4 G2 L1 L2 N1 O1 P1 WC`, pinned in `test/environment_test.dart`); the rest are hidden in
  the app and reported as `SKIPPED` by `SCENARIO=...` runs, because they add indicators, switch
  intervals and symbols, or save repeatedly on a real account. `--dart-define=ALLOW_PROD_WRITES=true`
  runs them anyway. Opening a chart still records it as the account's last-viewed one. Anything that
  ran the suite against UAT (including `example/tool/run_regression.sh`) now needs
  `--dart-define=CHART_ENV=uat` in its build.

## 0.0.4

* New `IosWebViewPlugin.probe(script)`: runs a script in the page and returns it with native facts
  (`hasWebView`, `attached`, `attachedViewId`, `ownsDelegate`, `isPaused`, `loadId`, `url`). The
  answer is the call's return value rather than an event, so it works when the event path is the
  thing that is broken. A renderer that never answers surfaces as `timedOut`.
* New `IosWebViewPlugin.claimDelegate()`: explicit take-back of the event delegate; returns whether
  ownership changed.
* New debug-only `IosWebViewPlugin.debugReleaseDelegate()` (refused on release builds) to
  reproduce the lost-event failure.
* Android: disposing a platform view no longer detaches the WebView when a newer platform view
  already hosts it (a kept-alive mini chart under a full chart used to blank the newer view).
  `viewDetached` gains `owned`.
* Android: a platform view asked for its view again (`getView()`) no longer pulls the WebView back
  out of a newer view that is hosting it; only a newly created view claims it. Together with the
  `dispose()` change above, this is what keeps a kept-alive mini chart and a full chart from
  blanking each other. `attachedViewId` is also reset when the renderer dies.
* iOS: `webViewWebContentProcessDidTerminate` is handled (reported as `renderProcessGone`);
  `loadUrl` emits `loadRequested`; new `destroyWebView`; `viewAttached` / `viewDetached` events;
  `reloadUrl` claims the delegate; every delegate claim now reports `delegateClaimed`, as on Android.
* Example app: a recovery suite (`example/lib/src/regression/recovery_catalog.dart`, run with
  `example/tool/run_recovery.sh`) that drives each of the above on a real device or simulator.

## 0.0.3

* Android: the event delegate now follows the engine that drives the WebView (first `prewarm` /
  `loadUrl` / `reloadUrl` / `destroyWebView` call, or a Dart event subscriber) instead of the
  engine that attached last. A headless engine (e.g. `firebase_messaging`'s background isolate)
  registering the plugin no longer takes `loadRequested` / `PageReady` / page messages away from
  the foreground engine. A detaching engine only releases the delegate if it owns it.
* Android: new diagnostic event `delegateClaimed` (`owner`, `reason`) whenever ownership changes.
* iOS: `onCancel` releases the delegate only when it owns it; `loadUrl` claims it.

## 0.0.1

* Initial release.
