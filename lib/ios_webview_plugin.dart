import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "webview_events.dart";

/// Plugin for interacting with the native WebView.
class IosWebViewPlugin {
  static const MethodChannel _channel = MethodChannel("webview_mo_flutter");

  static int _loadIdCounter = 0;

  /// Every native WebView event, decoded.
  ///
  /// Prefer this over the callback helpers: it is one shared subscription, so registering
  /// several listeners is safe.
  static Stream<WebViewEvent> get events => webViewEvents;

  /// Messages posted by page JavaScript through any registered channel.
  static Stream<String> get messages => webViewEvents
      .where((WebViewEvent e) => e is WebViewChannelMessageEvent)
      .map((WebViewEvent e) => (e as WebViewChannelMessageEvent).message);

  /// Stream of messages received from the web view's JavaScript channel.
  Stream<String> get onMessageReceived => messages;

  /// Allocates the next load generation.
  ///
  /// Pass the result to [openWebView] or [prewarm] so every event can be attributed to the load
  /// that caused it. Generated in Dart because iOS returns nothing from its load call.
  static int nextLoadId() => ++_loadIdCounter;

  /// Opens the WebView at [url].
  ///
  /// Set [isChart] to `false` for anything that must surface its own failures: with the legacy
  /// default of `true`, a load error silently navigates to a hardcoded fallback page and reports
  /// a second completion for the wrong URL. Pass [errorFallbackUrl] to choose the fallback
  /// explicitly, or [disableErrorFallback] to switch it off outright.
  static Future<void> openWebView(
    String url, {
    String? javascriptChannelName,
    bool? isChart,
    String? backgroundColor,
    List<String>? javascriptChannels,
    String? cacheMode,
    String? errorFallbackUrl,
    bool disableErrorFallback = false,
    int? loadId,
  }) async {
    final Map<String, Object?> args = <String, Object?>{
      "initialUrl": url,
      "javaScriptChannelName": javascriptChannelName,
      "isChart": isChart,
      "backgroundColor": backgroundColor,
      "javaScriptChannels": javascriptChannels,
      "cacheMode": cacheMode,
      "loadId": loadId,
    };
    // Presence of the key is meaningful: it disables the legacy isChart fallback even when null.
    if (errorFallbackUrl != null || disableErrorFallback) {
      args["errorFallbackUrl"] = errorFallbackUrl;
    }
    try {
      await _channel.invokeMethod<void>("loadUrl", args);
    } on PlatformException catch (e) {
      debugPrint("Failed to open WebView: '${e.message}'.");
    } on MissingPluginException catch (e) {
      debugPrint("openWebView not implemented: '${e.message}'.");
    }
  }

  /// Creates the native WebView, and optionally loads [url], before any platform view mounts.
  ///
  /// This moves WebView construction and the page's JavaScript parse off the critical path.
  /// Register [javascriptChannels] here: a channel only takes effect on the *next* navigation,
  /// so this is the only ordering that guarantees the page can post its first message.
  ///
  /// A detached WebView has a zero-size viewport, so a layout-driven page can render
  /// degenerately. Supply [width] and [height] to lay it out, and prefer to defer any
  /// content-loading call until the view is actually mounted.
  static Future<Map<String, Object?>> prewarm({
    String? url,
    List<String>? javascriptChannels,
    String? cacheMode,
    bool? offscreenPreRaster,
    int? width,
    int? height,
    int? loadId,
  }) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "prewarm",
        <String, Object?>{
          "url": url,
          "javaScriptChannels": javascriptChannels,
          "cacheMode": cacheMode,
          "offscreenPreRaster": offscreenPreRaster,
          "width": width,
          "height": height,
          "loadId": loadId,
        },
      );
      return res == null ? <String, Object?>{} : Map<String, Object?>.from(res);
    } on PlatformException catch (e) {
      debugPrint("Failed to prewarm: '${e.message}'.");
      return <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    }
  }

  /// Adds a JavaScript channel named [channelName].
  ///
  /// Prefer passing the name to [openWebView] or [prewarm]: a channel registered while no
  /// WebView exists cannot be installed, and only takes effect on the next navigation.
  static Future<void> addJavascriptChannel(String channelName) async {
    try {
      await _channel.invokeMethod<Object?>(
        "addJavascriptChannel",
        <String, Object?>{"channelName": channelName},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
    }
  }

  /// Removes the JavaScript channel named [channelName].
  static Future<bool> removeJavascriptChannel(String channelName) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "removeJavascriptChannel",
        <String, Object?>{"channelName": channelName},
      );
      return res?["removed"] as bool? ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Reloads the current URL.
  static Future<void> reloadUrl() async {
    try {
      await _channel.invokeMethod<void>("reloadUrl");
    } on PlatformException catch (e) {
      debugPrint("Failed to reload URL: ${e.message}");
      rethrow;
    }
  }

  /// Clears the WebView's HTTP cache.
  ///
  /// Only the HTTP cache: DOM storage, cookies and history are untouched. Use
  /// [clearBrowsingData] when more is needed.
  static Future<void> resetCache() async {
    try {
      await _channel.invokeMethod<void>("resetCache");
    } on PlatformException catch (e) {
      debugPrint("Failed to reset cache: ${e.message}");
      rethrow;
    }
  }

  /// Clears the selected browsing data, completing only once removal has finished.
  ///
  /// [preset] accepts `cold`, `netColdSessionWarm`, `netWarmSessionCold` or `warm`; otherwise the
  /// individual flags apply. Cookie and DOM-storage removal are **profile-global** — they affect
  /// every WebView in the host app — so this is a debug facility, and cookie clearing is ignored
  /// in a release build.
  static Future<List<String>> clearBrowsingData({
    String? preset,
    bool httpCache = false,
    bool domStorage = false,
    bool cookies = false,
    bool history = false,
  }) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "clearBrowsingData",
        <String, Object?>{
          "preset": preset,
          "httpCache": httpCache,
          "domStorage": domStorage,
          "cookies": cookies,
          "history": history,
        },
      );
      final Object? cleared = res?["cleared"];
      return cleared is List ? cleared.map((Object? e) => e.toString()).toList() : <String>[];
    } on PlatformException catch (e) {
      debugPrint("Failed to clear browsing data: ${e.message}");
      return <String>[];
    } on MissingPluginException {
      return <String>[];
    }
  }

  /// Sets the WebView cache mode.
  ///
  /// Accepts `default`, `cacheElseNetwork`, `noCache` or `cacheOnly`. Note the setting is
  /// WebView-global: `cacheElseNetwork` will serve a stale entry for *every* resource, including
  /// the entry document, so it is a diagnostic rather than a production setting.
  static Future<Map<String, Object?>> setCacheMode(String mode) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "setCacheMode",
        <String, Object?>{"mode": mode},
      );
      return res == null ? <String, Object?>{} : Map<String, Object?>.from(res);
    } on PlatformException {
      return <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    }
  }

  /// Executes the given JavaScript [script] in the web view.
  static Future<void> runJavaScript(String script) async {
    try {
      await _channel.invokeMethod<void>(
        "runJavaScript",
        <String, Object?>{"script": script},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to run JavaScript: '${e.message}'.");
    } on MissingPluginException catch (e) {
      debugPrint("runJavaScript not implemented: '${e.message}'.");
    }
  }

  /// Evaluates [script] and returns its decoded result.
  ///
  /// The platform hands back a JSON-encoded string, so this decodes it — unlike [runJavaScript],
  /// which discards the value.
  static Future<Object?> evaluateJavaScript(String script) async {
    try {
      final String? encoded = await _channel.invokeMethod<String>(
        "runJavaScript",
        <String, Object?>{"script": script},
      );
      if (encoded == null || encoded == "null") return null;
      try {
        return jsonDecode(encoded);
      } on FormatException {
        return encoded;
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to evaluate JavaScript: '${e.message}'.");
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Returns the current loaded URL from the web view.
  static Future<String> getCurrentLoadedUrl() async {
    try {
      return await _channel.invokeMethod<String>("getCurrentUrl") ?? "";
    } on PlatformException catch (e) {
      debugPrint("Failed to get current URL: '${e.message}'.");
      rethrow;
    }
  }

  /// Reads the native clocks back to back, so a monotonic native timestamp can be mapped into
  /// Dart's timebase.
  static Future<Map<String, Object?>> getClockSync() async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>("getClockSync");
      return res == null ? <String, Object?>{} : Map<String, Object?>.from(res);
    } on PlatformException {
      return <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    }
  }

  /// Returns WebView state and capabilities.
  ///
  /// Record `webViewVersion` alongside any measurement: the System WebView updates out of band
  /// and can shift timings materially.
  static Future<Map<String, Object?>> getDiagnostics() async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>("getDiagnostics");
      return res == null ? <String, Object?>{} : Map<String, Object?>.from(res);
    } on PlatformException {
      return <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    }
  }

  /// Requests a callback once the renderer has painted, delivered as a visual-state event.
  static Future<bool> postVisualStateCallback(int requestId) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "postVisualStateCallback",
        <String, Object?>{"requestId": requestId},
      );
      return res?["scheduled"] as bool? ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Enables or disables forwarding of page console messages.
  ///
  /// Off by default. Forwarding costs a channel send per message on the UI thread, which is
  /// measurable if it happens while timing a load.
  static Future<void> setConsoleForwarding({
    required bool enabled,
    String? minLevel,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        "setConsoleForwarding",
        <String, Object?>{"enabled": enabled, "minLevel": minLevel},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to set console forwarding: ${e.message}");
    } on MissingPluginException {
      // Older native side; nothing to do.
    }
  }

  /// Enables or disables forwarding of load-progress events.
  ///
  /// Off by default: progress fires many times per load, and its ordering relative to page
  /// completion is not guaranteed.
  static Future<void> setProgressForwarding({required bool enabled}) async {
    try {
      await _channel.invokeMethod<void>(
        "setProgressForwarding",
        <String, Object?>{"enabled": enabled},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to set progress forwarding: ${e.message}");
    } on MissingPluginException {
      // Older native side; nothing to do.
    }
  }

  /// Enables remote inspection of WebView contents.
  ///
  /// Ignored in a release build.
  static Future<Map<String, Object?>> setWebContentsDebuggingEnabled(
    // ignore: avoid_positional_boolean_parameters
    bool enabled,
  ) async {
    try {
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        "setWebContentsDebuggingEnabled",
        <String, Object?>{"enabled": enabled},
      );
      return res == null ? <String, Object?>{} : Map<String, Object?>.from(res);
    } on PlatformException {
      return <String, Object?>{};
    } on MissingPluginException {
      return <String, Object?>{};
    }
  }

  /// Destroys the native WebView.
  ///
  /// The WebView is a process-wide singleton shared by every platform view, so this discards the
  /// loaded page for the whole app.
  static Future<void> destroyWebView() async {
    try {
      await _channel.invokeMethod<void>("destroyWebView");
    } on PlatformException catch (e) {
      debugPrint("Failed to destroy WebView: ${e.message}");
    } on MissingPluginException {
      // Older native side; nothing to do.
    }
  }

  /// Registers [callback] to receive every event from the native WebView.
  ///
  /// Returns the subscription so it can be cancelled.
  @Deprecated("Listen to `events` instead, which is typed and safely multi-subscriber.")
  static StreamSubscription<Object?> getJavaScriptChannelStream(
    // Keeps `dynamic` deliberately: existing callers index the payload directly, and widening
    // to Object? would stop their code compiling.
    // ignore: avoid_annotating_with_dynamic
    void Function(dynamic) callback,
  ) {
    // Delivers the raw platform payload, unchanged, so existing callbacks keep working.
    return rawWebViewEvents.listen(callback);
  }

  /// Registers [callback] to be called for every event from the native WebView.
  ///
  /// Despite the name this is not filtered to load completion.
  @Deprecated("Listen to `events` instead and match on the event type.")
  static StreamSubscription<Object?> setWebViewLoadedCallback(
    // ignore: avoid_annotating_with_dynamic
    void Function(dynamic) callback,
  ) {
    return rawWebViewEvents.listen(callback);
  }

  /// Enables or disables user interaction with the web view.
  // ignore: avoid_positional_boolean_parameters
  static Future<void> setUserInteractionEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>(
        "setUserInteractionEnabled",
        <String, Object?>{"enabled": enabled},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to set user interaction: '${e.message}'.");
    } on MissingPluginException catch (e) {
      // MissingPluginException is not a PlatformException, so it would otherwise escape.
      debugPrint("setUserInteractionEnabled not implemented: '${e.message}'.");
    }
  }
}
