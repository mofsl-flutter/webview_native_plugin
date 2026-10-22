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
