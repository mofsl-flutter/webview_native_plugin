package com.example.ios_webview_plugin

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fills the WebView HTTP cache with the chart's JavaScript library, from a throwaway WebView.
 *
 * It is deliberately separate from [WebViewManager]'s singleton: that WebView is the chart, with a
 * `ChartController` listening to it, and anything loaded into it would race that listener. The
 * warmer is created, runs one script, reports once and is destroyed.
 *
 * The script ([lib/src/cache_warmer_js.dart]) has to run in a WebView so the entries it writes are
 * the ones the chart's own requests will read. All WebViews in a process share one HTTP cache.
 *
 * Constraints this honours:
 * * One warm-up at a time, process-wide. A second call is answered `busy` rather than queued, which
 *   also covers a Dart hot restart that forgot a warm-up was already running.
 * * The WebView is created, driven and destroyed on the main thread. The JavaScript bridge calls
 *   back on a WebView-internal thread, so it hops to main before anything else happens.
 * * The result is delivered exactly once, whichever of report, timeout, error or cancellation
 *   gets there first.
 * * Never calls `pauseTimers`/`resumeTimers`. Those are process-global and would stall the chart.
 */
internal class CacheWarmer private constructor(
    private val context: Context,
    private val args: Args,
    private val owner: Any,
    private val reply: (Map<String, Any?>) -> Unit
) {

    class Args(
        /** `baseUrl` (load generated HTML under the chart origin) or `navigate`. */
        val mode: String,
        val baseUrl: String,
        val html: String,
        val script: String,
        val navigateUrl: String,
        val timeoutMs: Long
    )

    private val main = Handler(Looper.getMainLooper())
    private val finished = AtomicBoolean(false)
    private var webView: WebView? = null
    private val onTimeout = Runnable { finish(mapOf("ok" to false, "reason" to "timeout")) }

    private inner class Bridge {
        @JavascriptInterface
        fun report(json: String) {
            main.post { finishFromReport(json) }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun begin() {
        val view = WebView(context)
        webView = view
        view.settings.javaScriptEnabled = true
        view.addJavascriptInterface(Bridge(), BRIDGE_NAME)
        view.webViewClient = object : WebViewClient() {
            private var injected = false

            override fun onPageFinished(v: WebView?, url: String?) {
                // In `baseUrl` mode the script is already inline in the page. In `navigate` mode
                // the page is just a document on the right origin and the script is injected.
                if (args.mode == MODE_NAVIGATE && !injected) {
                    injected = true
                    v?.evaluateJavascript(args.script, null)
                }
            }

            // The framework's three-argument overload calls this one for the main frame on every
            // API level, so this single override covers minSdk 21 and up.
            @Suppress("DEPRECATION")
            @Deprecated("Deprecated in Java")
            override fun onReceivedError(
                v: WebView?,
                errorCode: Int,
                description: String?,
                failingUrl: String?
            ) {
                finish(
                    mapOf(
                        "ok" to false,
                        "reason" to "navigation failed",
                        "error" to description,
                        "url" to failingUrl
                    )
                )
            }

            override fun onRenderProcessGone(
                v: WebView?,
                detail: RenderProcessGoneDetail?
            ): Boolean {
                // Returning false would kill the whole app. The renderer is shared with the chart,
                // so its own client handles its recovery; this one only has to report and go.
                finish(mapOf("ok" to false, "reason" to "renderer gone"))
                return true
            }
        }

        main.postDelayed(onTimeout, args.timeoutMs)
        if (args.mode == MODE_NAVIGATE) {
            view.loadUrl(args.navigateUrl)
        } else {
            view.loadDataWithBaseURL(args.baseUrl, args.html, "text/html", "UTF-8", null)
        }
    }

    private fun finishFromReport(json: String) {
        val parsed = try {
            toMap(JSONObject(json))
        } catch (e: Exception) {
            mapOf<String, Any?>("ok" to false, "reason" to "bad report", "error" to e.message)
        }
        finish(parsed)
    }

    private fun stopFetching() {
        webView?.evaluateJavascript("window.__warmStop=true;", null)
    }

    private fun finish(result: Map<String, Any?>) {
        if (!finished.compareAndSet(false, true)) return
        main.removeCallbacks(onTimeout)
        val view = webView
        webView = null
        if (view != null) {
            // Order matters: stop in-flight work before dropping the bridge, then destroy.
            runCatching { view.stopLoading() }
            runCatching { view.removeJavascriptInterface(BRIDGE_NAME) }
            runCatching { view.destroy() }
        }
        synchronized(lock) { if (current === this) current = null }
        // The engine that asked may be gone by now; a reply to it is best effort.
        runCatching { reply(result) }
    }

    companion object {
        private const val BRIDGE_NAME = "__WarmBridge"
        const val MODE_NAVIGATE = "navigate"

        private val lock = Any()

        /** Guarded by [lock]. */
        private var current: CacheWarmer? = null

        /** Starts a warm-up. Must be called on the main thread. [reply] is called exactly once. */
        fun start(
            context: Context,
            args: Args,
            owner: Any,
            reply: (Map<String, Any?>) -> Unit
        ) {
            val warmer = synchronized(lock) {
                if (current != null) {
                    null
                } else {
                    CacheWarmer(context, args, owner, reply).also { current = it }
                }
            }
            if (warmer == null) {
                reply(mapOf("ok" to false, "reason" to "busy"))
                return
            }
            try {
                warmer.begin()
            } catch (t: Throwable) {
                warmer.finish(
                    mapOf("ok" to false, "reason" to "start failed", "error" to t.message)
                )
            }
        }

        /** Asks the running warm-up to start no new fetches; in-flight ones still finish. */
        fun stop() {
            val warmer = synchronized(lock) { current }
            warmer?.stopFetching()
        }

        /**
         * Abandons a warm-up started by [owner]. A multi-engine host has several plugin instances,
         * and one detaching must not cancel another's work.
         */
        fun cancel(owner: Any) {
            val warmer = synchronized(lock) { current?.takeIf { it.owner === owner } }
            warmer?.finish(mapOf("ok" to false, "reason" to "detached"))
        }

        private fun toMap(o: JSONObject): Map<String, Any?> {
            val out = HashMap<String, Any?>()
            for (key in o.keys()) out[key] = fromJson(o.get(key))
            return out
        }

        private fun fromJson(v: Any?): Any? = when (v) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(v)
            is JSONArray -> (0 until v.length()).map { fromJson(v.get(it)) }
            else -> v
        }
    }
}
