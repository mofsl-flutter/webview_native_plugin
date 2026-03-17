import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Plugin for interacting with the native iOS WebView.
class IosWebViewPlugin {
  static const MethodChannel _channel = MethodChannel("webview_mo_flutter");
  static const EventChannel _eventChannel =
      EventChannel("webview_plugin_events");

  static late Stream<String> _onMessageReceivedStream;

  /// Stream of messages received from the web view's JavaScript channel.
  Stream<String> get onMessageReceived => _onMessageReceivedStream;

  /// Opens the WebView in iOS with the given [url] and optional parameters.
  static Future<void> openWebView(
    String url, {
    String? javascriptChannelName,
    bool? isChart,
    String? backgroundColor,
  }) async {
    try {
      await _channel.invokeMethod<void>("loadUrl", <String, Object?>{
        "initialUrl": url,
        "javaScriptChannelName": javascriptChannelName,
        "isChart": isChart,
        "backgroundColor": backgroundColor,
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to open WebView: '${e.message}'.");
    }
  }

  /// Adds a JavaScript channel with the given [channelName].
  static Future<void> addJavascriptChannel(String channelName) async {
    try {
      debugPrint("addJavascriptChannel  $channelName");
      await _channel.invokeMethod<void>(
        "addJavascriptChannel",
        <String, Object?>{"channelName": channelName},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
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

  /// Resets the web view's cache.
  static Future<void> resetCache() async {
    try {
      await _channel.invokeMethod<void>("resetCache");
    } on PlatformException catch (e) {
      debugPrint("Failed to reset cache: ${e.message}");
      rethrow;
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

  /// Registers [callback] to receive messages from the JavaScript channel.
  static void getJavaScriptChannelStream(
    void Function(Object?) callback,
  ) {
    _eventChannel.receiveBroadcastStream().listen(callback);
  }

  /// Registers [callback] to be called when the web view finishes loading.
  static void setWebViewLoadedCallback(
    void Function(Object?) callback,
  ) {
    _eventChannel.receiveBroadcastStream().listen((Object? event) {
      debugPrint(event.toString());
      callback(event);
    });
  }

  /// Enables or disables user interaction with the web view.
  static Future<void> setUserInteractionEnabled({
    required bool enabled,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        "setUserInteractionEnabled",
        <String, Object?>{"enabled": enabled},
      );
    } on PlatformException catch (e) {
      debugPrint("Failed to set user interaction: '${e.message}'.");
    }
  }
}
