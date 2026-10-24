// The library census must see the chart's files on every server layout the app talks to.
//
// UAT serves the chart under `/chart/`, production under `/charts/`. The census (which says how many
// library files were cached and how many downloaded) matched only `/chart/`, so against the hosted
// production page it counted nothing and a comparison with the bundled page would have read "no
// library files" for the page that downloads the most. The real snippet is run under node against
// fake Resource Timing entries. Skipped where node is missing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/service/js_snippets.dart';

const String _runner = r'''
const vm = require("node:vm");
const script = JSON.parse(process.argv[1]);
const entries = JSON.parse(process.argv[2]);
const out = [];
vm.runInNewContext(script, {
  window: { performance: { getEntriesByType: () => entries } },
  document: { querySelectorAll: () => [] },
  URL,
  __hb: (run, name, detail) => out.push({ name, detail }),
});
console.log(JSON.stringify(out));
''';

Map<String, Object?> _entry(String url, {int transfer = 0, int encoded = 0, int decoded = 0, String type = 'script'}) =>
    <String, Object?>{
      'name': url,
      'initiatorType': type,
      'transferSize': transfer,
      'encodedBodySize': encoded,
      'decodedBodySize': decoded,
      'startTime': 1,
      'duration': 1,
    };

Map<String, Object?> _census(List<Map<String, Object?>> entries) {
  final ProcessResult r = Process.runSync('node', <String>[
    '-e',
    _runner,
    jsonEncode(buildLibCacheJs('r1', 'test')),
    jsonEncode(entries),
  ]);
  if (r.exitCode != 0) fail('node failed: ${r.stderr}');
  final List<Object?> sent = jsonDecode((r.stdout as String).trim()) as List<Object?>;
  expect(sent, hasLength(1));
  return ((sent.single as Map<String, Object?>)['detail'] as Map<String, Object?>);
}

void main() {
  final bool hasNode = Process.runSync('node', <String>['--version']).exitCode == 0;
  final String? skip = hasNode ? null : 'node is not on PATH';

  const String lib = 'Libraries/Paid_libraries/TT_v29_1_0/bundles';

  for (final MapEntry<String, String> server in <String, String>{
    'UAT (/chart/)': 'https://uat.example/chart',
    'production (/charts/)': 'https://prod.example/charts',
    'the bundled page (/chart/ on the app host)': 'https://appassets.androidplatform.net/chart',
  }.entries) {
    test('counts the library files served from ${server.key}', () {
      final String root = server.value;
      final Map<String, Object?> detail = _census(<Map<String, Object?>>[
        _entry('$root/v1/$lib/library.js', transfer: 900000, encoded: 900000, decoded: 2700000),
        _entry('$root/v1/$lib/runtime.js', transfer: 0, decoded: 50000),
        _entry('$root/v4/js/main.js', transfer: 0, decoded: 70000),
        // Not static files: the page's own API calls, and something from elsewhere.
        _entry('$root/api/Chart/HistoryV3?x=1', transfer: 4000, encoded: 4000, decoded: 9000, type: 'fetch'),
        _entry('https://elsewhere.example/other.js', transfer: 100, encoded: 100, decoded: 100),
      ]);

      final Map<String, Object?> summary = detail['summary'] as Map<String, Object?>;
      expect(summary['download'], 1, reason: 'library.js came over the network');
      expect(summary['hit'], 2, reason: 'runtime.js and main.js were already there');
      expect(summary['entries'], 3, reason: 'neither the API call nor the other host is a chart file');
      expect(detail['key'], <String, Object?>{
        'library.js': 'download',
        'runtime.js': 'hit',
        'main.js': 'hit',
      }, reason: 'the file names are cut after the server prefix, whichever prefix it is');
    }, skip: skip);
  }

  test('a path that merely contains "chart" is not a chart path', () {
    final Map<String, Object?> detail = _census(<Map<String, Object?>>[
      _entry('https://h.example/mycharts/v1/a.js', transfer: 100, encoded: 100, decoded: 100),
      _entry('https://h.example/chartsx/v1/b.js', transfer: 100, encoded: 100, decoded: 100),
    ]);

    expect((detail['summary'] as Map<String, Object?>)['entries'], 0);
  }, skip: skip);
}
