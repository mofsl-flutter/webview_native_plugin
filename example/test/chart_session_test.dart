import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin/chart_session.dart';
import 'package:ios_webview_plugin/webview_events.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel plugin = MethodChannel('webview_mo_flutter');
  const MethodChannel eventChannel = MethodChannel(kWebViewEventChannelName);
  const StandardMethodCodec codec = StandardMethodCodec();

  final List<String> injected = <String>[];
  // What the page "returns" from the wrapped evaluate. The plugin decodes a JSON string, so
  // these are the encoded forms of the wire contract in chart_session.dart.
  String? pageVerdict;

  setUp(() {
    injected.clear();
    pageVerdict = '"__cs_ok"';
    ChartSession.instance.resetForTest();
    messenger.setMockMethodCallHandler(plugin, (MethodCall call) async {
      if (call.method != 'runJavaScript') return null;
      final String script =
          (call.arguments as Map<Object?, Object?>)['script'].toString();
      injected.add(script);
      // The reporter bootstrap is injected for its side effect and returns nothing.
      if (script.contains('window.__chartSessionAck=')) return null;
      return pageVerdict;
    });
    // An EventChannel sends "listen" on its own channel name before delivering anything.
    messenger.setMockMethodCallHandler(eventChannel, (MethodCall call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
    ChartSession.instance.resetForTest();
  });

  Future<void> emit(Map<String, Object?> payload) async {
    await messenger.handlePlatformMessage(
      kWebViewEventChannelName,
      codec.encodeSuccessEnvelope(payload),
      (ByteData? _) {},
    );
  }

  Future<void> emitAck(String opId, String status, {String? detail}) => emit(
        <String, Object?>{
          'event': 'javascriptChannelMessageReceived',
          'channelName': kChartSessionAckChannel,
          'message': jsonEncode(<String, Object?>{
            'opId': opId,
            'status': status,
            'detail': detail,
          }),
        },
      );

  group('Event decoding', () {
    test('viewAttached decodes, carrying the reparent flag', () {
      final WebViewEvent event = WebViewEvent.fromPlatform(<Object?, Object?>{
        'event': 'viewAttached',
        'viewId': 7,
        'wasReparented': true,
        'loadId': 3,
      });
      expect(event, isA<WebViewAttachedEvent>());
      final WebViewAttachedEvent attached = event as WebViewAttachedEvent;
      expect(attached.viewId, 7);
      expect(attached.wasReparented, isTrue);
      expect(attached.loadId, 3);
    });

    test('viewAttachFailed carries the native message', () {
      final WebViewEvent event = WebViewEvent.fromPlatform(<Object?, Object?>{
        'event': 'viewAttachFailed',
        'viewId': 2,
        'message': 'boom',
      });
      expect((event as WebViewAttachFailedEvent).message, 'boom');
    });

    test('viewDetached decodes rather than falling through to unknown', () {
      final WebViewEvent event = WebViewEvent.fromPlatform(<Object?, Object?>{
        'event': 'viewDetached',
        'viewId': 4,
      });
      expect(event, isA<WebViewDetachedEvent>());
      expect((event as WebViewDetachedEvent).viewId, 4);
    });

    test('a missing viewId degrades to -1 instead of throwing', () {
      final WebViewEvent event =
          WebViewEvent.fromPlatform(<Object?, Object?>{'event': 'viewDetached'});
      expect((event as WebViewDetachedEvent).viewId, -1);
    });
  });

  group('Session state', () {
    test('starts blank', () {
      final ChartSessionSnapshot s = ChartSession.instance.snapshot;
      expect(s.loadId, -1);
      expect(s.isPageLoaded, isFalse);
      expect(s.isAttached, isFalse);
    });

    test('reports a loaded page after started and finished', () async {
      ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      await emit(<String, Object?>{
        'event': 'pageStarted',
        'url': 'https://example.test/chart',
        'loadId': 11,
      });
      expect(ChartSession.instance.snapshot.isPageLoaded, isFalse);

      await emit(<String, Object?>{
        'event': 'pageFinished',
        'url': 'https://example.test/chart',
        'loadId': 11,
      });

      final ChartSessionSnapshot s = ChartSession.instance.snapshot;
      expect(s.isPageLoaded, isTrue);
      expect(s.loadId, 11);
      expect(s.url, 'https://example.test/chart');
    });

    test('a detached handle stops receiving events but the session keeps tracking', () async {
      final List<String> seen = <String>[];
      final ChartSessionHandle handle = ChartSession.instance.attach(
        onEvent: (WebViewEvent e) => seen.add(e.runtimeType.toString()),
      );
      await emit(<String, Object?>{'event': 'pageStarted', 'url': 'a', 'loadId': 1});
      expect(seen, hasLength(1));

      handle.detach();
      await emit(<String, Object?>{'event': 'pageFinished', 'url': 'a', 'loadId': 1});

      // The handle heard nothing more — but the session still knows the page finished, which is
      // exactly what the next widget to attach needs to read.
      expect(seen, hasLength(1));
      expect(ChartSession.instance.snapshot.isPageLoaded, isTrue);
      expect(handle.isDetached, isTrue);
    });

    test('detach is idempotent', () {
      final ChartSessionHandle handle =
          ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      handle.detach();
      handle.detach();
      expect(ChartSession.instance.snapshot.liveHandles, 0);
    });

    test('counts live platform views from the native attach events', () async {
      ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      await emit(<String, Object?>{'event': 'viewAttached', 'viewId': 1});
      expect(ChartSession.instance.snapshot.livePlatformViews, 1);

      // The contention hazard: a route transition mounts the incoming view before the outgoing
      // one is disposed, so both briefly hold the single WebView.
      await emit(<String, Object?>{'event': 'viewAttached', 'viewId': 2});
      expect(ChartSession.instance.snapshot.livePlatformViews, 2);

      await emit(<String, Object?>{'event': 'viewDetached', 'viewId': 1});
      final ChartSessionSnapshot s = ChartSession.instance.snapshot;
      expect(s.livePlatformViews, 1);
      expect(s.attachedViewId, 2);
      expect(s.isAttached, isTrue);
    });
  });

  group('Tracked operations', () {
    test('a synchronous operation reports ok, needing no channel at all', () async {
      pageVerdict = '"__cs_ok"';
      final OperationResult result =
          await ChartSession.instance.runOperation('return 1;');
      expect(result.status, OperationStatus.ok);
      expect(result.isOk, isTrue);
      expect(result.error, isNull);
    });

    test('a throwing operation is reported with the page detail', () async {
      pageVerdict = '"__cs_threw:boom is not a function"';
      final OperationResult result =
          await ChartSession.instance.runOperation('return window.boom();');
      expect(result.status, OperationStatus.threw);
      expect(result.error, 'boom is not a function');
    });

    test('no verdict at all is a reported failure, not a silent success', () async {
      // The case the plain runJavaScript path cannot distinguish from success.
      pageVerdict = null;
      final OperationResult result = await ChartSession.instance.runOperation(
        'return window.__missing__();',
        timeout: const Duration(milliseconds: 120),
      );
      expect(result.status, OperationStatus.timeout);
      expect(result.isOk, isFalse);
      expect(result.error, contains('no verdict'));
    });

    test('a promise that never settles times out', () async {
      pageVerdict = '"__cs_pending"';
      final OperationResult result = await ChartSession.instance.runOperation(
        'return new Promise(function(){});',
        timeout: const Duration(milliseconds: 120),
      );
      expect(result.status, OperationStatus.timeout);
      expect(result.error, contains('did not settle'));
    });

    test('a promise settled through the ack channel resolves ok', () async {
      ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      pageVerdict = '"__cs_pending"';
      final Future<OperationResult> pending = ChartSession.instance.runOperation(
        'return window.Authorize(t);',
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();
      await emitAck(_lastOpId(injected), 'ok');
      expect((await pending).status, OperationStatus.ok);
    });

    test('a rejected promise is reported as threw', () async {
      ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      pageVerdict = '"__cs_pending"';
      final Future<OperationResult> pending = ChartSession.instance.runOperation(
        'return window.Authorize(t);',
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();
      await emitAck(_lastOpId(injected), 'threw', detail: '401');
      final OperationResult result = await pending;
      expect(result.status, OperationStatus.threw);
      expect(result.error, '401');
    });

    test('installs the reporter once and correlates by a generated id', () async {
      await ChartSession.instance.runOperation('return 1;');
      expect(injected.first, contains('window.__chartSessionAck='));
      expect(injected.last, contains('return 1;'));
      expect(injected.last, contains('op-1-'));
    });

    test('a navigation abandons anything still pending rather than hanging', () async {
      ChartSession.instance.attach(onEvent: (WebViewEvent _) {});
      pageVerdict = '"__cs_pending"';
      final Future<OperationResult> pending = ChartSession.instance.runOperation(
        'return new Promise(function(){});',
        timeout: const Duration(seconds: 30),
      );
      await pumpEventQueue();
      await emit(<String, Object?>{'event': 'pageStarted', 'url': 'b', 'loadId': 2});

      final OperationResult result = await pending;
      expect(result.status, OperationStatus.timeout);
      expect(result.error, contains('navigated'));
    });

    test('operations are serialised, not raced', () async {
      final Future<OperationResult> first =
          ChartSession.instance.runOperation('return 1;');
      final Future<OperationResult> second =
          ChartSession.instance.runOperation('return 2;');
      await Future.wait<OperationResult>(<Future<OperationResult>>[first, second]);

      final int bootstraps =
          injected.where((String s) => s.contains('window.__chartSessionAck=')).length;
      expect(bootstraps, 1, reason: 'the reporter is installed once per document');
      final int firstIndex = injected.indexWhere((String s) => s.contains('return 1;'));
      final int secondIndex = injected.indexWhere((String s) => s.contains('return 2;'));
      expect(firstIndex, lessThan(secondIndex));
    });
  });
}

String _lastOpId(List<String> injected) {
  final RegExp pattern = RegExp(r'"(op-\d+-\d+)"');
  return pattern.firstMatch(injected.last)!.group(1)!;
}
