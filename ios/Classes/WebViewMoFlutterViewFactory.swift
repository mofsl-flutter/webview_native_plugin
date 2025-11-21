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
    private var containerView: UIView = UIView()
    private var delegate: WebViewControllerDelegate?
    private var isChart: Bool = true

    init(frame: CGRect, viewIdentifier: Int64, args: Any?, messenger: FlutterBinaryMessenger, delegate: WebViewControllerDelegate?) {
        self.delegate = delegate
        super.init()

        containerView.frame = frame
        containerView.autoresizesSubviews = true
        containerView.clipsToBounds = true

        // Read arguments
        if let argsDict = args as? [String: Any] {
            if let isChartArg = argsDict["isChart"] as? Bool {
                self.isChart = isChartArg
            }
        }

        // ATTACH THE SINGLETON WEBVIEW TO THIS VIEW - use frame instead of bounds
        WebViewManager.shared.attach(to: containerView, frame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    }

    func view() -> UIView {
        return containerView
    }

    deinit {
        // DETACH WHEN WIDGET IS REMOVED
        WebViewManager.shared.detach()
    }
}
