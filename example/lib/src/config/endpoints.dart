/// Endpoints and fixed inputs for the benchmark harness.
library;

import 'package:ios_webview_plugin/chart_bundle.dart';

import 'environment.dart';

/// Access-token API base.
///
/// The one token service, for both environments: a token it issues is accepted by UAT and by
/// production, so the environment is chosen by [kChartUrl] / [kChartRoot], not here.
const String kTokenBase =
    'https://tradingapi.motilaloswaluat.com/tradingapiV2/api/Authorize/AccessToken';

/// The chart page under test: production's hosted page by default, UAT's with `CHART_ENV=uat`.
///
/// Used when the harness loads the hosted page; with `--dart-define=CHART_LOCAL=true` the bundled
/// page is loaded instead and only [kChartRoot] decides which API it calls.
const String kChartUrl = kChartProd
    ? 'https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/v4/RiseApp_Mobile.html'
    : 'https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html';

/// Chart data API base, for reference when reading resource timings.
const String kChartApiBase = '${kChartRoot}api';

/// The server's chart root: the URL `api/...` is relative to, and what a bundled page is told as
/// `apiBase` (see `ChartBundle.localUrl`).
///
/// Production's by default, UAT's with `CHART_ENV=uat`, and `--dart-define=CHART_API_ROOT=<url>`
/// overrides either (it ends in `/`, e.g. `https://<host>/charts/`). The cache-warm cases and their
/// URL fixture belong to UAT and only run with `CHART_ENV=uat`.
const String kChartRoot = String.fromEnvironment(
  'CHART_API_ROOT',
  defaultValue: kChartProd
      ? 'https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/'
      : 'https://tradingapi.motilaloswaluat.com/chart/',
);

/// The symbol case `O1` opens (`--dart-define=CHART_SYMBOL=<symbol>`), in the form `loadChart` takes
/// (e.g. `0:22`, `IDX:1:SENSEX`). Defaults to the symbol the other bundled-chart cases use.
///
/// Opening a chart records it as the account's last-viewed symbol, so this is also how to put an
/// account back to the chart it was on.
const String kChartSymbol = String.fromEnvironment('CHART_SYMBOL', defaultValue: '0:3045');

/// A token to authorise the page with instead of asking UAT's token service for one
/// (`--dart-define=CHART_TOKEN=<token>`); empty means "ask UAT".
///
/// A UAT token is no use against another environment's API, and this harness cannot know that
/// environment's token service. The value is only ever handed to the page; it is not logged.
const String kChartToken = String.fromEnvironment('CHART_TOKEN');

/// Whether the harness loads the chart from the bundle inside the plugin instead of the hosted
/// page. Off by default so existing runs stay comparable; turn on with
/// `flutter run --dart-define=CHART_LOCAL=true`.
const bool kChartLocal = bool.fromEnvironment('CHART_LOCAL');

/// The URL the chart page is loaded from: the hosted page, or the bundled one when [kChartLocal].
///
/// With nothing else asked for and [kChartLocal] off this is exactly [kChartUrl], so the hosted
/// runs keep the URLs (and so the cache keys) they always had. [theme] and [runId] (`hbRun`, the
/// harness's cache-bust and stray-event marker) are added as query parameters in that order.
String chartPageUrl({String? theme, String? runId}) {
  final Map<String, String> extra = <String, String>{
    'theme': ?theme,
    'hbRun': ?runId,
  };
  if (!kChartLocal) {
    return extra.isEmpty
        ? kChartUrl
        : Uri.parse(kChartUrl).replace(queryParameters: extra).toString();
  }
  final Uri local = ChartBundle.localUrl(apiBase: Uri.parse(kChartRoot), theme: theme);
  return local
      .replace(
        queryParameters: <String, String>{
          ...local.queryParameters,
          'hbRun': ?runId,
        },
      )
      .toString();
}

/// Default client code: the one the token is minted for, so the account the run acts as.
///
/// Production's is `T029342` (the example app's production test client) and UAT's `T06794`. Override
/// with `--dart-define=CHART_CLIENT_CODE=<code>`; it is also editable on the token screen. A client
/// code that belongs to a real person means every run writes to that person's account.
const String kDefaultClientCode = String.fromEnvironment(
  'CHART_CLIENT_CODE',
  defaultValue: kChartProd ? 'T029342' : 'T06794',
);

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
