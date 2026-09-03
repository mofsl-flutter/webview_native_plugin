import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';
import 'package:ios_webview_plugin/webview_mo_flutter_view.dart';

import '../config/endpoints.dart';
import '../model/bench_models.dart';
import '../model/stats.dart';
import '../service/bench_runner.dart';
import '../service/webview_bridge.dart';
import 'results_screen.dart';
import 'session.dart';

/// Hosts the platform view and runs the batch.
class ChartScreen extends StatefulWidget {
  /// Creates the chart screen.
  const ChartScreen({required this.session, super.key});

  /// Shared session state.
  final BenchmarkSession session;

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  // Stable identity so a route animation never remounts the platform view. Remounting would
  // reparent a live WebView mid-run and corrupt the measurement.
  final GlobalKey _hostKey = GlobalKey();
  final Completer<void> _viewReady = Completer<void>();

  late final BenchRunner _runner;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _runner = BenchRunner(token: widget.session.token!);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;

    if (widget.session.template.preWarm) {
      // Register the channel here: an interface only takes effect on the next navigation, so
      // this is what guarantees the page can post its very first message.
      await IosWebViewPlugin.prewarm(
        javascriptChannels: <String>[kChartChannel],
        cacheMode: widget.session.template.cacheMode,
        url: kChartUrl,
      );
    }

    await _runner.runBatch(
      configs: widget.session.buildConfigs(),
      repeats: widget.session.repeats,
      awaitViewMounted: () => _viewReady.future,
    );

    if (!mounted) return;
    widget.session.addResults(_runner.records);
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(session: widget.session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving mid-batch would dispose the platform view and detach the WebView underneath a
      // live run.
      canPop: !_runner.isRunning,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && _runner.isRunning) _confirmAbort();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('3 · Running'),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.stop_circle),
              tooltip: 'Abort batch',
              onPressed: _confirmAbort,
            ),
          ],
        ),
        body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: WebViewMoFlutterView(
                key: _hostKey,
                backgroundColor: const Color(0xFF16182C),
                compositionMode: widget.session.template.hybridComposition
                    ? WebViewCompositionMode.hybrid
                    : WebViewCompositionMode.textureLayerWithFallback,
                onPlatformViewCreated: (int _) {
                  if (!_viewReady.isCompleted) _viewReady.complete();
                },
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              top: 8,
              child: ListenableBuilder(
                listenable: _runner,
                builder: (BuildContext context, Widget? _) =>
                    _TimelineOverlay(runner: _runner),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmAbort() {
    _runner.abort();
    if (mounted) Navigator.of(context).maybePop();
  }
}

class _TimelineOverlay extends StatelessWidget {
  const _TimelineOverlay({required this.runner});

  final BenchRunner runner;

  @override
  Widget build(BuildContext context) {
    final RunPhase? current = runner.phase;
    return Card(
      color: Colors.black.withValues(alpha: 0.78),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  'Run ${runner.runIndex}/${runner.runTotal}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  '${(runner.elapsedMicros / 1000000).toStringAsFixed(1)}s',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              runner.activeRunId ?? 'idle',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 6),
            ...RunPhase.values.map((RunPhase p) {
              final int? value = _markFor(p);
              final bool active = p == current;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 14,
                      child: active
                          ? const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.amber,
                              ),
                            )
                          : Icon(
                              value != null
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 11,
                              color: value != null ? Colors.greenAccent : Colors.white24,
                            ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.label,
                        style: TextStyle(
                          color: active ? Colors.amber : Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Text(
                      formatMicros(value),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 4),
            Text(
              'stray ${runner.strayEvents} · tail ${runner.tailEvents} · '
              'events ${WebViewBridge.instance.logLength.value}',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  int? _markFor(RunPhase p) => switch (p) {
        RunPhase.mountingView => null,
        RunPhase.navigating => runner.marks['openAcked'],
        RunPhase.awaitingPageStarted => runner.marks['pageStarted'],
        RunPhase.awaitingPageFinished => runner.marks['pageFinished'],
        RunPhase.awaitingPageReady => runner.marks['pageReady'],
        RunPhase.awaitingAuthorizeResolved => runner.marks['authorizeResolved'],
        RunPhase.awaitingChartTerminal => runner.marks['chartTerminal'],
      };
}
