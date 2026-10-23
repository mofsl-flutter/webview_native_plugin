import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ios_webview_plugin/chart_session.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_events.dart';

import '../config/chart_lib_urls.dart';
import '../config/endpoints.dart';
import '../model/bench_models.dart';
import '../model/chart_messages.dart';
import '../model/stats.dart';
import '../service/bench_runner.dart';
import '../service/js_snippets.dart';
import '../service/webview_bridge.dart';
import 'cache_census.dart';
import 'expectation.dart';
import 'harness_ack.dart';
import 'mirrored_host_gate.dart';
import 'scenario.dart';

/// UI-level actions the runner cannot perform itself.
///
/// Navigating away and back must really dispose and recreate the platform view, which only the
/// hosting screen can do.
class ScenarioHost {
  /// Creates a host binding.
  const ScenarioHost({
    required this.awaitViewMounted,
    required this.navigateAway,
    required this.navigateBack,
    required this.recreateChartScreen,
  });

  /// Completes once the platform view reports creation.
  final Future<void> Function() awaitViewMounted;

  /// Pushes a route over the chart, disposing the platform view.
  final Future<void> Function() navigateAway;

  /// Pops back to the chart, recreating the platform view.
  final Future<void> Function() navigateBack;

  /// Disposes the chart screen's `State` and rebuilds it, returning what the rebuilt screen
  /// observed of the session on attach.
  ///
  /// The returned map is the fresh `State`'s own read of `ChartSession.instance.snapshot`, which
  /// is what pins whether a rebuilt widget inherits the true page state or assumes a blank one.
  final Future<Map<String, Object?>> Function() recreateChartScreen;
}

/// Outcome of one regression case.
class ScenarioResult {
  /// Creates a result.
  ScenarioResult({
    required this.scenario,
    required this.results,
    required this.observations,
    this.error,
  });

  /// The case that ran.
  final Scenario scenario;

  /// Per-expectation verdicts.
  final List<ExpectationResult> results;

  /// Everything observed.
  final ScenarioObservations observations;

  /// Set when the case aborted before its expectations could be evaluated.
  final String? error;

  /// Whether every expectation held and nothing threw.
  bool get pass =>
      error == null && results.isNotEmpty && results.every((ExpectationResult r) => r.pass);

  /// Expectations that did not hold.
  List<ExpectationResult> get failures =>
      results.where((ExpectationResult r) => !r.pass).toList();

  /// One-line summary for the log and CSV.
  ///
  /// Carries a trailing metrics field on every run, pass or fail — not just failures — because
  /// the plan's trustworthiness gates (gateWait, stray, tail) and the A1/C2/H3 timing questions
  /// need the numbers from a PASSing run too, and the terse orchestration-script log was the
  /// only place they were being dropped.
  String get line {
    final String state = error != null ? 'ERROR' : (pass ? 'PASS' : 'FAIL');
    final String detail = error ??
        failures.map((ExpectationResult f) => f.toString()).join(' | ');
    final String metrics = _metricsSummary(observations.last);
    return '${scenario.id}\t$state\t${scenario.title}'
        '${detail.isEmpty ? '' : '\t$detail'}'
        '${metrics.isEmpty ? '' : '\t$metrics'}';
  }
}

/// Compact metrics summary for [ScenarioResult.line], sourced from the last load record.
String _metricsSummary(RunRecord? r) {
  if (r == null) return '';
  final Map<String, int?> m = r.metrics;
  String ms(String key) => m[key] == null ? '-' : '${(m[key]! / 1000).toStringAsFixed(1)}ms';
  final Map<String, Object?>? nt = r.navTiming;
  final String resources = nt == null
      ? 'req=- xfer=- dec=- docXfer=- docDec=-'
      : 'req=${nt['count']} xfer=${formatBytes(nt['bytesTransfer'])} '
          'dec=${formatBytes(nt['bytesDecoded'])} '
          'docXfer=${formatBytes(nt['docTransfer'])} docDec=${formatBytes(nt['docDecoded'])}';
  final Object? libSummary = nt?['libSummary'];
  // Counts only: the per-file list is long and lives on the separate evidence lines.
  final String lib = libSummary is Map
      ? ' ${formatLibCache(<String, Object?>{'summary': libSummary})}'
      : '';
  return 'metrics: nav=${ms('navigation')} doc=${ms('documentLoad')} jsBoot=${ms('jsBoot')} '
      'gate=${ms('gateWait')} authRtt=${ms('authorizeRtt')} render=${ms('chartRender')} '
      'e2e=${ms('endToEnd')} $resources$lib tail=${r.tailEvents} stray=${r.strayEvents}';
}

/// Executes scenarios and evaluates their expectations.
class ScenarioRunner extends ChangeNotifier {
  /// Creates a runner.
  ScenarioRunner({required this.token, required this.host});

  /// Access token injected into the page.
  final String token;

  /// UI actions this runner delegates.
  final ScenarioHost host;

  final HarnessAck _ack = HarnessAck();

  /// Reproduces the host's injection gate so the cases that pin its silent-skip defect can
  /// actually observe it.
  final MirroredHostGate _gate = MirroredHostGate();
  final Map<String, ScenarioResult> _results = <String, ScenarioResult>{};

  /// Warm-ups started in the background, awaiting an `AwaitWarm` step.
  final Map<String, Future<void>> _pendingWarms = <String, Future<void>>{};

  Scenario? _current;
  String? _currentStep;
  bool _running = false;

  /// Results so far, keyed by case id.
  Map<String, ScenarioResult> get results => Map<String, ScenarioResult>.unmodifiable(_results);

  /// The case currently executing.
  Scenario? get current => _current;

  /// The step currently executing.
  String? get currentStep => _currentStep;

  /// Whether a case or batch is in flight.
  bool get isRunning => _running;

  /// Runs [scenarios] in order.
  Future<void> runAll(List<Scenario> scenarios) async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      for (final Scenario s in scenarios) {
        await run(s);
      }
    } finally {
      _running = false;
      _current = null;
      _currentStep = null;
      notifyListeners();
    }
  }

  /// Runs a single case.
  Future<ScenarioResult> run(Scenario scenario) async {
    _current = scenario;
    _ack.reset();
    _gate.reset();
    _pendingWarms.clear();
    final ScenarioObservations obs = ScenarioObservations();
    String? error;

    try {
      for (final ScenarioStep step in scenario.steps) {
        _currentStep = step.describe;
        notifyListeners();
        await _execute(step, scenario, obs);
      }
    } on Object catch (e) {
      error = e.toString();
    }

    // Harvest page-side error messages from the shared log for the "reports nothing" cases.
    for (final LoggedEvent e in WebViewBridge.instance.log) {
      final WebViewEvent ev = e.event;
      if (ev is WebViewChannelMessageEvent && ev.decoded != null) {
        final ChannelResponse? r = ChannelResponse.tryParse(ev.decoded!);
        if (r?.error != null) obs.pageErrors.add('${r!.context}/${r.error!.reason}');
      } else if (ev is WebViewErrorEvent) {
        final String entry = '${ev.description}@${ev.failingUrl ?? "?"}';
        if (ev.isForMainFrame == true) {
          obs.nativeErrors.add(entry);
        } else {
          obs.subresourceErrors.add(entry);
        }
      }
    }

    final List<ExpectationResult> verdicts = error != null
        ? <ExpectationResult>[]
        : scenario.expectations
            .map((Expectation e) => e.evaluate(obs))
            .toList(growable: false);

    final ScenarioResult result = ScenarioResult(
      scenario: scenario,
      results: verdicts,
      observations: obs,
      error: error,
    );
    _results[scenario.id] = result;
    _currentStep = null;
    notifyListeners();
    return result;
  }

  // ------------------------------------------------------------- steps

  Future<void> _execute(
    ScenarioStep step,
    Scenario scenario,
    ScenarioObservations obs,
  ) async {
    switch (step) {
      case PreWarm(:final bool loadUrl):
        await IosWebViewPlugin.prewarm(
          javascriptChannels: <String>[kChartChannel, kChartSessionAckChannel],
          url: loadUrl ? chartPageUrl() : null,
        );
        obs.notes.add('pre-warmed${loadUrl ? ' with load' : ''}');

      case OpenChart(
          :final String symbol,
          :final bool authorizeFirst,
          :final bool neverAuthorize,
          :final String chartMode,
          :final double budgetScale
        ):
        final BenchRunner runner = BenchRunner(token: token);
        await runner.runBatch(
          configs: <RunConfig>[
            RunConfig(
              symbol: symbol,
              authorizeFirst: authorizeFirst,
              neverAuthorize: neverAuthorize,
              chartMode: chartMode,
              budgetScale: budgetScale,
            ),
          ],
          repeats: 1,
          awaitViewMounted: host.awaitViewMounted,
        );
        obs.records.addAll(runner.records);
        runner.dispose();
        if (chartMode != kChartMode) obs.notes.add('requested mode $chartMode');

      case ChangeSymbol(:final String symbol, :final String chartMode):
        // No navigation: reuse the live page. A load record is still produced so the
        // "was the page reused" assertion has marks to inspect.
        final BenchRunner runner = BenchRunner(token: token);
        await runner.runBatch(
          configs: <RunConfig>[
            RunConfig(
              symbol: symbol,
              changeSymbolOnWarmPage: true,
              chartMode: chartMode,
            ),
          ],
          repeats: 1,
          awaitViewMounted: host.awaitViewMounted,
        );
        obs.records.addAll(runner.records);
        runner.dispose();
        if (chartMode != kChartMode) obs.notes.add('requested mode $chartMode');

      case Operate(:final String op, :final Object? arg):
        await _operate(op, arg, obs);

      case ReAuthorize(:final String? token):
        final String runId = _runId();
        await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
        await IosWebViewPlugin.runJavaScript(
          buildAuthorizeJs(token ?? this.token, runId),
        );
        obs.acks.add(await _ack.awaitOp(runId, 'authorize'));

      case Reload(:final bool clearStorage):
        if (clearStorage) {
          await IosWebViewPlugin.runJavaScript(hbClearAllStorageJs);
        }
        // Mirrors the host: a reload drops the tracked state below the injection threshold,
        // which is what opens the silent-skip window.
        _gate.onLoadRequested();
        await IosWebViewPlugin.reloadUrl();
        obs.notes.add('gate closed by reload (state ${_gate.state.name})');

      case NavigateAway():
        await host.navigateAway();
        obs.notes.add('platform view disposed');

      case NavigateBack():
        await host.navigateBack();
        await host.awaitViewMounted();
        obs.notes.add('platform view recreated');

      case ResetState(:final ResetMode mode):
        switch (mode) {
          case ResetMode.warm:
            break;
          case ResetMode.netCold:
            await IosWebViewPlugin.clearBrowsingData(preset: 'netColdSessionWarm');
          case ResetMode.sessionCold:
            await IosWebViewPlugin.runJavaScript(hbClearAllStorageJs);
            await IosWebViewPlugin.clearBrowsingData(preset: 'netWarmSessionCold');
          case ResetMode.cold:
            await IosWebViewPlugin.runJavaScript(hbClearAllStorageJs);
            await IosWebViewPlugin.clearBrowsingData(preset: 'cold');
        }

      case SetCacheMode(:final String mode):
        await IosWebViewPlugin.setCacheMode(mode);

      case Probe(:final String label):
        final String runId = _runId();
        await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
        await IosWebViewPlugin.runJavaScript(buildProbeJs(runId, label));
        final Map<String, Object?>? p = await _ack.awaitProbe(runId);
        // Seed with the session's own view first: it is available even when the page cannot
        // answer, so a probe never comes back wholly empty.
        obs.probes[label] = <String, Object?>{
          ..._sessionFields(),
          ...?p,
        };
        // The few fields that say whether the chart drew anything, so a failed "has candles"
        // expectation can be read from the log without re-running under a debugger.
        final Map<String, Object?> seen = obs.probes[label]!;
        obs.summaries['probe.$label'] = 'symbol=${seen['symbol']} resolution=${seen['resolution']} '
            'bars=${seen['bars']} widgetReady=${seen['widgetReady']} hasToken=${seen['hasToken']}';

      case RecreateHost(:final String label):
        final Map<String, Object?> observed = await host.recreateChartScreen();
        obs.probes[label] = observed;
        obs.notes.add(
          'host State rebuilt; rebuilt screen saw '
          'isPageLoaded=${observed['isPageLoaded']} loadId=${observed['loadId']}',
        );

      case OperateTracked(
          :final String label,
          :final String script,
          :final Duration timeout
        ):
        final OperationResult result =
            await ChartSession.instance.runOperation(script, timeout: timeout);
        obs.probes[label] = <String, Object?>{
          'status': result.status.name,
          'elapsedMs': result.elapsedMs,
          'error': result.error,
        };
        obs.notes.add('tracked op $label -> ${result.status.name} in ${result.elapsedMs} ms');

      case CacheCensus(:final String label):
        final Map<String, Object?> raw = await IosWebViewPlugin.getWebCacheStats();
        final Map<String, Object?> summary = summarizeCacheStats(raw);
        obs.probes[label] = summary;
        obs.summaries[label] = formatCensus(summary);

      case LibCacheProbe(:final String label):
        final String runId = _runId();
        await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
        await IosWebViewPlugin.runJavaScript(buildLibCacheJs(runId, label));
        final HarnessMessage? m = await _ack.waitForAny(runId, <String>{'libCache'});
        final Object? d = m?.detail;
        final Map<String, Object?> detail =
            d is Map ? Map<String, Object?>.from(d) : <String, Object?>{'error': 'no reply'};
        final Object? summary = detail['summary'];
        final Object? key = detail['key'];
        obs.probes[label] = summary is Map
            ? <String, Object?>{
                ...Map<String, Object?>.from(summary),
                // Names of the heavy files, so an assertion can require the library bundle itself.
                'files': key is Map
                    ? key.keys.map((Object? k) => k.toString()).toList()
                    : <String>[],
              }
            : <String, Object?>{'error': detail['error']};
        obs.summaries[label] = formatLibCache(detail);

      case WarmLibCache(
          :final WarmMode mode,
          :final String label,
          :final String? manifestPath,
          :final bool background
        ):
        Future<void> warm() async {
          final Map<String, Object?> report = await IosWebViewPlugin.warmWebCache(
            baseUrl: kChartUrl,
            // The captured list stands in for a manifest unless the case wants the manifest path.
            urls: manifestPath == null ? kChartLibUrls : null,
            manifestPath: manifestPath ?? 'chart-lib-manifest.json',
            mode: mode,
            timeout: const Duration(minutes: 5),
          );
          obs.probes[label] = report;
          obs.summaries[label] = formatWarmReport(report);
        }

        if (background) {
          _pendingWarms[label] = warm();
        } else {
          await warm();
        }

      case AwaitWarm(:final String label):
        await _pendingWarms.remove(label);

      case CaptureLibUrls(:final bool includeDom):
        final String runId = _runId();
        await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
        await IosWebViewPlugin.runJavaScript(buildLibUrlsJs(runId, includeDom: includeDom));
        final HarnessMessage? m = await _ack.waitForAny(
          runId,
          <String>{'libUrls'},
          timeout: const Duration(seconds: 8),
        );
        final Object? d = m?.detail;
        final List<String> urls = d is Map && d['urls'] is List
            ? (d['urls'] as List<Object?>).map((Object? u) => u.toString()).toList()
            : <String>[];
        obs.probes['libUrls'] = <String, Object?>{
          'count': urls.length,
          'error': d is Map ? d['error'] : 'no reply',
          // Which origin each static file came from: the proof a bundled page fetched no code.
          'hosts': _hostCounts(urls.map((String u) => Uri.parse(u).host)),
        };
        obs.summaries['urls.hosts'] = _hostCounts(urls.map((String u) => Uri.parse(u).host)).toString();
        obs.summaries['urls.count'] = '${urls.length}';
        // A long log line is split by the platform, so the list goes out in short numbered lines.
        int chunk = 0;
        final List<String> line = <String>[];
        int chars = 0;
        void flush() {
          if (line.isEmpty) return;
          obs.summaries['urls.${(chunk++).toString().padLeft(3, '0')}'] = line.join(' ');
          line.clear();
          chars = 0;
        }
        for (final String u in urls) {
          if (chars + u.length > 600) flush();
          line.add(u);
          chars += u.length + 1;
        }
        flush();

      case TraceApi(:final String label):
        final String runId = _runId();
        await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
        await IosWebViewPlugin.runJavaScript(buildApiTraceJs(runId, label));
        final HarnessMessage? m = await _ack.waitForAny(
          runId,
          <String>{'apiTrace'},
          timeout: const Duration(seconds: 8),
        );
        final Object? d = m?.detail;
        final List<Object?> entries =
            d is Map && d['entries'] is List ? d['entries'] as List<Object?> : const <Object?>[];
        obs.probes['trace.$label'] = <String, Object?>{
          'count': entries.length,
          'error': d is Map ? d['error'] : 'no reply',
          'capped': d is Map ? d['capped'] : null,
          // Which origin each API call went to: a bundled page must reach the real server.
          'hosts': _hostCounts(
            entries.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> e) => '${e['h']}'),
          ),
        };
        obs.summaries['trace.$label.count'] = '${entries.length}';
        // One short evidence line per request: a long platform log line is split or dropped.
        for (int i = 0; i < entries.length; i++) {
          final Object? e = entries[i];
          if (e is! Map) continue;
          obs.summaries['trace.$label.${i.toString().padLeft(3, '0')}'] =
              '+${e['st']}ms ${e['end'] == null ? '' : '${(e['end'] as num) - (e['st'] as num)}ms '}'
              'xfer=${e['transfer']} dec=${e['decoded']} st=${e['status']} ${e['h']} ${e['p']}?${e['q']}';
        }

      case WaitForLibQuiet(:final Duration quiet, :final Duration max, :final Duration poll):
        final Stopwatch sw = Stopwatch()..start();
        int? last;
        Duration stableFor = Duration.zero;
        int polls = 0;
        while (sw.elapsed < max) {
          final int? count = await _libEntryCount();
          polls++;
          if (count != null && count == last) {
            stableFor += poll;
          } else {
            stableFor = Duration.zero;
          }
          last = count ?? last;
          if (stableFor >= quiet) break;
          await Future<void>.delayed(poll);
        }
        final bool settled = stableFor >= quiet;
        obs.summaries['settle'] = settled
            ? 'entries=$last stable ${quiet.inSeconds}s, waited ${sw.elapsed.inSeconds}s'
            : 'NOT SETTLED after ${sw.elapsed.inSeconds}s (entries=$last, $polls polls)';
        if (!settled) obs.notes.add('library files were still arriving when the wait gave up');

      case Wait(:final Duration duration):
        await Future<void>.delayed(duration);
    }
  }

  /// Number of static files the page has loaded under `/chart/`, or null when the page did not
  /// answer (mid-navigation, or not loaded).
  Future<int?> _libEntryCount() async {
    final String runId = _runId();
    await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
    await IosWebViewPlugin.runJavaScript(buildLibCacheJs(runId, 'poll'));
    final HarnessMessage? m =
        await _ack.waitForAny(runId, <String>{'libCache'}, timeout: const Duration(seconds: 8));
    final Object? d = m?.detail;
    final Object? summary = d is Map ? d['summary'] : null;
    final Object? entries = summary is Map ? summary['entries'] : null;
    return entries is num ? entries.toInt() : null;
  }

  /// The session's own state, recorded alongside every probe.
  Map<String, Object?> _sessionFields() {
    final ChartSessionSnapshot s = ChartSession.instance.snapshot;
    return <String, Object?>{
      'sessionLoadId': s.loadId,
      'sessionPageLoaded': s.isPageLoaded,
      'sessionAttached': s.isAttached,
      'sessionLiveViews': s.livePlatformViews,
    };
  }

  Future<void> _operate(String op, Object? arg, ScenarioObservations obs) async {
    final String runId = _runId();
    await IosWebViewPlugin.runJavaScript(hbBootstrapJs);

    final String? js = switch (op) {
      'changeTheme' => buildChangeThemeJs(runId, arg?.toString() ?? 'dark'),
      'setTimeFrame' => buildSetTimeFrameJs(runId, arg?.toString() ?? 'D'),
      'changeChartType' => buildChangeChartTypeJs(runId, (arg as num?)?.toInt() ?? 1),
      'chartEvents' => buildChartEventsJs(runId, arg?.toString() ?? 'startfullscreen'),
      'appendLiveTick' => buildAppendTickJs(
          runId,
          arg?.toString() ?? '0:22',
          100.5,
          99.0,
          1000,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ),
      'updateAskAndBid' => buildAskBidJs(runId, arg?.toString() ?? '0:22', 101.0, 100.0),
      'drain401' => buildDrain401Js(runId),
      'setResolution' => buildSetResolutionJs(runId, arg?.toString() ?? '5'),
      'scrollBack' => buildScrollBackJs(runId),
      'panZoom' => buildPanZoomJs(runId),
      _ => null,
    };

    if (js == null) {
      obs.notes.add('unknown op "$op"');
      return;
    }

    final bool injected = await _gate.runJavaScript(js, label: op);
    if (!injected) {
      // The host would have returned null here with only a debug line. Record the skip as a
      // silent result rather than waiting for an acknowledgement that cannot come.
      obs.acks.add(AckResult(op, AckStatus.silent, detail: 'gated: ${_gate.state.name}'));
      obs.notes.add('injection gated for "$op" at state ${_gate.state.name}');
      return;
    }
    obs.acks.add(await _ack.awaitOp(runId, op));
  }

  int _seq = 0;

  String _runId() =>
      'rgs-${DateTime.now().millisecondsSinceEpoch}-${++_seq}';

  @override
  void dispose() {
    _ack.dispose();
    _gate.dispose();
    WebViewBridge.instance.clearLog();
    super.dispose();
  }
}

/// How many of [hosts] each distinct host accounts for.
Map<String, int> _hostCounts(Iterable<String> hosts) {
  final Map<String, int> out = <String, int>{};
  for (final String h in hosts) {
    out[h] = (out[h] ?? 0) + 1;
  }
  return out;
}
