// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
//
// RemoveLegendHiddenClasses un-hides two legend elements the library hides again after an interval
// or symbol change, by polling every 500 ms for up to 10 more times. It re-armed itself without its
// remaining count, so every poll started again at 10 and the polling never stopped: 32 calls for one
// interval change and 133 for one symbol change were measured on a device.
//
// static_config.js is a closure that cannot be loaded on its own, so the real function is cut out of
// the file by matching its braces and run here against a fake page and fake timers.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const FILE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/static_config.js", import.meta.url), "utf8");

/** The source of `function (retries = 10) {...}` assigned to `this.RemoveLegendHiddenClasses`. */
function extract() {
  const head = FILE.indexOf("this.RemoveLegendHiddenClasses");
  assert.ok(head >= 0, "RemoveLegendHiddenClasses is still in static_config.js");
  const start = FILE.indexOf("function", head);
  const open = FILE.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < FILE.length; i++) {
    if (FILE[i] === "{") depth++;
    else if (FILE[i] === "}" && --depth === 0) return FILE.slice(start, i + 1);
  }
  throw new Error("unbalanced braces");
}

/**
 * The function bound to an object, with a page whose legend is [hidden] (the elements the function
 * looks for are present) or has no iframe yet. `calls` counts every call, including the re-polls.
 */
function load({ legend = "none" } = {}) {
  const timers = [];
  const hiddenClass = "blockHidden-e6PF69Df";
  const cleaned = [];
  const element = () => {
    const classes = new Set([hiddenClass]);
    const el = {
      classList: {
        contains: (c) => classes.has(c),
        remove: (c) => {
          classes.delete(c);
          cleaned.push(c);
        },
      },
      querySelector: () => null,
    };
    return el;
  };
  const doc = {
    getElementById: (id) => {
      if (id === "tv_chart_container") return { querySelector: () => (legend === "noframe" ? null : { id: "frame" }) };
      if (id === "frame") return { contentDocument: { querySelector: () => (legend === "hidden" ? element() : null) } };
      return null;
    },
  };
  const ctx = vm.createContext({
    document: doc,
    log: { debug() {} },
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
  });
  const original = vm.runInContext(`(${extract()})`, ctx);
  const obj = { calls: 0, cleaned };
  obj.RemoveLegendHiddenClasses = function (...args) {
    obj.calls++;
    return original.apply(this, args);
  };
  /** Runs queued timers until none are left, or [cap] calls have happened. */
  obj.drain = (cap = 100) => {
    while (timers.length && obj.calls < cap) timers.shift().fn();
    return { calls: obj.calls, pending: timers.length, delays: new Set() };
  };
  obj.timers = timers;
  return obj;
}

test("a poll stops after its ten re-polls instead of starting again", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses();
  const { calls, pending } = page.drain();

  assert.equal(calls, 11, "the first call and ten re-polls");
  assert.equal(pending, 0, "nothing is left scheduled");
});

test("it polls every 500 ms", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses();

  assert.equal(page.timers.length, 1);
  assert.equal(page.timers[0].ms, 500);
});

test("a second change starts a second, equally bounded poll", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses();
  page.drain();
  page.RemoveLegendHiddenClasses();
  const { calls, pending } = page.drain(200);

  assert.equal(calls, 22);
  assert.equal(pending, 0);
});

test("the count a caller passes is honoured", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses(2);
  const { calls, pending } = page.drain();

  assert.equal(calls, 3);
  assert.equal(pending, 0);
});

test("zero re-polls means the single call and no timer", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses(0);

  assert.equal(page.calls, 1);
  assert.equal(page.timers.length, 0);
});

test("it still does its job: the hidden classes are removed", () => {
  const page = load({ legend: "hidden" });

  page.RemoveLegendHiddenClasses();

  assert.ok(page.cleaned.length >= 2, "the wrapper and its title are un-hidden");
  assert.ok(page.cleaned.every((c) => c === "blockHidden-e6PF69Df"));
});

test("with no chart iframe yet it stops at once, as it always did", () => {
  const page = load({ legend: "noframe" });

  page.RemoveLegendHiddenClasses();
  const { calls, pending } = page.drain();

  assert.equal(calls, 1);
  assert.equal(pending, 0);
});
