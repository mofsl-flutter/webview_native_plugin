import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin/webview_events.dart';
import 'package:ios_webview_plugin_example/src/model/chart_messages.dart';
import 'package:ios_webview_plugin_example/src/model/stats.dart';
import 'package:ios_webview_plugin_example/src/service/token_api.dart';

void main() {
  group('Aggregate percentiles', () {
    // Off-by-one in a percentile index silently biases every comparison, so the small-n cases
    // are pinned explicitly.
    test('n=1 collapses to the single value', () {
      final Aggregate a = Aggregate.of(<int?>[100])!;
      expect(a.n, 1);
      expect(a.median, 100);
      expect(a.p25, 100);
      expect(a.p75, 100);
      expect(a.min, 100);
      expect(a.max, 100);
    });

    test('n=2 interpolates the median', () {
      final Aggregate a = Aggregate.of(<int?>[100, 200])!;
      expect(a.median, 150);
    });

    test('n=3 takes the middle value', () {
      final Aggregate a = Aggregate.of(<int?>[300, 100, 200])!;
      expect(a.median, 200);
    });

    test('n=4 interpolates between the two middles', () {
      final Aggregate a = Aggregate.of(<int?>[100, 200, 300, 400])!;
      expect(a.median, 250);
    });

    test('n=5 median and quartiles', () {
      final Aggregate a = Aggregate.of(<int?>[100, 200, 300, 400, 500])!;
      expect(a.median, 300);
      expect(a.p25, 200);
      expect(a.p75, 400);
    });

    test('n=6 interpolates', () {
      final Aggregate a = Aggregate.of(<int?>[10, 20, 30, 40, 50, 60])!;
      expect(a.median, 35);
    });

    test('p95 is suppressed below 20 samples', () {
      // Nearest-rank p95 at small n is just the maximum; labelling that as a percentile would
      // imply an estimate that does not exist.
      expect(Aggregate.of(<int?>[1, 2, 3, 4, 5])!.p95, isNull);
      final Aggregate big = Aggregate.of(List<int?>.generate(25, (int i) => i))!;
      expect(big.p95, isNotNull);
    });

    test('nulls are ignored and an all-null set yields nothing', () {
      expect(Aggregate.of(<int?>[null, 5, null])!.n, 1);
      expect(Aggregate.of(<int?>[null, null]), isNull);
    });
  });

  group('Event parsing', () {
    test('a platform Map<Object?, Object?> decodes without throwing', () {
      // This is the real shape a platform channel delivers; `as Map<String, dynamic>` throws.
      final Map<Object?, Object?> raw = <Object?, Object?>{
        'event': 'pageFinished',
        'url': 'https://example.com/x',
        'ts': 1234,
        'tsMono': 99,
        'loadId': 7,
      };
      final WebViewEvent e = WebViewEvent.fromPlatform(raw);
      expect(e, isA<WebViewPageFinishedEvent>());
      expect((e as WebViewPageFinishedEvent).url, 'https://example.com/x');
      expect(e.ts, 1234);
      expect(e.tsMono, 99);
      expect(e.loadId, 7);
    });

    test('a bare String becomes a raw event rather than throwing', () {
      final WebViewEvent e = WebViewEvent.fromPlatform('pageLoaded');
      expect(e, isA<WebViewRawStringEvent>());
      expect((e as WebViewRawStringEvent).value, 'pageLoaded');
    });

    test('an unmodelled event name is preserved, not dropped', () {
      final WebViewEvent e = WebViewEvent.fromPlatform(
        <Object?, Object?>{'event': 'somethingNew'},
      );
      expect(e, isA<WebViewUnknownEvent>());
      expect((e as WebViewUnknownEvent).name, 'somethingNew');
    });

    test('a null payload does not throw', () {
      expect(WebViewEvent.fromPlatform(null), isA<WebViewUnknownEvent>());
    });

    test('channel messages decode their inner JSON', () {
      final WebViewEvent e = WebViewEvent.fromPlatform(<Object?, Object?>{
        'event': 'javascriptChannelMessageReceived',
        'channelName': 'ChartAppDelegate',
        'message': jsonEncode(<String, Object?>{
          'context': 'PageReady',
          'success': <String, Object?>{'source': '20260724_01', 'resetCache': true},
        }),
      });
      expect(e, isA<WebViewChannelMessageEvent>());
      final WebViewChannelMessageEvent c = e as WebViewChannelMessageEvent;
      expect(c.decoded!['context'], 'PageReady');

      final ChannelResponse r = ChannelResponse.tryParse(c.decoded!)!;
      expect(r.context, 'PageReady');
      expect(r.success!.source, '20260724_01');
      expect(r.success!.resetCache, isTrue);
    });

    test('malformed channel JSON yields a null decode, not an exception', () {
      final WebViewEvent e = WebViewEvent.fromPlatform(<Object?, Object?>{
        'event': 'javascriptChannelMessageReceived',
        'channelName': 'ChartAppDelegate',
        'message': 'not json at all',
      });
      expect((e as WebViewChannelMessageEvent).decoded, isNull);
    });
  });

  group('Chart message shapes', () {
    test('a chart error parses its reason', () {
      final ChannelResponse r = ChannelResponse.tryParse(<String, Object?>{
        'context': 'Chart',
        'error': <String, Object?>{
          'source': 'resolveSymbol',
          'reason': 'SymbolNotFound',
          'symbol': '0:NIFTY 50',
        },
      })!;
      expect(r.error!.reason, 'SymbolNotFound');
      expect(r.error!.symbol, '0:NIFTY 50');
      expect(r.success, isNull);
    });

    test('a harness message carries its run id', () {
      final HarnessMessage m = HarnessMessage.tryParse(<String, Object?>{
        'context': 'Harness',
        'runId': 'abc-1',
        'phase': 'authorizeResolved',
        'perf': 4321,
      })!;
      expect(m.runId, 'abc-1');
      expect(m.phase, 'authorizeResolved');
      expect(m.perfMs, 4321);
    });

    test('a non-harness context is rejected', () {
      expect(
        HarnessMessage.tryParse(<String, Object?>{'context': 'Chart'}),
        isNull,
      );
    });

    test('theme falls back to light on an unknown name', () {
      expect(WebPageTheme.fromName('dark'), WebPageTheme.dark);
      expect(WebPageTheme.fromName('nonsense'), WebPageTheme.light);
    });
  });

  group('JWT decoding', () {
    test('an unpadded base64url payload decodes', () {
      // JWT segments are unpadded, which the strict decoder rejects without normalisation.
      final String payload = base64Url
          .encode(utf8.encode(jsonEncode(<String, Object?>{
            'unique_name': 'T06794',
            'role': 'T',
            'iat': 1788432597,
            'exp': 1788436197,
          })))
          .replaceAll('=', '');
      final JwtClaims c = JwtClaims.decode('header.$payload.signature')!;
      expect(c.uniqueName, 'T06794');
      expect(c.role, 'T');
      expect(
        c.expiresAt!.difference(c.issuedAt!),
        const Duration(hours: 1),
      );
    });

    test('a malformed token returns null instead of throwing', () {
      expect(JwtClaims.decode('nope'), isNull);
      expect(JwtClaims.decode('a.b.c'), isNull);
    });
  });
}
