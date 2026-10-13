import Foundation

/// Read-only census of the on-disk state WebKit keeps for the app's web views.
///
/// Exists to answer "is the charting library still on the device?" by looking rather than by
/// inferring it from timings. It only lists and stats files, so it is safe to call at any point in
/// a run. Mirrors the Android collector's output shape so one Dart summariser reads both.
///
/// Timestamps are file mtimes: when an entry was stored, not when it was last read.
///
/// Walks synchronously, so `collect` hops to a background queue and replies on the main queue.
enum WebCacheStats {
    /// Upper bound on files visited, so a pathological profile cannot stall the walk.
    private static let maxFiles = 200_000

    /// Directory levels below a root that form a group key, e.g. `NetworkCache/Version 17`.
    private static let groupDepth = 2

    private struct Bucket {
        var bytes: Int64 = 0
        var files = 0
        var oldest = Int64.max
        var newest: Int64 = 0

        mutating func add(size: Int64, mtimeMs: Int64) {
            bytes += size
            files += 1
            if mtimeMs < oldest { oldest = mtimeMs }
            if mtimeMs > newest { newest = mtimeMs }
        }

        var asMap: [String: Any] {
            [
                "bytes": bytes,
                "files": files,
                "oldestMtime": files == 0 ? NSNull() : oldest as Any,
                "newestMtime": files == 0 ? NSNull() : newest as Any,
            ]
        }
    }

    static func collect(completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stats = census()
            DispatchQueue.main.async { completion(stats) }
        }
    }

    private static func census() -> [String: Any] {
        let fm = FileManager.default
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first

        // WebKit keeps its network cache under Caches, and durable site data (local storage,
        // IndexedDB) under Library/WebKit. Which Caches location is used depends on the OS and
        // the data store, so both candidates are walked and reported separately.
        let candidates: [(label: String, url: URL?)] = [
            ("Library/Caches/<bundle>/WebKit",
             caches?.appendingPathComponent(bundleId, isDirectory: true)
                 .appendingPathComponent("WebKit", isDirectory: true)),
            ("Library/Caches/WebKit",
             caches?.appendingPathComponent("WebKit", isDirectory: true)),
            ("Library/WebKit/<bundle>",
             library?.appendingPathComponent("WebKit", isDirectory: true)
                 .appendingPathComponent(bundleId, isDirectory: true)),
        ]

        var visited = 0
        var truncated = false
        var rootMaps: [[String: Any]] = []

        for (label, url) in candidates {
            var groups: [String: Bucket] = [:]
            var isDir: ObjCBool = false
            let exists = url.map { fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false

            if exists, let root = url,
               let walker = fm.enumerator(
                   at: root,
                   includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                   options: [])
            {
                let rootDepth = root.pathComponents.count
                for case let file as URL in walker {
                    if visited >= maxFiles {
                        truncated = true
                        break
                    }
                    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                          values.isRegularFile == true else { continue }
                    visited += 1

                    let dirs = file.pathComponents.dropFirst(rootDepth).dropLast().prefix(groupDepth)
                    let key = dirs.isEmpty ? "." : dirs.joined(separator: "/")
                    let mtimeMs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                    groups[key, default: Bucket()].add(size: Int64(values.fileSize ?? 0), mtimeMs: mtimeMs)
                }
            }

            rootMaps.append([
                "root": label,
                "exists": exists,
                "totalBytes": groups.values.reduce(Int64(0)) { $0 + $1.bytes },
                "totalFiles": groups.values.reduce(0) { $0 + $1.files },
                "groups": groups.mapValues { $0.asMap },
            ])
        }

        return [
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
            "roots": rootMaps,
            "truncated": truncated,
        ]
    }
}
