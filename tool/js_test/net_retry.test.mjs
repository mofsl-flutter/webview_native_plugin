// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
//
// A cacheable API response that an earlier same-origin request stored without its CORS header makes
// the bundled page's (cross-origin) request fail with a TypeError (`net::ERR_FAILED`), and the chart
// reports SymbolNotFound. net_retry.js retries such a GET once with the cache bypassed, which stores
// a copy that has the header. These tests run the page's real module against a fake `fetch`.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/net_retry.js", import.meta.url), "utf8");

const API = "https://prod.example/charts/api/Chart/Symbols?symbol=IDX%3A1%3ASENSEX";

/**
 * Loads net_retry.js as the page would. `fetchImpl(url, options)` is `window.fetch`; the calls it
 * received are in `calls`. Looked up when called, because the harness replaces `window.fetch`.
 */
function load(fetchImpl) {
  const calls = [];
  const logged = [];
  const chartApp = {};
  const window = {
    fetch: (url, options) => {
      calls.push({ url, options });
      return fetchImpl(url, options, calls.length);
    },
    log: { info: (...a) => logged.push(a.join(" ")), debug: () => {} },
  };
  window.window = window;
  vm.runInNewContext(SOURCE, { window, ChartApp: chartApp, URL });
  return { netRetry: chartApp.netRetry, calls, logged, window };
}

/** What the page returned, as plain data: objects made inside the vm do not share our prototypes. */
const plain = (x) => JSON.parse(JSON.stringify(x));

// Created outside the page's realm on purpose: the module must not rely on `instanceof TypeError`.
const networkError = () => new TypeError("Failed to fetch");
const response = (status = 200) => ({ status, ok: status < 400 });

/** A cache that holds a copy without the CORS header: only a request that bypasses it succeeds. */
const poisonedCache = (url, options) =>
  options && options.cache === "reload" ? Promise.resolve(response()) : Promise.reject(networkError());

test("a healthy request is made once, with the options the caller gave", async () => {
  const opts = { method: "GET", headers: { Authorization: "Bearer x" } };
  const { netRetry, calls } = load(async () => response());

  const r = await netRetry.fetch(API, opts);

  assert.equal(r.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, API);
  assert.equal(calls[0].options, opts, "the very same options object, not a copy");
  assert.equal(netRetry.stats().retried, 0);
});

test("a GET that fails with a network error is retried once, bypassing the cache", async () => {
  const { netRetry, calls } = load(poisonedCache);

  const r = await netRetry.fetch(API, { method: "GET", headers: { Authorization: "Bearer x" } });

  assert.equal(r.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, API, "the same URL");
  assert.equal(calls[1].options.cache, "reload");
  assert.equal(calls[1].options.method, "GET");
  assert.deepEqual(calls[1].options.headers, { Authorization: "Bearer x" }, "headers carried over");
  assert.deepEqual(plain(netRetry.stats()), { retried: 1, recovered: 1, failed: 0 });
});

test("a request with no options at all is a GET and is retried", async () => {
  const { netRetry, calls } = load(poisonedCache);

  await netRetry.fetch(API);

  assert.equal(calls.length, 2);
  assert.equal(calls[1].options.cache, "reload");
});

test("the caller's options are not changed (the 401 queue keeps the same object)", async () => {
  const opts = { method: "GET", headers: { Authorization: "Bearer x" } };
  const { netRetry } = load(poisonedCache);

  await netRetry.fetch(API, opts);

  assert.deepEqual(opts, { method: "GET", headers: { Authorization: "Bearer x" } });
  assert.equal("cache" in opts, false);
});

test("a second failure is rejected, not retried again", async () => {
  const { netRetry, calls } = load(async () => {
    throw networkError();
  });

  await assert.rejects(netRetry.fetch(API, { method: "GET" }), (e) => e.name === "TypeError");

  assert.equal(calls.length, 2, "one retry, no more");
  assert.deepEqual(plain(netRetry.stats()), { retried: 1, recovered: 0, failed: 1 });
});

test("a write is never retried (it may have reached the server)", async () => {
  for (const method of ["POST", "PUT", "DELETE", "post", "PATCH"]) {
    const { netRetry, calls } = load(async () => {
      throw networkError();
    });

    await assert.rejects(netRetry.fetch(API, { method, body: "{}" }), (e) => e.name === "TypeError");

    assert.equal(calls.length, 1, method);
  }
});

test("a method written in lower case is still a GET", async () => {
  const { netRetry, calls } = load(poisonedCache);

  await netRetry.fetch(API, { method: "get" });

  assert.equal(calls.length, 2);
});

test("an error that is not a network failure is rejected untouched", async () => {
  for (const name of ["AbortError", "SyntaxError", "Error"]) {
    const { netRetry, calls } = load(async () => {
      const e = new Error("x");
      e.name = name;
      throw e;
    });

    await assert.rejects(netRetry.fetch(API, { method: "GET" }), (e) => e.name === name);

    assert.equal(calls.length, 1, name);
  }
});

test("a cache mode the caller chose is respected: no retry that would override it", async () => {
  for (const cache of ["no-store", "reload", "force-cache", "only-if-cached", "default", "no-cache"]) {
    const { netRetry, calls } = load(async () => {
      throw networkError();
    });

    await assert.rejects(netRetry.fetch(API, { method: "GET", cache }));

    assert.equal(calls.length, 1, cache);
  }
});

test("an HTTP error status is a response, not a failure: no retry", async () => {
  for (const status of [401, 404, 500]) {
    const { netRetry, calls } = load(async () => response(status));

    const r = await netRetry.fetch(API, { method: "GET" });

    assert.equal(r.status, status);
    assert.equal(calls.length, 1, String(status));
  }
});

test("a request that was aborted is not retried", async () => {
  const { netRetry, calls } = load(async () => {
    throw networkError();
  });

  await assert.rejects(netRetry.fetch(API, { method: "GET", signal: { aborted: true } }));

  assert.equal(calls.length, 1);
});

test("looks up fetch when it is called, so a replaced window.fetch is honoured", async () => {
  const { netRetry, window, calls } = load(async () => response());
  let replaced = 0;
  window.fetch = () => {
    replaced++;
    return Promise.reject(networkError());
  };

  await assert.rejects(netRetry.fetch(API, { method: "GET" }));

  assert.equal(replaced, 2, "the harness's network-failure case replaces window.fetch");
  assert.equal(calls.length, 0);
});

test("the retry is logged by path, never with the query (no symbol or account detail)", async () => {
  const { netRetry, logged } = load(poisonedCache);

  await netRetry.fetch(API, { method: "GET", headers: { Authorization: "Bearer SECRET-TOKEN" } });

  const line = logged.join("\n");
  assert.match(line, /Symbols/);
  assert.doesNotMatch(line, /SENSEX|symbol=|SECRET-TOKEN|Bearer/);
});

test("works without a logger", async () => {
  const chartApp = {};
  const window = { fetch: (u, o) => (o && o.cache === "reload" ? Promise.resolve(response()) : Promise.reject(networkError())) };
  window.window = window;
  vm.runInNewContext(SOURCE, { window, ChartApp: chartApp, URL });

  const r = await chartApp.netRetry.fetch(API, { method: "GET" });

  assert.equal(r.status, 200);
});

test("loading the module twice does not reset what it counted", async () => {
  const chartApp = {};
  const window = { fetch: poisonedCache };
  window.window = window;
  const ctx = { window, ChartApp: chartApp, URL };
  vm.runInNewContext(SOURCE, ctx);
  await chartApp.netRetry.fetch(API, { method: "GET" });

  vm.runInNewContext(SOURCE, ctx);

  assert.equal(chartApp.netRetry.stats().retried, 1);
});

// The invariant the retry depends on: it only helps if it is on every request the page makes.
test("the page's scripts make every request through it, and load it first", () => {
  const read = (p) => fs.readFileSync(new URL(`../../assets/chart/v4/${p}`, import.meta.url), "utf8");
  const bare = /(^|[^.\w])fetch\s*\(|window\.fetch\s*\(|XMLHttpRequest|sendBeacon/;
  for (const file of ["js/core/static_config.js", "js/core/preload.js", "js/core/api_base.js", "js/core/save_scheduler.js",
    "js/core/stream.js", "js/datafeeds/datafeed.js", "js/main.js"]) {
    const code = read(file)
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/(^|[^:])\/\/.*$/gm, "$1");
    assert.doesNotMatch(code, bare, `${file} makes a request that bypasses netRetry`);
  }
  const html = read("RiseApp_Mobile.html");
  const order = [...html.matchAll(/src="(js\/core\/[a-z_]+\.js)/g)].map((m) => m[1]);
  assert.ok(order.includes("js/core/net_retry.js"), "net_retry.js is loaded by the page");
  assert.ok(order.indexOf("js/core/net_retry.js") < order.indexOf("js/core/static_config.js"), "before static_config.js");
  assert.match(read("js/core/static_config.js"), /chartApp\.netRetry\.fetch\(/);
});
