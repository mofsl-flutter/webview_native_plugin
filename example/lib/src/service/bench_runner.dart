import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ios_webview_plugin/chart_session.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_events.dart';

import '../config/endpoints.dart';
import '../model/bench_models.dart';
import '../model/chart_messages.dart';
import 'js_snippets.dart';
import 'webview_bridge.dart';

/// Time to keep listening after a terminal, so late events are logged rather than attributed to
/// the next run.
const Duration kSettleDelay = Duration(milliseconds: 1500);

/// Belt-and-braces cap per run, on top of the per-phase budgets.
const Duration kGlobalRunCap = Duration(seconds: 120);

/// Drives benchmark runs and reports live progress.
class BenchRunner extends ChangeNotifier {
  /// Creates a runner bound to [token].
  BenchRunner({required this.token});

  /// Access token injected into the page.
  final String token;

  final List<RunRecord> _records = <RunRecord>[];
  final Map<String, int> _marks = <String, int>{};
  final String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  Stopwatch? _clock;
  Timer? _phaseTimer;
  Timer? _capTimer;
  Completer<void>? _terminal;

  String? _activeRunId;
  RunConfig? _activeConfig;
  RunPhase? _phase;
  DateTime? _startedAt;

  int _seq = 0;
  int _tailEvents = 0;
  int _strayEvents = 0;
  bool _batchRunning = false;
  bool _aborted = false;
  bool _bootstrapInstalled = false;

  /// Whether a page is currently loaded in the singleton WebView.
  ///
  /// Static deliberately: the WebView is process-wide, so this is process state. Holding it per
  /// instance made a second runner believe the page was cold and re-navigate — which silently
  /// converted every "reuse the live page" case into a fresh load.
  static bool _pageAlive = false;

  /// Whether the singleton WebView currently holds a loaded page.
  static bool get pageAlive => _pageAlive;

  String? _pageReadyVersion;
  bool? _pageReadyResetCache;
  String? _chartSource;
  String? _chartSymbolEcho;
  Map<String, Object?>? _navTiming;
  String? _envUserAgent;

  int _runIndex = 0;
  int _runTotal = 0;

  /// Completed run records.
  List<RunRecord> get records => List<RunRecord>.unmodifiable(_records);

  /// Currently executing phase, or null when idle.
  RunPhase? get phase => _phase;

  /// Identifier of the active run.
  String? get activeRunId => _activeRunId;

  /// Whether a batch is in flight.
  bool get isRunning => _batchRunning;

  /// Elapsed microseconds in the active run.
  int get elapsedMicros => _clock?.elapsedMicroseconds ?? 0;

  /// Marks observed so far in the active run.
  Map<String, int> get marks => Map<String, int>.unmodifiable(_marks);

  /// One-based index of the active run.
  int get runIndex => _runIndex;

  /// Total runs in the batch.
  int get runTotal => _runTotal;

  /// Events discarded as belonging to another run.
  int get strayEvents => _strayEvents;

  /// Events seen during the settle window.
  int get tailEvents => _tailEvents;

  /// User agent reported by the page, which carries the WebView version.
  String? get userAgent => _envUserAgent;

  /// Whether a signal was ever observed this session.
  final Map<String, bool> capabilities = <String, bool>{
    'pageStarted': false,
    'pageProgress': false,
    'authorizeResolved': false,
    'pageCommitVisible': false,
  };

  /// Runs [configs], [repeats] times each.
  Future<void> runBatch({
    required List<RunConfig> configs,
    required int repeats,
    required Future<void> Function() awaitViewMounted,
  }) async {
    if (_batchRunning) return;
    _batchRunning = true;
    _aborted = false;
    _runIndex = 0;
    _runTotal = configs.length * repeats;
    notifyListeners();

    WebViewBridge.instance.addSink(_onEvent);
    try {
      for (int r = 0; r < repeats && !_aborted; r++) {
        for (final RunConfig config in configs) {
          if (_aborted) break;
          _runIndex++;
          await _runOnce(config, awaitViewMounted);
          if (!_aborted) await Future<void>.delayed(kSettleDelay);
        }
      }
    } finally {
      WebViewBridge.instance.removeSink(_onEvent);
      _batchRunning = false;
      _phase = null;
      _activeRunId = null;
      notifyListeners();
    }
  }

  /// Stops the batch, recording the in-flight run as aborted.
  void abort() {
    _aborted = true;
    if (_activeRunId != null) _finish(TerminalOutcome.aborted);
  }

  // -------------------------------------------------------------- one run

  Future<void> _runOnce(
    RunConfig config,
    Future<void> Function() awaitViewMounted,
  ) async {
    _resetRunState(config);

    // Stop accepting events for the previous run before anything else.
    final String runId = '$_sessionId-${++_seq}';

    _setPhase(RunPhase.mountingView);
    try {
      // Bounded: without a timeout a view that never reports creation hangs the whole batch
      // rather than failing one case.
      await awaitViewMounted().timeout(RunPhase.mountingView.budget);
    } on Object {
      // The view failed to mount in time; the case will fail on its expectations.
    }

    await _applyReset(config);

    if (config.cacheMode != 'default') {
      await IosWebViewPlugin.setCacheMode(config.cacheMode);
    }

    _activeRunId = runId;
    _activeConfig = config;
    _terminal = Completer<void>();
    _startedAt = DateTime.now();
    _clock = Stopwatch()..start();
    _capTimer = Timer(kGlobalRunCap, () => _finish(TerminalOutcome.timeout));

    if (config.changeSymbolOnWarmPage && _pageAlive) {
      // No navigation: reuse the live page and only switch symbol. This is the arm that
      // separates render cost from JavaScript boot cost.
      //
      // Deliberately does NOT mark pageStarted or pageFinished. Those marks are the evidence
      // that a navigation happened, and fabricating them here to advance the phase machine
      // destroyed exactly the signal the reuse assertions read. Only pageReady is recorded,
      // because the gate is genuinely already open.
      _mark('pageReady');
      _mark('reusedPage');
      _setPhase(RunPhase.awaitingChartTerminal);
      await _injectLoadChart(runId, config);
    } else {
      _setPhase(RunPhase.navigating);
      await IosWebViewPlugin.openWebView(
        _buildUrl(runId, config),
        javascriptChannelName: kChartChannel,
        // A channel only takes effect on the next navigation, so the session's ack channel has
        // to be registered here or a promise-returning operation can never be acknowledged.
        javascriptChannels: const <String>[kChartSessionAckChannel],
        // Never leave this defaulted for a measurement: with the legacy default a failed load
        // silently navigates to a fallback page and reports a second completion.
        isChart: false,
        disableErrorFallback: true,
        loadId: IosWebViewPlugin.nextLoadId(),
      );
      _mark('openAcked');
      _setPhase(
        capabilities['pageStarted'] == true
            ? RunPhase.awaitingPageStarted
            : RunPhase.awaitingPageFinished,
      );
    }

    await _terminal!.future;
  }

  String _buildUrl(String runId, RunConfig config) {
    final StringBuffer url = StringBuffer(kChartUrl)..write('?theme=dark');
    if (config.cacheBustUrl) url.write('&hbRun=$runId');
    return url.toString();
  }

  void _resetRunState(RunConfig config) {
    _marks.clear();
    _tailEvents = 0;
    _strayEvents = 0;
    _pageReadyVersion = null;
    _pageReadyResetCache = null;
    _chartSource = null;
    _chartSymbolEcho = null;
    _navTiming = null;
    if (!config.changeSymbolOnWarmPage) _bootstrapInstalled = false;
  }

  Future<void> _applyReset(RunConfig config) async {
    switch (config.resetMode) {
      case ResetMode.warm:
        return;
      case ResetMode.netCold:
        await IosWebViewPlugin.clearBrowsingData(preset: 'netColdSessionWarm');
      case ResetMode.sessionCold:
        // Clear while the old page is still loaded: storage is origin-scoped and the next URL
        // shares the origin, so this is equivalent to clearing afterwards and far simpler.
        if (_pageAlive) await IosWebViewPlugin.runJavaScript(hbClearAllStorageJs);
        await IosWebViewPlugin.clearBrowsingData(preset: 'netWarmSessionCold');
      case ResetMode.cold:
        if (_pageAlive) await IosWebViewPlugin.runJavaScript(hbClearAllStorageJs);
        await IosWebViewPlugin.clearBrowsingData(preset: 'cold');
    }
  }

  // -------------------------------------------------------------- phases

  void _setPhase(RunPhase next) {
    _phase = next;
    _phaseTimer?.cancel();
    _phaseTimer = Timer(next.budget, () {
      if (_phase == next) _finish(TerminalOutcome.timeout, timedOutPhase: next);
    });
    notifyListeners();
  }

  void _mark(String name) {
    _marks.putIfAbsent(name, () => _clock?.elapsedMicroseconds ?? 0);
  }

  void _finish(
    TerminalOutcome outcome, {
    RunPhase? timedOutPhase,
    String? detail,
  }) {
    final String? runId = _activeRunId;
    final RunConfig? config = _activeConfig;
    if (runId == null || config == null) return;

    // Null the generation first, so every in-flight event drains to the stray log instead of
    // contaminating the next run.
    _activeRunId = null;
    _phaseTimer?.cancel();
    _capTimer?.cancel();
    _phaseTimer = null;
    _capTimer = null;
    final RunPhase? phaseAtEnd = timedOutPhase ?? _phase;
    _phase = null;

    _records.add(
      RunRecord(
        runId: runId,
        config: config,
        outcome: outcome,
        startedAt: _startedAt ?? DateTime.now(),
        marks: Map<String, int>.of(_marks),
        timedOutPhase: outcome == TerminalOutcome.timeout ? phaseAtEnd : null,
        pageReadyVersion: _pageReadyVersion,
        pageReadyResetCache: _pageReadyResetCache,
        chartSource: _chartSource,
        chartSymbolEcho: _chartSymbolEcho,
        failureDetail: detail,
        navTiming: _navTiming,
        tailEvents: _tailEvents,
        strayEvents: _strayEvents,
      ),
    );

    if (!(_terminal?.isCompleted ?? true)) _terminal!.complete();
    notifyListeners();
  }

  // -------------------------------------------------------------- events

  void _onEvent(WebViewEvent event) {
    final String? runId = _activeRunId;
    if (runId == null) {
      _tailEvents++;
      WebViewBridge.instance.note(event, EventDisposition.postRunTail, null);
      return;
    }

    // URL-bearing events can be matched mechanically; page-origin messages cannot, so those are
    // gated on state instead.
    final String? url = switch (event) {
      WebViewPageStartedEvent(:final String url) => url,
      WebViewPageFinishedEvent(:final String url) => url,
      WebViewPageCommitVisibleEvent(:final String url) => url,
      _ => null,
    };
    final RunConfig? config = _activeConfig;
    if (url != null &&
        config != null &&
        config.cacheBustUrl &&
        !url.contains('hbRun=$runId')) {
      _strayEvents++;
      WebViewBridge.instance.note(event, EventDisposition.stray, runId);
      notifyListeners();
      return;
    }

    WebViewBridge.instance.note(event, EventDisposition.accepted, runId);

    switch (event) {
      case WebViewPageStartedEvent():
        capabilities['pageStarted'] = true;
        _mark('pageStarted');
        _setPhase(RunPhase.awaitingPageFinished);
      case WebViewPageCommitVisibleEvent():
        capabilities['pageCommitVisible'] = true;
        _mark('pageCommitVisible');
      case WebViewProgressEvent():
        capabilities['pageProgress'] = true;
      case WebViewPageFinishedEvent():
        // The load event fires *after* DOMContentLoaded, and the page emits PageReady from
        // DOMContentLoaded - so this can legitimately arrive after the gate has already
        // opened. Record it, but never move the phase backwards.
        _mark('pageFinished');
        _pageAlive = true;
        if (_phase == RunPhase.awaitingPageStarted ||
            _phase == RunPhase.awaitingPageFinished) {
          _setPhase(RunPhase.awaitingPageReady);
        }
      case WebViewErrorEvent(:final bool? isForMainFrame, :final String description):
        if (isForMainFrame ?? false) {
          _finish(TerminalOutcome.pageLoadError, detail: description);
        }
      case WebViewChannelMessageEvent(:final Map<String, Object?>? decoded):
        if (decoded != null) _handleChannelMessage(decoded, runId);
      default:
        break;
    }
    notifyListeners();
  }

  void _handleChannelMessage(Map<String, Object?> json, String runId) {
    final HarnessMessage? harness = HarnessMessage.tryParse(json);
    if (harness != null) {
      // Harness messages carry the run id, so they are correlated exactly.
      if (harness.runId != runId) {
        _strayEvents++;
        return;
      }
      switch (harness.phase) {
        case 'authorizeResolved':
          capabilities['authorizeResolved'] = true;
          _mark('authorizeResolved');
          unawaited(_afterAuthorize(runId));
        case 'authorizeRejected':
        case 'authorizeThrew':
        case 'authorizeMissing':
          _finish(
            TerminalOutcome.apiError,
            detail: '${harness.phase}: ${harness.detail}',
          );
        case 'loadChartMissing':
        case 'loadChartThrew':
          _finish(
            TerminalOutcome.pageLoadError,
            detail: '${harness.phase}: ${harness.detail}',
          );
        case 'navTiming':
          final Object? d = harness.detail;
          if (d is Map) _navTiming = Map<String, Object?>.from(d);
        case 'env':
          final Object? d = harness.detail;
          if (d is Map) _envUserAgent = d['ua']?.toString();
        default:
          break;
      }
      return;
    }

    final ChannelResponse? response = ChannelResponse.tryParse(json);
    if (response == null) return;

    switch (response.context) {
      case 'PageReady':
        // Accept it in any pre-gate phase: it comes from DOMContentLoaded, so it routinely
        // beats the load event. Only a PageReady *after* the gate has opened means the page
        // reloaded underneath us, which does invalidate the measurement.
        const Set<RunPhase> preGate = <RunPhase>{
          RunPhase.navigating,
          RunPhase.awaitingPageStarted,
          RunPhase.awaitingPageFinished,
          RunPhase.awaitingPageReady,
        };
        if (_marks.containsKey('pageReady') || !preGate.contains(_phase)) {
          _finish(TerminalOutcome.strayPageReady);
          return;
        }
        _mark('pageReady');
        _pageReadyVersion = response.success?.source;
        _pageReadyResetCache = response.success?.resetCache;
        unawaited(_afterPageReady(runId));
      case 'Chart':
        if (_phase != RunPhase.awaitingChartTerminal) return;
        final SuccessData? ok = response.success;
        final ErrorData? err = response.error;
        _mark('chartTerminal');
        if (ok != null) {
          _chartSource = ok.source;
          _chartSymbolEcho = ok.symbol;
          unawaited(_harvestThenFinish(runId, TerminalOutcome.chartSuccess));
        } else if (err != null) {
          _chartSource = err.source;
          _chartSymbolEcho = err.symbol;
          final TerminalOutcome outcome = switch (err.reason) {
            'SymbolNotFound' => TerminalOutcome.chartErrorSymbolNotFound,
            'DataNotAvailable' => TerminalOutcome.chartErrorDataNotAvailable,
            _ => TerminalOutcome.apiError,
          };
          unawaited(_harvestThenFinish(runId, outcome, detail: err.reason));
        }
      case 'refreshToken':
        _finish(TerminalOutcome.refreshTokenError, detail: response.error?.reason);
      case 'Api':
        // A subresource error; the chart may still recover, so only log it.
        break;
      default:
        break;
    }
  }

  Future<void> _afterPageReady(String runId) async {
    // The page assigns its globals at the very end of DOMContentLoaded, immediately before
    // emitting PageReady - so this is the earliest moment they exist.
    if (!_bootstrapInstalled) {
      await IosWebViewPlugin.runJavaScript(hbBootstrapJs);
      _bootstrapInstalled = true;
    }
    await IosWebViewPlugin.runJavaScript(buildEnvJs(runId));
    if (_activeRunId != runId) return;

    final RunConfig config = _activeConfig!;
    if (config.neverAuthorize) {
      // Withhold the token entirely: the page parks its unauthorised request and never settles
      // the promise, so this must reach the phase budget rather than erroring.
      _setPhase(RunPhase.awaitingChartTerminal);
      _mark('loadChartInjected');
      await IosWebViewPlugin.runJavaScript(
        buildLoadChartJs(config.symbol, runId, chartMode: config.chartMode),
      );
      return;
    }
    if (!config.authorizeFirst) {
      // Deliberately wrong order. The page parks its 401'd request and never settles the
      // promise, so this hangs until the phase budget expires - which is the point.
      _setPhase(RunPhase.awaitingChartTerminal);
      await _injectLoadChart(runId, config);
      return;
    }

    _setPhase(RunPhase.awaitingAuthorizeResolved);
    _mark('authorizeInjected');
    await IosWebViewPlugin.runJavaScript(buildAuthorizeJs(token, runId));
  }

  Future<void> _afterAuthorize(String runId) async {
    if (_activeRunId != runId) return;
    final RunConfig config = _activeConfig!;
    _setPhase(RunPhase.awaitingChartTerminal);
    await _injectLoadChart(runId, config);
  }

  Future<void> _injectLoadChart(String runId, RunConfig config) async {
    _mark('loadChartInjected');
    await IosWebViewPlugin.runJavaScript(
      buildLoadChartJs(config.symbol, runId, chartMode: config.chartMode),
    );
    if (!config.authorizeFirst) {
      // Authorise only after the chart request, to exercise the ordering defect.
      _mark('authorizeInjected');
      await IosWebViewPlugin.runJavaScript(buildAuthorizeJs(token, runId));
    }
  }

  Future<void> _harvestThenFinish(
    String runId,
    TerminalOutcome outcome, {
    String? detail,
  }) async {
    await IosWebViewPlugin.runJavaScript(buildNavTimingJs(runId));
    // Give the harvest a moment to come back through the channel before recording.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_activeRunId != runId) return;
    _finish(outcome, detail: detail);
  }

  @override
  void dispose() {
    _phaseTimer?.cancel();
    _capTimer?.cancel();
    WebViewBridge.instance.removeSink(_onEvent);
    super.dispose();
  }
}
