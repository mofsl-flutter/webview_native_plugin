import 'package:flutter/foundation.dart';

import 'autorun.dart' show kResultTag;
import 'expectation.dart';
import 'recovery_case.dart';

/// Outcome of one recovery case.
class RecoveryResult {
  /// Creates a result.
  RecoveryResult({
    required this.recoveryCase,
    this.checks = const <ExpectationResult>[],
    this.error,
    this.skipReason,
  });

  /// The case that ran.
  final RecoveryCase recoveryCase;

  /// Per-check verdicts.
  final List<ExpectationResult> checks;

  /// Set when the case threw before its checks could be evaluated.
  final String? error;

  /// Set when the case did not apply to this platform or build.
  final String? skipReason;

  /// Whether the case was skipped.
  bool get skipped => skipReason != null;

  /// Whether every check held and nothing threw.
  bool get pass =>
      !skipped &&
      error == null &&
      checks.isNotEmpty &&
      checks.every((ExpectationResult r) => r.pass);

  /// Checks that did not hold.
  List<ExpectationResult> get failures =>
      checks.where((ExpectationResult r) => !r.pass).toList();

  /// Verdict word used in the log.
  String get verdict => skipped ? 'SKIP' : (error != null ? 'ERROR' : (pass ? 'PASS' : 'FAIL'));

  /// One-line summary for the log, in the same tab-separated shape as the regression suite.
  String get line {
    final String detail = skipReason ?? error ?? failures.map((ExpectationResult f) => f.toString()).join(' | ');
    return '${recoveryCase.id}\t$verdict\t${recoveryCase.title}${detail.isEmpty ? '' : '\t$detail'}';
  }
}

/// Runs recovery cases, one at a time.
class RecoveryRunner extends ChangeNotifier {
  /// Creates a runner.
  RecoveryRunner({required this.context, this.isAndroid = true});

  /// What the cases work with.
  final RecoveryContext context;

  /// Whether this is an Android run, for skipping Android-only cases.
  final bool isAndroid;

  final Map<String, RecoveryResult> _results = <String, RecoveryResult>{};
  RecoveryCase? _current;
  bool _running = false;

  /// Results so far, by case id.
  Map<String, RecoveryResult> get results => Map<String, RecoveryResult>.unmodifiable(_results);

  /// The case in flight.
  RecoveryCase? get current => _current;

  /// Whether anything is running.
  bool get isRunning => _running;

  /// Runs [cases] in order.
  Future<void> runAll(List<RecoveryCase> cases, {void Function(RecoveryResult)? onResult}) async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      for (final RecoveryCase c in cases) {
        final RecoveryResult r = await run(c);
        onResult?.call(r);
      }
    } finally {
      _running = false;
      _current = null;
      notifyListeners();
    }
  }

  /// Runs one case.
  Future<RecoveryResult> run(RecoveryCase c) async {
    final String? skip = _skipReason(c);
    if (skip != null) {
      return _results[c.id] = RecoveryResult(recoveryCase: c, skipReason: skip);
    }
    _current = c;
    notifyListeners();
    RecoveryResult result;
    try {
      final List<ExpectationResult> checks = await c.run(context);
      result = RecoveryResult(recoveryCase: c, checks: checks);
    } on Object catch (e) {
      result = RecoveryResult(recoveryCase: c, error: e.toString());
    } finally {
      // Never leave a stray engine behind for the next case.
      try {
        await context.engines.disposeAll();
      } on Object {
        // Best effort.
      }
    }
    _results[c.id] = result;
    _current = null;
    notifyListeners();
    return result;
  }

  String? _skipReason(RecoveryCase c) {
    if (c.androidOnly && !isAndroid) return 'needs Android';
    if (c.debugOnly && !kDebugMode) return 'needs a debug build';
    return null;
  }

  @override
  void dispose() {
    context.tape.dispose();
    super.dispose();
  }
}

/// Emits one verdict line for a host script to collect.
void emitRecoveryResult(RecoveryResult r) {
  debugPrintSynchronously('$kResultTag\t${r.line}');
}

/// Emits the end-of-batch marker the host script waits for.
void emitRecoveryDone(int total, int passed, int skipped) {
  debugPrintSynchronously('$kResultTag\t__DONE__\t$passed/${total - skipped} passed ($skipped skipped)');
}
