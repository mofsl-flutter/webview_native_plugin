import 'package:flutter/material.dart';

import '../config/endpoints.dart';
import '../model/bench_models.dart';
import 'chart_screen.dart';
import 'log_screen.dart';
import 'regression_screen.dart';
import 'results_screen.dart';
import 'session.dart';

/// Chooses symbols and experiment arms.
class ConfigScreen extends StatefulWidget {
  /// Creates the config screen.
  const ConfigScreen({required this.session, super.key});

  /// Shared session state.
  final BenchmarkSession session;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  @override
  Widget build(BuildContext context) {
    final BenchmarkSession s = widget.session;
    final RunConfig t = s.template;
    final int total = s.selectedSymbols.length * s.repeats;

    return Scaffold(
      appBar: AppBar(
        title: const Text('2 · Configuration'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Raw event log',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.fact_check),
            tooltip: 'Regression suite',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RegressionScreen(session: s),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.table_chart),
            tooltip: 'Results',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ResultsScreen(session: s)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Symbols', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: kScripPresets.map((ScripPreset p) {
              final bool selected = s.selectedSymbols.contains(p.symbol);
              return FilterChip(
                selected: selected,
                label: Text(p.label),
                avatar: p.expectFailure
                    ? const Icon(Icons.warning_amber, size: 16, color: Colors.orange)
                    : null,
                onSelected: (_) => setState(() => s.toggleSymbol(p.symbol)),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Indices need the IDX: prefix. A bare "0:NIFTY 50" returns HTTP 204 from '
            'Chart/Symbols and is kept only as a negative control — it terminates fast in '
            'SymbolNotFound, so never read it as a fast success.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(height: 28),
          Text('Arms', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            value: t.preWarm,
            title: const Text('Pre-warm WebView'),
            subtitle: const Text(
              'Create the WebView and boot the page before the view mounts',
            ),
            onChanged: (bool v) => setState(
              () => s.updateTemplate(_copy(t, preWarm: v)),
            ),
          ),
          SwitchListTile(
            value: t.changeSymbolOnWarmPage,
            title: const Text('Reuse page, change symbol only'),
            subtitle: const Text(
              'Skips navigation entirely. Isolates render cost from JS boot cost — this is '
              'the arm that tests whether the JS parse dominates',
            ),
            onChanged: (bool v) => setState(
              () => s.updateTemplate(_copy(t, changeSymbolOnWarmPage: v)),
            ),
          ),
          SwitchListTile(
            value: t.authorizeFirst,
            title: const Text('Authorize before loadChart'),
            subtitle: const Text(
              'Turn off to exercise the ordering defect: the page never settles its 401 '
              'promise, so the run should time out rather than error',
            ),
            onChanged: (bool v) => setState(
              () => s.updateTemplate(_copy(t, authorizeFirst: v)),
            ),
          ),
          SwitchListTile(
            value: t.cacheBustUrl,
            title: const Text('Per-run URL token'),
            subtitle: const Text(
              'Only changes the entry document\'s cache key; subresources keep theirs',
            ),
            onChanged: (bool v) => setState(
              () => s.updateTemplate(_copy(t, cacheBustUrl: v)),
            ),
          ),
          SwitchListTile(
            value: t.hybridComposition,
            title: const Text('Hybrid composition'),
            subtitle: const Text('Otherwise texture-layer with fallback, as production uses'),
            onChanged: (bool v) => setState(
              () => s.updateTemplate(_copy(t, hybridComposition: v)),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            title: const Text('Cache mode'),
            subtitle: Text(t.cacheMode),
            trailing: DropdownButton<String>(
              value: t.cacheMode,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'default', child: Text('default')),
                DropdownMenuItem<String>(
                  value: 'cacheElseNetwork',
                  child: Text('cacheElseNetwork'),
                ),
                DropdownMenuItem<String>(value: 'noCache', child: Text('noCache')),
              ],
              onChanged: (String? v) {
                if (v != null) setState(() => s.updateTemplate(_copy(t, cacheMode: v)));
              },
            ),
          ),
          ListTile(
            title: const Text('Reset before each run'),
            subtitle: Text(t.resetMode.label),
            trailing: DropdownButton<ResetMode>(
              value: t.resetMode,
              items: ResetMode.values
                  .map(
                    (ResetMode m) => DropdownMenuItem<ResetMode>(
                      value: m,
                      child: Text(m.label),
                    ),
                  )
                  .toList(),
              onChanged: (ResetMode? v) {
                if (v != null) setState(() => s.updateTemplate(_copy(t, resetMode: v)));
              },
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'A truly cold run cannot be produced in-app: resetCache clears only the HTTP '
            'cache. For that, run `adb shell pm clear '
            'com.example.ios_webview_plugin_example` and relaunch.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(height: 28),
          Text('Repeats: ${s.repeats}', style: Theme.of(context).textTheme.titleMedium),
          Slider(
            value: s.repeats.toDouble(),
            min: 1,
            max: 20,
            divisions: 19,
            label: '${s.repeats}',
            onChanged: (double v) => setState(() => s.setRepeats(v.round())),
          ),
          Text(
            '$total runs total (${s.selectedSymbols.length} symbols × ${s.repeats})',
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text('Start batch ($total runs)'),
            onPressed: !s.tokenHasHeadroom
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChartScreen(session: s),
                      ),
                    ),
          ),
          if (!s.tokenHasHeadroom)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Token has under 10 minutes left — regenerate it first.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  RunConfig _copy(
    RunConfig t, {
    bool? preWarm,
    String? cacheMode,
    ResetMode? resetMode,
    bool? authorizeFirst,
    bool? changeSymbolOnWarmPage,
    bool? cacheBustUrl,
    bool? hybridComposition,
  }) =>
      RunConfig(
        symbol: t.symbol,
        preWarm: preWarm ?? t.preWarm,
        cacheMode: cacheMode ?? t.cacheMode,
        resetMode: resetMode ?? t.resetMode,
        authorizeFirst: authorizeFirst ?? t.authorizeFirst,
        changeSymbolOnWarmPage: changeSymbolOnWarmPage ?? t.changeSymbolOnWarmPage,
        cacheBustUrl: cacheBustUrl ?? t.cacheBustUrl,
        hybridComposition: hybridComposition ?? t.hybridComposition,
      );
}
