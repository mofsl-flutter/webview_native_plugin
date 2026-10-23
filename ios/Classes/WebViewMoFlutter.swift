import Flutter
import UIKit
import WebKit

// MARK: - Plugin Implementation
public class WebViewMoFlutterPlugin: NSObject, FlutterPlugin, WKScriptMessageHandler, WebViewControllerDelegate {
    private var webView: WKWebView?
    private var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "webview_mo_flutter", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "webview_plugin_events", binaryMessenger: registrar.messenger())
        let instance = WebViewMoFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)

        let factory = WebViewMoFlutterViewFactory(messenger: registrar.messenger(), delegate: instance)
        registrar.register(factory, withId: "web_view_mo_flutter")
    }

    private var eventSink: FlutterEventSink?

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loadUrl":
            if let args = call.arguments as? [String: Any],
               let urlString = args["initialUrl"] as? String {
                let javaScriptChannelName = args["javaScriptChannelName"] as? String
                let isChart = args["isChart"] as? Bool ?? true
                let backgroundColor = args["backgroundColor"] as? String ?? "#FFFFFF"
                print("Received isChart: \(isChart)")
                // The engine that navigates owns the events (mirrors the Android plugin).
                claimDelegate(reason: "loadUrl")
                // The host's "navigation was dispatched" acknowledgement, which arrives within
                // milliseconds when the event path is healthy. Its absence is how the host tells
                // a dead event path from a slow page.
                onNativeEvent(["event": "loadRequested", "url": urlString, "channels": ["ChartAppDelegate"], "createdWebView": false, "viaPrewarm": false])
                WebViewManager.shared.loadURL(urlString, isChart, withJavaScriptChannel: javaScriptChannelName, plugin: self, backgroundColor: backgroundColor)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "URL is required", details: nil))
            }

        case "runJavaScript":
            if let script = (call.arguments as? [String: Any])?["script"] as? String {
                WebViewManager.shared.evaluateJavaScript(script) { (response, error) in
                    if let error = error {
                        result(FlutterError(code: "JAVASCRIPT_ERROR", message: error.localizedDescription, details: nil))
                    } else {
                        result(response)
                    }
                }
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "JavaScript code is required", details: nil))
            }

        case "reloadUrl":
            claimDelegate(reason: "reloadUrl")
            WebViewManager.shared.webView?.reload()
            result(nil)

        case "probe":
            guard let args = call.arguments as? [String: Any], let script = args["script"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "script is required", details: nil))
                return
            }
            let timeoutMs = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 1_500
            // The answer is this call's return value, not an event, so it still arrives when the
            // event path is the thing that is broken; `ownsDelegate` reports whether it is.
            WebViewManager.shared.probe(script: script, timeout: timeoutMs / 1000) { [weak self] facts in
                var out = facts
                out["ownsDelegate"] = self != nil && WebViewManager.shared.delegate === self
                result(out)
            }

        case "claimDelegate":
            let reason = (call.arguments as? [String: Any])?["reason"] as? String ?? "explicit"
            let changed = claimDelegate(reason: reason)
            result(["changed": changed, "owner": ObjectIdentifier(self).hashValue])

        case "debugReleaseDelegate":
            #if DEBUG
            if WebViewManager.shared.delegate === self { WebViewManager.shared.delegate = nil }
            result(nil)
            #else
            result(FlutterError(code: "RELEASE_BUILD", message: "debugReleaseDelegate is debug-only", details: nil))
            #endif

        case "destroyWebView":
            // Rebuilds the WKWebView. The host must remount its platform view afterwards: the old
            // view keeps the old (now discarded) WKWebView.
            claimDelegate(reason: "destroyWebView")
            WebViewManager.shared.destroyWebView()
            result(nil)

        case "resetCache":
            WebViewManager.shared.resetWebViewCache()
            result(nil)

        case "addJavascriptChannel":
            if let args = call.arguments as? [String: Any], let channelName = args["channelName"] as? String {
                WebViewManager.shared.addJavascriptChannel(name: channelName)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Channel name is required", details: nil))
            }

        case "getCurrentUrl":
            result(WebViewManager.shared.webView?.url?.absoluteString)

        case "warmWebCache":
            guard let args = call.arguments as? [String: Any],
                  let baseUrl = args["baseUrl"] as? String, !baseUrl.isEmpty,
                  let html = args["html"] as? String,
                  let script = args["script"] as? String,
                  let navigateUrl = args["navigateUrl"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGUMENT",
                                    message: "baseUrl, html, script and navigateUrl are required",
                                    details: nil))
                return
            }
            let timeoutMs = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 180_000
            CacheWarmer.start(
                CacheWarmer.Args(
                    mode: args["mode"] as? String ?? "baseUrl",
                    baseUrl: baseUrl,
                    html: html,
                    script: script,
                    navigateUrl: navigateUrl,
                    timeout: timeoutMs / 1000),
                owner: self
            ) { report in result(report) }

        case "stopWarmWebCache":
            CacheWarmer.stop()
            result(nil)

        case "getWebCacheStats":
            WebCacheStats.collect { stats in result(stats) }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        // A warm-up belongs to the engine that asked for it; nobody else can use its result.
        CacheWarmer.cancel(owner: self)
    }

    @objc public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("Received message: \(message.name) with body: \(message.body)")
        if let messageBody = message.body as? String {
            eventSink?(messageBody)
        }
    }

    func sendMessageBody(body: String) {
        eventSink?(body)
    }

    func pageDidLoad(url: String) {
        eventSink?(["event": "pageFinished", "url": url])
    }

    func onPageLoadError() {
        eventSink?(["event": "error", "message": "error"])
    }

    func onJavascriptChannelMessageReceived(channelName: String, message: String) {
        eventSink?(["event": "javascriptChannelMessageReceived", "channelName": channelName, "message": message])
    }

    /// Routes the manager's events to this plugin instance. Returns whether ownership moved, and
    /// reports the move as `delegateClaimed` (to this instance, which is now the owner), matching
    /// the Android plugin so a host reads one vocabulary on both platforms.
    @discardableResult
    private func claimDelegate(reason: String) -> Bool {
        if WebViewManager.shared.delegate === self { return false }
        WebViewManager.shared.delegate = self
        onNativeEvent(["event": "delegateClaimed",
                       "owner": ObjectIdentifier(self).hashValue,
                       "reason": reason])
        return true
    }

    func onNativeEvent(_ event: [String: Any]) {
        var stamped = event
        stamped["ts"] = Int64(Date().timeIntervalSince1970 * 1000)
        eventSink?(stamped)
    }

    func onNavigationRequest(url: String) {}
    func onPageFinished(url: String) {
        eventSink?(["event": "pageFinished", "url": url])
    }
    func onReceivedError(message: String) {}
    func onJsAlert(url: String, message: String) {}
}

extension WebViewMoFlutterPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        claimDelegate(reason: "listen")
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        // Only the owner gives the delegate up; another engine cancelling must not silence the
        // engine that is driving the WebView (mirrors the Android plugin).
        if WebViewManager.shared.delegate === self {
            WebViewManager.shared.delegate = nil
        }
        return nil
    }
}

// MARK: - WKWebView Manager
class WebViewManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WebViewManager()
    var webView: WKWebView!
    weak var delegate: WebViewControllerDelegate?
    private var configuredJavaScriptChannels: Set<String> = []
    private let defaultURLString = "https://tradingview.com/"
    private var isChart = true

    /// Platform view whose container currently hosts the WebView, or -1 when none does.
    var attachedViewId: Int64 = -1

    override init() {
        super.init()
        buildWebView()
    }

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.bounces = false
        addJavascriptChannel(name: "ChartAppDelegate")
    }

    /// Discards the WKWebView and builds a fresh one, for a host that has decided the current one
    /// is beyond recovery. Channels are re-registered on the new instance.
    func destroyWebView() {
        let old = webView
        old?.navigationDelegate = nil
        old?.stopLoading()
        old?.removeFromSuperview()
        // The content controller retains its message handlers, which would keep this manager and
        // the dead view alive.
        for name in configuredJavaScriptChannels {
            old?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        configuredJavaScriptChannels.removeAll()
        attachedViewId = -1
        buildWebView()
    }

    func getWebView(frame: CGRect) -> WKWebView {
        webView.frame = frame
        return webView
    }

    /// What only the native side can say: whether a platform view is actually hosting the WebView.
    func probeFacts() -> [String: Any] {
        var facts: [String: Any] = [
            "hasWebView": webView != nil,
            "attached": webView?.superview != nil && webView?.window != nil,
            "attachedViewId": attachedViewId,
            "isPaused": false,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        // Explicit NSNull: an Optional inside `Any` is not reliably encodable by the platform codec.
        if let url = webView?.url?.absoluteString {
            facts["url"] = url
        } else {
            facts["url"] = NSNull()
        }
        return facts
    }

    /// Runs `script` and returns its value with `probeFacts`. Completes exactly once; a content
    /// process that never answers surfaces as `timedOut` instead of leaving the caller waiting.
    func probe(script: String, timeout: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        var finished = false
        let finish: ([String: Any]) -> Void = { extras in
            if finished { return }
            finished = true
            completion(self.probeFacts().merging(extras) { _, new in new })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(["js": NSNull(), "timedOut": true])
        }
        webView.evaluateJavaScript(script) { response, error in
            if let error = error {
                finish(["js": NSNull(), "error": error.localizedDescription])
            } else {
                finish(["js": response ?? NSNull()])
            }
        }
    }

    func loadURL(_ urlString: String, _ isFromChart: Bool, withJavaScriptChannel javaScriptChannelName: String?, plugin: WKScriptMessageHandler, backgroundColor: String) {
        isChart = isFromChart
        StatusBarAppearanceUtility.updateStatusBar(for: backgroundColor)
        if let uiColor = UIColor(hex: backgroundColor) {
            webView.scrollView.backgroundColor = uiColor
            webView.backgroundColor = uiColor
        }

        guard let url = URL(string: urlString), isValidURL(url) else {
            delegate?.onPageLoadError()
            loadDefaultURL()
            return
        }

        if let name = javaScriptChannelName {
            addJavascriptChannel(name: name)
        }

        if webView.url != url {
            print("Loading URL: \(urlString)")
            webView.load(URLRequest(url: url))
        }
    }

    func evaluateJavaScript(_ script: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        webView.evaluateJavaScript(script, completionHandler: completionHandler)
    }

    func resetWebViewCache() {
        let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        WKWebsiteDataStore.default().removeData(ofTypes: websiteDataTypes, modifiedSince: date, completionHandler: {})
    }

    func addJavascriptChannel(name: String) -> Bool {
        if configuredJavaScriptChannels.contains(name) { return false }
        let source = "window.\(name) = webkit.messageHandlers.\(name);"
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(script)
        webView.configuration.userContentController.add(self, name: name)
        configuredJavaScriptChannels.insert(name)
        return true
    }

    private func loadDefaultURL() {
        if let defaultURL = URL(string: defaultURLString) {
            webView.load(URLRequest(url: defaultURL))
        }
    }

    private func isValidURL(_ url: URL) -> Bool {
        return UIApplication.shared.canOpenURL(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isChart {
            delegate?.pageDidLoad(url: webView.url?.absoluteString ?? "")
        } else {
            delegate?.onPageFinished(url: webView.url?.absoluteString ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        delegate?.onPageLoadError()
        loadDefaultURL()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.onPageLoadError()
        loadDefaultURL()
    }

    /// iOS reclaims the web content process of a backgrounded app routinely. The WKWebView object
    /// survives it but renders blank, and nothing is ever reported unless this is implemented, so
    /// the host kept believing the chart was loaded. Reported under the same name Android uses for
    /// the equivalent failure so the host handles both with one path.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.onNativeEvent(["event": "renderProcessGone", "didCrash": false])
    }

    @objc public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let messageBody = message.body as? String {
            delegate?.onJavascriptChannelMessageReceived(channelName: message.name, message: messageBody)
        }
    }
}

protocol WebViewControllerDelegate: AnyObject {
    func pageDidLoad(url: String)
    func sendMessageBody(body: String)
    func onPageLoadError()
    func onJavascriptChannelMessageReceived(channelName: String, message: String)
    func onNavigationRequest(url: String)
    func onPageFinished(url: String)
    func onReceivedError(message: String)
    func onJsAlert(url: String, message: String)
    /// Emits a native event (`event` plus its fields) on the shared event channel, stamped with `ts`.
    func onNativeEvent(_ event: [String: Any])
}


// MARK: - Status Bar Utility
class StatusBarAppearanceUtility {
    // Only tints the window background behind the WebView. This MUST NOT touch
    // overrideUserInterfaceStyle on the app's root view controller: doing so pins
    // FlutterViewController's traitCollection, which permanently stops iOS from
    // delivering userInterfaceStyle changes to the Flutter engine — breaking
    // "follow system theme" for the rest of the process, app-wide, after the
    // first chart open. See: theme stops following the device after opening charts.
    static func updateStatusBar(for backgroundColorHex: String) {
        guard let uiColor = UIColor(hex: backgroundColorHex) else { return }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.backgroundColor = uiColor
        }
    }
}

// MARK: - UIColor Extensions
extension UIColor {
    convenience init?(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.remove(at: hexString.startIndex) }

        guard let rgbValue = UInt64(hexString, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        switch hexString.count {
        case 6: // RGB
            r = CGFloat((rgbValue >> 16) & 0xFF) / 255
            g = CGFloat((rgbValue >> 8) & 0xFF) / 255
            b = CGFloat(rgbValue & 0xFF) / 255
            a = 1.0
        case 8: // ARGB
            a = CGFloat((rgbValue >> 24) & 0xFF) / 255
            r = CGFloat((rgbValue >> 16) & 0xFF) / 255
            g = CGFloat((rgbValue >> 8) & 0xFF) / 255
            b = CGFloat(rgbValue & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var isLight: Bool {
        var white: CGFloat = 0
        getWhite(&white, alpha: nil)
        return white > 0.7
    }
}
