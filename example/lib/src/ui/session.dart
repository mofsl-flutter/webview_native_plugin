import 'package:flutter/foundation.dart';

import '../config/endpoints.dart';
import '../model/bench_models.dart';
import '../service/token_api.dart';

/// Long-lived state shared across screens.
///
/// Notifies only on coarse events — token acquired, batch finished — so the chart screen's
/// platform view is never rebuilt by a high-frequency update.
class BenchmarkSession extends ChangeNotifier {
  /// Client code to authenticate with.
  String clientCode = kDefaultClientCode;

  /// User type.
  String userType = kDefaultUserType;

  /// Application id header.
  String appId = kDefaultAppId;

  /// Most recent token request.
  TokenResult? tokenResult;

  /// Claims decoded from the current token.
  JwtClaims? claims;

  /// Selected symbols.
  final Set<String> selectedSymbols = <String>{kScripPresets.first.symbol};

  /// Repeats per configuration.
  int repeats = 5;

  /// Arm configuration applied to every selected symbol.
  RunConfig template = const RunConfig(symbol: '');

  /// Results accumulated across batches.
  final List<RunRecord> results = <RunRecord>[];

  /// Whether a usable token is held.
  bool get hasToken => tokenResult?.ok == true && tokenResult?.token != null;

  /// The current token, or null.
  String? get token => tokenResult?.token;

  /// Whether the token has enough life left for a batch.
  ///
  /// A batch that straddles expiry produces a hang indistinguishable from the deliberate
  /// wrong-order arm, so this is checked before starting.
  bool get tokenHasHeadroom {
    final Duration? left = claims?.remaining;
    if (left == null) return hasToken;
    return left > const Duration(minutes: 10);
  }

  /// Records a token request outcome.
  void applyTokenResult(TokenResult result) {
    tokenResult = result;
    claims = result.token == null ? null : JwtClaims.decode(result.token!);
    notifyListeners();
  }

  /// Replaces the arm template.
  void updateTemplate(RunConfig next) {
    template = next;
    notifyListeners();
  }

  /// Toggles a symbol selection.
  void toggleSymbol(String symbol) {
    if (selectedSymbols.contains(symbol)) {
      if (selectedSymbols.length > 1) selectedSymbols.remove(symbol);
    } else {
      selectedSymbols.add(symbol);
    }
    notifyListeners();
  }

  /// Sets the repeat count.
  void setRepeats(int value) {
    repeats = value;
    notifyListeners();
  }

  /// Appends a batch's records.
  void addResults(List<RunRecord> records) {
    results.addAll(records);
    notifyListeners();
  }

  /// Clears accumulated results.
  void clearResults() {
    results.clear();
    notifyListeners();
  }

  /// Builds the run list for the current selection.
  List<RunConfig> buildConfigs() => selectedSymbols
      .map((String s) => template.withSymbol(s))
      .toList(growable: false);
}
