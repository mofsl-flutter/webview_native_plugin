import "package:flutter_test/flutter_test.dart";

import "../tool/src/sha256.dart";
import "../tool/src/webpack_runtime.dart";

/// Same shape as the real `bundles/runtime.<hash>.js` of the charting library: language chunks as
/// a ternary chain, then `(({id:"name",...}[e]||e)+"."+{id:"hash"}[e]+".js"`, with a newline after
/// the opening brace of the name table (which an earlier version of the parser tripped on).
const String _runtime = r'''
!function(){var o={};o.u=e=>2970===e?"__LANG__.2970.192d64e32a7edae012d7.js":1904===e?"__LANG__.1904.b23c76f1dd4da22ffcf5.js":(({
92:"chart-screenshot-hint",139:"get-error-card"}[e]||e)+"."+{92:"9f3a96d769a1e33cd974",139:"a031f39f01dfc4896f5c",195:"949d4976aef94aeb9c1a"}[e]+".js"),o.miniCssF=e=>e+"."+{303:"e9b6e523eb66dacf92bd",422:"bc23975c348a4f41dea4"}[e]+".css",o.f.j=(a,c)=>{var d=o.o(e,a)?e[a]:void 0;if(0!==d)if(d)c.push(d[2]);else if(/^(195)$/.test(a))e[a]=0;else{}},o.g=function(){}}();
''';

void main() {
  group("sha256Hex", () {
    test("matches the published vectors", () {
      expect(sha256Hex("abc".codeUnits),
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
      expect(sha256Hex(const <int>[]),
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
      // Crosses a block boundary: 1000 bytes is 16 blocks with the padding in the last one.
      expect(sha256Hex(List<int>.filled(1000, 0x61)),
          "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
    });
  });

  group("parseWebpackRuntime", () {
    test("names chunks from the name table", () {
      final WebpackChunks c = parseWebpackRuntime(_runtime);
      expect(c.js.map((WebpackChunk k) => k.file), <String>[
        "chart-screenshot-hint.9f3a96d769a1e33cd974.js",
        "get-error-card.a031f39f01dfc4896f5c.js",
      ]);
    });

    test("falls back to the id for an unnamed chunk that has a script", () {
      // 195 has a hash and no name; here it is not CSS-only, so it is a script named by its id.
      final String runtime = _runtime.replaceAll("/^(195)\$/", "/^(999)\$/");
      expect(parseWebpackRuntime(runtime).js.map((WebpackChunk k) => k.file),
          contains("195.949d4976aef94aeb9c1a.js"));
    });

    test("leaves out chunks the runtime marks as having no script", () {
      // The hash table lists every chunk; asking for the .js of a stylesheet-only one is a 404.
      expect(parseWebpackRuntime(_runtime).js.any((WebpackChunk k) => k.id == "195"), isFalse);
    });

    test("refuses a runtime with no CSS-only test, rather than guessing", () {
      final String broken = _runtime.replaceAll("/^(195)\$/.test(a)", "false");
      expect(() => parseWebpackRuntime(broken), throwsFormatException);
    });

    test("keeps language chunks with the placeholder and lists stylesheets by id", () {
      final WebpackChunks c = parseWebpackRuntime(_runtime);
      expect(c.languageJs, <String>[
        "__LANG__.2970.192d64e32a7edae012d7.js",
        "__LANG__.1904.b23c76f1dd4da22ffcf5.js",
      ]);
      expect(c.css, <String>[
        "303.e9b6e523eb66dacf92bd.css",
        "422.bc23975c348a4f41dea4.css",
      ]);
      expect(withLanguage(c.languageJs.first, "en"), "en.2970.192d64e32a7edae012d7.js");
    });

    test("refuses a runtime whose name fallback has no parsable table", () {
      // Falling back to bare ids here would name files that do not exist.
      final String broken = _runtime.replaceAll('{\n92:"chart-screenshot-hint",139:"get-error-card"}[e]||e', "X||e");
      expect(() => parseWebpackRuntime(broken), throwsFormatException);
    });

    test("refuses a runtime missing either table", () {
      expect(() => parseWebpackRuntime("nothing here"), throwsFormatException);
      expect(() => parseWebpackRuntime(_runtime.replaceAll("o.miniCssF=", "o.other=")),
          throwsFormatException);
      expect(() => parseWebpackRuntime(_runtime.replaceAll('.js"),o.miniCssF', '.mjs"),o.miniCssF')),
          throwsFormatException);
    });
  });

  group("parseBundleList", () {
    test("picks the bundle list and ignores the locale table", () {
      const String src = '''
        var l=JSON.parse('[{"iso":"en","dir":"ltr","language":"en"}]');
        var b=JSON.parse('["bundles/runtime.aa.js","bundles/__LANG__.344.bb.js","bundles/4986.cc.css"]');
      ''';
      expect(parseBundleList(src),
          <String>["bundles/runtime.aa.js", "bundles/__LANG__.344.bb.js", "bundles/4986.cc.css"]);
    });

    test("throws when there is none", () {
      expect(() => parseBundleList("JSON.parse('[1,2]')"), throwsFormatException);
    });
  });

  group("references", () {
    test("cssUrlReferences skips data URIs and fragments, unquotes, and keeps absolute urls", () {
      const String css = '''
        a{background:url(dot.3d617b6b01edba83a7f4.cur)}
        b{src:url("EuclidCircular.be8f862db48c2976009f.woff2") format("woff2")}
        c{background:url( 'x.svg' )} d{background:url(data:image/png;base64,AAA)}
        e{filter:url(#blur)} f{background:url(https://cdn.example/x.png)}
      ''';
      expect(cssUrlReferences(css), <String>[
        "dot.3d617b6b01edba83a7f4.cur",
        "EuclidCircular.be8f862db48c2976009f.woff2",
        "x.svg",
        "https://cdn.example/x.png",
      ]);
    });

    test("hashedAssetNames finds content-hashed assets and nothing else", () {
      const String js = 'a="eraser.c80610a04a92d2465b03.cur";b="library.47eb07e437b7b06c889a.js";'
          'c="plain.png";d="x.0123456789abcdef0123.svg"';
      expect(hashedAssetNames(js)..sort(),
          <String>["eraser.c80610a04a92d2465b03.cur", "x.0123456789abcdef0123.svg"]);
    });
  });
}
