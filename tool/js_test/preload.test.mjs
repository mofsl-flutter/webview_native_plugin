// Run with: node --test tool/js_test/*.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/preload.js", import.meta.url), "utf8");

/** A clock the test drives by hand, so nothing here waits on real time. */
function fakeClock() {
  let nowMs = 1_000_000, nextId = 1;
  const timers = new Map();
  return {
    now: () => nowMs,
    setTimer: (fn, ms) => { const id = nextId++; timers.set(id, { at: nowMs + ms, fn }); return id; },
    clearTimer: (id) => { timers.delete(id); },
    advance(ms) {
      const end = nowMs + ms;
      for (;;) {
        let due = null;
        for (const [id, t] of timers) if (t.at <= end && (due === null || t.at < timers.get(due).at)) due = id;
        if (due === null) break;
        const t = timers.get(due); timers.delete(due); nowMs = t.at; t.fn();
      }
      nowMs = end;
    },
  };
}

function create(options = {}) {
  const clock = fakeClock();
  const chartApp = {};
  vm.runInNewContext(SOURCE, { window: {}, ChartApp: chartApp });
  const preload = chartApp.preload.create({ now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer, ...options });
  return { preload, clock };
}

const json = async (r) => JSON.parse(JSON.stringify(await r.json())); // plain objects: vm realms differ

// ---------------------------------------------------------------------------------------- basics

test("a delivered entry is returned once, as a response the adapter can read", async () => {
  const { preload, clock } = create();
  preload.put("symbols", "0:22", JSON.stringify({ ticker: "NSE:ACC" }), clock.now());
  const r = await preload.take("symbols", "0:22", { maxAgeMs: 60000 });
  assert.equal(r.status, 200);
  assert.equal(r.ok, true);
  assert.deepEqual(await json(r), { ticker: "NSE:ACC" });
  assert.equal(await preload.take("symbols", "0:22", { maxAgeMs: 60000 }), undefined, "single use");
});

test("nothing delivered is a miss, answered at once", async () => {
  const { preload } = create();
  assert.equal(await preload.take("config", "RiseApp_Mobile_V4.html", { maxAgeMs: 60000 }), undefined);
  assert.equal(preload.stats().misses, 1);
});

test("the same key under different kinds does not collide", async () => {
  const { preload, clock } = create();
  preload.put("symbols", "k", JSON.stringify({ a: 1 }), clock.now());
  preload.put("savedInfo", "k", JSON.stringify({ b: 2 }), clock.now());
  assert.deepEqual(await json(await preload.take("savedInfo", "k", { maxAgeMs: 1e6 })), { b: 2 });
  assert.deepEqual(await json(await preload.take("symbols", "k", { maxAgeMs: 1e6 })), { a: 1 });
});

test("an entry older than maxAge is refused and dropped", async () => {
  const { preload, clock } = create();
  preload.put("savedInfo", "NSE:ACC", JSON.stringify({ interval: "1" }), clock.now());
  clock.advance(31_000);
  assert.equal(await preload.take("savedInfo", "NSE:ACC", { maxAgeMs: 30_000 }), undefined);
  assert.equal(preload.stats().expired, 1);
  assert.equal(await preload.take("savedInfo", "NSE:ACC", { maxAgeMs: 30_000 }), undefined);
});

test("a body that is not JSON is a miss, not an exception in the adapter", async () => {
  const { preload, clock } = create();
  preload.put("config", "p", "<html>gateway error</html>", clock.now());
  assert.equal(await preload.take("config", "p", { maxAgeMs: 60000 }), undefined);
  assert.equal(preload.stats().rejected, 1);
});

// ------------------------------------------------------------------------------- in-flight waits

test("take waits for an expected entry and returns it when it arrives", async () => {
  const { preload, clock } = create();
  preload.expect("history", "NSE:ACC|1");
  const pending = preload.take("history", "NSE:ACC|1", { maxAgeMs: 15000 });
  clock.advance(2000);
  preload.put("history", "NSE:ACC|1", JSON.stringify({ t: [1] }), clock.now());
  const r = await pending;
  assert.ok(r, "should have been served");
  assert.equal(preload.stats().hits, 1);
});

test("take gives up after waitMs and the page falls back to the network", async () => {
  const { preload, clock } = create({ waitMs: 5000 });
  preload.expect("config", "p");
  const pending = preload.take("config", "p", { maxAgeMs: 60000 });
  clock.advance(5000);
  assert.equal(await pending, undefined);
  assert.equal(preload.stats().timedOut, 1);
  // The response that finally arrives has nobody waiting and must not linger for a later take.
  preload.put("config", "p", JSON.stringify({ late: true }), clock.now());
  assert.equal(await preload.take("config", "p", { maxAgeMs: 60000 }), undefined);
});

test("cancel releases a waiter at once instead of making it wait out waitMs", async () => {
  const { preload } = create();
  preload.expect("symbols", "0:22");
  const pending = preload.take("symbols", "0:22", { maxAgeMs: 60000 });
  preload.cancel("symbols", "0:22");
  assert.equal(await pending, undefined);
});

test("cancel removes a delivered entry that nobody has taken", async () => {
  const { preload, clock } = create();
  preload.put("symbols", "0:22", JSON.stringify({ x: 1 }), clock.now());
  preload.cancel("symbols", "0:22");
  assert.equal(await preload.take("symbols", "0:22", { maxAgeMs: 60000 }), undefined);
});

test("two waiters on one entry: the first gets it, the second does not", async () => {
  const { preload, clock } = create();
  preload.expect("symbols", "0:22");
  const a = preload.take("symbols", "0:22", { maxAgeMs: 60000 });
  const b = preload.take("symbols", "0:22", { maxAgeMs: 60000 });
  preload.put("symbols", "0:22", JSON.stringify({ x: 1 }), clock.now());
  const [ra, rb] = await Promise.all([a, b]);
  assert.ok(ra);
  assert.equal(rb, undefined, "an entry is single-use even when two callers wait for it");
});

// ----------------------------------------------------------------------------------------- history

const bar = (t) => t; // bar timestamps in seconds; only their order and count matter here
/** A server-shaped body of one-minute bars, [fromT, toT] inclusive, one every 60 s. */
function bars(fromT, toT) {
  const t = []; for (let x = fromT; x <= toT; x += 60) t.push(bar(x));
  return JSON.stringify({ t, o: t.map(() => 1), h: t.map(() => 2), l: t.map(() => 0), c: t.map(() => 1), v: t.map(() => 5), divisor: 100, extra: "kept" });
}

function historyCase({ asked, req, ageMs = 1000, resolution = "1" }) {
  const { preload, clock } = create();
  preload.put("history", `NSE:ACC|${resolution}`, bars(asked.from, asked.to), clock.now() - ageMs, { from: asked.from, to: asked.to });
  return preload.takeHistory({ ticker: "NSE:ACC", resolution, firstDataRequest: true, ...req });
}

test("history: a wider prefetch is sliced to exactly the window the library asked for", async () => {
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 69_120, to, countBack: 300 } });
  const body = await json(r);
  assert.ok(body.t[0] >= to - 69_120 && body.t[body.t.length - 1] <= to, "nothing outside [from, to]");
  assert.ok(body.t.length >= 300);
  for (const k of ["o", "h", "l", "c", "v"]) assert.equal(body[k].length, body.t.length, `${k} sliced with t`);
  assert.equal(body.divisor, 100);
  assert.equal(body.extra, "kept", "fields that are not per-bar arrays survive");
});

test("history: not the first request is never served from a prefetch", async () => {
  const to = 2_000_000;
  const { preload, clock } = create();
  preload.put("history", "NSE:ACC|1", bars(to - 600_000, to), clock.now(), { from: to - 600_000, to });
  const r = await preload.takeHistory({ ticker: "NSE:ACC", resolution: "1", firstDataRequest: false, from: to - 69_120, to, countBack: 300 });
  assert.equal(r, undefined);
});

test("history: refused when the prefetch starts after the window the library wants", async () => {
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 30_000, to }, req: { from: to - 69_120, to, countBack: 300 } });
  assert.equal(r, undefined, "the older bars were never fetched");
});

test("history: refused when the prefetch stops well before the library's `to`", async () => {
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 600_000, to: to - 3600 }, req: { from: to - 69_120, to, countBack: 300 } });
  assert.equal(r, undefined, "an hour of newer bars would be missing");
});

test("history: refused when the window holds fewer bars than countBack", async () => {
  // The server pads nothing: with fewer than countBack bars in range it returns what it has, so a
  // slice that is short could not have come from the server's own answer either.
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 6_000, to, countBack: 300 } });
  assert.equal(r, undefined);
});

test("history: the prefetch's `to` may trail the library's by a few seconds, as it always does", async () => {
  // The library asks a second or two after the host fetched, and a response that was just waited
  // for has zero age, so staleness has to be read from the two `to`s, not from the entry's age.
  const to = 2_000_000;
  const ok = await historyCase({ asked: { from: to - 600_000, to: to - 2 }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 0 });
  assert.ok(ok, "a 2 s lag with a fresh response must be accepted");
  const stale = await historyCase({ asked: { from: to - 600_000, to: to - 20 }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 0 });
  assert.equal(stale, undefined, "20 s of unseen bars is more than one-minute bars allow (15 s)");
  const fiveSec = await historyCase({ asked: { from: to - 600_000, to: to - 6 }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 0, resolution: "5S" });
  assert.equal(fiveSec, undefined, "6 s of unseen bars is more than a 5-second bar");
});

test("history is never waited for: in flight means a miss at once, and the late response is dropped", async () => {
  const to = 2_000_000;
  const { preload, clock } = create();
  preload.expect("history", "NSE:ACC|1");
  const r = await preload.takeHistory({ ticker: "NSE:ACC", resolution: "1", firstDataRequest: true, from: to - 69_120, to, countBack: 300 });
  assert.equal(r, undefined, "answered without waiting");
  assert.equal(preload.stats().notReady, 1);
  preload.put("history", "NSE:ACC|1", bars(to - 600_000, to), clock.now(), { from: to - 600_000, to });
  assert.equal(preload.stats().discarded, 1, "it arrived after the page went to the network");
  assert.equal(await preload.takeHistory({ ticker: "NSE:ACC", resolution: "1", firstDataRequest: true, from: to - 69_120, to, countBack: 300 }), undefined,
    "and must not be offered to a later request");
});

test("history: refused when stale, limited by the bar length for short bars", async () => {
  const to = 2_000_000;
  const old = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 16_000 });
  assert.equal(old, undefined, "older than 15 s");
  const fiveSec = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 6_000, resolution: "5S" });
  assert.equal(fiveSec, undefined, "older than one 5-second bar");
});

test("history: a different symbol or resolution is a different entry", async () => {
  const to = 2_000_000;
  const { preload, clock } = create();
  preload.put("history", "NSE:ACC|1", bars(to - 600_000, to), clock.now(), { from: to - 600_000, to });
  assert.equal(await preload.takeHistory({ ticker: "NSE:ACC", resolution: "5", firstDataRequest: true, from: to - 69_120, to, countBack: 300 }), undefined);
  assert.equal(await preload.takeHistory({ ticker: "NSE:SBIN", resolution: "1", firstDataRequest: true, from: to - 69_120, to, countBack: 300 }), undefined);
});
