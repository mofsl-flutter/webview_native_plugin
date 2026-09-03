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
  const LaunchArgs({this.scenarioId, this.dimension, this.autorun = false});

  /// A single case id to run, e.g. `B2`.
  final String? scenarioId;

  /// A dimension code to run, e.g. `C`.
  final String? dimension;

  /// Whether to start running without waiting for a tap.
  final bool autorun;

  /// Whether anything was requested.
  bool get hasWork => autorun && (scenarioId != null || dimension != null);

  /// Reads the launch intent.
  ///
  /// Returns empty arguments when the platform has no extras or the channel is unavailable,
  /// so the app still starts normally when launched from the launcher.
  static Future<LaunchArgs> read() async {
    try {
      final Map<Object?, Object?>? raw =
          await _launchChannel.invokeMethod<Map<Object?, Object?>>('getLaunchArgs');
      return _parseArgs(raw);
    } on PlatformException {
      return const LaunchArgs();
    } on MissingPluginException {
      return const LaunchArgs();
    }
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
