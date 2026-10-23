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
* Example app: `--dart-define=CHART_LOCAL=true` loads the bundled chart, `--dart-define=SCENARIO=L1`
  starts a regression case on iOS, cases `L1`/`L2` check the bundled chart on both platforms, and `S1`/`S2`
  record save traffic and legend-poll cost.

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
