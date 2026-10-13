import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/config/endpoints.dart';
import 'package:ios_webview_plugin_example/src/model/bench_models.dart';
import 'package:ios_webview_plugin_example/src/regression/cache_census.dart';
import 'package:ios_webview_plugin_example/src/regression/expectation.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario_catalog.dart';
import 'package:ios_webview_plugin_example/src/service/js_snippets.dart';

// Shaped like the platform channel delivers it: nested maps are Map<Object?, Object?>.
Map<String, Object?> _raw({int ts = 1000000, bool truncated = false}) => <String, Object?>{
      'ts': ts,
      'truncated': truncated,
      'codeCache': <Object?, Object?>{'bytes': 4096, 'files': 3},
      'roots': <Object?>[
        <Object?, Object?>{
          'root': 'cache/WebView',
          'totalBytes': 5000000,
          'groups': <Object?, Object?>{
            'Default/HTTP Cache': <Object?, Object?>{
              'bytes': 4800000,
              'files': 120,
              'oldestMtime': ts - 7200000,
              'newestMtime': ts - 60000,
            },
            'Default/Code Cache': <Object?, Object?>{'bytes': 4096, 'files': 3},
          },
        },
        <Object?, Object?>{
          'root': 'data/app_webview',
          'totalBytes': 90000,
          'groups': <Object?, Object?>{
            'Default/Local Storage': <Object?, Object?>{
              'bytes': 90000,
              'files': 4,
              'oldestMtime': 1,
              'newestMtime': 2,
            },
          },
        },
      ],
    };

void main() {
  group('summarizeCacheStats', () {
    test('sums only the HTTP cache group and measures ages against the census clock', () {
      final Map<String, Object?> s = summarizeCacheStats(_raw());
      expect(s['httpBytes'], 4800000);
      expect(s['httpFiles'], 120);
      expect(s['httpNewestAgeS'], 60);
      expect(s['httpOldestAgeS'], 7200);
      expect(s['cacheBytes'], 5000000);
      expect(s['dataBytes'], 90000);
      expect(s['codeBytes'], 4096);
    });

    test('Local Storage mtimes do not leak into the HTTP cache ages', () {
      // Its mtimes are 1 and 2: if they were folded in, oldest age would be ~1000s of years.
      expect(summarizeCacheStats(_raw())['httpOldestAgeS'], 7200);
    });

    test('an empty or malformed census yields an empty or null summary, never a throw', () {
      expect(summarizeCacheStats(<String, Object?>{}), isEmpty);
      final Map<String, Object?> s =
          summarizeCacheStats(<String, Object?>{'ts': 5, 'roots': 'nope'});
      expect(s['httpBytes'], isNull);
      expect(formatCensus(<String, Object?>{}), 'census=unavailable');
    });

    test('a wiped cache reports zero files rather than being omitted', () {
      final Map<String, Object?> raw = _raw();
      ((raw['roots']! as List<Object?>).first! as Map<Object?, Object?>)['groups'] =
          <Object?, Object?>{
        'Default/HTTP Cache': <Object?, Object?>{
          'bytes': 0,
          'files': 0,
          'oldestMtime': null,
          'newestMtime': null,
        },
      };
      final Map<String, Object?> s = summarizeCacheStats(raw);
      expect(s['httpFiles'], 0);
      expect(s['httpNewestAgeS'], isNull);
    });

    test('reads the WebKit layout too: NetworkCache is the HTTP cache, two cache roots add up', () {
      final Map<String, Object?> s = summarizeCacheStats(<String, Object?>{
        'ts': 1000000,
        'roots': <Object?>[
          <Object?, Object?>{
            'root': 'Library/Caches/<bundle>/WebKit',
            'totalBytes': 2000,
            'groups': <Object?, Object?>{
              'NetworkCache/Version 17': <Object?, Object?>{
                'bytes': 1900,
                'files': 7,
                'oldestMtime': 940000,
                'newestMtime': 990000,
              },
            },
          },
          <Object?, Object?>{'root': 'Library/Caches/WebKit', 'totalBytes': 50, 'groups': <Object?, Object?>{}},
          <Object?, Object?>{'root': 'Library/WebKit/<bundle>', 'totalBytes': 300, 'groups': <Object?, Object?>{}},
        ],
      });
      expect(s['httpBytes'], 1900);
      expect(s['httpFiles'], 7);
      expect(s['httpNewestAgeS'], 10);
      expect(s['cacheBytes'], 2050);
      expect(s['dataBytes'], 300);
    });

    test('truncation is surfaced', () {
      expect(formatCensus(summarizeCacheStats(_raw(truncated: true))), contains('TRUNCATED'));
    });
  });

  group('formatLibCache', () {
    test('renders counts and strips content hashes from file names', () {
      final String line = formatLibCache(<String, Object?>{
        'summary': <Object?, Object?>{
          'hit': 3,
          'revalidated': 1,
          'download': 2,
          'opaque': 0,
          'capped': false,
          'blockedFrames': 0,
          'bytesTransfer': 1048576,
          'bytesDecoded': 3145728,
        },
        'key': <Object?, Object?>{'library.47eb07e437b7b06c889a.js': 'download'},
      });
      expect(line, 'lib=h3/r1/d2/o0 xfer=1.00 MB/3.00 MBdec [library.js=download]');
    });

    test('flags a capped timeline and blocked frames, since the counts are then a lower bound', () {
      final String line = formatLibCache(<String, Object?>{
        'summary': <Object?, Object?>{
          'hit': 1,
          'revalidated': 0,
          'download': 0,
          'opaque': 0,
          'capped': true,
          'blockedFrames': 2,
        },
      });
      expect(line, contains('CAPPED'));
      expect(line, contains('blockedFrames=2'));
    });

    test('a page-side error is reported, not swallowed', () {
      expect(formatLibCache(<String, Object?>{'error': 'boom'}), 'lib=error(boom)');
      expect(formatLibCache(<String, Object?>{}), 'lib=unavailable');
    });
  });

  group('formatWarmReport', () {
    test('renders a successful report on one line', () {
      final String line = formatWarmReport(<String, Object?>{
        'ok': true,
        'origin': 'https://h.example',
        'files': 115,
        'counts': <Object?, Object?>{
          'hit': 0, 'revalidated': 0, 'download': 115, 'opaque': 0, 'failed': 0,
        },
        'bytesTransfer': 1824000,
        'bytesDecoded': 5380000,
        'durationMs': 41000,
      });
      expect(line, contains('ok=true'));
      expect(line, contains('origin=https://h.example'));
      expect(line, contains('h0/r0/d115/o0/f0'));
      expect(line, contains('41000ms'));
      expect(line, isNot(contains('reason=')));
    });

    test('a failure carries its reason and first error; an empty reply is not hidden', () {
      final String line = formatWarmReport(<String, Object?>{
        'ok': false,
        'reason': 'some files failed',
        'errors': <Object?>['a.js: HTTP 404'],
      });
      expect(line, contains('ok=false reason=some files failed'));
      expect(line, contains('firstError=a.js: HTTP 404'));
      expect(formatWarmReport(<String, Object?>{}), 'warm=no report');
    });
  });

  group('cache warm-up cases', () {
    final List<Scenario> catalog = buildCatalog();
    Scenario byId(String id) => catalog.firstWhere((Scenario s) => s.id == id);
    Expectation exp(String id, int i) => byId(id).expectations[i];

    ScenarioObservations obs({
      Map<String, Object?>? warm,
      Map<String, Object?>? afterWarm,
      Map<String, Object?>? settled,
    }) {
      final ScenarioObservations o = ScenarioObservations();
      if (warm != null) o.probes['warm'] = warm;
      if (afterWarm != null) o.probes['afterWarm'] = afterWarm;
      if (settled != null) o.probes['settled'] = settled;
      return o;
    }

    Map<String, Object?> settled({int entries = 100, int download = 0, int xfer = 10000}) =>
        <String, Object?>{
          'entries': entries,
          'download': download,
          'bytesTransfer': xfer,
          'files': <String>['library.47eb07e437b7b06c889a.js'],
        };

    test('the warm-up must run on the chart origin, not merely succeed', () {
      final Expectation e = exp('W0', 0);
      final String origin = Uri.parse(kChartUrl).origin;
      expect(e.evaluate(obs(warm: <String, Object?>{'ok': true, 'origin': origin})).pass, isTrue);
      expect(e.evaluate(obs(warm: <String, Object?>{'ok': true, 'origin': 'null'})).pass, isFalse,
          reason: 'an opaque-origin page would fill the wrong cache partition');
      expect(e.evaluate(obs(warm: <String, Object?>{'ok': false, 'origin': origin})).pass, isFalse);
      expect(e.evaluate(obs()).pass, isFalse);
    });

    test('the warm-up must leave real data in the HTTP cache', () {
      final Expectation e = exp('W0', 1);
      expect(e.evaluate(obs(afterWarm: <String, Object?>{'httpBytes': 2500000})).pass, isTrue);
      expect(e.evaluate(obs(afterWarm: <String, Object?>{'httpBytes': 100})).pass, isFalse);
      expect(e.evaluate(obs(afterWarm: <String, Object?>{})).pass, isFalse);
    });

    test('served-from-cache allows few downloads and little transfer, and nothing more', () {
      final Expectation e = exp('W2', 0);
      expect(e.evaluate(obs(settled: settled())).pass, isTrue);
      expect(e.evaluate(obs(settled: settled(download: 5))).pass, isTrue, reason: '5% of 100');
      expect(e.evaluate(obs(settled: settled(download: 6))).pass, isFalse);
      expect(e.evaluate(obs(settled: settled(xfer: 175000))).pass, isTrue);
      expect(e.evaluate(obs(settled: settled(xfer: 175001))).pass, isFalse);
      expect(e.evaluate(obs()).pass, isFalse);
    });

    test('served-from-cache is not satisfied by a run that never loaded the library bundle', () {
      final Map<String, Object?> noLibrary = settled()..['files'] = <String>['main.js'];
      expect(exp('W2', 0).evaluate(obs(settled: noLibrary)).pass, isFalse);
    });

    test('W1 is the new-install case, W2 follows a process kill, W0 needs no host', () {
      expect(byId('W0').precondition, isNull);
      expect(byId('W1').precondition, ExternalPrecondition.fullCold);
      expect(byId('W2').precondition, ExternalPrecondition.processDeath);
      expect(byId('W1').steps.whereType<WarmLibCache>(), hasLength(1));
      expect(byId('W1').steps.whereType<OpenChart>(), hasLength(1));
    });

    test('a second warm-up must be served from cache, not just succeed', () {
      Map<String, Object?> warm({int downloads = 0, int xfer = 1000, bool ok = true}) =>
          <String, Object?>{
            'ok': ok,
            'files': 115,
            'counts': <Object?, Object?>{'download': downloads},
            'bytesTransfer': xfer,
          };
      final Expectation e = exp('W3', 1);
      ScenarioObservations with2(Map<String, Object?> w) => ScenarioObservations()..probes['warm2'] = w;
      expect(e.evaluate(with2(warm())).pass, isTrue);
      expect(e.evaluate(with2(warm(downloads: 5))).pass, isTrue, reason: '5 of 115 is under 5%');
      expect(e.evaluate(with2(warm(downloads: 6))).pass, isFalse);
      expect(e.evaluate(with2(warm(xfer: 175001))).pass, isFalse);
      expect(e.evaluate(with2(warm(ok: false))).pass, isFalse);
      expect(e.evaluate(ScenarioObservations()).pass, isFalse);
    });

    test('the race case fails when the warm-up and the open each download everything', () {
      final Expectation e = exp('W4', 2);
      ScenarioObservations total(int warmed, int opened) => ScenarioObservations()
        ..probes['warm'] = <String, Object?>{'bytesTransfer': warmed}
        ..probes['settled'] = <String, Object?>{'bytesTransfer': opened};
      expect(e.evaluate(total(1740000, 0)).pass, isTrue, reason: 'one cold load, shared');
      expect(e.evaluate(total(1000000, 1200000)).pass, isTrue, reason: 'some overlap is fine');
      expect(e.evaluate(total(1740000, 1740000)).pass, isFalse, reason: 'a full duplicate');
    });

    test('the manifest case needs the reason, and an empty cache', () {
      ScenarioObservations with0(Map<String, Object?> warm, int bytes) => ScenarioObservations()
        ..probes['warm'] = warm
        ..probes['afterWarm'] = <String, Object?>{'httpBytes': bytes};
      final Expectation missing = exp('W5', 0);
      final Expectation empty = exp('W5', 1);
      final Map<String, Object?> reported = <String, Object?>{'ok': false, 'reason': 'manifest missing'};
      expect(missing.evaluate(with0(reported, 0)).pass, isTrue);
      expect(missing.evaluate(with0(<String, Object?>{'ok': false, 'reason': 'timeout'}, 0)).pass, isFalse);
      expect(empty.evaluate(with0(reported, 2500000)).pass, isFalse, reason: 'it must not have downloaded');
      expect(empty.evaluate(with0(reported, 20000)).pass, isTrue);
    });

    test('W4 starts the warm-up in the background and joins it after the open', () {
      final List<ScenarioStep> steps = byId('W4').steps;
      expect((steps.first as WarmLibCache).background, isTrue);
      expect(steps.indexWhere((ScenarioStep s) => s is OpenChart),
          lessThan(steps.indexWhere((ScenarioStep s) => s is AwaitWarm)));
    });

    test('the capture case asserts it found a plausible number of files', () {
      final Expectation e = byId('WC').expectations.single;
      final ScenarioObservations few = ScenarioObservations()
        ..probes['libUrls'] = <String, Object?>{'count': 3, 'error': null};
      final ScenarioObservations many = ScenarioObservations()
        ..probes['libUrls'] = <String, Object?>{'count': 115, 'error': null};
      expect(e.evaluate(few).pass, isFalse);
      expect(e.evaluate(many).pass, isTrue);
    });
  });

  group('cache study cases', () {
    final List<Scenario> catalog = buildCatalog();
    Scenario byId(String id) => catalog.firstWhere((Scenario s) => s.id == id);

    test('K1-K3 each carry a host precondition, K0 (the primer) carries none', () {
      expect(byId('K0').precondition, isNull);
      expect(byId('K1').precondition, ExternalPrecondition.processDeath);
      expect(byId('K2').precondition, ExternalPrecondition.forceStop);
      expect(byId('K3').precondition, ExternalPrecondition.cacheTrimmed);
    });

    test('a run that only loaded page scripts does not count as a measurement', () {
      Map<String, Object?> probe(List<String> files) =>
          <String, Object?>{'entries': files.length, 'files': files};
      bool passes(Map<String, Object?>? settled) {
        final ScenarioObservations o = ScenarioObservations();
        if (settled != null) o.probes['settled'] = settled;
        return byId('K1').expectations.single.evaluate(o).pass;
      }

      expect(passes(probe(<String>['main.js', 'static_config.js'])), isFalse);
      expect(passes(probe(<String>[])), isFalse);
      expect(passes(<String, Object?>{'error': 'boom'}), isFalse);
      expect(passes(null), isFalse);
      expect(passes(probe(<String>['main.js', 'library.47eb07e437b7b06c889a.js'])), isTrue);
    });

    test('every one waits for the library to stop arriving, with a raised time budget', () {
      for (final String id in <String>['K0', 'K1', 'K2', 'K3']) {
        final List<ScenarioStep> steps = byId(id).steps;
        expect(steps.whereType<WaitForLibQuiet>(), hasLength(1), reason: id);
        expect(steps.whereType<OpenChart>().single.budgetScale, greaterThan(1), reason: id);
      }
    });

    test('every one censuses before and after, and probes the library after settling', () {
      for (final String id in <String>['K0', 'K1', 'K2', 'K3']) {
        final List<ScenarioStep> steps = byId(id).steps;
        expect(steps.first, isA<CacheCensus>(), reason: '$id must census at launch first');
        expect(steps.last, isA<CacheCensus>(), reason: '$id must census at the end');
        expect(steps.whereType<LibCacheProbe>(), isNotEmpty, reason: id);
      }
    });
  });

  group('RunConfig.budgetScale', () {
    test('defaults to 1 so no existing case changes, and survives copying', () {
      expect(const RunConfig(symbol: 'a').budgetScale, 1.0);
      expect(const RunConfig(symbol: 'a', budgetScale: 12).withSymbol('b').budgetScale, 12);
    });
  });

  group('library harvest snippet', () {
    test('walks child iframes, since the library loads its bundles there', () {
      final String js = buildNavTimingJs('r1');
      expect(js, contains('querySelectorAll("iframe")'));
      expect(js, contains('libSummary'));
      // The pre-existing top-window fields must survive the change.
      expect(js, contains('bytesTransfer'));
      expect(js, contains('docTransfer'));
    });

    test('the standalone probe reports under its own phase', () {
      expect(buildLibCacheJs('r1', 'settled'), contains('"libCache"'));
    });
  });
}
