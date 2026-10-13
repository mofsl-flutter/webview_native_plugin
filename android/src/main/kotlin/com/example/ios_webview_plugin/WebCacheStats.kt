package com.example.ios_webview_plugin

import android.content.Context
import java.io.File

/**
 * Read-only census of the on-disk state Chromium keeps for the WebView.
 *
 * This exists to answer "is the charting library still on the device?" without inferring it from
 * timings. It only lists and stats files; it never opens, mutates or deletes anything, so it is
 * safe to call at any point in a run, including from a harness that is about to kill the process.
 *
 * Caveat on the timestamps: they are file mtimes. Chromium's simple cache writes an entry once and
 * does not touch the file when the entry is merely read, so `newestMtime` is "last stored", not
 * "last used". That is the useful bound for cache lifetime, but it is not an access time.
 *
 * Walks synchronously, so callers must not invoke it on the main thread.
 */
internal object WebCacheStats {

    /** Upper bound on files visited, so a pathological profile cannot stall the walk. */
    private const val MAX_FILES = 200_000

    /**
     * How many directory levels below a root form a group key. Two gives `Default/HTTP Cache`,
     * `Default/Local Storage` and so on, which is the granularity that answers the question.
     */
    private const val GROUP_DEPTH = 2

    private const val CODE_CACHE_DIR = "Code Cache"

    private class Bucket {
        var bytes = 0L
        var files = 0
        var oldest = Long.MAX_VALUE
        var newest = 0L

        fun add(file: File) {
            bytes += file.length()
            files++
            val modified = file.lastModified()
            if (modified < oldest) oldest = modified
            if (modified > newest) newest = modified
        }

        fun toMap(): Map<String, Any?> = mapOf(
            "bytes" to bytes,
            "files" to files,
            "oldestMtime" to if (files == 0) null else oldest,
            "newestMtime" to if (files == 0) null else newest
        )
    }

    private class WalkState {
        var visited = 0
        var truncated = false
    }

    fun collect(context: Context): Map<String, Any?> {
        // Chromium splits the profile: disposable HTTP and code caches under cacheDir, durable
        // storage (cookies, local storage, service workers) under the app's data dir.
        val roots = listOf(
            "cache/WebView" to File(context.cacheDir, "WebView"),
            "data/app_webview" to File(context.applicationInfo.dataDir, "app_webview")
        )
        val codeCache = Bucket()
        val state = WalkState()

        val rootMaps = roots.map { (label, dir) ->
            val groups = LinkedHashMap<String, Bucket>()
            if (dir.isDirectory) walk(dir, dir, groups, codeCache, state, inCodeCache = false)
            mapOf(
                "root" to label,
                "exists" to dir.isDirectory,
                "totalBytes" to groups.values.sumOf { it.bytes },
                "totalFiles" to groups.values.sumOf { it.files },
                "groups" to groups.mapValues { it.value.toMap() }
            )
        }

        return mapOf(
            "ts" to System.currentTimeMillis(),
            "roots" to rootMaps,
            // Reported separately because it is nested inside the HTTP cache group, and it is the
            // part that decides whether a re-served library is recompiled or not.
            "codeCache" to codeCache.toMap(),
            "truncated" to state.truncated
        )
    }

    private fun walk(
        root: File,
        dir: File,
        groups: MutableMap<String, Bucket>,
        codeCache: Bucket,
        state: WalkState,
        inCodeCache: Boolean
    ) {
        val children = dir.listFiles() ?: return
        for (child in children) {
            if (state.visited >= MAX_FILES) {
                state.truncated = true
                return
            }
            if (child.isDirectory) {
                walk(root, child, groups, codeCache, state, inCodeCache || child.name == CODE_CACHE_DIR)
            } else {
                state.visited++
                groups.getOrPut(groupKey(root, child)) { Bucket() }.add(child)
                if (inCodeCache) codeCache.add(child)
            }
        }
    }

    private fun groupKey(root: File, file: File): String {
        val parts = file.relativeTo(root).invariantSeparatorsPath.split('/')
        val dirs = parts.dropLast(1).take(GROUP_DEPTH)
        return if (dirs.isEmpty()) "." else dirs.joinToString("/")
    }
}
