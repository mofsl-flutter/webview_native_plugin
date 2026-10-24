// Case L5: the bundled page opens in a WebView profile the hosted page used first.
//
// Production's Symbols (2 h) and Config (6 h) are cacheable and carry their CORS header only when the
// request has an Origin, so a copy stored by the hosted page (same-origin, no Origin) is served to
// the bundled page's CORS request, which fails and reports SymbolNotFound. This is the case that
// would have caught it; these tests check the case itself, against observations built by hand: a
// good run passes, and every way the poisoned run can look fails.
// Run it twice: plainly, and with `flutter test --dart-define=CHART_LOCAL=true`. In a hosted build
// "follow the build" and "force the hosted page" are the same URL, so the check that `pageUrl` uses
// the decision at all only bites in the second run.
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/config/endpoints.dart';
import 'package:ios_webview_plugin_example/src/model/bench_models.dart';
import 'package:ios_webview_plugin_example/src/regression/expectation.dart';
import 'package:ios_webview_plugin_example/src/regression/local_bundle_scenarios.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario_runner.dart';
import 'package:ios_webview_plugin_example/src/service/bench_runner.dart';

Scenario get _l5 => localBundleScenarios.firstWhere((Scenario s) => s.id == 'L5');

String _origin(String url) {
  final Uri u = Uri.parse(url);
  return '${u.scheme}://${u.host}';
}

final String _hostedOrigin = _origin(chartPageUrl(local: false));
final String _bundledOrigin = _origin(chartPageUrl(local: true));

RunRecord _record(TerminalOutcome outcome) => RunRecord(
      runId: 'r',
      config: const RunConfig(symbol: '1:500125'),
      outcome: outcome,
      startedAt: DateTime(2026, 10, 24),
      marks: const <String, int>{},
    );

Map<String, Object?> _probe({required String origin, bool ready = true, Object? bars = 300, Object? retry}) =>
    <String, Object?>{'origin': origin, 'widgetReady': ready, 'bars': bars, 'netRetry': retry};

/// A run where everything went right.
ScenarioObservations _good() => ScenarioObservations()
  ..records.addAll(<RunRecord>[_record(TerminalOutcome.chartSuccess), _record(TerminalOutcome.chartSuccess)])
  ..probes['hosted'] = _probe(origin: _hostedOrigin)
  ..probes['bundled'] = _probe(
    origin: _bundledOrigin,
    retry: <String, Object?>{'retried': 2, 'recovered': 2, 'failed': 0},
  );

/// The verdict of each expectation except the one that needs a build flag, by description.
Map<String, bool> _verdicts(ScenarioObservations o) => <String, bool>{
      for (final Expectation e in _l5.expectations)
        if (!e.description.contains('CHART_LOCAL')) e.description: e.evaluate(o).pass,
    };

void main() {
  test('is in the catalog, opens the hosted page and then the bundled one, and probes both', () {
    final List<ScenarioStep> steps = _l5.steps;
    final List<OpenChart> opens = steps.whereType<OpenChart>().toList();

    expect(opens, hasLength(2));
    expect(opens[0].forceHosted, isTrue);
    expect(opens[1].forceHosted, isFalse);
    expect(steps.indexOf(opens[0]), lessThan(steps.indexOf(opens[1])));
    expect(steps.whereType<Probe>().map((Probe p) => p.label), <String>['hosted', 'bundled']);
    expect(_l5.precondition, ExternalPrecondition.fullCold, reason: 'it starts from an empty profile');
  });

  test('a good run passes every expectation', () {
    final Map<String, bool> v = _verdicts(_good());

    expect(v, isNotEmpty);
    expect(v.values, everyElement(isTrue), reason: '$v');
  });

  test('requires CHART_LOCAL: on a hosted-only build the case says so instead of passing', () {
    final Expectation local =
        _l5.expectations.firstWhere((Expectation e) => e.description.contains('CHART_LOCAL'));

    expect(local.evaluate(_good()).pass, kChartLocal);
  });

  group('the poisoned run fails', () {
    test('when the bundled open ends in SymbolNotFound, with no bars', () {
      final ScenarioObservations o = _good();
      o.records[1] = _record(TerminalOutcome.chartErrorSymbolNotFound);
      o.probes['bundled'] = _probe(origin: _bundledOrigin, ready: true, bars: 0);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the bundled open ended in SymbolNotFound even though the page looks healthy', () {
      // The outcome is the page's own verdict; it must not be overruled by a probe that happens to look fine.
      final ScenarioObservations o = _good();
      o.records[1] = _record(TerminalOutcome.chartErrorSymbolNotFound);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the bundled open succeeded but drew no candles', () {
      final ScenarioObservations o = _good();
      o.probes['bundled'] = _probe(origin: _bundledOrigin, bars: 0);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the widget is not ready', () {
      final ScenarioObservations o = _good();
      o.probes['bundled'] = _probe(origin: _bundledOrigin, ready: false);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the first open did not succeed, so the cache was never filled the way the case needs', () {
      final ScenarioObservations o = _good();
      o.records[0] = _record(TerminalOutcome.timeout);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the first open was not the hosted page', () {
      final ScenarioObservations o = _good();
      o.probes['hosted'] = _probe(origin: _bundledOrigin);

      expect(_verdicts(o).values, contains(false));
    });

    test('when the second open was not the bundled page', () {
      final ScenarioObservations o = _good();
      o.probes['bundled'] = _probe(origin: _hostedOrigin);

      expect(_verdicts(o).values, contains(false));
    });

    test('when only one open happened', () {
      final ScenarioObservations o = _good()..records.removeLast();

      expect(_verdicts(o).values, contains(false));
    });

    test('when a probe is missing', () {
      final ScenarioObservations o = _good()..probes.remove('bundled');

      expect(_verdicts(o).values, contains(false));
    });

    test('and nothing at all passes with nothing observed', () {
      expect(_verdicts(ScenarioObservations()).values, everyElement(isFalse));
    });
  });

  group('forceHosted reaches the run', () {
    test('from the step into the run configuration, with every other field too', () {
      const OpenChart step = OpenChart(
        '1:500125',
        authorizeFirst: false,
        neverAuthorize: true,
        chartMode: 'LightWeightChart',
        budgetScale: 4,
        prefetch: true,
        hideLastBars: 3,
        forceHosted: true,
      );

      final RunConfig c = runConfigFor(step);

      expect(c.forceHosted, isTrue);
      expect(c.symbol, '1:500125');
      expect(c.authorizeFirst, isFalse);
      expect(c.neverAuthorize, isTrue);
      expect(c.chartMode, 'LightWeightChart');
      expect(c.budgetScale, 4);
      expect(c.prefetch, isTrue);
      expect(c.hideLastBars, 3);
    });

    test('and is off unless asked for', () {
      expect(runConfigFor(const OpenChart('1:500125')).forceHosted, isFalse);
    });

    test('the decision: hosted when asked, otherwise whatever the build was started with', () {
      expect(BenchRunner.localFor(const RunConfig(symbol: 'x', forceHosted: true)), isFalse);
      expect(BenchRunner.localFor(const RunConfig(symbol: 'x')), isNull,
          reason: 'null means follow the build; false would force the hosted page on every run');
    });

    test('the URL a run loads is built from that decision', () {
      for (final bool forceHosted in <bool>[true, false]) {
        final RunConfig c = RunConfig(symbol: 'x', forceHosted: forceHosted);

        expect(
          BenchRunner.pageUrl('r1', c),
          chartPageUrl(theme: 'dark', runId: 'r1', local: BenchRunner.localFor(c)),
          reason: 'forceHosted=$forceHosted',
        );
      }
    });

    test('from the run into the URL it loads', () {
      final String hosted = BenchRunner.pageUrl('r1', const RunConfig(symbol: 'x', forceHosted: true));
      final String followsBuild = BenchRunner.pageUrl('r1', const RunConfig(symbol: 'x'));

      expect(Uri.parse(hosted).host, Uri.parse(kChartUrl).host);
      expect(hosted, startsWith(kChartUrl));
      expect(hosted, contains('hbRun=r1'));
      expect(followsBuild, chartPageUrl(theme: 'dark', runId: 'r1'));
    });

    test('so the two opens of L5 load different origins', () {
      final List<OpenChart> opens = _l5.steps.whereType<OpenChart>().toList();

      expect(
        _origin(BenchRunner.pageUrl('r', runConfigFor(opens[0]))),
        _hostedOrigin,
      );
      expect(
        _origin(BenchRunner.pageUrl('r', runConfigFor(opens[1]))),
        _origin(chartPageUrl(local: kChartLocal)),
        reason: 'the second follows the build, which is the bundled page when CHART_LOCAL is on',
      );
    });
  });

  test('the retry counter is evidence, not a requirement: a run where the cache was healthy still passes', () {
    final ScenarioObservations o = _good();
    o.probes['bundled'] = _probe(origin: _bundledOrigin, retry: <String, Object?>{'retried': 0, 'recovered': 0, 'failed': 0});

    expect(_verdicts(o).values, everyElement(isTrue));
  });
}
