// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/api_base.js", import.meta.url), "utf8");

/** Loads api_base.js as the page would, with window.location set to [href]. */
function load(href) {
  const chartApp = {};
  const window = { location: new URL(href) };
  vm.runInNewContext(SOURCE, { window, ChartApp: chartApp, URL, URLSearchParams });
  return chartApp.apiBase;
}

const ANDROID = "https://appassets.androidplatform.net/chart/v4/RiseApp_Mobile.html";
const IOS = "mochart://app/chart/v4/RiseApp_Mobile.html";
const REMOTE = "https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html";
const SERVER = "https://tradingapi.motilaloswaluat.com/chart/";
const q = (base) => `?apiBase=${encodeURIComponent(base)}`;

test("a remote page without apiBase keeps its relative paths exactly as before", () => {
  const a = load(REMOTE);
  assert.equal(a.base, null);
  assert.equal(a.error, null);
  assert.equal(a.resolve("../api/Chart/Config?page=x"), "../api/Chart/Config?page=x");
  assert.equal(a.resolve("api/Chart/Config"), "api/Chart/Config");
});

test("served from the app without apiBase is an error, not a guess", () => {
  for (const href of [ANDROID, IOS]) {
    const a = load(href);
    assert.match(a.error, /apiBase is required/);
    assert.throws(() => a.resolve("../api/Chart/Config"), /apiBase is required/);
  }
});

test("resolves both relative forms onto the server, and equals what the browser did before", () => {
  const a = load(ANDROID + q(SERVER));
  assert.equal(a.base, SERVER);
  for (const [fromPage, path] of [
    ["../api/Chart/LogJsErrors", "../api/Chart/LogJsErrors"],
    ["../api/Chart/Config?page=RiseApp_Mobile_V4.html", "../api/Chart/Config?page=RiseApp_Mobile_V4.html"],
    ["../api/chart/GetChartSavedInfo?symbol=NSE:ACC&page=RiseApp_Mobile.html", "../api/chart/GetChartSavedInfo?symbol=NSE:ACC&page=RiseApp_Mobile.html"],
    ["../api/Chart/HistoryV3?symbol=NSE%3AACC&resolution=1&from=1&to=2&countBack=300&firstDataRequest=true", "../api/Chart/HistoryV3?symbol=NSE%3AACC&resolution=1&from=1&to=2&countBack=300&firstDataRequest=true"],
  ]) {
    const before = new URL(fromPage, REMOTE).href; // what the hosted page requested
    assert.equal(a.resolve(path), before, path);
  }
});

test("the 'api/' form and the '../api/' form are the same request", () => {
  const a = load(IOS + q(SERVER));
  assert.equal(a.resolve("api/Chart/Symbols?symbol=0%3A22"), a.resolve("../api/Chart/Symbols?symbol=0%3A22"));
});

test("is idempotent, so the 401 retry queue can resolve a URL twice", () => {
  const a = load(ANDROID + q(SERVER));
  const once = a.resolve("../api/Chart/Config?page=x");
  assert.equal(a.resolve(once), once);
});

test("leaves non-API URLs alone", () => {
  const a = load(ANDROID + q(SERVER));
  for (const u of ["Icons/Moon.png", "../../../Icons/Moon.png", "https://other.example/api/x", "js/main.js", ""]) {
    assert.equal(a.resolve(u), u, u);
  }
});

test("normalises the base: trailing slash added, path kept", () => {
  assert.equal(load(ANDROID + q("https://h.example/chart")).base, "https://h.example/chart/");
  assert.equal(load(ANDROID + q("https://h.example/chart///")).base, "https://h.example/chart/");
  assert.equal(load(ANDROID + q("https://h.example")).base, "https://h.example/");
  assert.equal(load(ANDROID + q("https://h.example:8443/a/b/")).base, "https://h.example:8443/a/b/");
});

test("a valid apiBase is honoured on a remote page too", () => {
  const a = load(REMOTE + q("https://staging.example/chart/"));
  assert.equal(a.resolve("../api/x"), "https://staging.example/chart/api/x");
});

test("rejects an unusable apiBase instead of falling back", () => {
  const bad = {
    "not a url": /not an absolute URL/,
    "/chart/": /not an absolute URL/,
    "http://h.example/chart/": /https/,
    "javascript:alert(1)": /https/,
    "https://user:pw@h.example/chart/": /credentials/,
    "https://h.example/chart/?x=1": /query or fragment/,
    "https://h.example/chart/#f": /query or fragment/,
    "https://appassets.androidplatform.net/chart/": /own host/,
  };
  for (const [value, message] of Object.entries(bad)) {
    const a = load(ANDROID + q(value));
    assert.match(a.error ?? "", message, value);
    assert.throws(() => a.resolve("../api/x"), message, value);
  }
});

test("an empty apiBase counts as missing", () => {
  assert.match(load(ANDROID + "?apiBase=").error, /required/);
  assert.equal(load(REMOTE + "?apiBase=").base, null);
});

test("theme and other query parameters do not disturb apiBase", () => {
  const a = load(ANDROID + `?theme=dark&apiBase=${encodeURIComponent(SERVER)}&x=1`);
  assert.equal(a.base, SERVER);
});
