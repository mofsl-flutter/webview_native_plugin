// Run with: node --test tool/js_test/*.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/preload.js", import.meta.url), "utf8");

/** A clock the test drives by hand, so nothing here waits on real time. */
function fakeClock() {
  // 2,000,000 s: the `to` the history tests use, so "now" and the library's window agree.
  let nowMs = 2_000_000_000, nextId = 1;
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

test("history: a short but non-empty window is served, because the server pads nothing there", async () => {
  // Checked on production for windows of 1, 2, 4, 10 and 12 bars, with countBack 300 and 1: a
  // non-empty window is answered with exactly its bars. Early in the session the library's window
  // (which starts at the previous close) holds only today's bars, far fewer than countBack.
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 6_000, to, countBack: 300 } });
  assert.ok(r, "50-odd bars is what the server would have returned");
  const body = await json(r);
  assert.ok(body.t.length > 0 && body.t.length < 300);
});

test("history: an empty window is refused, because the server answers it with older bars", async () => {
  // Observed on production: a window with no bars in it (the market is closed) comes back as a
  // long run of bars from BEFORE the window. A slice of a prefetch cannot reproduce that.
  const to = 2_000_000;
  const r = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to + 10, to: to + 100, countBack: 300 } });
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

test("history: the library asks up to the END of the current bar, which is in the future", async () => {
  // Observed on a real account: for one-minute bars the library's `to` was exactly 60 s ahead of the
  // prefetch's. No bars exist in that future minute, so it must not count as bars the prefetch
  // missed; staleness is the gap between the prefetch's `to` and NOW.
  const to = 2_000_000; // "now" for the fake clock
  const overshoot = await historyCase({ asked: { from: to - 600_000, to: to - 1 }, req: { from: to - 69_060, to: to + 60, countBack: 300 }, ageMs: 0 });
  assert.ok(overshoot, "a 60 s overshoot past now with a 1 s old prefetch must be accepted");
  const reallyStale = await historyCase({ asked: { from: to - 600_000, to: to - 40 }, req: { from: to - 69_060, to: to + 60, countBack: 300 }, ageMs: 0 });
  assert.equal(reallyStale, undefined, "40 s of real, unseen time is still too much for one-minute bars (15 s)");
});

test("history: refused when stale, limited by the bar length for short bars", async () => {
  const to = 2_000_000;
  const old = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 16_000 });
  assert.equal(old, undefined, "older than 15 s");
  const fiveSec = await historyCase({ asked: { from: to - 600_000, to }, req: { from: to - 69_120, to, countBack: 300 }, ageMs: 6_000, resolution: "5S" });
  assert.equal(fiveSec, undefined, "older than one 5-second bar");
});

test("history: daily is one entry whether the library asks for D or 1D", async () => {
  const to = 2_000_000;
  // Daily bars: one a day, so the window needs about 300 days.
  const t = []; for (let i = 0; i < 400; i++) t.push(to - (400 - i) * 86_400);
  const body = JSON.stringify({ t, o: t.map(() => 1), h: t.map(() => 2), l: t.map(() => 0), c: t.map(() => 1), v: t.map(() => 5), divisor: 100 });
  for (const spelling of ["D", "1D"]) {
    const { preload, clock } = create();
    // Delivered under the one canonical spelling, as ChartPrefetch does.
    preload.put("history", "NSE:ACC|1D", body, clock.now(), { from: to - 500 * 86_400, to });
    const r = await preload.takeHistory({ ticker: "NSE:ACC", resolution: spelling, firstDataRequest: true, from: to - 350 * 86_400, to, countBack: 300 });
    assert.ok(r, `asked as ${spelling}, delivered as 1D`);
  }
});

test("a refusal records why, so a silent miss can be explained", async () => {
  const to = 2_000_000;
  const cases = [
    [{ asked: { from: to - 30_000, to }, req: { from: to - 69_120, to, countBack: 300 } }, /reach back/],
    [{ asked: { from: to - 600_000, to: to - 3600 }, req: { from: to - 69_120, to, countBack: 300 } }, /trails/],
    [{ asked: { from: to - 600_000, to }, req: { from: to + 10, to: to + 100, countBack: 300 } }, /no bars in the window/],
  ];
  for (const [c, why] of cases) {
    const { preload, clock } = create();
    preload.put("history", "NSE:ACC|1", bars(c.asked.from, c.asked.to), clock.now(), { from: c.asked.from, to: c.asked.to });
    assert.equal(await preload.takeHistory({ ticker: "NSE:ACC", resolution: "1", firstDataRequest: true, ...c.req }), undefined);
    assert.match(preload.stats().lastReject, why);
  }
});

test("history: a different symbol or resolution is a different entry", async () => {
  const to = 2_000_000;
  const { preload, clock } = create();
  preload.put("history", "NSE:ACC|1", bars(to - 600_000, to), clock.now(), { from: to - 600_000, to });
  assert.equal(await preload.takeHistory({ ticker: "NSE:ACC", resolution: "5", firstDataRequest: true, from: to - 69_120, to, countBack: 300 }), undefined);
  assert.equal(await preload.takeHistory({ ticker: "NSE:SBIN", resolution: "1", firstDataRequest: true, from: to - 69_120, to, countBack: 300 }), undefined);
});
