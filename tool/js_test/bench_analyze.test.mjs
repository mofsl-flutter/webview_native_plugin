// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
//
// example/tool/bench/analyze.mjs turns the HBRESULT lines the harness prints (one file per app launch)
// into the tables the timing comparison is read from. The fixtures below are real result lines from
// the emulator, so a change to the harness's output format breaks these tests instead of quietly
// producing a table of zeros.
import test from "node:test";
import assert from "node:assert/strict";

import { parseFileName, parseRun, summarize, median } from "../../example/tool/bench/analyze.mjs";

const BUNDLED_COLD = [
  "HBRESULT\tO1\tPASS\tBundled chart: open the symbol given by CHART_SYMBOL\tmetrics: nav=950.0ms doc=363.0ms jsBoot=337.0ms gate=17.1ms authRtt=13.0ms render=3580.0ms e2e=4823.0ms req=16 xfer=0.0 KB dec=0.0 KB docXfer=0.3 KB docDec=0.0 KB lib=h119/r0/d0/o0 xfer=0.0 KB/0.0 KBdec tail=0 stray=0",
  "HBRESULT\tO1\tEVIDENCE\topen.1\tprefetch=false outcome=chartSuccess authorizeRtt=13000 chartRender=3580000 endToEnd=4823000",
  "HBRESULT\tO1\tEVIDENCE\tprobe.opened\tsymbol=IDX:1:SENSEX resolution=1 bars=300 widgetReady=true hasToken=true",
  "HBRESULT\t__DONE__\t1/1 passed",
].join("\n");

// The hosted run's result line says FAIL because the case wants CHART_LOCAL; the open itself is fine.
const HOSTED_COLD = [
  "HBRESULT\tO1\tFAIL\tBundled chart: open the symbol given by CHART_SYMBOL\tFAIL  the harness was started with CHART_LOCAL=true\tmetrics: nav=1549.0ms doc=373.7ms jsBoot=363.5ms gate=17.1ms authRtt=2.8ms render=3716.1ms e2e=5648.8ms req=13 xfer=242.3 KB dec=345.0 KB docXfer=1.7 KB docDec=1.4 KB lib=h0/r0/d116/o0 xfer=4.90 MB/4.87 MBdec tail=0 stray=0",
  "HBRESULT\tO1\tEVIDENCE\topen.1\tprefetch=false outcome=chartSuccess authorizeRtt=2798 chartRender=3716089 endToEnd=5648782",
  "HBRESULT\tO1\tEVIDENCE\tprobe.opened\tsymbol=IDX:1:SENSEX resolution=1 bars=300 widgetReady=true hasToken=true",
  "HBRESULT\t__DONE__\t0/1 passed",
].join("\n");

test("reads the metrics of a bundled run", () => {
  const r = parseRun(BUNDLED_COLD);

  assert.equal(r.ok, true);
  assert.equal(r.e2e, 4823);
  assert.equal(r.nav, 950);
  assert.equal(r.doc, 363);
  assert.equal(r.jsBoot, 337);
  assert.equal(r.authRtt, 13);
  assert.equal(r.render, 3580);
  assert.equal(r.req, 16);
  assert.deepEqual(r.lib, { hit: 119, revalidated: 0, download: 0, opaque: 0, netMB: 0 });
  assert.equal(r.outcome, "chartSuccess");
  assert.equal(r.bars, 300);
});

test("reads a hosted run, whose result line says FAIL for an unrelated reason, by its open", () => {
  const r = parseRun(HOSTED_COLD);

  assert.equal(r.ok, true, "the open succeeded; the FAIL is the CHART_LOCAL expectation");
  assert.equal(r.e2e, 5648.8);
  assert.deepEqual(r.lib, { hit: 0, revalidated: 0, download: 116, opaque: 0, netMB: 4.9 });
});

test("an open that did not end in success is not a usable timing", () => {
  const r = parseRun(BUNDLED_COLD.replace("outcome=chartSuccess", "outcome=chartErrorSymbolNotFound"));

  assert.equal(r.ok, false);
  assert.match(r.why, /chartErrorSymbolNotFound/);
});

test("a run that never finished says so", () => {
  const r = parseRun(BUNDLED_COLD.split("\n").slice(0, 0).join("\n"));
  assert.equal(r.ok, false);
  assert.match(r.why, /no metrics/i);

  const noDone = parseRun(BUNDLED_COLD.replace(/\nHBRESULT\t__DONE__.*/, ""));
  assert.equal(noDone.ok, false);
  assert.match(noDone.why, /never finished/i);
});

test("a result with missing fields is not read as zeros", () => {
  const r = parseRun(BUNDLED_COLD.replace(" e2e=4823.0ms", ""));

  assert.equal(r.ok, false);
  assert.match(r.why, /e2e/);
});

test("a dash (a phase that was never reached) is a missing value, not a number", () => {
  const r = parseRun(BUNDLED_COLD.replace("render=3580.0ms", "render=-"));

  assert.equal(r.ok, false);
  assert.match(r.why, /render/);
});

test("a phase that finished a hair before its start event was logged is a small negative number, not a missing one", () => {
  // Seen on a hosted warm run: the page announced itself 1.4 ms before the navigation event arrived.
  const r = parseRun(BUNDLED_COLD.replace("jsBoot=337.0ms", "jsBoot=-1.4ms"));

  assert.equal(r.ok, true);
  assert.equal(r.jsBoot, -1.4);
  assert.equal(r.e2e, 4823, "the rest of the run is read as usual");
});

test("a lone dash is still a missing value, and so is a bare minus sign", () => {
  assert.equal(parseRun(BUNDLED_COLD.replace("jsBoot=337.0ms", "jsBoot=-")).ok, false);
  assert.equal(parseRun(BUNDLED_COLD.replace("jsBoot=337.0ms", "jsBoot=-ms")).ok, false);
});

test("kilobytes and megabytes of transfer are both read as megabytes", () => {
  assert.equal(parseRun(HOSTED_COLD.replace("xfer=4.90 MB/4.87 MBdec", "xfer=512.0 KB/1.0 MBdec")).lib.netMB, 0.5);
});

test("file names carry the block, variant, scenario, cache state and run number", () => {
  assert.deepEqual(parseFileName("H1__hosted_pre__O1__cold__3.tsv"), {
    block: "H1",
    variant: "hosted_pre",
    scenario: "O1",
    cache: "cold",
    n: 3,
  });
  assert.equal(parseFileName("H1__hosted_pre__O1__prime__0.tsv").cache, "prime");
  assert.equal(parseFileName("H1__hosted_pre__O1__lukewarm__3.tsv"), null, "only cold, warm and prime exist");
  assert.equal(parseFileName("notes.txt"), null);
  assert.equal(parseFileName("a__b__c__d.tsv"), null);
});

test("the median of an even count is the mean of the middle two, and of nothing is NaN", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 3, 2]), 2.5);
  assert.equal(median([7]), 7);
  assert.ok(Number.isNaN(median([])));
});

const run = (variant, cache, block, e2e, extra = {}) => ({
  block, variant, scenario: "O1", cache, n: 1, ok: true, e2e, nav: 1, doc: 1, jsBoot: 1, authRtt: 1, render: 1, req: 10,
  lib: { hit: 0, revalidated: 0, download: 0, opaque: 0, netMB: 0 }, ...extra,
});

test("summarizes per variant and cache state, and drops the priming run", () => {
  const rows = summarize([
    run("hosted_pre", "cold", "H1", 6000),
    run("hosted_pre", "cold", "H2", 6200),
    run("hosted_pre", "warm", "H1", 2900),
    run("hosted_pre", "prime", "H1", 9000),
    run("bundled_pre", "cold", "B1", 4800),
  ]);

  const hostedCold = rows.find((r) => r.variant === "hosted_pre" && r.cache === "cold");
  assert.equal(hostedCold.n, 2);
  assert.equal(hostedCold.e2e.median, 6100);
  assert.equal(hostedCold.e2e.min, 6000);
  assert.equal(hostedCold.e2e.max, 6200);
  assert.equal(rows.some((r) => r.cache === "prime"), false, "the priming launch only fills the cache");
  assert.equal(rows.length, 3);
});

test("two scenarios of the same variant are two rows, never one blended number", () => {
  const rows = summarize([
    run("bundled_pre", "warm", "B1", 4000),
    run("bundled_pre", "warm", "B1", 2000, { scenario: "O2" }),
  ]);

  assert.equal(rows.length, 2);
  assert.deepEqual(rows.map((r) => [r.scenario, r.e2e.median]).sort(), [["O1", 4000], ["O2", 2000]]);
});

test("also gives the median without the slowest run, the baseline file's convention", () => {
  const rows = summarize([2000, 2100, 2200, 9000].map((e, i) => run("v", "cold", `B${i}`, e)));

  assert.equal(rows[0].e2e.median, 2150);
  assert.equal(rows[0].e2e.medianWithoutSlowest, 2100);
});

test("unusable runs are counted and left out of every statistic", () => {
  const rows = summarize([run("v", "cold", "B1", 4000), run("v", "cold", "B2", 0, { ok: false, why: "x" })]);

  assert.equal(rows[0].n, 1);
  assert.equal(rows[0].unusable, 1);
  assert.equal(rows[0].e2e.median, 4000);
});

test("reports each block's median so drift between blocks is visible", () => {
  const rows = summarize([run("v", "cold", "B1", 4000), run("v", "cold", "B1", 4200), run("v", "cold", "B2", 5000)]);

  assert.deepEqual(rows[0].byBlock, { B1: 4100, B2: 5000 });
});
