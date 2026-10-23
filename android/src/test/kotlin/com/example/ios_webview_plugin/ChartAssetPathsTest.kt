package com.example.ios_webview_plugin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The path rules that decide which bundled file a request may read. The page never asks for a
 * path that fails these, so a request that does is refused rather than repaired: serving a
 * "normalised" path would let a crafted URL pick a file the page did not mean to load.
 */
class ChartAssetPathsTest {

    @Test
    fun mapsAPathUnderThePrefixOntoTheBundle() {
        assertEquals(
            "assets/chart/v4/js/main.js",
            ChartAssetPaths.assetPath("v4/js/main.js"),
        )
        assertEquals(
            "assets/chart/v1/Libraries/Paid_libraries/TT_v29_1_0/bundles/runtime.e7b22a9e847c6e4bedc1.js",
            ChartAssetPaths.assetPath(
                "v1/Libraries/Paid_libraries/TT_v29_1_0/bundles/runtime.e7b22a9e847c6e4bedc1.js"
            ),
        )
    }

    @Test
    fun refusesAnythingThatCouldLeaveTheBundle() {
        val refused = listOf(
            "",                       // nothing asked for
            "v4/",                    // a directory
            "../manifest.json",       // climbs out
            "v4/../../secret",        // climbs out in the middle
            "v4/./js/main.js",        // a dot segment is not a file name the page uses
            "v4//js/main.js",         // empty segment
            "v4\\js\\main.js",        // backslash
            "v4/js/main.js\u0000.png" // NUL truncation
        )
        for (path in refused) {
            assertNull(ChartAssetPaths.assetPath(path), "should refuse: ${path.replace("\u0000", "\\0")}")
        }
    }

    @Test
    fun dotsInsideAFileNameAreNotATraversal() {
        // Hashed chunk names are full of dots; only a segment that IS "." or ".." is a traversal.
        assertEquals(
            "assets/chart/v1/bundles/a..b.js",
            ChartAssetPaths.assetPath("v1/bundles/a..b.js"),
        )
    }

    @Test
    fun picksTheMimeTypeTheWebViewNeeds() {
        // The library loads scripts with `crossorigin` and checks module/CSS types, so a wrong or
        // missing type fails the load rather than being sniffed.
        assertEquals("text/javascript", ChartAssetPaths.mimeType("assets/chart/v4/js/main.js"))
        assertEquals("text/css", ChartAssetPaths.mimeType("x/4986.8b484bfeff805649f879.css"))
        assertEquals("font/woff2", ChartAssetPaths.mimeType("x/EuclidCircular.be8f862db48c2976009f.woff2"))
        assertEquals("image/x-icon", ChartAssetPaths.mimeType("x/dot.3d617b6b01edba83a7f4.cur"))
        assertEquals("image/png", ChartAssetPaths.mimeType("x/Moon.PNG"))
        assertEquals("application/octet-stream", ChartAssetPaths.mimeType("x/blob.unknown"))
        assertEquals("application/octet-stream", ChartAssetPaths.mimeType("x/noextension"))
    }

    @Test
    fun onlyTextTypesCarryACharset() {
        assertEquals("utf-8", ChartAssetPaths.encoding("text/javascript"))
        assertEquals("utf-8", ChartAssetPaths.encoding("application/json"))
        assertNull(ChartAssetPaths.encoding("image/png"))
        assertNull(ChartAssetPaths.encoding("font/woff2"))
    }

    @Test
    fun theBaseUrlMatchesTheHostAndPrefix() {
        assertEquals("https://appassets.androidplatform.net/chart/", ChartAssetPaths.BASE_URL)
    }
}
