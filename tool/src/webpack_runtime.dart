/// Reads the file lists out of the TradingView charting library's own loader and webpack runtime.
///
/// The library loads most of its code lazily, by chunk id, from tables inside
/// `bundles/runtime.<hash>.js`. A capture of one session misses every chunk that session did not
/// need, so the sync tool reads the tables instead. Each parser throws [FormatException] when the
/// text is not the shape it expects: a library upgrade that changes the runtime must stop the
/// sync, not quietly ship a bundle with files missing.
library;

import "dart:convert";

/// A script chunk: the id the library asks for it by, and the file that serves it.
class WebpackChunk {
  /// Creates a chunk.
  const WebpackChunk(this.id, this.file);

  /// Numeric chunk id, as it appears in `o.e(<id>)` calls, e.g. `7995`.
  final String id;

  /// File name relative to `bundles/`, e.g. `line-tool-table.<hash>.js` or `7995.<hash>.js`.
  final String file;
}

/// The chunk file names a webpack runtime can request, relative to `bundles/`.
class WebpackChunks {
  /// Creates the result.
  const WebpackChunks({required this.js, required this.languageJs, required this.css});

  /// Language-independent script chunks that have a script file.
  final List<WebpackChunk> js;

  /// Per-language script chunks with the `__LANG__` placeholder still in the name, e.g.
  /// `__LANG__.2970.<hash>.js`. The runtime substitutes the page's language at request time.
  final List<String> languageJs;

  /// Stylesheet chunks, e.g. `4986.<hash>.css`. Right-to-left variants are not listed.
  final List<String> css;
}

final RegExp _langTernary = RegExp(r'(\d+)===e\?"(__LANG__\.[^"]+\.js)"');
final RegExp _entry = RegExp(r'(\d+)\s*:\s*"([^"]*)"');
final RegExp _nameMap = RegExp(r"\(\{([^}]*)\}\[e\]\|\|e\)");
final RegExp _jsHashes = RegExp(r'\+"\."\+\{([^}]*)\}\[e\]\+"\.js"');
final RegExp _cssHashes = RegExp(r'e\+"\."\+\{([^}]*)\}\[e\]\+"\.css"');

/// The runtime's own "this chunk has no script" test, as a pattern over chunk ids.
///
/// It sits in the chunk-loading handler as `.f.j=(a,c)=>{…/^(…)$/.test(a)…}`. The pattern is
/// plain alternation and character classes, so it means the same in Dart.
RegExp _cssOnlyIds(String runtimeSource) {
  final int handler = runtimeSource.indexOf(RegExp(r"\.f\.j=\(\w+,\w+\)=>"));
  final int open = handler < 0 ? -1 : runtimeSource.indexOf("/^(", handler);
  final int close = open < 0 ? -1 : runtimeSource.indexOf(")\$/.test(", open);
  if (close < 0) {
    throw const FormatException("runtime has no `.f.j` handler with a CSS-only chunk test");
  }
  return RegExp(runtimeSource.substring(open + 1, close + 2));
}

Map<String, String> _entries(String body) => <String, String>{
      for (final RegExpMatch m in _entry.allMatches(body)) m.group(1)!: m.group(2)!,
    };

/// Parses `.u` (script chunk file names) and `.miniCssF` (stylesheet chunk file names) out of
/// [runtimeSource].
///
/// A script chunk is named `<name>.<hash>.js`, where `<name>` is the entry in the name table or,
/// when the id has none, the id itself. Only ids that have a hash exist as files.
WebpackChunks parseWebpackRuntime(String runtimeSource) {
  final int u = runtimeSource.indexOf(".u=e=>");
  final int css = runtimeSource.indexOf(".miniCssF=");
  if (u < 0 || css < 0 || css < u) {
    throw const FormatException("runtime has no `.u=` / `.miniCssF=` tables in the expected order");
  }
  final String uSection = runtimeSource.substring(u, css);

  final List<String> language = <String>[
    for (final RegExpMatch m in _langTernary.allMatches(uSection)) m.group(2)!,
  ];

  final RegExpMatch? hashMatch = _jsHashes.firstMatch(uSection);
  if (hashMatch == null) {
    throw const FormatException('runtime `.u` has no `{id:"hash"}[e]+".js"` table');
  }
  final Map<String, String> hashes = _entries(hashMatch.group(1)!);
  if (hashes.isEmpty) throw const FormatException("runtime `.u` hash table is empty");

  // `||e)` is webpack's "use the id when there is no name" fallback. If it is present the table
  // in front of it must parse; falling back to bare ids would name files that do not exist.
  final RegExpMatch? nameMatch = _nameMap.firstMatch(uSection);
  if (nameMatch == null && uSection.contains("||e)")) {
    throw const FormatException("runtime `.u` has a name fallback but no parsable name table");
  }
  final Map<String, String> names =
      nameMatch == null ? const <String, String>{} : _entries(nameMatch.group(1)!);

  // The hash table covers every chunk, including the ones that only have a stylesheet. The runtime
  // skips those with a test in `.f.j` (`/^(…ids…)$/.test(id)`), so apply the same test; asking
  // for their `.js` would be a 404.
  final RegExp cssOnly = _cssOnlyIds(runtimeSource);
  final List<WebpackChunk> js = <WebpackChunk>[
    for (final MapEntry<String, String> h in hashes.entries)
      if (!cssOnly.hasMatch(h.key)) WebpackChunk(h.key, "${names[h.key] ?? h.key}.${h.value}.js"),
  ];

  final RegExpMatch? cssMatch = _cssHashes.firstMatch(runtimeSource.substring(css));
  if (cssMatch == null) {
    throw const FormatException('runtime `.miniCssF` has no `e+"."+{id:"hash"}[e]+".css"` table');
  }
  final Map<String, String> cssHashes = _entries(cssMatch.group(1)!);
  if (cssHashes.isEmpty) throw const FormatException("runtime `.miniCssF` hash table is empty");

  return WebpackChunks(
    js: js,
    languageJs: language,
    css: <String>[
      for (final MapEntry<String, String> h in cssHashes.entries) "${h.key}.${h.value}.css",
    ],
  );
}

/// The files `charting_library.standalone.js` writes into its iframe, relative to the library
/// directory (e.g. `bundles/runtime.<hash>.js`).
///
/// The loader embeds several `JSON.parse('[...]')` literals (locales, bundle list); the bundle
/// list is the one whose members all start with `bundles/`.
List<String> parseBundleList(String standaloneSource) {
  for (final RegExpMatch m in RegExp(r"JSON\.parse\('(\[[^']*\])'\)").allMatches(standaloneSource)) {
    final Object? decoded = jsonDecode(m.group(1)!);
    if (decoded is List<Object?> &&
        decoded.isNotEmpty &&
        decoded.every((Object? e) => e is String && e.startsWith("bundles/"))) {
      return decoded.cast<String>();
    }
  }
  throw const FormatException("no JSON.parse([...]) bundle list found in the library loader");
}

/// Replaces the `__LANG__` placeholder the runtime substitutes at request time.
String withLanguage(String chunkFile, String language) =>
    chunkFile.replaceAll("__LANG__", language);

/// Files a stylesheet references with `url(...)`, as written (relative to the stylesheet).
///
/// `data:` URIs and fragment-only references are skipped. Absolute `http(s):` and
/// protocol-relative references are returned unchanged so the caller can refuse or report them.
List<String> cssUrlReferences(String cssSource) {
  final Set<String> out = <String>{};
  for (final RegExpMatch m in RegExp(r"url\(\s*([^)]*?)\s*\)").allMatches(cssSource)) {
    String ref = m.group(1)!;
    if (ref.length >= 2 &&
        (ref.startsWith('"') && ref.endsWith('"') || ref.startsWith("'") && ref.endsWith("'"))) {
      ref = ref.substring(1, ref.length - 1);
    }
    if (ref.isEmpty || ref.startsWith("data:") || ref.startsWith("#")) continue;
    out.add(ref);
  }
  return out.toList();
}

/// Content-hashed asset file names (`name.<20 hex>.ext`) mentioned anywhere in [source].
///
/// Webpack emits fonts, cursors, images and sounds under such names and scripts refer to them by
/// string. This is a textual search, so it can name a file that is never requested; the caller
/// treats a name that does not resolve as a warning, not a failure.
List<String> hashedAssetNames(String source) => RegExp(
      r"[A-Za-z0-9_-]+\.[0-9a-f]{20}\.(?:woff2?|ttf|otf|eot|svg|png|jpe?g|gif|webp|cur|ico|mp3|ogg|wav|json|wasm)\b",
    ).allMatches(source).map((RegExpMatch m) => m.group(0)!).toSet().toList();
