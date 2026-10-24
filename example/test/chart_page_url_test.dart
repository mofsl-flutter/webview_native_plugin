import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/config/endpoints.dart';

/// The hosted-page runs must keep the URLs they always had, because the query string is part of
/// the HTTP cache key and the harness matches `hbRun` to tell its own events from strays. These
/// are the three shapes the code built by hand before [chartPageUrl] existed.
void main() {
  // These three describe the hosted URLs; with the bundled flag on the URL is a different shape.
  final String? hostedOnly = kChartLocal ? 'hosted-URL case; CHART_LOCAL is on' : null;

  test('without CHART_LOCAL these cases exercise the hosted path', () {
    expect(kChartLocal, isFalse);
  }, skip: kChartLocal ? 'run with CHART_LOCAL=true for the bundled-URL case' : false);

  // Build-time defines cannot be changed from inside a test, so this only runs when the test run is
  // started with them:
  //   flutter test --dart-define=CHART_LOCAL=true \
  //     --dart-define=CHART_API_ROOT=https://api.example/charts/ test/chart_page_url_test.dart
  const String definedRoot = String.fromEnvironment('CHART_API_ROOT');
  test(
    'CHART_API_ROOT is what the bundled page is told to call',
    () {
      expect(kChartRoot, definedRoot);
      final Uri page = Uri.parse(chartPageUrl(theme: 'dark'));
      expect(page.queryParameters['apiBase'], definedRoot);
      expect(page.queryParameters['theme'], 'dark');
    },
    skip: definedRoot.isEmpty || !kChartLocal
        ? 'needs --dart-define=CHART_LOCAL=true and --dart-define=CHART_API_ROOT=<url>'
        : false,
  );

  test('nothing asked for is exactly the hosted URL', () {
    expect(chartPageUrl(), kChartUrl);
  }, skip: hostedOnly);

  test('theme only is `?theme=dark`', () {
    expect(chartPageUrl(theme: 'dark'), '$kChartUrl?theme=dark');
  }, skip: hostedOnly);

  test('theme and run id are `?theme=dark&hbRun=<id>` in that order', () {
    expect(chartPageUrl(theme: 'dark', runId: 'r42'), '$kChartUrl?theme=dark&hbRun=r42');
  }, skip: hostedOnly);

  // A case can load either page whatever the build was started with. The hosted-then-bundled case
  // (L5) needs both in one run, in the same WebView profile.
  group('choosing the page for one load', () {
    test('local: false is the hosted URL, with the same query as always', () {
      expect(chartPageUrl(local: false), kChartUrl);
      expect(chartPageUrl(local: false, theme: 'dark', runId: 'r1'), '$kChartUrl?theme=dark&hbRun=r1');
    });

    test('local: true is the bundled page, told to call the configured API', () {
      final Uri page = Uri.parse(chartPageUrl(local: true, theme: 'dark', runId: 'r1'));

      expect(page.host, 'appassets.androidplatform.net');
      expect(page.path, '/chart/v4/RiseApp_Mobile.html');
      expect(page.queryParameters['apiBase'], kChartRoot);
      expect(page.queryParameters['theme'], 'dark');
      expect(page.queryParameters['hbRun'], 'r1');
    });

    test('left out, it follows CHART_LOCAL as it always did', () {
      expect(chartPageUrl(), chartPageUrl(local: kChartLocal));
      expect(chartPageUrl(theme: 'dark', runId: 'r1'), chartPageUrl(local: kChartLocal, theme: 'dark', runId: 'r1'));
    });

    test('the two pages are on different origins, which is what makes the second a CORS client', () {
      expect(Uri.parse(chartPageUrl(local: true)).origin, isNot(Uri.parse(chartPageUrl(local: false)).origin));
      expect(Uri.parse(chartPageUrl(local: false)).host, Uri.parse(kChartRoot).host,
          reason: 'the hosted page is same-origin to its API: that is how it poisons the cache');
    });
  });
}
