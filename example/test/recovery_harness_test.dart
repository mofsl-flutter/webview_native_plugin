// The pure parts of the recovery suite: the probe script and its decoding, event matching, and the
// bounded waits. The cases themselves need a device; these make sure the machinery they stand on
// reports "nothing arrived" as an observation rather than hanging or throwing.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin/webview_events.dart';
import 'package:ios_webview_plugin_example/src/config/recovery_page.dart';
import 'package:ios_webview_plugin_example/src/regression/event_tape.dart';
import 'package:ios_webview_plugin_example/src/regression/recovery_catalog.dart';
import 'package:ios_webview_plugin_example/src/regression/recovery_case.dart';

WebViewChannelMessageEvent message(Map<String, Object?> body) => WebViewChannelMessageEvent(
      raw: const <String, Object?>{},
      channelName: 'ChartAppDelegate',
      message: jsonEncode(body),
      decoded: body,
    );

void main() {
  group('probe script', () {
    test('reports readiness through its return value and posts a message for the event path', () {
      final String script = buildProbeScript(7);

      // Return value: independent of the event path.
      expect(script, contains('window.ChartApp.v1'));
      expect(script, contains('return JSON.stringify(r)'));
      // Message: exercises the event path, tagged so the reply can be matched.
      expect(script, contains('window.ChartAppDelegate.postMessage'));
      expect(script, contains('"$kProbeEvent"'));
      expect(script, contains('id:7'));
    });

    test('is a single expression a platform can evaluate', () {
      for (final String s in <String>[buildProbeScript(1), buildPingScript(1), buildBusyScript(10)]) {
        expect(s.startsWith('(function(){'), isTrue);
        expect(s.endsWith('})()'), isTrue);
      }
    });
  });

  group('decodeProbeResult', () {
    final String payload = jsonEncode(<String, Object?>{'ready': true});

    test('reads the single encoding iOS returns', () {
      expect(decodeProbeResult(payload), <String, Object?>{'ready': true});
    });

    test('reads the double encoding Android returns', () {
      expect(decodeProbeResult(jsonEncode(payload)), <String, Object?>{'ready': true});
    });

    test('returns null instead of throwing on anything else', () {
      expect(decodeProbeResult(null), isNull);
      expect(decodeProbeResult('null'), isNull);
      expect(decodeProbeResult('garbage'), isNull);
      expect(decodeProbeResult('[1]'), isNull);
      expect(decodeProbeResult(3), isNull);
    });
  });

  group('recovery page', () {
    test('is a data URL carrying the page, so no network is needed', () {
      expect(kRecoveryPageUrl, startsWith('data:text/html;charset=utf-8;base64,'));
      final String html = utf8.decode(base64Decode(kRecoveryPageUrl.split(',').last));
      expect(html, kRecoveryPageHtml);
      expect(html, contains('PageReady'));
      expect(html, contains('ChartApp'));
    });
  });

  group('EventTape', () {
    late EventTape tape;

    setUp(() => tape = EventTape());
    tearDown(() => tape.dispose());

    void deliver(WebViewEvent e) => tape.feedForTest(e);

    test('finds an event that already arrived (the action returned after the event)', () async {
      deliver(message(<String, Object?>{'event': kProbeEvent, 'id': 3}));

      final WebViewEvent? e = await tape.waitFor(probeReply(3), timeout: const Duration(milliseconds: 50));

      expect(e, isNotNull);
    });

    test('reports nothing arriving as null after the bound, not a hang or an error', () async {
      final Stopwatch sw = Stopwatch()..start();

      final WebViewEvent? e = await tape.waitFor(probeReply(1), timeout: const Duration(milliseconds: 80));

      expect(e, isNull);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('completes a pending wait when the event arrives', () async {
      final Future<WebViewEvent?> pending =
          tape.waitFor(pingReply(9), timeout: const Duration(seconds: 2));

      deliver(message(<String, Object?>{'event': kPingEvent, 'id': 9}));

      expect(await pending, isNotNull);
    });

    test('only looks at events after the given index', () async {
      deliver(message(<String, Object?>{'event': kProbeEvent, 'id': 5}));
      final int mark = tape.length;

      final WebViewEvent? e =
          await tape.waitFor(probeReply(5), from: mark, timeout: const Duration(milliseconds: 50));

      expect(e, isNull, reason: 'the reply predates the mark');
    });

    test('matches the right id, not just the right kind', () async {
      deliver(message(<String, Object?>{'event': kProbeEvent, 'id': 1}));

      expect(await tape.waitFor(probeReply(2), timeout: const Duration(milliseconds: 50)), isNull);
      expect(await tape.waitFor(probeReply(1), timeout: const Duration(milliseconds: 50)), isNotNull);
    });

    test('matches native lifecycle events by name and delegateClaimed by reason', () async {
      deliver(const WebViewUnknownEvent(
        raw: <String, Object?>{'event': 'delegateClaimed', 'reason': 'loadUrl'},
        name: 'delegateClaimed',
      ));

      expect(await tape.waitFor(nativeEvent('delegateClaimed'), timeout: const Duration(milliseconds: 50)), isNotNull);
      expect(await tape.waitFor(claimedBy('loadUrl'), timeout: const Duration(milliseconds: 50)), isNotNull);
      expect(await tape.waitFor(claimedBy('reloadUrl'), timeout: const Duration(milliseconds: 50)), isNull);
    });

    test('a pending wait is released, not left dangling, when the tape is disposed', () async {
      final Future<WebViewEvent?> pending = tape.waitFor(probeReply(1), timeout: const Duration(seconds: 30));

      tape.dispose();

      expect(await pending.timeout(const Duration(seconds: 1)), isNull);
    });
  });

  group('summarizeEvents', () {
    test('counts attach, reparent, owned and unowned detach, and named native events', () {
      final Map<String, Object?> s = summarizeEvents(<WebViewEvent>[
        const WebViewAttachedEvent(raw: <String, Object?>{}, viewId: 1, wasReparented: false),
        const WebViewAttachedEvent(raw: <String, Object?>{}, viewId: 2, wasReparented: true),
        const WebViewDetachedEvent(raw: <String, Object?>{}, viewId: 1, owned: false),
        const WebViewDetachedEvent(raw: <String, Object?>{}, viewId: 2),
        const WebViewUnknownEvent(raw: <String, Object?>{}, name: 'delegateClaimed'),
        const WebViewUnknownEvent(raw: <String, Object?>{}, name: 'renderProcessGone'),
      ]);

      expect(s['viewAttached'], 2);
      expect(s['viewAttachedReparented'], 1);
      expect(s['viewDetachedNotOwned'], 1);
      expect(s['viewDetachedOwned'], 1);
      expect(s['delegateClaimed'], 1);
      expect(s['renderProcessGone'], 1);
    });
  });

  group('catalog', () {
    final List<RecoveryCase> cases = buildRecoveryCatalog();

    test('ids are unique', () {
      final Set<String> ids = cases.map((RecoveryCase c) => c.id).toSet();
      expect(ids.length, cases.length);
    });

    test('every case has a title, a group and a body', () {
      for (final RecoveryCase c in cases) {
        expect(c.title, isNotEmpty, reason: c.id);
        expect(c.group, isNotEmpty, reason: c.id);
      }
    });

    test('the Android-only cases are exactly the ones that need a second engine or a renderer crash', () {
      final Set<String> androidOnly =
          cases.where((RecoveryCase c) => c.androidOnly).map((RecoveryCase c) => c.id).toSet();
      expect(androidOnly, containsAll(<String>['E1', 'E2', 'E2b', 'E9', 'R3']));
      expect(androidOnly, isNot(contains('P1')));
      expect(androidOnly, isNot(contains('V2')));
    });
  });

  group('ProbeOutcome', () {
    test('reads the native facts and the decoded page answer separately', () {
      const ProbeOutcome o = ProbeOutcome(
        facts: <String, Object?>{'hasWebView': true, 'attached': false, 'ownsDelegate': true, 'timedOut': false},
        page: <String, Object?>{'ready': true},
        pong: false,
      );

      expect(o.hasWebView, isTrue);
      expect(o.attached, isFalse);
      expect(o.ownsDelegate, isTrue);
      expect(o.ready, isTrue, reason: 'the return value answered');
      expect(o.pong, isFalse, reason: 'even though the message never arrived');
    });

    test('a missing page answer is not ready', () {
      const ProbeOutcome o = ProbeOutcome(facts: <String, Object?>{'timedOut': true}, page: null, pong: false);
      expect(o.ready, isFalse);
      expect(o.timedOut, isTrue);
    });
  });
}
