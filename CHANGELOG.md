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
