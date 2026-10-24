/// Which regression cases may run against production.
///
/// Most cases change what the account has saved: they add indicators, switch intervals and symbols,
/// pan until the page saves. Against production that is a real account. Opening a chart already
/// makes the page save its state (the symbol it opened becomes the account's last-viewed one),
/// which is what the app does too, so a case whose every step only opens and observes is allowed.
///
/// The rule is on the kinds of step, not a list of case ids, so it fails closed: a step type nobody
/// has judged is blocked, and a case cannot be allowed by a typo in a list.
library;

import '../config/environment.dart';
import 'scenario.dart';

/// Whether [step] does nothing to an account beyond opening a chart and looking at the result.
bool isOpenOnlyStep(ScenarioStep step) => switch (step) {
      OpenChart() ||
      Wait() ||
      TraceApi() ||
      Probe() ||
      WaitForBars() ||
      CaptureLibUrls() ||
      WaitForLibQuiet() =>
        true,
      // Stubs the page's own fetch to fail, then puts it back; it reaches no server.
      Operate(:final String op) => op == 'networkFailure',
      // Everything else: symbol and interval changes, themes, indicators, ticks, reloads, host
      // lifecycle, cache warming. Not judged, so not allowed here.
      _ => false,
    };

/// The decision, separated from the build flags so every combination can be tested.
bool caseRunsIn(Scenario scenario, {required bool production, required bool allowWrites}) =>
    !production || allowWrites || scenario.steps.every(isOpenOnlyStep);

/// Whether [scenario] runs in this build's environment.
bool runsInThisEnvironment(Scenario scenario) =>
    caseRunsIn(scenario, production: kChartProd, allowWrites: kAllowProdWrites);

/// What to tell someone whose case was not run.
String blockedReason(Scenario scenario) =>
    'blocked on production: ${scenario.id} does more than open a chart, so it would change account '
    'state. Build with --dart-define=CHART_ENV=uat to run it against UAT, or '
    '--dart-define=ALLOW_PROD_WRITES=true if you mean to run it on this account.';
