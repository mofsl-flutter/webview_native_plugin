package com.example.ios_webview_plugin

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformViewRegistry
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.inOrder
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The WebView and its [WebViewManager] are process-wide, but a Flutter app can host more than one
 * engine: `firebase_messaging` starts a headless engine for background pushes, and that engine
 * registers every plugin too. Events must keep flowing to the engine that actually drives the
 * WebView (the one whose Dart code listens and calls `loadUrl`/`prewarm`), not to whichever
 * engine attached last.
 */
class DelegateOwnershipTest {

    /** Stands in for the singleton: a real `delegate` slot, every other call a no-op. */
    private val manager: WebViewManager = mock(WebViewManager::class.java)
    private var held: WebViewControllerDelegate? = null

    private class RecordingSink : EventChannel.EventSink {
        val events = mutableListOf<Any?>()
        override fun success(event: Any?) { events.add(event) }
        override fun error(code: String?, message: String?, details: Any?) {}
        override fun endOfStream() {}
    }

    private class NoopResult : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) {}
        override fun notImplemented() {}
    }

    init {
        `when`(manager.delegate).thenAnswer { held }
        doAnswer { held = it.arguments[0] as WebViewControllerDelegate?; null }
            .`when`(manager).delegate = any()
    }

    private fun newPlugin(): WebViewMoFlutterPlugin =
        WebViewMoFlutterPlugin(managerProvider = { manager }, postToMain = { it.run() })

    private fun binding(): FlutterPlugin.FlutterPluginBinding {
        val b = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(b.applicationContext).thenReturn(mock(Context::class.java))
        `when`(b.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
        `when`(b.platformViewRegistry).thenReturn(mock(PlatformViewRegistry::class.java))
        return b
    }

    private fun event(name: String): Map<String, Any?> = mapOf("event" to name, "loadId" to 0L)

    @Test
    fun `engine that loads the page keeps receiving events after a later engine attaches`() {
        val main = newPlugin()
        val headless = newPlugin()
        val sink = RecordingSink()

        main.onAttachedToEngine(binding())
        main.onListen(null, sink)
        headless.onAttachedToEngine(binding())

        main.onMethodCall(MethodCall("loadUrl", mapOf("initialUrl" to "https://chart")), NoopResult())
        held!!.onWebViewEvent(event("loadRequested"))

        assertSame(main, held)
        assertEquals(listOf("loadRequested"), sink.events.map { (it as Map<*, *>)["event"] })
    }

    @Test
    fun `a later engine detaching does not drop the owning engine`() {
        val main = newPlugin()
        val headless = newPlugin()
        val headlessBinding = binding()

        main.onAttachedToEngine(binding())
        main.onListen(null, RecordingSink())
        headless.onAttachedToEngine(headlessBinding)
        main.onMethodCall(MethodCall("loadUrl", mapOf("initialUrl" to "https://chart")), NoopResult())

        headless.onDetachedFromEngine(headlessBinding)

        assertSame(main, held)
    }

    @Test
    fun `prewarm claims the delegate before the manager creates the WebView`() {
        val main = newPlugin()
        val headless = newPlugin()

        main.onAttachedToEngine(binding())
        headless.onAttachedToEngine(binding())

        main.onMethodCall(MethodCall("prewarm", emptyMap<String, Any?>()), NoopResult())

        // webViewCreated is emitted from inside prewarm(); the claim must precede it.
        val order = inOrder(manager)
        order.verify(manager).delegate = main
        order.verify(manager).prewarm(any(), any(), any(), any(), any(), any(), any())
        assertSame(main, held)

        held!!.onWebViewEvent(event("webViewCreated"))
        val sink = RecordingSink()
        main.onListen(null, sink)
        assertEquals(listOf("webViewCreated"), sink.events.map { (it as Map<*, *>)["event"] })
    }

    @Test
    fun `attaching alone never claims the delegate`() {
        val headless = newPlugin()
        headless.onAttachedToEngine(binding())
        assertTrue(held == null, "attach must not claim; only listen/loadUrl/prewarm do")
    }
}
