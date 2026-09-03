import 'dart:convert';

import 'package:flutter/material.dart';

import '../service/webview_bridge.dart';

/// Raw event log, newest first.
///
/// Indispensable when a run hangs: it is the only place that shows what actually arrived, in
/// what order, and how each event was treated.
class LogScreen extends StatefulWidget {
  /// Creates the log screen.
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  EventDisposition? _filter;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Raw event log'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () => setState(WebViewBridge.instance.clearLog),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  FilterChip(
                    label: const Text('all'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  const SizedBox(width: 6),
                  ...EventDisposition.values.map(
                    (EventDisposition d) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(d.name),
                        selected: _filter == d,
                        onSelected: (_) => setState(() => _filter = d),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: WebViewBridge.instance.logLength,
              builder: (BuildContext context, int _, Widget? child) {
                final List<LoggedEvent> items = WebViewBridge.instance.log
                    .where((LoggedEvent e) => _filter == null || e.disposition == _filter)
                    .toList()
                    .reversed
                    .toList();
                if (items.isEmpty) {
                  return const Center(child: Text('No events'));
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int i) {
                    final LoggedEvent e = items[i];
                    return ExpansionTile(
                      dense: true,
                      title: Text(
                        '#${e.seq}  ${e.label}',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        '${(e.atMicros / 1000).toStringAsFixed(0)} ms · '
                        '${e.disposition.name} · ${e.runtimeTypeName}'
                        '${e.runIdAtArrival == null ? "" : " · ${e.runIdAtArrival}"}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: SelectableText(
                            _pretty(e.event.raw),
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _pretty(Object? raw) {
    try {
      if (raw is Map) {
        return const JsonEncoder.withIndent('  ').convert(
          raw.map((Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v)),
        );
      }
      return raw.toString();
    } on Object {
      return raw.toString();
    }
  }
}
