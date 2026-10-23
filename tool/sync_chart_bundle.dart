// Mirrors the hosted chart page and its TradingView charting library into `assets/chart/`, so the
// plugin can serve them from the app instead of the network.
//
//   dart tool/sync_chart_bundle.dart --dry-run          # collect + report, write nothing
//   dart tool/sync_chart_bundle.dart                    # write assets/chart/
//
// Run it with `dart tool/...`, not `dart run`: this package depends on the Flutter SDK, which
// `dart run` cannot resolve.
//
// What is fetched, and how the list is found:
//   * the page HTML and the scripts it names;
//   * the library loader (`charting_library.standalone.js`), the bundle list inside it, and every
//     chunk the webpack runtime can request (read from the runtime's own tables, so lazy chunks no
//     session happened to touch are included);
//   * files named by `url(...)` in the stylesheets (required), hashed asset names found by text
//     search of the library scripts, and images the app scripts reference (both reported as
//     warnings when they do not resolve, since a text search can name a file nothing requests).
//
// Fail closed: everything is collected in memory first, and nothing is written unless every
// required file arrived. The layout mirrors the server (`v1/...`, `v4/...`), so the page's
// relative paths keep working.
//
// Ownership: `v1/` is upstream and is replaced wholesale. `v4/` (the page and app scripts) is OURS
// once it exists: the first sync creates it, later syncs write upstream copies to `upstream/v4/`
// for a deliberate diff and merge, and never touch it.
import "dart:async";
import "dart:collection";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "src/sha256.dart";
import "src/webpack_runtime.dart";

const String _chartRoot = "/chart/";

Future<void> main(List<String> argv) async {
  final _Options options = _Options.parse(argv);
  final _Fetcher fetcher = _Fetcher(options.concurrency);
  try {
    final _Plan plan = await _collect(fetcher, options);
    plan.report();
    if (options.dryRun) {
      stdout.writeln("\ndry run: nothing written");
      return;
    }
    _write(plan, options);
  } on _SyncFailure catch (e) {
    stderr.writeln("\nsync failed: ${e.message}\nnothing was written.");
    exitCode = 1;
  } finally {
    fetcher.close();
  }
}

final class _SyncFailure implements Exception {
  _SyncFailure(this.message);
  final String message;
}

final class _Options {
  _Options({
    required this.host,
    required this.page,
    required this.out,
    required this.language,
    required this.dryRun,
    required this.concurrency,
  });

  final Uri host;
  final String page;
  final String out;
  final String language;
  final bool dryRun;
  final int concurrency;

  Uri get pageUri => host.resolve(page);

  static _Options parse(List<String> argv) {
    String host = "https://tradingapi.motilaloswaluat.com";
    String page = "/chart/v4/RiseApp_Mobile.html";
    String out = "assets/chart";
    String language = "en";
    bool dryRun = false;
    int concurrency = 8;
    for (int i = 0; i < argv.length; i++) {
      final String a = argv[i];
      String next() {
        if (i + 1 >= argv.length) _usage("$a needs a value");
        return argv[++i];
      }

      switch (a) {
        case "--host":
          host = next();
        case "--page":
          page = next();
        case "--out":
          out = next();
        case "--language":
          language = next();
        case "--concurrency":
          concurrency = int.tryParse(next()) ?? _usage("--concurrency needs an integer");
        case "--dry-run":
          dryRun = true;
        case "-h" || "--help":
          _usage(null);
        default:
          _usage("unknown argument $a");
      }
    }
    final Uri hostUri = Uri.parse(host);
    if (hostUri.scheme != "https" || hostUri.host.isEmpty) _usage("--host must be an https URL");
    if (concurrency < 1 || concurrency > 32) _usage("--concurrency must be 1..32");
    return _Options(
      host: hostUri,
      page: page,
      out: out,
      language: language,
      dryRun: dryRun,
      concurrency: concurrency,
    );
  }
}

Never _usage(String? error) {
  final IOSink sink = error == null ? stdout : stderr;
  if (error != null) sink.writeln("error: $error\n");
  sink.writeln('''
usage: dart tool/sync_chart_bundle.dart [options]

  --host URL          server to mirror (default https://tradingapi.motilaloswaluat.com)
  --page PATH         chart page path (default /chart/v4/RiseApp_Mobile.html)
  --out DIR           output directory (default assets/chart)
  --language CODE     library language chunks to ship (default en; the page hard-codes "en")
  --concurrency N     parallel downloads, 1..32 (default 8)
  --dry-run           collect and report, write nothing''');
  exit(error == null ? 0 : 64);
}

// ------------------------------------------------------------------------------------ fetching

final class _Result {
  _Result(this.url, {this.bytes, this.contentType, this.status, this.error});
  final Uri url;
  final Uint8List? bytes;
  final String? contentType;
  final int? status;
  final String? error;
  bool get ok => bytes != null;
  String get why => error ?? "HTTP $status";
}

final class _Fetcher {
  _Fetcher(this._concurrency);

  final int _concurrency;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  void close() => _client.close(force: true);

  /// Fetches [url] once, retrying server errors and I/O failures but not 4xx.
  Future<_Result> _one(Uri url) async {
    String? lastError;
    int? lastStatus;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final HttpClientRequest req = await _client.getUrl(url);
        final HttpClientResponse res = await req.close().timeout(const Duration(seconds: 120));
        final BytesBuilder body = BytesBuilder(copy: false);
        await for (final List<int> chunk in res) {
          body.add(chunk);
        }
        if (res.statusCode == 200) {
          return _Result(url,
              bytes: body.takeBytes(), contentType: res.headers.contentType?.mimeType);
        }
        lastStatus = res.statusCode;
        if (res.statusCode < 500) return _Result(url, status: res.statusCode);
      } on Object catch (e) {
        lastError = e.toString();
      }
      await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }
    return _Result(url, status: lastStatus, error: lastError);
  }

  /// Fetches every URL with bounded concurrency; results are in input order.
  Future<List<_Result>> many(List<Uri> urls) async {
    final List<_Result?> out = List<_Result?>.filled(urls.length, null);
    final Queue<int> pending = Queue<int>.from(List<int>.generate(urls.length, (int i) => i));
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final int i = pending.removeFirst();
        out[i] = await _one(urls[i]);
      }
    }

    await Future.wait(<Future<void>>[
      for (int w = 0; w < _concurrency && w < urls.length; w++) worker(),
    ]);
    return out.cast<_Result>();
  }
}

// -------------------------------------------------------------------------------------- planning

final class _File {
  _File(this.rel, this.source, this.bytes, this.kind);
  final String rel;
  final Uri source;
  final Uint8List bytes;
  final String kind;
}

final class _Plan {
  final Map<String, _File> files = <String, _File>{};
  final List<String> warnings = <String>[];
  final List<String> externals = <String>[];
  late Uri pageUri;
  late Uri libBase;
  String? appVersion;

  String get libraryVersion =>
      RegExp(r"TT_v[0-9_]+").firstMatch(libBase.path)?.group(0) ?? "unknown";

  void report() {
    final Map<String, int> count = <String, int>{};
    final Map<String, int> size = <String, int>{};
    for (final _File f in files.values) {
      count[f.kind] = (count[f.kind] ?? 0) + 1;
      size[f.kind] = (size[f.kind] ?? 0) + f.bytes.length;
    }
    final int total = size.values.fold(0, (int a, int b) => a + b);
    stdout
      ..writeln('\nlibrary $libraryVersion  page version ${appVersion ?? "unknown"}')
      ..writeln("files: ${files.length}   total: ${_mb(total)}")
      ..writeln("by kind:");
    for (final String k in (count.keys.toList()..sort())) {
      stdout.writeln("  ${k.padRight(14)} ${count[k].toString().padLeft(4)} files  ${_mb(size[k]!)}");
    }
    final List<_File> biggest = files.values.toList()
      ..sort((_File a, _File b) => b.bytes.length.compareTo(a.bytes.length));
    stdout.writeln("largest:");
    for (final _File f in biggest.take(6)) {
      stdout.writeln("  ${_mb(f.bytes.length).padLeft(9)}  ${f.rel}");
    }
    if (externals.isNotEmpty) {
      stdout.writeln("external references (not bundled): ${externals.length}");
      for (final String e in externals.take(10)) {
        stdout.writeln("  $e");
      }
    }
    if (warnings.isNotEmpty) {
      stdout.writeln("warnings: ${warnings.length}");
      for (final String w in warnings.take(30)) {
        stdout.writeln("  $w");
      }
    }
  }
}

String _mb(int bytes) => "${(bytes / 1048576).toStringAsFixed(2)} MB";

/// Top-level directories under `/chart/` that mirror the server and are replaced on every sync:
/// the library (`v1/`) and the images the app scripts show in the chart UI (`Icons/`).
const List<String> _mirroredRoots = <String>["v1", "Icons"];

/// The page and app scripts (`v4/`). Ours once they exist; see the file header.
const String _ownedRoot = "v4";

String _rel(Uri u) {
  if (!u.path.startsWith(_chartRoot)) {
    throw _SyncFailure("$u is outside $_chartRoot");
  }
  final String p = Uri.decodeComponent(u.path.substring(_chartRoot.length));
  if (p.isEmpty || p.endsWith("/") || p.split("/").contains("..")) {
    throw _SyncFailure("$u is not a plain file path");
  }
  final String root = p.split("/").first;
  if (!_mirroredRoots.contains(root) && root != _ownedRoot) {
    throw _SyncFailure('$u is under "$root/"; only ${_mirroredRoots.join("/, ")}/ and $_ownedRoot/ are handled');
  }
  return p;
}

String? _relOrNull(Uri u) {
  try {
    return _rel(u);
  } on _SyncFailure {
    return null;
  }
}

String _text(Uint8List b) => utf8.decode(b, allowMalformed: true);

Future<_Plan> _collect(_Fetcher fetcher, _Options o) async {
  final _Plan plan = _Plan()..pageUri = o.pageUri;
  final String host = o.host.host;

  /// Fetches [urls] and adds the successes to the plan. Returns what was added and what failed;
  /// it is the caller's job to decide whether a failure matters.
  Future<(List<_File>, List<_Result>)> fetchInto(List<Uri> urls, String kind) async {
    final List<Uri> todo = <Uri>[
      for (final Uri u in urls)
        if (!plan.files.containsKey(_rel(u))) u,
    ];
    final List<_Result> results = await fetcher.many(todo);
    final List<_Result> failed = results.where((_Result r) => !r.ok).toList();
    final List<_File> added = <_File>[];
    for (final _Result r in results.where((_Result r) => r.ok)) {
      final String rel = _rel(r.url);
      if (!rel.endsWith(".html") && (r.contentType ?? "").contains("text/html")) {
        throw _SyncFailure("${r.url} came back as HTML; the server answered with a fallback page");
      }
      final _File? have = plan.files[rel];
      if (have != null) {
        if (_sameBytes(have.bytes, r.bytes!)) continue;
        throw _SyncFailure("$rel was requested as ${have.source} and ${r.url} with different bytes");
      }
      final _File f = _File(rel, r.url, r.bytes!, kind);
      plan.files[rel] = f;
      added.add(f);
    }
    return (added, failed);
  }

  String describe(List<_Result> failed, String kind) {
    final String list = failed.take(10).map((_Result r) => "  ${r.why}  ${r.url}").join("\n");
    return "${failed.length} required file(s) failed ($kind):\n$list";
  }

  /// Fetches [urls], requiring every one.
  Future<List<_File>> require(List<Uri> urls, String kind) async {
    final (List<_File> added, List<_Result> failed) = await fetchInto(urls, kind);
    if (failed.isNotEmpty) throw _SyncFailure(describe(failed, kind));
    return added;
  }

  /// Best-effort fetch for candidates a text search suggested. Misses become warnings.
  Future<List<_File>> optional(List<List<Uri>> alternatives, String kind, String label) async {
    final List<_File> added = <_File>[];
    for (final List<Uri> candidates in alternatives) {
      // A candidate outside the directories we mirror (e.g. the same relative path resolved
      // against the page instead of the library) cannot be bundled, so it is not tried.
      final List<Uri> alts = candidates.where((Uri u) => _relOrNull(u) != null).toList();
      if (alts.isEmpty) {
        plan.warnings.add("$label has no bundlable location: ${candidates.first}");
        continue;
      }
      if (alts.any((Uri u) => plan.files.containsKey(_rel(u)))) continue;
      final List<_Result> rs = await fetcher.many(alts);
      final int hit = rs.indexWhere(
        (_Result r) => r.ok && !(r.contentType ?? "").contains("text/html"),
      );
      if (hit < 0) {
        plan.warnings.add("$label did not resolve: ${alts.first.pathSegments.last} "
            '(tried ${alts.length} location(s), ${rs.map((_Result r) => r.why).toSet().join("/")})');
        continue;
      }
      final _File f = _File(_rel(rs[hit].url), rs[hit].url, rs[hit].bytes!, kind);
      plan.files[f.rel] = f;
      added.add(f);
    }
    return added;
  }

  // 1. The page and the scripts/stylesheets it names.
  stdout.writeln("page      ${o.pageUri}");
  final List<_Result> pageRes = await fetcher.many(<Uri>[o.pageUri]);
  if (!pageRes.single.ok) {
    throw _SyncFailure("page failed: ${pageRes.single.why}  ${o.pageUri}");
  }
  final String html = _text(pageRes.single.bytes!);
  plan.files[_rel(o.pageUri)] = _File(_rel(o.pageUri), o.pageUri, pageRes.single.bytes!, "page");
  plan.appVersion = RegExp(r"config\.version\s*=\s*'([^']+)'").firstMatch(html)?.group(1);

  final List<Uri> appUrls = <Uri>[];
  for (final RegExpMatch m in RegExp(
    '''<script\\b[^>]*?\\bsrc\\s*=\\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(html)) {
    appUrls.add(o.pageUri.resolve(m.group(1)!));
  }
  for (final RegExpMatch m in RegExp(
    '''<link\\b[^>]*?\\brel\\s*=\\s*["']stylesheet["'][^>]*?\\bhref\\s*=\\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).allMatches(html)) {
    appUrls.add(o.pageUri.resolve(m.group(1)!));
  }
  for (final Uri u in appUrls) {
    if (u.host != host) {
      throw _SyncFailure("the page loads $u from another host; it cannot be bundled");
    }
  }
  final Uri? standaloneUrl = appUrls
      .where((Uri u) => u.path.endsWith("/charting_library.standalone.js"))
      .cast<Uri?>()
      .firstWhere((Uri? _) => true, orElse: () => null);
  if (standaloneUrl == null) {
    throw _SyncFailure("the page does not load charting_library.standalone.js");
  }
  plan.libBase = standaloneUrl.resolve(".");
  // Strip the query from the key but keep it in the request: `main.js?v=6` and `main.js` are
  // different cache entries on the server, and the same file for us.
  final List<_File> app = await require(
    appUrls.where((Uri u) => u != standaloneUrl).toList(),
    "app",
  );

  // 2. The library loader, then every bundle and chunk it can ask for.
  stdout.writeln("library   ${plan.libBase}");
  final _File standalone = (await require(<Uri>[standaloneUrl], "library-loader")).single;
  final List<String> bundleList = parseBundleList(_text(standalone.bytes));
  final String runtimeRel =
      bundleList.firstWhere((String b) => RegExp(r"^bundles/runtime\.[0-9a-f]+\.js$").hasMatch(b));
  final _File runtime =
      (await require(<Uri>[plan.libBase.resolve(runtimeRel)], "library-runtime")).single;
  final WebpackChunks chunks = parseWebpackRuntime(_text(runtime.bytes));
  stdout.writeln("chunks    ${chunks.js.length} js, ${chunks.languageJs.length} "
      "${o.language} language, ${chunks.css.length} css");

  Uri bundle(String file) => plan.libBase.resolve("bundles/${withLanguage(file, o.language)}");
  final List<Uri> core = <Uri>[
    for (final String b in bundleList) plan.libBase.resolve(withLanguage(b, o.language)),
  ];
  await require(core, "library-core");
  await require(chunks.languageJs.map(bundle).toList(), "library-language");
  await require(chunks.css.map(bundle).toList(), "library-css");

  // Script chunks. A 404 is tolerated only for a chunk id that no library script ever requests
  // (`.e(<id>)`): the table lists it, but nothing can ask for it. Anything that is requested and
  // missing would break the chart at runtime, so it still fails the sync.
  final Map<Uri, WebpackChunk> byUrl = <Uri, WebpackChunk>{
    for (final WebpackChunk c in chunks.js) bundle(c.file): c,
  };
  final (_, List<_Result> jsFailed) = await fetchInto(byUrl.keys.toList(), "library-js");
  if (jsFailed.isNotEmpty) {
    final String scripts = plan.files.values
        .where((_File f) => f.rel.startsWith("v1/") && f.rel.endsWith(".js"))
        .map((_File f) => _text(f.bytes))
        .join("\n");
    final List<_Result> needed = <_Result>[];
    for (final _Result r in jsFailed) {
      final WebpackChunk chunk = byUrl[r.url]!;
      if (r.status == 404 && !RegExp("\\.e\\(${chunk.id}\\)").hasMatch(scripts)) {
        plan.warnings.add("chunk ${chunk.id} (${chunk.file}) is in the runtime table but is not "
            "on the server, and no library script requests it; skipped");
      } else {
        needed.add(r);
      }
    }
    if (needed.isNotEmpty) throw _SyncFailure(describe(needed, "library-js"));
  }

  // 3. Files the stylesheets name. Required: a missing font breaks the UI.
  final List<_File> sheets = plan.files.values.where((_File f) => f.rel.endsWith(".css")).toList();
  final List<Uri> cssRefs = <Uri>[];
  for (final _File css in sheets) {
    for (final String ref in cssUrlReferences(_text(css.bytes))) {
      final Uri u = css.source.resolve(ref.split(RegExp(r"[?#]")).first);
      if (u.host != host || u.scheme != "https") {
        plan.externals.add("${css.rel}: $ref");
      } else if (u.path.isNotEmpty && !u.path.endsWith("/")) {
        cssRefs.add(u);
      }
    }
  }
  await require(cssRefs.toSet().toList(), "library-asset");

  // 4. Hashed asset names mentioned in library scripts. A text search, so misses only warn.
  final Set<String> named = <String>{};
  for (final _File f in <_File>[
    ...plan.files.values.where((_File f) => f.rel.endsWith(".js") && f.rel.startsWith("v1/")),
  ]) {
    named.addAll(hashedAssetNames(_text(f.bytes)));
  }
  await optional(<List<Uri>>[
    for (final String n in named.toList()..sort())
      <Uri>[plan.libBase.resolve("bundles/$n"), plan.libBase.resolve(n)],
  ], "library-asset", "asset named in a library script");

  // 5. Images the app scripts reference. They are resolved inside the library's iframe, whose
  // <base> is the library directory, so they are relative to that, not to the page.
  final Set<String> images = <String>{};
  for (final _File f in app.where((_File f) => f.rel.endsWith(".js"))) {
    for (final RegExpMatch m in RegExp(
      '''["']((?:\\.\\./)+[\\w./-]+\\.(?:png|svg|jpe?g|gif|webp))["']''',
    ).allMatches(_text(f.bytes))) {
      images.add(m.group(1)!);
    }
  }
  await optional(<List<Uri>>[
    for (final String i in images.toList()..sort())
      <Uri>[plan.libBase.resolve(i), o.pageUri.resolve(i)],
  ], "app-image", "image referenced by an app script");

  return plan;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------------------- writing

/// Removes the Akamai mPulse (boomerang) snippet from the page. It is third-party analytics that
/// phones home on every open; the local copy should not.
(String, bool) _stripMpulse(String html) {
  final RegExp snippet = RegExp(
    r'<script>!function\(e\)\{var n="https://s\.go-mpulse\.net/boomerang/";[\s\S]*?</script>',
  );
  if (!snippet.hasMatch(html)) return (html, false);
  return (html.replaceFirst(snippet, "<!-- Akamai mPulse snippet removed by sync_chart_bundle -->"), true);
}

void _writeFile(String path, List<int> bytes) {
  final File f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}

void _write(_Plan plan, _Options o) {
  final Directory out = Directory(o.out)..createSync(recursive: true);
  final String base = out.path;

  // Mirrored roots: stage, then swap, so an interrupted write never leaves a half-replaced one.
  for (final String root in _mirroredRoots) {
    final Directory staging = Directory("$base/.$root.sync");
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    for (final _File f in plan.files.values.where((_File f) => f.rel.startsWith("$root/"))) {
      _writeFile("${staging.path}/${f.rel.substring(root.length + 1)}", f.bytes);
    }
    final Directory live = Directory("$base/$root");
    final Directory old = Directory("$base/.$root.old");
    if (old.existsSync()) old.deleteSync(recursive: true);
    if (live.existsSync()) live.renameSync(old.path);
    if (staging.existsSync()) staging.renameSync(live.path);
    if (old.existsSync()) old.deleteSync(recursive: true);
  }

  // Page and app scripts: ours once they exist.
  final Directory owned = Directory("$base/$_ownedRoot");
  final bool firstSync = !owned.existsSync();
  final String appRoot = firstSync ? owned.path : "$base/upstream/$_ownedRoot";
  if (!firstSync) {
    final Directory up = Directory(appRoot);
    if (up.existsSync()) up.deleteSync(recursive: true);
  }
  bool stripped = false;
  for (final _File f in plan.files.values.where((_File f) => f.rel.startsWith("$_ownedRoot/"))) {
    List<int> bytes = f.bytes;
    if (firstSync && f.kind == "page") {
      final (String html, bool did) = _stripMpulse(_text(f.bytes));
      stripped = did;
      bytes = utf8.encode(html);
    }
    _writeFile("$appRoot/${f.rel.substring(_ownedRoot.length + 1)}", bytes);
  }

  _writeManifest(plan, o, base, firstSync: firstSync, strippedMpulse: stripped);

  stdout
    ..writeln("\nwrote ${plan.files.length} files to $base")
    ..writeln(firstSync
        ? "v4/ created (page + app scripts are now yours to edit)."
        : "v4/ left untouched; upstream copies are in upstream/v4/ - diff and merge by hand.");
  if (firstSync && !stripped) {
    stdout.writeln("warning: the Akamai mPulse snippet was not found in the page; check it by hand.");
  }
  final Set<String> dirs = <String>{
    for (final String root in <String>[..._mirroredRoots, _ownedRoot])
      if (Directory("$base/$root").existsSync())
        for (final FileSystemEntity e in Directory("$base/$root").listSync(recursive: true))
          if (e is File) e.parent.path,
  };
  stdout.writeln("flutter asset directories for pubspec.yaml: ${dirs.length}");
}

void _writeManifest(
  _Plan plan,
  _Options o,
  String base, {
  required bool firstSync,
  required bool strippedMpulse,
}) {
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  for (final String root in <String>[..._mirroredRoots, _ownedRoot]) {
    final Directory d = Directory("$base/$root");
    if (!d.existsSync()) continue;
    final List<File> disk = d.listSync(recursive: true).whereType<File>().toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File f in disk) {
      final String rel = "$root/${f.path.substring(d.path.length + 1)}";
      final Uint8List bytes = f.readAsBytesSync();
      final _File? src = plan.files[rel];
      final String sha = sha256Hex(bytes);
      entries.add(<String, Object?>{
        "path": rel,
        "bytes": bytes.length,
        "sha256": sha,
        "source": src?.source.toString(),
        if (root == _ownedRoot) "owned": true,
        if (root == _ownedRoot && src != null) "upstreamSha256": sha256Hex(src.bytes),
        if (root == _ownedRoot && src == null) "localOnly": true,
      });
    }
  }
  final Map<String, Object?> manifest = <String, Object?>{
    "generatedAt": DateTime.now().toUtc().toIso8601String(),
    "host": o.host.toString(),
    "page": o.page,
    "library": plan.libraryVersion,
    "pageVersion": plan.appVersion,
    "language": o.language,
    "strippedMpulse": strippedMpulse,
    "unresolved": plan.warnings,
    "external": plan.externals,
    "fileCount": entries.length,
    "files": entries,
  };
  _writeFile("$base/manifest.json", utf8.encode('${const JsonEncoder.withIndent('  ').convert(manifest)}\n'));
}
