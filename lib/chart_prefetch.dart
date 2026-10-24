import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart" show visibleForTesting;

/// Fetches what the bundled chart needs to open before its page has finished loading, and hands it
/// to the page, so the chart does not wait for a chain of requests that could have run in parallel
/// with the page loading.
///
/// Opening a chart is Symbols, then GetChartSavedInfo, then (once the widget exists) Config and the
/// first HistoryV3. The page cannot start any of them before it has loaded; the host can. Start this
/// as soon as the symbol and token are known, deliver it once the page is up, then ask the page to
/// load the chart:
///
/// ```dart
/// final ChartPrefetch prefetch = ChartPrefetch(apiBase: apiBase, token: token)..start("0:22");
/// // ...navigate to ChartBundle.localUrl(...), wait for the page's PageReady...
/// await prefetch.handoff(IosWebViewPlugin.runJavaScript);
/// // ...authorise, then call loadChart as before.
/// ```
///
/// This is a shortcut, never a source of truth. The page takes a delivered response instead of
/// making the request, parses it with the code it has always used, and goes to the network itself
/// for anything that is missing, late, stale or does not cover what the chart asks for. A request
/// that fails here is simply not delivered. It does not change what the chart shows, only when.
///
/// Read-only: it sends `GET`s for the same four endpoints the page would, with the same token.
class ChartPrefetch {
  /// Creates a prefetch for the chart at [apiBase] (the server's chart root, the URL `api/...` is
  /// relative to) authorised with [token].
  ///
  /// [apiBase] must be `https`, except for a loopback host, which is allowed so a test can serve it
  /// locally. [page] is the chart page's name as the server knows it. [requestTimeout] bounds each
  /// request; one that exceeds it is abandoned and the page asks for itself.
  ChartPrefetch({
    required Uri apiBase,
    required String token,
    this.page = "RiseApp_Mobile.html",
    this.requestTimeout = const Duration(seconds: 25),
    HttpClient? httpClient,
    DateTime Function()? clock,
  })  : _apiBase = _checked(apiBase),
        _token = token,
        _client = httpClient ?? HttpClient(),
        _clock = clock ?? DateTime.now;

  static Uri _checked(Uri apiBase) {
    final bool loopback =
        apiBase.host == "127.0.0.1" || apiBase.host == "localhost" || apiBase.host == "::1";
    if (apiBase.host.isEmpty || (apiBase.scheme != "https" && !(loopback && apiBase.scheme == "http"))) {
      throw ArgumentError.value(apiBase, "apiBase", "must be an absolute https URL");
    }
    // `resolve` drops the last path segment unless the path ends in a slash.
    return apiBase.path.endsWith("/") ? apiBase : apiBase.replace(path: "${apiBase.path}/");
  }

  final Uri _apiBase;
  final String _token;
  final HttpClient _client;
  final DateTime Function() _clock;

  /// The chart page's name, e.g. `RiseApp_Mobile.html`; part of the saved-layout request.
  final String page;

  /// How long one request may take before it is abandoned.
  final Duration requestTimeout;

  bool _started = false;
  bool _cancelled = false;
  String _symbol = "";

  late final Future<_Fetched?> _symbolsFetch;
  late final Future<_Fetched?> _configFetch;
  late final Future<_Fetched?> _savedInfoFetch;
  late final Future<_Fetched?> _historyFetch;

  final Map<String, String> _outcomes = <String, String>{};

  /// What happened to each request, by kind: `ok <ms> <bytes>B` or why it was not delivered. For
  /// logging and for deciding whether a run actually used the prefetch.
  Map<String, String> get outcomes => Map<String, String>.unmodifiable(_outcomes);

  // The name the server knows the config page under: the mobile page asks for its `_V4` variant.
  String get _configPage => page == "RiseApp_Mobile.html" ? "RiseApp_Mobile_V4.html" : page;

  /// Starts fetching [symbol]'s opening data and returns at once.
  ///
  /// [symbol] is what `loadChart` will be called with (e.g. `0:22`), because that is what the page
  /// looks it up by. Throws [StateError] if called twice.
  void start(String symbol) {
    if (_started) throw StateError("ChartPrefetch.start was already called");
    _started = true;
    _symbol = symbol;

    _symbolsFetch = _get("symbols", "api/Chart/Symbols?symbol=${Uri.encodeComponent(symbol)}");
    _configFetch = _get("config", "api/Chart/Config?page=$_configPage");

    // Each later request needs something from the one before it: the ticker names the layout, and
    // the layout names the interval. A step whose input is missing is skipped, and the page asks.
    _savedInfoFetch = _symbolsFetch.then((_Fetched? symbols) async {
      final String? ticker = _tickerOf(symbols);
      if (ticker == null) return null;
      // Unencoded, exactly as the page builds this URL.
      return _get("savedInfo", "api/chart/GetChartSavedInfo?symbol=$ticker&page=$page");
    });
    _historyFetch = _savedInfoFetch.then((_Fetched? saved) async {
      final String? ticker = _tickerOf(await _symbolsFetch);
      if (ticker == null || saved == null) return null;
      final String interval = _intervalOf(saved);
      final int nowSec = _clock().millisecondsSinceEpoch ~/ 1000;
      final int fromSec = nowSec - historyLookbackSeconds(interval);
      _historyWindow = (from: fromSec, to: nowSec);
      final String query = <String, String>{
        "symbol": ticker,
        "resolution": interval,
        "from": "$fromSec",
        "to": "$nowSec",
        "countBack": "300",
        "firstDataRequest": "true",
      }.entries.map((MapEntry<String, String> e) => "${e.key}=${Uri.encodeComponent(e.value)}").join("&");
      return _get("history", "api/Chart/HistoryV3?$query");
    });
  }

  // The window the history request covered, set when that request is made.
  ({int from, int to})? _historyWindow;

  // What the page reads as `data.ticker` from the Symbols response.
  String? _tickerOf(_Fetched? symbols) => _field(symbols, "ticker");

  /// The interval the chart opens at, which decides which history to fetch.
  ///
  /// It is NOT the saved-info `interval` field. When the account has a saved layout the library
  /// restores the layout's main series, and opens at that series' interval whatever the widget was
  /// told: on a real account the field said `1D` while the layout's main series was at `1`, and the
  /// chart asked for one-minute bars. So: the main series' interval from the layout if there is one;
  /// else the `interval` field; else one minute (the page's own default). A wrong guess costs only a
  /// wasted request, because the page looks history up by the resolution it actually asks for.
  String _intervalOf(_Fetched saved) {
    final Object? decoded = _decode(saved.body);
    if (decoded is Map<String, Object?>) {
      final String? fromLayout = _mainSeriesInterval(decoded["saveData"]);
      if (fromLayout != null) return fromLayout;
      final Object? field = decoded["interval"];
      if (field != null && "$field".isNotEmpty) return "$field";
    }
    return "1";
  }

  /// [_intervalOf] for a saved-info response body, so a test can feed it awkward shapes.
  @visibleForTesting
  String intervalOfSavedInfoForTest(String body) => _intervalOf(_Fetched(body, 0));

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  // `saveData` is a JSON document inside the JSON response. The interval is the first main series
  // found: a drawing in the same layout carries an `interval` of its own that must not be mistaken
  // for it. Anything unexpected is "no answer", never an error.
  static String? _mainSeriesInterval(Object? saveData) {
    if (saveData is! String || saveData.isEmpty) return null;
    final Object? layout = _decode(saveData);
    if (layout is! Map) return null;
    final Object? charts = layout["charts"];
    if (charts is! List || charts.isEmpty) return null;
    final Object? chart = charts.first;
    if (chart is! Map) return null;
    final Object? panes = chart["panes"];
    if (panes is! List) return null;
    for (final Object? pane in panes) {
      final Object? sources = pane is Map ? pane["sources"] : null;
      if (sources is! List) continue;
      for (final Object? source in sources) {
        if (source is Map && source["type"] == "MainSeries") {
          final Object? state = source["state"];
          final Object? interval = state is Map ? state["interval"] : null;
          if (interval != null && "$interval".isNotEmpty) return "$interval";
        }
      }
    }
    return null;
  }

  /// The one spelling of a resolution used in history keys: TradingView says `D` in some places and
  /// `1D` in others for the same thing, and a mismatch would silently waste the prefetch. Mirrors the
  /// page's own normalisation in `core/preload.js`.
  static String normalizeResolution(String resolution) =>
      RegExp(r"^[dwm]$", caseSensitive: false).hasMatch(resolution)
          ? "1${resolution.toUpperCase()}"
          : resolution;

  /// How far back, in seconds, to ask for history at [resolution], so the window reaches past the
  /// one the chart library will ask for.
  ///
  /// The library asks for about 330 bars ending now. Intraday bars only exist for 6.25 of a day's 24
  /// hours, so a window of that many bars spans about 3.8 times as much wall time (observed: 19.2 h
  /// for one-minute bars, 4.4 days for five-minute); daily bars skip weekends. Each is widened by
  /// 1.6 for margin. A guess that is too short costs nothing but a duplicate request: the page
  /// refuses a prefetch that does not reach back far enough.
  static int historyLookbackSeconds(String resolution) {
    const int bars = 330;
    final String r = resolution.toUpperCase();
    final int n = int.tryParse(RegExp(r"^\d+").stringMatch(r) ?? "") ?? 1;
    final double seconds;
    if (r.endsWith("S")) {
      seconds = bars * n * 3.84;
    } else if (r.endsWith("D")) {
      seconds = bars * n * 86400 * 1.4;
    } else if (r.endsWith("W")) {
      seconds = bars * n * 7 * 86400.0;
    } else if (r.endsWith("M")) {
      seconds = bars * n * 30 * 86400.0;
    } else {
      seconds = bars * n * 60 * 3.84;
    }
    return (seconds * 1.6).ceil();
  }

  String? _field(_Fetched? fetched, String name) {
    if (fetched == null) return null;
    try {
      final Object? decoded = jsonDecode(fetched.body);
      if (decoded is Map<String, Object?>) {
        final Object? value = decoded[name];
        if (value != null && "$value".isNotEmpty) return "$value";
      }
    } on FormatException {
      // Not JSON: nothing to read, so nothing further is prefetched.
    }
    return null;
  }

  Future<_Fetched?> _get(String kind, String relative) async {
    if (_cancelled) return null;
    final Stopwatch sw = Stopwatch()..start();
    try {
      final HttpClientRequest request =
          await _client.getUrl(_apiBase.resolve(relative)).timeout(requestTimeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, "Bearer $_token")
        ..set(HttpHeaders.acceptHeader, "application/json");
      final HttpClientResponse response = await request.close().timeout(requestTimeout);
      final String body = await response.transform(utf8.decoder).join().timeout(requestTimeout);
      if (response.statusCode != 200) {
        // 204 (no data) and 401 alike: only a 200 is a response the page could have used.
        _outcomes[kind] = "http ${response.statusCode} after ${sw.elapsedMilliseconds} ms";
        return null;
      }
      _outcomes[kind] = "ok ${sw.elapsedMilliseconds} ms ${utf8.encode(body).length}B";
      return _Fetched(body, _clock().millisecondsSinceEpoch);
    } on TimeoutException {
      _outcomes[kind] = "timed out after ${sw.elapsedMilliseconds} ms";
      return null;
    } on Object catch (e) {
      // The token never appears in a message: the request headers are not part of any exception.
      _outcomes[kind] = "failed: ${e.runtimeType}";
      return null;
    }
  }

  /// Delivers what was fetched to the page, and keeps delivering as the rest arrives.
  ///
  /// [run] executes JavaScript in the page (e.g. `IosWebViewPlugin.runJavaScript`). Call it after
  /// the page has announced itself and **before** asking it to load the chart. On a page without the
  /// preload store (the hosted one) the scripts do nothing.
  ///
  /// Returns once the first announcements are in, not when every fetch is done: the page waits for
  /// any response still in flight, so the chart can be requested straight away.
  Future<void> handoff(Future<void> Function(String script) run) async {
    if (!_started) throw StateError("ChartPrefetch.start has not been called");
    final String configKey = _configPage;
    // The two whose keys are known now are announced first, so a page that asks at once waits
    // instead of making its own request.
    await run(_script(<String>[
      _expect("symbols", _symbol),
      _expect("config", configKey),
    ]));

    unawaited(_configFetch.then((_Fetched? f) => run(_script(<String>[_deliver("config", configKey, f)]))));

    unawaited(() async {
      final _Fetched? symbols = await _symbolsFetch;
      final String? ticker = _tickerOf(symbols);
      if (symbols == null || ticker == null) {
        // Nothing more can be keyed. The page asks for the symbol itself and for everything after.
        await run(_script(<String>[_deliver("symbols", _symbol, null)]));
        return;
      }
      // Announce the layout BEFORE delivering the symbol: the page asks for the layout the moment
      // it has the symbol, and must find it expected, not absent.
      final String savedKey = "$ticker|$page";
      await run(_script(<String>[_expect("savedInfo", savedKey), _deliver("symbols", _symbol, symbols)]));

      final _Fetched? saved = await _savedInfoFetch;
      if (saved == null) {
        await run(_script(<String>[_deliver("savedInfo", savedKey, null)]));
        return;
      }
      final String interval = _intervalOf(saved);
      final String historyKey = "$ticker|${normalizeResolution(interval)}";
      await run(_script(<String>[_expect("history", historyKey), _deliver("savedInfo", savedKey, saved)]));

      final _Fetched? history = await _historyFetch;
      final ({int from, int to})? window = _historyWindow;
      await run(_script(<String>[_deliver("history", historyKey, history, meta: window)]));
    }());
  }

  /// Gives up: in-flight requests are dropped and nothing further is delivered. Pages already told
  /// to expect a response are released by [handoff]'s own cancellations.
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
  }

  // ------------------------------------------------------------------------------------ scripts

  static String _js(String s) => jsonEncode(s);

  static String _expect(String kind, String key) => "p.expect(${_js(kind)},${_js(key)});";

  static String _deliver(String kind, String key, _Fetched? fetched, {({int from, int to})? meta}) {
    if (fetched == null) return "p.cancel(${_js(kind)},${_js(key)});";
    final String metaJs = meta == null ? "undefined" : "{from:${meta.from},to:${meta.to}}";
    return "p.put(${_js(kind)},${_js(key)},${_js(fetched.body)},${fetched.fetchedAtMs},$metaJs);";
  }

  // Wrapped so that a page without the store (the hosted one) ignores it instead of throwing.
  static String _script(List<String> calls) =>
      "(function(){try{var p=window.ChartApp&&window.ChartApp.preload;if(!p)return;${calls.join()}}catch(e){}})();";
}

class _Fetched {
  const _Fetched(this.body, this.fetchedAtMs);

  final String body;
  final int fetchedAtMs;
}
