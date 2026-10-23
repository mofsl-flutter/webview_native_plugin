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
      // The chart reports ready before its data arrives. UAT's HistoryV3 takes about 10 s when the
      // requested range reaches "now" (production answers in about 0.25 s), so wait long enough for
      // UAT before looking for bars. No interval is changed: the page saves it to the server, and a
      // probe taken mid-load reads zero bars.
      Wait(Duration(seconds: 22)),
      TraceApi('candles'),
      Probe('candles'),
    ],
    expectations: <Expectation>[
      const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
      const ExpectCustom('the chart holds candles', _hasCandles),
    ],
  ),
  saveTrafficScenario,
  legendPollScenario,
  prefetchScenario,
  networkFailureScenario,
];

/// Not a pass/fail case: it records how much the page saves while it is panned, so a change to the
/// page's save logic can be compared before and after on the same movement.
final Scenario saveTrafficScenario = Scenario(
  id: 'S1',
  title: 'Bundled chart: save traffic while panning',
  dimension: Dimension.storage,
  precondition: ExternalPrecondition.fullCold,
  hypothesis: 'The page saves the whole chart to the server on every visible-range change, and '
      'its panes_order_changed handler subscribes to range changes again each time it runs, so a '
      'second pan after adding an indicator should save more than the first for the same movement.',
  steps: const <ScenarioStep>[
    OpenChart(kEquityB, budgetScale: 6),
    // Wait out UAT's ~10 s HistoryV3 (production: ~0.25 s) so there is data to pan over, then drop
    // the load-time requests.
    Wait(Duration(seconds: 22)),
    TraceApi('load'),
    // What the chart carries on open. Indicators this case adds are saved to the server's copy of
    // the layout, so leftovers from an earlier run show up here.
    Probe('start'),
    // 40 range changes over 10 s; saves go out 1 s after a change and the POST takes ~0.2 s.
    Operate('panZoom'),
    Wait(Duration(seconds: 14)),
    TraceApi('pan1'),
    Probe('pan1'),
    // An indicator in its own pane re-runs the page's panes_order_changed handler.
    Operate('addStudy', arg: 'Relative Strength Index'),
    Wait(Duration(seconds: 6)),
    TraceApi('study'),
    Operate('panZoom'),
    Wait(Duration(seconds: 14)),
    TraceApi('pan2'),
    Probe('pan2'),
    // A second indicator re-runs the handler again. If each run adds another subscription, this
    // pan saves about twice as often as the last for the same movement.
    Operate('addStudy', arg: 'MACD'),
    Wait(Duration(seconds: 6)),
    TraceApi('study2'),
    Operate('panZoom'),
    Wait(Duration(seconds: 14)),
    TraceApi('pan3'),
    Operate('saveCost'),
    Probe('pan3'),
    // Leave the shared test client's layout as it was found: take out what this case added, every
    // copy (earlier runs left some), and give the page's debounced save time to go out.
    Operate('removeStudies', arg: 'Relative Strength Index,MACD'),
    Wait(Duration(seconds: 6)),
    Probe('end'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    // Measurement only: assert the instrument saw the chart and counted range events.
    const ExpectCustom('the chart had data to pan over', _hasPanData),
  ],
);

/// Not a pass/fail case: how many times the page's legend poll runs per interval and per symbol
/// change on a bundled chart, so the cost of the poll is a number rather than an impression.
final Scenario legendPollScenario = Scenario(
  id: 'S2',
  title: 'Bundled chart: legend poll calls',
  dimension: Dimension.storage,
  precondition: ExternalPrecondition.fullCold,
  hypothesis: 'RemoveLegendHiddenClasses re-polls every 500 ms (up to 10 times) after each interval '
      'and symbol change. Counting its calls says whether that is a cost worth removing.',
  steps: const <ScenarioStep>[
    OpenChart(kEquityB, budgetScale: 6),
    Wait(Duration(seconds: 22)),
    Operate('countLegendPolls'),
    Operate('setResolution', arg: '5'),
    Wait(Duration(seconds: 16)),
    Probe('afterInterval'),
    ChangeSymbol(kEquityA),
    Wait(Duration(seconds: 16)),
    Probe('afterSymbol'),
    // Put the shared test client's saved interval back to 1.
    Operate('setResolution', arg: '1'),
    Wait(Duration(seconds: 3)),
    Probe('afterRestore'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('the poll was observed', _legendObserved),
  ],
);

bool _legendObserved(ScenarioObservations o) {
  final Object? n = o.probes['afterRestore']?['legendPolls'];
  return n is num;
}

/// What the page's adapter does when the network itself fails (offline, DNS, TLS, blocked).
///
/// It must reject, so the caller's own `.catch` runs and the chart can say "no data". A promise that
/// never settles leaves the chart waiting forever with nothing to tell the host.
final Scenario networkFailureScenario = Scenario(
  id: 'N1',
  title: 'Bundled chart: a network failure rejects instead of hanging',
  dimension: Dimension.network,
  precondition: ExternalPrecondition.fullCold,
  hypothesis: 'fetchWith401Retry wrapped its fetch in an async promise executor, so a rejected '
      'fetch threw inside the executor and nothing settled the promise.',
  steps: const <ScenarioStep>[
    OpenChart(kEquityB, budgetScale: 6),
    Wait(Duration(seconds: 3)),
    Operate('networkFailure'),
    // The op is acknowledged when its promise starts; it records its verdict after up to 3 s.
    Wait(Duration(seconds: 4)),
    Probe('net'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('the adapter rejects a failed request', _networkFailureRejects),
  ],
);

bool _networkFailureRejects(ScenarioObservations o) {
  final Object? net = o.probes['net']?['net'];
  return net is String && net.startsWith('rejected');
}

/// The opening requests the page made itself, per endpoint, for a trace probe.
int _pageCalls(ScenarioObservations o, String trace, String endpoint) {
  final Object? paths = o.probes[trace]?['paths'];
  if (paths is! Map) return -1;
  final Object? n = paths[endpoint];
  return n is num ? n.toInt() : 0;
}

/// Opens the same chart twice, once leaving the page to ask for everything itself and once with the
/// opening data fetched from Dart while the page loads, and shows what changed.
///
/// What it asserts is that the prefetch is *used* and that it changes *when*, not *what*: the page
/// asks for none of the three requests whose keys are exact, and the chart ends up with the same
/// symbol, interval and candles. The first candles are the fourth request, which is only served when
/// the server's answer covers the window the library asked for; UAT's often does not (it can return
/// an older window), so that one is reported rather than required.
final Scenario prefetchScenario = Scenario(
  id: 'P1',
  title: 'Bundled chart: opening data prefetched while the page loads',
  dimension: Dimension.storage,
  precondition: ExternalPrecondition.fullCold,
  hypothesis: 'Symbols, the saved layout and Config cannot be asked for before the page has loaded, '
      'but the host can ask for them in parallel with loading it. Handing them to the page should '
      'remove those requests from the page and bring the first candles forward, without changing '
      'what the chart shows.',
  steps: const <ScenarioStep>[
    // Control: the page asks for everything itself.
    OpenChart(kEquityB, budgetScale: 6),
    TraceApi('control'),
    WaitForBars('control'),
    // Prefetched: Dart fetches while the page loads and hands it over before loadChart.
    OpenChart(kEquityB, budgetScale: 6, prefetch: true),
    TraceApi('prefetch'),
    WaitForBars('prefetch'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('without prefetch the page asked for the symbol, layout and config itself', _controlAsks),
    const ExpectCustom('with prefetch the page asked for none of them', _prefetchAsksNone),
    const ExpectCustom('the page took what it was given and never gave up waiting', _pageUsedIt),
    const ExpectCustom('both opens show the same chart', _sameChart),
  ],
);

bool _controlAsks(ScenarioObservations o) =>
    _pageCalls(o, 'trace.control', 'chart/symbols') >= 1 &&
    _pageCalls(o, 'trace.control', 'chart/getchartsavedinfo') >= 1 &&
    _pageCalls(o, 'trace.control', 'chart/config') >= 1;

bool _prefetchAsksNone(ScenarioObservations o) =>
    _pageCalls(o, 'trace.prefetch', 'chart/symbols') == 0 &&
    _pageCalls(o, 'trace.prefetch', 'chart/getchartsavedinfo') == 0 &&
    _pageCalls(o, 'trace.prefetch', 'chart/config') == 0;

bool _pageUsedIt(ScenarioObservations o) {
  final Object? stats = o.probes['prefetch']?['preload'];
  if (stats is! Map) return false;
  final Object? hits = stats['hits'];
  final Object? timedOut = stats['timedOut'];
  return hits is num && hits >= 3 && timedOut is num && timedOut == 0;
}

bool _sameChart(ScenarioObservations o) {
  final Map<String, Object?>? a = o.probes['control'];
  final Map<String, Object?>? b = o.probes['prefetch'];
  if (a == null || b == null) return false;
  final Object? barsA = a['bars'];
  final Object? barsB = b['bars'];
  return a['symbol'] == b['symbol'] &&
      a['resolution'] == b['resolution'] &&
      barsA is num &&
      barsB is num &&
      barsA > 0 &&
      barsA == barsB;
}

bool _hasPanData(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['pan1'];
  final Object? bars = p?['bars'];
  final Object? events = p?['rangeEvents'];
  return bars is num && bars > 0 && events is num && events > 0;
}

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
