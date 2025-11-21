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
            WebViewManager.shared.webView?.reload()
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

        default:
            result(FlutterMethodNotImplemented)
        }
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
        eventSink?( ["event": "pageFinished", "url": url] )
    }

    func onPageLoadError() {
        eventSink?( ["event": "error", "message": "error"] )
    }

    func onJavascriptChannelMessageReceived(channelName: String, message: String) {
        eventSink?( ["event": "javascriptChannelMessageReceived", "channelName": channelName, "message": message] )
    }

    func onNavigationRequest(url: String) {
    }
    func onPageFinished(url: String) {
        eventSink?( ["event": "pageFinished", "url": url] )
    }
    func onReceivedError(message: String) {}
    func onJsAlert(url: String, message: String) {}
}

extension WebViewMoFlutterPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        WebViewManager.shared.delegate = self
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        WebViewManager.shared.delegate = nil
        return nil
    }
}

// MARK: - WKWebView Manager
class WebViewManager: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WebViewManager()
    private(set) var webView: WKWebView?
    weak var delegate: WebViewControllerDelegate?
    private var configuredJavaScriptChannels: Set<String> = []
    private let defaultURLString = "https://tradingview.com/"
    private var isChart = true
    
    private override init() {
        super.init()
    }
    
    func getOrCreateWebView() -> WKWebView {
        if webView == nil {
            print("[WEBVIEW_PLUGIN] WebViewManager.resume - Creating new WebView instance")
            configuredJavaScriptChannels.removeAll()
            
            let configuration = WKWebViewConfiguration()
            configuration.preferences.javaScriptEnabled = true
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
            
            webView = WKWebView(frame: .zero, configuration: configuration)
            webView!.navigationDelegate = self
            webView!.isOpaque = false
            webView!.scrollView.bounces = false
            addJavascriptChannel(name: "ChartAppDelegate")
        } else {
            print("[WEBVIEW_PLUGIN] WebViewManager.resume - Reusing existing WebView instance")
        }
        return webView!
    }
    
    func getWebView(frame: CGRect) -> WKWebView {
        let view = getOrCreateWebView()
        view.frame = frame
        return view
    }
    
    // MARK: - ATTACH / DETACH
    
    func attach(to parent: UIView, frame: CGRect) {
        print("[WEBVIEW_PLUGIN] WebViewManager.attach - Attaching WebView to parent, frame=\(frame)")
        let view = getOrCreateWebView()
        
        // If WKWebView is already attached somewhere else, detach first
        if view.superview != nil {
            print("[WEBVIEW_PLUGIN] WebViewManager.attach - Removing from previous parent")
            view.removeFromSuperview()
        }

        // Set frame and use autoresizing mask for flexible sizing
        if frame.width > 0 && frame.height > 0 {
            view.frame = frame
        } else {
            // If frame is zero, use parent's bounds
            view.frame = parent.bounds
        }
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        parent.addSubview(view)
        print("[WEBVIEW_PLUGIN] WebViewManager.attach - WebView attached, frame=\(view.frame)")
    }

    func detach() {
        print("[WEBVIEW_PLUGIN] WebViewManager.detach - Detaching WebView from parent")
        guard let view = webView else { return }
        // Remove from parent if attached
        if view.superview != nil {
            view.removeFromSuperview()
        }
    }
    
    func destroyWebView() {
        print("[WEBVIEW_PLUGIN] WebViewManager.destroy - Destroying WebView instance")
        guard let view = webView else { return }
        view.stopLoading()
        view.removeFromSuperview()
        view.configuration.userContentController.removeAllUserScripts()
        webView = nil
        configuredJavaScriptChannels.removeAll()
    }
    
    // MARK: - URL Loading
    
    func loadURL(_ urlString: String, _ isFromChart: Bool, withJavaScriptChannel javaScriptChannelName: String?, plugin: WKScriptMessageHandler, backgroundColor: String) {
        isChart = isFromChart
        let view = getOrCreateWebView()
        
        StatusBarAppearanceUtility.updateStatusBar(for: backgroundColor)
        if let uiColor = UIColor(hex: backgroundColor) {
            view.scrollView.backgroundColor = uiColor
            view.backgroundColor = uiColor
        }
        
        guard let url = URL(string: urlString), isValidURL(url) else {
            delegate?.onPageLoadError()
            loadDefaultURL()
            return
        }
        
        if let name = javaScriptChannelName {
            addJavascriptChannel(name: name)
        }
        
        if view.url != url {
            view.load(URLRequest(url: url))
        }
    }
    
    func evaluateJavaScript(_ script: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        guard let view = webView else {
            completionHandler(nil, NSError(domain: "WebViewManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView not initialized"]))
            return
        }
        view.evaluateJavaScript(script, completionHandler: completionHandler)
    }
    
    func resetWebViewCache() {
        let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        WKWebsiteDataStore.default().removeData(ofTypes: websiteDataTypes, modifiedSince: date, completionHandler: {})
    }
    
    func addJavascriptChannel(name: String) -> Bool {
        if configuredJavaScriptChannels.contains(name) {
            return false
        }
        guard let view = webView else {
            return false
        }
        let source = "window.\(name) = webkit.messageHandlers.\(name);"
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        view.configuration.userContentController.addUserScript(script)
        view.configuration.userContentController.add(self, name: name)
        configuredJavaScriptChannels.insert(name)
        return true
    }
    
    private func loadDefaultURL() {
        guard let view = webView, let defaultURL = URL(string: defaultURLString) else { return }
        view.load(URLRequest(url: defaultURL))
    }
    
    private func isValidURL(_ url: URL) -> Bool {
        return url.scheme?.starts(with: "http") ?? false
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
}


// MARK: - Status Bar Utility
class StatusBarAppearanceUtility {
    static func updateStatusBar(for backgroundColorHex: String) {
        guard let uiColor = UIColor(hex: backgroundColorHex) else { return }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.backgroundColor = uiColor
        }

        let isLightBackground = uiColor.isLight
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let viewController = windowScene.windows.first?.rootViewController {
            viewController.overrideUserInterfaceStyle = isLightBackground ? .light : .dark
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
