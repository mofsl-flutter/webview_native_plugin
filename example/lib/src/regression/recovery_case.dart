import 'dart:async';
import 'dart:io' show Platform;

import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_events.dart';

import '../config/endpoints.dart';
import '../config/recovery_page.dart';
import '../service/headless_engines.dart';
import '../service/recovery_pages.dart';
import 'event_tape.dart';
import 'expectation.dart';

/// UI operations a recovery case cannot perform itself: mounting and disposing platform views.
///
/// Two views can be mounted at once. That is the situation of a kept-alive mini chart underneath a
/// full chart, and the one the plugin's view-ownership handling exists for.
abstract class RecoveryHost {
  /// Mounts the primary platform view and returns its platform-view id.
  Future<int> mountPrimary();

  /// Disposes the primary platform view.
  Future<void> unmountPrimary();

  /// Mounts a second platform view alongside the first and returns its id.
  Future<int> mountSecondary();

  /// Disposes the second platform view.
  Future<void> unmountSecondary();

  /// Id of the primary view while mounted, else `null`.
  int? get primaryId;

  /// Id of the secondary view while mounted, else `null`.
  int? get secondaryId;
}

/// What a probe saw, with the page's own answer already decoded.
class ProbeOutcome {
  /// Creates an outcome.
  const ProbeOutcome({required this.facts, required this.page, required this.pong});

  /// Native facts and the raw script result, as `IosWebViewPlugin.probe` returned them.
  final Map<String, Object?> facts;

  /// The script's decoded return value, or `null` when it did not run.
  final Map<String, Object?>? page;

  /// Whether the page's message reached Dart. Distinct from [page]: the return value does not use
  /// the event path, the message does.
  final bool pong;

  /// Whether a native WebView exists.
  bool get hasWebView => facts['hasWebView'] == true;

  /// Whether a platform view hosts the WebView.
  bool get attached => facts['attached'] == true;

  /// Whether this engine receives the WebView's events.
  bool get ownsDelegate => facts['ownsDelegate'] == true;

  /// Whether the renderer failed to answer in time.
  bool get timedOut => facts['timedOut'] == true;

  /// Whether the page's chart app reported itself ready.
  bool get ready => page?['ready'] == true;

  /// Id of the platform view hosting the WebView, or `-1`.
  Object? get attachedViewId => facts['attachedViewId'];

  @override
  String toString() => 'hasWebView=$hasWebView attached=$attached owns=$ownsDelegate '
      'ready=$ready pong=$pong timedOut=$timedOut view=$attachedViewId';
}

/// Everything a recovery case works with.
class RecoveryContext {
  /// Creates a context.
  RecoveryContext({
    required this.tape,
    required this.host,
    required this.engines,
    RecoveryPages? pages,
  }) : pages = pages ?? RecoveryPages();

  /// The pages the cases load.
  final RecoveryPages pages;

  /// Recording of every native event.
  final EventTape tape;

  /// Platform-view operations.
  final RecoveryHost host;

  /// Extra Flutter engines, Android only.
  final HeadlessEngines engines;

  int _seq = 0;

  /// Whether this run is on Android.
  bool get isAndroid => Platform.isAndroid;

  /// How long to wait for an event that should arrive.
  static const Duration arrives = Duration(seconds: 4);

  /// How long to wait before concluding an event is not coming.
  static const Duration absent = Duration(milliseconds: 1800);

  /// Puts the plugin in a known state: no extra engines, one fresh WebView hosted by the primary
  /// view, owned by this engine, nothing loaded.
  ///
  /// Goes through destroy and prewarm on purpose. That is the same sequence a hard reset uses, so
  /// every case that reaches its first assertion has also exercised it.
  Future<void> reset() async {
    await pages.ensureStarted();
    await engines.disposeAll();
    if (host.secondaryId != null) await host.unmountSecondary();
    if (host.primaryId != null) await host.unmountPrimary();
    await IosWebViewPlugin.destroyWebView();
    await IosWebViewPlugin.claimDelegate(reason: 'harness:reset');
    await IosWebViewPlugin.prewarm(javascriptChannels: <String>[kChartChannel]);
    await host.mountPrimary();
    tape.clear();
  }

  /// Navigates to the recovery page and waits for its `PageReady`.
  ///
  /// Returns whether it arrived. Assertions that need the page loaded should include this in their
  /// own checks rather than assuming it.
  Future<bool> loadPage({String? url, bool waitReady = true}) async {
    final int from = tape.length;
    await IosWebViewPlugin.openWebView(
      url ?? pages.freshChartPage(),
      javascriptChannelName: kChartChannel,
      isChart: false,
      disableErrorFallback: true,
    );
    if (!waitReady) return true;
    return await tape.waitFor(pageContext('PageReady'), from: from, timeout: arrives) != null;
  }

  /// Asks the page and the native side for their state; see [ProbeOutcome].
  Future<ProbeOutcome> probe({Duration timeout = const Duration(milliseconds: 1200)}) async {
    final int id = ++_seq;
    final int from = tape.length;
    final Map<String, Object?> facts =
        await IosWebViewPlugin.probe(buildProbeScript(id), timeout: timeout);
    final bool pong =
        await tape.waitFor(probeReply(id), from: from, timeout: absent) != null;
    return ProbeOutcome(facts: facts, page: decodeProbeResult(facts['js']), pong: pong);
  }

  /// Makes the page post one message and reports whether it reached Dart within [wait].
  Future<bool> ping({Duration? wait}) async {
    final int id = ++_seq;
    final int from = tape.length;
    await IosWebViewPlugin.runJavaScript(buildPingScript(id));
    return await tape.waitFor(pingReply(id), from: from, timeout: wait ?? absent) != null;
  }

  /// Polls [probe] until [done] holds, for effects that complete on another engine's schedule.
  /// Returns the last outcome, so a caller can report what it saw when the wait gave up.
  Future<ProbeOutcome> probeUntil(
    bool Function(ProbeOutcome) done, {
    Duration within = const Duration(seconds: 8),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    ProbeOutcome last = await probe();
    while (!done(last) && sw.elapsed < within) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      last = await probe();
    }
    return last;
  }
}

/// One recovery case.
class RecoveryCase {
  /// Creates a case.
  const RecoveryCase({
    required this.id,
    required this.title,
    required this.group,
    required this.run,
    this.androidOnly = false,
    this.debugOnly = false,
    this.pins,
  });

  /// Stable id, e.g. `E2`.
  final String id;

  /// One-line description.
  final String title;

  /// Group heading.
  final String group;

  /// Runs the case and returns its checks.
  final Future<List<ExpectationResult>> Function(RecoveryContext c) run;

  /// Whether the case needs an Android-only mechanism (a second engine, a renderer crash).
  final bool androidOnly;

  /// Whether the case needs a debug build.
  final bool debugOnly;

  /// What this case documents, when it pins current behaviour that is not obviously desirable.
  final String? pins;
}

/// Builds a check result.
// ignore: avoid_positional_boolean_parameters
ExpectationResult check(String what, bool ok, [Object? actual]) =>
    ExpectationResult(what, ok, actual: ok ? null : '$actual');

/// Convenience for the common "event arrived" / "event did not arrive" checks.
ExpectationResult arrived(String what, WebViewEvent? e) =>
    ExpectationResult('$what arrived', e != null, actual: e == null ? 'nothing within the wait' : null);
