import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/model/bench_models.dart';
import 'package:ios_webview_plugin_example/src/regression/expectation.dart';
import 'package:ios_webview_plugin_example/src/regression/harness_ack.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario_catalog.dart';

RunRecord _record({
  TerminalOutcome outcome = TerminalOutcome.chartSuccess,
  Map<String, int>? marks,
  String? chartSource,
  bool? resetCache,
  int strays = 0,
}) =>
    RunRecord(
      runId: 'r1',
      config: const RunConfig(symbol: '0:22'),
      outcome: outcome,
      startedAt: DateTime.utc(2026),
      marks: marks ?? <String, int>{},
      chartSource: chartSource,
      pageReadyResetCache: resetCache,
      strayEvents: strays,
    );

void main() {
  group('ExpectOutcome', () {
    test('passes on a match and reports the actual on a miss', () {
      final ScenarioObservations o = ScenarioObservations()
        ..records.add(_record(outcome: TerminalOutcome.timeout));
      expect(const ExpectOutcome(TerminalOutcome.timeout).evaluate(o).pass, isTrue);
      final ExpectationResult miss =
          const ExpectOutcome(TerminalOutcome.chartSuccess).evaluate(o);
      expect(miss.pass, isFalse);
      expect(miss.actual, 'timeout');
    });

    test('fails rather than throws when no load ran', () {
      final ExpectationResult r =
          const ExpectOutcome(TerminalOutcome.chartSuccess).evaluate(ScenarioObservations());
      expect(r.pass, isFalse);
      expect(r.actual, 'no load ran');
    });
  });

  group('ExpectMarkAbsent — the page-reuse assertion', () {
    test('passes when the mark never arrived', () {
      final ScenarioObservations o = ScenarioObservations()..records.add(_record());
      expect(const ExpectMarkAbsent('pageStarted').evaluate(o).pass, isTrue);
    });

    test('fails when a navigation did happen', () {
      // This is the falsifiability check: a reuse path that quietly re-navigates must go red.
      final ScenarioObservations o = ScenarioObservations()
        ..records.add(_record(marks: <String, int>{'pageStarted': 1234}));
      final ExpectationResult r = const ExpectMarkAbsent('pageStarted').evaluate(o);
      expect(r.pass, isFalse);
      expect(r.actual, contains('1234'));
    });
  });

  group('ExpectAck / ExpectSilentSkip', () {
    test('a silent operation fails ExpectAck', () {
      final ScenarioObservations o = ScenarioObservations()
        ..acks.add(const AckResult('changeTheme', AckStatus.silent));
      expect(const ExpectAck('changeTheme').evaluate(o).pass, isFalse);
    });

    test('a silent operation satisfies ExpectSilentSkip', () {
      final ScenarioObservations o = ScenarioObservations()
        ..acks.add(const AckResult('changeTheme', AckStatus.silent));
      expect(
        const ExpectSilentSkip('changeTheme', knownDefect: 'gated below pageLoaded')
            .evaluate(o)
            .pass,
        isTrue,
      );
    });

    test('a missing ack counts as silent, not as an error', () {
      expect(
        const ExpectSilentSkip('changeTheme', knownDefect: 'x')
            .evaluate(ScenarioObservations())
            .pass,
        isTrue,
      );
    });

    test('an operation that threw can be asserted explicitly', () {
      final ScenarioObservations o = ScenarioObservations()
        ..acks.add(const AckResult('chartEvents', AckStatus.threw, detail: 'undefined'));
      expect(
        const ExpectAck('chartEvents', allow: <AckStatus>{AckStatus.threw}).evaluate(o).pass,
        isTrue,
      );
      // …and does not satisfy the default "acknowledged" set.
      expect(const ExpectAck('chartEvents').evaluate(o).pass, isFalse);
    });

    test('the most recent ack for an op wins', () {
      final ScenarioObservations o = ScenarioObservations()
        ..acks.add(const AckResult('changeTheme', AckStatus.silent))
        ..acks.add(const AckResult('changeTheme', AckStatus.called));
      expect(const ExpectAck('changeTheme').evaluate(o).pass, isTrue);
    });
  });

  group('Probe assertions', () {
    test('ExpectProbeChanged detects a real state change', () {
      final ScenarioObservations o = ScenarioObservations();
      o.probes['a'] = <String, Object?>{'symbol': 'NSE:ACC'};
      o.probes['b'] = <String, Object?>{'symbol': 'NSE:SBIN'};
      expect(const ExpectProbeChanged('a', 'b', 'symbol').evaluate(o).pass, isTrue);
    });

    test('ExpectProbeChanged fails when the page did not move', () {
      final ScenarioObservations o = ScenarioObservations();
      o.probes['a'] = <String, Object?>{'theme': 'dark'};
      o.probes['b'] = <String, Object?>{'theme': 'dark'};
      final ExpectationResult r = const ExpectProbeChanged('a', 'b', 'theme').evaluate(o);
      expect(r.pass, isFalse);
      expect(r.actual, 'dark → dark');
    });

    test('a missing probe fails rather than throws', () {
      expect(
        const ExpectProbeChanged('a', 'b', 'theme').evaluate(ScenarioObservations()).pass,
        isFalse,
      );
      expect(const ExpectProbe('a', 'theme', 'dark').evaluate(ScenarioObservations()).pass,
          isFalse);
    });
  });

  group('ExpectPhaseUnder', () {
    test('compares in microseconds against a Duration budget', () {
      final ScenarioObservations o = ScenarioObservations()
        ..records.add(_record(marks: <String, int>{'pageStarted': 300000}));
      // navigation = pageStarted - t0 = 300 ms
      expect(
        const ExpectPhaseUnder('navigation', Duration(milliseconds: 400)).evaluate(o).pass,
        isTrue,
      );
      expect(
        const ExpectPhaseUnder('navigation', Duration(milliseconds: 200)).evaluate(o).pass,
        isFalse,
      );
    });

    test('an unmeasured metric fails instead of passing vacuously', () {
      final ScenarioObservations o = ScenarioObservations()..records.add(_record());
      final ExpectationResult r =
          const ExpectPhaseUnder('navigation', Duration(seconds: 1)).evaluate(o);
      expect(r.pass, isFalse);
      expect(r.actual, 'not measured');
    });
  });

  group('ExpectNoStrays', () {
    test('sums strays across every run in the scenario', () {
      final ScenarioObservations o = ScenarioObservations()
        ..records.add(_record())
        ..records.add(_record(strays: 2));
      final ExpectationResult r = const ExpectNoStrays().evaluate(o);
      expect(r.pass, isFalse);
      expect(r.actual, '2');
    });
  });

  group('Catalog integrity', () {
    final List<Scenario> catalog = buildCatalog();

    test('case ids are unique', () {
      final Set<String> ids = catalog.map((Scenario s) => s.id).toSet();
      expect(ids.length, catalog.length);
    });

    test('every case has at least one expectation', () {
      for (final Scenario s in catalog) {
        expect(s.expectations, isNotEmpty, reason: '${s.id} has no expectations');
      }
    });

    test('every case has at least one step', () {
      for (final Scenario s in catalog) {
        expect(s.steps, isNotEmpty, reason: '${s.id} has no steps');
      }
    });

    test('cases pinning a known defect carry a hypothesis', () {
      // A case whose assertion is "the defect reproduces" is meaningless without a written
      // reason, because a future reader cannot tell a green result from a real pass.
      for (final Scenario s in catalog) {
        final bool pinsDefect =
            s.expectations.any((Expectation e) => e is ExpectSilentSkip);
        if (pinsDefect) {
          expect(s.hypothesis, isNotNull, reason: '${s.id} pins a defect with no hypothesis');
        }
      }
    });

    test('externally-gated cases are flagged as needing the host script', () {
      for (final Scenario s in catalog) {
        if (s.precondition != null && s.precondition != ExternalPrecondition.backgrounded) {
          expect(s.needsHost, isTrue, reason: '${s.id} should need the host');
        }
      }
    });

    test('the negative controls are present and each expects a specific failure', () {
      // These three are what make every green result meaningful: if a case that must fail
      // starts passing, the assertions are not actually wired to anything.
      final Scenario e4 = catalog.firstWhere((Scenario s) => s.id == 'E4');
      expect(
        e4.expectations.whereType<ExpectOutcome>().single.outcome,
        TerminalOutcome.chartErrorSymbolNotFound,
      );

      // Measured on device: authorising late does NOT hang. It yields an empty chart, because
      // the 401'd history request already told the library there is no data.
      final Scenario d2 = catalog.firstWhere((Scenario s) => s.id == 'D2');
      expect(
        d2.expectations.whereType<ExpectOutcome>().single.outcome,
        TerminalOutcome.chartErrorDataNotAvailable,
      );

      // Withholding the token entirely is the case that actually hangs.
      final Scenario d2b = catalog.firstWhere((Scenario s) => s.id == 'D2b');
      expect(
        d2b.expectations.whereType<ExpectOutcome>().single.outcome,
        TerminalOutcome.timeout,
      );
    });
  });
}
