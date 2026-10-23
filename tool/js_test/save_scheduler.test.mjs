// Run with: node --test tool/js_test/*.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/save_scheduler.js", import.meta.url), "utf8");

/** A clock the test drives by hand, so nothing here waits on real time. */
function fakeClock() {
  let nowMs = 0, nextId = 1;
  const timers = new Map();
  return {
    now: () => nowMs,
    setTimer: (fn, ms) => { const id = nextId++; timers.set(id, { at: nowMs + ms, fn }); return id; },
    clearTimer: (id) => { timers.delete(id); },
    /** Moves time forward, firing due timers in order, each at its own due time. */
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
    pending: () => timers.size,
  };
}

function create(options = {}) {
  const clock = fakeClock();
  const runs = [];
  const chartApp = {};
  vm.runInNewContext(SOURCE, { window: {}, ChartApp: chartApp });
  const scheduler = chartApp.saveScheduler.create({
    delayMs: 1000, maxWaitMs: 5000,
    run: () => { runs.push(clock.now()); if (options.throwOnce && runs.length === 1) throw new Error("boom"); },
    now: clock.now, setTimer: clock.setTimer, clearTimer: clock.clearTimer,
    onError: options.onError,
  });
  return { scheduler, clock, runs };
}

test("one request runs once, after the delay and not before", () => {
  const { scheduler, clock, runs } = create();
  scheduler.request();
  clock.advance(999);
  assert.deepEqual(runs, []);
  clock.advance(1);
  assert.deepEqual(runs, [1000]);
});

test("a burst inside the delay is one run, a delay after the last request", () => {
  const { scheduler, clock, runs } = create();
  let last = 0;
  for (let i = 0; i < 40; i++) { last = clock.now(); scheduler.request(); clock.advance(20); } // one every 20 ms
  assert.deepEqual(runs, []);
  clock.advance(1000);
  assert.equal(runs.length, 1);
  assert.equal(runs[0], last + 1000, "the delay is measured from the last request");
});

test("a pan that never pauses still saves, at least every maxWait", () => {
  // The case a plain debounce gets wrong: with a request every 250 ms and a 1 s delay it would
  // never fire, and a pan that ends in a crash would lose everything since the last pause.
  const { scheduler, clock, runs } = create();
  for (let t = 0; t < 12000; t += 250) { scheduler.request(); clock.advance(250); }
  clock.advance(2000); // the pan stops
  assert.ok(runs.length >= 2, `saved only ${runs.length} times during a 12 s pan`);
  assert.ok(runs.length <= 4, `saved ${runs.length} times; expected a handful, not one per request`);
  const gaps = runs.map((t, i) => t - (i ? runs[i - 1] : 0));
  assert.ok(gaps.every((g) => g <= 5000 + 250), `a gap exceeded maxWait: ${gaps}`);
});

test("a request after a run starts a fresh cycle", () => {
  const { scheduler, clock, runs } = create();
  scheduler.request(); clock.advance(1000);
  clock.advance(7000);
  scheduler.request(); clock.advance(1000);
  assert.deepEqual(runs, [1000, 9000]);
});

test("nothing is scheduled when nothing was requested", () => {
  const { clock, runs } = create();
  clock.advance(60000);
  assert.deepEqual(runs, []);
  assert.equal(clock.pending(), 0);
});

test("a run that throws does not stop later saves, and the error is reported", () => {
  const errors = [];
  const { scheduler, clock, runs } = create({ throwOnce: true, onError: (e) => errors.push(e.message) });
  scheduler.request(); clock.advance(1000);
  scheduler.request(); clock.advance(1000);
  assert.equal(runs.length, 2);
  assert.deepEqual(errors, ["boom"]);
});

test("cancel drops a pending run", () => {
  const { scheduler, clock, runs } = create();
  scheduler.request();
  scheduler.cancel();
  clock.advance(10000);
  assert.deepEqual(runs, []);
  assert.equal(scheduler.pending, false);
});

test("flush runs a pending save now, and does nothing when none is pending", () => {
  const { scheduler, clock, runs } = create();
  scheduler.flush();
  assert.deepEqual(runs, []);
  scheduler.request(); clock.advance(300);
  scheduler.flush();
  assert.deepEqual(runs, [300]);
  clock.advance(5000);
  assert.deepEqual(runs, [300], "the cancelled timer fired anyway");
});

test("pending reports whether a save is waiting", () => {
  const { scheduler, clock } = create();
  assert.equal(scheduler.pending, false);
  scheduler.request();
  assert.equal(scheduler.pending, true);
  clock.advance(1000);
  assert.equal(scheduler.pending, false);
});
