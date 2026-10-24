// Case O2: O1 with the opening data prefetched from Dart while the page loads.
//
// It exists so the cost of a first open can be timed with and without the prefetch on the same build,
// the same launch routine and the same account, one launch at a time (see tool/bench). It is open-only,
// so it may run on production.
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/regression/expectation.dart';
import 'package:ios_webview_plugin_example/src/regression/local_bundle_scenarios.dart';
import 'package:ios_webview_plugin_example/src/regression/production_guard.dart';
import 'package:ios_webview_plugin_example/src/regression/scenario.dart';

Scenario _case(String id) => localBundleScenarios.firstWhere((Scenario s) => s.id == id);

void main() {
  test('opens one chart with the prefetch on, and nothing else', () {
    final List<ScenarioStep> steps = _case('O2').steps;
    final List<OpenChart> opens = steps.whereType<OpenChart>().toList();

    expect(opens, hasLength(1));
    expect(opens.single.prefetch, isTrue);
    expect(opens.single.forceHosted, isFalse);
    expect(steps.whereType<Probe>().map((Probe p) => p.label), <String>['opened']);
  });

  test('is O1 with the prefetch the only difference, so the two can be compared', () {
    final Scenario o1 = _case('O1');
    final Scenario o2 = _case('O2');
    final OpenChart a = o1.steps.whereType<OpenChart>().single;
    final OpenChart b = o2.steps.whereType<OpenChart>().single;

    expect(b.symbol, a.symbol);
    expect(b.budgetScale, a.budgetScale);
    expect(b.authorizeFirst, a.authorizeFirst);
    expect(o2.steps.length, o1.steps.length);
    expect(o2.precondition, o1.precondition);
    expect(o2.expectations.map((Expectation e) => e.description), o1.expectations.map((Expectation e) => e.description));
  });

  test('may run on production, because it only opens a chart', () {
    expect(caseRunsIn(_case('O2'), production: true, allowWrites: false), isTrue);
  });
}
