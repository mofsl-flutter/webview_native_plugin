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
import org.mockito.Mockito.RETURNS_DEFAULTS
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

    /**
     * Stands in for the singleton: a real `delegate` slot, every other call a no-op, except
     * `probe`, which completes immediately with a fixed script result like a healthy page would.
     */
    private val manager: WebViewManager = mock(WebViewManager::class.java) { call ->
        if (call.method.name == "probe") {
            @Suppress("UNCHECKED_CAST")
            (call.arguments[2] as (Map<String, Any?>) -> Unit)(mapOf("js" to "\"ok\"", "attached" to true))
            null
        } else {
            RETURNS_DEFAULTS.answer(call)
        }
    }
    private var held: WebViewControllerDelegate? = null

    /** Keeps what a method call answered with. */
    private class CapturingResult : MethodChannel.Result {
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { errorCode = code }
        override fun notImplemented() {}
    }

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

    @Test
    fun `claimDelegate takes the delegate back and reports whether it moved`() {
        val main = newPlugin()
        val other = newPlugin()
        main.onAttachedToEngine(binding())
        other.onAttachedToEngine(binding())
        main.onListen(null, RecordingSink())
        other.onMethodCall(MethodCall("prewarm", emptyMap<String, Any?>()), NoopResult())
        assertSame(other, held)

        val first = CapturingResult()
        main.onMethodCall(MethodCall("claimDelegate", mapOf("reason" to "test")), first)
        val second = CapturingResult()
        main.onMethodCall(MethodCall("claimDelegate", emptyMap<String, Any?>()), second)

        assertSame(main, held)
        assertEquals(true, (first.value as Map<*, *>)["changed"])
        assertEquals(false, (second.value as Map<*, *>)["changed"], "already owned, nothing moved")
    }

    @Test
    fun `probe reports whether this engine owns the delegate`() {
        val main = newPlugin()
        val other = newPlugin()
        main.onAttachedToEngine(binding())
        other.onAttachedToEngine(binding())
        main.onListen(null, RecordingSink())

        val owned = CapturingResult()
        main.onMethodCall(MethodCall("probe", mapOf("script" to "1")), owned)
        // The delegate moves to another engine: the page may be fine but events no longer arrive.
        other.onMethodCall(MethodCall("prewarm", emptyMap<String, Any?>()), NoopResult())
        val stolen = CapturingResult()
        main.onMethodCall(MethodCall("probe", mapOf("script" to "1")), stolen)

        assertEquals(true, (owned.value as Map<*, *>)["ownsDelegate"])
        assertEquals(false, (stolen.value as Map<*, *>)["ownsDelegate"])
        assertEquals("\"ok\"", (stolen.value as Map<*, *>)["js"], "script result still comes back")
    }

    @Test
    fun `probe without a script is rejected`() {
        val main = newPlugin()
        main.onAttachedToEngine(binding())
        val result = CapturingResult()
        main.onMethodCall(MethodCall("probe", emptyMap<String, Any?>()), result)
        assertEquals("INVALID_ARGUMENT", result.errorCode)
    }

    @Test
    fun `debugReleaseDelegate is refused on a release build`() {
        val main = newPlugin()
        main.onAttachedToEngine(binding())
        main.onListen(null, RecordingSink())
        // The mocked manager reports isDebuggable() == false, like a shipped app.
        val result = CapturingResult()
        main.onMethodCall(MethodCall("debugReleaseDelegate", emptyMap<String, Any?>()), result)
        assertEquals("RELEASE_BUILD", result.errorCode)
        assertSame(main, held, "a refused call must not touch ownership")
    }
}
