import Foundation
import WebKit

/// Fills WebKit's disk cache with the chart's JavaScript library, from a throwaway web view.
///
/// Separate from `WebViewManager`'s singleton on purpose: that web view is the chart, with a
/// `ChartController` listening to it, and anything loaded into it would race that listener. This
/// one is created, runs one script, reports once and is released.
///
/// The script (`lib/src/cache_warmer_js.dart`) has to run in a web view so the entries it writes
/// are the ones the chart's own requests read. It uses `WKWebsiteDataStore.default()`, the store
/// the chart uses; a non-persistent store would fill a cache that is thrown away.
///
/// Constraints this honours:
/// * One warm-up at a time. A second call is answered `busy` rather than queued.
/// * Everything runs on the main thread, so no locking is needed.
/// * The result is delivered exactly once, whichever of report, timeout, error or cancellation
///   gets there first.
/// * The timeout is wall-clock. The web content and network processes are suspended soon after the
///   app is backgrounded, and a monotonic timer would not advance during that, leaving the warm-up
///   "running" after the user returned.
/// * The script message handler is held weakly: `WKUserContentController` retains its handlers, and
///   a strong one would keep this object alive for as long as the web view.
final class CacheWarmer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    struct Args {
        /// `baseUrl` (load generated HTML under the chart origin) or `navigate`.
        let mode: String
        let baseUrl: String
        let html: String
        let script: String
        let navigateUrl: String
        let timeout: TimeInterval
    }

    private static let bridgeName = "warmBridge"
    private static let modeNavigate = "navigate"

    /// Main thread only.
    private static var current: CacheWarmer?

    private let args: Args
    private weak var owner: AnyObject?
    private var reply: (([String: Any]) -> Void)?
    private var webView: WKWebView?
    private var timeoutItem: DispatchWorkItem?
    private var injected = false

    private init(args: Args, owner: AnyObject, reply: @escaping ([String: Any]) -> Void) {
        self.args = args
        self.owner = owner
        self.reply = reply
        super.init()
    }

    /// Starts a warm-up. Must be called on the main thread. `reply` is called exactly once.
    static func start(
        _ args: Args,
        owner: AnyObject,
        reply: @escaping ([String: Any]) -> Void
    ) {
        if current != nil {
            reply(["ok": false, "reason": "busy"])
            return
        }
        let warmer = CacheWarmer(args: args, owner: owner, reply: reply)
        current = warmer
        warmer.begin()
    }

    /// Asks the running warm-up to start no new fetches; in-flight ones still finish.
    static func stop() {
        current?.webView?.evaluateJavaScript("window.__warmStop=true;", completionHandler: nil)
    }

    /// Abandons a warm-up started by `owner`, so one plugin instance detaching does not cancel
    /// another's work in a multi-engine host.
    static func cancel(owner: AnyObject) {
        guard let warmer = current, warmer.owner === owner else { return }
        warmer.finish(["ok": false, "reason": "detached"])
    }

    private func begin() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.userContentController.add(WeakScriptHandler(self), name: CacheWarmer.bridgeName)

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.navigationDelegate = self
        webView = view

        let item = DispatchWorkItem { [weak self] in
            self?.finish(["ok": false, "reason": "timeout"])
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + args.timeout, execute: item)

        if args.mode == CacheWarmer.modeNavigate {
            guard let url = URL(string: args.navigateUrl) else {
                finish(["ok": false, "reason": "start failed", "error": "bad navigateUrl"])
                return
            }
            view.load(URLRequest(url: url))
        } else {
            view.loadHTMLString(args.html, baseURL: URL(string: args.baseUrl))
        }
    }

    private func finish(_ result: [String: Any]) {
        guard let deliver = reply else { return }
        reply = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: CacheWarmer.bridgeName)
        }
        webView = nil
        if CacheWarmer.current === self { CacheWarmer.current = nil }
        deliver(result)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let json = message.body as? String,
              let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            finish(["ok": false, "reason": "bad report"])
            return
        }
        finish(parsed)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // In `baseUrl` mode the script is inline in the page. In `navigate` mode the page is just a
        // document on the right origin and the script is injected once it has loaded.
        guard args.mode == CacheWarmer.modeNavigate, !injected else { return }
        injected = true
        webView.evaluateJavaScript(args.script, completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(["ok": false, "reason": "navigation failed", "error": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(["ok": false, "reason": "navigation failed", "error": error.localizedDescription])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(["ok": false, "reason": "renderer gone"])
    }
}

/// Forwards script messages without retaining the real handler.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
