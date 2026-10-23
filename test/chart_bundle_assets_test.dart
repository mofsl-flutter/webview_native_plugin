// Checks the bundled chart (assets/chart) against its own manifest and against what the page and
// the library can request, so a bad sync or a hand-edit that drops a file fails here and not on a
// device with the network off.
//
// Mirrored files (v1/, Icons/) must match their recorded SHA-256 exactly. The page and app
// scripts (v4/) are ours to edit, so their hashes are deliberately not pinned; only their
// presence and what they reference are checked.
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "../tool/src/sha256.dart";
import "../tool/src/webpack_runtime.dart";

const String _root = "assets/chart";
const String _chartPath = "/chart/";

/// Where a `/chart/...` URL path lives on disk.
File _file(Uri u) {
  if (!u.path.startsWith(_chartPath)) throw ArgumentError("$u is outside the bundled root");
  return File("$_root/${Uri.decodeComponent(u.path.substring(_chartPath.length))}");
}

String _read(File f) => utf8.decode(f.readAsBytesSync(), allowMalformed: true);

void main() {
  final Map<String, Object?> manifest =
      jsonDecode(File("$_root/manifest.json").readAsStringSync()) as Map<String, Object?>;
  final List<Map<String, Object?>> entries =
      (manifest["files"]! as List<Object?>).cast<Map<String, Object?>>();
  final String language = manifest["language"]! as String;
  final Set<String> skippedIds = <String>{
    for (final Object? s in manifest["skippedChunks"]! as List<Object?>)
      (s! as Map<String, Object?>)["id"]! as String,
  };

  final Uri page = Uri.parse("${_chartPath}v4/RiseApp_Mobile.html");
  final String html = _read(_file(page));
  final Uri standalone = <Uri>[
    for (final RegExpMatch m in RegExp(
      r"""<script\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']""",
      caseSensitive: false,
    ).allMatches(html))
      page.resolve(m.group(1)!),
  ].singleWhere((Uri u) => u.path.endsWith("/charting_library.standalone.js"));
  final Uri libBase = standalone.resolve(".");
  final Uri bundles = libBase.resolve("bundles/");

  group("manifest", () {
    test("agrees with the disk on every mirrored file", () {
      final Set<String> listed = <String>{
        for (final Map<String, Object?> e in entries) e["path"]! as String,
      };
      final Set<String> onDisk = <String>{
        for (final FileSystemEntity e in Directory(_root).listSync(recursive: true))
          if (e is File)
            e.path.substring(_root.length + 1),
      }..removeWhere((String p) => p == "manifest.json" || p.startsWith("upstream/"));
      // v4/ is ours: adding a file there by hand is normal and must not need a network sync, so
      // extra files are allowed. A file the manifest lists must still exist, mirrored or owned.
      expect(listed.difference(onDisk), isEmpty, reason: "in the manifest but not on disk");
      expect(
        onDisk.difference(listed).where((String p) => !p.startsWith("v4/")),
        isEmpty,
        reason: "mirrored file on disk but not in the manifest",
      );
    });

    test("every mirrored file matches its recorded size and SHA-256", () {
      final List<String> bad = <String>[];
      for (final Map<String, Object?> e in entries) {
        if (e["owned"] == true) continue;
        final List<int> bytes = File("$_root/${e["path"]}").readAsBytesSync();
        if (bytes.length != e["bytes"] || sha256Hex(bytes) != e["sha256"]) bad.add("${e["path"]}");
      }
      expect(bad, isEmpty, reason: "changed since the last sync; re-run tool/sync_chart_bundle.dart");
    });
  });

  group("pubspec", () {
    test("declares every directory that holds a bundled file", () {
      // Flutter asset directories are not recursive: a file in an undeclared directory is simply
      // absent from the built app, and nothing else would notice until the page loaded.
      final Set<String> declared = <String>{
        for (final RegExpMatch m in RegExp(r"^\s*-\s+(assets/chart/\S+)\s*$", multiLine: true)
            .allMatches(File("pubspec.yaml").readAsStringSync()))
          m.group(1)!,
      };
      final List<String> uncovered = <String>[
        for (final Map<String, Object?> e in entries)
          if (!declared.contains("assets/chart/${e["path"]}") &&
              !declared.contains("assets/chart/${(e["path"]! as String).replaceFirst(RegExp(r"[^/]+$"), "")}"))
            e["path"]! as String,
      ];
      expect(uncovered, isEmpty, reason: "add the directory to flutter.assets in pubspec.yaml");
      final List<String> dead = declared
          .where((String d) => !File(d).existsSync() && !Directory(d).existsSync())
          .toList();
      expect(dead, isEmpty, reason: "declared in pubspec.yaml but not on disk");
    });
  });

  group("library", () {
    final String standaloneSource = _read(_file(standalone));

    test("the loader's bundles are all present", () {
      for (final String b in parseBundleList(standaloneSource)) {
        final Uri u = libBase.resolve(withLanguage(b, language));
        expect(_file(u).existsSync(), isTrue, reason: "$u");
      }
    });

    final List<String> runtimes = parseBundleList(standaloneSource)
        .where((String b) => RegExp(r"^bundles/runtime\.[0-9a-f]+\.js$").hasMatch(b))
        .toList();

    test("exactly one runtime, and every chunk it can request is present", () {
      expect(runtimes, hasLength(1));
      final WebpackChunks chunks = parseWebpackRuntime(_read(_file(libBase.resolve(runtimes.single))));
      final List<String> missing = <String>[
        for (final WebpackChunk c in chunks.js)
          if (!skippedIds.contains(c.id) && !_file(bundles.resolve(c.file)).existsSync()) c.file,
        for (final String f in chunks.languageJs)
          if (!_file(bundles.resolve(withLanguage(f, language))).existsSync()) f,
        for (final String f in chunks.css)
          if (!_file(bundles.resolve(f)).existsSync()) f,
      ];
      expect(missing, isEmpty);
      // A skipped chunk is a table entry nothing requests; it must stay that way.
      final String scripts = <String>[
        for (final FileSystemEntity e in Directory(_file(bundles).path).listSync())
          if (e is File && e.path.endsWith(".js")) _read(e),
      ].join("\n");
      for (final String id in skippedIds) {
        expect(RegExp("\\.e\\($id\\)").hasMatch(scripts), isFalse,
            reason: "chunk $id is recorded as skipped but a script requests it");
      }
    });

    test("every file a stylesheet names is present", () {
      final List<String> missing = <String>[];
      final Directory dir = Directory(_file(bundles).path);
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File || !e.path.endsWith(".css")) continue;
        final Uri cssUri = bundles.resolve(e.uri.pathSegments.last);
        for (final String ref in cssUrlReferences(_read(e))) {
          final Uri u = cssUri.resolve(ref.split(RegExp(r"[?#]")).first);
          if (u.hasScheme || u.path.isEmpty || u.path.endsWith("/")) continue;
          if (!_file(u).existsSync()) missing.add("${e.uri.pathSegments.last} -> $ref");
        }
      }
      expect(missing, isEmpty);
    });
  });

  group("page", () {
    test("loads nothing from outside the bundle", () {
      final List<RegExpMatch> srcs = RegExp(
        r"""\b(?:src|href)\s*=\s*["']([^"']+)["']""",
        caseSensitive: false,
      ).allMatches(html).toList();
      expect(srcs, isNotEmpty);
      for (final RegExpMatch m in srcs) {
        final Uri u = page.resolve(m.group(1)!);
        expect(u.hasScheme && u.scheme != "file" ? u.host : "", isEmpty,
            reason: "${m.group(1)} points off-device");
        expect(_file(u).existsSync(), isTrue, reason: "${m.group(1)} is missing from the bundle");
      }
    });

    test("carries no third-party analytics snippet", () {
      expect(html, isNot(contains("go-mpulse")));
    });

    test("every image an app script shows is present", () {
      final List<String> missing = <String>[];
      for (final FileSystemEntity e in Directory(_file(page.resolve("js/")).path).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith(".js")) continue;
        // The library's iframe is the document these paths resolve in, so its <base> is libBase.
        for (final RegExpMatch m in RegExp(
          r"""["']((?:\.\./)+[\w./-]+\.(?:png|svg|jpe?g|gif|webp))["']""",
        ).allMatches(_read(e))) {
          if (!_file(libBase.resolve(m.group(1)!)).existsSync()) missing.add(m.group(1)!);
        }
      }
      expect(missing, isEmpty);
    });
  });
}
