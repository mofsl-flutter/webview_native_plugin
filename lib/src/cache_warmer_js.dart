import "dart:convert";

/// Builds the JavaScript that warms the WebView's HTTP cache.
///
/// One copy of this script serves both platforms. Native creates a throwaway WebView on the chart's
/// origin, runs the script there, and receives its single JSON report through a bridge
/// (`__WarmBridge.report` on Android, the `warmBridge` message handler on iOS).
///
/// The script has to run *inside* a WebView, not in Dart: a Dart download would fill a different
/// cache from the one the chart page later reads. It fetches every file with the same request
/// shape the library's own `<script crossorigin="anonymous">` tags use (`cors`, same-origin
/// credentials), so the entries it writes are the ones the chart will look up.
///
/// Behaviour worth knowing:
/// * Each response body is read to the end. Chromium writes a cache entry as the body is consumed,
///   so an abandoned response leaves nothing usable behind. The body is read in chunks and
///   discarded, so a 2.76 MB bundle is never held in memory.
/// * Files are fetched by a small worker pool. Concurrency is the only lever that protects
///   whatever else the app is doing on the network: `priority: 'low'` only reorders requests
///   inside this one WebView.
/// * `window.__warmStop = true` stops new fetches. Those already in flight finish, so their
///   entries stay valid.
/// * The report carries `origin`, so a caller can detect a page that did not get the chart origin
///   (which would silently fill the wrong cache partition).
String buildWarmerScript({
  required String baseUrl,
  String manifestPath = "chart-lib-manifest.json",
  List<String>? urls,
  int concurrency = 3,
}) {
  final String config = jsonEncode(<String, Object?>{
    "base": baseUrl,
    "manifestPath": manifestPath,
    "urls": urls,
    "concurrency": concurrency,
  })
      // Safe to embed in an HTML <script> block as well as to evaluate directly.
      .replaceAll("<", r"\u003c");
  return _template.replaceFirst("__CONFIG__", config);
}

/// Wraps [script] in a minimal HTML document, for platforms and modes that load a string.
String buildWarmerHtml(String script) => "<!doctype html><html><head><meta charset='utf-8'>"
    "</head><body><script>$script</script></body></html>";

const String _template = r"""
(function (cfg) {
  if (window.__warmStarted) { return; }
  window.__warmStarted = true;
  window.__warmStop = false;

  var reported = false;
  var failed = {};
  var t0 = Date.now();
  var report = {
    ok: false, reason: null, origin: String(location.origin), manifestVersion: null,
    files: 0, stopped: false, durationMs: 0, bytesTransfer: 0, bytesDecoded: 0,
    counts: { hit: 0, revalidated: 0, download: 0, opaque: 0, failed: 0 }, errors: []
  };

  function note(m) {
    if (report.errors.length < 10) { report.errors.push(String(m).slice(0, 200)); }
  }

  function post() {
    if (reported) { return; }
    reported = true;
    report.durationMs = Date.now() - t0;
    var s = JSON.stringify(report);
    try {
      if (window.__WarmBridge && window.__WarmBridge.report) {
        window.__WarmBridge.report(s);
      } else if (window.webkit && window.webkit.messageHandlers &&
                 window.webkit.messageHandlers.warmBridge) {
        window.webkit.messageHandlers.warmBridge.postMessage(s);
      }
    } catch (e) {}
  }

  function fail(reason, e) {
    report.ok = false;
    report.reason = reason;
    if (e) { note((e && e.message) || e); }
    post();
  }

  async function drain(u) {
    var r = await fetch(u, { mode: 'cors', credentials: 'same-origin', priority: 'low' });
    if (!r.ok) { throw new Error('HTTP ' + r.status); }
    if (r.body && r.body.getReader) {
      var rd = r.body.getReader();
      for (;;) {
        var c = await rd.read();
        if (c.done) { break; }
      }
    } else {
      await r.arrayBuffer();
    }
  }

  // Same classification the harness uses for the page's own resources.
  function classify(urls) {
    for (var i = 0; i < urls.length; i++) {
      if (failed[urls[i]]) { continue; }
      var es = performance.getEntriesByName(urls[i], 'resource');
      var e = es.length ? es[es.length - 1] : null;
      if (!e) { report.counts.opaque++; continue; }
      var t = e.transferSize || 0, enc = e.encodedBodySize || 0, dec = e.decodedBodySize || 0;
      var c = (e.deliveryType === 'cache' || (t === 0 && dec > 0)) ? 'hit'
        : ((t > 0 && t < 1024 && enc >= 2048) ? 'revalidated'
        : ((t === 0 && dec === 0 && enc === 0) ? 'opaque' : 'download'));
      report.counts[c]++;
      report.bytesTransfer += t;
      report.bytesDecoded += dec;
    }
  }

  async function run() {
    try { performance.setResourceTimingBufferSize(1000); } catch (e) {}

    var urls = cfg.urls;
    if (!urls) {
      var manifestUrl = new URL(cfg.manifestPath, cfg.base).href;
      var mr;
      try {
        mr = await fetch(manifestUrl, { cache: 'no-cache', mode: 'cors', credentials: 'same-origin' });
      } catch (e) { return fail('manifest unreachable', e); }
      if (mr.status === 404) { return fail('manifest missing'); }
      if (!mr.ok) { return fail('manifest http ' + mr.status); }
      var m;
      try { m = await mr.json(); } catch (e) { return fail('manifest invalid', e); }
      if (!m || !Array.isArray(m.files)) { return fail('manifest invalid'); }
      report.manifestVersion = (m.version === undefined || m.version === null) ? null : String(m.version);
      var files = m.files.filter(function (f) { return f && typeof f.path === 'string'; });
      // Critical files first, otherwise the manifest's own order.
      var crit = files.filter(function (f) { return f.critical; });
      var rest = files.filter(function (f) { return !f.critical; });
      urls = crit.concat(rest).map(function (f) { return f.path; });
    }

    urls = urls.map(function (p) { return new URL(p, cfg.base).href; });
    urls = urls.filter(function (u, i) { return urls.indexOf(u) === i; });
    report.files = urls.length;
    if (!urls.length) { return fail('manifest empty'); }

    var queue = urls.slice();
    async function worker() {
      while (queue.length && !window.__warmStop) {
        var u = queue.shift();
        try {
          await drain(u);
        } catch (e) {
          failed[u] = true;
          report.counts.failed++;
          note(u.split('/').pop() + ': ' + ((e && e.message) || e));
        }
      }
    }
    var n = Math.max(1, Math.min(cfg.concurrency | 0 || 3, 6));
    var pool = [];
    for (var i = 0; i < n; i++) { pool.push(worker()); }
    await Promise.all(pool);

    report.stopped = window.__warmStop === true && queue.length > 0;
    // Resource Timing entries are queued asynchronously after the last body is read.
    await new Promise(function (r) { setTimeout(r, 100); });
    classify(urls);

    report.ok = !report.stopped && report.counts.failed === 0;
    if (report.stopped) { report.reason = 'stopped'; }
    else if (report.counts.failed) { report.reason = 'some files failed'; }
    post();
  }

  run().catch(function (e) { fail('exception', e); });
})(__CONFIG__);
""";
