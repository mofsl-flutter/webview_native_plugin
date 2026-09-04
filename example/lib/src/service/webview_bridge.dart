import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ios_webview_plugin/webview_events.dart';

/// How a received event was treated.
enum EventDisposition {
  /// Belonged to the active run.
  accepted,

  /// Belonged to a different run, or arrived with no run active.
  stray,

  /// Arrived after the terminal, during the settle window.
  postRunTail,

  /// Could not be understood.
  malformed,
}

/// One received event, with everything needed to audit it afterwards.
class LoggedEvent {
  /// Creates a log entry.
  LoggedEvent({
    required this.seq,
    required this.atMicros,
    required this.wallClock,
    required this.event,
    required this.disposition,
    required this.runtimeTypeName,
    this.runIdAtArrival,
  });

  /// Monotonic sequence number within the session.
  final int seq;

  /// Microseconds since session start.
  final int atMicros;

  /// Wall clock at arrival.
  final DateTime wallClock;

  /// The decoded event.
  final WebViewEvent event;

  /// How it was treated.
  final EventDisposition disposition;

  /// Runtime type of the raw payload.
  ///
  /// Worth recording: it is how you notice the day the native side starts sending a bare string
  /// again, which a map-assuming parser would throw on.
  final String runtimeTypeName;

  /// Run active when it arrived.
  final String? runIdAtArrival;

  /// Short label for the log list.
  String get label => switch (event) {
        WebViewChannelMessageEvent(:final String channelName) => 'channel:$channelName',
        WebViewPageStartedEvent() => 'pageStarted',
        WebViewPageFinishedEvent() => 'pageFinished',
        WebViewPageCommitVisibleEvent() => 'pageCommitVisible',
        WebViewProgressEvent(:final int progress) => 'progress:$progress',
        WebViewErrorEvent() => 'error',
        WebViewHttpErrorEvent(:final int statusCode) => 'httpError:$statusCode',
        WebViewConsoleEvent() => 'console',
        WebViewVisualStateEvent() => 'visualState',
        WebViewAttachedEvent(:final bool wasReparented) =>
          wasReparented ? 'viewAttached:reparented' : 'viewAttached',
        WebViewAttachFailedEvent() => 'viewAttachFailed',
        WebViewDetachedEvent() => 'viewDetached',
        WebViewRawStringEvent(:final String value) => 'rawString:$value',
        WebViewUnknownEvent(:final String name) => name.isEmpty ? 'unknown' : name,
      };
}

/// The single subscription to the native event stream, fanned out in Dart.
///
/// There must be exactly one platform subscription for the whole app: each
/// `receiveBroadcastStream` call reinstalls the channel's message handler, and there is only one
/// handler per channel name, so a second subscription silently stops the first receiving
/// anything. The plugin memoises its stream, and this class memoises the listener on top.
class WebViewBridge {
  WebViewBridge._();

  /// The shared instance.
  static final WebViewBridge instance = WebViewBridge._();

  final List<void Function(WebViewEvent)> _sinks = <void Function(WebViewEvent)>[];
  final List<LoggedEvent> _log = <LoggedEvent>[];

  /// Notifies when [log] grows, without waking the run driver's own listeners.
  final ValueNotifier<int> logLength = ValueNotifier<int>(0);

  // Deliberately never cancelled: it must live for the whole session. Cancelling would let a
  // later subscription reinstall the channel's message handler, which is the exact failure this
  // class exists to prevent.
  // ignore: cancel_subscriptions
  StreamSubscription<WebViewEvent>? _subscription;
  late Stopwatch _sessionClock;
  int _seq = 0;

  /// Maximum retained log entries.
  static const int logCapacity = 2000;

  /// Events received this session, oldest first.
  List<LoggedEvent> get log => List<LoggedEvent>.unmodifiable(_log);

  /// Microseconds since the bridge started.
  int get sessionMicros => _sessionClock.elapsedMicroseconds;

  /// Starts listening. Safe to call more than once; only the first call takes effect.
  void start() {
    if (_subscription != null) return;
    _sessionClock = Stopwatch()..start();
    // Deliberately never cancelled: it must live for the whole session. Cancelling would let a
    // later subscription reinstall the channel handler, which is the failure this class exists
    // to prevent.
    // ignore: cancel_subscriptions
    _subscription = webViewEvents.listen(_onEvent);
  }

  /// Registers a listener.
  void addSink(void Function(WebViewEvent) sink) => _sinks.add(sink);

  /// Removes a listener.
  void removeSink(void Function(WebViewEvent) sink) => _sinks.remove(sink);

  /// Records how an event was treated, for the audit log.
  void note(
    WebViewEvent event,
    EventDisposition disposition,
    String? runId,
  ) {
    if (_log.length >= logCapacity) _log.removeAt(0);
    _log.add(
      LoggedEvent(
        seq: _seq++,
        atMicros: _sessionClock.elapsedMicroseconds,
        wallClock: DateTime.now(),
        event: event,
        disposition: disposition,
        runtimeTypeName: event.raw.runtimeType.toString(),
        runIdAtArrival: runId,
      ),
    );
    logLength.value = _log.length;
  }

  /// Clears the log.
  void clearLog() {
    _log.clear();
    logLength.value = 0;
  }

  void _onEvent(WebViewEvent event) {
    // Iterate a copy: a sink may remove itself while handling an event.
    for (final void Function(WebViewEvent) sink
        in List<void Function(WebViewEvent)>.of(_sinks)) {
      sink(event);
    }
  }
}
