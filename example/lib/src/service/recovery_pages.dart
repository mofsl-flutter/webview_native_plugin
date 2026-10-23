import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/recovery_page.dart';

/// Where the recovery suite's pages come from.
///
/// Android loads them from `data:` URLs, which needs nothing else. iOS cannot: its `loadUrl`
/// validates the URL with `UIApplication.canOpenURL`, which rejects `data:`, and then quietly loads
/// the plugin's fallback page instead. So on iOS the same pages are served from a loopback HTTP
/// server inside the app. Either way no network is involved.
class RecoveryPages {
  HttpServer? _server;
  Future<void>? _starting;

  /// Whether pages are served over loopback rather than as `data:` URLs.
  bool get usesServer => Platform.isIOS;

  /// Starts serving, if this platform needs it. Idempotent; safe to await repeatedly.
  Future<void> ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    if (!usesServer) return;
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((HttpRequest request) {
      final String? html = switch (request.uri.path) {
        '/recovery.html' => kRecoveryPageHtml,
        '/plain.html' => kPlainPageHtml,
        _ => null,
      };
      if (html == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response
          ..headers.contentType = ContentType.html
          ..headers.set('Cache-Control', 'no-store')
          ..write(html);
      }
      unawaited(request.response.close());
    });
  }

  /// The page that behaves like the chart page: posts `PageReady`, exposes `ChartApp.v1`.
  String get chartPage => usesServer
      ? 'http://127.0.0.1:${_server!.port}/recovery.html'
      : kRecoveryPageUrl;

  /// [chartPage] as a URL that is different every time it is asked for.
  ///
  /// The iOS plugin skips the navigation when asked to load the URL it is already on, so a case
  /// that means to load the page again needs a new one. The app's chart controller does the same
  /// with a `t=` timestamp. Android always navigates, and a `data:` URL cannot take a query string
  /// without corrupting its payload, so there it is returned unchanged.
  String freshChartPage() =>
      usesServer ? '$chartPage?t=${DateTime.now().microsecondsSinceEpoch}' : chartPage;

  /// A page with no chart app at all.
  String get plainPage => usesServer
      ? 'http://127.0.0.1:${_server!.port}/plain.html'
      : 'data:text/html;charset=utf-8;base64,${base64Encode(utf8.encode(kPlainPageHtml))}';

  /// Stops serving.
  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }
}
