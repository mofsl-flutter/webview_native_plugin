import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:ios_webview_plugin/chart_bundle.dart";
import "package:ios_webview_plugin/ios_webview_plugin.dart";

final Uri _server = Uri.parse("https://tradingapi.motilaloswaluat.com/chart/");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("ChartBundle.localUrl", () {
    test("Android serves from the virtual host", () {
      final Uri url = ChartBundle.localUrl(
        apiBase: _server,
        theme: "dark",
        platform: TargetPlatform.android,
      );
      expect(url.scheme, "https");
      expect(url.host, "appassets.androidplatform.net");
      expect(url.path, "/chart/v4/RiseApp_Mobile.html");
      expect(url.queryParameters, <String, String>{"theme": "dark", "apiBase": _server.toString()});
    });

    test("iOS serves from the custom scheme", () {
      final Uri url = ChartBundle.localUrl(apiBase: _server, platform: TargetPlatform.iOS);
      expect(url.scheme, "mochart");
      expect(url.host, "app");
      expect(url.path, "/chart/v4/RiseApp_Mobile.html");
      expect(url.queryParameters.containsKey("theme"), isFalse);
    });

    test("encodes apiBase the way the page decodes it", () {
      // tool/js_test/api_base.test.mjs feeds the page exactly this encoding.
      final Uri url = ChartBundle.localUrl(apiBase: _server, platform: TargetPlatform.android);
      expect(
        url.query,
        "apiBase=https%3A%2F%2Ftradingapi.motilaloswaluat.com%2Fchart%2F",
      );
    });

    test("accepts production's API Gateway root and keeps its /charts/ path", () {
      final Uri prod = Uri.parse("https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/");
      for (final TargetPlatform platform in <TargetPlatform>[TargetPlatform.android, TargetPlatform.iOS]) {
        final Uri url = ChartBundle.localUrl(apiBase: prod, theme: "dark", platform: platform);
        expect(Uri.parse(url.queryParameters["apiBase"]!), prod);
        expect(url.queryParameters["apiBase"], endsWith("/charts/"));
      }
    });

    test("refuses an apiBase the page would reject", () {
      final List<Uri> bad = <Uri>[
        Uri.parse("http://tradingapi.motilaloswaluat.com/chart/"),
        Uri.parse("https://user:pw@tradingapi.motilaloswaluat.com/chart/"),
        Uri.parse("https://tradingapi.motilaloswaluat.com/chart/?x=1"),
        Uri.parse("https://tradingapi.motilaloswaluat.com/chart/#f"),
        Uri.parse("https://appassets.androidplatform.net/chart/"),
        Uri.parse("/chart/"),
        Uri.parse("https:///chart/"),
      ];
      for (final Uri u in bad) {
        expect(
          () => ChartBundle.localUrl(apiBase: u, platform: TargetPlatform.android),
          throwsArgumentError,
          reason: "$u",
        );
      }
    });

    test("is Android and iOS only", () {
      expect(
        () => ChartBundle.localUrl(apiBase: _server, platform: TargetPlatform.macOS),
        throwsUnsupportedError,
      );
    });
  });

  group("ChartBundle.apiBaseOf", () {
    test("is the directory above v4, for UAT and for production", () {
      expect(
        ChartBundle.apiBaseOf(Uri.parse("https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html")),
        Uri.parse("https://tradingapi.motilaloswaluat.com/chart/"),
      );
      expect(
        ChartBundle.apiBaseOf(Uri.parse(
            "https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/v4/RiseApp_Mobile.html")),
        Uri.parse("https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/"),
      );
    });

    test("drops the query and fragment, the theme and cache-busting the host adds", () {
      final Uri? root = ChartBundle.apiBaseOf(Uri.parse(
          "https://h.example/chart/v4/RiseApp_Mobile.html?theme=dark&t=1792822168#x"));
      expect(root, Uri.parse("https://h.example/chart/"));
      expect(root!.hasQuery, isFalse);
      expect(root.hasFragment, isFalse);
    });

    test("keeps a non-default port and a deeper path", () {
      expect(
        ChartBundle.apiBaseOf(Uri.parse("https://h.example:8443/a/b/v4/RiseApp_Mobile.html")),
        Uri.parse("https://h.example:8443/a/b/"),
      );
    });

    test("a page at the host root has the root as its API root", () {
      expect(
        ChartBundle.apiBaseOf(Uri.parse("https://h.example/v4/RiseApp_Mobile.html")),
        Uri.parse("https://h.example/"),
      );
    });

    test("is null for anything that is not shaped like the hosted page", () {
      final List<String> notThePage = <String>[
        "https://h.example/chart/v4/RiseApp_Mobile_ios12.html",
        "https://h.example/chart/v4/PeakMobileChart.html",
        "https://h.example/chart/v5/RiseApp_Mobile.html",
        "https://h.example/chart/RiseApp_Mobile.html",
        "https://h.example/chart/xv4/RiseApp_Mobile.html",
        "https://h.example/chart/v4/RiseApp_Mobile.html/extra",
        "http://h.example/chart/v4/RiseApp_Mobile.html",
        "https://user:pw@h.example/chart/v4/RiseApp_Mobile.html",
        "https://appassets.androidplatform.net/chart/v4/RiseApp_Mobile.html",
        "/chart/v4/RiseApp_Mobile.html",
        "https:///chart/v4/RiseApp_Mobile.html",
        "",
      ];
      for (final String url in notThePage) {
        expect(ChartBundle.apiBaseOf(Uri.parse(url)), isNull, reason: url);
      }
    });

    test("whatever it returns, localUrl accepts", () {
      final Uri? root =
          ChartBundle.apiBaseOf(Uri.parse("https://h.example/chart/v4/RiseApp_Mobile.html?theme=dark"));
      final Uri url = ChartBundle.localUrl(apiBase: root!, theme: "dark", platform: TargetPlatform.android);
      expect(Uri.parse(url.queryParameters["apiBase"]!), root);
    });
  });

  group("IosWebViewPlugin.chartBundleInfo", () {
    const MethodChannel channel = MethodChannel("webview_mo_flutter");

    void handle(Future<Object?>? Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test("reads what the native side reports", () async {
      handle((MethodCall c) async {
        expect(c.method, "chartBundleInfo");
        return <String, Object?>{
          "available": true,
          "baseUrl": "https://appassets.androidplatform.net/chart/",
          "library": "TT_v29_1_0",
          "pageVersion": "20260724_01",
          "language": "en",
          "fileCount": 515,
        };
      });
      final ChartBundleInfo info = await IosWebViewPlugin.chartBundleInfo();
      expect(info.available, isTrue);
      expect(info.library, "TT_v29_1_0");
      expect(info.fileCount, 515);
      expect(info.reason, isNull);
    });

    test("a native report of unavailable carries its reason", () async {
      handle((MethodCall c) async => <String, Object?>{
            "available": false,
            "baseUrl": "https://appassets.androidplatform.net/chart/",
            "reason": "asset not found",
          });
      final ChartBundleInfo info = await IosWebViewPlugin.chartBundleInfo();
      expect(info.available, isFalse);
      expect(info.reason, "asset not found");
    });

    test("never throws: a missing handler, an error and an empty reply all read as unavailable",
        () async {
      // No handler registered: the platform side does not know the method.
      ChartBundleInfo info = await IosWebViewPlugin.chartBundleInfo();
      expect(info.available, isFalse);

      handle((MethodCall c) async => throw PlatformException(code: "boom", message: "kaput"));
      info = await IosWebViewPlugin.chartBundleInfo();
      expect(info.available, isFalse);
      expect(info.reason, contains("kaput"));

      handle((MethodCall c) async => null);
      info = await IosWebViewPlugin.chartBundleInfo();
      expect(info.available, isFalse);
    });
  });
}
