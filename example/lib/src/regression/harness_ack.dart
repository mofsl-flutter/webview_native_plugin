import 'dart:async';

import 'package:ios_webview_plugin/webview_events.dart';

import '../model/chart_messages.dart';
import '../service/webview_bridge.dart';

/// Outcome of waiting for a page-side acknowledgement.
enum AckStatus {
  /// The page confirmed the call was made.
  called,

  /// A promise returned by the call settled successfully.
  resolved,

  /// The function did not exist on the page.
  missing,

  /// The call threw.
  threw,

  /// A returned promise rejected.
  rejected,

  /// Nothing came back within the bound.
  ///
  /// This is the silent-skip signal, and the whole reason this class exists: the page has several
  /// paths that accept a call and quietly do nothing.
  silent,
}

/// The result of an injected operation.
class AckResult {
  /// Creates a result.
  const AckResult(this.op, this.status, {this.detail, this.elapsedMicros = 0});

  /// Operation name, e.g. `changeTheme`.
  final String op;

  /// What the page reported.
  final AckStatus status;

  /// Extra context reported alongside.
  final Object? detail;

  /// Time from injection to acknowledgement.
  final int elapsedMicros;

  /// Whether the page confirmed it acted.
  bool get ok => status == AckStatus.called || status == AckStatus.resolved;

  @override
  String toString() => '$op → ${status.name}${detail == null ? '' : ' ($detail)'}';
}

/// Waits for `window.__hb` reports from the page.
///
/// Registers one sink on the shared bridge and hands out futures keyed by run and phase, so
/// callers never subscribe to the event channel themselves.
class HarnessAck {
  /// Starts listening on the shared bridge.
  HarnessAck() {
    WebViewBridge.instance.addSink(_onEvent);
  }

  final List<_Waiter> _waiters = <_Waiter>[];
  final List<HarnessMessage> _seen = <HarnessMessage>[];

  /// Every harness message observed, in arrival order.
  List<HarnessMessage> get seen => List<HarnessMessage>.unmodifiable(_seen);

  /// Clears the observed history, at the start of a scenario.
  void reset() => _seen.clear();

  void _onEvent(WebViewEvent event) {
    if (event is! WebViewChannelMessageEvent) return;
    final Map<String, Object?>? decoded = event.decoded;
    if (decoded == null) return;
    final HarnessMessage? msg = HarnessMessage.tryParse(decoded);
    if (msg == null) return;
    _seen.add(msg);
    for (final _Waiter w in List<_Waiter>.of(_waiters)) {
      if (w.runId == msg.runId && w.phases.contains(msg.phase)) {
        _waiters.remove(w);
        if (!w.completer.isCompleted) w.completer.complete(msg);
      }
    }
  }

  /// Waits for any of [phases] for [runId].
  Future<HarnessMessage?> waitForAny(
    String runId,
    Set<String> phases, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    // Satisfy immediately if it already arrived — injection and acknowledgement can race.
    for (final HarnessMessage m in _seen.reversed) {
      if (m.runId == runId && phases.contains(m.phase)) {
        return Future<HarnessMessage?>.value(m);
      }
    }
    final _Waiter w = _Waiter(runId, phases, Completer<HarnessMessage>());
    _waiters.add(w);
    return w.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(w);
        throw TimeoutException('no ack for $phases');
      },
    ).then<HarnessMessage?>((HarnessMessage m) => m).catchError(
      (Object _) {
        _waiters.remove(w);
        return null;
      },
      test: (Object e) => e is TimeoutException,
    );
  }

  /// Awaits the standard acknowledgement set for [op].
  ///
  /// Returns [AckStatus.silent] when nothing arrives, which is a failure, not a pass.
  Future<AckResult> awaitOp(
    String runId,
    String op, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    final HarnessMessage? m = await waitForAny(
      runId,
      <String>{
        '${op}Called',
        '${op}Resolved',
        '${op}Missing',
        '${op}Threw',
        '${op}Rejected',
      },
      timeout: timeout,
    );
    if (m == null) {
      return AckResult(op, AckStatus.silent, elapsedMicros: sw.elapsedMicroseconds);
    }
    final AckStatus status = switch (m.phase.substring(op.length)) {
      'Called' => AckStatus.called,
      'Resolved' => AckStatus.resolved,
      'Missing' => AckStatus.missing,
      'Threw' => AckStatus.threw,
      'Rejected' => AckStatus.rejected,
      _ => AckStatus.silent,
    };
    return AckResult(
      op,
      status,
      detail: m.detail,
      elapsedMicros: sw.elapsedMicroseconds,
    );
  }

  /// Awaits the next state probe for [runId].
  Future<Map<String, Object?>?> awaitProbe(
    String runId, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final HarnessMessage? m =
        await waitForAny(runId, <String>{'probe'}, timeout: timeout);
    final Object? d = m?.detail;
    return d is Map ? Map<String, Object?>.from(d) : null;
  }

  /// Stops listening.
  void dispose() {
    WebViewBridge.instance.removeSink(_onEvent);
    for (final _Waiter w in _waiters) {
      if (!w.completer.isCompleted) w.completer.completeError(StateError('disposed'));
    }
    _waiters.clear();
  }
}

class _Waiter {
  _Waiter(this.runId, this.phases, this.completer);

  final String runId;
  final Set<String> phases;
  final Completer<HarnessMessage> completer;
}
