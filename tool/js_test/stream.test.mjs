// Run with: node --test tool/js_test/*.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/stream.js", import.meta.url), "utf8");

/** Loads stream.js as the page would and returns its `stream` plus what it published. */
function load() {
  const quotes = [];
  const chartApp = { quote: { publishQuote: (...args) => quotes.push(args) } };
  const logger = { debug() {}, warn() {}, error() {} };
  vm.runInNewContext(SOURCE, { window: {}, log: { getLogger: () => logger }, ChartApp: chartApp });
  return { stream: chartApp.stream, quotes };
}

const MIN = 60 * 1000;
const T0 = Date.UTC(2026, 9, 23, 4, 0, 0); // a minute boundary
const bar = (time, close) => ({ time, open: close, high: close, low: close, close, volume: 0 });

/** Subscribes [guid] to ticker/resolution after seeding the bar the page would have cached. */
function subscribe(stream, ticker, resolution, guid, seed = bar(T0, 100)) {
  stream.saveBar(ticker, resolution, seed);
  const seen = [];
  stream.subscribe(ticker, resolution, guid, (b) => seen.push(b));
  return seen;
}

test("a tick updates every resolution subscribed for that symbol", () => {
  const { stream } = load();
  const m1 = subscribe(stream, "NSE:ACC", "1", "g1");
  const m5 = subscribe(stream, "NSE:ACC", "5", "g5");
  stream.onTickReceived("NSE:ACC", "1", 101, 99, 10, T0 + 10 * 1000);
  assert.equal(m1.length, 1);
  assert.equal(m5.length, 1);
  assert.equal(m1[0].close, 101);
});

test("a tick for one symbol does not reach a symbol that merely starts with it", () => {
  // `NSE:ACC` is a prefix of `NSE:ACCELYA`; they are different instruments.
  const { stream } = load();
  const acc = subscribe(stream, "NSE:ACC", "1", "g1");
  const accelya = subscribe(stream, "NSE:ACCELYA", "1", "g2", bar(T0, 2000));
  stream.onTickReceived("NSE:ACC", "1", 101, 99, 10, T0 + 10 * 1000);
  assert.equal(acc.length, 1);
  assert.equal(accelya.length, 0, "ACC's price was applied to ACCELYA");
});

test("getV2 returns exactly the items for the symbol", () => {
  const { stream } = load();
  subscribe(stream, "NSE:ACC", "1", "g1");
  subscribe(stream, "NSE:ACC", "5", "g2");
  subscribe(stream, "NSE:ACCELYA", "1", "g3");
  assert.equal(stream.getV2("NSE:ACC").length, 2);
  assert.equal(stream.getV2("NSE:ACCELYA").length, 1);
  assert.equal(stream.getV2("NSE:NOPE").length, 0);
});

test("a second handler on the same symbol and resolution shares one item", () => {
  const { stream } = load();
  stream.saveBar("NSE:ACC", "1", bar(T0, 100));
  const a = [], b = [];
  stream.subscribe("NSE:ACC", "1", "g1", (x) => a.push(x));
  stream.subscribe("NSE:ACC", "1", "g2", (x) => b.push(x));
  assert.equal(stream.getV2("NSE:ACC").length, 1);
  assert.equal(stream.data._subscriptions.size, 1);
  stream.onTickReceived("NSE:ACC", "1", 101, 99, 10, T0 + 5000);
  assert.equal(a.length, 1);
  assert.equal(b.length, 1);
});

test("unsubscribing the last handler removes the item; others keep receiving", () => {
  const { stream } = load();
  const m1 = subscribe(stream, "NSE:ACC", "1", "g1");
  const m5 = subscribe(stream, "NSE:ACC", "5", "g5");
  stream.unsubscribe("g1");
  assert.equal(stream.getV2("NSE:ACC").length, 1);
  assert.equal(stream.data._subscriptions.has("NSE:ACC_1"), false);
  stream.onTickReceived("NSE:ACC", "5", 101, 99, 10, T0 + 5000);
  assert.equal(m1.length, 0);
  assert.equal(m5.length, 1);
  stream.unsubscribe("g5");
  assert.equal(stream.getV2("NSE:ACC").length, 0);
  assert.equal(stream.data._subscriptions.size, 0);
});

test("a tick inside the bar updates its high, low and close", () => {
  const { stream } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g1", bar(T0, 100));
  stream.onTickReceived("NSE:ACC", "1", 105, 99, 10, T0 + 10 * 1000);
  stream.onTickReceived("NSE:ACC", "1", 95, 99, 20, T0 + 20 * 1000);
  const last = seen[seen.length - 1];
  assert.equal(last.time, T0);
  assert.equal(last.high, 105);
  assert.equal(last.low, 95);
  assert.equal(last.close, 95);
});

test("a tick past the bar's end opens the next bar", () => {
  const { stream } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g1", bar(T0, 100));
  stream.onTickReceived("NSE:ACC", "1", 110, 99, 10, T0 + MIN + 1000);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].time, T0 + MIN + 1000);
  assert.equal(seen[0].open, 110);
});

test("a tick older than the last bar is dropped, and an unchanged price is ignored", () => {
  const { stream } = load();
  const seen = subscribe(stream, "NSE:ACC", "1", "g1", bar(T0, 100));
  stream.onTickReceived("NSE:ACC", "1", 105, 99, 10, T0 - 5000); // before the bar
  stream.onTickReceived("NSE:ACC", "1", 100, 99, 10, T0 + 5000); // same close
  assert.equal(seen.length, 0);
});

test("computeNextBarTime steps by the resolution", () => {
  const { stream } = load();
  assert.equal(stream.computeNextBarTime(T0, "1"), T0 + MIN);
  assert.equal(stream.computeNextBarTime(T0, "5"), T0 + 5 * MIN);
  assert.equal(stream.computeNextBarTime(T0, "60"), T0 + 60 * MIN);
  assert.equal(stream.computeNextBarTime(T0, "D"), T0 + 24 * 60 * MIN);
});
