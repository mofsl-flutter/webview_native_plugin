package com.example.ios_webview_plugin

import android.util.Log
import android.webkit.WebResourceResponse
import androidx.webkit.WebViewAssetLoader
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

/**
 * Maps a request path under the chart prefix to a bundled asset. No Android types, so it is unit
 * tested on a plain JVM.
 *
 * The bundle is `assets/chart/` in this package (see `tool/sync_chart_bundle.dart`), mirroring the
 * server's `/chart/` tree, so `https://appassets.androidplatform.net/chart/v4/js/main.js` is the
 * asset `assets/chart/v4/js/main.js`.
 */
internal object ChartAssetPaths {
    /** Virtual host the chart is served from. Nothing resolves it; the WebView intercepts it. */
    const val HOST = "appassets.androidplatform.net"

    /** Path prefix under [HOST] that maps onto the bundle. */
    const val URL_PREFIX = "/chart/"

    /** Flutter package that owns the assets. */
    const val PACKAGE = "ios_webview_plugin"

    private const val ASSET_ROOT = "assets/chart/"

    /** The base URL the page is loaded from, e.g. `https://appassets.androidplatform.net/chart/`. */
    const val BASE_URL = "https://$HOST$URL_PREFIX"

    /**
     * The asset a request path refers to, or `null` when it is not a safe path to a file.
     *
     * [relative] is the part after [URL_PREFIX], already percent-decoded. Anything that could
     * climb out of the bundle (`..`, `.`, empty segments, backslashes, NUL) is refused rather than
     * normalised: the page never asks for such a path, so a request for one is not ours to fix.
     */
    fun assetPath(relative: String): String? {
        if (relative.isEmpty() || relative.endsWith("/")) return null
        for (segment in relative.split('/')) {
            if (segment.isEmpty() || segment == "." || segment == "..") return null
            if (segment.contains('\\') || segment.contains('\u0000')) return null
        }
        return ASSET_ROOT + relative
    }

    /** MIME type from the file extension; unknown extensions are served as opaque bytes. */
    fun mimeType(path: String): String =
        when (path.substringAfterLast('.', "").lowercase()) {
            "js", "mjs" -> "text/javascript"
            "css" -> "text/css"
            "html", "htm" -> "text/html"
            "json" -> "application/json"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "ico", "cur" -> "image/x-icon"
            "woff2" -> "font/woff2"
            "woff" -> "font/woff"
            "ttf" -> "font/ttf"
            "otf" -> "font/otf"
            "mp3" -> "audio/mpeg"
            "ogg" -> "audio/ogg"
            "wav" -> "audio/wav"
            "wasm" -> "application/wasm"
            else -> "application/octet-stream"
        }

    /** Text types are declared UTF-8; binary types must not carry a charset. */
    fun encoding(mime: String): String? =
        if (mime.startsWith("text/") || mime == "application/json" || mime == "image/svg+xml") {
            "utf-8"
        } else {
            null
        }
}

/**
 * Serves the bundled chart for [WebViewAssetLoader].
 *
 * Both lookups are injected so the class has no hold on the Flutter engine or a `Context`.
 * [lookupKey] turns `assets/chart/...` into the path inside the APK, and [openAsset] opens it.
 */
internal class ChartAssetPathHandler(
    private val lookupKey: (String) -> String,
    private val openAsset: (String) -> InputStream,
) : WebViewAssetLoader.PathHandler {

    override fun handle(path: String): WebResourceResponse {
        // Never let an exception out of here: it is thrown on a WebView IO thread and would take
        // the whole app down instead of failing one request.
        return try {
            val asset = ChartAssetPaths.assetPath(path) ?: return notFound()
            val stream = openAsset(lookupKey(asset))
            val mime = ChartAssetPaths.mimeType(asset)
            WebResourceResponse(mime, ChartAssetPaths.encoding(mime), 200, "OK", HEADERS, stream)
        } catch (e: IOException) {
            // The page asked for a file the bundle does not have. There is no network behind this
            // host, so answer definitively instead of letting the WebView try DNS.
            Log.w(TAG, "chart asset not found: $path")
            notFound()
        } catch (e: Exception) {
            Log.e(TAG, "chart asset failed: $path", e)
            WebResourceResponse(
                "text/plain", "utf-8", 500, "Internal Error", HEADERS,
                ByteArrayInputStream(ByteArray(0))
            )
        }
    }

    private fun notFound() = WebResourceResponse(
        "text/plain", "utf-8", 404, "Not Found", HEADERS, ByteArrayInputStream(ByteArray(0))
    )

    private companion object {
        const val TAG = "ChartAssets"

        /** The library loads its scripts with `crossorigin`; same-origin needs no header, a
         *  differently-originated embedder (a host page, a test) does. */
        val HEADERS = mapOf("Access-Control-Allow-Origin" to "*")
    }
}
