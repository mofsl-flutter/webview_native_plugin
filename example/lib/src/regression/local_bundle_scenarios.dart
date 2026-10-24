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
  openSymbolScenario,
  gapFillScenario,
  tickAfterGapScenario,
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

/// Opens one chart, the symbol named by `--dart-define=CHART_SYMBOL`, and lets the page save.
///
/// Not a test: a way to open a chosen chart through the page's own save path. The page records the
/// symbol it opens as the account's last-viewed one, so a run that had to open something else (the
/// other cases use SBIN) can be undone by opening whatever the account was on.
final Scenario openSymbolScenario = Scenario(
  id: 'O1',
  title: 'Bundled chart: open the symbol given by CHART_SYMBOL',
  dimension: Dimension.storage,
  precondition: ExternalPrecondition.fullCold,
  steps: const <ScenarioStep>[
    OpenChart(kChartSymbol, budgetScale: 6),
    // The page saves its state a moment after the chart is ready.
    Wait(Duration(seconds: 6)),
    Probe('opened'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('the chart for that symbol is up', _chartIsUp),
  ],
);

bool _chartIsUp(ScenarioObservations o) => o.probes['opened']?['widgetReady'] == true;

/// Candles a gap in live ticks leaves behind are filled from history, cheaply, on the real library.
///
/// Live ticks build the last candle and open the next; while the app is away none arrive, so the
/// chart jumps from its last candle to the next tick's. The chart is opened with its last 8 candles
/// hidden from the first history answer (the real server still has them), then `ChartSession.fillMissingCandles` is asked to bring them
/// back. What is checked is what the chart holds, read from the library's own export, and what the
/// page requested: history only, none of the symbol, layout or config requests that loading the
/// chart again makes.
///
/// Opens the chart named by `--dart-define=CHART_SYMBOL`, so an account is left on the symbol it was
/// on. Needs the market closed or history that has bars for the last candles: the fetch is real.
final Scenario gapFillScenario = Scenario(
  id: 'L3',
  title: 'Bundled chart: candles a gap in ticks left are filled from history',
  dimension: Dimension.storage,
  hypothesis: 'After a gap in ticks the missing candles can be fetched on their own (one history '
      'request) and fed to the chart as live bars, giving the chart the candles it would have had, '
      'without loading the chart again.',
  steps: const <ScenarioStep>[
    OpenChart(kChartSymbol, budgetScale: 6, hideLastBars: 8),
    // The chart reports ready before its data arrives.
    Wait(Duration(seconds: 12)),
    Operate('barCensus'),
    Wait(Duration(seconds: 2)),
    Probe('holed'),
    TraceApi('open'),
    FillGap('fill'),
    Operate('barCensus'),
    Wait(Duration(seconds: 2)),
    Probe('filled'),
    TraceApi('fill'),
    // Nothing is missing any more, so a second fill must change nothing.
    FillGap('again'),
    Probe('afterAgain'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('the chart really lost its last candles', _gapWasMade),
    const ExpectCustom('the fill fed those candles back', _fillFedThem),
    const ExpectCustom('the chart holds those candles again, in order', _gapIsFilled),
    const ExpectCustom('the fill asked for history only, nothing a reload asks for', _fillIsCheap),
    const ExpectCustom('a second fill finds nothing new', _secondFillIsNoop),
  ],
);

/// The first tick after a gap arrives before anything asked for a fill.
///
/// Same set-up as L3. A tick for a time long after the chart's last candle would, unhandled, open one
/// candle at its own time and leave every candle in between missing, and the library then refuses the
/// missing ones as older than its last. The page must hold the tick, fetch what is missing, feed it,
/// and only then apply the tick. The tick is synthetic and stamped with the time of the run, which is
/// outside the symbol's session when the market is closed, so the library draws no candle for it; what
/// shows it was applied is the page's own last bar.
final Scenario tickAfterGapScenario = Scenario(
  id: 'L4',
  title: 'Bundled chart: the first tick after a gap brings the missing candles with it',
  dimension: Dimension.storage,
  hypothesis: 'A tick that jumps over missing candles is held while they are fetched from history, '
      'fed in order, and then applied, so the chart has every candle and the tick lands after them.',
  steps: const <ScenarioStep>[
    OpenChart(kChartSymbol, budgetScale: 6, hideLastBars: 8),
    Wait(Duration(seconds: 12)),
    Operate('barCensus'),
    Wait(Duration(seconds: 2)),
    Probe('holed'),
    TraceApi('open'),
    Operate('appendLiveTick', arg: kChartSymbol),
    // Held while history is fetched, then applied: well inside this.
    Wait(Duration(seconds: 4)),
    Operate('barCensus'),
    Wait(Duration(seconds: 2)),
    Probe('afterTick'),
    TraceApi('tick'),
  ],
  expectations: <Expectation>[
    const ExpectCustom('the harness was started with CHART_LOCAL=true', _localModeOn),
    const ExpectCustom('the chart really lost its last candles', _gapWasMade),
    const ExpectCustom('the page fetched and fed the missing candles by itself', _tickFilledByItself),
    const ExpectCustom('the chart holds them and the tick, in order', _tickLandedAfterThem),
    const ExpectCustom('it asked for history only, nothing a reload asks for', _tickFillIsCheap),
  ],
);

bool _tickFilledByItself(ScenarioObservations o) {
  final Object? dropped = _mapAt(o.probes['holed'], 'gap')?['dropped'];
  final Map<Object?, Object?>? result = _lastFill(o, 'afterTick');
  final Object? fed = result?['fed'];
  return dropped is num && result?['status'] == 'filled' && fed is num && fed >= dropped;
}

bool _tickLandedAfterThem(ScenarioObservations o) {
  final Map<Object?, Object?>? gap = _mapAt(o.probes['holed'], 'gap');
  final Object? dropped = gap?['dropped'];
  final Object? full = gap?['fullLastMs'];
  final Object? before = _mapAt(o.probes['holed'], 'census')?['rows'];
  final Map<Object?, Object?>? after = _mapAt(o.probes['afterTick'], 'census');
  final Object? rows = after?['rows'];
  final Object? streamLast = after?['streamLastMs'];
  // The missing candles are back, in order, ending on the real last one. The tick was applied after
  // them (the stream's last bar is the tick's, later than the last real one). The library draws no
  // candle for it: the run is outside the symbol's session, and the library ignores a live bar there.
  return dropped is num &&
      full is num &&
      before is num &&
      rows is num &&
      rows == before + dropped &&
      after?['strictlyIncreasing'] == true &&
      _seconds(after?['lastSec']) == full ~/ 1000 &&
      streamLast is num &&
      streamLast > full;
}

bool _tickFillIsCheap(ScenarioObservations o) =>
    _pageCalls(o, 'trace.tick', 'chart/historyv3') == 1 &&
    _pageCalls(o, 'trace.tick', 'chart/symbols') == 0 &&
    _pageCalls(o, 'trace.tick', 'chart/getchartsavedinfo') == 0 &&
    _pageCalls(o, 'trace.tick', 'chart/config') == 0;

/// A time from the library's export or the page, in whole seconds: it may arrive as ms or s.
int? _seconds(Object? v) {
  if (v is! num) return null;
  final int n = v.toInt();
  return n > 100000000000 ? n ~/ 1000 : n;
}

Map<Object?, Object?>? _mapAt(Map<String, Object?>? probe, String key) {
  final Object? v = probe?[key];
  return v is Map ? v : null;
}

/// The latest fill result the page recorded, from a probe's `fills` entries (`[key, result]`).
Map<Object?, Object?>? _lastFill(ScenarioObservations o, String probe) {
  final Object? fills = o.probes[probe]?['fills'];
  if (fills is! List || fills.isEmpty) return null;
  final Object? entry = fills.first;
  if (entry is! List || entry.length < 2) return null;
  final Object? result = entry[1];
  return result is Map ? result : null;
}

bool _gapWasMade(ScenarioObservations o) {
  final Map<Object?, Object?>? gap = _mapAt(o.probes['holed'], 'gap');
  final Map<Object?, Object?>? census = _mapAt(o.probes['holed'], 'census');
  if (gap == null || census == null) return false;
  final Object? dropped = gap['dropped'];
  final Object? truncated = gap['truncatedLastMs'];
  final Object? full = gap['fullLastMs'];
  return dropped is num &&
      dropped > 0 &&
      gap['timedOut'] != true &&
      truncated is num &&
      full is num &&
      truncated < full &&
      _seconds(census['lastSec']) == truncated ~/ 1000 &&
      census['streamLastMs'] == truncated;
}

bool _fillFedThem(ScenarioObservations o) {
  if (o.probes['fill']?['status'] != 'ok') return false;
  final Object? dropped = _mapAt(o.probes['holed'], 'gap')?['dropped'];
  final Map<Object?, Object?>? result = _lastFill(o, 'filled');
  final Object? fed = result?['fed'];
  return dropped is num && result?['status'] == 'filled' && fed is num && fed >= dropped;
}

bool _gapIsFilled(ScenarioObservations o) {
  final Map<Object?, Object?>? gap = _mapAt(o.probes['holed'], 'gap');
  final Map<Object?, Object?>? before = _mapAt(o.probes['holed'], 'census');
  final Map<Object?, Object?>? after = _mapAt(o.probes['filled'], 'census');
  if (gap == null || before == null || after == null) return false;
  final Object? dropped = gap['dropped'];
  final Object? full = gap['fullLastMs'];
  final Object? rowsBefore = before['rows'];
  final Object? rowsAfter = after['rows'];
  return dropped is num &&
      full is num &&
      rowsBefore is num &&
      rowsAfter is num &&
      rowsAfter == rowsBefore + dropped &&
      after['strictlyIncreasing'] == true &&
      _seconds(after['lastSec']) == full ~/ 1000 &&
      after['streamLastMs'] == full;
}

bool _fillIsCheap(ScenarioObservations o) =>
    _pageCalls(o, 'trace.fill', 'chart/historyv3') == 1 &&
    _pageCalls(o, 'trace.fill', 'chart/symbols') == 0 &&
    _pageCalls(o, 'trace.fill', 'chart/getchartsavedinfo') == 0 &&
    _pageCalls(o, 'trace.fill', 'chart/config') == 0;

bool _secondFillIsNoop(ScenarioObservations o) {
  if (o.probes['again']?['status'] != 'ok') return false;
  return _lastFill(o, 'afterAgain')?['status'] == 'nothing-new';
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
