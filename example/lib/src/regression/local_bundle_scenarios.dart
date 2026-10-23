/// Cases for the chart bundled inside the plugin.
///
/// They only mean something when the harness loads the bundled page, so each starts by asserting
/// `--dart-define=CHART_LOCAL=true`; without it they fail with that reason instead of passing on
/// the hosted page. Run one with
/// `adb -s <emulator> shell am start -n <pkg>/.MainActivity --es scenario L1 --ez autorun true`.
library;

import '../config/endpoints.dart';
import 'expectation.dart';
import 'scenario.dart';
import 'scenario_catalog.dart' show kEquityA, kEquityB;

/// The cases, appended to the main catalog.
final List<Scenario> localBundleScenarios = <Scenario>[
  Scenario(
    id: 'L1',
    title: 'Bundled chart: code from the app, data from the server',
    dimension: Dimension.storage,
    precondition: ExternalPrecondition.fullCold,
    hypothesis: 'A page served from the plugin fetches none of the chart code over the network, '
        'and its API calls still reach the real server (cross-origin, via the apiBase it was '
        'given). Resource Timing names every file the page loaded and every API call it made, '
        'so the origin of each is observed, not inferred.',
    steps: const <ScenarioStep>[
      OpenChart(kEquityA, budgetScale: 6),
      // The library loads some chunks lazily after the chart reports; wait for the count of
      // loaded files to stop growing so the host tally covers them too.
      WaitForLibQuiet(quiet: Duration(seconds: 10), max: Duration(seconds: 90)),
      CaptureLibUrls(includeDom: true),
      TraceApi('open'),
    ],
    expectations: <Expectation>[
      const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
      const ExpectCustom('every static file came from the app', _staticFilesFromApp),
      const ExpectCustom('every API call went to the server, none to the app', _apiCallsToServer),
    ],
  ),
  Scenario(
    id: 'L2',
    title: 'Bundled chart: candles render',
    dimension: Dimension.storage,
    precondition: ExternalPrecondition.fullCold,
    hypothesis: 'Serving the page from the app must not change what the chart shows. L1 proves '
        'where files came from; this proves the library still draws candles from the API data.',
    steps: const <ScenarioStep>[
      OpenChart(kEquityB, budgetScale: 6),
      // The chart reports ready before its data arrives. The API answers in about 10 s when the
      // requested range reaches "now", so wait that out before looking for bars. No interval is
      // changed: the page saves it to the server, and a probe taken mid-load reads zero bars.
      Wait(Duration(seconds: 22)),
      TraceApi('candles'),
      Probe('candles'),
    ],
    expectations: <Expectation>[
      const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
      const ExpectCustom('the chart holds candles', _hasCandles),
    ],
  ),
];

bool _hasCandles(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['candles'];
  final Object? bars = p?['bars'];
  return p?['widgetReady'] == true && bars is num && bars > 0;
}

/// The host a bundled page is served from, e.g. `appassets.androidplatform.net`.
String get _appHost => Uri.parse(chartPageUrl()).host;

/// The host the real API lives on.
String get _serverHost => Uri.parse(kChartRoot).host;

bool _localModeOn(ScenarioObservations o) => kChartLocal;

bool _staticFilesFromApp(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['libUrls'];
  final Object? hosts = p?['hosts'];
  final Object? count = p?['count'];
  // More than a handful, or an empty capture would pass vacuously; and nothing from any other host.
  return p?['error'] == null &&
      count is num &&
      count > 20 &&
      hosts is Map &&
      hosts.length == 1 &&
      hosts.containsKey(_appHost);
}

bool _apiCallsToServer(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['trace.open'];
  final Object? hosts = p?['hosts'];
  final Object? count = p?['count'];
  return p?['error'] == null &&
      count is num &&
      count > 0 &&
      hosts is Map &&
      hosts.containsKey(_serverHost) &&
      !hosts.containsKey(_appHost);
}
