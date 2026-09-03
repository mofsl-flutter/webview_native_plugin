import 'dart:async';

import 'package:flutter/material.dart';

import '../service/token_api.dart';
import 'config_screen.dart';
import 'session.dart';

/// Generates an access token from a client code.
class AuthScreen extends StatefulWidget {
  /// Creates the auth screen.
  const AuthScreen({required this.session, super.key});

  /// Shared session state.
  final BenchmarkSession session;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final TextEditingController _clientCode =
      TextEditingController(text: widget.session.clientCode);
  late final TextEditingController _userType =
      TextEditingController(text: widget.session.userType);
  late final TextEditingController _appId =
      TextEditingController(text: widget.session.appId);

  final TokenApi _api = TokenApi();
  bool _loading = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Drives the expiry countdown.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.session.claims != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _clientCode.dispose();
    _userType.dispose();
    _appId.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _loading = true);
    widget.session
      ..clientCode = _clientCode.text.trim()
      ..userType = _userType.text.trim()
      ..appId = _appId.text.trim();
    final TokenResult result = await _api.fetch(
      clientCode: widget.session.clientCode,
      userType: widget.session.userType,
      appId: widget.session.appId,
    );
    if (!mounted) return;
    widget.session.applyTokenResult(result);
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final BenchmarkSession s = widget.session;
    final TokenResult? r = s.tokenResult;
    final JwtClaims? c = s.claims;

    return Scaffold(
      appBar: AppBar(title: const Text('1 · Access token')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _clientCode,
            decoration: const InputDecoration(
              labelText: 'Client code',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userType,
            decoration: const InputDecoration(
              labelText: 'User type',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appId,
            decoration: const InputDecoration(
              labelText: 'AppId header',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading ? null : _generate,
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.vpn_key),
            label: const Text('Generate access token'),
          ),
          if (r != null) ...<Widget>[
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          r.ok ? Icons.check_circle : Icons.error,
                          color: r.ok ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          r.ok ? 'HTTP ${r.statusCode}' : (r.error ?? 'Failed'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _kv('Connect', '${((r.connectMicros ?? 0) / 1000).toStringAsFixed(1)} ms'),
                    _kv('Total', '${(r.totalMicros / 1000).toStringAsFixed(1)} ms'),
                    if (r.token != null) ...<Widget>[
                      _kv('Token length', '${r.token!.length} chars'),
                      _kv('Token', _truncate(r.token!)),
                    ],
                    if (c != null) ...<Widget>[
                      const Divider(height: 20),
                      _kv('unique_name', c.uniqueName ?? '--'),
                      _kv('role', c.role ?? '--'),
                      _kv('appid', c.appId ?? '--'),
                      _kv('iat', c.issuedAt?.toIso8601String() ?? '--'),
                      _kv('nbf', c.notBefore?.toIso8601String() ?? '--'),
                      _kv('exp', c.expiresAt?.toIso8601String() ?? '--'),
                      _kv('Remaining', _formatRemaining(c.remaining)),
                      if (!s.tokenHasHeadroom)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Under 10 minutes left. A batch that outlives the token produces '
                            'hangs that look exactly like the wrong-order arm — regenerate '
                            'before running.',
                            style: TextStyle(color: Colors.orange),
                          ),
                        ),
                    ] else if (r.token != null)
                      const Text('JWT payload undecodable'),
                    const Divider(height: 20),
                    Text('Raw response', style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          r.rawBody.isEmpty ? '(empty)' : r.rawBody,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: s.hasToken
                ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ConfigScreen(session: s),
                      ),
                    )
                : null,
            child: const Text('Continue to configuration'),
          ),
        ],
      ),
    );
  }

  static String _truncate(String token) => token.length <= 40
      ? token
      : '${token.substring(0, 24)}…${token.substring(token.length - 12)}';

  static String _formatRemaining(Duration? d) {
    if (d == null) return '--';
    if (d.isNegative) return 'expired';
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '${m}m ${s}s';
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 110,
              child: Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            Expanded(
              child: Text(
                v,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      );
}
