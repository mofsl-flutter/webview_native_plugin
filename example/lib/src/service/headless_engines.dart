import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';

const MethodChannel _channel = MethodChannel('recovery_harness/engine');

/// Starts and stops extra Flutter engines in this process.
///
/// This is what `firebase_messaging` does when a push arrives while the app is in the background:
/// it starts a second, headless engine and registers every plugin on it. That engine attaching is
/// what took the plugin's event delegate away from the foreground engine on 2026-10-22, so the
/// recovery cases need to be able to do the same thing deliberately.
///
/// Android only. The native side is `MainActivity`'s `recovery_harness/engine` channel.
class HeadlessEngines {
  /// Starts an engine that only registers plugins and does nothing with them, like a headless
  /// engine whose Dart code never touches the WebView.
  Future<void> spawnIdle() => _spawn('headlessIdle');

  /// Starts an engine whose Dart code calls the plugin's `prewarm`, like a headless engine that
  /// really does use the WebView. Using the plugin legitimately claims the delegate.
  Future<void> spawnUsingPlugin() => _spawn('headlessPrewarm');

  Future<void> _spawn(String entrypoint) async {
    await _channel.invokeMethod<int>('spawn', <String, Object?>{'entrypoint': entrypoint});
  }

  /// Destroys every engine started through this class. A destroyed engine detaches its plugins,
  /// which is the other half of the lifecycle a real headless engine goes through.
  Future<void> disposeAll() async {
    try {
      await _channel.invokeMethod<void>('disposeAll');
    } on MissingPluginException {
      // Not an Android build; nothing was ever started.
    }
  }
}

/// Entrypoint for [HeadlessEngines.spawnIdle].
@pragma('vm:entry-point')
Future<void> headlessIdle() async {
  WidgetsFlutterBinding.ensureInitialized();
}

/// Entrypoint for [HeadlessEngines.spawnUsingPlugin].
@pragma('vm:entry-point')
Future<void> headlessPrewarm() async {
  WidgetsFlutterBinding.ensureInitialized();
  await IosWebViewPlugin.prewarm();
}
