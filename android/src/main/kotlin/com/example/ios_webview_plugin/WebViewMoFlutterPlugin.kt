package com.example.ios_webview_plugin

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

private const val TAG = "WebViewMoFlutterPlugin"

/** Maximum events retained while no Dart subscriber is attached. */
private const val REPLAY_BUFFER_CAPACITY = 512

class WebViewMoFlutterPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    WebViewControllerDelegate {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private lateinit var context: Context
    private lateinit var webViewManager: WebViewManager
    private val uiThreadHandler: Handler = Handler(Looper.getMainLooper())

    /**
     * Events captured before Dart subscribed.
     *
     * The delegate is wired in [onAttachedToEngine] so pre-warm works before any subscriber
     * exists; without this buffer the page's first `PageReady` would be discarded and a
     * consumer waiting on it would hang. Only ever touched from the main thread, because every
     * append happens inside the posted lambda.
     */
    private val replayBuffer = ArrayDeque<Map<String, Any?>>()
    private var droppedEvents = 0

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        methodChannel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "webview_mo_flutter").apply {
                setMethodCallHandler(this@WebViewMoFlutterPlugin)
            }
        eventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "webview_plugin_events").apply {
                setStreamHandler(this@WebViewMoFlutterPlugin)
            }
        webViewManager = WebViewManager.getInstance(context)
        // Wired here, not in onListen, so events raised before Dart subscribes are buffered
        // rather than dropped.
        webViewManager.delegate = this
        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "web_view_mo_flutter",
            WebViewMoFlutterViewFactory(webViewManager)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        webViewManager.delegate = null
        eventSink = null
        replayBuffer.clear()
        // Deliberately does NOT destroy the WebView. It is a process-wide singleton: a hot
        // restart would otherwise throw away a pre-warmed page, and in a multi-engine host the
        // first engine to detach would destroy it out from under the others. Use the explicit
        // `destroyWebView` method instead.
    }

    override fun onWebViewEvent(event: Map<String, Any?>) {
        // Already timestamped at the point of capture by WebViewManager.emit().
        uiThreadHandler.post {
            val sink = eventSink
            if (sink != null) {
                sink.success(event)
            } else {
                if (replayBuffer.size >= REPLAY_BUFFER_CAPACITY) {
                    replayBuffer.pollFirst()
                    droppedEvents++
                }
                replayBuffer.addLast(event)
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        if (events == null) return
        if (droppedEvents > 0) {
            events.success(
                mapOf(
                    "event" to "bufferOverflow",
                    "dropped" to droppedEvents,
                    "ts" to System.currentTimeMillis()
                )
            )
            droppedEvents = 0
        }
        while (replayBuffer.isNotEmpty()) {
            events.success(replayBuffer.pollFirst())
        }
    }

    override fun onCancel(arguments: Any?) {
        // Null only the sink; keep the delegate so events continue to be buffered. This also
        // makes a hot-reload cancel/listen cycle lossless.
        eventSink = null
    }

    @Suppress("LongMethod", "CyclomaticComplexMethod")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadUrl" -> {
                val urlString = call.argument<String>("initialUrl")
                if (urlString == null) {
                    result.error("INVALID_ARGUMENT", "URL is required", null)
                    return
                }
                webViewManager.loadURL(
                    urlString = urlString,
                    javaScriptChannelName = call.argument<String>("javaScriptChannelName"),
                    isChart = call.argument<Boolean>("isChart") ?: true,
                    channels = call.argument<List<String>>("javaScriptChannels"),
                    cacheMode = call.argument<String>("cacheMode"),
                    backgroundColor = call.argument<String>("backgroundColor"),
                    fallbackUrl = call.argument<String>("errorFallbackUrl"),
                    fallbackUrlProvided = call.hasArgument("errorFallbackUrl"),
                    requestedLoadId = (call.argument<Number>("loadId"))?.toLong()
                )
                result.success(null)
            }

            "prewarm" -> {
                val info = webViewManager.prewarm(
                    url = call.argument<String>("url"),
                    channels = call.argument<List<String>>("javaScriptChannels"),
                    cacheMode = call.argument<String>("cacheMode"),
                    offscreenPreRaster = call.argument<Boolean>("offscreenPreRaster"),
                    width = call.argument<Number>("width")?.toInt(),
                    height = call.argument<Number>("height")?.toInt(),
                    requestedLoadId = call.argument<Number>("loadId")?.toLong()
                )
                result.success(info)
            }

            "runJavaScript" -> {
                val script = call.argument<String>("script")
                if (script == null) {
                    result.error("INVALID_ARGUMENT", "JavaScript code is required", null)
                    return
                }
                webViewManager.evaluateJavaScript(script) { response, error ->
                    if (error != null) {
                        result.error("NO_WEBVIEW", error.localizedMessage, null)
                    } else {
                        result.success(response)
                    }
                }
            }

            "reloadUrl" -> {
                val view = webViewManager.webView
                if (view == null) {
                    result.error("NO_WEBVIEW", "WebView does not exist", null)
                } else {
                    view.reload()
                    result.success(null)
                }
            }

            "resetCache" -> {
                webViewManager.resetWebViewCache()
                result.success(null)
            }

            "clearBrowsingData" -> {
                val preset = call.argument<String>("preset")
                val httpCache: Boolean
                val domStorage: Boolean
                val cookies: Boolean
                val history: Boolean
                when (preset) {
                    "cold" -> {
                        httpCache = true; domStorage = true; cookies = true; history = true
                    }
                    "netColdSessionWarm" -> {
                        httpCache = true; domStorage = false; cookies = false; history = false
                    }
                    "netWarmSessionCold" -> {
                        httpCache = false; domStorage = true; cookies = true; history = true
                    }
                    "warm" -> {
                        httpCache = false; domStorage = false; cookies = false; history = false
                    }
                    else -> {
                        httpCache = call.argument<Boolean>("httpCache") ?: false
                        domStorage = call.argument<Boolean>("domStorage") ?: false
                        cookies = call.argument<Boolean>("cookies") ?: false
                        history = call.argument<Boolean>("history") ?: false
                    }
                }
                webViewManager.clearBrowsingData(
                    httpCache, domStorage, cookies, history
                ) { cleared ->
                    result.success(
                        mapOf("cleared" to cleared, "ts" to System.currentTimeMillis())
                    )
                }
            }

            "setCacheMode" -> {
                val mode = call.argument<String>("mode")
                if (mode == null) {
                    result.error("INVALID_ARGUMENT", "mode is required", null)
                } else {
                    result.success(webViewManager.applyCacheMode(mode))
                }
            }

            "addJavascriptChannel" -> {
                val channelName = call.argument<String>("channelName")
                if (channelName == null) {
                    result.error("INVALID_ARGUMENT", "Channel name is required", null)
                } else {
                    result.success(webViewManager.addJavascriptChannel(channelName))
                }
            }

            "removeJavascriptChannel" -> {
                val channelName = call.argument<String>("channelName")
                if (channelName == null) {
                    result.error("INVALID_ARGUMENT", "Channel name is required", null)
                } else {
                    result.success(
                        mapOf("removed" to webViewManager.removeJavascriptChannel(channelName))
                    )
                }
            }

            "getCurrentUrl" -> result.success(webViewManager.webView?.url)

            "setUserInteractionEnabled" -> {
                // Accepts both the positional form used by existing callers and a map.
                val enabled = when (val args = call.arguments) {
                    is Boolean -> args
                    is Map<*, *> -> args["enabled"] as? Boolean ?: true
                    else -> true
                }
                webViewManager.setUserInteractionEnabled(enabled)
                result.success(null)
            }

            "setConsoleForwarding" -> {
                webViewManager.setConsoleForwarding(
                    call.argument<Boolean>("enabled") ?: false,
                    call.argument<String>("minLevel")
                )
                result.success(null)
            }

            "setProgressForwarding" -> {
                webViewManager.setProgressForwarding(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }

            "setWebContentsDebuggingEnabled" -> {
                result.success(
                    webViewManager.setWebContentsDebuggingEnabled(
                        call.argument<Boolean>("enabled") ?: false
                    )
                )
            }

            "postVisualStateCallback" -> {
                val requestId = call.argument<Number>("requestId")?.toLong()
                    ?: System.currentTimeMillis()
                result.success(
                    mapOf("scheduled" to webViewManager.postVisualStateCallback(requestId))
                )
            }

            "getClockSync" -> result.success(webViewManager.clockSync())

            "getDiagnostics" -> result.success(webViewManager.diagnostics())

            "destroyWebView" -> {
                webViewManager.destroyWebView()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }
}
