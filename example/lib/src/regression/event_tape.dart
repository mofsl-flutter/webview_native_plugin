import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ios_webview_plugin/webview_events.dart';

import '../config/recovery_page.dart';
import '../service/webview_bridge.dart';

/// A recording of every native event, for cases that assert on what arrived and what did not.
///
/// The recovery cases are mostly about events that stop arriving, so "nothing came" has to be a
/// positive observation rather than the lack of one: every wait here is bounded and reports a
/// timeout as `null`.
class EventTape {
  /// Starts recording from the shared bridge.
  EventTape() {
    WebViewBridge.instance.addSink(_onEvent);
  }

  final List<WebViewEvent> _events = <WebViewEvent>[];
  final List<_Waiter> _waiters = <_Waiter>[];

  /// Events recorded so far, oldest first.
  List<WebViewEvent> get events => List<WebViewEvent>.unmodifiable(_events);

  /// Number of events recorded. Take it before an action to ask only about what followed.
  int get length => _events.length;

  /// Forgets everything recorded.
  void clear() => _events.clear();

  /// Whether any event from index [from] on satisfies [test].
  bool any(bool Function(WebViewEvent) test, {int from = 0}) =>
      _events.skip(from).any(test);

  /// Number of events from index [from] on that satisfy [test].
  int count(bool Function(WebViewEvent) test, {int from = 0}) =>
      _events.skip(from).where(test).length;

  /// Waits for an event satisfying [test], looking first at what was already recorded from [from].
  ///
  /// Returns `null` on timeout. The look-back matters: an event can arrive between the action that
  /// causes it returning and the wait starting.
  Future<WebViewEvent?> waitFor(
    bool Function(WebViewEvent) test, {
    int from = 0,
    Duration timeout = const Duration(seconds: 3),
  }) {
    for (final WebViewEvent e in _events.skip(from)) {
      if (test(e)) return Future<WebViewEvent?>.value(e);
    }
    final _Waiter w = _Waiter(test, Completer<WebViewEvent?>());
    _waiters.add(w);
    return w.completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(w);
        return null;
      },
    );
  }

  /// Feeds an event in as though the bridge had delivered it. Test seam: the bridge itself needs a
  /// platform channel.
  @visibleForTesting
  void feedForTest(WebViewEvent event) => _onEvent(event);

  void _onEvent(WebViewEvent event) {
    _events.add(event);
    for (final _Waiter w in List<_Waiter>.of(_waiters)) {
      if (w.test(event)) {
        _waiters.remove(w);
        if (!w.completer.isCompleted) w.completer.complete(event);
      }
    }
  }

  /// Stops recording.
  void dispose() {
    WebViewBridge.instance.removeSink(_onEvent);
    for (final _Waiter w in _waiters) {
      if (!w.completer.isCompleted) w.completer.complete(null);
    }
    _waiters.clear();
  }
}

class _Waiter {
  _Waiter(this.test, this.completer);

  final bool Function(WebViewEvent) test;
  final Completer<WebViewEvent?> completer;
}

/// Matches a message the page posted on its channel whose JSON has `context == [context]`.
bool Function(WebViewEvent) pageContext(String context) => (WebViewEvent e) =>
    e is WebViewChannelMessageEvent && e.decoded?['context'] == context;

/// Matches the page's reply to probe [id].
bool Function(WebViewEvent) probeReply(int id) => (WebViewEvent e) =>
    e is WebViewChannelMessageEvent &&
    e.decoded?['event'] == kProbeEvent &&
    e.decoded?['id'] == id;

/// Matches the page's message for ping [id].
bool Function(WebViewEvent) pingReply(int id) => (WebViewEvent e) =>
    e is WebViewChannelMessageEvent &&
    e.decoded?['event'] == kPingEvent &&
    e.decoded?['id'] == id;

/// Matches a native lifecycle event reported under [name] (`loadRequested`, `renderProcessGone`,
/// `delegateClaimed`, ...).
bool Function(WebViewEvent) nativeEvent(String name) =>
    (WebViewEvent e) => e is WebViewUnknownEvent && e.name == name;

/// Matches `delegateClaimed` with the given [reason] (`loadUrl`, `reloadUrl`, `prewarm`, `listen`,
/// or whatever an explicit `claimDelegate(reason:)` passed).
bool Function(WebViewEvent) claimedBy(String reason) => (WebViewEvent e) {
      if (e is! WebViewUnknownEvent || e.name != 'delegateClaimed') return false;
      final Object? raw = e.raw;
      return raw is Map && raw['reason'] == reason;
    };

/// The platform-view events in [events], in order, as one line, e.g.
/// `attach(3) attach(4,reparented) detach(3,notOwner)`. Put in a failing check's detail so a
/// view-ownership failure shows the order things happened in.
String viewTrace(Iterable<WebViewEvent> events) {
  final List<String> out = <String>[];
  for (final WebViewEvent e in events) {
    if (e is WebViewAttachedEvent) {
      out.add('attach(${e.viewId}${e.wasReparented ? ',reparented' : ''})');
    } else if (e is WebViewDetachedEvent) {
      out.add('detach(${e.viewId}${e.owned ? '' : ',notOwner'})');
    }
  }
  return out.isEmpty ? '(no view events)' : out.join(' ');
}

/// Summarises a tape for assertions about platform-view and ownership events.
Map<String, Object?> summarizeEvents(List<WebViewEvent> events) {
  int attached = 0;
  int reparented = 0;
  int detachedOwned = 0;
  int detachedNotOwned = 0;
  int named(String n) =>
      events.where((WebViewEvent e) => e is WebViewUnknownEvent && e.name == n).length;
  for (final WebViewEvent e in events) {
    if (e is WebViewAttachedEvent) {
      attached++;
      if (e.wasReparented) reparented++;
    } else if (e is WebViewDetachedEvent) {
      if (e.owned) {
        detachedOwned++;
      } else {
        detachedNotOwned++;
      }
    }
  }
  return <String, Object?>{
    'viewAttached': attached,
    'viewAttachedReparented': reparented,
    'viewDetachedOwned': detachedOwned,
    'viewDetachedNotOwned': detachedNotOwned,
    'delegateClaimed': named('delegateClaimed'),
    'renderProcessGone': named('renderProcessGone'),
    'loadRequested': named('loadRequested'),
  };
}
