import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IosWebViewPlugin {
  static const MethodChannel _channel = MethodChannel('webview_mo_flutter');
  static const EventChannel _eventChannel = EventChannel('webview_plugin_events');
  // Method to open the WebView in iOS
  // Stream<String>? _onPageLoadedStream;
  static Stream<String>? _onMessageReceivedStream;
  Stream<String> get onMessageReceived => _onMessageReceivedStream!;
  static Future<void> openWebView(
    String url, {
    String? javascriptChannelName,
    bool? isChart,
    String? backgroundColor,
  }) async {
    try {
      await _channel.invokeMethod('loadUrl', {
        'initialUrl': url,
        'javaScriptChannelName': javascriptChannelName,
        'isChart': isChart,
        'backgroundColor': backgroundColor,
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to open WebView: '${e.message}'.");
    }
  }

  static Future<void> addJavascriptChannel(String channelName) async {
    try {
      debugPrint("addJavascriptChannel  $channelName");
      await _channel.invokeMethod('addJavascriptChannel', {'channelName': channelName});
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
    }
  }

  /// Reloads the current URL.
  static Future<void> reloadUrl() async {
    try {
      await _channel.invokeMethod('reloadUrl');
    } on PlatformException catch (e) {
      debugPrint("Failed to reload URL: ${e.message}");
      rethrow;
    }
  }

  /// Resets the web view's cache.
  static Future<void> resetCache() async {
    try {
      await _channel.invokeMethod('resetCache');
    } on PlatformException catch (e) {
      debugPrint("Failed to reset cache: ${e.message}");
      rethrow;
    }
  }

  // Method to authenticate the webviewSession in iOS
  static Future<void> runJavaScript(String script) async {
    try {
      await _channel.invokeMethod('runJavaScript', {'script': script});
    } on PlatformException catch (e) {
      debugPrint("Failed to run JavaScript: '${e.message}'.");
    }
  }

  // Stream<String> get onPageLoaded {
  //   _onPageLoadedStream ??=
  //       _eventChannel.receiveBroadcastStream().map<String>((event) => event as String);
  //   return _onPageLoadedStream!;
  // }
  static Future<String> getCurrentLoadedUrl() async {
    try {
      return await _channel.invokeMethod('getCurrentUrl');
    } on PlatformException catch (e) {
      debugPrint("Failed to get current URL: '${e.message}'.");
      rethrow;
    }
  }

  static void getJavaScriptChannelStream(Function(dynamic) callback) {
    _eventChannel.receiveBroadcastStream().listen((event) {
      callback(event);
    });
  }

  static void setWebViewLoadedCallback(Function(dynamic) callback) {
    _eventChannel.receiveBroadcastStream().listen((event) {
      debugPrint(event.toString());
      callback(event);
    });
  }

  static Future<void> setUserInteractionEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setUserInteractionEnabled', {'enabled': enabled});
    } on PlatformException catch (e) {
      debugPrint("Failed to set user interaction: '${e.message}'.");
    }
  }
}
