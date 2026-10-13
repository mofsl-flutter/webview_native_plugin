import '../config/endpoints.dart';
import '../model/bench_models.dart';
import 'expectation.dart';
import 'harness_ack.dart';
import 'scenario.dart';

/// Symbols used across the catalog.
const String kEquityA = '0:22';
const String kEquityB = '0:3045';
const String kIndex = 'IDX:0:NIFTY 50';
const String kMalformedIndex = '0:NIFTY 50';

bool _loadIdSurvivedRecreate(ScenarioObservations o) {
  final Object? before = o.probes['beforeRecreate']?['sessionLoadId'];
  final Object? after = o.probes['afterRecreate']?['loadId'];
  return before != null && after != null && before == after;
}

bool _atLeastOneLiveView(ScenarioObservations o) {
  final Object? views = o.probes['afterRecreate']?['livePlatformViews'];
  return views is int && views >= 1;
}

bool _vanishedOperationWasReported(ScenarioObservations o) {
  final Object? status = o.probes['ackTimeout']?['status'];
  return status == 'timeout' || status == 'threw';
}

/// The regression cases, in the order they should be run.
///
/// The first group pins **suspected live defects**. Those cases are written so that the
/// assertion passes when the defect reproduces — a green result means "still broken, as
/// documented"; a red one means the behaviour changed and the design notes need revisiting.
/// Every such case carries a [Scenario.hypothesis].
List<Scenario> buildCatalog() => <Scenario>[
      // ---------------------------------------------------------------- D0
      Scenario(
        id: 'D0',
        title: 'Operate immediately after a resume-triggered reload',
        dimension: Dimension.ordering,
        hypothesis: 'The host reloads on every resume, which drops its state below the '
            'injection threshold, so every call until the next PageReady is discarded with '
            'only a debug log. Expect a silent skip.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('beforeReload'),
          Reload(),
          // No wait: this is the point. Operate inside the window the reload opens.
          Operate('changeTheme', arg: 'light'),
          Probe('afterOperate'),
        ],
        expectations: const <Expectation>[
          ExpectSilentSkip(
            'changeTheme',
            knownDefect: 'injection is gated below pageLoaded after reload()',
          ),
        ],
      ),

      // ---------------------------------------------------------------- I2
      Scenario(
        id: 'I2',
        title: 'Unauthorised load on a cold page reports nothing',
        dimension: Dimension.ordering,
        hypothesis: 'A 401 before the first loadChart cannot emit refreshToken, because the '
            'gate flag is unset until a load runs and the first symbol lookup precedes it. '
            'Expect a timeout with no error event at all.',
        steps: const <ScenarioStep>[
          ResetState(ResetMode.sessionCold),
          // The token is withheld entirely — merely delaying it recovers (see D2).
          OpenChart(kEquityA, neverAuthorize: true),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.timeout),
          ExpectMarkAbsent('chartTerminal', because: 'no chart event should arrive'),
          // The claim being tested: the failure is never reported to native at all.
          ExpectNoPageError(),
        ],
      ),

      // ---------------------------------------------------------------- B2
      Scenario(
        id: 'B2',
        title: 'Navigate away and back reuses the loaded page',
        dimension: Dimension.view,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('beforeAway'),
          NavigateAway(),
          Wait(Duration(milliseconds: 600)),
          NavigateBack(),
          Probe('afterBack'),
          ChangeSymbol(kEquityB),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
          ExpectMarkAbsent(
            'pageStarted',
            because: 'the page must survive platform-view disposal',
          ),
          ExpectChartSource('changeSymbol'),
          ExpectProbe('afterBack', 'widgetReady', true),
          ExpectNoStrays(),
        ],
      ),

      // ---------------------------------------------------------------- B9
      Scenario(
        id: 'B9',
        title: 'Chart screen rebuilt from scratch inherits the real page state',
        dimension: Dimension.view,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('beforeRecreate'),
          RecreateHost('afterRecreate'),
          // The reuse assertion needs a load issued *after* the rebuild: ExpectMarkAbsent reads
          // the last record, and the opening navigation legitimately carries pageStarted.
          ChangeSymbol(kEquityB),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
          // The whole point: a State built from nothing must not believe the page is blank.
          ExpectProbe('afterRecreate', 'isPageLoaded', true),
          ExpectProbe('afterRecreate', 'pageStarted', true),
          ExpectProbe('afterRecreate', 'isAttached', true),
          // Deliberately not asserting livePlatformViews == 1. Measured at 2 in a batch run:
          // the harness handles onNewIntent by pushing a *new* regression screen, and the
          // screens below stay in the tree with their platform views still mounted. That count
          // is therefore a property of how many launches stacked, not of the session — and the
          // session correctly reports the newest view as the attached one either way.
          ExpectCustom(
            'the session tracks at least one live platform view',
            _atLeastOneLiveView,
          ),
          // Same document, not a re-navigation: persistence across disposal is what makes the
          // inherited state meaningful in the first place.
          ExpectCustom(
            'loadId unchanged across the host rebuild',
            _loadIdSurvivedRecreate,
          ),
          ExpectMarkAbsent(
            'pageStarted',
            because: 'rebuilding the host State must not re-navigate the page',
          ),
        ],
      ),

      // ---------------------------------------------------------------- C13
      Scenario(
        id: 'C13',
        title: 'Unacknowledged operation reports a timeout, not silence',
        dimension: Dimension.operation,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          // A function that does not exist on any page. The plain runJavaScript path discards
          // this outcome entirely; the tracked path must name it.
          OperateTracked(
            'ackTimeout',
            'return window.__noSuchChartFunction__();',
            timeout: Duration(seconds: 3),
          ),
          OperateTracked(
            'ackOk',
            'return 1;',
            timeout: Duration(seconds: 3),
          ),
        ],
        expectations: const <Expectation>[
          // `threw` is also an acceptable report — what must never happen is silence.
          ExpectCustom(
            'a vanished operation is reported, not silent',
            _vanishedOperationWasReported,
          ),
          // The negative control for the control: a trivially valid script must report ok, or
          // the ack channel is simply not wired up and the assertion above is vacuous.
          ExpectProbe('ackOk', 'status', 'ok'),
        ],
      ),

      // ---------------------------------------------------------------- C2
      Scenario(
        id: 'C2',
        title: 'Change symbol on a live page',
        dimension: Dimension.operation,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('symbolA'),
          ChangeSymbol(kEquityB),
          Probe('symbolB'),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
          ExpectMarkAbsent('pageStarted', because: 'reuse must not re-navigate'),
          ExpectChartSource('changeSymbol'),
          ExpectProbeChanged('symbolA', 'symbolB', 'symbol'),
          // This is the number that decides whether the library dominates chartRender.
          ExpectPhaseUnder('endToEnd', Duration(seconds: 3)),
        ],
      ),

      // ---------------------------------------------------------------- C3
      Scenario(
        id: 'C3',
        title: 'Request a different chart mode on a loaded page',
        dimension: Dimension.operation,
        hypothesis: 'The page latches chart mode for the document lifetime and returns early '
            'on a mismatch, logging only to its own console. Latent in production (the host '
            'only ever uses one mode) but a trap if compact mode is ever enabled.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('beforeModeSwitch'),
          ChangeSymbol(kEquityB, chartMode: 'LightWeightChart'),
          Probe('afterModeSwitch'),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.timeout),
          ExpectCustom(
            'symbol did not change despite the load call',
            _symbolUnchanged,
          ),
        ],
      ),

      // ---------------------------------------------------------------- C4
      Scenario(
        id: 'C4',
        title: 'Change theme with a valid value',
        dimension: Dimension.operation,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('themeBefore'),
          Operate('changeTheme', arg: 'light'),
          Wait(Duration(milliseconds: 800)),
          Probe('themeAfter'),
        ],
        expectations: const <Expectation>[
          ExpectAck('changeTheme'),
          ExpectProbeChanged('themeBefore', 'themeAfter', 'theme'),
        ],
      ),

      // ---------------------------------------------------------------- C4b
      Scenario(
        id: 'C4b',
        title: 'Change theme with a wrongly-cased value',
        dimension: Dimension.operation,
        hypothesis: 'The page applies a strict dark|light allowlist with no fallback, so a '
            'capitalised value is a total no-op — not even the stored value changes.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('themeBefore'),
          Operate('changeTheme', arg: 'Dark'),
          Wait(Duration(milliseconds: 500)),
          Probe('themeAfter'),
        ],
        expectations: const <Expectation>[
          // It is acknowledged as *called* — the no-op is inside the page.
          ExpectAck('changeTheme'),
          ExpectCustom('theme unchanged by an invalid value', _themeUnchanged),
        ],
      ),

      // ---------------------------------------------------------------- C5
      Scenario(
        id: 'C5',
        title: 'setTimeFrame in the default chart mode',
        dimension: Dimension.operation,
        hypothesis: 'setTimeFrame routes only to the compact chart, whose widget does not '
            'exist in the default mode, so it warns and returns. Structurally inapplicable '
            'rather than merely unacknowledged.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('tfBefore'),
          Operate('setTimeFrame', arg: 'D'),
          Wait(Duration(milliseconds: 800)),
          Probe('tfAfter'),
        ],
        expectations: const <Expectation>[
          ExpectAck('setTimeFrame'),
          ExpectCustom('resolution unchanged', _resolutionUnchanged),
        ],
      ),

      // ---------------------------------------------------------------- C9
      Scenario(
        id: 'C9',
        title: 'chartEvents on mobile',
        dimension: Dimension.operation,
        hypothesis: 'The fullscreen button is only built on the web path, so this dereferences '
            'undefined and throws — the one entry point that surfaces a visible error.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Operate('chartEvents', arg: 'startfullscreen'),
        ],
        expectations: const <Expectation>[
          ExpectAck('chartEvents', allow: <AckStatus>{AckStatus.threw}),
        ],
      ),

      // ---------------------------------------------------------------- C7
      Scenario(
        id: 'C7',
        title: 'Live tick for a symbol that was never resolved',
        dimension: Dimension.operation,
        hypothesis: 'The page looks the symbol up in its cache and returns with no log at '
            'all when absent, so a mismatched symbol format drops every tick invisibly.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Operate('appendLiveTick', arg: '0:999999'),
          Probe('afterTick'),
        ],
        expectations: const <Expectation>[
          // Called successfully — the drop is silent and internal.
          ExpectAck('appendLiveTick'),
          ExpectCustom(
            'unresolved symbol absent from the page cache',
            _unresolvedSymbolNotCached,
          ),
        ],
      ),

      // ---------------------------------------------------------------- E3
      Scenario(
        id: 'E3',
        title: 'Index symbol with the IDX prefix',
        dimension: Dimension.symbol,
        steps: const <ScenarioStep>[OpenChart(kIndex), Probe('index')],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
          ExpectProbe('index', 'widgetReady', true),
        ],
      ),

      // ---------------------------------------------------------------- E4
      Scenario(
        id: 'E4',
        title: 'Malformed index symbol',
        dimension: Dimension.symbol,
        hypothesis: 'The lookup returns no content, which the page treats as an error, and '
            'failures are never cached — so the request repeats unboundedly.',
        steps: const <ScenarioStep>[OpenChart(kMalformedIndex)],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartErrorSymbolNotFound),
        ],
      ),

      // ---------------------------------------------------------------- D2
      Scenario(
        id: 'D2',
        title: 'Authorise late, after the load has been requested',
        dimension: Dimension.ordering,
        hypothesis: 'Measured: this does NOT hang. The late token drains the page\'s parked '
            'queue and the symbol resolves — but the history request that 401\'d already told '
            'the charting library there is no data, and the library stops asking. So a late '
            'token yields a permanently EMPTY chart rather than a recovered one. That is worse '
            'than a hang, because it looks like a successfully loaded chart with no bars.',
        steps: const <ScenarioStep>[
          ResetState(ResetMode.sessionCold),
          OpenChart(kEquityA, authorizeFirst: false),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartErrorDataNotAvailable),
        ],
      ),

      // ---------------------------------------------------------------- D2b
      Scenario(
        id: 'D2b',
        title: 'Never authorise at all',
        dimension: Dimension.ordering,
        hypothesis: 'With the token withheld entirely the page parks its request and never '
            'settles the promise, so nothing terminal ever arrives and the phase budget is the '
            'only thing that ends the run.',
        steps: const <ScenarioStep>[
          ResetState(ResetMode.sessionCold),
          OpenChart(kEquityA, neverAuthorize: true),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.timeout),
          ExpectMarkAbsent('chartTerminal', because: 'no chart event should ever arrive'),
        ],
      ),

      // ---------------------------------------------------------------- D8
      Scenario(
        id: 'D8',
        title: 'Drain the parked queue without re-authorising',
        dimension: Dimension.ordering,
        hypothesis: 'The page exposes a queue-drain the host never calls. If it unsticks a '
            'parked request without a token, it is a viable recovery primitive.',
        steps: const <ScenarioStep>[
          ResetState(ResetMode.sessionCold),
          OpenChart(kEquityA, authorizeFirst: false),
          ReAuthorize(),
          Operate('drain401'),
          Wait(Duration(seconds: 3)),
          Probe('afterDrain'),
        ],
        expectations: const <Expectation>[
          ExpectAck('drain401'),
        ],
      ),

      // ---------------------------------------------------------------- H3
      Scenario(
        id: 'H3',
        title: 'Pre-warmed WebView removes the first-open navigation cost',
        dimension: Dimension.rendering,
        steps: const <ScenarioStep>[
          PreWarm(),
          Wait(Duration(seconds: 4)),
          OpenChart(kEquityA),
        ],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
          // The measured cold first-open navigation was ~1.2 s; pre-warm should land far under.
          ExpectPhaseUnder('navigation', Duration(milliseconds: 400)),
        ],
      ),

      // ---------------------------------------------------------------- H4
      Scenario(
        id: 'H4',
        title: 'Load-free pre-warm still removes most of the navigation cost',
        dimension: Dimension.rendering,
        steps: const <ScenarioStep>[
          // Deliberately loadUrl: false. H3 pre-warms *with* a load, so its figure folds in
          // subresource cache priming; this isolates the WebView/Chromium construction share,
          // which is the only part a production pre-warm can take without creating page state.
          PreWarm(loadUrl: false),
          Wait(Duration(seconds: 2)),
          OpenChart(kEquityA),
        ],
        expectations: const <Expectation>[
          // No navigation budget is asserted: the point of this case is the number, and the
          // comparison that matters is cross-case (against A1 cold and H3 warm in the same run),
          // which the expectation framework cannot express. A budget here would either be
          // vacuous or flaky.
          ExpectOutcome(TerminalOutcome.chartSuccess),
          ExpectNoStrays(),
        ],
      ),

      // ---------------------------------------------------------------- F3
      Scenario(
        id: 'F3',
        title: 'Storage cleared forces a re-authorise',
        dimension: Dimension.storage,
        hypothesis: 'Clearing storage destroys the stored token. The page only reports its '
            'purge flag on a version change, so on a plain wipe the flag stays false and the '
            'host must authorise unconditionally.',
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          ResetState(ResetMode.sessionCold),
          Probe('afterWipe'),
          Reload(),
          Wait(Duration(seconds: 4)),
          ReAuthorize(),
          ChangeSymbol(kEquityB),
        ],
        expectations: const <Expectation>[
          ExpectProbe('afterWipe', 'hasToken', false),
          ExpectAck('authorize'),
          ExpectOutcome(TerminalOutcome.chartSuccess),
        ],
      ),

      // ---------------------------------------------------------------- A3
      Scenario(
        id: 'A3',
        title: 'Resume from background with the page alive',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.backgrounded,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA),
          Probe('beforeBackground'),
          // The host script backgrounds and resumes between these steps.
          Wait(Duration(seconds: 2)),
          Probe('afterResume'),
          ChangeSymbol(kEquityB),
        ],
        expectations: const <Expectation>[
          ExpectMarkAbsent('pageStarted', because: 'resume must not re-navigate'),
          ExpectProbe('afterResume', 'widgetReady', true),
          ExpectOutcome(TerminalOutcome.chartSuccess),
        ],
      ),

      // ---------------------------------------------------------------- A1
      Scenario(
        id: 'A1',
        title: 'Full cold first load',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.fullCold,
        hypothesis: 'Settles whether the multi-megabyte charting bundle is actually fetched '
            'per cold open, which the warm runs could not show.',
        steps: const <ScenarioStep>[OpenChart(kEquityA)],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
        ],
      ),

      // ---------------------------------------------------------------- K0..K3
      // Cache-lifetime study. Each case opens the chart, lets the page settle long enough for the
      // library's lazy chunks to load, then records (a) how the library's files were served and
      // (b) what Chromium holds on disk. K0 primes; K1-K3 are launched by the host script *after*
      // it has primed with K0 and applied a precondition, so their `atLaunch` census doubles as
      // proof the precondition did what it claims.
      //
      // They assert that the measurement is valid, not that the chart drew data: the question is
      // how the library was served, which does not depend on the market-data backend answering.
      Scenario(
        id: 'K0',
        title: 'Library cache baseline after a cold open',
        dimension: Dimension.storage,
        hypothesis: 'Run straight after a full data wipe, every library file should classify as a '
            'download; run on a warm app, as hit or revalidated. Used by the host script as the '
            'priming launch for K1-K3.',
        steps: _cacheStudySteps,
        expectations: const <Expectation>[
          ExpectCustom('the library bundle was observed and classified', _libraryObserved),
        ],
      ),
      Scenario(
        id: 'K1',
        title: 'Library cache after the process is killed',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.processDeath,
        hypothesis: 'The HTTP cache is on disk, so a swiped-away app should relaunch with the '
            'library served from cache. Whether that is a pure hit or a 304 per file depends on '
            'the heuristic freshness window, which is what the classification shows.',
        steps: _cacheStudySteps,
        expectations: const <Expectation>[
          ExpectCustom('the library bundle was observed and classified', _libraryObserved),
        ],
      ),
      Scenario(
        id: 'K2',
        title: 'Library cache after a force-stop',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.forceStop,
        hypothesis: 'Some OEMs implement swipe-from-recents as a force-stop. The disk cache '
            'should survive that too, so this should match K1.',
        steps: _cacheStudySteps,
        expectations: const <Expectation>[
          ExpectCustom('the library bundle was observed and classified', _libraryObserved),
        ],
      ),
      Scenario(
        id: 'K3',
        title: 'Library cache after the OS trims the app cache',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.cacheTrimmed,
        hypothesis: 'Low-storage eviction empties the HTTP cache but leaves cookies and DOM '
            'storage, so the library should be downloaded again while the user stays signed in. '
            'This is the case a bundled library fixes. If `atLaunch` shows the cache not '
            'actually emptied, the trim did nothing on this device and the result is void.',
        steps: _cacheStudySteps,
        expectations: const <Expectation>[
          ExpectCustom('the library bundle was observed and classified', _libraryObserved),
        ],
      ),

      // ---------------------------------------------------------------- W0..W2, WC
      // Cache warm-up. The question is whether a fetch made from a throwaway WebView on the chart
      // origin fills the same HTTP cache entries the chart's library iframe later reads. W1 asks it
      // within one process (the new-install case); W2 asks it across a process kill, which rules
      // out the renderer's in-memory cache standing in for the disk cache.
      Scenario(
        id: 'W0',
        title: 'Warm-up fills the HTTP cache from the chart origin',
        dimension: Dimension.storage,
        hypothesis: 'The warm-up page must report the chart origin, or its requests land in a '
            'different cache partition and every later chart request misses. Also the primer '
            'for W2.',
        steps: const <ScenarioStep>[
          CacheCensus('atLaunch'),
          WarmLibCache(),
          CacheCensus('afterWarm'),
        ],
        expectations: const <Expectation>[
          ExpectCustom('the warm-up ran on the chart origin and succeeded', _warmedFromChartOrigin),
          ExpectCustom('the warm-up wrote to the HTTP cache', _warmFilledDiskCache),
        ],
      ),
      Scenario(
        id: 'W1',
        title: 'New install: warm-up first, then the chart opens from cache',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.fullCold,
        hypothesis: 'After a warm-up on an empty cache, opening the chart should classify the '
            'library as cache hits and transfer almost nothing. JS boot is not asserted: the '
            'warm-up fills the network cache, not the compiled-code cache.',
        steps: const <ScenarioStep>[
          CacheCensus('atLaunch'),
          WarmLibCache(),
          CacheCensus('afterWarm'),
          OpenChart(kEquityA, budgetScale: 12),
          WaitForLibQuiet(),
          LibCacheProbe('settled'),
          CacheCensus('afterOpen'),
        ],
        expectations: const <Expectation>[
          ExpectCustom('the warm-up ran on the chart origin and succeeded', _warmedFromChartOrigin),
          ExpectCustom('the library was served from the warmed cache', _libraryServedFromCache),
        ],
      ),
      Scenario(
        id: 'W2',
        title: 'Warm-up survives a process kill',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.processDeath,
        hypothesis: 'The warmed entries are on disk, so a relaunch after the process dies should '
            'read the library from cache exactly as it does after a normal open (K1).',
        steps: _cacheStudySteps,
        expectations: const <Expectation>[
          ExpectCustom('the library was served from the warmed cache', _libraryServedFromCache),
        ],
      ),
      Scenario(
        id: 'W3',
        title: 'A second warm-up is nearly free',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.fullCold,
        hypothesis: 'Everything the first warm-up fetched is now cached, so a second should '
            'classify as hits and transfer almost nothing. This is what makes re-triggering on '
            'every login and app start cheap.',
        steps: const <ScenarioStep>[
          WarmLibCache(label: 'warm1'),
          WarmLibCache(label: 'warm2'),
          CacheCensus('afterWarm'),
        ],
        expectations: const <Expectation>[
          ExpectCustom('the first warm-up succeeded on the chart origin', _warm1Ok),
          ExpectCustom('the second warm-up was served from cache', _warm2Cached),
        ],
      ),
      Scenario(
        id: 'W4',
        title: 'A warm-up racing the chart open does not double the download',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.fullCold,
        hypothesis: 'The warm-up and the chart ask for the same files at the same time. Chromium '
            'can attach a second request to an in-progress cache write, so the total over the '
            'wire should stay near one cold load (1.74 MB), not two.',
        steps: const <ScenarioStep>[
          WarmLibCache(background: true),
          OpenChart(kEquityA, budgetScale: 12),
          AwaitWarm('warm'),
          WaitForLibQuiet(),
          LibCacheProbe('settled'),
        ],
        expectations: const <Expectation>[
          ExpectCustom('the warm-up finished on the chart origin', _warmedFromChartOrigin),
          ExpectCustom('the library bundle was observed and classified', _libraryObserved),
          ExpectCustom('the combined download stayed under 130% of one cold load', _noDoubleDownload),
        ],
      ),
      Scenario(
        id: 'W5',
        title: 'A missing manifest does nothing and says so',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.fullCold,
        hypothesis: 'The web team has not published the manifest yet. The warm-up must report '
            '`manifest missing` and leave the cache alone, so shipping the app first is safe.',
        steps: const <ScenarioStep>[
          // A path that can never exist, so the case keeps meaning "missing" once a real manifest
          // is published.
          WarmLibCache(manifestPath: 'no-such-manifest-for-this-test.json'),
          CacheCensus('afterWarm'),
        ],
        expectations: const <Expectation>[
          ExpectCustom('the warm-up reported the manifest missing', _manifestMissing),
          ExpectCustom('nothing was downloaded', _cacheStillEmpty),
        ],
      ),
      // Not a regression: captures the file list the warm-up cases use. Run by
      // tool/capture_chart_lib_urls.sh, not by the suite.
      Scenario(
        id: 'WC',
        title: 'Capture the chart library URLs for the warm-up fixture',
        dimension: Dimension.storage,
        precondition: ExternalPrecondition.fullCold,
        steps: const <ScenarioStep>[
          OpenChart(kEquityA, budgetScale: 12),
          WaitForLibQuiet(),
          CaptureLibUrls(),
        ],
        expectations: const <Expectation>[
          ExpectCustom('library URLs were captured', _urlsCaptured),
        ],
      ),

      // ---------------------------------------------------------------- G2
      Scenario(
        id: 'G2',
        title: 'Offline at load',
        dimension: Dimension.network,
        precondition: ExternalPrecondition.offline,
        hypothesis: 'A rejected fetch inside the page cannot be reported by construction, so '
            'expect a timeout with no page-side error rather than a clean failure.',
        steps: const <ScenarioStep>[OpenChart(kEquityA)],
        expectations: const <Expectation>[
          ExpectCustom('terminated without hanging the app', _terminated),
        ],
      ),

      // ---------------------------------------------------------------- A5
      Scenario(
        id: 'A5',
        title: 'Recovery after an induced crash',
        dimension: Dimension.process,
        precondition: ExternalPrecondition.vmCrash,
        steps: const <ScenarioStep>[OpenChart(kEquityA)],
        expectations: const <Expectation>[
          ExpectOutcome(TerminalOutcome.chartSuccess),
        ],
      ),
    ];

/// Steps shared by the cache-lifetime cases.
///
/// The wait matters: the library loads some chunks lazily, after the chart reports a terminal, and
/// a probe taken at the terminal event would classify only the eager ones. It polls rather than
/// sleeping a fixed time so the same cases are valid on a fast link and on a throttled one.
///
/// The 12x budget is for slow networks: a cold load at GPRS speed takes minutes, against the
/// ~11 s the budgets were sized for. It only raises the ceiling, so a fast run still ends when the
/// chart does.
const List<ScenarioStep> _cacheStudySteps = <ScenarioStep>[
  CacheCensus('atLaunch'),
  OpenChart(kEquityA, budgetScale: 12),
  WaitForLibQuiet(),
  LibCacheProbe('settled'),
  CacheCensus('afterOpen'),
];

// Predicates kept top-level so the scenarios can stay `const`.

bool _symbolUnchanged(ScenarioObservations o) {
  final Object? before = o.probes['beforeModeSwitch']?['symbol'];
  final Object? after = o.probes['afterModeSwitch']?['symbol'];
  return before != null && before == after;
}

bool _themeUnchanged(ScenarioObservations o) =>
    o.probes['themeBefore']?['theme'] == o.probes['themeAfter']?['theme'];

bool _resolutionUnchanged(ScenarioObservations o) =>
    o.probes['tfBefore']?['resolution'] == o.probes['tfAfter']?['resolution'];

bool _unresolvedSymbolNotCached(ScenarioObservations o) {
  final Object? keys = o.probes['afterTick']?['symbolKeys'];
  if (keys is! List) return false;
  return !keys.contains('0:999999');
}

bool _terminated(ScenarioObservations o) => o.records.isNotEmpty;

/// The warm-up succeeded and its page really had the chart's origin.
///
/// Checking the origin is the point: a `loadDataWithBaseURL` page that ended up with an opaque
/// origin would still fetch every file and report success, while filling a cache partition the
/// chart never reads.
bool _warmedFromChartOrigin(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['warm'];
  return p != null && p['ok'] == true && p['origin'] == Uri.parse(kChartUrl).origin;
}

/// The census after the warm-up shows the HTTP cache actually holds data now.
bool _warmFilledDiskCache(ScenarioObservations o) {
  final Object? bytes = o.probes['afterWarm']?['httpBytes'];
  return bytes is num && bytes > 1000000;
}

/// After a warm-up the chart open was served from cache: nearly everything a hit or a
/// revalidation, and almost nothing transferred.
///
/// The thresholds are the plan's: at most 5% downloads, and no more than 175 KB over the wire,
/// against 1.74 MB for the cold open this is meant to avoid.
bool _libraryServedFromCache(ScenarioObservations o) {
  if (!_libraryObserved(o)) return false;
  final Map<String, Object?> p = o.probes['settled']!;
  final Object? entries = p['entries'];
  final Object? downloads = p['download'];
  final Object? transferred = p['bytesTransfer'];
  return entries is num &&
      downloads is num &&
      transferred is num &&
      downloads <= entries * 0.05 &&
      transferred <= 175000;
}

bool _warm1Ok(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['warm1'];
  return p != null && p['ok'] == true && p['origin'] == Uri.parse(kChartUrl).origin;
}

bool _warm2Cached(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['warm2'];
  final Object? counts = p?['counts'];
  final Object? files = p?['files'];
  final Object? transferred = p?['bytesTransfer'];
  if (p == null || p['ok'] != true || counts is! Map || files is! num || transferred is! num) {
    return false;
  }
  final Object? downloads = counts['download'];
  return downloads is num && downloads <= files * 0.05 && transferred <= 175000;
}

/// One cold load is 1.74 MB over the wire. A warm-up and a chart open that each fetched
/// everything would be about twice that, so 130% leaves room for the few files that overlap
/// without hiding a real duplicate.
bool _noDoubleDownload(ScenarioObservations o) {
  final Object? warmed = o.probes['warm']?['bytesTransfer'];
  final Object? opened = o.probes['settled']?['bytesTransfer'];
  return warmed is num && opened is num && warmed + opened <= 1740000 * 1.3;
}

bool _manifestMissing(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['warm'];
  return p != null && p['ok'] == false && p['reason'] == 'manifest missing';
}

bool _cacheStillEmpty(ScenarioObservations o) {
  final Object? bytes = o.probes['afterWarm']?['httpBytes'];
  return bytes is num && bytes < 100000;
}

bool _urlsCaptured(ScenarioObservations o) {
  final Object? count = o.probes['libUrls']?['count'];
  return count is num && count > 20 && o.probes['libUrls']?['error'] == null;
}

/// The post-settle probe saw the library bundle itself, not merely some page script.
///
/// "Saw any resource" is too weak: on a link too slow to finish loading, the page's own small
/// scripts arrive and the multi-megabyte library never starts, which would still pass and read as
/// a measurement of nothing. An empty, errored or bundle-less probe must fail loudly rather than
/// record a confident-looking result.
bool _libraryObserved(ScenarioObservations o) {
  final Map<String, Object?>? p = o.probes['settled'];
  if (p == null || p['error'] != null) return false;
  final Object? files = p['files'];
  return files is List &&
      files.any((Object? f) => f is String && f.startsWith('library.') && f.endsWith('.js'));
}
