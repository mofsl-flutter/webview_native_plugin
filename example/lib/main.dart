import 'package:flutter/material.dart';
import 'package:ios_webview_plugin/chart_session.dart';
import 'package:ios_webview_plugin/ios_webview_plugin.dart';

import 'src/regression/autorun.dart';
import 'src/regression/scenario.dart';
import 'src/regression/scenario_catalog.dart';
import 'src/service/token_api.dart';
import 'src/service/webview_bridge.dart';
import 'src/ui/auth_screen.dart';
import 'src/ui/recovery_screen.dart';
import 'src/ui/regression_screen.dart';
import 'src/ui/session.dart';

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Start the single event subscription before anything can trigger a load, and keep progress
  // and console forwarding off so they cannot perturb a timed run. Turn them on from the log
  // screen only for diagnostic passes.
  WebViewBridge.instance.start();
  // Must start here, not on first attach: a screen built after the page has loaded has to be
  // able to read the real page state, which means the session cannot have missed the load.
  ChartSession.instance.start();
  IosWebViewPlugin.setProgressForwarding(enabled: false);
  IosWebViewPlugin.setConsoleForwarding(enabled: false);

  final BenchmarkSession session = BenchmarkSession();

  // A relaunch delivered to an already-running instance (see MainActivity.onNewIntent) never
  // goes through LaunchArgs.read()'s one-shot startup check, so a resume-driven scenario
  // request — e.g. the orchestration script backgrounding the app then "reopening" it — has to
  // be picked up here instead, wherever the app currently is.
  listenForNewLaunch((LaunchArgs args) {
    if (args.hasRecoveryWork) {
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(builder: (_) => RecoveryScreen(autorun: args.recovery)),
      );
      return;
    }
    if (!args.hasWork) return;
    final List<Scenario> selected = selectScenarios(args, buildCatalog());
    if (selected.isEmpty) return;
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => RegressionScreen(session: session, autorunScenarios: selected),
      ),
    );
  });

  runApp(BenchmarkApp(session: session));
}

/// Fetches a token with the default credentials, then runs the requested cases.
///
/// Used only on an intent-driven launch: an unattended run cannot stop to have a token typed in.
class _AutorunBootstrap extends StatefulWidget {
  const _AutorunBootstrap({required this.session, required this.scenarios});

  final BenchmarkSession session;
  final List<Scenario> scenarios;

  @override
  State<_AutorunBootstrap> createState() => _AutorunBootstrapState();
}

class _AutorunBootstrapState extends State<_AutorunBootstrap> {
  String _status = 'requesting token…';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final TokenResult r = await TokenApi().fetch(
      clientCode: widget.session.clientCode,
      userType: widget.session.userType,
      appId: widget.session.appId,
      // Nobody is watching an unattended run, and the same launch may be on a throttled network
      // (the cache-lifetime cases are). A tight limit here ends the run before any case starts.
      connectionTimeout: const Duration(seconds: 120),
    );
    if (!mounted) return;
    widget.session.applyTokenResult(r);
    if (!r.ok) {
      final String why = 'token failed: ${r.error ?? r.statusCode}';
      setState(() => _status = why);
      // One line per case, so the host script reports ERROR with the reason rather than a bare
      // "0/N passed" and an empty results file.
      for (final Scenario s in widget.scenarios) {
        emitBootError(s.id, why);
      }
      emitDone(widget.scenarios.length, 0);
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => RegressionScreen(
          session: widget.session,
          autorunScenarios: widget.scenarios,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: Text(_status)),
      );
}

/// Chart load-time benchmark harness.
class BenchmarkApp extends StatelessWidget {
  /// Creates the app.
  const BenchmarkApp({required this.session, super.key});

  /// Shared session state.
  final BenchmarkSession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Chart load benchmark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF16182C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: FutureBuilder<LaunchArgs>(
        future: LaunchArgs.read(),
        builder: (BuildContext context, AsyncSnapshot<LaunchArgs> snap) {
          if (!snap.hasData) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final LaunchArgs args = snap.data!;
          if (args.hasRecoveryWork) return RecoveryScreen(autorun: args.recovery);
          if (args.hasWork) {
            final List<Scenario> selected = selectScenarios(args, buildCatalog());
            if (selected.isNotEmpty) {
              return _AutorunBootstrap(session: session, scenarios: selected);
            }
          }
          return AuthScreen(session: session);
        },
      ),
    );
  }
}
