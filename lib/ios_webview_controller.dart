import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Controller for the native web view on iOS.
class WebViewMoFlutterController {
  static const MethodChannel _methodChannel =
      MethodChannel("webview_mo_flutter");
  static const EventChannel _eventChannel =
      EventChannel("webview_plugin_events");

  late Stream<String> _onPageLoadedStream;
  late Stream<String> _onMessageReceivedStream;

  /// Loads a URL in the native web view.
  Future<void> loadUrl(final String url) async {
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
  Future<dynamic> runJavaScript(final String script) async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
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
  Future<void> addJavascriptChannel(final String channelName) async {
    try {
      await _methodChannel.invokeMethod<void>(
        "addJavascriptChannel",
        <String, Object?>{"channelName": channelName},
      );
      _onMessageReceivedStream = _eventChannel
          .receiveBroadcastStream()
          .map<String>((final Object? event) => event.toString());
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
    }
  }

  /// Stream of messages received from the web view.
  Stream<String> get onMessageReceived => _onMessageReceivedStream;

  /// Close the web view (if supported by the native code).
  Future<void> closeWebView() async {
    try {
      await _methodChannel.invokeMethod<void>("close");
    } on PlatformException catch (e) {
      debugPrint("Failed to close web view: ${e.message}");
      rethrow;
    }
  }
}
