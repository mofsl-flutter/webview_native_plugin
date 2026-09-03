/// Configuration, phases and results for a benchmark run.
library;

/// Ordered phases of a single chart load.
enum RunPhase {
  /// Waiting for the platform view to report creation.
  mountingView('Mount platform view', Duration(seconds: 5)),

  /// `openWebView` in flight.
  navigating('Dispatch openWebView', Duration(seconds: 5)),

  /// Waiting for the native page-started event.
  awaitingPageStarted('Navigation start', Duration(seconds: 10)),

  /// Waiting for the main document to finish.
  awaitingPageFinished('Document load', Duration(seconds: 30)),

  /// Waiting for the page to announce its globals are ready.
  awaitingPageReady('JS boot (PageReady)', Duration(seconds: 20)),

  /// Waiting for the authorize promise to settle.
  awaitingAuthorizeResolved('Authorize', Duration(seconds: 15)),

  /// Waiting for the chart to report render or failure.
  awaitingChartTerminal('Chart render', Duration(seconds: 45));

  const RunPhase(this.label, this.budget);

  /// Human-readable label.
  final String label;

  /// Hard timeout for this phase.
  ///
  /// Per-phase rather than one global timer, so a hang names the phase that hung. This is what
  /// turns the page's unresolved-promise hang into data instead of a frozen app.
  final Duration budget;
}

/// How a run ended.
enum TerminalOutcome {
  /// Chart rendered.
  chartSuccess('Success'),

  /// Symbol could not be resolved.
  chartErrorSymbolNotFound('SymbolNotFound'),

  /// Symbol resolved but no bars came back.
  chartErrorDataNotAvailable('DataNotAvailable'),

  /// A chart API reported an error.
  apiError('API error'),

  /// The page asked for a token refresh.
  refreshTokenError('Token refresh'),

  /// The document itself failed to load.
  pageLoadError('Page load error'),

  /// A phase exceeded its budget.
  timeout('Timeout'),

  /// An unexpected reload invalidated the measurement.
  strayPageReady('Stray reload'),

  /// The operator aborted.
  aborted('Aborted');

  const TerminalOutcome(this.label);

  /// Human-readable label.
  final String label;

  /// Whether this outcome represents a rendered chart.
  bool get isSuccess => this == TerminalOutcome.chartSuccess;
}

/// Which cache and storage state a run starts from.
enum ResetMode {
  /// Nothing cleared.
  warm('Warm'),

  /// HTTP cache cleared, session kept.
  netCold('Net cold, session warm'),

  /// Storage cleared, network cache kept.
  sessionCold('Net warm, session cold'),

  /// Everything the app can clear.
  cold('Cold (partial)');

  const ResetMode(this.label);

  /// Human-readable label.
  final String label;
}

/// One experimental configuration.
class RunConfig {
  /// Creates a configuration.
  const RunConfig({
    required this.symbol,
    this.preWarm = false,
    this.cacheMode = 'default',
    this.resetMode = ResetMode.warm,
    this.authorizeFirst = true,
    this.neverAuthorize = false,
    this.changeSymbolOnWarmPage = false,
    this.cacheBustUrl = true,
    this.hybridComposition = false,
    this.chartMode = 'FullChart',
  });

  /// Symbol to load.
  final String symbol;

  /// Whether the WebView was pre-warmed before this run.
  final bool preWarm;

  /// WebView cache mode for this run.
  final String cacheMode;

  /// What to clear before the run.
  final ResetMode resetMode;

  /// When false, deliberately loads the chart before authorising.
  ///
  /// The page parks a 401'd request on an internal queue and never settles its promise until
  /// authorize drains it, so the wrong order hangs rather than erroring.
  final bool authorizeFirst;

  /// Never authorise at all.
  ///
  /// Distinct from [authorizeFirst] being false, which only delays it. A late token still
  /// drains the page's parked queue; withholding it entirely is what leaves the promise
  /// unsettled forever.
  final bool neverAuthorize;

  /// Reuse the already-loaded page and just switch symbol.
  ///
  /// This is the arm that isolates render cost from JavaScript boot cost.
  final bool changeSymbolOnWarmPage;

  /// Append a per-run token to the URL.
  ///
  /// Only changes the cache key of the small entry document; every expensive subresource is
  /// referenced relatively and keeps its own cache entry.
  final bool cacheBustUrl;

  /// Composite the platform view with full hybrid composition.
  final bool hybridComposition;

  /// Chart mode to request.
  ///
  /// The page latches this for the document's lifetime, so requesting a different one than the
  /// document was initialised with is refused inside the page.
  final String chartMode;

  /// Short identifier for grouping results by arm.
  String get armKey => 'pw=${preWarm ? 1 : 0},cm=$cacheMode,'
      'rm=${resetMode.name},af=${authorizeFirst ? 1 : 0},na=${neverAuthorize ? 1 : 0},'
      'cs=${changeSymbolOnWarmPage ? 1 : 0},cb=${cacheBustUrl ? 1 : 0},'
      'hc=${hybridComposition ? 1 : 0}';

  /// Copies with a different symbol.
  RunConfig withSymbol(String next) => RunConfig(
        symbol: next,
        preWarm: preWarm,
        cacheMode: cacheMode,
        resetMode: resetMode,
        authorizeFirst: authorizeFirst,
        neverAuthorize: neverAuthorize,
        changeSymbolOnWarmPage: changeSymbolOnWarmPage,
        cacheBustUrl: cacheBustUrl,
        hybridComposition: hybridComposition,
        chartMode: chartMode,
      );
}

/// Result of one run.
class RunRecord {
  /// Creates a record.
  RunRecord({
    required this.runId,
    required this.config,
    required this.outcome,
    required this.startedAt,
    required this.marks,
    this.timedOutPhase,
    this.pageReadyVersion,
    this.pageReadyResetCache,
    this.chartSource,
    this.chartSymbolEcho,
    this.failureDetail,
    this.navTiming,
    this.tailEvents = 0,
    this.strayEvents = 0,
  });

  /// Unique run identifier, also carried in the URL.
  final String runId;

  /// Configuration used.
  final RunConfig config;

  /// How it ended.
  final TerminalOutcome outcome;

  /// Wall clock at T0.
  final DateTime startedAt;

  /// Microseconds since T0 for each observed mark. A missing key means the signal never arrived,
  /// which must stay distinguishable from zero.
  final Map<String, int> marks;

  /// Phase that exceeded its budget, when [outcome] is a timeout.
  final RunPhase? timedOutPhase;

  /// Page version reported at `PageReady`.
  final String? pageReadyVersion;

  /// Whether the page purged its own storage.
  final bool? pageReadyResetCache;

  /// `initialLoad`, `changeSymbol` or `resolveSymbol`.
  final String? chartSource;

  /// Symbol the chart echoed back.
  final String? chartSymbolEcho;

  /// Extra context for a failure.
  final String? failureDetail;

  /// Resource-timing summary harvested from inside the page.
  final Map<String, Object?>? navTiming;

  /// Events that arrived after the terminal, during the settle window.
  final int tailEvents;

  /// Events discarded as belonging to another run.
  final int strayEvents;

  int? _span(String from, String to) {
    final int? a = from == 't0' ? 0 : marks[from];
    final int? b = marks[to];
    if (a == null || b == null) return null;
    return b - a;
  }

  /// Time from T0 until `openWebView` returned.
  int? get channelDispatch => _span('t0', 'openAcked');

  /// Time from T0 until navigation began.
  int? get navigation => _span('t0', 'pageStarted');

  /// Document load duration, to the load event.
  ///
  /// May overlap [jsBoot]: the load event fires after DOMContentLoaded, so it can land after
  /// the page has already announced itself ready.
  int? get documentLoad =>
      _span(marks.containsKey('pageStarted') ? 'pageStarted' : 't0', 'pageFinished');

  /// Time from navigation start until the page's globals are assigned.
  ///
  /// This is the interval where megabytes of charting-library JavaScript are fetched, parsed
  /// and compiled. Measured from `pageStarted` rather than the load event, because the page
  /// signals readiness from DOMContentLoaded, which precedes it.
  int? get jsBoot =>
      _span(marks.containsKey('pageStarted') ? 'pageStarted' : 't0', 'pageReady');

  /// Harness overhead between the gate opening and the first injection. Should be near zero.
  int? get gateWait => _span('pageReady', 'authorizeInjected');

  /// True authorize round-trip, from the bridged promise.
  int? get authorizeRtt => _span('authorizeInjected', 'authorizeResolved');

  /// Chart render duration.
  int? get chartRender => _span('loadChartInjected', 'chartTerminal');

  /// Total time to the chart terminal.
  int? get endToEnd => _span('t0', 'chartTerminal');

  /// Metric accessor by name, for tables and export.
  Map<String, int?> get metrics => <String, int?>{
        'channelDispatch': channelDispatch,
        'navigation': navigation,
        'documentLoad': documentLoad,
        'jsBoot': jsBoot,
        'gateWait': gateWait,
        'authorizeRtt': authorizeRtt,
        'chartRender': chartRender,
        'endToEnd': endToEnd,
      };
}
