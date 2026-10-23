import Flutter
import UIKit
import WebKit

class WebViewMoFlutterViewFactory: NSObject, FlutterPlatformViewFactory {
   
    
    private var messenger: FlutterBinaryMessenger
    var delegate: WebViewControllerDelegate?

    init(messenger: FlutterBinaryMessenger, delegate: WebViewControllerDelegate?) {
        self.messenger = messenger
        self.delegate = delegate
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return WebViewMoFlutter(frame: frame, viewIdentifier: viewId, args: args, messenger: messenger, delegate: delegate)
    }
}

class WebViewMoFlutter: NSObject, FlutterPlatformView {
    private var webView: WKWebView
    private var url: URL?
    private var delegate: WebViewControllerDelegate?
    private var isChart: Bool = true

    private let viewId: Int64

    init(frame: CGRect, viewIdentifier: Int64, args: Any?, messenger: FlutterBinaryMessenger, delegate: WebViewControllerDelegate?) {
        self.webView = WebViewManager.shared.getWebView(frame: frame)
        self.delegate = delegate
        self.viewId = viewIdentifier
        super.init()
        // Flutter creates the incoming platform view before releasing the outgoing one, so the
        // WebView may still sit in the old container here; UIKit reparents it when this view is
        // added. Recorded so the host can tell "page alive" from "page alive and on screen".
        let wasReparented = webView.superview != nil
        WebViewManager.shared.attachedViewId = viewIdentifier
        delegate?.onNativeEvent(["event": "viewAttached", "viewId": viewIdentifier, "wasReparented": wasReparented])

         // Initialize isChart from args
        if let argsDict = args as? [String: Any], let isChart = argsDict["isChart"] as? Bool {
            self.isChart = isChart
            self.webView.scrollView.backgroundColor = UIColor.clear
        } else {
            self.isChart = true
        }
        print("Received arg isChart: \(isChart)")

        if let argsDict = args as? [String: Any], let _ = argsDict["initialUrl"] as? String {

            // self.url = URL(string: urlString)
            // loadUrl()
        }
        
        if let argsDict = args as? [String: Any], let backgroundColor = argsDict["backgroundColor"] as? String {
            self.webView.scrollView.backgroundColor = UIColor(named: backgroundColor)
            self.webView.backgroundColor = UIColor(named: backgroundColor)
        }
        
        self.webView.navigationDelegate = self
    }

    func view() -> UIView {
        webView.isOpaque = false
        webView.scrollView.bounces = false
        return webView
    }

    deinit {
        // Only the newest host may clear the record: a newer view is created before this one is
        // released, and its id must survive.
        let owned = WebViewManager.shared.attachedViewId == viewId
        if owned {
            WebViewManager.shared.attachedViewId = -1
        }
        delegate?.onNativeEvent(["event": "viewDetached", "viewId": viewId, "owned": owned])
    }
}

extension WebViewMoFlutter: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("Received pageDidLoad2 isChart: \(isChart)")
       if isChart {
            delegate?.pageDidLoad(url: webView.url?.absoluteString ?? "")
        } else {
            delegate?.onPageFinished(url: webView.url?.absoluteString ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // handleLoadingError()
        delegate?.onPageLoadError()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // handleLoadingError()
        delegate?.onPageLoadError()
    }

    /// This view replaces `WebViewManager` as the navigation delegate while it is mounted, so the
    /// termination callback has to be handled here too; `WebViewManager`'s copy only covers the
    /// time between platform views. iOS reclaims the web content process of a backgrounded app
    /// routinely and the WKWebView then renders blank with nothing reported, so the host kept
    /// believing the chart was loaded. Reported under the name Android uses for the equivalent
    /// failure so the host handles both with one path.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        delegate?.onNativeEvent(["event": "renderProcessGone", "didCrash": false])
    }
}
