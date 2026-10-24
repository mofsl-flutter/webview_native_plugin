import "package:flutter/foundation.dart";

/// What the chart bundle inside this build is, as the native side reports it.
///
/// The bundle is the chart page and the TradingView library, shipped as assets and served from the
/// app (see [ChartBundle]). A build can lack it, for example when the host app was built against a
/// plugin version that predates it, so check [available] before loading [ChartBundle.localUrl] and
/// fall back to the hosted page when it is false.
@immutable
class ChartBundleInfo {
  /// Creates a report.
  const ChartBundleInfo({
    required this.available,
    required this.baseUrl,
    this.library,
    this.pageVersion,
    this.language,
    this.fileCount,
    this.reason,
  });

  /// A report for a build that cannot serve the bundle, with the [reason] why.
  const ChartBundleInfo.unavailable(String this.reason)
      : available = false,
        baseUrl = "",
        library = null,
        pageVersion = null,
        language = null,
        fileCount = null;

  /// Reads the map the native side returns.
  factory ChartBundleInfo.fromMap(Map<Object?, Object?> map) {
    return ChartBundleInfo(
      available: map["available"] == true,
      baseUrl: map["baseUrl"] as String? ?? "",
      library: map["library"] as String?,
      pageVersion: map["pageVersion"] as String?,
      language: map["language"] as String?,
      fileCount: map["fileCount"] as int?,
      reason: map["reason"] as String?,
    );
  }

  /// Whether this build ships the bundle and can serve it.
  final bool available;

  /// The origin and path the bundle is served from, e.g.
  /// `https://appassets.androidplatform.net/chart/`. Empty when unavailable.
  final String baseUrl;

  /// The TradingView library version the bundle holds, e.g. `TT_v29_1_0`.
  final String? library;

  /// The chart page's own version (`config.version`) at the time the bundle was synced.
  final String? pageVersion;

  /// The library language the bundle ships.
  final String? language;

  /// How many files the bundle holds.
  final int? fileCount;

  /// Why the bundle is unavailable, when it is.
  final String? reason;

  @override
  String toString() => available
      ? "ChartBundleInfo($library, page $pageVersion, $fileCount files, $baseUrl)"
      : "ChartBundleInfo(unavailable: $reason)";
}

/// The chart page and TradingView library bundled with this plugin and served from the app, so
/// opening the chart fetches no code from the network.
///
/// Only the code is local. The page still calls the server's API (symbols, history, saved layouts)
/// and needs to be told where that is: pass it as `apiBase`.
abstract final class ChartBundle {
  /// The chart page, relative to the bundle root.
  static const String pagePath = "v4/RiseApp_Mobile.html";

  /// The virtual host Android serves the bundle from. Nothing resolves it; the WebView intercepts
  /// every request to it.
  static const String androidBase = "https://appassets.androidplatform.net/chart/";

  /// The custom scheme iOS serves the bundle from.
  static const String iosBase = "mochart://app/chart/";

  /// The URL to load the bundled chart page from.
  ///
  /// [apiBase] is the server's chart root, the URL that `api/...` is relative to. For the hosted
  /// page `https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html` it is
  /// `https://tradingapi.motilaloswaluat.com/chart/`. It is required: a page served from the app
  /// has no server of its own, and refusing to guess is better than calling the wrong host.
  ///
  /// [theme] is passed through to the page as `theme` (the page reads `dark` or `light`).
  ///
  /// Throws [ArgumentError] for an [apiBase] the page would reject (not `https`, carrying
  /// credentials, a query or fragment, or the app's own virtual host) and [UnsupportedError] off
  /// Android and iOS. [platform] exists for tests; it defaults to the running platform.
  static Uri localUrl({
    required Uri apiBase,
    String? theme,
    TargetPlatform? platform,
  }) {
    final String? problem = _apiBaseProblem(apiBase);
    if (problem != null) throw ArgumentError.value(apiBase, "apiBase", problem);

    final TargetPlatform target = platform ?? defaultTargetPlatform;
    final String base = switch (target) {
      TargetPlatform.android => androidBase,
      TargetPlatform.iOS => iosBase,
      _ => throw UnsupportedError("The bundled chart is served on Android and iOS, not $target."),
    };
    return Uri.parse("$base$pagePath").replace(
      queryParameters: <String, String>{
        if (theme != null) "theme": theme,
        "apiBase": apiBase.toString(),
      },
    );
  }

  /// The API root a hosted chart page URL implies, or null when [hostedPage] is not shaped like one.
  ///
  /// The hosted page lives at `<root>/v4/RiseApp_Mobile.html` and the API at `<root>/api/...`, so
  /// `https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html?theme=dark` gives
  /// `https://tradingapi.motilaloswaluat.com/chart/`. A host app that already learns the hosted URL
  /// from its own configuration can derive the [localUrl] `apiBase` from it instead of keeping a
  /// second copy that drifts.
  ///
  /// Null, never a guess, for anything else: another page (`..._ios12.html`), another path layout,
  /// a non-`https` URL, one carrying credentials, or one an [apiBase] could not be (see [localUrl]).
  /// The caller then keeps loading the hosted page. The query and fragment (theme, cache-busting
  /// parameters) are dropped.
  static Uri? apiBaseOf(Uri hostedPage) {
    const String suffix = "/$pagePath";
    if (!hostedPage.path.endsWith(suffix)) return null;
    final String rootPath = hostedPage.path.substring(0, hostedPage.path.length - pagePath.length);
    final Uri root = Uri(
      scheme: hostedPage.scheme,
      host: hostedPage.host,
      port: hostedPage.hasPort ? hostedPage.port : null,
      path: rootPath,
    );
    if (hostedPage.userInfo.isNotEmpty) return null;
    return _apiBaseProblem(root) == null ? root : null;
  }

  /// Why [apiBase] cannot be the page's `apiBase`, or null if it can. The one place the rules live,
  /// so [localUrl] and [apiBaseOf] cannot disagree.
  static String? _apiBaseProblem(Uri apiBase) {
    if (apiBase.scheme != "https" || apiBase.host.isEmpty) return "must be an absolute https URL";
    if (apiBase.userInfo.isNotEmpty) return "must not carry credentials";
    if (apiBase.hasQuery || apiBase.hasFragment) return "must not carry a query or fragment";
    if (Uri.parse(androidBase).host == apiBase.host) return "must not be the app's own host";
    return null;
  }
}
