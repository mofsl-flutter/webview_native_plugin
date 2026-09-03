import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/bench_models.dart';
import '../model/stats.dart';
import 'session.dart';

/// Metric columns, in the order they are reported.
const List<String> kMetricOrder = <String>[
  'channelDispatch',
  'navigation',
  'documentLoad',
  'jsBoot',
  'gateWait',
  'authorizeRtt',
  'chartRender',
  'endToEnd',
];

/// Shows outcomes first, then per-phase aggregates.
class ResultsScreen extends StatelessWidget {
  /// Creates the results screen.
  const ResultsScreen({required this.session, super.key});

  /// Shared session state.
  final BenchmarkSession session;

  @override
  Widget build(BuildContext context) {
    final List<RunRecord> all = session.results;
    final Map<String, List<RunRecord>> bySymbol = <String, List<RunRecord>>{};
    for (final RunRecord r in all) {
      bySymbol.putIfAbsent(r.config.symbol, () => <RunRecord>[]).add(r);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('4 · Results'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy CSV',
            onPressed: () => _copyCsv(context, all),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear results',
            onPressed: session.clearResults,
          ),
        ],
      ),
      body: all.isEmpty
          ? const Center(child: Text('No runs recorded yet'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                for (final MapEntry<String, List<RunRecord>> e in bySymbol.entries)
                  _SymbolSection(symbol: e.key, records: e.value),
                const SizedBox(height: 16),
                Text('All runs', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _RunTable(records: all),
              ],
            ),
    );
  }

  void _copyCsv(BuildContext context, List<RunRecord> records) {
    final String csv = buildCsv(records);
    Clipboard.setData(ClipboardData(text: csv));
    // dart:developer log, not debugPrint: debugPrint throttles to roughly 1 KB/s and silently
    // drops and reorders, which would truncate the export.
    for (final String line in csv.split('\n')) {
      developer.log(line, name: 'HBCSV');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${records.length} rows (also logged as HBCSV)')),
    );
  }
}

/// Renders CSV for [records].
String buildCsv(List<RunRecord> records) {
  final List<String> header = <String>[
    'run_id',
    'wall_clock_iso',
    'symbol',
    'arm',
    'outcome',
    'timed_out_phase',
    ...kMetricOrder.map((String m) => '${m}_us'),
    'page_ready_version',
    'page_ready_reset_cache',
    'chart_source',
    'chart_symbol_echo',
    'res_count',
    'res_bytes_transfer',
    'res_bytes_decoded',
    'tail_events',
    'stray_events',
    'failure_detail',
  ];
  final StringBuffer sb = StringBuffer(header.join(','));
  for (final RunRecord r in records) {
    final Map<String, int?> m = r.metrics;
    final List<String> row = <String>[
      r.runId,
      r.startedAt.toIso8601String(),
      r.config.symbol,
      r.config.armKey,
      r.outcome.name,
      r.timedOutPhase?.name ?? '',
      ...kMetricOrder.map((String k) => m[k]?.toString() ?? ''),
      r.pageReadyVersion ?? '',
      r.pageReadyResetCache?.toString() ?? '',
      r.chartSource ?? '',
      r.chartSymbolEcho ?? '',
      r.navTiming?['count']?.toString() ?? '',
      r.navTiming?['bytesTransfer']?.toString() ?? '',
      r.navTiming?['bytesDecoded']?.toString() ?? '',
      r.tailEvents.toString(),
      r.strayEvents.toString(),
      r.failureDetail ?? '',
    ];
    sb.write('\n${row.map(_csvEscape).join(',')}');
  }
  return sb.toString();
}

String _csvEscape(String v) =>
    v.contains(',') || v.contains('"') ? '"${v.replaceAll('"', '""')}"' : v;

class _SymbolSection extends StatelessWidget {
  const _SymbolSection({required this.symbol, required this.records});

  final String symbol;
  final List<RunRecord> records;

  @override
  Widget build(BuildContext context) {
    final Map<TerminalOutcome, int> counts = <TerminalOutcome, int>{};
    for (final RunRecord r in records) {
      counts[r.outcome] = (counts[r.outcome] ?? 0) + 1;
    }
    // Aggregate only within one outcome class: pooling a fast failure with a slow success would
    // make the failure look like the best result.
    final List<RunRecord> successes =
        records.where((RunRecord r) => r.outcome.isSuccess).toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(symbol, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: counts.entries.map((MapEntry<TerminalOutcome, int> e) {
                final bool good = e.key.isSuccess;
                return Chip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: good
                      ? Colors.green.withValues(alpha: 0.18)
                      : Colors.red.withValues(alpha: 0.18),
                  label: Text(
                    '${e.value} × ${e.key.label}',
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              }).toList(),
            ),
            if (successes.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No successful runs — timings below are omitted rather than averaged with '
                  'failures. Terminal reason: '
                  '${records.map((RunRecord r) => r.failureDetail ?? r.outcome.label).toSet().join(", ")}',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              )
            else ...<Widget>[
              const Divider(height: 20),
              Text(
                'Successful runs only (n=${successes.length})',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              ...kMetricOrder.map((String key) {
                final Aggregate? agg = Aggregate.of(
                  successes.map((RunRecord r) => r.metrics[key]),
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 128,
                        child: Text(key, style: const TextStyle(fontSize: 12)),
                      ),
                      Expanded(
                        child: Text(
                          formatAggregate(agg),
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            if (records.any((RunRecord r) => r.navTiming != null)) ...<Widget>[
              const Divider(height: 20),
              _NavTimingPanel(
                navTiming: records
                    .lastWhere((RunRecord r) => r.navTiming != null)
                    .navTiming!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavTimingPanel extends StatelessWidget {
  const _NavTimingPanel({required this.navTiming});

  final Map<String, Object?> navTiming;

  @override
  Widget build(BuildContext context) {
    final Object? top = navTiming['top'];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        'Resource evidence · ${navTiming['count']} requests · '
        'transferred ${formatBytes(navTiming['bytesTransfer'])} of '
        '${formatBytes(navTiming['bytesDecoded'])} decoded',
        style: const TextStyle(fontSize: 12),
      ),
      children: <Widget>[
        const Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'transfer 0 = served from cache · small transfer against large decoded = '
              'conditional revalidation · transfer ≈ encoded = full download',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ),
        if (top is List)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 14,
              headingRowHeight: 28,
              dataRowMinHeight: 24,
              dataRowMaxHeight: 30,
              columns: const <DataColumn>[
                DataColumn(label: Text('asset', style: TextStyle(fontSize: 11))),
                DataColumn(label: Text('ms', style: TextStyle(fontSize: 11))),
                DataColumn(label: Text('transfer', style: TextStyle(fontSize: 11))),
                DataColumn(label: Text('decoded', style: TextStyle(fontSize: 11))),
                DataColumn(label: Text('status', style: TextStyle(fontSize: 11))),
              ],
              rows: top.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> e) {
                return DataRow(
                  cells: <DataCell>[
                    DataCell(Text('${e['n']}', style: const TextStyle(fontSize: 11))),
                    DataCell(Text('${e['d']}', style: const TextStyle(fontSize: 11))),
                    DataCell(Text(formatBytes(e['transfer']),
                        style: const TextStyle(fontSize: 11))),
                    DataCell(Text(formatBytes(e['decoded']),
                        style: const TextStyle(fontSize: 11))),
                    DataCell(Text('${e['status'] ?? '--'}',
                        style: const TextStyle(fontSize: 11))),
                  ],
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

class _RunTable extends StatelessWidget {
  const _RunTable({required this.records});

  final List<RunRecord> records;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 16,
        headingRowHeight: 32,
        dataRowMinHeight: 28,
        dataRowMaxHeight: 34,
        columns: <DataColumn>[
          const DataColumn(label: Text('run', style: TextStyle(fontSize: 11))),
          const DataColumn(label: Text('symbol', style: TextStyle(fontSize: 11))),
          const DataColumn(label: Text('outcome', style: TextStyle(fontSize: 11))),
          ...kMetricOrder.map(
            (String m) => DataColumn(label: Text(m, style: const TextStyle(fontSize: 11))),
          ),
          const DataColumn(label: Text('stray', style: TextStyle(fontSize: 11))),
          const DataColumn(label: Text('tail', style: TextStyle(fontSize: 11))),
        ],
        rows: records.map((RunRecord r) {
          final Map<String, int?> m = r.metrics;
          return DataRow(
            cells: <DataCell>[
              DataCell(Text(
                r.runId.split('-').last,
                style: const TextStyle(fontSize: 11),
              )),
              DataCell(Text(r.config.symbol, style: const TextStyle(fontSize: 11))),
              DataCell(
                Text(
                  r.outcome.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: r.outcome.isSuccess ? Colors.green : Colors.red,
                  ),
                ),
              ),
              ...kMetricOrder.map(
                (String k) => DataCell(
                  Text(
                    formatMicros(m[k]),
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
              ),
              DataCell(Text('${r.strayEvents}', style: const TextStyle(fontSize: 11))),
              DataCell(Text('${r.tailEvents}', style: const TextStyle(fontSize: 11))),
            ],
          );
        }).toList(),
      ),
    );
  }
}
