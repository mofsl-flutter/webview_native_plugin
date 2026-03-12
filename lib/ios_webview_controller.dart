import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WebViewMoFlutterController {
  static const MethodChannel _methodChannel = MethodChannel('webview_mo_flutter');
  static const EventChannel _eventChannel = EventChannel('webview_plugin_events');

  Stream<String>? _onPageLoadedStream;

  /// Loads a URL in the native web view.
  Future<void> loadUrl(String url) async {
    try {
      await _methodChannel.invokeMethod('loadUrl', {'initialUrl': url});
    } on PlatformException catch (e) {
      debugPrint("Failed to load URL: ${e.message}");
      rethrow;
    }
  }

  /// Reloads the current URL.
  Future<void> reloadUrl() async {
    try {
      await _methodChannel.invokeMethod('reloadUrl');
    } on PlatformException catch (e) {
      debugPrint("Failed to reload URL: ${e.message}");
      rethrow;
    }
  }

  /// Resets the web view's cache.
  Future<void> resetCache() async {
    try {
      await _methodChannel.invokeMethod('resetCache');
    } on PlatformException catch (e) {
      debugPrint("Failed to reset cache: ${e.message}");
      rethrow;
    }
  }

  /// Executes JavaScript in the native web view.
  Future<dynamic> runJavaScript(String script) async {
    try {
      final result = await _methodChannel.invokeMethod('runJavaScript', {'script': script});
      return result;
    } on PlatformException catch (e) {
      debugPrint("Failed to execute JavaScript: ${e.message}");
      rethrow;
    }
  }

  /// Adds a JavaScript channel to the web view.
  Future<void> addJavascriptChannel(String channelName) async {
    try {
      await _methodChannel.invokeMethod('addJavascriptChannel', {'channelName': channelName});
      _onMessageReceivedStream ??=
          _eventChannel.receiveBroadcastStream().map<String>((event) => event.toString());
    } on PlatformException catch (e) {
      debugPrint("Failed to add JavaScript channel: ${e.message}");
      rethrow;
    }
  }

  Stream<String>? _onMessageReceivedStream;

  Stream<String> get onMessageReceived => _onMessageReceivedStream!;

  /// Close the web view (if supported by the native code).
  Future<void> closeWebView() async {
    try {
      await _methodChannel.invokeMethod('close');
    } on PlatformException catch (e) {
      debugPrint("Failed to close web view: ${e.message}");
      rethrow;
    }
  }
}
