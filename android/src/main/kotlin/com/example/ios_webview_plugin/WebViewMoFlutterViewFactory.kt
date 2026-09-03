package com.example.ios_webview_plugin

import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.http.SslError
import android.os.Build
import android.os.Message
import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.webkit.WebResourceErrorCompat
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

private const val TAG = "WebViewMoFlutterPlugin"

/**
 * Transport for structured WebView events.
 *
 * [event] always contains at least `"event"`, `"ts"`, `"tsMono"` and `"loadId"`. Called from
 * arbitrary threads (the UI thread and WebView JavaBridge threads), so implementations must
 * marshal to the platform thread themselves.
 *
 * This is an internal API of the plugin; it is `public` only because Kotlin cannot cleanly expose
 * an `internal` supertype from a public class.
 */
interface WebViewControllerDelegate {
    fun onWebViewEvent(event: Map<String, Any?>)
}

class WebViewMoFlutterViewFactory(
    private val webViewManager: WebViewManager
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return WebViewMoFlutter(context, viewId, args, webViewManager)
    }
}

class WebViewMoFlutter(
    context: Context,
    private val viewId: Int,
    args: Any?,
    private val webViewManager: WebViewManager
) : PlatformView {

    private val container = FrameLayout(context)
    private val webView = webViewManager.getOrCreateWebView()

    init {
        // Android previously ignored creation params entirely. Honour the two that iOS reads.
        // `initialUrl` stays deliberately inert: loading from the view constructor would race
        // pre-warm and make the load timeline ambiguous.
        (args as? Map<*, *>)?.let { map ->
            (map["backgroundColor"] as? String)?.let { webViewManager.applyBackgroundColor(it) }
            (map["isChart"] as? Boolean)?.let { webViewManager.setIsFromChart(it) }
        }
        attachWebViewToContainer(fromGetView = false)
    }

    private fun attachWebViewToContainer(fromGetView: Boolean) {
        try {
            val parent = webView.parent
            val wasReparented = parent != null && parent != container
            if (wasReparented) {
                (parent as? ViewGroup)?.removeView(webView)
            }

            if (webView.parent != container) {
                container.removeAllViews()
                container.addView(
                    webView,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                )
            }

            // Only resume if actually paused.
            if (webViewManager.isWebViewPaused) {
                webViewManager.resumeWebView()
            }

            if (!fromGetView) {
                webViewManager.emit(
                    "viewAttached",
                    "viewId" to viewId,
                    "wasReparented" to wasReparented
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error attaching WebView: ${e.message}")
            webViewManager.emit(
                "viewAttachFailed",
                "viewId" to viewId,
                "message" to (e.message ?: "unknown")
            )
        }
    }

    override fun getView(): View {
        attachWebViewToContainer(fromGetView = true)
        return container
    }

    override fun dispose() {
        container.removeAllViews()
        // Detach only — never pause or destroy. The singleton WebView and its loaded page
        // survive platform-view disposal, which is what makes chart reuse possible.
        webViewManager.detachWebView()
        webViewManager.emit("viewDetached", "viewId" to viewId)
    }
}

class WebViewManager private constructor(private val context: Context) {

    var delegate: WebViewControllerDelegate? = null
    var webView: WebView? = null
        private set

    private val configuredJavaScriptChannels: MutableSet<String> = mutableSetOf()

    /** Channels requested before a WebView existed; replayed on creation. */
    private val pendingJavaScriptChannels: MutableSet<String> = mutableSetOf()

    private val defaultURLString = "https://tradingview.com/"

    var isWebViewPaused: Boolean = false
        private set

    private var isFromChart: Boolean = true

    /** Explicit fallback target on load error. `null` disables the fallback entirely. */
    private var errorFallbackUrl: String? = null

    /** Monotonic load generation, stamped onto every event for attribution. */
    private var loadId: Long = -1L

    private var consoleForwarding: Boolean = false
    private var consoleMinLevel: Int = 0
    private var progressForwarding: Boolean = false

    /** When false the touch listener consumes events, blocking interaction with the page. */
    private var userInteractionEnabled: Boolean = true

    private val debuggable: Boolean =
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun debugLog(message: String) {
        if (debuggable) Log.d(TAG, message)
    }

    // ---------------------------------------------------------------- events

    /**
     * Builds and dispatches an event, stamping the clock **at the point of capture**.
     *
     * This must never be deferred into a `Handler.post` before stamping: the main thread is
     * congested while the page parses megabytes of JavaScript, which is precisely the interval
     * being measured, so a timestamp taken after the queue drains measures the wrong thing.
     */
    fun emit(name: String, vararg extras: Pair<String, Any?>) {
        val target = delegate ?: return
        val map = HashMap<String, Any?>(extras.size + 4)
        map["event"] = name
        map["ts"] = System.currentTimeMillis()
        map["tsMono"] = SystemClock.elapsedRealtime()
        map["loadId"] = loadId
        for ((k, v) in extras) map[k] = v
        target.onWebViewEvent(map)
    }

    fun clockSync(): Map<String, Any?> = mapOf(
        "currentTimeMillis" to System.currentTimeMillis(),
        "elapsedRealtime" to SystemClock.elapsedRealtime(),
        "uptimeMillis" to SystemClock.uptimeMillis()
    )

    fun diagnostics(): Map<String, Any?> {
        val pkg = runCatching { WebViewCompat.getCurrentWebViewPackage(context) }.getOrNull()
        return mapOf(
            "hasWebView" to (webView != null),
            "currentUrl" to webView?.url,
            "isPaused" to isWebViewPaused,
            "cacheMode" to cacheModeName(webView?.settings?.cacheMode),
            "configuredChannels" to configuredJavaScriptChannels.toList(),
            "pendingChannels" to pendingJavaScriptChannels.toList(),
            "webViewPackage" to pkg?.packageName,
            "webViewVersion" to pkg?.versionName,
            "sdkInt" to Build.VERSION.SDK_INT,
            "debuggable" to debuggable,
            "userInteractionEnabled" to userInteractionEnabled,
            "loadId" to loadId,
            "ts" to System.currentTimeMillis(),
            "tsMono" to SystemClock.elapsedRealtime()
        )
    }

    // ------------------------------------------------------------ web view

    fun getOrCreateWebView(): WebView {
        val existing = webView
        if (existing != null) {
            debugLog("Reusing existing WebView instance")
            resumeWebView()
            return existing
        }

        debugLog("Creating new WebView instance")
        configuredJavaScriptChannels.clear()
        configureWebContentsDebugging()

        // A fresh WebView is running. destroyWebView() leaves this flag true, and without
        // resetting it here a brand-new WebView is reported paused and gets a process-global
        // resumeTimers() from the platform view.
        isWebViewPaused = false

        val created = WebView(context)
        created.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            cacheMode = WebSettings.LOAD_DEFAULT
            javaScriptCanOpenWindowsAutomatically = true
            setSupportZoom(true)
            builtInZoomControls = false
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = true
            allowFileAccess = true
            allowContentAccess = true
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            // The chart needs no popups, and onCreateWindow cannot show a dialog from an
            // application context without throwing BadTokenException.
            setSupportMultipleWindows(false)
        }

        // The Flutter side paints the themed background behind the view, so the WebView itself
        // must stay transparent. Do not "fix" this.
        created.setBackgroundColor(Color.TRANSPARENT)

        created.setOnTouchListener { _, event ->
            if (!userInteractionEnabled) {
                true // consume, blocking the page
            } else {
                if (event.action == MotionEvent.ACTION_DOWN && isWebViewPaused) {
                    resumeWebView()
                }
                false
            }
        }

        created.webChromeClient = createChromeClient()
        created.webViewClient = createWebViewClient()
        webView = created

        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_VIEW_RENDERER_CLIENT_BASIC_USAGE)) {
            runCatching { attachRenderProcessClient(created) }
        }

        val pkg = runCatching { WebViewCompat.getCurrentWebViewPackage(context) }.getOrNull()
        emit(
            "webViewCreated",
            "webViewPackage" to pkg?.packageName,
            "webViewVersion" to pkg?.versionName,
            "sdkInt" to Build.VERSION.SDK_INT
        )

        // Replay any channel requested before the WebView existed.
        if (pendingJavaScriptChannels.isNotEmpty()) {
            val replay = pendingJavaScriptChannels.toList()
            pendingJavaScriptChannels.clear()
            for (name in replay) addJavascriptChannel(name)
        }

        return created
    }

    private fun attachRenderProcessClient(target: WebView) {
        WebViewCompat.setWebViewRenderProcessClient(
            target,
            object : androidx.webkit.WebViewRenderProcessClient() {
                override fun onRenderProcessUnresponsive(
                    view: WebView,
                    renderer: androidx.webkit.WebViewRenderProcess?
                ) {
                    emit("renderProcessUnresponsive", "url" to view.url)
                }

                override fun onRenderProcessResponsive(
                    view: WebView,
                    renderer: androidx.webkit.WebViewRenderProcess?
                ) {
                    emit("renderProcessResponsive", "url" to view.url)
                }
            }
        )
    }

    private fun createChromeClient(): WebChromeClient = object : WebChromeClient() {

        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
            if (debuggable) {
                Log.d(
                    TAG,
                    "WebViewConsole: ${consoleMessage.message()} " +
                        "at ${consoleMessage.sourceId()}:${consoleMessage.lineNumber()}"
                )
            }
            if (consoleForwarding && levelRank(consoleMessage.messageLevel()) >= consoleMinLevel) {
                emit(
                    "consoleMessage",
                    "message" to consoleMessage.message(),
                    "level" to consoleMessage.messageLevel().name,
                    "sourceId" to consoleMessage.sourceId(),
                    "lineNumber" to consoleMessage.lineNumber()
                )
            }
            // Keep returning true: returning false makes the framework emit its own
            // chromium: [INFO:CONSOLE(..)] logcat line on top of ours.
            return true
        }

        override fun onProgressChanged(view: WebView?, newProgress: Int) {
            super.onProgressChanged(view, newProgress)
            if (progressForwarding) {
                emit("pageProgress", "progress" to newProgress, "url" to view?.url)
            }
        }

        override fun onJsAlert(
            view: WebView?,
            url: String?,
            message: String?,
            result: JsResult?
        ): Boolean {
            emit("onJsAlert", "url" to url, "message" to message)
            // Always confirm. Returning true without confirming leaves the page's alert()
            // call unresolved and wedges its JavaScript thread permanently.
            result?.confirm()
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest?) {
            request?.grant(request.resources)
        }

        override fun onCreateWindow(
            view: WebView?,
            isDialog: Boolean,
            isUserGesture: Boolean,
            resultMsg: Message?
        ): Boolean {
            // Multiple windows are disabled in settings. Previously this built an AlertDialog
            // from the application context, which throws BadTokenException.
            emit("createWindowBlocked", "isDialog" to isDialog, "isUserGesture" to isUserGesture)
            return false
        }
    }

    private fun createWebViewClient(): WebViewClientCompat = object : WebViewClientCompat() {

        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
            super.onPageStarted(view, url, favicon)
            emit("pageStarted", "url" to (url ?: ""))
        }

        override fun onPageCommitVisible(view: WebView, url: String) {
            super.onPageCommitVisible(view, url)
            emit("pageCommitVisible", "url" to url)
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            super.onPageFinished(view, url)
            debugLog("Page finished loading: $url")
            emit("pageFinished", "url" to (url ?: ""))
        }

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest
        ): Boolean {
            emit(
                "navigationRequest",
                "url" to request.url?.toString(),
                "isForMainFrame" to request.isForMainFrame,
                "hasGesture" to request.hasGesture(),
                "method" to request.method
            )
            return false
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceErrorCompat
        ) {
            // WebViewClientCompat normalises this callback down to API 21; the plain framework
            // overload is API 23+, so previously nothing was reported at all on 21-22.
            val code = if (WebViewFeature.isFeatureSupported(
                    WebViewFeature.WEB_RESOURCE_ERROR_GET_CODE
                )
            ) {
                runCatching { error.errorCode }.getOrDefault(-1)
            } else {
                -1
            }
            val description = if (WebViewFeature.isFeatureSupported(
                    WebViewFeature.WEB_RESOURCE_ERROR_GET_DESCRIPTION
                )
            ) {
                runCatching { error.description.toString() }.getOrNull() ?: "unknown"
            } else {
                "unknown"
            }

            emit(
                "error",
                "errorCode" to code,
                "description" to description,
                "failingUrl" to request.url?.toString(),
                "isForMainFrame" to request.isForMainFrame,
                // Preserved for consumers that read this key today.
                "message" to description
            )

            if (request.isForMainFrame) maybeNavigateToFallback(request.url?.toString())
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse
        ) {
            emit(
                "httpError",
                "statusCode" to errorResponse.statusCode,
                "reasonPhrase" to errorResponse.reasonPhrase,
                "url" to request.url?.toString(),
                "isForMainFrame" to request.isForMainFrame,
                "mimeType" to errorResponse.mimeType
            )
        }

        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: SslError?
        ) {
            emit(
                "sslError",
                "primaryError" to (error?.primaryError ?: -1),
                "url" to error?.url,
                "action" to "cancelled"
            )
            // Never expose proceed(): that would be a remote-code-execution hole in a WebView
            // running third-party JavaScript.
            handler?.cancel()
        }

        override fun onRenderProcessGone(
            view: WebView?,
            detail: RenderProcessGoneDetail?
        ): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            emit(
                "renderProcessGone",
                "didCrash" to (detail?.didCrash() ?: false),
                "url" to view?.url
            )
            // Returning false would kill the whole app process.
            webView = null
            configuredJavaScriptChannels.clear()
            isWebViewPaused = false
            return true
        }
    }

    private fun maybeNavigateToFallback(fromUrl: String?) {
        val target = errorFallbackUrl ?: if (isFromChart) defaultURLString else null
        if (target == null) return
        emit("errorFallbackNavigation", "fromUrl" to fromUrl, "toUrl" to target)
        webView?.loadUrl(target)
    }

    // ------------------------------------------------------------- loading

    /**
     * Creates the WebView, registers channels and optionally starts a load — all before any
     * platform view is mounted, so Chromium start-up and the page's JavaScript parse happen off
     * the chart-open critical path.
     *
     * The error fallback is forced off: a transient failure at app boot must not silently
     * replace the pre-warmed page.
     */
    fun prewarm(
        url: String?,
        channels: List<String>?,
        cacheMode: String?,
        offscreenPreRaster: Boolean?,
        width: Int?,
        height: Int?,
        requestedLoadId: Long?
    ): Map<String, Any?> {
        val hadWebView = webView != null
        val view = getOrCreateWebView()

        channels?.forEach { addJavascriptChannel(it) }
        cacheMode?.let { applyCacheMode(it) }

        var preRasterApplied = false
        if (offscreenPreRaster == true &&
            WebViewFeature.isFeatureSupported(WebViewFeature.OFF_SCREEN_PRERASTER)
        ) {
            runCatching {
                androidx.webkit.WebSettingsCompat.setOffscreenPreRaster(view.settings, true)
                preRasterApplied = true
            }
        }

        // A detached WebView has a 0x0 viewport, so window.innerWidth is 0 and any layout-driven
        // page renders degenerately. Measuring and laying out gives it a real viewport.
        var laidOut = false
        if (width != null && height != null && width > 0 && height > 0) {
            runCatching {
                view.measure(
                    View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
                )
                view.layout(0, 0, width, height)
                laidOut = true
            }
        }

        if (!url.isNullOrEmpty()) {
            loadId = requestedLoadId ?: (loadId + 1)
            errorFallbackUrl = null
            isFromChart = false
            emit(
                "loadRequested",
                "url" to url,
                "cacheMode" to cacheModeName(view.settings.cacheMode),
                "channels" to (channels ?: emptyList<String>()),
                "createdWebView" to !hadWebView,
                "errorFallbackUrl" to null,
                "viaPrewarm" to true
            )
            view.loadUrl(url)
        }

        val pkg = runCatching { WebViewCompat.getCurrentWebViewPackage(context) }.getOrNull()
        return mapOf(
            "created" to !hadWebView,
            "channelsRegistered" to configuredJavaScriptChannels.toList(),
            "webViewPackage" to pkg?.packageName,
            "webViewVersion" to pkg?.versionName,
            "offscreenPreRasterApplied" to preRasterApplied,
            "laidOut" to laidOut,
            "ts" to System.currentTimeMillis(),
            "tsMono" to SystemClock.elapsedRealtime()
        )
    }

    fun loadURL(
        urlString: String,
        javaScriptChannelName: String?,
        isChart: Boolean,
        channels: List<String>? = null,
        cacheMode: String? = null,
        backgroundColor: String? = null,
        fallbackUrl: String? = null,
        fallbackUrlProvided: Boolean = false,
        requestedLoadId: Long? = null
    ) {
        isFromChart = isChart
        // An explicitly provided key wins, including an explicit null which disables the
        // fallback. Absent the key, isChart keeps its legacy meaning.
        errorFallbackUrl = if (fallbackUrlProvided) fallbackUrl else null

        // Create on demand rather than silently no-opping when no platform view has mounted yet.
        val view = getOrCreateWebView()

        loadId = requestedLoadId ?: (loadId + 1)

        backgroundColor?.let { applyBackgroundColor(it) }
        cacheMode?.let { applyCacheMode(it) }

        // Register before loadUrl: addJavascriptInterface only takes effect on the next
        // navigation, so this is the only ordering that beats the page's DOMContentLoaded.
        javaScriptChannelName?.let { addJavascriptChannel(it) }
        channels?.forEach { addJavascriptChannel(it) }

        debugLog("loadURL : $urlString")
        emit(
            "loadRequested",
            "url" to urlString,
            "cacheMode" to cacheModeName(view.settings.cacheMode),
            "channels" to configuredJavaScriptChannels.toList(),
            "createdWebView" to false,
            "errorFallbackUrl" to (errorFallbackUrl ?: if (isChart) defaultURLString else null),
            "viaPrewarm" to false
        )

        if (urlString.isNotEmpty()) {
            view.loadUrl(urlString)
        } else {
            loadDefaultURL()
        }
        resumeWebView()
    }

    fun evaluateJavaScript(script: String, completionHandler: (Any?, Throwable?) -> Unit) {
        val view = webView
        if (view == null) {
            completionHandler(null, IllegalStateException("WebView does not exist"))
            return
        }
        view.evaluateJavascript(script) { result -> completionHandler(result, null) }
    }

    private fun loadDefaultURL() {
        webView?.loadUrl(defaultURLString)
    }

    // ------------------------------------------------------------ channels

    fun addJavascriptChannel(name: String): Boolean {
        // Resolve the WebView *before* touching the set. Recording the name without a successful
        // registration used to poison it permanently, because the contains() early-return then
        // blocked every valid retry.
        val view = webView
        if (view == null) {
            pendingJavaScriptChannels.add(name)
            Log.w(TAG, "addJavascriptChannel($name) deferred: no WebView yet")
            return false
        }
        if (!configuredJavaScriptChannels.add(name)) return false
        debugLog("addJavascriptChannel === $name")
        view.addJavascriptInterface(
            object : Any() {
                @JavascriptInterface
                fun postMessage(message: String) {
                    // Runs on a JavaBridge thread. Stamp here, not after marshalling.
                    emit(
                        "javascriptChannelMessageReceived",
                        "channelName" to name,
                        "message" to message
                    )
                }
            },
            name
        )
        return true
    }

    fun removeJavascriptChannel(name: String): Boolean {
        pendingJavaScriptChannels.remove(name)
        val view = webView ?: return false
        if (!configuredJavaScriptChannels.remove(name)) return false
        view.removeJavascriptInterface(name)
        return true
    }

    // --------------------------------------------------------------- cache

    fun applyCacheMode(mode: String): Map<String, Any?> {
        val view = webView
        val previous = cacheModeName(view?.settings?.cacheMode)
        val resolved = when (mode) {
            "default" -> WebSettings.LOAD_DEFAULT
            "cacheElseNetwork" -> WebSettings.LOAD_CACHE_ELSE_NETWORK
            "noCache" -> WebSettings.LOAD_NO_CACHE
            "cacheOnly" -> WebSettings.LOAD_CACHE_ONLY
            else -> WebSettings.LOAD_DEFAULT
        }
        view?.settings?.cacheMode = resolved
        return mapOf("previous" to previous, "current" to cacheModeName(resolved))
    }

    private fun cacheModeName(mode: Int?): String = when (mode) {
        WebSettings.LOAD_DEFAULT -> "default"
        WebSettings.LOAD_CACHE_ELSE_NETWORK -> "cacheElseNetwork"
        WebSettings.LOAD_NO_CACHE -> "noCache"
        WebSettings.LOAD_CACHE_ONLY -> "cacheOnly"
        else -> "unknown"
    }

    /** Unchanged legacy behaviour: HTTP cache only, never DOM storage. */
    fun resetWebViewCache() {
        webView?.clearCache(true)
    }

    /**
     * Clears the selected browsing data. [onDone] fires after cookie removal has actually
     * completed — resolving early would let the next benchmark run start mid-clear.
     *
     * Cookie and DOM-storage removal are **profile-global**: they affect every WebView in the
     * host app, so this is a debug/benchmark facility.
     */
    fun clearBrowsingData(
        httpCache: Boolean,
        domStorage: Boolean,
        cookies: Boolean,
        history: Boolean,
        onDone: (List<String>) -> Unit
    ) {
        val cleared = mutableListOf<String>()
        if (httpCache) {
            webView?.clearCache(true)
            cleared.add("httpCache")
        }
        if (domStorage) {
            WebStorage.getInstance().deleteAllData()
            cleared.add("domStorage")
        }
        if (history) {
            webView?.clearHistory()
            cleared.add("history")
        }
        if (cookies) {
            if (!debuggable) {
                onDone(cleared)
                return
            }
            CookieManager.getInstance().removeAllCookies {
                CookieManager.getInstance().flush()
                cleared.add("cookies")
                onDone(cleared)
            }
        } else {
            onDone(cleared)
        }
    }

    // ------------------------------------------------------------ lifecycle

    fun setIsFromChart(value: Boolean) {
        isFromChart = value
    }

    fun applyBackgroundColor(hex: String) {
        runCatching {
            val normalized = if (hex.startsWith("#")) hex else "#$hex"
            webView?.setBackgroundColor(Color.parseColor(normalized))
        }
    }

    fun setUserInteractionEnabled(enabled: Boolean) {
        userInteractionEnabled = enabled
    }

    fun setConsoleForwarding(enabled: Boolean, minLevel: String?) {
        consoleForwarding = enabled
        consoleMinLevel = when (minLevel) {
            "TIP" -> 0
            "LOG" -> 1
            "DEBUG" -> 2
            "WARNING" -> 3
            "ERROR" -> 4
            else -> 0
        }
    }

    fun setProgressForwarding(enabled: Boolean) {
        progressForwarding = enabled
    }

    private fun levelRank(level: ConsoleMessage.MessageLevel?): Int = when (level) {
        ConsoleMessage.MessageLevel.TIP -> 0
        ConsoleMessage.MessageLevel.LOG -> 1
        ConsoleMessage.MessageLevel.DEBUG -> 2
        ConsoleMessage.MessageLevel.WARNING -> 3
        ConsoleMessage.MessageLevel.ERROR -> 4
        else -> 0
    }

    fun postVisualStateCallback(requestId: Long): Boolean {
        val view = webView ?: return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.VISUAL_STATE_CALLBACK)) return false
        return runCatching {
            WebViewCompat.postVisualStateCallback(view, requestId) { id ->
                emit("visualStateReady", "requestId" to id, "url" to view.url)
            }
            true
        }.getOrDefault(false)
    }

    fun detachWebView() {
        (webView?.parent as? ViewGroup)?.removeView(webView)
        // Deliberately does not pause: keeping timers running preserves touch responsiveness
        // and lets the loaded page survive navigation away from the chart.
    }

    fun destroyWebView() {
        debugLog("destroyWebView")
        isWebViewPaused = true
        webView?.apply {
            onPause()
            pauseTimers()
            destroy()
        }
        webView = null
        configuredJavaScriptChannels.clear()
    }

    fun resumeWebView() {
        if (isWebViewPaused) {
            isWebViewPaused = false
            webView?.onResume()
            webView?.resumeTimers()
        }
    }

    fun setWebContentsDebuggingEnabled(enabled: Boolean): Map<String, Any?> {
        if (enabled && !debuggable) {
            return mapOf("applied" to false, "reason" to "release_build")
        }
        return runCatching {
            WebView.setWebContentsDebuggingEnabled(enabled)
            debuggingConfigured = true
            mapOf<String, Any?>("applied" to true, "reason" to null)
        }.getOrElse { mapOf("applied" to false, "reason" to (it.message ?: "failed")) }
    }

    private fun configureWebContentsDebugging() {
        // Deliberately not done at plugin attach: touching the WebView provider there forces it
        // to load and adds to app start-up, contaminating the very baseline being measured.
        if (debuggingConfigured || !debuggable) return
        runCatching {
            WebView.setWebContentsDebuggingEnabled(true)
            debuggingConfigured = true
        }
    }

    companion object {
        private var INSTANCE: WebViewManager? = null

        @Volatile
        private var debuggingConfigured: Boolean = false

        fun getInstance(context: Context): WebViewManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: WebViewManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }
}
