import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "webview_events.dart";

/// Controller for the native web view on iOS.
class WebViewMoFlutterController {
  static const MethodChannel _methodChannel =
      MethodChannel("webview_mo_flutter");

  /// Loads a URL in the native web view.
  Future<void> loadUrl(String url) async {
    try {
      await _methodChannel.invokeMethod<void>(
        "loadUrl",
        <String, Object?>{"initialUrl": url},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to load URL: ${e.message}");
      rethrow;
    }
  }

  /// Reloads the current URL.
  Future<void> reloadUrl() async {
    try {
      await _methodChannel.invokeMethod<void>("reloadUrl");
    } on PlatformException catch (e) {
      debugPrint("Failed to reload URL: ${e.message}");
      rethrow;
    }
  }

  /// Resets the web view's cache.
  Future<void> resetCache() async {
    try {
      await _methodChannel.invokeMethod<void>("resetCache");
    } on PlatformException catch (e) {
      debugPrint("Failed to reset cache: ${e.message}");
      rethrow;
    }
  }

  /// Executes JavaScript in the native web view.
  Future<dynamic> runJavaScript(String script) async {
    try {
      dynamic result = await _methodChannel.invokeMethod<dynamic>(
        "runJavaScript",
        <String, Object?>{"script": script},
      );
      return result;
    } on PlatformException catch (e) {
      debugPrint("Failed to execute JavaScript: ${e.message}");
      rethrow;
    }
  }

  /// Adds a JavaScript channel to the web view.
  Future<void> addJavascriptChannel(String channelName) async {
    try {
      await _methodChannel.invokeMethod<void>(
        "addJavascriptChannel",
        <String, Object?>{"channelName": channelName},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
    }
  }

  /// Stream of messages received from the web view.
  ///
  /// Backed by the library's single shared event subscription, so this is safe to read before
  /// [addJavascriptChannel] and safe to listen to more than once.
  Stream<String> get onMessageReceived => webViewEvents
      .where((WebViewEvent e) => e is WebViewChannelMessageEvent)
      .map((WebViewEvent e) => (e as WebViewChannelMessageEvent).message);

  /// Closes the web view, where the native side supports it.
  ///
  /// Neither platform implements `close` today, so this reports and returns rather than
  /// throwing. Note [MissingPluginException] is not a [PlatformException], so it needs its own
  /// clause or it escapes uncaught.
  Future<void> closeWebView() async {
    try {
      await _methodChannel.invokeMethod<void>("close");
    } on PlatformException catch (e) {
      debugPrint("Failed to close web view: ${e.message}");
    } on MissingPluginException catch (e) {
      debugPrint("closeWebView not implemented: ${e.message}");
    }
  }
}
