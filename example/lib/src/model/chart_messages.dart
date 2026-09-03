/// Message shapes the chart page posts through its native channel.
///
/// These mirror the host app's `charts_impl/data/channel_response.dart` so the harness parses
/// exactly what production parses.
library;

/// Page theme, as the chart page names it.
enum WebPageTheme {
  /// Dark theme.
  dark,

  /// Light theme.
  light;

  /// Resolves a theme from its wire name, defaulting to [WebPageTheme.light].
  static WebPageTheme fromName(String name) {
    for (final WebPageTheme t in WebPageTheme.values) {
      if (t.name == name.toLowerCase()) return t;
    }
    return WebPageTheme.light;
  }
}

/// Progression the chart reports, mirroring production's `ChartState`.
enum ChartState {
  /// Nothing started.
  initial(-1),

  /// Document navigation in flight.
  pageLoading(0),

  /// Page JavaScript booted and its globals assigned.
  pageLoaded(1),

  /// Chart requested, waiting on render.
  chartLoading(2),

  /// Chart reported a failure.
  chartError(3),

  /// Chart rendered.
  chartLoaded(4);

  const ChartState(this.value);

  /// Ordering value.
  final int value;
}

/// Success payload of a [ChannelResponse].
class SuccessData {
  /// Creates a success payload.
  ///
  /// Positional to mirror the host app's `SuccessData` exactly.
  // ignore: avoid_positional_boolean_parameters
  const SuccessData(this.source, this.symbol, this.theme, this.resetCache);

  /// For `PageReady` this is the page version; for `Chart` it is the trigger
  /// (`initialLoad`, `changeSymbol`, `resolveSymbol`).
  final String source;

  /// Symbol the chart rendered, when reported.
  final String? symbol;

  /// Theme the chart used.
  final WebPageTheme theme;

  /// Whether the page purged its own storage because its version changed.
  ///
  /// Self-verifying: after deliberately clearing storage this must come back true, otherwise the
  /// purge did not happen and a "cold" run is mislabelled.
  final bool resetCache;

  /// Parses a success payload.
  factory SuccessData.fromJson(Map<String, Object?> json) => SuccessData(
        json['source']?.toString() ?? '',
        json['symbol']?.toString(),
        WebPageTheme.fromName(json['theme']?.toString() ?? 'light'),
        json['resetCache'] as bool? ?? false,
      );
}

/// Error payload of a [ChannelResponse].
class ErrorData {
  /// Creates an error payload.
  const ErrorData(this.source, this.reason, this.symbol);

  /// Where the error came from.
  final String source;

  /// Why it failed, e.g. `SymbolNotFound` or `DataNotAvailable`.
  final String reason;

  /// Symbol involved.
  final String? symbol;

  /// Parses an error payload.
  factory ErrorData.fromJson(Map<String, Object?> json) => ErrorData(
        json['source']?.toString() ?? '',
        json['reason']?.toString() ?? '',
        json['symbol']?.toString(),
      );
}

/// A `{context, success|error}` message from the chart page.
class ChannelResponse {
  /// Creates a response.
  const ChannelResponse(this.context, this.success, this.error);

  /// `PageReady`, `Chart`, `Api`, `refreshToken`, ...
  final String context;

  /// Success payload, when present.
  final SuccessData? success;

  /// Error payload, when present.
  final ErrorData? error;

  /// Parses a response, or returns null when the shape does not match.
  static ChannelResponse? tryParse(Map<String, Object?> json) {
    final Object? context = json['context'];
    if (context == null) return null;
    final Object? success = json['success'];
    final Object? error = json['error'];
    return ChannelResponse(
      context.toString(),
      success is Map
          ? SuccessData.fromJson(Map<String, Object?>.from(success))
          : null,
      error is Map ? ErrorData.fromJson(Map<String, Object?>.from(error)) : null,
    );
  }
}

/// A message the harness itself injected, carrying a run id.
///
/// The page's own messages cannot be tagged, so anything the harness controls reports through
/// `window.__hb` instead and is correlated exactly.
class HarnessMessage {
  /// Creates a harness message.
  const HarnessMessage(this.runId, this.phase, this.detail, this.perfMs);

  /// Run this message belongs to.
  final String runId;

  /// Phase name, e.g. `authorizeResolved`.
  final String phase;

  /// Optional detail payload.
  final Object? detail;

  /// In-page `performance.now()` reading, for cross-checking against Dart timestamps.
  final int perfMs;

  /// Parses a harness message, or returns null when the shape does not match.
  static HarnessMessage? tryParse(Map<String, Object?> json) {
    if (json['context'] != 'Harness') return null;
    return HarnessMessage(
      json['runId']?.toString() ?? '',
      json['phase']?.toString() ?? '',
      json['detail'],
      (json['perf'] as num?)?.toInt() ?? 0,
    );
  }
}
