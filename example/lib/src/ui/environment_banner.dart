import 'package:flutter/material.dart';

/// A strip that says which environment, and which account, this run is about to touch.
///
/// Production is the default, so it is deliberately hard to miss: nobody should find out from a
/// side effect on a real account that they were not on UAT.
class EnvironmentBanner extends StatelessWidget {
  /// Creates the banner.
  const EnvironmentBanner({
    required this.production,
    required this.clientCode,
    this.hiddenCases = 0,
    super.key,
  });

  /// Whether the app is pointed at production.
  final bool production;

  /// The client the token is for.
  final String clientCode;

  /// How many regression cases are hidden because they would change the account.
  final int hiddenCases;

  @override
  Widget build(BuildContext context) {
    final Color background = production ? const Color(0xFF7A1F1F) : const Color(0xFF1F4D7A);
    final String hidden = hiddenCases > 0
        ? ' · $hiddenCases cases hidden: they change account state '
            '(CHART_ENV=uat shows them, ALLOW_PROD_WRITES=true runs them here)'
        : '';
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        '${production ? 'PRODUCTION' : 'UAT'} · client $clientCode$hidden',
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
