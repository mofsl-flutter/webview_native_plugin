import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:ios_webview_plugin/chart_prefetch.dart";

/// A chart API on loopback that records what it is asked and answers from a table, so the prefetch
/// is tested against real HTTP without leaving the machine.
class _FakeApi {
  _FakeApi._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeApi> start() async =>
      _FakeApi._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// Every request seen, as `path?query`, in order.
  final List<String> requests = <String>[];
  final List<String?> authorizations = <String?>[];

  /// The `interval` field of the saved-info response, and the interval inside its layout's main
  /// series. They are different things (the field is the last interval saved, the layout's is what
  /// the chart opens at), so a test can set them apart. Null omits the layout.
  String savedInterval = "5";
  String? layoutInterval;

  /// Per endpoint name (the last path segment): status, body override and delay.
  final Map<String, int> status = <String, int>{};
  final Map<String, Duration> delay = <String, Duration>{};

  Uri get base => Uri.parse("http://127.0.0.1:${_server.port}/charts/");

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add("${request.uri.path}?${request.uri.query}");
    authorizations.add(request.headers.value(HttpHeaders.authorizationHeader));
    final String endpoint = request.uri.pathSegments.last;
    final Duration? wait = delay[endpoint];
    if (wait != null) await Future<void>.delayed(wait);
    final int code = status[endpoint] ?? 200;
    request.response.statusCode = code;
    if (code == 200) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_body(endpoint, request.uri.queryParameters)));
    }
    await request.response.close();
  }

  Object _body(String endpoint, Map<String, String> q) {
    switch (endpoint) {
      case "Symbols":
        return <String, Object?>{"ticker": "NSE:ACC", "name": "ACC", "currency_code": "INR"};
      case "GetChartSavedInfo":
        return <String, Object?>{
          "interval": savedInterval,
          // A saved layout is a JSON document inside the JSON response. Its drawings carry their own
          // `interval`, which is not the chart's.
          "saveData": layoutInterval == null
              ? null
              : jsonEncode(<String, Object?>{
                  "charts": <Object?>[
                    <String, Object?>{
                      "panes": <Object?>[
                        <String, Object?>{
                          "sources": <Object?>[
                            <String, Object?>{
                              "type": "LineToolEmoji",
                              "state": <String, Object?>{"interval": "1D"},
                            },
                            <String, Object?>{
                              "type": "MainSeries",
                              "state": <String, Object?>{"symbol": "IDX:1:SENSEX", "interval": layoutInterval},
                            },
                          ],
                        },
                      ],
                    },
                  ],
                }),
        };
      case "Config":
        return <String, Object?>{"supported_resolutions": <String>["1", "5"]};
      case "HistoryV3":
        final int from = int.parse(q["from"]!);
        final int to = int.parse(q["to"]!);
        final int step = int.parse(q["resolution"]!) * 60;
        final List<int> t = <int>[for (int x = from; x <= to; x += step) x];
        return <String, Object?>{
          "t": t,
          "o": t.map((int x) => 100000 + x % 97).toList(),
          "h": t.map((int x) => 100100 + x % 97).toList(),
          "l": t.map((int x) => 99900 + x % 97).toList(),
          "c": t.map((int x) => 100050 + x % 97).toList(),
          "v": t.map((int x) => 10 + x % 7).toList(),
          "divisor": 100,
        };
      default:
        return <String, Object?>{};
    }
  }
}

/// What the page would run, in order.
Future<List<String>> _deliver(ChartPrefetch prefetch) async {
  final List<String> scripts = <String>[];
  await prefetch.handoff((String s) async => scripts.add(s));
  // handoff returns after the first announcements; the rest arrives as the fetches finish.
  for (int i = 0; i < 100 && !scripts.any((String s) => s.contains("p.put(\"history\"") || s.contains("p.cancel(\"history\"")); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (scripts.any((String s) => s.contains("p.cancel(\"symbols\"") || s.contains("p.cancel(\"savedInfo\""))) break;
  }
  return scripts;
}

final bool _hasNode = (() {
  try {
    return Process.runSync("node", <String>["--version"]).exitCode == 0;
  } on ProcessException {
    return false;
  }
})();

void main() {
  late _FakeApi api;

  setUp(() async => api = await _FakeApi.start());
  tearDown(() async => api.close());

  group("construction", () {
    test("requires https, except for loopback", () {
      expect(() => ChartPrefetch(apiBase: Uri.parse("http://example.com/charts/"), token: "t"), throwsArgumentError);
      expect(() => ChartPrefetch(apiBase: Uri.parse("/charts/"), token: "t"), throwsArgumentError);
      expect(() => ChartPrefetch(apiBase: Uri.parse("https://example.com/charts/"), token: "t"), returnsNormally);
      expect(() => ChartPrefetch(apiBase: Uri.parse("http://127.0.0.1:1/charts/"), token: "t"), returnsNormally);
    });

    test("start twice and handoff before start are errors", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t");
      await expectLater(p.handoff((String s) async {}), throwsStateError);
      p.start("0:22");
      expect(() => p.start("0:22"), throwsStateError);
      p.cancel();
    });

    test("a base without a trailing slash still resolves under its path", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: Uri.parse(api.base.toString().replaceAll(RegExp(r"/$"), "")), token: "t")
        ..start("0:22");
      await _deliver(p);
      expect(api.requests.first, startsWith("/charts/api/Chart/Symbols?"));
    });
  });

  group("the requests", () {
    test("are the ones the page makes, in the page's form, with the token", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "test-token")..start("0:22");
      await _deliver(p);

      expect(api.requests, hasLength(4));
      expect(api.requests.contains("/charts/api/Chart/Symbols?symbol=0%3A22"), isTrue);
      expect(api.requests.contains("/charts/api/Chart/Config?page=RiseApp_Mobile_V4.html"), isTrue);
      // Unencoded ticker, as the page concatenates it.
      expect(api.requests.contains("/charts/api/chart/GetChartSavedInfo?symbol=NSE:ACC&page=RiseApp_Mobile.html"), isTrue);
      final String history = api.requests.singleWhere((String r) => r.contains("HistoryV3"));
      final Map<String, String> q = Uri.parse(history).queryParameters;
      expect(q["symbol"], "NSE:ACC");
      expect(q["resolution"], "5", reason: "the saved interval, not a default");
      expect(q["firstDataRequest"], "true");
      expect(int.parse(q["to"]!) - int.parse(q["from"]!), ChartPrefetch.historyLookbackSeconds("5"));
      expect(api.authorizations.toSet(), <String?>{"Bearer test-token"});
    });

    test("opens at the layout's own interval, not the saved-interval field and not a drawing's", () async {
      // The shape of a real account: the field says 1D, the layout's main series is at 1, and a
      // drawing in the layout is at 1D. The library opens at the main series' interval.
      api.savedInterval = "1D";
      api.layoutInterval = "1";
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      final String history = api.requests.singleWhere((String r) => r.contains("HistoryV3"));
      expect(Uri.parse(history).queryParameters["resolution"], "1");
      expect(scripts.join("\n"), contains("p.put(\"history\",\"NSE:ACC|1\""));
    });

    test("without a layout it falls back to the saved-interval field, then to one minute", () async {
      api.savedInterval = "15";
      api.layoutInterval = null;
      final ChartPrefetch withField = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      await _deliver(withField);
      expect(Uri.parse(api.requests.singleWhere((String r) => r.contains("HistoryV3"))).queryParameters["resolution"], "15");

      api.requests.clear();
      api.savedInterval = "";
      final ChartPrefetch neither = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      await _deliver(neither);
      expect(Uri.parse(api.requests.singleWhere((String r) => r.contains("HistoryV3"))).queryParameters["resolution"], "1");
    });

    test("a layout that is not what is expected is ignored, not trusted or thrown on", () async {
      // Truncated JSON in saveData must not stop the open, only the guess.
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t");
      expect(p.intervalOfSavedInfoForTest("{\"interval\":\"5\",\"saveData\":\"{not json\"}"), "5");
      expect(p.intervalOfSavedInfoForTest("{\"interval\":\"5\",\"saveData\":\"{\\\"charts\\\":[]}\"}"), "5");
      expect(p.intervalOfSavedInfoForTest("{\"interval\":\"5\",\"saveData\":42}"), "5");
      expect(p.intervalOfSavedInfoForTest("not json at all"), "1");
    });

    test("daily is one key whether it is spelled D or 1D", () {
      expect(ChartPrefetch.normalizeResolution("D"), "1D");
      expect(ChartPrefetch.normalizeResolution("1D"), "1D");
      expect(ChartPrefetch.normalizeResolution("w"), "1W");
      expect(ChartPrefetch.normalizeResolution("M"), "1M");
      expect(ChartPrefetch.normalizeResolution("5"), "5");
      expect(ChartPrefetch.normalizeResolution("60"), "60");
      expect(ChartPrefetch.normalizeResolution("15S"), "15S");
      expect(ChartPrefetch.normalizeResolution("2D"), "2D");
    });

    test("the layout waits for the symbol, and the history for the layout", () async {
      api.delay["Symbols"] = const Duration(milliseconds: 150);
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      await _deliver(p);
      int at(String endpoint) => api.requests.indexWhere((String r) => r.contains(endpoint));
      expect(at("Symbols"), lessThan(at("GetChartSavedInfo")));
      expect(at("GetChartSavedInfo"), lessThan(at("HistoryV3")));
    });

    test("the lookback reaches past the windows the library was seen to ask for", () {
      expect(ChartPrefetch.historyLookbackSeconds("1"), greaterThan(69120), reason: "1 m: 19.2 h observed");
      expect(ChartPrefetch.historyLookbackSeconds("5"), greaterThan(378000), reason: "5 m: 4.4 days observed");
      for (final String r in <String>["5S", "15", "60", "D", "1D", "W", "M"]) {
        expect(ChartPrefetch.historyLookbackSeconds(r), greaterThan(0), reason: r);
      }
      expect(ChartPrefetch.historyLookbackSeconds("60"), greaterThan(ChartPrefetch.historyLookbackSeconds("15")));
      expect(ChartPrefetch.historyLookbackSeconds("W"), greaterThan(ChartPrefetch.historyLookbackSeconds("D")));
    });
  });

  group("the scripts", () {
    test("announce what is coming before delivering what the page is waiting on", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      final String all = scripts.join("\n");

      expect(scripts.first, contains("p.expect(\"symbols\",\"0:22\")"));
      expect(scripts.first, contains("p.expect(\"config\",\"RiseApp_Mobile_V4.html\")"));
      // The page asks for the layout the moment it has the symbol, so the layout must already be
      // expected when the symbol lands; likewise history before the layout.
      expect(all.indexOf("p.expect(\"savedInfo\""), lessThan(all.indexOf("p.put(\"symbols\"")));
      expect(all.indexOf("p.expect(\"history\""), lessThan(all.indexOf("p.put(\"savedInfo\"")));
      expect(all, contains("p.put(\"history\",\"NSE:ACC|5\""));
    });

    test("never contain the token, and do nothing on a page without the store", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "secret-token-value")..start("0:22");
      final List<String> scripts = await _deliver(p);
      for (final String s in scripts) {
        expect(s, isNot(contains("secret-token-value")));
        expect(s, contains("window.ChartApp&&window.ChartApp.preload"));
        expect(s, contains("if(!p)return;"));
      }
    });

    test("the final outcomes are reported without leaking anything", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "secret-token-value")..start("0:22");
      await _deliver(p);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.outcomes.keys, containsAll(<String>["symbols", "config", "savedInfo", "history"]));
      for (final String v in p.outcomes.values) {
        expect(v, startsWith("ok "));
        expect(v, isNot(contains("secret-token-value")));
      }
    });
  });

  group("when something fails the page is released to ask for itself", () {
    test("a rejected token on Symbols: cancel, and nothing further is requested", () async {
      api.status["Symbols"] = 401;
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      expect(scripts.join("\n"), contains("p.cancel(\"symbols\",\"0:22\")"));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(api.requests.any((String r) => r.contains("GetChartSavedInfo")), isFalse);
      expect(api.requests.any((String r) => r.contains("HistoryV3")), isFalse);
      expect(p.outcomes["symbols"], contains("401"));
    });

    test("a failing layout: the layout is cancelled and no history is fetched", () async {
      api.status["GetChartSavedInfo"] = 500;
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      expect(scripts.join("\n"), contains("p.cancel(\"savedInfo\",\"NSE:ACC|RiseApp_Mobile.html\")"));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(api.requests.any((String r) => r.contains("HistoryV3")), isFalse);
    });

    test("an empty history (204) is cancelled, not delivered as data", () async {
      api.status["HistoryV3"] = 204;
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      expect(scripts.join("\n"), contains("p.cancel(\"history\",\"NSE:ACC|5\")"));
      expect(scripts.join("\n"), isNot(contains("p.put(\"history\"")));
    });

    test("a request past the timeout is abandoned and cancelled", () async {
      api.delay["Config"] = const Duration(milliseconds: 600);
      final ChartPrefetch p = ChartPrefetch(
        apiBase: api.base,
        token: "t",
        requestTimeout: const Duration(milliseconds: 200),
      )..start("0:22");
      final List<String> scripts = await _deliver(p);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(p.outcomes["config"], startsWith("timed out"));
      expect(scripts.join("\n"), isNot(contains("p.put(\"config\"")));
    });

    test("an unreachable server fails quietly", () async {
      final Uri dead = api.base;
      await api.close();
      final ChartPrefetch p = ChartPrefetch(apiBase: dead, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      expect(scripts.join("\n"), contains("p.cancel(\"symbols\""));
      expect(p.outcomes["symbols"], startsWith("failed"));
      api = await _FakeApi.start(); // for tearDown
    });
  });

  group("against the page's real preload store", () {
    Future<Map<String, Object?>> runInPage(List<String> scripts, List<Map<String, Object?>> takes) async {
      final Process node = await Process.start("node", <String>["tool/js_test/support/handoff_runner.mjs"]);
      node.stdin.write(jsonEncode(<String, Object?>{"scripts": scripts, "takes": takes}));
      await node.stdin.close();
      final String out = await node.stdout.transform(utf8.decoder).join();
      final String err = await node.stderr.transform(utf8.decoder).join();
      expect(await node.exitCode, 0, reason: err);
      return jsonDecode(out) as Map<String, Object?>;
    }

    test("every kind the Dart side delivers is one the page can take, under the same key", () async {
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      final Map<String, String> history = Uri.parse(api.requests.singleWhere((String r) => r.contains("HistoryV3"))).queryParameters;
      final int to = int.parse(history["to"]!);

      final Map<String, Object?> out = await runInPage(scripts, <Map<String, Object?>>[
        <String, Object?>{"op": "take", "kind": "symbols", "key": "0:22", "maxAgeMs": 60000},
        <String, Object?>{"op": "take", "kind": "config", "key": "RiseApp_Mobile_V4.html", "maxAgeMs": 60000},
        <String, Object?>{"op": "take", "kind": "savedInfo", "key": "NSE:ACC|RiseApp_Mobile.html", "maxAgeMs": 30000},
        // The library asks for a window inside the prefetched one, as it does for real.
        <String, Object?>{
          "op": "history",
          "request": <String, Object?>{
            "ticker": "NSE:ACC",
            "resolution": "5",
            "from": to - 100000,
            "to": to,
            "countBack": 300,
            "firstDataRequest": true,
          },
        },
      ]);
      final List<Map<String, Object?>> results = (out["results"]! as List<Object?>).cast<Map<String, Object?>>();
      expect(results.map((Map<String, Object?> r) => r["found"]).toList(), <bool>[true, true, true, true]);
      expect((results[0]["body"]! as Map<String, Object?>)["ticker"], "NSE:ACC");
      expect((results[2]["body"]! as Map<String, Object?>)["interval"], "5");
      final Map<String, Object?> bars = results[3]["body"]! as Map<String, Object?>;
      final List<Object?> t = bars["t"]! as List<Object?>;
      expect(t.length, greaterThanOrEqualTo(300));
      expect(t.cast<int>().first, greaterThanOrEqualTo(to - 100000));
      expect(t.cast<int>().last, lessThanOrEqualTo(to));
      expect((bars["c"]! as List<Object?>).length, t.length, reason: "per-bar arrays are cut with t");
      expect(bars["divisor"], 100);
    });

    test("a cancelled kind is a miss in the page, so the page asks the server itself", () async {
      api.status["Config"] = 500;
      final ChartPrefetch p = ChartPrefetch(apiBase: api.base, token: "t")..start("0:22");
      final List<String> scripts = await _deliver(p);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final Map<String, Object?> out = await runInPage(scripts, <Map<String, Object?>>[
        <String, Object?>{"op": "take", "kind": "config", "key": "RiseApp_Mobile_V4.html", "maxAgeMs": 60000},
        <String, Object?>{"op": "take", "kind": "symbols", "key": "0:22", "maxAgeMs": 60000},
      ]);
      final List<Map<String, Object?>> results = (out["results"]! as List<Object?>).cast<Map<String, Object?>>();
      expect(results[0]["found"], isFalse);
      expect(results[1]["found"], isTrue, reason: "one failure must not take the others down");
    });

    test("a body with awkward characters survives the quoting", () async {
      // A name with quotes, a backslash, a line break and the JS line separators.
      const String awkward = "ACC \"Ltd\" \\ line\nbreak     </script>";
      final String script = "(function(){try{var p=window.ChartApp&&window.ChartApp.preload;if(!p)return;p.put(\"symbols\",\"k\",${jsonEncode(jsonEncode(<String, String>{"name": awkward}))},${DateTime.now().millisecondsSinceEpoch},undefined);}catch(e){}})();";
      final Map<String, Object?> out = await runInPage(<String>[script], <Map<String, Object?>>[
        <String, Object?>{"op": "take", "kind": "symbols", "key": "k", "maxAgeMs": 60000},
      ]);
      final Map<String, Object?> body = ((out["results"]! as List<Object?>).single! as Map<String, Object?>)["body"]! as Map<String, Object?>;
      expect(body["name"], awkward);
    });
  }, skip: _hasNode ? false : "node is not on PATH");
}
