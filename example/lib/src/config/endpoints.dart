/// Endpoints and fixed inputs for the benchmark harness.
library;

/// Access-token API base.
const String kTokenBase =
    'https://tradingapi.motilaloswaluat.com/tradingapiV2/api/Authorize/AccessToken';

/// The chart page under test.
const String kChartUrl =
    'https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html';

/// Chart data API base, for reference when reading resource timings.
const String kChartApiBase = 'https://tradingapi.motilaloswaluat.com/chart/api';

/// Default client code.
const String kDefaultClientCode = 'T06794';

/// Default user type.
const String kDefaultUserType = 'T';

/// Default application id header value.
const String kDefaultAppId = '3f5b73f9-a07f-4ab9-9678-09133a99282a';

/// The JavaScript channel the chart page posts through.
///
/// The page reads `window.ChartAppDelegate` and, when absent, logs
/// `'ChartAppDelegate not available, message skipped'` and drops the message. So the channel
/// must exist before the page's `DOMContentLoaded` runs.
const String kChartChannel = 'ChartAppDelegate';

/// Chart mode. Must stay constant for a whole session.
///
/// `LoadChart` latches the mode on first use and silently returns if a later call disagrees, so
/// mixing modes on a surviving page produces a timeout that looks nothing like its cause.
const String kChartMode = 'FullChart';

/// A selectable symbol for the benchmark.
class ScripPreset {
  /// Creates a preset.
  const ScripPreset(this.symbol, this.label, {this.expectFailure = false});

  /// Symbol string passed to the chart page.
  final String symbol;

  /// Human-readable label.
  final String label;

  /// Whether this symbol is expected to terminate in an error.
  final bool expectFailure;
}

/// The symbols under comparison.
///
/// Indices need the `IDX:` prefix — verified against `Chart/Symbols`, where `IDX:0:NIFTY 50`
/// returns 200 (`type: Index`) while a bare `0:NIFTY 50` returns 204. The malformed form is kept
/// as a negative control because it exercises the double-lookup failure path.
const List<ScripPreset> kScripPresets = <ScripPreset>[
  ScripPreset('0:22', 'ACC (0:22)'),
  ScripPreset('0:3045', 'SBIN (0:3045)'),
  ScripPreset('IDX:0:NIFTY 50', 'NIFTY 50 (IDX:0:NIFTY 50)'),
  ScripPreset(
    '0:NIFTY 50',
    'NIFTY 50 malformed - negative control',
    expectFailure: true,
  ),
];
