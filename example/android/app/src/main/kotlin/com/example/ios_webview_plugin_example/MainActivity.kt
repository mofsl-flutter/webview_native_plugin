package com.example.ios_webview_plugin_example

import android.content.Intent
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes the launch intent's extras to Dart.
 *
 * This is what lets the regression suite be driven from a host script: the orchestrator sets an
 * adb precondition (kill the process, enable airplane mode, clear data), launches with
 * `--es scenario <id>`, and the app runs that one case and logs its verdict. Driving the UI by
 * synthetic taps was tried and is unusable — coordinates are fragile and input lands in whatever
 * app happens to be foreground.
 *
 * `singleTop` means a relaunch while the app is already running — including a plain app-icon tap
 * once a task exists, which is exactly what the "reopen the app" regression cases simulate — is
 * delivered to [onNewIntent], not a fresh `onCreate`. That new intent is forwarded to Dart over
 * the same channel so a resume-driven scenario request is not silently dropped.
 */
class MainActivity : FlutterActivity() {

    private var launchChannel: MethodChannel? = null

    /** Extra engines started on request; see [spawnHeadlessEngine]. */
    private val headlessEngines = mutableListOf<FlutterEngine>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "recovery_harness/engine")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "spawn" -> {
                        spawnHeadlessEngine(call.argument<String>("entrypoint") ?: "headlessIdle")
                        result.success(headlessEngines.size)
                    }
                    "disposeAll" -> {
                        headlessEngines.forEach { it.destroy() }
                        headlessEngines.clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "regression_harness/launch"
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchArgs" -> result.success(extrasOf(intent))
                else -> result.notImplemented()
            }
        }
        launchChannel = channel
    }

    /**
     * Starts a second engine in this process and runs [entrypoint] on it.
     *
     * This is what `firebase_messaging` does when a push arrives in the background: a headless
     * engine, with every plugin registered on it. Registering plugins is automatic for an engine
     * built this way, which is the point: the plugin's `onAttachedToEngine` runs on it exactly as
     * it does in production.
     */
    private fun spawnHeadlessEngine(entrypoint: String) {
        val engine = FlutterEngine(applicationContext)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                // The entrypoints are not in main.dart, so the library has to be named.
                "package:ios_webview_plugin_example/src/service/headless_engines.dart",
                entrypoint
            )
        )
        headlessEngines.add(engine)
    }

    override fun onDestroy() {
        headlessEngines.forEach { it.destroy() }
        headlessEngines.clear()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launchChannel?.invokeMethod("onNewIntent", extrasOf(intent))
    }

    private fun extrasOf(intent: Intent?): Map<String, Any?> {
        val extras = intent?.extras
        val map = HashMap<String, Any?>()
        if (extras != null) {
            for (key in extras.keySet()) {
                // Only forward scalars; anything else is not something a launch
                // argument should be carrying.
                when (val value = extras.get(key)) {
                    is String, is Boolean, is Int, is Long, is Double -> map[key] = value
                    else -> map[key] = value?.toString()
                }
            }
        }
        return map
    }
}
