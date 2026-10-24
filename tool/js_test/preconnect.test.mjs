// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
//
// A page served from the app calls its API on another origin, and the first call pays for the DNS
// lookup, the TCP connection and the TLS handshake (measured: a first preflight of about half a second
// against 40 to 60 ms for the ones after it). api_base.js knows that origin the moment it parses the
// page URL, so it asks the browser to open the connection then, while the rest of the page and the
// charting library are still loading. These tests run the real script against a fake `document`.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const SOURCE = fs.readFileSync(new URL("../../assets/chart/v4/js/core/api_base.js", import.meta.url), "utf8");

const ANDROID = "https://appassets.androidplatform.net/chart/v4/RiseApp_Mobile.html";
const IOS = "mochart://app/chart/v4/RiseApp_Mobile.html";
const HOSTED = "https://tradingapi.motilaloswaluat.com/chart/v4/RiseApp_Mobile.html";
const SERVER = "https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com/charts/";
const q = (base) => `?apiBase=${encodeURIComponent(base)}`;

/** A document with just enough head for the script: records what was added to it. */
function fakeDocument({ head = true } = {}) {
  const children = [];
  const doc = {
    createElement: (tag) => ({ tagName: tag.toUpperCase() }),
    head: head
      ? {
          children,
          appendChild: (el) => children.push(el),
          insertBefore: (el) => children.unshift(el),
          querySelector: (selector) => {
            const m = /link\[rel="preconnect"\]\[href="([^"]+)"\]/.exec(selector);
            return m ? children.find((c) => c.rel === "preconnect" && c.href === m[1]) ?? null : null;
          },
        }
      : null,
  };
  return doc;
}

/** Loads api_base.js as the page would, at [href], with [document]. */
function load(href, document = fakeDocument()) {
  const chartApp = {};
  const window = { location: new URL(href), document };
  vm.runInNewContext(SOURCE, { window, ChartApp: chartApp, URL, URLSearchParams, document });
  return { apiBase: chartApp.apiBase, document, window, chartApp };
}

const links = (doc) => (doc.head ? doc.head.children.filter((c) => c.tagName === "LINK") : []);

test("a page served from the app asks the browser to connect to the API's origin at once", () => {
  const { document, apiBase } = load(ANDROID + q(SERVER));

  assert.equal(links(document).length, 1);
  const link = links(document)[0];
  assert.equal(link.rel, "preconnect");
  assert.equal(link.href, "https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com", "the origin, not the /charts/ path");
  assert.equal(apiBase.preconnected, true);
});

test("the hint is for a CORS request, which is what the page's fetch calls are", () => {
  // Without crossorigin the browser opens a connection of the wrong kind and the first fetch cannot use it.
  const { document } = load(IOS + q(SERVER));

  assert.equal(links(document)[0].crossOrigin, "anonymous");
});

test("works the same on iOS's custom scheme", () => {
  const { document } = load(IOS + q(SERVER));

  assert.equal(links(document).length, 1);
  assert.equal(links(document)[0].href, "https://6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com");
});

test("a hosted page without apiBase adds nothing: its API is already its own origin", () => {
  const { document, apiBase } = load(HOSTED);

  assert.equal(links(document).length, 0);
  assert.equal(apiBase.preconnected, false);
});

test("an apiBase on the page's own origin adds nothing", () => {
  const { document } = load(HOSTED + q("https://tradingapi.motilaloswaluat.com/chart/"));

  assert.equal(links(document).length, 0);
});

test("an apiBase on another origin adds one, even for a hosted page", () => {
  const { document } = load(HOSTED + q(SERVER));

  assert.equal(links(document).length, 1);
});

test("an invalid apiBase adds nothing and does not throw (the error is reported on the first request)", () => {
  for (const bad of ["http://insecure.example/chart/", "https://user:pw@h.example/chart/", "https://appassets.androidplatform.net/chart/", "not a url"]) {
    const { document, apiBase } = load(ANDROID + q(bad));

    assert.equal(links(document).length, 0, bad);
    assert.ok(apiBase.error, bad);
    assert.equal(apiBase.preconnected, false, bad);
  }
});

test("a page served from the app with no apiBase adds nothing", () => {
  const { document, apiBase } = load(ANDROID);

  assert.equal(links(document).length, 0);
  assert.match(apiBase.error, /apiBase is required/);
});

test("with no document, or no head yet, the API calls still resolve", () => {
  for (const doc of [undefined, fakeDocument({ head: false })]) {
    const chartApp = {};
    const window = { location: new URL(ANDROID + q(SERVER)), document: doc };
    vm.runInNewContext(SOURCE, { window, ChartApp: chartApp, URL, URLSearchParams, document: doc });

    assert.equal(chartApp.apiBase.base, SERVER);
    assert.equal(chartApp.apiBase.preconnected, false);
    assert.equal(chartApp.apiBase.resolve("../api/Chart/Config"), SERVER + "api/Chart/Config");
  }
});

test("a document that throws never breaks the page", () => {
  const document = {
    createElement: () => {
      throw new Error("no DOM");
    },
    head: { appendChild() {}, querySelector: () => null },
  };
  const { apiBase } = load(ANDROID + q(SERVER), document);

  assert.equal(apiBase.base, SERVER);
  assert.equal(apiBase.preconnected, false);
});

test("the script loaded twice adds the hint once", () => {
  const document = fakeDocument();
  load(ANDROID + q(SERVER), document);
  load(ANDROID + q(SERVER), document);

  assert.equal(links(document).length, 1);
});

test("resolving URLs is unchanged by the hint", () => {
  const { apiBase } = load(ANDROID + q(SERVER));

  assert.equal(apiBase.base, SERVER);
  assert.equal(apiBase.resolve("api/Chart/Symbols?symbol=X"), SERVER + "api/Chart/Symbols?symbol=X");
  assert.equal(apiBase.resolve("../api/Chart/Config"), SERVER + "api/Chart/Config");
  assert.equal(apiBase.resolve("../v1/Libraries/x.js"), "../v1/Libraries/x.js");
});
