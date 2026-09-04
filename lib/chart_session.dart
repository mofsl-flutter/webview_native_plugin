import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart";

import "ios_webview_plugin.dart";
import "webview_events.dart";

/// Name of the JavaScript channel [ChartSession] installs for its own acknowledgements.
///
/// Pass this to `IosWebViewPlugin.prewarm` or `IosWebViewPlugin.openWebView` alongside any other
/// channel the page needs. A channel only takes effect on the *next* navigation, so registering it
/// after the page has loaded leaves [ChartSession.runOperation] unable to hear anything and every
/// operation reports [OperationStatus.timeout].
const String kChartSessionAckChannel = "ChartSessionAck";

const String _bootstrapJs = "(function(){"
    "if(window.__chartSessionAck)return;"
    "window.__chartSessionAck=function(opId,status,detail){"
    "try{"
    "var c=window.$kChartSessionAckChannel;"
    "if(!c||!c.postMessage)return;"
    "c.postMessage(JSON.stringify({"
    "opId:opId,status:status,detail:detail,ts:Date.now()"
    "}));"
    "}catch(e){}"
    "};"
    "})();";

const String _kSyncOk = "__cs_ok";
const String _kSyncPending = "__cs_pending";
const String _kSyncThrew = "__cs_threw:";

/// How an injected operation finished.
enum OperationStatus {
  /// The script ran to completion, and settled if it returned a promise.
  ok,

  /// The script threw, or the promise it returned rejected.
  threw,

  /// No acknowledgement arrived before the deadline.
  ///
  /// This is the case the plain `runJavaScript` path cannot report at all. It covers a page
  /// function that does not exist, one that returns without doing anything, and one whose promise
  /// never settles — all of which are otherwise indistinguishable from success.
  timeout,
}

/// Outcome of one [ChartSession.runOperation] call.
class OperationResult {
  /// Creates a result.
  const OperationResult({
    required this.opId,
    required this.status,
    required this.elapsedMs,
    this.error,
  });

  /// Correlation id carried by the injected reporter.
  final String opId;

  /// How the operation finished.
  final OperationStatus status;

  /// Milliseconds from injection to acknowledgement, or to the deadline.
  final int elapsedMs;

  /// Detail from the page for [OperationStatus.threw], or the reason for a timeout.
  final String? error;

  /// Whether the page acknowledged the operation as successful.
  bool get isOk => status == OperationStatus.ok;

  @override
  String toString() =>
      "OperationResult($opId, ${status.name}, ${elapsedMs}ms${error == null ? "" : ", $error"})";
}

/// A synchronous read of the page's real state.
///
/// This exists so a freshly built widget does not have to assume it is looking at a blank page.
/// The native WebView is a process-wide singleton whose document survives platform-view disposal,
/// so a rebuilt widget is routinely handed a page that is already loaded and idle.
class ChartSessionSnapshot {
  /// Creates a snapshot.
  const ChartSessionSnapshot({
    required this.loadId,
    required this.pageStarted,
    required this.pageFinished,
    required this.liveHandles,
    required this.livePlatformViews,
    this.attachedViewId,
    this.url,
    this.lastError,
  });

  /// Load generation the rest of these fields describe, or `-1` before any load.
  final int loadId;

  /// Whether navigation began for [loadId].
  final bool pageStarted;

  /// Whether the document finished loading for [loadId].
  final bool pageFinished;

  /// Number of live consumer registrations.
  final int liveHandles;

  /// Number of platform views currently holding the WebView, per the native attach events.
  ///
  /// Greater than one means two platform views are contending for the single WebView, and the
  /// outgoing one has already lost it.
  final int livePlatformViews;

  /// Platform view currently holding the WebView, or null when it is detached.
  final int? attachedViewId;

  /// Last URL reported by the page.
  final String? url;

  /// Last main-frame error description, cleared on the next navigation.
  final String? lastError;

  /// Whether a document is loaded and can be operated on.
  bool get isPageLoaded => pageStarted && pageFinished;

  /// Whether the WebView is parented into a platform view.
  bool get isAttached => attachedViewId != null;

  @override
  String toString() => "ChartSessionSnapshot(loadId: $loadId, started: $pageStarted, "
      "finished: $pageFinished, attached: $attachedViewId, views: $livePlatformViews, "
      "handles: $liveHandles)";
}

/// A widget's registration with [ChartSession].
///
/// Obtained from [ChartSession.attach] in `initState` and released with [detach] in `dispose`.
/// The session owns the underlying stream subscription, so events can never be delivered to a
/// disposed `State` once its handle is detached.
class ChartSessionHandle {
  ChartSessionHandle._(this._session, this._onEvent);

  final ChartSession _session;
  final void Function(WebViewEvent) _onEvent;
  bool _detached = false;

  /// Whether [detach] has been called.
  bool get isDetached => _detached;

  /// Stops event delivery to this handle. Idempotent.
  ///
  /// Does not stop the session, tear down the WebView, or affect any other handle.
  void detach() {
    if (_detached) return;
    _detached = true;
    _session._removeHandle(this);
  }
}

class _PendingOp {
  _PendingOp() : watch = Stopwatch()..start();

  final Completer<OperationResult> completer = Completer<OperationResult>();
  final Stopwatch watch;
}

/// Process-scoped state for the singleton WebView and the page it holds.
///
/// The native WebView outlives every widget that hosts it: disposing a platform view only
/// detaches it, so its document, timers and JavaScript state survive navigation. Anything that
/// tracks that page must therefore live at process scope too. Scoping it to a widget's `State`
/// produces two failures this class exists to remove — events arriving at a disposed callback
/// target, and a rebuilt widget acting on the assumption that the page is blank when it is not.
///
/// On top of that it provides [runOperation], which turns an unacknowledged injection into a
/// reported [OperationStatus.timeout] rather than silence.
class ChartSession {
  ChartSession._();

  /// The single instance, matching the lifetime of the WebView it describes.
  static final ChartSession instance = ChartSession._();

  final List<ChartSessionHandle> _handles = <ChartSessionHandle>[];
  final Map<String, _PendingOp> _pending = <String, _PendingOp>{};

  StreamSubscription<WebViewEvent>? _subscription;
  Future<void> _queueTail = Future<void>.value();
  int _opCounter = 0;
  bool _bootstrapped = false;

  int _loadId = -1;
  bool _pageStarted = false;
  bool _pageFinished = false;
  final Set<int> _liveViewIds = <int>{};
  int? _attachedViewId;
  String? _url;
  String? _lastError;

  /// The page's state right now, safe to read the instant a widget attaches.
  ChartSessionSnapshot get snapshot => ChartSessionSnapshot(
        loadId: _loadId,
        pageStarted: _pageStarted,
        pageFinished: _pageFinished,
        liveHandles: _handles.length,
        livePlatformViews: _liveViewIds.length,
        attachedViewId: _attachedViewId,
        url: _url,
        lastError: _lastError,
      );

  /// Registers [onEvent] for the life of the returned handle.
  ///
  /// Call from `initState` and [ChartSessionHandle.detach] from `dispose`. Read [snapshot]
  /// immediately afterwards rather than waiting for events: a page that loaded before this widget
  /// existed has already emitted everything it is going to emit for that load.
  ChartSessionHandle attach({required void Function(WebViewEvent) onEvent}) {
    start();
    final ChartSessionHandle handle = ChartSessionHandle._(this, onEvent);
    _handles.add(handle);
    return handle;
  }

  /// Runs [script] in the page and waits for it to acknowledge.
  ///
  /// Operations are serialised: native `evaluateJavascript` gives no ordering guarantee across
  /// calls, so concurrent injections would otherwise race. Each is wrapped in a reporter that
  /// acknowledges completion, a thrown error, or a rejected promise; anything else resolves as
  /// [OperationStatus.timeout] once [timeout] elapses.
  ///
  /// Write [script] as a statement body and `return` any promise that should be awaited, e.g.
  /// `return window.Authorize(token);`.
  Future<OperationResult> runOperation(
    String script, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final Completer<OperationResult> gate = Completer<OperationResult>();
    _queueTail = _queueTail.then((void _) async {
      gate.complete(await _runNow(script, timeout));
    });
    return gate.future;
  }

  /// Begins tracking page state. Idempotent, and safe to call before any WebView exists.
  ///
  /// Call this once at app startup. The session must be listening from process start, not from
  /// the first [attach]: a widget that attaches after the page has loaded would otherwise find a
  /// session that missed every event and reports a blank page — which is the very mistake this
  /// class exists to prevent.
  void start() {
    _subscription ??= IosWebViewPlugin.events.listen(_onPlatformEvent);
  }

  /// Installs the acknowledgement reporter if the current document does not have it.
  ///
  /// Called automatically by [runOperation]; exposed so a caller can pay the cost once, right
  /// after the page reports ready, rather than on its first operation.
  Future<void> ensureReporterInstalled() async {
    if (_bootstrapped) return;
    await IosWebViewPlugin.addJavascriptChannel(kChartSessionAckChannel);
    await IosWebViewPlugin.runJavaScript(_bootstrapJs);
    _bootstrapped = true;
  }

  /// Drops all tracked state. For tests only.
  @visibleForTesting
  void resetForTest() {
    for (final _PendingOp op in _pending.values) {
      if (!op.completer.isCompleted) {
        op.completer.complete(
          OperationResult(
            opId: "",
            status: OperationStatus.timeout,
            elapsedMs: op.watch.elapsedMilliseconds,
            error: "session reset",
          ),
        );
      }
    }
    _pending.clear();
    _handles.clear();
    _liveViewIds.clear();
    _subscription?.cancel();
    _subscription = null;
    _queueTail = Future<void>.value();
    _opCounter = 0;
    _bootstrapped = false;
    _loadId = -1;
    _pageStarted = false;
    _pageFinished = false;
    _attachedViewId = null;
    _url = null;
    _lastError = null;
  }

  Future<OperationResult> _runNow(String script, Duration timeout) async {
    await ensureReporterInstalled();
    final String opId = "op-${++_opCounter}-${DateTime.now().microsecondsSinceEpoch}";
    final _PendingOp pending = _PendingOp();
    _pending[opId] = pending;

    // The synchronous verdict comes straight back from the evaluate call, so the common case
    // needs no channel at all. Only a returned promise has to wait for the reporter.
    final Object? verdict =
        await IosWebViewPlugin.evaluateJavaScript(_wrapForAck(script, opId));
    final String outcome = verdict?.toString() ?? "";

    if (outcome == _kSyncOk) {
      _pending.remove(opId);
      return OperationResult(
        opId: opId,
        status: OperationStatus.ok,
        elapsedMs: pending.watch.elapsedMilliseconds,
      );
    }
    if (outcome.startsWith(_kSyncThrew)) {
      _pending.remove(opId);
      return OperationResult(
        opId: opId,
        status: OperationStatus.threw,
        elapsedMs: pending.watch.elapsedMilliseconds,
        error: outcome.substring(_kSyncThrew.length),
      );
    }
    if (outcome != _kSyncPending) {
      _pending.remove(opId);
      return OperationResult(
        opId: opId,
        status: OperationStatus.timeout,
        elapsedMs: pending.watch.elapsedMilliseconds,
        error: "no verdict from the page (evaluate returned ${verdict ?? "null"})",
      );
    }

    try {
      return await pending.completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(opId);
      return OperationResult(
        opId: opId,
        status: OperationStatus.timeout,
        elapsedMs: pending.watch.elapsedMilliseconds,
        error: "promise did not settle within ${timeout.inMilliseconds} ms",
      );
    }
  }

  static String _wrapForAck(String script, String opId) {
    final String id = jsonEncode(opId);
    return "(function(){"
        "var a=window.__chartSessionAck||function(){};"
        "try{"
        "var r=(function(){$script})();"
        "if(r&&typeof r.then===\"function\"){"
        "r.then(function(){a($id,\"ok\",null);},"
        "function(e){a($id,\"threw\",String((e&&e.message)||e));});"
        "return \"$_kSyncPending\";"
        "}"
        "return \"$_kSyncOk\";"
        "}catch(e){return \"$_kSyncThrew\"+String((e&&e.message)||e);}"
        "})();";
  }

  void _onPlatformEvent(WebViewEvent event) {
    if (event is WebViewPageStartedEvent) {
      _loadId = event.loadId ?? _loadId;
      _pageStarted = true;
      _pageFinished = false;
      _url = event.url;
      _lastError = null;
      // A new document loses the injected reporter, so it must be reinstalled.
      _bootstrapped = false;
      _abandonPending("document navigated before acknowledgement");
    } else if (event is WebViewPageFinishedEvent) {
      _pageFinished = true;
      _url = event.url;
    } else if (event is WebViewAttachedEvent) {
      _liveViewIds.add(event.viewId);
      _attachedViewId = event.viewId;
      if (kDebugMode && _liveViewIds.length > 1) {
        debugPrint(
          "ChartSession: ${_liveViewIds.length} platform views hold the singleton WebView "
          "($_liveViewIds). The outgoing view has already lost it.",
        );
      }
    } else if (event is WebViewDetachedEvent) {
      _liveViewIds.remove(event.viewId);
      if (_attachedViewId == event.viewId) {
        _attachedViewId = _liveViewIds.isEmpty ? null : _liveViewIds.last;
      }
    } else if (event is WebViewErrorEvent) {
      if (event.isForMainFrame ?? false) _lastError = event.description;
    } else if (event is WebViewChannelMessageEvent &&
        event.channelName == kChartSessionAckChannel) {
      _completeAck(event.decoded);
    }

    // Copy first: a handler may detach itself while being notified.
    for (final ChartSessionHandle handle in List<ChartSessionHandle>.of(_handles)) {
      if (!handle.isDetached) handle._onEvent(event);
    }
  }

  void _completeAck(Map<String, Object?>? payload) {
    final String? opId = payload?["opId"]?.toString();
    if (opId == null) return;
    final _PendingOp? pending = _pending.remove(opId);
    if (pending == null || pending.completer.isCompleted) return;
    final bool ok = payload?["status"]?.toString() == "ok";
    pending.completer.complete(
      OperationResult(
        opId: opId,
        status: ok ? OperationStatus.ok : OperationStatus.threw,
        elapsedMs: pending.watch.elapsedMilliseconds,
        error: ok ? null : payload?["detail"]?.toString(),
      ),
    );
  }

  void _abandonPending(String reason) {
    if (_pending.isEmpty) return;
    final List<String> ids = _pending.keys.toList();
    for (final String id in ids) {
      final _PendingOp? pending = _pending.remove(id);
      if (pending == null || pending.completer.isCompleted) continue;
      pending.completer.complete(
        OperationResult(
          opId: id,
          status: OperationStatus.timeout,
          elapsedMs: pending.watch.elapsedMilliseconds,
          error: reason,
        ),
      );
    }
  }

  void _removeHandle(ChartSessionHandle handle) => _handles.remove(handle);
}
