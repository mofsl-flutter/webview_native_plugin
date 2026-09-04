import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ios_webview_plugin/chart_session.dart';
import 'package:ios_webview_plugin/webview_events.dart';
import 'package:ios_webview_plugin/webview_mo_flutter_view.dart';

import '../regression/autorun.dart';
import '../regression/expectation.dart';
import '../regression/scenario.dart';
import '../regression/scenario_catalog.dart';
import '../regression/scenario_runner.dart';
import 'log_screen.dart';
import 'session.dart';

/// Runs the regression catalog and reports per-case verdicts.
class RegressionScreen extends StatefulWidget {
  /// Creates the screen.
  const RegressionScreen({
    required this.session,
    this.autorunScenarios,
    super.key,
  });

  /// Shared session state.
  final BenchmarkSession session;

  /// When set, these cases run immediately and their verdicts are logged for collection.
  final List<Scenario>? autorunScenarios;

  @override
  State<RegressionScreen> createState() => _RegressionScreenState();
}

class _RegressionScreenState extends State<RegressionScreen> {
  // Stable identity: the platform view must not be remounted by a rebuild, only by the
  // deliberate navigate-away step.
  final GlobalKey _hostKey = GlobalKey();
  final List<Scenario> _catalog = buildCatalog();

  Completer<void> _viewReady = Completer<void>();
  late final ScenarioRunner _runner;

  /// Whether the platform view is in the tree.
  ///
  /// Pushing an opaque route is NOT enough to dispose it — Flutter keeps a covered route's
  /// state alive, so the view is never recreated and anything awaiting its creation hangs.
  /// Swapping it out of the tree is what actually exercises dispose/recreate.
  bool _viewMounted = true;

  @override
  void initState() {
    super.initState();
    _runner = ScenarioRunner(
      token: widget.session.token!,
      host: ScenarioHost(
        awaitViewMounted: () => _viewReady.future,
        navigateAway: _navigateAway,
        navigateBack: _navigateBack,
        recreateChartScreen: _recreateChartScreen,
      ),
    );
    final List<Scenario>? auto = widget.autorunScenarios;
    if (auto != null && auto.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The platform view must exist before any case runs, so wait for it rather than
        // starting on the first frame.
        _viewReady.future.then((_) => runAndEmit(_runner, auto));
      });
    }
  }

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _navigateAway() async {
    _viewReady = Completer<void>();
    setState(() => _viewMounted = false);
    // Let the framework actually tear the platform view down before continuing.
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Future<void> _navigateBack() async {
    setState(() => _viewMounted = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  /// Pushes a real route so a brand-new `State` attaches to the session from scratch.
  ///
  /// This screen's own platform view is unmounted first, so the pushed route's view is the only
  /// one contending for the singleton WebView. What comes back is the rebuilt screen's own read of
  /// the session, taken before it has seen a single event of its own.
  Future<Map<String, Object?>> _recreateChartScreen() async {
    // Resolved before the first await: the context must not be touched across an async gap.
    final NavigatorState navigator = Navigator.of(context);
    _viewReady = Completer<void>();
    setState(() => _viewMounted = false);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final Map<String, Object?>? observed =
        await navigator.push<Map<String, Object?>>(
      MaterialPageRoute<Map<String, Object?>>(
        builder: (BuildContext _) => const RecreatedChartRoute(),
      ),
    );

    if (!mounted) return observed ?? <String, Object?>{};
    setState(() => _viewMounted = true);
    await _viewReady.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return observed ?? <String, Object?>{};
  }

  Future<void> _runAll() => _runner.runAll(_catalog);

  Future<void> _runFailedOnly() {
    final List<Scenario> failed = _catalog
        .where((Scenario s) {
          final ScenarioResult? r = _runner.results[s.id];
          return r != null && !r.pass;
        })
        .toList();
    return _runner.runAll(failed.isEmpty ? _catalog : failed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Regression'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Event log',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // Kept small but mounted: the platform view must exist for any case to run.
          SizedBox(
            height: 140,
            child: Stack(
              children: <Widget>[
                if (_viewMounted)
                  Positioned.fill(
                    child: WebViewMoFlutterView(
                      key: _hostKey,
                      backgroundColor: const Color(0xFF16182C),
                      onPlatformViewCreated: (int _) {
                        if (!_viewReady.isCompleted) _viewReady.complete();
                      },
                    ),
                  )
                else
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0xFF16182C),
                      child: Center(
                        child: Text(
                          'platform view detached',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListenableBuilder(
            listenable: _runner,
            builder: (BuildContext context, Widget? _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text('Run all (${_catalog.length})'),
                    onPressed: _runner.isRunning ? null : _runAll,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _runner.isRunning ? null : _runFailedOnly,
                    child: const Text('Failed only'),
                  ),
                  const Spacer(),
                  if (_runner.isRunning)
                    Expanded(
                      child: Text(
                        '${_runner.current?.id ?? ''} · ${_runner.currentStep ?? ''}',
                        style: const TextStyle(fontSize: 11),
                        textAlign: TextAlign.right,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _runner,
              builder: (BuildContext context, Widget? _) => ListView.builder(
                itemCount: _catalog.length,
                itemBuilder: (BuildContext context, int i) {
                  final Scenario s = _catalog[i];
                  return _CaseTile(
                    scenario: s,
                    result: _runner.results[s.id],
                    running: _runner.current?.id == s.id && _runner.isRunning,
                    onRun: _runner.isRunning ? null : () => _runner.run(s),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaseTile extends StatelessWidget {
  const _CaseTile({
    required this.scenario,
    required this.result,
    required this.running,
    required this.onRun,
  });

  final Scenario scenario;
  final ScenarioResult? result;
  final bool running;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    final Widget leading = running
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            result == null
                ? Icons.radio_button_unchecked
                : (result!.pass ? Icons.check_circle : Icons.cancel),
            color: result == null
                ? Colors.white24
                : (result!.pass ? Colors.greenAccent : Colors.redAccent),
            size: 18,
          );

    return ExpansionTile(
      dense: true,
      leading: leading,
      title: Text(
        '${scenario.id}  ${scenario.title}',
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        '${scenario.dimension.label}'
        '${scenario.precondition == null ? '' : ' · needs ${scenario.precondition!.name}'}'
        '${result?.error == null ? '' : ' · ERROR'}',
        style: const TextStyle(fontSize: 10),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.play_circle_outline, size: 20),
        onPressed: onRun,
      ),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (scenario.hypothesis != null) ...<Widget>[
                Text(
                  'Hypothesis',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Text(
                  scenario.hypothesis!,
                  style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
                ),
                const SizedBox(height: 8),
              ],
              Text('Steps', style: Theme.of(context).textTheme.labelSmall),
              ...scenario.steps.map(
                (ScenarioStep s) => Text(
                  '· ${s.describe}',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 8),
              Text('Expectations', style: Theme.of(context).textTheme.labelSmall),
              if (result == null)
                ...scenario.expectations.map(
                  (Expectation e) => Text(
                    '· ${e.description}',
                    style: const TextStyle(fontSize: 11),
                  ),
                )
              else if (result!.error != null)
                Text(
                  result!.error!,
                  style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                )
              else
                ...result!.results.map(
                  (ExpectationResult r) => Text(
                    '${r.pass ? "✓" : "✗"} ${r.description}'
                    '${r.actual == null ? '' : "  → ${r.actual}"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: r.pass ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                ),
              if (result != null && result!.observations.notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text('Notes', style: Theme.of(context).textTheme.labelSmall),
                ...result!.observations.notes.map(
                  (String n) => Text('· $n', style: const TextStyle(fontSize: 10)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A chart host built from scratch, used to prove a rebuilt `State` inherits the real page state.
///
/// Nothing is passed in and nothing is carried over: this `State` learns everything it knows about
/// the page from `ChartSession`. If the session were widget-scoped, this screen would believe it
/// were looking at a blank page while the singleton WebView sits fully loaded behind it.
class RecreatedChartRoute extends StatefulWidget {
  /// Creates the route.
  const RecreatedChartRoute({super.key});

  @override
  State<RecreatedChartRoute> createState() => _RecreatedChartRouteState();
}

class _RecreatedChartRouteState extends State<RecreatedChartRoute> {
  ChartSessionHandle? _handle;
  final List<String> _seen = <String>[];
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    // The session owns the subscription, so nothing can land on this State after it detaches.
    _handle = ChartSession.instance.attach(onEvent: _onEvent);
  }

  @override
  void dispose() {
    _handle?.detach();
    super.dispose();
  }

  void _onEvent(WebViewEvent event) {
    if (_seen.length < 20) _seen.add(event.runtimeType.toString());
  }

  Future<void> _reportAndPop() async {
    if (_reported) return;
    _reported = true;
    // Let the reparent settle so the attach event has landed.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    final ChartSessionSnapshot snapshot = ChartSession.instance.snapshot;
    Navigator.of(context).pop(<String, Object?>{
      'loadId': snapshot.loadId,
      'pageStarted': snapshot.pageStarted,
      'pageFinished': snapshot.pageFinished,
      'isPageLoaded': snapshot.isPageLoaded,
      'isAttached': snapshot.isAttached,
      'livePlatformViews': snapshot.livePlatformViews,
      'url': snapshot.url,
      'eventsSeenByNewState': _seen.length,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF16182C),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 140,
              child: WebViewMoFlutterView(
                backgroundColor: const Color(0xFF16182C),
                onPlatformViewCreated: (int _) => _reportAndPop(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'rebuilt chart host',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
