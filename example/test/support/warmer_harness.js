// Runs the generated cache-warm script against a mocked network and prints what happened.
//   node warmer_harness.js <script.js> <scenario.json>
// The scenario describes routes (url -> {status|reject|chunks|json}), Resource Timing entries
// (perf: url -> entry fields) and options (delayMs, stopOnFirstFile, runTwice).
const fs = require('fs');
const [, , scriptPath, scenarioPath] = process.argv;
const sc = JSON.parse(fs.readFileSync(scenarioPath, 'utf8'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const log = { fetches: [], inFlight: 0, maxInFlight: 0, drained: {}, reports: [] };
const isManifest = (u) => /manifest/.test(u);
const begin = (u) => { log.inFlight++; log.maxInFlight = Math.max(log.maxInFlight, log.inFlight); };
const end = () => { log.inFlight--; };

global.window = global;
global.location = { origin: sc.origin || 'https://h.example' };
global.__WarmBridge = { report: (s) => log.reports.push(JSON.parse(s)) };
Object.defineProperty(global, 'performance', {
  configurable: true, writable: true,
  value: {
    setResourceTimingBufferSize() {},
    getEntriesByName: (u) => (sc.perf && sc.perf[u] ? [Object.assign({ name: u }, sc.perf[u])] : []),
  },
});

global.fetch = async (url, opts) => {
  url = String(url);
  log.fetches.push({ url, mode: opts && opts.mode, credentials: opts && opts.credentials,
                     cache: opts && opts.cache, priority: opts && opts.priority });
  begin(url);
  await sleep(sc.delayMs === undefined ? 3 : sc.delayMs);
  if (sc.stopOnFirstFile && !isManifest(url)) { global.__warmStop = true; }
  const spec = sc.routes[url];
  if (!spec) { end(); return { ok: false, status: 404 }; }
  if (spec.reject) { end(); throw new Error('network down'); }
  if (spec.status && spec.status !== 200) { end(); return { ok: false, status: spec.status }; }
  if (spec.json !== undefined) {
    return { ok: true, status: 200, async json() { end(); return spec.json; } };
  }
  let i = 0;
  const chunks = spec.chunks === undefined ? 3 : spec.chunks;
  return {
    ok: true, status: 200,
    body: { getReader() { return { async read() {
      await sleep(0);
      if (i >= chunks) { log.drained[url] = true; end(); return { done: true }; }
      i++; return { done: false, value: new Uint8Array(8) };
    } }; } },
  };
};

(async () => {
  const code = fs.readFileSync(scriptPath, 'utf8');
  (0, eval)(code);
  if (sc.runTwice) { (0, eval)(code); }
  for (let t = 0; t < 400 && log.reports.length === 0; t++) { await sleep(10); }
  await sleep(50);
  process.stdout.write(JSON.stringify({
    reports: log.reports, fetches: log.fetches, maxInFlight: log.maxInFlight, drained: log.drained,
  }));
})();
