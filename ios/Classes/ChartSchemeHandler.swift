import Foundation
import WebKit

/// The bundled chart's addressing and file rules, with no WebKit state, so they can be reasoned
/// about (and mirrored against `ChartAssetPaths` on Android) in one place.
///
/// The bundle is `assets/chart/` in this package (see `tool/sync_chart_bundle.dart`), mirroring the
/// server's `/chart/` tree: `mochart://app/chart/v4/js/main.js` is the asset
/// `assets/chart/v4/js/main.js`. WKWebView cannot intercept `https`, so iOS serves the bundle from
/// a custom scheme; Android uses a virtual https host for the same reason in reverse.
enum ChartBundleScheme {
    static let name = "mochart"
    static let host = "app"
    static let urlPrefix = "/chart/"
    static let package = "ios_webview_plugin"
    static var baseURL: String { "\(name)://\(host)\(urlPrefix)" }

    /// Turns `assets/chart/...` into the key Flutter bundled it under. Set by the plugin when it
    /// registers; deliberately not on `WebViewManager`, whose first access builds a WKWebView, which
    /// `register(with:)` must not do for every engine (a background isolate registers plugins too).
    static var assetKeyLookup: ((String) -> String)?

    /// Whether [url] addresses the bundled chart.
    static func isChartURL(_ url: URL?) -> Bool { url?.scheme == name }

    /// The asset a request URL refers to, or nil when it is not a safe path to a file.
    ///
    /// Anything that could climb out of the bundle (`..`, `.`, empty segments, backslashes, NUL) is
    /// refused rather than normalised: the page never asks for such a path, so a request for one is
    /// not ours to fix. `URL.path` is already percent-decoded.
    static func assetPath(for url: URL) -> String? {
        guard url.scheme == name, url.host == host, url.path.hasPrefix(urlPrefix) else { return nil }
        let relative = String(url.path.dropFirst(urlPrefix.count))
        if relative.isEmpty || relative.hasSuffix("/") { return nil }
        for segment in relative.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." || segment == ".." { return nil }
            if segment.contains("\\") || segment.contains("\u{0}") { return nil }
        }
        return "assets/chart/" + relative
    }

    /// The file on disk for an asset, or nil when this build does not carry it.
    static func filePath(forAsset asset: String) -> String? {
        guard let lookup = assetKeyLookup else { return nil }
        return Bundle.main.path(forResource: lookup(asset), ofType: nil)
    }

    /// MIME type from the extension; unknown extensions are served as opaque bytes.
    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico", "cur": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }

    /// Text types are declared UTF-8; binary types must not carry a charset.
    static func contentType(forMime mime: String) -> String {
        let text = mime.hasPrefix("text/") || mime == "application/json" || mime == "image/svg+xml"
        return text ? "\(mime); charset=utf-8" : mime
    }

    /// What the bundle is, or why it is not available. Read from the bundle's own manifest, so a
    /// build that shipped without the assets says so and the host can fall back to the hosted page.
    static func info() -> [String: Any?] {
        guard let path = filePath(forAsset: "assets/chart/manifest.json") else {
            return ["available": false, "baseUrl": baseURL, "reason": "assets/chart/manifest.json is not in this build"]
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["available": false, "baseUrl": baseURL, "reason": "manifest.json is not an object"]
            }
            return [
                "available": true,
                "baseUrl": baseURL,
                "library": manifest["library"] as? String,
                "pageVersion": manifest["pageVersion"] as? String,
                "language": manifest["language"] as? String,
                "fileCount": manifest["fileCount"] as? Int,
            ]
        } catch {
            return ["available": false, "baseUrl": baseURL, "reason": error.localizedDescription]
        }
    }
}

/// Serves the bundled chart to WKWebView for the `mochart` scheme.
///
/// A file the bundle does not have is answered with a real 404 rather than a failed task: the page
/// treats a failed load of a script as fatal, and there is no network behind this scheme to retry.
final class ChartSchemeHandler: NSObject, WKURLSchemeHandler {
    private let queue = DispatchQueue(label: "ios_webview_plugin.chart-assets", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    /// Tasks WebKit has cancelled. Responding to one afterwards raises an Objective-C exception, so
    /// every response is checked against this on the main thread first.
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let asset = ChartBundleScheme.assetPath(for: url) else {
            finish(urlSchemeTask, id, status: 404, mime: "text/plain", data: Data())
            return
        }
        let mime = ChartBundleScheme.mimeType(forPath: asset)
        // Read off the main thread: the library's largest file is 2.6 MB.
        queue.async {
            guard let path = ChartBundleScheme.filePath(forAsset: asset),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
                self.finish(urlSchemeTask, id, status: 404, mime: "text/plain", data: Data())
                return
            }
            self.finish(urlSchemeTask, id, status: 200, mime: mime, data: data)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    /// Answers [task] on the main thread unless WebKit already cancelled it.
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, status: Int, mime: String, data: Data) {
        DispatchQueue.main.async {
            self.lock.lock()
            let wasStopped = self.stopped.remove(id) != nil
            self.lock.unlock()
            if wasStopped { return }
            guard let url = task.request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": ChartBundleScheme.contentType(forMime: mime),
                        "Content-Length": String(data.count),
                        // The library loads scripts with `crossorigin`.
                        "Access-Control-Allow-Origin": "*",
                    ]
                  ) else {
                task.didFailWithError(URLError(.badServerResponse))
                return
            }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }
}
