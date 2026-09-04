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
