import '../model/bench_models.dart';
import 'harness_ack.dart';

/// Everything observed while a scenario ran, for expectations to assert over.
class ScenarioObservations {
  /// Creates an observation set.
  ScenarioObservations();

  /// Records produced by load-bearing steps, in order.
  final List<RunRecord> records = <RunRecord>[];

  /// Acknowledgements for injected operations, in order.
  final List<AckResult> acks = <AckResult>[];

  /// Page-state probes, keyed by their label.
  final Map<String, Map<String, Object?>> probes = <String, Map<String, Object?>>{};

  /// Free-form notes a step wanted to record (e.g. "platform view recreated").
  final List<String> notes = <String>[];

  /// Error messages the **page** reported over its channel.
  ///
  /// Separate from a run's terminal outcome: the point of some cases is that the page reports
  /// *nothing at all*, which a terminal outcome cannot express.
  final List<String> pageErrors = <String>[];

  /// Main-frame transport-level errors reported by the WebView itself.
  ///
  /// Kept apart from [pageErrors] deliberately. A connection failure means the run never
  /// reached the behaviour under test, so counting it as a page error would turn an
  /// inconclusive run into a confident — and wrong — verdict. Restricted to the main frame:
  /// a subresource (e.g. a third-party analytics beacon) failing is noise, not evidence the
  /// behaviour under test was never reached — see [subresourceErrors].
  final List<String> nativeErrors = <String>[];

  /// Subresource transport failures — noise for these cases, recorded for visibility only.
  ///
  /// The chart page pulls a third-party analytics beacon (`s.go-mpulse.net`) that some
  /// networks refuse; treating that as invalidating turned every such run inconclusive even
  /// though the main document and the chart flow were unaffected.
  final List<String> subresourceErrors = <String>[];

  /// The last load record, or null when no load ran.
  RunRecord? get last => records.isEmpty ? null : records.last;

  /// The acknowledgement for [op], most recent first.
  AckResult? ackFor(String op) {
    for (final AckResult a in acks.reversed) {
      if (a.op == op) return a;
    }
    return null;
  }
}

/// The verdict of a single assertion.
class ExpectationResult {
  /// Creates a verdict.
  // ignore: avoid_positional_boolean_parameters
  const ExpectationResult(this.description, this.pass, {this.actual});

  /// What was asserted.
  final String description;

  /// Whether it held.
  final bool pass;

  /// What was observed instead, when it did not.
  final String? actual;

  @override
  String toString() =>
      '${pass ? "PASS" : "FAIL"}  $description${actual == null ? '' : ' — got $actual'}';
}

/// One assertion over a completed scenario.
abstract class Expectation {
  /// Creates an expectation.
  const Expectation();

  /// Human-readable statement of what is expected.
  String get description;

  /// Evaluates against [o].
  ExpectationResult evaluate(ScenarioObservations o);
}

/// Asserts the last load ended with a specific outcome.
///
/// Used to assert *failures* as much as successes: a malformed symbol must come back
/// `SymbolNotFound`, and the inverted-order case must come back `timeout`.
class ExpectOutcome extends Expectation {
  /// Creates the assertion.
  const ExpectOutcome(this.outcome);

  /// The required outcome.
  final TerminalOutcome outcome;

  @override
  String get description => 'outcome is ${outcome.name}';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final RunRecord? r = o.last;
    if (r == null) {
      return ExpectationResult(description, false, actual: 'no load ran');
    }
    return ExpectationResult(description, r.outcome == outcome, actual: r.outcome.name);
  }
}

/// Asserts a timing mark was never recorded.
///
/// This is how "the page was reused" is asserted: no `pageStarted` means no navigation
/// happened. A reuse path that quietly re-navigates fails here even though it still succeeded.
class ExpectMarkAbsent extends Expectation {
  /// Creates the assertion.
  const ExpectMarkAbsent(this.mark, {this.because});

  /// Mark that must not be present.
  final String mark;

  /// Why it matters, shown in the report.
  final String? because;

  @override
  String get description =>
      'mark "$mark" absent${because == null ? '' : ' ($because)'}';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final RunRecord? r = o.last;
    if (r == null) {
      return ExpectationResult(description, false, actual: 'no load ran');
    }
    final bool present = r.marks.containsKey(mark);
    return ExpectationResult(
      description,
      !present,
      actual: present ? 'present at ${r.marks[mark]}µs' : 'absent',
    );
  }
}

/// Asserts a timing mark was recorded.
class ExpectMarkPresent extends Expectation {
  /// Creates the assertion.
  const ExpectMarkPresent(this.mark);

  /// Mark that must be present.
  final String mark;

  @override
  String get description => 'mark "$mark" present';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final RunRecord? r = o.last;
    if (r == null) {
      return ExpectationResult(description, false, actual: 'no load ran');
    }
    return ExpectationResult(
      description,
      r.marks.containsKey(mark),
      actual: r.marks.containsKey(mark) ? 'present' : 'absent',
    );
  }
}

/// Asserts what triggered the chart, e.g. `initialLoad` versus `changeSymbol`.
class ExpectChartSource extends Expectation {
  /// Creates the assertion.
  const ExpectChartSource(this.source);

  /// Required source.
  final String source;

  @override
  String get description => 'chart source is "$source"';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final String? actual = o.last?.chartSource;
    return ExpectationResult(description, actual == source, actual: actual ?? 'none');
  }
}

/// Asserts an injected operation was acknowledged by the page.
///
/// The single most important assertion in the suite. The page has many paths that accept a call
/// and then do nothing — a strict allowlist that rejects an unexpected value, a mode latch, a
/// guard that returns early. All of them present as "nothing happened", and only the absence of
/// an acknowledgement distinguishes them from success.
class ExpectAck extends Expectation {
  /// Creates the assertion.
  const ExpectAck(this.op, {this.allow = const <AckStatus>{AckStatus.called, AckStatus.resolved}});

  /// Operation name.
  final String op;

  /// Statuses that count as a pass.
  final Set<AckStatus> allow;

  @override
  String get description =>
      'op "$op" acknowledged (${allow.map((AckStatus s) => s.name).join('|')})';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final AckResult? a = o.ackFor(op);
    if (a == null) {
      return ExpectationResult(description, false, actual: 'no ack recorded');
    }
    return ExpectationResult(description, allow.contains(a.status), actual: a.status.name);
  }
}

/// Asserts an operation produced **no** acknowledgement — a documented silent skip.
///
/// Used for cases that pin a known defect: the assertion passes when the defect reproduces, so
/// the case going green means "still broken, as documented", and going red means the behaviour
/// changed and the design notes need revisiting.
class ExpectSilentSkip extends Expectation {
  /// Creates the assertion.
  const ExpectSilentSkip(this.op, {required this.knownDefect});

  /// Operation name.
  final String op;

  /// Description of the defect this pins.
  final String knownDefect;

  @override
  String get description => 'op "$op" is silently skipped — $knownDefect';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final AckResult? a = o.ackFor(op);
    final bool silent = a == null || a.status == AckStatus.silent;
    return ExpectationResult(description, silent, actual: a?.status.name ?? 'no ack');
  }
}

/// Asserts a probe field equals a value.
class ExpectProbe extends Expectation {
  /// Creates the assertion.
  const ExpectProbe(this.label, this.field, this.value);

  /// Probe label.
  final String label;

  /// Field within the probe.
  final String field;

  /// Required value.
  final Object? value;

  @override
  String get description => 'probe "$label".$field == $value';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final Map<String, Object?>? p = o.probes[label];
    if (p == null) {
      return ExpectationResult(description, false, actual: 'probe missing');
    }
    return ExpectationResult(description, p[field] == value, actual: '${p[field]}');
  }
}

/// Asserts a probe field changed between two probes.
///
/// Stronger than an acknowledgement: it checks the page's observable state actually moved.
class ExpectProbeChanged extends Expectation {
  /// Creates the assertion.
  const ExpectProbeChanged(this.before, this.after, this.field);

  /// Earlier probe label.
  final String before;

  /// Later probe label.
  final String after;

  /// Field that must differ.
  final String field;

  @override
  String get description => 'probe.$field changed between "$before" and "$after"';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final Map<String, Object?>? a = o.probes[before];
    final Map<String, Object?>? b = o.probes[after];
    if (a == null || b == null) {
      return ExpectationResult(description, false, actual: 'probe(s) missing');
    }
    return ExpectationResult(
      description,
      a[field] != b[field],
      actual: '${a[field]} → ${b[field]}',
    );
  }
}

/// Asserts a phase completed within a budget.
class ExpectPhaseUnder extends Expectation {
  /// Creates the assertion.
  const ExpectPhaseUnder(this.metric, this.budget);

  /// Metric name from [RunRecord.metrics].
  final String metric;

  /// Upper bound.
  final Duration budget;

  @override
  String get description => '$metric under ${budget.inMilliseconds} ms';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final int? v = o.last?.metrics[metric];
    if (v == null) {
      return ExpectationResult(description, false, actual: 'not measured');
    }
    return ExpectationResult(
      description,
      v <= budget.inMicroseconds,
      actual: '${(v / 1000).toStringAsFixed(1)} ms',
    );
  }
}

/// Asserts the page reported whether it purged its own storage.
///
/// Note the asymmetry: on a true first install the page reports `false` even though no token
/// exists, so this cannot be the only trigger for re-authorising.
class ExpectResetCache extends Expectation {
  /// Creates the assertion.
  // ignore: avoid_positional_boolean_parameters
  const ExpectResetCache(this.value);

  /// Required flag value.
  final bool value;

  @override
  String get description => 'PageReady.resetCache == $value';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final bool? actual = o.last?.pageReadyResetCache;
    return ExpectationResult(description, actual == value, actual: '$actual');
  }
}

/// Asserts no run in the scenario recorded stray events.
///
/// A trustworthiness gate rather than a behavioural assertion: strays mean event correlation
/// leaked across runs and the timings cannot be relied on.
class ExpectNoStrays extends Expectation {
  /// Creates the assertion.
  const ExpectNoStrays();

  @override
  String get description => 'no stray events in any run';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    final int total = o.records.fold<int>(0, (int a, RunRecord r) => a + r.strayEvents);
    return ExpectationResult(description, total == 0, actual: '$total');
  }
}

/// Asserts an arbitrary predicate, for one-off cases.
class ExpectCustom extends Expectation {
  /// Creates the assertion.
  const ExpectCustom(this.description, this._predicate);

  @override
  final String description;

  final bool Function(ScenarioObservations) _predicate;

  @override
  ExpectationResult evaluate(ScenarioObservations o) =>
      ExpectationResult(description, _predicate(o));
}


/// Asserts the page reported no error message of its own.
///
/// This is how "it fails without telling anyone" is pinned. The page has paths where an
/// unauthorised or failed request is parked and no message is ever emitted, so the absence of
/// an error is the observation under test.
class ExpectNoPageError extends Expectation {
  /// Creates the assertion.
  const ExpectNoPageError();

  @override
  String get description => 'page emitted no error message';

  @override
  ExpectationResult evaluate(ScenarioObservations o) {
    // A transport failure means the request never reached the server, so the 401 path was
    // never exercised and this case proves nothing. Report that rather than passing.
    if (o.nativeErrors.isNotEmpty) {
      return ExpectationResult(
        description,
        false,
        actual: 'inconclusive — transport failed: ${o.nativeErrors.join(', ')}',
      );
    }
    return ExpectationResult(
      description,
      o.pageErrors.isEmpty,
      actual: o.pageErrors.isEmpty ? 'none' : o.pageErrors.join(', '),
    );
  }
}
