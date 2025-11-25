package com.example.ios_webview_plugin

import android.app.AlertDialog
import android.content.Context
import android.os.Message
import android.util.Log
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import android.graphics.Color
import android.view.View
import android.widget.FrameLayout
import android.view.MotionEvent

class WebViewMoFlutterViewFactory(
    private val messenger: BinaryMessenger,
    private val delegate: WebViewControllerDelegate?,
    private val webViewManager: WebViewManager
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return WebViewMoFlutter(context, viewId, args, messenger, delegate, webViewManager)
    }
}

class WebViewMoFlutter(
    context: Context,
    viewId: Int,
    args: Any?,
    messenger: BinaryMessenger,
    private val delegate: WebViewControllerDelegate?,
    private val webViewManager: WebViewManager
) : PlatformView {

    private val container = FrameLayout(context)
    private val webView = webViewManager.getOrCreateWebView()

    init {
        attachWebViewToContainer()
    }

    private fun attachWebViewToContainer() {
        try {
            val parent = webView.parent
            Log.d("WebViewMoFlutterPlugin", "Attaching WebView - current parent: $parent, target: $container")
            
            if (parent is ViewGroup && parent != container) {
                Log.d("WebViewMoFlutterPlugin", "Removing WebView from previous parent")
                parent.removeView(webView)
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
                Log.d("WebViewMoFlutterPlugin", "WebView added to container")
            }

            // Only resume if actually paused
            if (webViewManager.isWebViewPaused) {
                Log.d("WebViewMoFlutterPlugin", "Resuming paused WebView")
                webViewManager.resumeWebView()
            }

            Log.d("WebViewMoFlutterPlugin", "WebView attached successfully")
        } catch (e: Exception) {
            Log.e("WebViewMoFlutterPlugin", "Error attaching WebView: ${e.message}")
        }
    }

    override fun getView(): View {
        attachWebViewToContainer()
        return container
    }


    override fun dispose() {
        Log.d("WebViewMoFlutterPlugin", "dispose - detaching WebView")

        container.removeAllViews()

        // This now ONLY detaches view, not pause/destroy timers
        webViewManager.detachWebView()

        Log.d(
            "WebViewMoFlutterPlugin",
            "After dispose: isAttached=${webView.parent != null}"
        )
    }
}

class WebViewManager private constructor(private val context: Context) {

    var delegate: WebViewControllerDelegate? = null
    var webView: WebView? = null
        private set
    private val configuredJavaScriptChannels: MutableSet<String> = mutableSetOf()
    private val defaultURLString = "https://tradingview.com/"
    private var isWebViewPaused: Boolean = false
    private var isFromChart: Boolean = true

    fun getOrCreateWebView(): WebView {
        if (webView == null) {
            Log.d("WebViewMoFlutterPlugin", "Creating new WebView instance")
            configuredJavaScriptChannels.clear()
            webView = WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                settings.javaScriptCanOpenWindowsAutomatically = true
                
                // Add touch event settings
                settings.setSupportZoom(true)
                settings.builtInZoomControls = false
                settings.displayZoomControls = false
                settings.useWideViewPort = true
                settings.loadWithOverviewMode = true
                settings.allowFileAccess = true
                settings.allowContentAccess = true
                settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                Log.d("WebViewMoFlutterPlugin", "WebView background set to transparent")
                
                // Enable touch events with logging
                setOnTouchListener { _, event ->
                    Log.d("WebViewMoFlutterPlugin", "Touch event detected: ${event.action}, isPaused: $isWebViewPaused")
                    when (event.action) {
                        MotionEvent.ACTION_DOWN -> {
                            Log.d("WebViewMoFlutterPlugin", "Touch DOWN at (${event.x}, ${event.y})")
                            if (isWebViewPaused) {
                                Log.d("WebViewMoFlutterPlugin", "Resuming WebView due to touch")
                                resumeWebView()
                            }
                            false
                        }
                        MotionEvent.ACTION_MOVE -> {
                            Log.d("WebViewMoFlutterPlugin", "Touch MOVE at (${event.x}, ${event.y})")
                            false
                        }
                        MotionEvent.ACTION_UP -> {
                            Log.d("WebViewMoFlutterPlugin", "Touch UP at (${event.x}, ${event.y})")
                            false
                        }
                        else -> false
                    }
                }

                webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                        Log.d("WebViewMoFlutterPlugin", "WebViewConsole: ${consoleMessage.message()} at ${consoleMessage.sourceId()}:${consoleMessage.lineNumber()}")
                        return true
                    }

                    override fun onJsAlert(view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                        delegate?.onJsAlert(url, message)
                        return true
                    }

                    override fun onPermissionRequest(request: PermissionRequest?) {
                        super.onPermissionRequest(request)
                        request?.grant(request.resources)
                    }

                    override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message?): Boolean {
                        val newWebView = WebView(context)
                        val webSettings = newWebView.settings
                        webSettings.javaScriptEnabled = true
                        webSettings.javaScriptCanOpenWindowsAutomatically = true

                        val dialog = AlertDialog.Builder(context)
                        dialog.setView(newWebView)
                            .setPositiveButton("Close") { dialogInterface, i ->
                                (newWebView.parent as ViewGroup).removeView(newWebView)
                                dialogInterface.dismiss()
                            }
                            .show()

                        val transport = resultMsg!!.obj as WebView.WebViewTransport
                        transport.webView = newWebView
                        resultMsg.sendToTarget()
                        return true
                    }
                }
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        super.onPageFinished(view, url)
                        Log.d("WebViewMoFlutterPlugin", "Page finished loading: $url")
                        delegate?.onPageFinished(url ?: "")
                    }

                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                        return false
                    }

                    override fun onReceivedError(
                        view: WebView?,
                        request: WebResourceRequest?,
                        error: WebResourceError?
                    ) {
                        super.onReceivedError(view, request, error)
                        delegate?.onReceivedError("error")
                        if (isFromChart) {
                            loadDefaultURL()
                        }
                    }
                }
            }
        } else {
            Log.d("WebViewMoFlutterPlugin", "Reusing existing WebView instance")
            resumeWebView()
        }
        return webView!!
    }

    fun loadURL(urlString: String, javaScriptChannelName: String?, isChart: Boolean) {
        isFromChart = isChart
        Log.d("WebViewMoFlutterPlugin", "loadURL : $urlString")
        if (urlString.isNotEmpty()) {
            if (javaScriptChannelName != null) {
                addJavascriptChannel(javaScriptChannelName)
            }
            webView?.loadUrl(urlString)
        } else {
            loadDefaultURL()
        }
        resumeWebView()
    }

    fun evaluateJavaScript(script: String, completionHandler: (Any?, Throwable?) -> Unit) {
        Log.d("WebViewMoFlutterPlugin", "evaluateJavaScript : $script ")
        webView?.evaluateJavascript(script) { result ->
            completionHandler(result, null)
        }
    }

    fun resetWebViewCache() {
        webView?.clearCache(true)
    }

    fun addJavascriptChannel(name: String): Boolean {
        if (configuredJavaScriptChannels.contains(name)) return false
        Log.d("WebViewMoFlutterPlugin", "addJavascriptChannel === $name")
        webView?.addJavascriptInterface(object : Any() {
            @JavascriptInterface
            fun postMessage(message: String) {
                Log.d("WebViewMoFlutterPlugin", "JavaScript message received on channel $name: $message")
                delegate?.onJavascriptChannelMessageReceived(name, message)
            }
        }, name)
        configuredJavaScriptChannels.add(name)
        return true
    }

    private fun loadDefaultURL() {
        webView?.loadUrl(defaultURLString)
    }

    fun detachWebView() {
        Log.d("WebViewMoFlutterPlugin", "detachWebView - removing from parent only")
        // Remove from parent if attached
        (webView?.parent as? ViewGroup)?.removeView(webView)
        // DON'T pause WebView to keep touch events active
        Log.d("WebViewMoFlutterPlugin", "WebView detached but kept active for touch events")
    }

    fun destroyWebView() {
        Log.d("WebViewMoFlutterPlugin", "destroyWebView - fully destroying WebView")
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
        Log.d("WebViewMoFlutterPlugin", "resumeWebView - isPaused: $isWebViewPaused")
        if (isWebViewPaused) {
            isWebViewPaused = false
            webView?.onResume()
            webView?.resumeTimers()
            Log.d("WebViewMoFlutterPlugin", "WebView resumed")
        } else {
            Log.d("WebViewMoFlutterPlugin", "WebView already active")
        }
    }

    companion object {
        private var INSTANCE: WebViewManager? = null

        fun getInstance(context: Context): WebViewManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: WebViewManager(context.applicationContext).also {
                    INSTANCE = it
                    Log.d("WebViewMoFlutterPlugin", "Created new WebViewManager singleton instance")
                }
            }
        }
    }
}

interface WebViewControllerDelegate {
    fun pageDidLoad()
    fun onMessageReceived(message: String)
    fun onJavascriptChannelMessageReceived(channelName: String, message: String)
    fun onNavigationRequest(url: String)
    fun onPageFinished(url: String)
    fun onReceivedError(message: String)
    fun onJsAlert(url: String?, message: String?)
}
