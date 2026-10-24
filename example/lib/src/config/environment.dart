/// Which environment the example app talks to, and which regression cases it will run there.
///
/// Production is the default. `--dart-define=CHART_ENV=uat` selects UAT, which is what the whole
/// regression suite was written against. Which cases may run against production is decided in
/// `regression/production_guard.dart`.
library;

/// `prod` (the default) or `uat`.
const String kChartEnvName = String.fromEnvironment('CHART_ENV', defaultValue: 'prod');

/// Whether the app is pointed at production.
const bool kChartProd = kChartEnvName == 'prod';

/// `--dart-define=ALLOW_PROD_WRITES=true` runs every case against production anyway, for someone who
/// means to (a throwaway account, say). Off by default.
const bool kAllowProdWrites = bool.fromEnvironment('ALLOW_PROD_WRITES');

/// Stops the app starting with a value that would silently mean production.
///
/// `CHART_ENV=staging` would otherwise fall through to UAT URLs or production ones depending on how
/// a comparison happened to be written; refusing is better than guessing which one was meant.
void requireKnownEnvironment() {
  if (kChartEnvName != 'prod' && kChartEnvName != 'uat') {
    throw StateError('CHART_ENV must be "prod" or "uat", not "$kChartEnvName".');
  }
}
