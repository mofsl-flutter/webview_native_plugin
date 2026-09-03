import '../model/bench_models.dart';
import 'expectation.dart';

/// Which dimension of the matrix a case belongs to.
enum Dimension {
  /// Process and app lifecycle.
  process('A', 'Process lifecycle'),

  /// Screen and platform-view lifecycle.
  view('B', 'View lifecycle'),

  /// Operations on an already-loaded page.
  operation('C', 'Page operations'),

  /// Ordering, authorisation and silent-failure modes.
  ordering('D', 'Ordering & auth'),

  /// Symbol classes.
  symbol('E', 'Symbol classes'),

  /// Cache and storage state.
  storage('F', 'Cache & storage'),

  /// Network conditions.
  network('G', 'Network'),

  /// Rendering and composition.
  rendering('H', 'Rendering'),

  /// Cross-dimension pairings.
  combined('X', 'Cross-dimension');

  const Dimension(this.code, this.label);

  /// Single-letter prefix used in case ids.
  final String code;

  /// Human-readable label.
  final String label;
}

/// A precondition the host machine must establish before the app runs the case.
///
/// These are the adb-driven ones. The app cannot set them itself, so a case carrying any of these
/// is launched by the orchestration script rather than run in an in-app batch.
enum ExternalPrecondition {
  /// `pm clear` — wipes cache, DOM storage and cookies.
  fullCold,

  /// `am kill` while backgrounded — process dies, disk cache survives.
  processDeath,

  /// `am crash` — induced VM crash.
  vmCrash,

  /// `am kill-all` — device-wide pressure on cached processes.
  memoryPressure,

  /// `cmd connectivity airplane-mode enable`.
  offline,

  /// Backgrounded via HOME, then resumed.
  backgrounded;

  /// Whether this needs the host script rather than the app.
  bool get needsHost => this != ExternalPrecondition.backgrounded;
}

/// One declarative step in a scenario.
sealed class ScenarioStep {
  const ScenarioStep();

  /// Short description for the report.
  String get describe;
}

/// Pre-warms the WebView before any view mounts.
final class PreWarm extends ScenarioStep {
  /// Creates the step.
  const PreWarm({this.loadUrl = true});

  /// Whether to also start loading the page.
  final bool loadUrl;

  @override
  String get describe => 'pre-warm${loadUrl ? ' + load' : ''}';
}

/// Navigates the page and drives it to a chart terminal.
final class OpenChart extends ScenarioStep {
  /// Creates the step.
  const OpenChart(
    this.symbol, {
    this.authorizeFirst = true,
    this.neverAuthorize = false,
    this.chartMode = 'FullChart',
  });

  /// Symbol to load.
  final String symbol;

  /// When false, deliberately loads before authorising.
  final bool authorizeFirst;

  /// Withholds the token entirely, rather than merely delaying it.
  final bool neverAuthorize;

  /// Chart mode to request.
  final String chartMode;

  @override
  String get describe => 'open $symbol'
      '${neverAuthorize ? ' (no authorize)' : (authorizeFirst ? '' : ' (inverted order)')}'
      '${chartMode == 'FullChart' ? '' : ' mode=$chartMode'}';
}

/// Calls loadChart on the already-loaded page.
final class ChangeSymbol extends ScenarioStep {
  /// Creates the step.
  const ChangeSymbol(this.symbol, {this.chartMode = 'FullChart'});

  /// Symbol to switch to.
  final String symbol;

  /// Mode to request — a mismatch exercises the page's mode latch.
  final String chartMode;

  @override
  String get describe =>
      'change symbol → $symbol${chartMode == 'FullChart' ? '' : ' mode=$chartMode'}';
}

/// Injects a page operation and awaits its acknowledgement.
final class Operate extends ScenarioStep {
  /// Creates the step.
  const Operate(this.op, {this.arg});

  /// Operation name, matching the injected reporter prefix.
  final String op;

  /// Optional argument.
  final Object? arg;

  @override
  String get describe => 'op $op${arg == null ? '' : '($arg)'}';
}

/// Re-authorises with the current token.
final class ReAuthorize extends ScenarioStep {
  /// Creates the step.
  const ReAuthorize({this.token});

  /// Token to inject; null uses the session token.
  final String? token;

  @override
  String get describe => 'authorize${token == null ? '' : ' (explicit token)'}';
}

/// Re-navigates the page.
final class Reload extends ScenarioStep {
  /// Creates the step.
  const Reload({this.clearStorage = false});

  /// Whether to purge page storage first.
  final bool clearStorage;

  @override
  String get describe => clearStorage ? 'reset + reload' : 'reload';
}

/// Pushes a route over the chart, disposing the platform view.
final class NavigateAway extends ScenarioStep {
  /// Creates the step.
  const NavigateAway();

  @override
  String get describe => 'navigate away';
}

/// Pops back to the chart, recreating the platform view.
final class NavigateBack extends ScenarioStep {
  /// Creates the step.
  const NavigateBack();

  @override
  String get describe => 'navigate back';
}

/// Clears cache and/or storage.
final class ResetState extends ScenarioStep {
  /// Creates the step.
  const ResetState(this.mode);

  /// What to clear.
  final ResetMode mode;

  @override
  String get describe => 'reset ${mode.label}';
}

/// Sets the WebView cache mode.
final class SetCacheMode extends ScenarioStep {
  /// Creates the step.
  const SetCacheMode(this.mode);

  /// Cache mode name.
  final String mode;

  @override
  String get describe => 'cacheMode $mode';
}

/// Captures a page-state probe for later assertions.
final class Probe extends ScenarioStep {
  /// Creates the step.
  const Probe(this.label);

  /// Label recorded with the probe.
  final String label;

  @override
  String get describe => 'probe "$label"';
}

/// Waits a fixed period, for settling or deliberate races.
final class Wait extends ScenarioStep {
  /// Creates the step.
  const Wait(this.duration);

  /// How long to wait.
  final Duration duration;

  @override
  String get describe => 'wait ${duration.inMilliseconds} ms';
}

/// One regression case.
class Scenario {
  /// Creates a case.
  const Scenario({
    required this.id,
    required this.title,
    required this.dimension,
    required this.steps,
    required this.expectations,
    this.precondition,
    this.hypothesis,
  });

  /// Stable id, e.g. `B2`.
  final String id;

  /// One-line description.
  final String title;

  /// Matrix dimension.
  final Dimension dimension;

  /// Ordered steps.
  final List<ScenarioStep> steps;

  /// Assertions evaluated after the steps complete.
  final List<Expectation> expectations;

  /// External precondition, if any.
  final ExternalPrecondition? precondition;

  /// What this case is predicted to show, for cases probing a suspected defect.
  final String? hypothesis;

  /// Whether the orchestration script must launch this case.
  bool get needsHost => precondition?.needsHost ?? false;
}
