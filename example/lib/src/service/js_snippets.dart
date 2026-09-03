/// Every JavaScript string the harness injects.
///
/// All interpolated values go through `jsonEncode`, which produces a complete, correctly escaped
/// JavaScript string literal *including* its quotes — so the templates never add their own.
library;

import 'dart:convert';

/// Installs `window.__hb`, the harness's own reporter.
///
/// The page's `PageReady` and `Chart` messages carry no run identifier, so anything the harness
/// controls reports through this instead and is correlated exactly. It also carries an in-page
/// `performance.now()` reading, which cross-checks Dart-side timestamps and exposes main-thread
/// stalls.
const String hbBootstrapJs = '(function(){'
    'if(window.__hb)return;'
    'window.__hb=function(runId,phase,detail){'
    'try{'
    'var d=window.ChartAppDelegate;'
    'if(!d)return;'
    'd.postMessage(JSON.stringify({'
    'context:"Harness",runId:runId,phase:phase,detail:detail,'
    'ts:Date.now(),perf:Math.round((window.performance&&performance.now())||0)'
    '}));'
    '}catch(e){}'
    '};'
    '})();';

/// Authorises the page and reports when the promise actually settles.
///
/// `Authorize` is `async` and, with session validation enabled, awaits a network round-trip.
/// A plain injection returns as soon as the promise is *created*, so bridging `.then` is the only
/// way to measure the real cost.
String buildAuthorizeJs(String token, String runId) {
  final String t = jsonEncode(token);
  final String r = jsonEncode(runId);
  return '(function(){'
      'try{'
      'var a=(window.ChartApp&&window.ChartApp.v1&&window.ChartApp.v1.authorize)||window.Authorize;'
      'if(typeof a!=="function"){__hb($r,"authorizeMissing",null);return;}'
      '__hb($r,"authorizeCalled",null);'
      'var p=a($t);'
      'if(p&&typeof p.then==="function"){'
      'p.then(function(){__hb($r,"authorizeResolved",null);},'
      'function(e){__hb($r,"authorizeRejected",String((e&&e.message)||e));});'
      '}else{__hb($r,"authorizeResolved",null);}'
      '}catch(e){__hb($r,"authorizeThrew",String((e&&e.message)||e));}'
      '})();';
}

/// Loads [symbol] using the page's v1 API, which takes an explicit theme.
///
/// Pinning the theme matters: the legacy `window.LoadChart` leaves it undefined, so the page
/// resolves it from local storage — meaning a storage-clearing run silently renders a different
/// theme and loads different assets.
String buildLoadChartJs(
  String symbol,
  String runId, {
  String chartMode = 'FullChart',
  String theme = 'dark',
}) {
  final String s = jsonEncode(symbol);
  final String r = jsonEncode(runId);
  final String m = jsonEncode(chartMode);
  final String th = jsonEncode(theme);
  return '(function(){'
      'try{'
      'var v1=window.ChartApp&&window.ChartApp.v1;'
      'if(v1&&typeof v1.loadChart==="function"){'
      '__hb($r,"loadChartCalled",$s);'
      'v1.loadChart($s,$m,$th,true,false);'
      'return;'
      '}'
      'if(typeof window.LoadChart==="function"){'
      '__hb($r,"loadChartCalledLegacy",$s);'
      // isMobileApp must be true: it is what routes the page's 401 reporting to the native
      // channel rather than to window.parent.
      'window.LoadChart($s,$m,null,null,true,false);'
      'return;'
      '}'
      '__hb($r,"loadChartMissing",null);'
      '}catch(e){__hb($r,"loadChartThrew",String((e&&e.message)||e));}'
      '})();';
}

/// Clears just the page's stored tokens.
///
/// Both keys matter: the page keeps a previous token alongside the current one.
const String hbClearTokenJs = '(function(){'
    'try{localStorage.removeItem("chart.user.token");'
    'localStorage.removeItem("chart.user.oldToken");}catch(e){}'
    'try{sessionStorage.clear();}catch(e){}'
    '})();';

/// Clears all page storage.
///
/// Self-verifying: this drops the page's stored version, so the next load purges storage itself
/// and reports `resetCache: true` at `PageReady`. If that flag comes back false, the purge did
/// not happen and a "cold" run is mislabelled.
const String hbClearAllStorageJs = '(function(){'
    'try{localStorage.clear();}catch(e){}'
    'try{sessionStorage.clear();}catch(e){}'
    '})();';

/// Harvests navigation and resource timings from inside the page.
///
/// This is what settles the caching question per asset rather than by inference:
/// `transfer == 0` is a cache hit, a small `transfer` against a large `decoded` is a conditional
/// revalidation, and `transfer ~= encoded` is a full download. Aggregated in JavaScript before
/// returning, because the raw entry list is large and must not cross the channel mid-run.
String buildNavTimingJs(String runId) {
  final String r = jsonEncode(runId);
  return '(function(){'
      'try{'
      'var n=(performance.getEntriesByType("navigation")||[])[0]||{};'
      'var rs=performance.getEntriesByType("resource")||[];'
      'var top=rs.map(function(e){return{'
      'n:String(e.name).split("/").pop().split("?")[0],'
      'd:Math.round(e.duration),'
      'transfer:e.transferSize||0,'
      'encoded:e.encodedBodySize||0,'
      'decoded:e.decodedBodySize||0,'
      'status:(typeof e.responseStatus==="number"?e.responseStatus:null),'
      'init:e.initiatorType'
      '};})'
      '.sort(function(a,b){return b.d-a.d;}).slice(0,20);'
      '__hb($r,"navTiming",{'
      'dom:Math.round(n.domContentLoadedEventEnd||0),'
      'load:Math.round(n.loadEventEnd||0),'
      'resp:Math.round(n.responseEnd||0),'
      'count:rs.length,'
      'bytesTransfer:rs.reduce(function(a,e){return a+(e.transferSize||0);},0),'
      'bytesDecoded:rs.reduce(function(a,e){return a+(e.decodedBodySize||0);},0),'
      // The navigation entry is its own PerformanceResourceTiming and is excluded from
      // getEntriesByType("resource"), so a bundle inlined into the document response — as
      // opposed to fetched as a separate <script src>— would be invisible above without this.
      'docTransfer:n.transferSize||0,'
      'docDecoded:n.decodedBodySize||0,'
      'docEncoded:n.encodedBodySize||0,'
      'top:top'
      '});'
      '}catch(e){__hb($r,"navTimingFailed",String(e));}'
      '})();';
}

/// Reports the page environment, including the WebView version from the user agent.
///
/// A benchmark that does not record the WebView version is not reproducible: the System WebView
/// updates out of band and can move these numbers materially.
String buildEnvJs(String runId) {
  final String r = jsonEncode(runId);
  return '(function(){'
      'try{var c=navigator.connection||{};'
      '__hb($r,"env",{'
      'ua:navigator.userAgent,'
      'dpr:window.devicePixelRatio,'
      'cores:navigator.hardwareConcurrency||null,'
      'w:window.innerWidth,h:window.innerHeight,'
      'net:c.effectiveType||null,down:c.downlink||null'
      '});}catch(e){}'
      '})();';
}

/// Reports observable page state so an expectation can assert a real change.
///
/// Just seeing an operation "called" proves nothing — the page has several paths that accept a
/// call and then silently do nothing. Probing `tvWidget` for the symbol, resolution and bar count
/// turns those into detectable failures.
String buildProbeJs(String runId, String label) {
  final String r = jsonEncode(runId);
  final String l = jsonEncode(label);
  return '(function(){'
      'var out={label:$l};'
      'try{'
      'var A=window.ChartApp||{};'
      'out.version=(A.config&&A.config.version)||null;'
      'out.theme=null;try{out.theme=localStorage.getItem("chart.user.theme");}catch(e){}'
      'out.hasToken=false;try{out.hasToken=!!localStorage.getItem("chart.user.token");}catch(e){}'
      'var w=A.tvWidget;'
      'out.hasWidget=!!w;'
      'out.widgetReady=!!(w&&w._ready);'
      'if(w&&w._ready){'
      'try{var c=w.chart();'
      'out.symbol=c.symbol();'
      'out.resolution=c.resolution();'
      'try{out.bars=c.getSeries().data().bars()._items.length;}catch(e){out.bars=null;}'
      '}catch(e){out.chartErr=String(e&&e.message||e);}'
      '}'
      'try{out.charts=(w&&w.chartsCount)?w.chartsCount():null;}catch(e){}'
      // Ground truth for whether a tick can possibly render. Without these, a dead tick
      // stream is invisible: the page drops ticks silently when the symbol is not in the
      // map or no seed bar was ever cached.
      'try{out.symbolKeys=(A.data&&A.data.symbolInfoMap)?Array.from(A.data.symbolInfoMap.keys()):null;}catch(e){}'
      'try{out.barCacheKeys=(A.stream&&A.stream.data&&A.stream.data._lastBarCache)'
      '?Array.from(A.stream.data._lastBarCache.keys()):null;}catch(e){}'
      'try{out.subKeys=(A.stream&&A.stream.data&&A.stream.data._subscriptions)'
      '?Array.from(A.stream.data._subscriptions.keys()):null;}catch(e){}'
      'try{out.isMobileApp=(A.config?A.config.isMobileApp:null);}catch(e){}'
      'try{out.versionModified=(A.config?A.config.versionModified:null);}catch(e){}'
      '}catch(e){out.err=String(e&&e.message||e);}'
      '__hb($r,"probe",out);'
      '})();';
}

/// Injects a page operation, reporting whether the function existed, was called, threw, or
/// returned a promise that later settled.
///
/// [jsCall] is the call expression to evaluate, e.g. `v1.changeTheme("dark")`. [resolver] is the
/// expression yielding the callable to null-check first.
String buildOpJs({
  required String runId,
  required String op,
  required String resolver,
  required String jsCall,
}) {
  final String r = jsonEncode(runId);
  final String o = jsonEncode(op);
  return '(function(){'
      'try{'
      'var v1=(window.ChartApp&&window.ChartApp.v1)||{};'
      'var fn=$resolver;'
      'if(typeof fn!=="function"){__hb($r,$o+"Missing",null);return;}'
      'var res=$jsCall;'
      'if(res&&typeof res.then==="function"){'
      '__hb($r,$o+"Called","promise");'
      'res.then(function(){__hb($r,$o+"Resolved",null);},'
      'function(e){__hb($r,$o+"Rejected",String((e&&e.message)||e));});'
      '}else{__hb($r,$o+"Called","sync");}'
      '}catch(e){__hb($r,$o+"Threw",String((e&&e.message)||e));}'
      '})();';
}

/// Changes the page theme.
String buildChangeThemeJs(String runId, String theme) => buildOpJs(
      runId: runId,
      op: 'changeTheme',
      resolver: 'v1.changeTheme||window.ChangeTheme',
      jsCall: 'fn(${jsonEncode(theme)})',
    );

/// Changes the chart resolution.
String buildSetTimeFrameJs(String runId, String timeFrame) => buildOpJs(
      runId: runId,
      op: 'setTimeFrame',
      resolver: 'v1.setTimeFrame||window.SetTimeFrame',
      jsCall: 'fn(${jsonEncode(timeFrame)})',
    );

/// Changes the chart series type.
String buildChangeChartTypeJs(String runId, int chartTypeId) => buildOpJs(
      runId: runId,
      op: 'changeChartType',
      resolver: 'window.ChangeChartType',
      jsCall: 'fn($chartTypeId)',
    );

/// Pushes a live tick into the chart.
///
/// Argument order differs between the two entry points, which is itself worth exercising:
/// `AppendLiveTickV2(symbol, close, ltp, volume, tradeTime)` versus
/// `v1.appendLiveTick(symbol, ltp, close, volume, tradeTime)`.
String buildAppendTickJs(
  String runId,
  String symbol,
  double ltp,
  double close,
  int volume,
  int tradeTimeSeconds,
) =>
    buildOpJs(
      runId: runId,
      op: 'appendLiveTick',
      resolver: 'v1.appendLiveTick',
      jsCall: 'fn(${jsonEncode(symbol)},$ltp,$close,$volume,$tradeTimeSeconds)',
    );

/// Updates the ask/bid overlay.
String buildAskBidJs(String runId, String symbol, double ask, double bid) => buildOpJs(
      runId: runId,
      op: 'updateAskAndBid',
      resolver: 'window.UpdateAskAndBidValues',
      jsCall: 'fn(${jsonEncode(symbol)},$ask,$bid)',
    );

/// Fires a named chart event.
String buildChartEventsJs(String runId, String name) => buildOpJs(
      runId: runId,
      op: 'chartEvents',
      resolver: 'v1.ChartEvents||window.ChartEvents',
      jsCall: 'fn(${jsonEncode(name)})',
    );

/// Loads a chart with an explicit mode, for the mode-latch case.
///
/// The page latches the mode for the document's lifetime and silently returns on a mismatch, so
/// this is expected to produce a `loadChartCalled` with no chart terminal ever arriving.
String buildLoadChartModeJs(
  String runId,
  String symbol,
  String chartMode, {
  String theme = 'dark',
}) =>
    buildLoadChartJs(symbol, runId, chartMode: chartMode, theme: theme);


/// Drains the page's parked-401 queue without re-authorising.
///
/// The page parks a 401'd request and never settles its promise; only an authorize call drains
/// it. This is the one escape hatch that does not require a token, and it is not used by the host
/// app — a candidate recovery primitive.
String buildDrain401Js(String runId) {
  final String r = jsonEncode(runId);
  return '(function(){'
      'try{'
      'var h=window.ChartApp&&window.ChartApp.adapter&&window.ChartApp.adapter.chartHttp;'
      'if(!h||typeof h.Retry401ErrorApis!=="function"){__hb($r,"drain401Missing",null);return;}'
      'h.Retry401ErrorApis();'
      '__hb($r,"drain401Called","sync");'
      '}catch(e){__hb($r,"drain401Threw",String((e&&e.message)||e));}'
      '})();';
}

/// Makes the page emit an arbitrary message, to test the native parser.
///
/// Lets malformed and unexpected payloads be exercised without waiting for the page to
/// misbehave — including `context` values the page would never send.
String buildSyntheticMessageJs(String runId, Map<String, Object?> payload) {
  final String r = jsonEncode(runId);
  final String p = jsonEncode(jsonEncode(payload));
  return '(function(){'
      'try{'
      'var d=window.ChartAppDelegate;'
      'if(!d){__hb($r,"syntheticMissing",null);return;}'
      'd.postMessage($p);'
      '__hb($r,"syntheticCalled","sync");'
      '}catch(e){__hb($r,"syntheticThrew",String((e&&e.message)||e));}'
      '})();';
}
