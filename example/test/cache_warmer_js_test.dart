import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';
// The builder is deliberately not part of the public API; the test exercises it directly.
// ignore: implementation_imports
import 'package:ios_webview_plugin/src/cache_warmer_js.dart';

const String _base = 'https://h.example/chart/v4/RiseApp_Mobile.html';
const String _lib = 'https://h.example/chart/v1/Lib/';
String _u(String name) => '$_lib$name';
const String _manifest = 'https://h.example/chart/v4/chart-lib-manifest.json';

/// Runs the generated script under node against a mocked network. Skipped where node is missing.
Future<Map<String, Object?>?> _run(
  String script,
  Map<String, Object?> scenario,
) async {
  final Directory dir = await Directory.systemTemp.createTemp('warmer_test');
  try {
    final File scriptFile = File('${dir.path}/script.js')..writeAsStringSync(script);
    final File scenarioFile = File('${dir.path}/scenario.json')
      ..writeAsStringSync(jsonEncode(scenario));
    final ProcessResult r = await Process.run(
      'node',
      <String>['test/support/warmer_harness.js', scriptFile.path, scenarioFile.path],
    );
    if (r.exitCode != 0) fail('node failed: ${r.stderr}');
    return jsonDecode(r.stdout as String) as Map<String, Object?>;
  } on ProcessException {
    return null;
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<bool> _nodeAvailable() async {
  try {
    return (await Process.run('node', <String>['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Map<String, Object?> _report(Map<String, Object?> out) =>
    ((out['reports']! as List<Object?>).single! as Map<String, Object?>);

List<String> _fetched(Map<String, Object?> out) => (out['fetches']! as List<Object?>)
    .map((Object? f) => (f! as Map<String, Object?>)['url']! as String)
    .toList();

Map<String, Object?> _counts(Map<String, Object?> report) =>
    report['counts']! as Map<String, Object?>;

void main() {
  late bool hasNode;
  setUpAll(() async => hasNode = await _nodeAvailable());

  group('buildWarmerScript', () {
    test('escapes < so the script can sit inside an HTML script block', () {
      final String html = buildWarmerHtml(buildWarmerScript(
        baseUrl: _base,
        urls: <String>['x</script><b>.js'],
      ));
      expect(RegExp('</script>').allMatches(html).length, 1, reason: 'only the closing tag');
      expect(html, contains(r'</script>'));
    });
  });

  group('IosWebViewPlugin.warmWebCache never throws', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('webview_mo_flutter');

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('a malformed base URL comes back as a reason', () async {
      final Map<String, Object?> r =
          await IosWebViewPlugin.warmWebCache(baseUrl: 'http://[bad', urls: <String>['a.js']);
      expect(r['ok'], isFalse);
      expect(r['reason'], 'bad url');
    });

    test('a platform without the method reports unsupported', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final Map<String, Object?> r =
          await IosWebViewPlugin.warmWebCache(baseUrl: _base, urls: <String>['a.js']);
      expect(r, <String, Object?>{'ok': false, 'reason': 'unsupported'});
    });

    test('a native error and a silent native side are both reported, not thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall c) async {
        throw PlatformException(code: 'X', message: 'boom');
      });
      final Map<String, Object?> err =
          await IosWebViewPlugin.warmWebCache(baseUrl: _base, urls: <String>['a.js']);
      expect(err['reason'], 'platform error');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall c) async => null);
      final Map<String, Object?> none =
          await IosWebViewPlugin.warmWebCache(baseUrl: _base, urls: <String>['a.js']);
      expect(none['reason'], 'no reply');
    });

    test('sends everything native needs, with the manifest resolved next to the page', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall c) async {
        seen = c;
        return <Object?, Object?>{'ok': true};
      });
      final Map<String, Object?> r = await IosWebViewPlugin.warmWebCache(
        baseUrl: _base,
        timeout: const Duration(seconds: 90),
        mode: WarmMode.navigate,
      );
      expect(r['ok'], isTrue);
      final Map<Object?, Object?> args = seen!.arguments as Map<Object?, Object?>;
      expect(seen!.method, 'warmWebCache');
      expect(args['navigateUrl'], 'https://h.example/chart/v4/chart-lib-manifest.json');
      expect(args['mode'], 'navigate');
      expect(args['timeoutMs'], 90000);
      expect(args['html'] as String, contains('<script>'));
      expect(args['script'] as String, contains('__warmStarted'));
    });
  });

  group('warm script behaviour', () {
    test('fetches critical files first, de-duplicated, with the cache-compatible request shape',
        () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base),
        <String, Object?>{
          'routes': <String, Object?>{
            _manifest: <String, Object?>{
              'json': <String, Object?>{
                'version': 'v7',
                'files': <Object?>[
                  <String, Object?>{'path': '../v1/Lib/b.js'},
                  <String, Object?>{'path': '../v1/Lib/a.js', 'critical': true},
                  <String, Object?>{'path': '../v1/Lib/a.js', 'critical': true},
                  <String, Object?>{'path': '../v1/Lib/c.js'},
                ],
              },
            },
            _u('a.js'): <String, Object?>{},
            _u('b.js'): <String, Object?>{},
            _u('c.js'): <String, Object?>{},
          },
        },
      );
      if (out == null) return;
      final Map<String, Object?> r = _report(out);
      expect(r['ok'], isTrue, reason: '${r['reason']} ${r['errors']}');
      expect(r['manifestVersion'], 'v7');
      expect(r['files'], 3, reason: 'duplicate dropped');
      expect(_fetched(out), <String>[_manifest, _u('a.js'), _u('b.js'), _u('c.js')]);
      final Map<String, Object?> file = (out['fetches']! as List<Object?>)[1]! as Map<String, Object?>;
      // Must match a <script crossorigin="anonymous"> request, or the cache entry is not reused.
      expect(file['mode'], 'cors');
      expect(file['credentials'], 'same-origin');
      final Map<String, Object?> manifest =
          (out['fetches']! as List<Object?>)[0]! as Map<String, Object?>;
      expect(manifest['cache'], 'no-cache', reason: 'a stale manifest would warm stale files');
    });

    test('reads every body to the end, since an abandoned response is not cached', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: <String>[_u('a.js'), _u('b.js')]),
        <String, Object?>{
          'routes': <String, Object?>{
            _u('a.js'): <String, Object?>{'chunks': 5},
            _u('b.js'): <String, Object?>{'chunks': 0},
          },
        },
      );
      if (out == null) return;
      expect((out['drained']! as Map<String, Object?>).keys, unorderedEquals(<String>[_u('a.js'), _u('b.js')]));
    });

    test('never exceeds the concurrency cap', () async {
      if (!hasNode) markTestSkipped('node not available');
      final List<String> files = List<String>.generate(12, (int i) => _u('f$i.js'));
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: files, concurrency: 3),
        <String, Object?>{
          'routes': <String, Object?>{for (final String f in files) f: <String, Object?>{}},
        },
      );
      if (out == null) return;
      expect(out['maxInFlight'], 3);
      expect(_report(out)['ok'], isTrue);
    });

    test('a missing manifest is reported and nothing else is fetched', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base),
        <String, Object?>{'routes': <String, Object?>{}},
      );
      if (out == null) return;
      final Map<String, Object?> r = _report(out);
      expect(r['ok'], isFalse);
      expect(r['reason'], 'manifest missing');
      expect(_fetched(out), <String>[_manifest]);
    });

    test('a manifest of the wrong shape or an empty one is rejected', () async {
      if (!hasNode) markTestSkipped('node not available');
      for (final (Object? json, String reason) in <(Object?, String)>[
        (<String, Object?>{'files': 'nope'}, 'manifest invalid'),
        (<String, Object?>{'files': <Object?>[]}, 'manifest empty'),
      ]) {
        final Map<String, Object?>? out = await _run(
          buildWarmerScript(baseUrl: _base),
          <String, Object?>{
            'routes': <String, Object?>{_manifest: <String, Object?>{'json': json}},
          },
        );
        if (out == null) return;
        expect(_report(out)['reason'], reason);
        expect(_report(out)['ok'], isFalse);
      }
    });

    test('one failing file makes the run not ok but the others are still warmed', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: <String>[_u('a.js'), _u('gone.js'), _u('b.js')]),
        <String, Object?>{
          'routes': <String, Object?>{
            _u('a.js'): <String, Object?>{},
            _u('b.js'): <String, Object?>{},
          },
          'perf': <String, Object?>{
            _u('a.js'): <String, Object?>{'transferSize': 4000, 'encodedBodySize': 3900, 'decodedBodySize': 9000},
            _u('b.js'): <String, Object?>{'transferSize': 4000, 'encodedBodySize': 3900, 'decodedBodySize': 9000},
          },
        },
      );
      if (out == null) return;
      final Map<String, Object?> r = _report(out);
      expect(r['ok'], isFalse);
      expect(r['reason'], 'some files failed');
      expect(_counts(r)['failed'], 1);
      expect(_counts(r)['download'], 2, reason: 'the failed file is not also classified');
      expect(r['errors'], isNotEmpty);
    });

    test('stopping lets in-flight files finish, starts no new ones, and is not ok', () async {
      if (!hasNode) markTestSkipped('node not available');
      final List<String> files = List<String>.generate(9, (int i) => _u('f$i.js'));
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: files, concurrency: 3),
        <String, Object?>{
          'stopOnFirstFile': true,
          'routes': <String, Object?>{for (final String f in files) f: <String, Object?>{}},
        },
      );
      if (out == null) return;
      final Map<String, Object?> r = _report(out);
      expect(r['stopped'], isTrue);
      expect(r['ok'], isFalse);
      expect(r['reason'], 'stopped');
      expect(_fetched(out).length, lessThan(9), reason: 'later files were never requested');
      expect((out['drained']! as Map<String, Object?>).length, _fetched(out).length,
          reason: 'every file that started was read to the end');
    });

    test('classifies hit, revalidated, download and missing timing entries', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(
          baseUrl: _base,
          urls: <String>[_u('hit.js'), _u('nm.js'), _u('dl.js'), _u('none.js'), _u('cache.js')],
        ),
        <String, Object?>{
          'routes': <String, Object?>{
            for (final String n in <String>['hit', 'nm', 'dl', 'none', 'cache'])
              _u('$n.js'): <String, Object?>{},
          },
          'perf': <String, Object?>{
            _u('hit.js'): <String, Object?>{'transferSize': 0, 'encodedBodySize': 5000, 'decodedBodySize': 9000},
            _u('nm.js'): <String, Object?>{'transferSize': 300, 'encodedBodySize': 5000, 'decodedBodySize': 9000},
            _u('dl.js'): <String, Object?>{'transferSize': 5300, 'encodedBodySize': 5000, 'decodedBodySize': 9000},
            _u('cache.js'): <String, Object?>{'deliveryType': 'cache', 'transferSize': 0, 'decodedBodySize': 1},
          },
        },
      );
      if (out == null) return;
      final Map<String, Object?> r = _report(out);
      expect(_counts(r), <String, Object?>{
        'hit': 2, 'revalidated': 1, 'download': 1, 'opaque': 1, 'failed': 0,
      });
      expect(r['bytesTransfer'], 5600);
    });

    test('reports the origin it actually ran on', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: <String>[_u('a.js')]),
        <String, Object?>{
          'origin': 'null',
          'routes': <String, Object?>{_u('a.js'): <String, Object?>{}},
        },
      );
      if (out == null) return;
      expect(_report(out)['origin'], 'null', reason: 'a caller can then reject a wrong-origin page');
    });

    test('injecting the script twice runs it once', () async {
      if (!hasNode) markTestSkipped('node not available');
      final Map<String, Object?>? out = await _run(
        buildWarmerScript(baseUrl: _base, urls: <String>[_u('a.js')]),
        <String, Object?>{
          'runTwice': true,
          'routes': <String, Object?>{_u('a.js'): <String, Object?>{}},
        },
      );
      if (out == null) return;
      expect((out['reports']! as List<Object?>).length, 1);
      expect(_fetched(out), <String>[_u('a.js')]);
    });
  });
}
