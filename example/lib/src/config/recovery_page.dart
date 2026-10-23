import 'dart:convert';

/// The page the recovery suite loads, and the scripts it injects.
///
/// The recovery cases test the plugin's self-healing primitives, not the chart, so they must not
/// depend on the chart's network, a token, or a login. This page is served from a `data:` URL and
/// honours just enough of the chart page's contract for the plugin and a host to behave exactly as
/// they do in production:
///
/// * it reads `window.ChartAppDelegate`, which the plugin exposes as a JavaScript channel,
/// * it posts `PageReady` as soon as it has booted,
/// * it defines `window.ChartApp.v1`, which is what a host's readiness check looks for,
/// * `loadChart` answers with a `Chart` message, as the real page does.
const String kRecoveryPageHtml = '''<!doctype html>
<html>
<head><meta charset="utf-8"><title>recovery page</title></head>
<body style="background:#16182C;color:#8a8fb0;font:12px sans-serif">recovery page</body>
<script>
(function () {
  function post(o) {
    try { window.ChartAppDelegate.postMessage(JSON.stringify(o)); } catch (e) {}
  }
  window.ChartApp = {
    v1: {
      authorize: function () {},
      changeTheme: function () {},
      loadChart: function (symbol, mode, theme) {
        post({context: 'Chart', success: {source: 'changeSymbol', symbol: symbol, theme: theme || 'light', resetCache: false}});
      }
    }
  };
  post({context: 'PageReady', success: {source: 'recovery_page_v1', resetCache: false}});
})();
</script>
</html>''';

/// A page with no chart app and no messages, for the "page is up but is not the chart" cases.
const String kPlainPageHtml =
    '<!doctype html><html><head><meta charset="utf-8"><title>plain</title></head>'
    '<body style="background:#16182C;color:#8a8fb0;font:12px sans-serif">plain page, no chart app</body></html>';

/// [kRecoveryPageHtml] as a URL the plugin can navigate to (Android; see `RecoveryPages` for iOS).
final String kRecoveryPageUrl =
    'data:text/html;charset=utf-8;base64,${base64Encode(utf8.encode(kRecoveryPageHtml))}';

/// Event name the probe's page-side message carries.
const String kProbeEvent = '__probe';

/// Event name a ping's page-side message carries.
const String kPingEvent = '__ping';

/// The script a host runs to ask the page whether it is alive.
///
/// Mirrors `ChartController.probeScript` in the app (`trader_native_charts`), which is what runs in
/// production. It reports readiness through the call's return value, which does not depend on the
/// event path, and also posts a message on the chart channel, which does. Whether that second
/// message arrives is how a lost event path is told apart from a dead page. The URL is trimmed
/// only because a `data:` URL here is far longer than the chart's real one.
String buildProbeScript(int id) => '(function(){var r={ready:false};'
    'try{r.href=location.href.slice(0,60);'
    'r.ready=!!(window.ChartApp&&window.ChartApp.v1)}catch(e){}'
    'try{window.ChartAppDelegate.postMessage(JSON.stringify({event:"$kProbeEvent",id:$id}))}catch(e){}'
    'return JSON.stringify(r)})()';

/// A script that makes the page post one message, to test whether events reach Dart.
String buildPingScript(int id) =>
    '(function(){try{window.ChartAppDelegate.postMessage(JSON.stringify({event:"$kPingEvent",id:$id}))}catch(e){}})()';

/// A script that keeps the page's JavaScript thread busy for [milliseconds].
///
/// A renderer stuck in a loop cannot answer an evaluation, which is the shape of a hung page.
String buildBusyScript(int milliseconds) =>
    '(function(){var t=Date.now();while(Date.now()-t<$milliseconds){}})()';

/// Decodes what [buildProbeScript] returned.
///
/// The script returns a JSON string. Android hands a script's return value back JSON-encoded, so
/// that string arrives wrapped in a second layer of JSON; iOS returns it as is. Decoding up to
/// twice accepts both. Mirrors `PageProbe.parseScriptResult` in the app.
Map<String, Object?>? decodeProbeResult(Object? raw) {
  Object? value = raw;
  for (int i = 0; i < 2 && value is String; i++) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return value is Map ? Map<String, Object?>.from(value) : null;
}
