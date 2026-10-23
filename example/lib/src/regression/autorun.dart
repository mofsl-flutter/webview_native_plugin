import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scenario.dart';
import 'scenario_runner.dart';

/// Log name the orchestration script greps for.
const String kResultTag = 'HBRESULT';

const MethodChannel _launchChannel = MethodChannel('regression_harness/launch');

/// Arguments passed in the launch intent.
class LaunchArgs {
  /// Creates a set of launch arguments.
  const LaunchArgs({this.scenarioId, this.dimension, this.recovery, this.autorun = false});

  /// A single case id to run, e.g. `B2`.
  final String? scenarioId;

  /// A dimension code to run, e.g. `C`.
  final String? dimension;

  /// Recovery-suite case ids to run, comma separated, or `all`. Needs no token.
  final String? recovery;

  /// Whether to start running without waiting for a tap.
  final bool autorun;

  /// Whether anything was requested of the chart regression suite.
  bool get hasWork => autorun && (scenarioId != null || dimension != null);

  /// Whether the recovery suite was requested.
  bool get hasRecoveryWork => autorun && recovery != null && recovery!.isNotEmpty;

  /// Reads the launch intent.
  ///
  /// Returns empty arguments when the platform has no extras or the channel is unavailable,
  /// so the app still starts normally when launched from the launcher.
  static Future<LaunchArgs> read() async {
    try {
      final Map<Object?, Object?>? raw =
          await _launchChannel.invokeMethod<Map<Object?, Object?>>('getLaunchArgs');
      final LaunchArgs fromIntent = _parseArgs(raw);
      return fromIntent.hasRecoveryWork || fromIntent.hasWork ? fromIntent : _fromBuild();
    } on PlatformException {
      return _fromBuild();
    } on MissingPluginException {
      return _fromBuild();
    }
  }

  /// A request baked into the build with `--dart-define=RECOVERY=all` (or a comma-separated list of
  /// case ids). The launch intent is Android-only, so this is how an iOS run, or any run without
  /// `adb`, asks for the recovery suite to start by itself.
  ///
  /// `--dart-define=SCENARIO=L1` (or a comma-separated list) does the same for chart regression
  /// cases, which the launch intent otherwise selects on Android.
  static LaunchArgs _fromBuild() {
    const String recovery = String.fromEnvironment('RECOVERY');
    const String scenario = String.fromEnvironment('SCENARIO');
    if (scenario.isNotEmpty) return const LaunchArgs(scenarioId: scenario, autorun: true);
    if (recovery.isEmpty) return const LaunchArgs();
    return const LaunchArgs(recovery: recovery, autorun: true);
  }
}

/// Selects the cases [args] asks for.
///
/// [LaunchArgs.scenarioId] may be a single id or a comma-separated list, so a batch of cases
/// without an external precondition can run together in one launch instead of one `am start`
/// per case — each of which after the first would hit an already-running instance and be
/// silently swallowed (see [listenForNewLaunch]).
List<Scenario> selectScenarios(LaunchArgs args, List<Scenario> catalog) {
  if (args.scenarioId != null) {
    final Set<String> ids = args.scenarioId!.split(',').map((String s) => s.trim()).toSet();
    return catalog.where((Scenario s) => ids.contains(s.id)).toList();
  }
  if (args.dimension != null) {
    final String code = args.dimension!.toUpperCase();
    return catalog.where((Scenario s) => s.dimension.code == code).toList();
  }
  return const <Scenario>[];
}

/// Parses the raw platform map from either `getLaunchArgs` or `onNewIntent`.
LaunchArgs _parseArgs(Map<Object?, Object?>? raw) {
  if (raw == null) return const LaunchArgs();
  final Map<String, Object?> m = Map<String, Object?>.from(raw);
  return LaunchArgs(
    scenarioId: m['scenario']?.toString(),
    dimension: m['dimension']?.toString(),
    recovery: m['recovery']?.toString(),
    autorun: m['autorun']?.toString().toLowerCase() == 'true',
  );
}

/// Registers a handler for a new intent arriving while the app is already running.
///
/// A relaunch to an already-running `singleTop` activity — which is also what a real app-icon
/// tap looks like once a task exists — is delivered to `onNewIntent`, not `onCreate`, so the
/// startup-only [LaunchArgs.read] never sees it. Without this, the orchestration script's
/// `am start` after backgrounding the app would silently do nothing, which is exactly the kind
/// of gap a "reopen the app" regression case must not have.
void listenForNewLaunch(void Function(LaunchArgs args) onNewLaunch) {
  _launchChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'onNewIntent') return;
    onNewLaunch(_parseArgs(call.arguments as Map<Object?, Object?>?));
  });
}

/// Emits a verdict for the orchestration script to collect.
///
/// Uses [debugPrintSynchronously], not `debugPrint` and not `dart:developer`'s `log`. The
/// default `debugPrint` throttles to roughly 1 KB/s and silently drops and reorders, which would
/// truncate a batch. `developer.log` avoids the throttle but routes to the VM service rather
/// than stdout, so it never reaches logcat in a profile build — verified the hard way.
void emitResult(ScenarioResult result) {
  debugPrintSynchronously('$kResultTag\t${result.line}');
  // Evidence goes on its own lines. A long log line is split by the platform and every piece after
  // the first loses the tag the host script greps for, so one long line silently dropped its tail
  // (including the post-open cache census).
  for (final MapEntry<String, String> e in result.observations.summaries.entries) {
    debugPrintSynchronously('$kResultTag\t${result.scenario.id}\tEVIDENCE\t${e.key}\t${e.value}');
  }
}

/// Reports that a case could not start, so the host script shows why instead of silence.
void emitBootError(String id, String message) {
  debugPrintSynchronously('$kResultTag\t$id\tERROR\t$message');
}

/// Emits a line marking the end of a batch, so the script knows when to stop polling.
void emitDone(int total, int passed) {
  debugPrintSynchronously('$kResultTag\t__DONE__\t$passed/$total passed');
}

/// Runs [scenarios] and emits one line per case plus a terminator.
Future<void> runAndEmit(ScenarioRunner runner, List<Scenario> scenarios) async {
  int passed = 0;
  for (final Scenario s in scenarios) {
    final ScenarioResult r = await runner.run(s);
    if (r.pass) passed++;
    emitResult(r);
  }
  emitDone(scenarios.length, passed);
}
