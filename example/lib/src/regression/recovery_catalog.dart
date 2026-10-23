import 'dart:async';

import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_events.dart';

import '../config/endpoints.dart';
import '../config/recovery_page.dart';
import 'event_tape.dart';
import 'expectation.dart';
import 'recovery_case.dart';

/// The cases that exercise the plugin's self-healing primitives.
///
/// What they cover is what a host needs in order to *diagnose* a stuck chart instead of retrying it
/// blindly: whether the page is alive, whether the native side hosts it, and whether its events
/// still reach this engine. They need no network, no token and no chart server; the page they load
/// is served from a `data:` URL.
///
/// Each case starts from [RecoveryContext.reset], so none depends on another.
List<RecoveryCase> buildRecoveryCatalog() => <RecoveryCase>[
      // ------------------------------------------------------------------ probe
      const RecoveryCase(
        id: 'P1',
        title: 'Probe of a healthy page reports everything healthy',
        group: 'Probe',
        run: _p1,
      ),
      const RecoveryCase(
        id: 'P2',
        title: 'Probe of a page without the chart app reports not ready',
        group: 'Probe',
        run: _p2,
      ),
      const RecoveryCase(
        id: 'P3',
        title: 'Probe after the WebView is destroyed reports no WebView',
        group: 'Probe',
        androidOnly: true,
        run: _p3,
      ),
      const RecoveryCase(
        id: 'P4',
        title: 'Probe of a hung renderer times out instead of waiting forever',
        group: 'Probe',
        run: _p4,
      ),
      const RecoveryCase(
        id: 'P5',
        title: 'Probe sees a live page that no platform view hosts',
        group: 'Probe',
        run: _p5,
      ),

      // ------------------------------------------------------------- event path
      const RecoveryCase(
        id: 'E1',
        title: 'A second engine that only registers plugins does not take the events',
        group: 'Event path',
        androidOnly: true,
        run: _e1,
      ),
      const RecoveryCase(
        id: 'E2',
        title: 'A second engine that uses the plugin takes the events; claim restores them',
        group: 'Event path',
        androidOnly: true,
        pins: 'The 2026-10-22 failure: the page stays alive but its messages stop reaching Dart. '
            'Using the plugin from another engine takes the delegate by design.',
        run: _e2,
      ),
      const RecoveryCase(
        id: 'E2b',
        title: 'A navigation from this engine takes the events back on its own',
        group: 'Event path',
        androidOnly: true,
        run: _e2b,
      ),
      const RecoveryCase(
        id: 'E3',
        title: 'Released delegate: page alive, events lost, claim restores them',
        group: 'Event path',
        debugOnly: true,
        run: _e3,
      ),
      const RecoveryCase(
        id: 'E4',
        title: 'claimDelegate reports whether ownership actually moved',
        group: 'Event path',
        debugOnly: true,
        run: _e4,
      ),
      const RecoveryCase(
        id: 'E5',
        title: 'A navigation is acknowledged with loadRequested almost at once',
        group: 'Event path',
        run: _e5,
      ),
      const RecoveryCase(
        id: 'E6',
        title: 'openWebView takes the delegate back',
        group: 'Event path',
        debugOnly: true,
        run: _e6,
      ),
      const RecoveryCase(
        id: 'E7',
        title: 'reloadUrl takes the delegate back',
        group: 'Event path',
        debugOnly: true,
        run: _e7,
      ),
      const RecoveryCase(
        id: 'E8',
        title: 'prewarm takes the delegate back',
        group: 'Event path',
        androidOnly: true,
        debugOnly: true,
        run: _e8,
      ),
      const RecoveryCase(
        id: 'E9',
        title: 'When the owning engine goes away nobody owns the events until one claims',
        group: 'Event path',
        androidOnly: true,
        pins: 'Documents current behaviour: a detaching owner releases the delegate and it is not '
            'handed to a surviving engine, so the host has to claim. A plugin that hands it back '
            'automatically would turn this case red; that would be an improvement, not a regression.',
        run: _e9,
      ),

      // ------------------------------------------------------------------ views
      const RecoveryCase(
        id: 'V1',
        title: 'Disposing and remounting the view is reported and reflected in the probe',
        group: 'Views',
        run: _v1,
      ),
      const RecoveryCase(
        id: 'V2',
        title: 'Disposing an older view does not take the WebView from a newer one',
        group: 'Views',
        run: _v2,
      ),

      // ---------------------------------------------------------------- rebuild
      const RecoveryCase(
        id: 'R1',
        title: 'Hard reset: destroy, prewarm, navigate, remount gives a healthy page',
        group: 'Rebuild',
        run: _r1,
      ),
      const RecoveryCase(
        id: 'R2',
        title: 'A rebuilt WebView is not shown until the platform view is remounted',
        group: 'Rebuild',
        run: _r2,
      ),
      const RecoveryCase(
        id: 'R3',
        title: 'A crashed renderer is reported and the WebView can be rebuilt',
        group: 'Rebuild',
        androidOnly: true,
        run: _r3,
      ),
    ];

// ======================================================================= probe

Future<List<ExpectationResult>> _p1(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('a native WebView exists', p.hasWebView, p),
    check('a platform view hosts it', p.attached, p),
    check('this engine receives its events', p.ownsDelegate, p),
    check('the chart app reports ready', p.ready, p),
    check("the page's message reached Dart (event path works)", p.pong, p),
  ];
}

Future<List<ExpectationResult>> _p2(RecoveryContext c) async {
  await c.reset();
  final int from = c.tape.length;
  await c.loadPage(url: c.pages.plainPage, waitReady: false);
  await c.tape.waitFor(
    (WebViewEvent e) => e is WebViewPageFinishedEvent,
    from: from,
    timeout: RecoveryContext.arrives,
  );
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('a native WebView exists', p.hasWebView, p),
    check('the page answered the script', p.page != null, p),
    check('the chart app is not ready', !p.ready, p),
  ];
}

Future<List<ExpectationResult>> _p3(RecoveryContext c) async {
  await c.reset();
  await c.loadPage();
  await c.host.unmountPrimary();
  await IosWebViewPlugin.destroyWebView();
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('no native WebView exists', !p.hasWebView, p),
    check('the script did not run', p.page == null, p),
    check('the reply says so rather than timing out', p.facts['error'] == 'NO_WEBVIEW', p.facts),
  ];
}

Future<List<ExpectationResult>> _p4(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  // Keep the page's JavaScript thread busy. The call returns only when the loop ends, so it is
  // deliberately not awaited.
  unawaited(IosWebViewPlugin.runJavaScript(buildBusyScript(3500)));
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final Stopwatch sw = Stopwatch()..start();
  final ProbeOutcome busy = await c.probe(timeout: const Duration(milliseconds: 700));
  final int answeredInMs = sw.elapsedMilliseconds;
  await Future<void>.delayed(const Duration(milliseconds: 3600));
  final ProbeOutcome after = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('the probe reported the renderer as not answering', busy.timedOut, busy),
    check('the script did not run while the page was busy', busy.page == null, busy),
    check('it gave up near its own bound, not the busy loop\'s end', answeredInMs < 2600, '$answeredInMs ms'),
    check('once the loop ended the same page answers again', after.ready, after),
  ];
}

Future<List<ExpectationResult>> _p5(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  await c.host.unmountPrimary();
  final ProbeOutcome unhosted = await c.probe();
  final int id = await c.host.mountPrimary();
  final ProbeOutcome hosted = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('with no view mounted the page is still alive', unhosted.ready, unhosted),
    check('with no view mounted nothing hosts the WebView', !unhosted.attached, unhosted),
    check('after remounting a view hosts it again', hosted.attached, hosted),
    check('and it is the new view that hosts it', hosted.attachedViewId == id, '${hosted.attachedViewId} != $id'),
  ];
}

// ================================================================== event path

Future<List<ExpectationResult>> _e1(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  await c.engines.spawnIdle();
  final bool pinged = await c.ping();
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('this engine still owns the delegate', p.ownsDelegate, p),
    check('the page\'s messages still reach this engine', pinged && p.pong, '$pinged / ${p.pong}'),
  ];
}

Future<List<ExpectationResult>> _e2(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final bool before = await c.ping();
  await c.engines.spawnUsingPlugin();
  // The other engine boots its Dart isolate asynchronously, so wait for the effect.
  final ProbeOutcome stolen = await c.probeUntil((ProbeOutcome p) => !p.ownsDelegate);
  final bool lost = !await c.ping();
  final Map<String, Object?> claim = await IosWebViewPlugin.claimDelegate(reason: 'harness:E2');
  final ProbeOutcome after = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('messages reached this engine before the other engine used the plugin', before),
    check('the other engine took the delegate', !stolen.ownsDelegate, stolen),
    check('the page is still alive (its script answers)', stolen.ready, stolen),
    check('but its messages no longer reach this engine', lost && !stolen.pong, 'lost=$lost pong=${stolen.pong}'),
    check('claimDelegate reports that ownership moved', claim['changed'] == true, claim),
    check('after claiming, messages reach this engine again', after.ownsDelegate && after.pong, after),
  ];
}

Future<List<ExpectationResult>> _e2b(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  await c.engines.spawnUsingPlugin();
  final ProbeOutcome stolen = await c.probeUntil((ProbeOutcome p) => !p.ownsDelegate);
  final int from = c.tape.length;
  final bool reloaded = await c.loadPage();
  final WebViewEvent? claimed = await c.tape.waitFor(claimedBy('loadUrl'), from: from, timeout: RecoveryContext.arrives);
  final ProbeOutcome after = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('the other engine took the delegate', !stolen.ownsDelegate, stolen),
    check('the navigation reported claiming the delegate', claimed != null, 'no delegateClaimed(loadUrl)'),
    check('and its PageReady reached this engine', reloaded),
    check('events keep flowing afterwards', after.ownsDelegate && after.pong, after),
  ];
}

Future<List<ExpectationResult>> _e3(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final bool before = await c.ping();
  final bool released = await IosWebViewPlugin.debugReleaseDelegate();
  if (!released) {
    return <ExpectationResult>[check('debugReleaseDelegate is available', false, 'refused: release build?')];
  }
  final bool lost = !await c.ping();
  final ProbeOutcome p = await c.probe();
  final Map<String, Object?> claim = await IosWebViewPlugin.claimDelegate(reason: 'harness:E3');
  final bool after = await c.ping();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('messages reached this engine before the release', before),
    check('after the release the page\'s messages are lost', lost, 'ping still arrived'),
    check('yet the page is alive (its script answers)', p.ready, p),
    check('and the probe says this engine no longer owns the events', !p.ownsDelegate, p),
    check('claimDelegate reports that ownership moved', claim['changed'] == true, claim),
    check('messages reach this engine again', after),
  ];
}

Future<List<ExpectationResult>> _e4(RecoveryContext c) async {
  await c.reset();
  final Map<String, Object?> owned = await IosWebViewPlugin.claimDelegate(reason: 'harness:E4a');
  final bool released = await IosWebViewPlugin.debugReleaseDelegate();
  final Map<String, Object?> moved = await IosWebViewPlugin.claimDelegate(reason: 'harness:E4b');
  final Map<String, Object?> again = await IosWebViewPlugin.claimDelegate(reason: 'harness:E4c');
  return <ExpectationResult>[
    check('claiming what this engine already owns changes nothing', owned['changed'] == false, owned),
    check('debugReleaseDelegate is available', released),
    check('claiming after a release moves ownership', moved['changed'] == true, moved),
    check('claiming again is a no-op', again['changed'] == false, again),
  ];
}

Future<List<ExpectationResult>> _e5(RecoveryContext c) async {
  await c.reset();
  final int from = c.tape.length;
  final Stopwatch sw = Stopwatch()..start();
  await IosWebViewPlugin.openWebView(
    c.pages.freshChartPage(),
    javascriptChannelName: kChartChannel,
    isChart: false,
    disableErrorFallback: true,
  );
  final WebViewEvent? ack = await c.tape.waitFor(
    nativeEvent('loadRequested'),
    from: from,
    timeout: const Duration(milliseconds: 1500),
  );
  final int ackMs = sw.elapsedMilliseconds;
  final WebViewEvent? ready =
      await c.tape.waitFor(pageContext('PageReady'), from: from, timeout: RecoveryContext.arrives);
  return <ExpectationResult>[
    arrived('loadRequested', ack),
    // A host waits ~3 s for this before concluding the event path is dead, so it has to be quick.
    check('within the window a host waits for it', ack != null && ackMs < 1500, '$ackMs ms'),
    arrived('PageReady', ready),
  ];
}

Future<List<ExpectationResult>> _claimByEntryPoint(
  RecoveryContext c,
  String reason,
  Future<void> Function() act, {
  bool expectPageReady = true,
}) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final bool released = await IosWebViewPlugin.debugReleaseDelegate();
  if (!released) {
    return <ExpectationResult>[check('debugReleaseDelegate is available', false, 'refused: release build?')];
  }
  final int from = c.tape.length;
  await act();
  final WebViewEvent? claimed =
      await c.tape.waitFor(claimedBy(reason), from: from, timeout: RecoveryContext.arrives);
  final bool ready = !expectPageReady ||
      await c.tape.waitFor(pageContext('PageReady'), from: from, timeout: RecoveryContext.arrives) != null;
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('delegateClaimed("$reason") arrived', claimed != null, 'nothing within the wait'),
    if (expectPageReady) check('the resulting PageReady reached this engine', ready),
    check('this engine owns the events again', p.ownsDelegate, p),
  ];
}

Future<List<ExpectationResult>> _e6(RecoveryContext c) => _claimByEntryPoint(
      c,
      'loadUrl',
      () => IosWebViewPlugin.openWebView(
        c.pages.freshChartPage(),
        javascriptChannelName: kChartChannel,
        isChart: false,
        disableErrorFallback: true,
      ),
    );

Future<List<ExpectationResult>> _e7(RecoveryContext c) =>
    _claimByEntryPoint(c, 'reloadUrl', IosWebViewPlugin.reloadUrl);

Future<List<ExpectationResult>> _e8(RecoveryContext c) => _claimByEntryPoint(
      c,
      'prewarm',
      () async {
        await IosWebViewPlugin.prewarm();
      },
      expectPageReady: false,
    );

Future<List<ExpectationResult>> _e9(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  await c.engines.spawnUsingPlugin();
  final ProbeOutcome stolen = await c.probeUntil((ProbeOutcome p) => !p.ownsDelegate);
  // The engine that owns the delegate goes away, as a headless engine does when its work is done.
  await c.engines.disposeAll();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final ProbeOutcome orphaned = await c.probe();
  final bool lost = !await c.ping();
  final Map<String, Object?> claim = await IosWebViewPlugin.claimDelegate(reason: 'harness:E9');
  final bool restored = await c.ping();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    check('the other engine took the delegate', !stolen.ownsDelegate, stolen),
    check('after it is destroyed this engine still does not own the events', !orphaned.ownsDelegate, orphaned),
    check('and the page\'s messages are lost', lost, 'ping still arrived'),
    check('claimDelegate reports that ownership moved', claim['changed'] == true, claim),
    check('after claiming, messages arrive again', restored),
  ];
}

// ====================================================================== views

Future<List<ExpectationResult>> _v1(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final int from = c.tape.length;
  final int? oldId = c.host.primaryId;
  await c.host.unmountPrimary();
  final WebViewEvent? detached = await c.tape.waitFor(
    (WebViewEvent e) => e is WebViewDetachedEvent && e.viewId == oldId,
    from: from,
    timeout: RecoveryContext.arrives,
  );
  final ProbeOutcome unhosted = await c.probe();
  final int newId = await c.host.mountPrimary();
  final WebViewEvent? attached = await c.tape.waitFor(
    (WebViewEvent e) => e is WebViewAttachedEvent && e.viewId == newId,
    from: from,
    timeout: RecoveryContext.arrives,
  );
  final ProbeOutcome hosted = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    arrived('viewDetached for the disposed view', detached),
    check('it was the owner of the WebView', detached is WebViewDetachedEvent && detached.owned, detached),
    check('with no view the probe says nothing hosts the WebView', !unhosted.attached, unhosted),
    arrived('viewAttached for the new view', attached),
    check('the probe says the new view hosts it', hosted.attached && hosted.attachedViewId == newId, hosted),
    check('and the page survived the round trip', hosted.ready, hosted),
  ];
}

Future<List<ExpectationResult>> _v2(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final int? primary = c.host.primaryId;
  final int from = c.tape.length;
  final int secondary = await c.host.mountSecondary();
  final WebViewEvent? attached = await c.tape.waitFor(
    (WebViewEvent e) => e is WebViewAttachedEvent && e.viewId == secondary,
    from: from,
    timeout: RecoveryContext.arrives,
  );
  final ProbeOutcome both = await c.probe();
  // The older view goes away while the newer one is hosting the WebView. This is the kept-alive
  // mini chart under a full chart, or a chart route replaced by another.
  await c.host.unmountPrimary();
  final WebViewEvent? detached = await c.tape.waitFor(
    (WebViewEvent e) => e is WebViewDetachedEvent && e.viewId == primary,
    from: from,
    timeout: RecoveryContext.arrives,
  );
  final ProbeOutcome after = await c.probe();
  await c.host.unmountSecondary();
  final ProbeOutcome none = await c.probe();
  final String trace = 'primary=$primary secondary=$secondary: ${viewTrace(c.tape.events.skip(from))}';
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    arrived('viewAttached for the second view', attached),
    check('it took the WebView from the first', both.attached && both.attachedViewId == secondary, '$both | $trace'),
    arrived('viewDetached for the first view', detached),
    check('which reports it did not own the WebView', detached is WebViewDetachedEvent && !detached.owned, trace),
    check('the second view still hosts the WebView', after.attached && after.attachedViewId == secondary, '$after | $trace'),
    check('and the page is still alive', after.ready, after),
    check('only when the last view goes does nothing host it', !none.attached, none),
  ];
}

// ==================================================================== rebuild

Future<List<ExpectationResult>> _r1(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  await c.host.unmountPrimary();
  await IosWebViewPlugin.destroyWebView();
  final ProbeOutcome gone = await c.probe();
  await IosWebViewPlugin.claimDelegate(reason: 'harness:R1');
  await IosWebViewPlugin.prewarm(javascriptChannels: <String>[kChartChannel]);
  final bool reloaded = await c.loadPage();
  await c.host.mountPrimary();
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady before the reset', loaded),
    // On iOS a destroyed WebView is replaced at once, so there is no gap to observe.
    if (c.isAndroid) check('after destroy no WebView exists', !gone.hasWebView, gone),
    check('the rebuilt WebView loads and reports PageReady', reloaded),
    check('a platform view hosts it', p.attached, p),
    check('this engine receives its events', p.ownsDelegate, p),
    check('the chart app reports ready', p.ready, p),
    check('and its messages reach Dart', p.pong, p),
  ];
}

Future<List<ExpectationResult>> _r2(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  // The view stays mounted, so it keeps holding the WebView that is about to be discarded.
  await IosWebViewPlugin.destroyWebView();
  await IosWebViewPlugin.claimDelegate(reason: 'harness:R2');
  await IosWebViewPlugin.prewarm(javascriptChannels: <String>[kChartChannel]);
  final bool reloaded = await c.loadPage();
  final ProbeOutcome stale = await c.probe();
  await c.host.unmountPrimary();
  final int id = await c.host.mountPrimary();
  final ProbeOutcome fixed = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady before the rebuild', loaded),
    check('the rebuilt WebView loads and reports PageReady', reloaded),
    check('it is alive', stale.ready, stale),
    // This is why a host must remount its platform view after a rebuild.
    check('but the still-mounted view does not host it', !stale.attached, stale),
    check('after remounting, the new view hosts it', fixed.attached && fixed.attachedViewId == id, fixed),
  ];
}

Future<List<ExpectationResult>> _r3(RecoveryContext c) async {
  await c.reset();
  final bool loaded = await c.loadPage();
  final int from = c.tape.length;
  // The standard way to take a renderer down for onRenderProcessGone.
  await IosWebViewPlugin.openWebView(
    'chrome://crash',
    javascriptChannelName: kChartChannel,
    isChart: false,
    disableErrorFallback: true,
  );
  final WebViewEvent? gone = await c.tape.waitFor(
    nativeEvent('renderProcessGone'),
    from: from,
    timeout: const Duration(seconds: 10),
  );
  final ProbeOutcome crashed = await c.probe();
  await c.reset();
  final bool rebuilt = await c.loadPage();
  final ProbeOutcome p = await c.probe();
  return <ExpectationResult>[
    check('page reported PageReady', loaded),
    arrived('renderProcessGone', gone),
    check('the plugin released the dead WebView', !crashed.hasWebView, crashed),
    check('a rebuilt WebView loads and reports PageReady', rebuilt),
    check('and is healthy', p.ready && p.attached && p.ownsDelegate && p.pong, p),
  ];
}
