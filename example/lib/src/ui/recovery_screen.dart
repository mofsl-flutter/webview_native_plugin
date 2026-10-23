import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:ios_webview_plugin/webview_mo_flutter_view.dart';

import '../regression/event_tape.dart';
import '../regression/expectation.dart';
import '../regression/recovery_case.dart';
import '../regression/recovery_catalog.dart';
import '../regression/recovery_runner.dart';
import '../service/headless_engines.dart';
import 'log_screen.dart';

/// Runs the recovery cases against the plugin.
///
/// Needs no token and no network: the page under test is served from a `data:` URL. Two platform
/// views can be mounted at once, because a kept-alive mini chart under a full chart is one of the
/// situations the cases cover.
class RecoveryScreen extends StatefulWidget {
  /// Creates the screen. [autorun] ids, or `all`, start immediately and log verdicts for a host
  /// script to collect.
  const RecoveryScreen({this.autorun, super.key});

  /// Case ids to run on launch, comma separated, or `all`.
  final String? autorun;

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> implements RecoveryHost {
  final List<RecoveryCase> _catalog = buildRecoveryCatalog();
  late final RecoveryRunner _runner;

  int? _primaryId;
  int? _secondaryId;
  Completer<int> _primaryCreated = Completer<int>();
  Completer<int> _secondaryCreated = Completer<int>();
  bool _primaryWanted = true;
  bool _secondaryWanted = false;

  // Bumped on every mount so a remount builds a new platform view even if the widget is otherwise
  // identical; a view reused across a dispose would not exercise the dispose at all.
  int _primaryGen = 0;
  int _secondaryGen = 0;

  @override
  int? get primaryId => _primaryId;

  @override
  int? get secondaryId => _secondaryId;

  @override
  void initState() {
    super.initState();
    _runner = RecoveryRunner(
      isAndroid: Platform.isAndroid,
      context: RecoveryContext(tape: EventTape(), host: this, engines: HeadlessEngines()),
    );
    final String? auto = widget.autorun;
    if (auto != null && auto.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_autorun(auto)));
    }
  }

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _autorun(String spec) async {
    final Set<String> ids = spec.split(',').map((String s) => s.trim()).toSet();
    final List<RecoveryCase> cases = spec == 'all'
        ? _catalog
        : _catalog.where((RecoveryCase c) => ids.contains(c.id)).toList();
    int passed = 0;
    int skipped = 0;
    await _runner.runAll(
      cases,
      onResult: (RecoveryResult r) {
        if (r.pass) passed++;
        if (r.skipped) skipped++;
        emitRecoveryResult(r);
      },
    );
    emitRecoveryDone(cases.length, passed, skipped);
  }

  // ------------------------------------------------------------- RecoveryHost

  @override
  Future<int> mountPrimary() async {
    _primaryCreated = Completer<int>();
    setState(() {
      _primaryWanted = true;
      _primaryGen++;
    });
    final int id = await _primaryCreated.future.timeout(const Duration(seconds: 6));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return id;
  }

  @override
  Future<void> unmountPrimary() async {
    setState(() {
      _primaryWanted = false;
      _primaryId = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Future<int> mountSecondary() async {
    _secondaryCreated = Completer<int>();
    setState(() {
      _secondaryWanted = true;
      _secondaryGen++;
    });
    final int id = await _secondaryCreated.future.timeout(const Duration(seconds: 6));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return id;
  }

  @override
  Future<void> unmountSecondary() async {
    setState(() {
      _secondaryWanted = false;
      _secondaryId = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recovery'),
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
          SizedBox(
            height: 100,
            child: Row(
              children: <Widget>[
                Expanded(child: _slot('primary', _primaryWanted, _primaryGen, true)),
                const VerticalDivider(width: 1),
                Expanded(child: _slot('secondary', _secondaryWanted, _secondaryGen, false)),
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
                    onPressed: _runner.isRunning ? null : () => unawaited(_runner.runAll(_catalog)),
                  ),
                  const SizedBox(width: 12),
                  if (_runner.isRunning)
                    Expanded(
                      child: Text(
                        '${_runner.current?.id ?? ''} · ${_runner.current?.title ?? ''}',
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  else
                    Expanded(child: Text(_summary(), style: const TextStyle(fontSize: 12))),
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
                  final RecoveryCase c = _catalog[i];
                  return _CaseTile(
                    recoveryCase: c,
                    result: _runner.results[c.id],
                    running: _runner.current?.id == c.id,
                    onRun: _runner.isRunning ? null : () => unawaited(_runner.run(c)),
                    showGroup: i == 0 || _catalog[i - 1].group != c.group,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _summary() {
    if (_runner.results.isEmpty) return 'not run yet';
    final Iterable<RecoveryResult> all = _runner.results.values;
    final int pass = all.where((RecoveryResult r) => r.pass).length;
    final int skip = all.where((RecoveryResult r) => r.skipped).length;
    final int fail = all.length - pass - skip;
    return '$pass passed · $fail failed${skip == 0 ? '' : ' · $skip skipped'}';
  }

  Widget _slot(String label, bool wanted, int gen, bool primary) {
    if (!wanted) {
      return ColoredBox(
        color: const Color(0xFF16182C),
        child: Center(
          child: Text('$label: no view', style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ),
      );
    }
    return WebViewMoFlutterView(
      key: ValueKey<String>('$label-$gen'),
      backgroundColor: const Color(0xFF16182C),
      onPlatformViewCreated: (int id) {
        if (primary) {
          _primaryId = id;
          if (!_primaryCreated.isCompleted) _primaryCreated.complete(id);
        } else {
          _secondaryId = id;
          if (!_secondaryCreated.isCompleted) _secondaryCreated.complete(id);
        }
      },
    );
  }
}

class _CaseTile extends StatelessWidget {
  const _CaseTile({
    required this.recoveryCase,
    required this.result,
    required this.running,
    required this.onRun,
    required this.showGroup,
  });

  final RecoveryCase recoveryCase;
  final RecoveryResult? result;
  final bool running;
  final VoidCallback? onRun;
  final bool showGroup;

  @override
  Widget build(BuildContext context) {
    final RecoveryResult? r = result;
    final Widget leading = running
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(
            r == null
                ? Icons.radio_button_unchecked
                : (r.skipped ? Icons.remove_circle_outline : (r.pass ? Icons.check_circle : Icons.cancel)),
            color: r == null || r.skipped
                ? Colors.white24
                : (r.pass ? Colors.greenAccent : Colors.redAccent),
            size: 18,
          );

    final Widget tile = ExpansionTile(
      dense: true,
      leading: leading,
      title: Text('${recoveryCase.id}  ${recoveryCase.title}', style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        <String>[
          if (recoveryCase.androidOnly) 'Android only',
          if (recoveryCase.debugOnly) 'debug build',
          if (r?.skipped ?? false) 'skipped: ${r!.skipReason}',
        ].join(' · '),
        style: const TextStyle(fontSize: 10),
      ),
      trailing: IconButton(icon: const Icon(Icons.play_circle_outline, size: 20), onPressed: onRun),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (recoveryCase.pins != null) ...<Widget>[
                Text(
                  recoveryCase.pins!,
                  style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
                ),
                const SizedBox(height: 8),
              ],
              if (r == null)
                const Text('not run', style: TextStyle(fontSize: 11))
              else if (r.error != null)
                Text(r.error!, style: const TextStyle(fontSize: 11, color: Colors.redAccent))
              else
                ...r.checks.map(
                  (ExpectationResult e) => Text(
                    '${e.pass ? "✓" : "✗"} ${e.description}${e.actual == null ? '' : '  → ${e.actual}'}',
                    style: TextStyle(fontSize: 11, color: e.pass ? Colors.greenAccent : Colors.redAccent),
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    if (!showGroup) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Text(recoveryCase.group.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        ),
        tile,
      ],
    );
  }
}
