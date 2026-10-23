import 'package:flutter_test/flutter_test.dart';
import 'package:ios_webview_plugin_example/src/config/endpoints.dart';

/// The hosted-page runs must keep the URLs they always had, because the query string is part of
/// the HTTP cache key and the harness matches `hbRun` to tell its own events from strays. These
/// are the three shapes the code built by hand before [chartPageUrl] existed.
void main() {
  test('the flag is off in tests, so these cases exercise the hosted path', () {
    expect(kChartLocal, isFalse);
  });

  test('nothing asked for is exactly the hosted URL', () {
    expect(chartPageUrl(), kChartUrl);
  });

  test('theme only is `?theme=dark`', () {
    expect(chartPageUrl(theme: 'dark'), '$kChartUrl?theme=dark');
  });

  test('theme and run id are `?theme=dark&hbRun=<id>` in that order', () {
    expect(chartPageUrl(theme: 'dark', runId: 'r42'), '$kChartUrl?theme=dark&hbRun=r42');
  });
}
