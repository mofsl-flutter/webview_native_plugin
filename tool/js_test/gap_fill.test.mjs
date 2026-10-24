// Run with: node --test tool/js_test/*.test.mjs
//
// The candles a gap in live ticks leaves behind (stream.js: fillGaps, and the hold on a tick that
// jumps a gap). The page's own stream.js runs in a vm with a clock the test controls and a fake
// history source.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(
  new URL("../../assets/chart/v4/js/core/stream.js", import.meta.url),
  "utf8",
);

const MIN = 60 * 1000;
const T0 = Date.UTC(2026, 9, 23, 4, 0, 0); // a minute boundary

const bar = (time, close, extra = {}) => ({
  time, open: close, high: close, low: close, close, volume: 0, ...extra,
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}

/** Lets every promise chain that can settle, settle. */
const settle = () => new Promise((resolve) => setImmediate(resolve));

/**
 * Loads stream.js as the page would, with a history source whose answer the test decides.
 * `source.answer` is called with the request and returns bars, a promise of them, or throws.
 */
function load({ withSource = true } = {}) {
  const chartApp = { quote: { publishQuote() {} } };
  const logger = { debug() {}, warn() {}, error() {} };
  vm.runInNewContext(SOURCE, {
    window: {}, setTimeout, clearTimeout,
    log: { getLogger: () => logger }, ChartApp: chartApp,
  });
  const stream = chartApp.stream;
  const clock = { now: T0 };
  stream.gap.now = () => clock.now;
  const source = { requests: [], answer: () => [] };
  if (withSource) {
    stream.setHistorySource((ticker, resolution, fromSec, toSec, countBack) => {
      source.requests.push({ ticker, resolution, fromSec, toSec, countBack });
      return source.answer({ ticker, resolution, fromSec, toSec, countBack });
    });
  }
  return { stream, clock, source };
}

/** Subscribes and seeds the last bar, as the datafeed does after getBars. */
function subscribe(stream, ticker, resolution, guid, seed = bar(T0, 100)) {
  stream.saveBar(ticker, resolution, seed);
  const seen = [];
  stream.subscribe(ticker, resolution, guid, (b) => seen.push(b));
  return seen;
}

const lastBarOf = (stream, ticker) => stream.getV2(ticker)[0].lastDailyBar;

test("the bars a gap left are fed in order, and become the last bar", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5.5 * MIN;
  const server = [0, 1, 2, 3, 4, 5].map((k) => bar(T0 + k * MIN, 100 + k, { volume: 10 }));
  source.answer = () => server;

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "filled");
  assert.equal(result.fetched, 6);
  assert.equal(result.fed, 6);
  assert.deepEqual(seen.map((b) => b.time), server.map((b) => b.time));
  assert.equal(seen[0].close, 100, "the closed bar the chart already had is replaced by history's");
  assert.equal(lastBarOf(stream, "NSE:ACC").time, T0 + 5 * MIN);
  assert.equal(stream.data._lastBarCache.get("NSE:ACC_1").time, T0 + 5 * MIN);
  assert.equal(stream.data.fills.get("NSE:ACC_1").status, "filled");
});

test("history is asked for the window from the last bar to now, as the library asks it", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5.5 * MIN;
  await stream.fillGaps();

  assert.equal(source.requests.length, 1);
  const r = source.requests[0];
  assert.equal(r.ticker, "NSE:ACC");
  assert.equal(r.resolution, "1");
  assert.equal(r.fromSec, T0 / 1000);
  assert.ok(r.toSec >= (clock.now + MIN) / 1000, "to reaches the end of the current bar");
  assert.equal(r.countBack, 7);
});

test("nothing is asked while the last bar is still the current one", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 30 * 1000;

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "current");
  assert.equal(source.requests.length, 0);
});

test("older bars, which the server returns for an empty window, are ignored", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  source.answer = () => [3, 2, 1].map((k) => bar(T0 - k * MIN, 90));

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "nothing-new");
  assert.equal(seen.length, 0);
  assert.equal(lastBarOf(stream, "NSE:ACC").time, T0);
});

test("when only the current bar comes back, its range is widened and its close is kept", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 90 * 1000;
  source.answer = () => [bar(T0, 103, { high: 105, low: 95 })];

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "filled");
  assert.equal(seen.length, 1);
  assert.equal(seen[0].time, T0);
  assert.equal(seen[0].high, 105);
  assert.equal(seen[0].low, 95);
  assert.equal(seen[0].close, 100, "ticks established the close; history lags them");
});

test("when the current bar comes back unchanged, nothing is fed", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 90 * 1000;
  source.answer = () => [bar(T0, 100)];

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "nothing-new");
  assert.equal(seen.length, 0);
});

test("malformed bars are skipped, not fed", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  source.answer = () => [
    null, { time: "x" }, { time: T0 + MIN, open: NaN, high: 1, low: 1, close: 1 },
    bar(T0 + 2 * MIN, 102),
  ];

  const [result] = await stream.fillGaps();

  assert.equal(result.fetched, 1);
  assert.deepEqual(seen.map((b) => b.time), [T0 + 2 * MIN]);
});

test("a tick that jumps a gap is held while the bars are fetched, then applied", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  const answer = deferred();
  source.answer = () => answer.promise;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);
  await settle();
  assert.equal(seen.length, 0, "nothing reaches the chart until the missing bars are there");
  assert.equal(source.requests.length, 1);

  answer.resolve([...Array(11).keys()].map((k) => bar(T0 + k * MIN, 100 + k)));
  await settle();

  const times = seen.map((b) => b.time);
  assert.deepEqual(times.slice(0, 11), [...Array(11).keys()].map((k) => T0 + k * MIN));
  assert.equal(seen.length, 12, "the held tick follows the filled bars");
  assert.equal(times[11], T0 + 10 * MIN, "the tick lands in the last filled bar, not after a hole");
  assert.equal(seen[11].close, 111);
  assert.ok(times.every((t, i) => i === 0 || t >= times[i - 1]), "times never go backwards");
});

test("ticks that arrive while a fill runs are applied afterwards, in order", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  const answer = deferred();
  source.answer = () => answer.promise;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 1000);
  stream.onTickReceived("NSE:ACC", "1", 112, 99, 11, T0 + 10 * MIN + 2000);
  stream.onTickReceived("NSE:ACC", "1", 113, 99, 12, T0 + 10 * MIN + 3000);
  answer.resolve([...Array(11).keys()].map((k) => bar(T0 + k * MIN, 100 + k)));
  await settle();

  assert.deepEqual(seen.slice(-3).map((b) => b.close), [111, 112, 113]);
  assert.equal(source.requests.length, 1);
});

test("history that fails applies the held tick as it always was, and is not asked again soon", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  source.answer = () => Promise.reject(new Error("HTTP 500"));

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);
  await settle();

  assert.equal(stream.data.fills.get("NSE:ACC_1").status, "failed");
  assert.match(stream.data.fills.get("NSE:ACC_1").error, /500/);
  assert.equal(seen.length, 1, "the tick opened a bar at its own time, as before");
  assert.equal(seen[0].time, T0 + 10 * MIN + 5000);

  // Another jump inside the cooldown goes straight through, without another request.
  stream.onTickReceived("NSE:ACC", "1", 120, 99, 20, T0 + 30 * MIN);
  assert.equal(seen.length, 2);
  assert.equal(source.requests.length, 1);

  // After the cooldown it asks again.
  clock.now += stream.gap.cooldownMs + 1;
  stream.onTickReceived("NSE:ACC", "1", 130, 99, 30, T0 + 60 * MIN);
  await settle();
  assert.equal(source.requests.length, 2);
});

test("history that never answers releases the held tick after the timeout", async () => {
  const { stream, clock, source } = load();
  stream.gap.timeoutMs = 30;
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  const never = deferred();
  source.answer = () => never.promise;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);
  assert.equal(seen.length, 0);
  await new Promise((resolve) => setTimeout(resolve, 90));

  assert.equal(seen.length, 1, "the chart does not freeze on a slow server");
  assert.equal(stream.data.fills.get("NSE:ACC_1").status, "failed");

  // A late answer must not feed bars behind the chart's new last bar.
  never.resolve([...Array(11).keys()].map((k) => bar(T0 + k * MIN, 100 + k)));
  await settle();
  assert.equal(seen.length, 1);
});

test("a tick inside the next bar is not a gap", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 2 * MIN;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 1.5 * MIN);

  assert.equal(seen.length, 1, "applied at once");
  assert.equal(source.requests.length, 0);
});

test("with no history source, ticks behave exactly as before", () => {
  const { stream, clock } = load({ withSource: false });
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);

  assert.equal(seen.length, 1);
  assert.equal(seen[0].time, T0 + 10 * MIN + 5000);
});

test("two requests for the same fill share one request", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  const answer = deferred();
  source.answer = () => answer.promise;

  const first = stream.fillGaps();
  const second = stream.fillGaps();
  answer.resolve([bar(T0 + 3 * MIN, 103)]);
  const [a] = await first;
  const [b] = await second;

  assert.equal(source.requests.length, 1);
  assert.equal(a, b);
});

test("a history source that throws is reported, and does not wedge later fills", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  source.answer = () => { throw new Error("no token"); };

  const [failed] = await stream.fillGaps();
  assert.equal(failed.status, "failed");
  assert.match(failed.error, /no token/);

  source.answer = () => [bar(T0 + 3 * MIN, 103)];
  const [ok] = await stream.fillGaps();
  assert.equal(ok.status, "filled");
});

test("a monthly chart is left alone", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1M", "g");
  clock.now = T0 + 90 * 24 * 60 * MIN;

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "unsupported");
  assert.equal(source.requests.length, 0);
});

test("only the asked symbol is filled, and NSE:ACC is not NSE:ACCELYA", async () => {
  const { stream, clock, source } = load();
  subscribe(stream, "NSE:ACC", "1", "g1");
  subscribe(stream, "NSE:ACCELYA", "1", "g2");
  clock.now = T0 + 5 * MIN;

  const results = await stream.fillGaps("NSE:ACC");

  assert.equal(results.length, 1);
  assert.deepEqual(source.requests.map((r) => r.ticker), ["NSE:ACC"]);
  assert.equal((await stream.fillGaps("NSE:NOPE")).length, 0);
});

test("a fill never feeds a bar behind the chart's current last bar", async () => {
  const { stream, clock, source } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  const answer = deferred();
  source.answer = () => answer.promise;

  const filling = stream.fillGaps();
  // A tick opens the next bar while history is out. It is not a gap, so it goes straight through.
  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 70 * 1000);
  assert.equal(seen.length, 1);
  const barNow = lastBarOf(stream, "NSE:ACC").time;
  assert.equal(barNow, T0 + 70 * 1000);

  answer.resolve([0, 1, 2, 3, 4, 5].map((k) => bar(T0 + k * MIN, 100 + k)));
  await filling;

  const fed = seen.slice(1).map((b) => b.time);
  assert.ok(fed.length > 0);
  assert.ok(fed.every((t) => t >= barNow), `fed ${fed} behind ${barNow}`);
  assert.deepEqual(fed, [2, 3, 4, 5].map((k) => T0 + k * MIN));
});

test("too many missing bars are not fed one by one", async () => {
  const { stream, clock, source } = load();
  stream.gap.maxFeed = 50;
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 200 * MIN;
  source.answer = () => [...Array(120).keys()].map((k) => bar(T0 + (k + 1) * MIN, 100));

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "too-large");
  assert.equal(result.fetched, 120);
  assert.equal(seen.length, 0);
});

test("a handler that throws does not stop the rest of the bars", async () => {
  const { stream, clock, source } = load();
  stream.saveBar("NSE:ACC", "1", bar(T0, 100));
  const seen = [];
  stream.subscribe("NSE:ACC", "1", "g", (b) => {
    seen.push(b);
    if (seen.length === 1) throw new Error("library said no");
  });
  clock.now = T0 + 5 * MIN;
  source.answer = () => [1, 2, 3].map((k) => bar(T0 + k * MIN, 100 + k));

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "filled");
  assert.equal(seen.length, 3);
});

// What the host is told when a fill could not close the gap (stream.onGapNotClosed, which main.js
// turns into a `GapFill` message so the app can load the page again).

/** Collects what the stream tells the host. */
function listen(stream) {
  const told = [];
  stream.onGapNotClosed = (result) => told.push(result);
  return told;
}

test("a host fill that is too large tells the host, once", async () => {
  const { stream, clock, source } = load();
  stream.gap.maxFeed = 50;
  const told = listen(stream);
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 200 * MIN;
  source.answer = () => [...Array(120).keys()].map((k) => bar(T0 + (k + 1) * MIN, 100));

  await stream.fillGaps();

  assert.equal(told.length, 1);
  assert.equal(told[0].status, "too-large");
  assert.equal(told[0].ticker, "NSE:ACC");
});

test("a tick-started fill that is too large tells the host, and the tick still lands", async () => {
  const { stream, clock, source } = load();
  stream.gap.maxFeed = 50;
  const told = listen(stream);
  const seen = subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 200 * MIN;
  source.answer = () => [...Array(120).keys()].map((k) => bar(T0 + (k + 1) * MIN, 100));

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 200 * MIN + 5000);
  await settle();

  assert.deepEqual(told.map((r) => r.status), ["too-large"]);
  assert.equal(seen.length, 1, "no bars fed, the tick applied as before");
});

test("a failing host fill tells the host", async () => {
  const { stream, clock, source } = load();
  const told = listen(stream);
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 5 * MIN;
  source.answer = () => Promise.reject(new Error("HTTP 500"));

  await stream.fillGaps();

  assert.deepEqual(told.map((r) => r.status), ["failed"]);
});

test("a failing tick-started fill does not: slow history there is routine", async () => {
  const { stream, clock, source } = load();
  const told = listen(stream);
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  source.answer = () => Promise.reject(new Error("HTTP 500"));

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);
  await settle();

  assert.equal(stream.data.fills.get("NSE:ACC_1").status, "failed");
  assert.deepEqual(told, []);
});

test("a host call that joins a tick-started fill that fails is told", async () => {
  const { stream, clock, source } = load();
  const told = listen(stream);
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 10 * MIN;
  const answer = deferred();
  source.answer = () => answer.promise;

  stream.onTickReceived("NSE:ACC", "1", 111, 99, 10, T0 + 10 * MIN + 5000);
  const joined = stream.fillGaps();
  answer.reject(new Error("HTTP 500"));
  await joined;

  assert.deepEqual(told.map((r) => r.status), ["failed"]);
});

test("a fill that worked, found nothing, or had nothing to do tells no one", async () => {
  const { stream, clock, source } = load();
  const told = listen(stream);
  subscribe(stream, "NSE:ACC", "1", "g");

  clock.now = T0 + 30 * 1000;
  await stream.fillGaps(); // current
  clock.now = T0 + 5 * MIN;
  source.answer = () => [];
  await stream.fillGaps(); // nothing-new
  source.answer = () => [1, 2, 3].map((k) => bar(T0 + k * MIN, 100 + k));
  await stream.fillGaps(); // filled

  assert.deepEqual(told, []);
});

test("a listener that throws does not break the fill", async () => {
  const { stream, clock, source } = load();
  stream.gap.maxFeed = 2;
  stream.onGapNotClosed = () => { throw new Error("host said no"); };
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 20 * MIN;
  source.answer = () => [1, 2, 3, 4].map((k) => bar(T0 + k * MIN, 100));

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "too-large");
});

test("with no listener set, a too-large fill is still just reported in its result", async () => {
  const { stream, clock, source } = load();
  stream.gap.maxFeed = 2;
  subscribe(stream, "NSE:ACC", "1", "g");
  clock.now = T0 + 20 * MIN;
  source.answer = () => [1, 2, 3, 4].map((k) => bar(T0 + k * MIN, 100));

  const [result] = await stream.fillGaps();

  assert.equal(result.status, "too-large");
});
