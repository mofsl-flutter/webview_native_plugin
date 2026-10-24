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

/// JavaScript declaring `hbLib()`, which classifies every static asset the chart page loaded from
/// under `/chart/` (UAT, and the bundled page) or `/charts/` (production) as `hit`, `revalidated` or
/// `download`.
///
/// The charting library does not load its bundles into the top window: it builds an iframe and
/// writes the bundle `<script>` tags into that, so the entries live on the *iframe's* performance
/// timeline and a top-window-only harvest never sees the multi-megabyte library at all. This walks
/// the top window and every same-origin iframe; a cross-origin frame throws and is counted in
/// `blockedFrames` rather than silently dropped.
///
/// Classification, per entry:
/// * `hit` — `deliveryType == "cache"`, or nothing transferred yet a body was delivered. (A
///   cross-origin entry without `Timing-Allow-Origin` also reports 0 transferred, but it reports a
///   0 decoded size too, which is why the decoded check is there.)
/// * `revalidated` — headers only were transferred (< 1 KB) for a body of at least 2 KB: a `304`.
///   The 2 KB floor stops a tiny file that was fully downloaded being misread as a `304`.
/// * `opaque` — no size information at all, so it cannot be classified either way.
/// * `download` — anything else.
///
/// `capped` is set when any frame's timeline reached the default 250-entry buffer, since entries
/// past that are dropped by the browser and the counts would then be a lower bound.
const String _hbLibFnJs = 'function hbLib(){try{'
    'var out=[],blocked=0,frames=0,capped=false;'
    'var take=function(w,tag){'
    'var rs=w.performance.getEntriesByType("resource")||[];'
    'if(rs.length>=250)capped=true;'
    'for(var i=0;i<rs.length;i++){'
    'var e=rs[i],u;'
    // The chart API lives under the same prefix; only static assets are of interest. The prefix is
    // /chart/ on UAT and on the bundled page and /charts/ on production, so both are matched.
    'if(e.initiatorType==="xmlhttprequest"||e.initiatorType==="fetch")continue;'
    'try{u=new URL(e.name);}catch(x){continue;}'
    'var at=/\\/charts?\\//.exec(u.pathname);'
    'if(!at)continue;'
    'var t=e.transferSize||0,enc=e.encodedBodySize||0,dec=e.decodedBodySize||0;'
    'var c=(e.deliveryType==="cache"||(t===0&&dec>0))?"hit"'
    ':((t>0&&t<1024&&enc>=2048)?"revalidated"'
    // No size information at all: a cross-origin entry without Timing-Allow-Origin. Counting it as
    // a download would manufacture evidence either way, so it is kept apart.
    ':((t===0&&dec===0&&enc===0)?"opaque":"download"));'
    'out.push({f:tag,p:u.pathname.slice(at.index+at[0].length),h:u.href,st:e.startTime,c:c,transfer:t,encoded:enc,decoded:dec,'
    'd:Math.round(e.duration),'
    'status:(typeof e.responseStatus==="number"?e.responseStatus:null)});'
    '}};'
    'take(window,"top");frames++;'
    'var fs=document.querySelectorAll("iframe");'
    'for(var j=0;j<fs.length;j++){'
    'try{take(fs[j].contentWindow,"lib");frames++;}catch(x){blocked++;}'
    '}'
    'var s={hit:0,revalidated:0,download:0,opaque:0,bytesTransfer:0,bytesDecoded:0,'
    'entries:out.length,frames:frames,blockedFrames:blocked,capped:capped};'
    // Compact name -> class map for the heavy files only, so it survives a one-line logcat
    // record; the full list stays in `list`.
    'var key={};'
    'for(var k=0;k<out.length;k++){var o=out[k];s[o.c]++;'
    's.bytesTransfer+=o.transfer;s.bytesDecoded+=o.decoded;'
    'if(o.decoded>=30000)key[o.p.split("/").pop()]=o.c;}'
    'return{list:out.slice(0,150),all:out,summary:s,key:key};'
    '}catch(x){return{error:String((x&&x.message)||x)};}}';

/// Reports how the charting library's files were served, without the rest of the navigation
/// harvest, so it can be taken more than once in a run.
///
/// Taken a second time well after chart render it catches the lazily-loaded chunks that a
/// harvest at the terminal event misses.
String buildLibCacheJs(String runId, String label) {
  final String r = jsonEncode(runId);
  final String l = jsonEncode(label);
  return '(function(){'
      '$_hbLibFnJs'
      'try{var L=hbLib();'
      '__hb($r,"libCache",{label:$l,summary:L.summary||null,key:L.key||null,'
      'error:L.error||null});'
      '}catch(e){__hb($r,"libCache",{label:$l,error:String(e)});}'
      '})();';
}

/// Reports the full URL of every static file the chart page loaded under `/chart/`, query string
/// included, in the order they were requested.
///
/// The query string is part of the HTTP cache key, so a warm-up has to request `main.js?v=6`, not
/// `main.js`. This is how that list is captured from a real run, rather than guessed from the
/// page's source: the lazy chunks only show up once the chart is actually used.
///
/// With [includeDom] the URLs the page's own `<script src>` / `<link href>` elements name, in the
/// page and every same-origin frame, are added. Resource Timing is the primary source, but WebKit
/// records none for files served by a custom URL scheme (the bundled chart on iOS), so on its own
/// it would report an empty page. The elements say where each file was requested from on every
/// platform. Off by default: the capture script that writes the warm-up fixture wants exactly what
/// the network timeline saw.
String buildLibUrlsJs(String runId, {bool includeDom = false}) {
  final String r = jsonEncode(runId);
  final String domPass = includeDom
      ? 'var dom=0;'
          'var walk=function(w){try{'
          'var els=w.document.querySelectorAll("script[src],link[href]");'
          'for(var k=0;k<els.length;k++){'
          'var u=els[k].src||els[k].href;'
          'if(!u||!/\\/charts?\\//.test(u))continue;'
          'if(els[k].tagName==="LINK"&&!/stylesheet/i.test(els[k].rel||""))continue;'
          'if(!seen[u]){seen[u]=1;urls.push(u);dom++;}}'
          'var fs=w.document.querySelectorAll("iframe");'
          'for(var j=0;j<fs.length;j++){try{walk(fs[j].contentWindow);}catch(x){}}'
          '}catch(x){}};'
          'walk(window);'
      : 'var dom=null;';
  return '(function(){'
      '$_hbLibFnJs'
      'try{var L=hbLib();'
      'var all=(L.all||[]).slice().sort(function(a,b){return a.st-b.st;});'
      'var seen={},urls=[];'
      'for(var i=0;i<all.length;i++){var h=all[i].h;if(!seen[h]){seen[h]=1;urls.push(h);}}'
      '$domPass'
      '__hb($r,"libUrls",{urls:urls,domOnly:dom,error:L.error||null});'
      '}catch(e){__hb($r,"libUrls",{urls:[],error:String(e)});}'
      '})();';
}

/// Reports the chart data-API requests (`/chart/api/...`) the page has made since the previous
/// report, query strings included.
///
/// [_hbLibFnJs] deliberately skips fetch/XHR; this is its counterpart for the data calls. It
/// answers what the page source cannot: how many `HistoryV3` calls a first open really makes and
/// with which `countBack`/`from`/`to`, how large the bodies are, and how many `SaveChartData`
/// POSTs a pan produces. Resource Timing does not record the HTTP method, so POSTs are told apart
/// by path.
///
/// Entries are de-duplicated by `startTime|name` rather than by list position: the timeline is
/// ordered by start time but an entry only appears once its response completes, so a slow request
/// that started before the previous report would be skipped by an index cursor.
///
/// Sizes are readable only while the page and the API share an origin (true for the remote page;
/// a locally served page needs `Timing-Allow-Origin` on the API or they read 0).
String buildApiTraceJs(String runId, String label) {
  final String r = jsonEncode(runId);
  final String l = jsonEncode(label);
  return '(function(){'
      'try{'
      'try{performance.setResourceTimingBufferSize(2000);}catch(x){}'
      'var seen=window.__hbTraceSeen||(window.__hbTraceSeen={});'
      'var rs=performance.getEntriesByType("resource")||[];'
      'var out=[];'
      'for(var i=0;i<rs.length;i++){'
      'var e=rs[i];'
      'if(e.initiatorType!=="fetch"&&e.initiatorType!=="xmlhttprequest")continue;'
      'var k=Math.round(e.startTime)+"|"+e.name;'
      'if(seen[k])continue;'
      'var u;try{u=new URL(e.name);}catch(x){continue;}'
      // UAT serves the API under /chart/api/, production under /charts/api/.
      'var m=/\\/charts?\\/api\\//i.exec(u.pathname);'
      'if(!m)continue;'
      'seen[k]=1;'
      'out.push({h:u.host,p:u.pathname.slice(m.index+m[0].length),q:u.search.slice(1),'
      'st:Math.round(e.startTime),end:Math.round(e.responseEnd),'
      'transfer:e.transferSize||0,decoded:e.decodedBodySize||0,'
      'status:(typeof e.responseStatus==="number"?e.responseStatus:null)});'
      '}'
      'out.sort(function(a,b){return a.st-b.st;});'
      '__hb($r,"apiTrace",{label:$l,entries:out,total:rs.length,capped:rs.length>=250});'
      '}catch(e){__hb($r,"apiTrace",{label:$l,entries:[],error:String(e)});}'
      '})();';
}

/// Changes the full chart's resolution through the widget, resolving when its data has loaded.
///
/// `v1.setTimeFrame` cannot be used: it is wired to the *compact* chart only, so on a full chart
/// it would silently do nothing.
String buildSetResolutionJs(String runId, String resolution) => buildOpJs(
      runId: runId,
      op: 'setResolution',
      resolver: '(function(res){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'return new Promise(function(ok){w.activeChart().setResolution(res,ok);});'
          '})',
      jsCall: 'fn(${jsonEncode(resolution)})',
    );

/// Measures what one `tvWidget.save()` costs: wall time to serialise the chart and the size of the
/// JSON the page then POSTs. Stashed on `window.__hbSaveCost` and read back by [buildProbeJs],
/// because an op's promise resolves with no value to report.
String buildSaveCostJs(String runId) => buildOpJs(
      runId: runId,
      op: 'saveCost',
      resolver: '(function(){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'return new Promise(function(ok){'
          'var t=performance.now();'
          'w.save(function(o){'
          'var s=JSON.stringify(o);'
          'window.__hbSaveCost={ms:Math.round((performance.now()-t)*10)/10,bytes:s.length};'
          'ok();});'
          '});'
          '})',
      jsCall: 'fn()',
    );

/// Makes the page's first history answer lose its last [dropBars] candles, as if live ticks had
/// stopped that many bars before the chart opened, so a fill has something real to fetch.
///
/// Installed after the page is ready and before it is told to load: the page's history adapter is
/// wrapped for exactly one first request, whose answer loses its last bars, and then put back. The
/// bars stay on the server, which is what makes a later fill a real test. Stashes
/// `{dropped, fullLastMs, truncatedLastMs, fullBars}` on `window.__hbGap` when that answer arrives,
/// read back by [buildProbeJs].
String buildHideLastBarsJs(int dropBars) => '(function(n){'
    'var h=window.ChartApp&&window.ChartApp.adapter&&window.ChartApp.adapter.chartHttp;'
    'if(!h)return;'
    'var orig=h.getData;'
    'h.getData=function(t,r,f,to,cb,firstReq){'
    'var p=orig.apply(this,arguments);'
    'if(!firstReq)return p;'
    'return p.then(function(bars){'
    'h.getData=orig;'
    'if(bars.length>n){'
    'window.__hbGap={dropped:n,fullLastMs:bars[bars.length-1].time,'
    'truncatedLastMs:bars[bars.length-n-1].time,fullBars:bars.length};'
    'return bars.slice(0,bars.length-n);}'
    'window.__hbGap={dropped:0,fullBars:bars.length,note:"too few bars to hide"};'
    'return bars;});};'
    '})($dropBars);';

/// Exports the candles the chart actually holds around the last bar the page knew of, and stashes a
/// summary on `window.__hbBars`: how many rows, the first and last times (seconds), whether times
/// strictly increase, the last dozen, and the time of the stream's last bar.
///
/// Reads the library's own data through its public `exportData`, not the page's bookkeeping, because
/// the point is what the chart would draw. Anchored on `window.__hbGap.fullLastMs` when a gap was
/// set up, so a census before and after a fill covers the same stretch of time.
String buildBarCensusJs(String runId) => buildOpJs(
      runId: runId,
      op: 'barCensus',
      resolver: '(function(){'
          'var A=window.ChartApp,w=A&&A.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'var item=Array.from(A.stream.data._subscriptions.values())[0];'
          'var streamLast=item&&item.lastDailyBar?item.lastDailyBar.time:null;'
          'var anchor=(window.__hbGap&&window.__hbGap.fullLastMs)||streamLast||Date.now();'
          'return w.activeChart().exportData({from:Math.floor((anchor-86400000*10)/1000),'
          'to:Math.ceil(Date.now()/1000)+3600,includeTime:true,includeSeries:true,includedStudies:[]})'
          '.then(function(d){'
          'var times=d.data.map(function(r){return r[0];});'
          'window.__hbBars={rows:times.length,firstSec:times.length?times[0]:null,'
          'lastSec:times.length?times[times.length-1]:null,'
          'strictlyIncreasing:times.every(function(t,i){return i===0||t>times[i-1];}),'
          'tail:times.slice(-12),streamLastMs:streamLast};'
          '});'
          '})',
      jsCall: 'fn()',
    );

/// Counts calls to the page's `RemoveLegendHiddenClasses` (its legend un-hiding poll) from now on,
/// in `window.__hbLegend`, by wrapping it. Wrapping, not replacing: the real work still runs.
String buildLegendCounterJs(String runId) => buildOpJs(
      runId: runId,
      op: 'countLegendPolls',
      resolver: '(function(){'
          'var h=window.ChartApp&&window.ChartApp.adapter&&window.ChartApp.adapter.chartHttp;'
          'if(!h||typeof h.RemoveLegendHiddenClasses!=="function")throw new Error("no poll");'
          'if(!h.__hbWrapped){'
          'var orig=h.RemoveLegendHiddenClasses;window.__hbLegend=0;window.__hbLegendMs=0;'
          'h.RemoveLegendHiddenClasses=function(){window.__hbLegend++;var t=performance.now();'
          'try{return orig.apply(this,arguments);}finally{window.__hbLegendMs+=performance.now()-t;}};'
          'h.__hbWrapped=true;}'
          '})',
      jsCall: 'fn()',
    );

/// Removes the indicators named in [names] (comma separated) from the active chart, every copy.
///
/// The page saves the chart layout to the server whenever it changes, so an indicator a test adds
/// is still there on the next open unless it is removed. Named, never "all": the Volume pane is the
/// chart's own and must stay.
String buildRemoveStudiesJs(String runId, String names) => buildOpJs(
      runId: runId,
      op: 'removeStudies',
      resolver: '(function(csv){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'var c=w.activeChart();var names=csv.split(",");'
          'var all=c.getAllStudies().filter(function(s){return names.indexOf(s.name)>=0;});'
          'all.forEach(function(s){c.removeEntity(s.id);});'
          'return Promise.resolve(all.length);'
          '})',
      jsCall: 'fn(${jsonEncode(names)})',
    );

/// Makes the page's network calls fail, asks its adapter for a symbol, and records what the adapter
/// did within three seconds: `rejected: <message>`, `resolved`, or `hung`.
///
/// A promise that never settles is how a failed request used to leave the chart spinning forever;
/// one that rejects lets the chart report "no data". Stored on `window.__hbNet` for [buildProbeJs],
/// since an op's promise resolves with no value. `fetch` is put back afterwards.
String buildNetworkFailureJs(String runId) => buildOpJs(
      runId: runId,
      op: 'networkFailure',
      resolver: '(function(){'
          'var a=window.ChartApp&&window.ChartApp.adapter&&window.ChartApp.adapter.chartHttp;'
          'if(!a)throw new Error("no adapter");'
          'var orig=window.fetch;'
          'window.fetch=function(){return Promise.reject(new TypeError("Failed to fetch"));};'
          'return new Promise(function(ok){'
          'var settled=false;'
          'var finish=function(v){if(settled)return;settled=true;window.__hbNet=v;window.fetch=orig;ok();};'
          'setTimeout(function(){finish("hung");},3000);'
          'a.symbolInfo("0:NETFAIL").then(function(){finish("resolved");},'
          'function(e){finish("rejected: "+((e&&e.message)||e));});'
          '});'
          '})',
      jsCall: 'fn()',
    );

/// Adds an indicator by name. Most indicators (RSI, MACD) get a pane of their own, which makes the
/// page re-run its `panes_order_changed` handler.
String buildAddStudyJs(String runId, String name) => buildOpJs(
      runId: runId,
      op: 'addStudy',
      resolver: '(function(name){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'return w.activeChart().createStudy(name,false,false);'
          '})',
      jsCall: 'fn(${jsonEncode(name)})',
    );

/// Moves the visible window three spans into the past, which forces the library to ask the
/// datafeed for older bars (`getBars` with `firstDataRequest=false`).
String buildScrollBackJs(String runId) => buildOpJs(
      runId: runId,
      op: 'scrollBack',
      resolver: '(function(){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'var c=w.activeChart();var r=c.getVisibleRange();var s=r.to-r.from;'
          'return c.setVisibleRange({from:r.from-3*s,to:r.to-3*s});'
          '})',
      jsCall: 'fn()',
    );

/// Pans the visible window back and forth for ten seconds at ~4 Hz, to count the save traffic a
/// pan generates.
///
/// The window only ever moves toward the (empty) future, so it never asks for history and the
/// request count isolates saves. It returns at once and the timer runs on; the scenario waits out
/// the ten seconds itself, because an acknowledgement would have to outlast the ack timeout.
///
/// A finger drag fires range changes far faster than 4 Hz, so the count this yields is a lower
/// bound for real use.
String buildPanZoomJs(String runId) => buildOpJs(
      runId: runId,
      op: 'panZoom',
      resolver: '(function(){'
          'var w=window.ChartApp&&window.ChartApp.tvWidget;'
          'if(!w)throw new Error("no tvWidget");'
          'var c=w.activeChart();var r=c.getVisibleRange();var step=(r.to-r.from)/50;'
          // Count the chart's own range events, so a trace of SaveChartData POSTs can be set against
          // what triggered them. One counter listener, added once.
          'if(!window.__hbRangeSub){window.__hbRange=0;window.__hbRangeSub=true;'
          'c.onVisibleRangeChanged().subscribe(null,function(){window.__hbRange++;});}'
          'var n=0,k=0,dir=1;'
          'var t=setInterval(function(){'
          'n++;if(n>40){clearInterval(t);return;}'
          'k+=dir;if(k>=10||k<=0)dir=-dir;'
          'c.setVisibleRange({from:r.from+k*step,to:r.to+k*step});'
          '},250);'
          '})',
      jsCall: 'fn()',
    );

/// Harvests navigation and resource timings from inside the page.
///
/// This is what settles the caching question per asset rather than by inference:
/// `transfer == 0` is a cache hit, a small `transfer` against a large `decoded` is a conditional
/// revalidation, and `transfer ~= encoded` is a full download. Aggregated in JavaScript before
/// returning, because the raw entry list is large and must not cross the channel mid-run.
///
/// The top-window fields (`top`, `count`, `bytes*`) are unchanged. `lib`, `libSummary` and
/// `libKey` are added from [_hbLibFnJs] so the charting library, which loads in an iframe, is
/// finally visible.
String buildNavTimingJs(String runId) {
  final String r = jsonEncode(runId);
  return '(function(){'
      '$_hbLibFnJs'
      'try{'
      'var n=(performance.getEntriesByType("navigation")||[])[0]||{};'
      'var rs=performance.getEntriesByType("resource")||[];'
      'var L=hbLib();'
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
      'lib:L.list||null,libSummary:L.summary||null,libKey:L.key||null,libError:L.error||null,'
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
      'try{var pl=window.ChartApp&&window.ChartApp.preload;out.preload=pl&&pl.stats?pl.stats():null;}catch(e){out.preload=null;}'
      'out.gap=window.__hbGap||null;out.census=window.__hbBars||null;'
      'try{out.fills=Array.from(A.stream.data.fills.entries());}catch(e){out.fills=null;}'
      'out.rangeEvents=window.__hbRange||0;out.net=window.__hbNet||null;out.saveCost=window.__hbSaveCost||null;out.legendPolls=window.__hbLegend||0;out.legendMs=Math.round((window.__hbLegendMs||0)*10)/10;'
      'try{out.studies=w&&w._ready?w.activeChart().getAllStudies().map(function(s){return s.name;}):null;}catch(e){out.studies=null;}'
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
