// Not a test file: the Dart test (test/chart_prefetch_test.dart) runs it to check that the scripts
// ChartPrefetch generates work against the page's real preload store.
//
// stdin:  {"scripts": ["...", ...], "takes": [{"op":"take","kind","key","maxAgeMs"} |
//                                              {"op":"history","request":{...}}]}
// stdout: {"results": [{"found": bool, "body": <parsed json> | null}, ...], "stats": {...}}
//
// Scripts run in order, in a page-like context (window.ChartApp, no other globals), exactly as the
// plugin's runJavaScript would run them.
import fs from "node:fs";
import vm from "node:vm";

const input = JSON.parse(fs.readFileSync(0, "utf8"));
const source = fs.readFileSync(new URL("../../../assets/chart/v4/js/core/preload.js", import.meta.url), "utf8");

const window = {};
window.window = window;
window.ChartApp = {};
const context = vm.createContext(window);
vm.runInContext(source.replace("})(window, ChartApp);", "})(window, window.ChartApp);"), context);

for (const script of input.scripts) vm.runInContext(script, context);

const results = [];
for (const t of input.takes) {
  const response = t.op === "history"
    ? await window.ChartApp.preload.takeHistory(t.request)
    : await window.ChartApp.preload.take(t.kind, t.key, { maxAgeMs: t.maxAgeMs });
  results.push({ found: response !== undefined, body: response ? JSON.parse(JSON.stringify(await response.json())) : null });
}
console.log(JSON.stringify({ results, stats: window.ChartApp.preload.stats() }));
