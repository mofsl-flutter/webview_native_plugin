// Run with: node --test tool/js_test/*.test.mjs   (also run by `flutter test`, see test/chart_js_test.dart)
//
// example/tool/bench/hosts.mjs decides whether every request a captured run made went somewhere it
// should have: the production API gateway, the app's own origin, or a host the TradingView library is
// known to call on its own. A request to a UAT host, a plain-http request, or an unknown host fails the
// check, so "the charting library only uses production" is asserted on every capture.
import test from "node:test";
import assert from "node:assert/strict";

import { classify, check, KNOWN_LIBRARY_HOSTS } from "../../example/tool/bench/hosts.mjs";

const PROD = "6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com";
const rec = (url, extra = {}) => ({ method: "GET", url, host: safeHost(url), phase: "run", ...extra });
function safeHost(url) {
  try {
    return new URL(url).host;
  } catch {
    return "";
  }
}

test("the production gateway and the app's own origins are expected", () => {
  for (const url of [
    `https://${PROD}/charts/api/Chart/Symbols?symbol=X`,
    `https://${PROD}/charts/v1/Libraries/x.js`,
    "https://appassets.androidplatform.net/chart/v4/js/main.js",
    "mochart://app/chart/v4/RiseApp_Mobile.html",
  ]) {
    assert.equal(classify(rec(url), { apiHost: PROD }), "expected", url);
  }
});

test("the library's own third parties are known, not expected and not failures", () => {
  for (const url of [
    "https://cdnjs.cloudflare.com/ajax/libs/twemoji/13.0.1/svg/1f600.svg",
    "https://www.google-analytics.com/analytics.js",
  ]) {
    assert.equal(classify(rec(url), { apiHost: PROD }), "known-library", url);
  }
  assert.ok(KNOWN_LIBRARY_HOSTS.includes("cdnjs.cloudflare.com"));
});

test("a request with no host (blob:, data:) is the page talking to itself", () => {
  assert.equal(classify(rec("blob:https://appassets.androidplatform.net/9f90c481"), { apiHost: PROD }), "expected");
  assert.equal(classify(rec("data:text/html,x"), { apiHost: PROD }), "expected");
});

test("a UAT host is a failure, however it is spelled", () => {
  for (const url of [
    "https://tradingapi.motilaloswaluat.com/chart/api/Chart/Symbols",
    "https://uat.motilaloswal.com/x",
    "https://TRADINGAPI.MOTILALOSWALUAT.COM/chart/v4/RiseApp_Mobile.html",
  ]) {
    assert.equal(classify(rec(url), { apiHost: PROD }), "uat", url);
  }
});

test("plain http is a failure even to an otherwise expected host", () => {
  assert.equal(classify(rec(`http://${PROD}/charts/api/x`), { apiHost: PROD }), "insecure");
  assert.equal(classify(rec("http://cdnjs.cloudflare.com/x.js"), { apiHost: PROD }), "insecure");
});

test("an unknown host is a failure", () => {
  assert.equal(classify(rec("https://tracker.example/pixel.gif"), { apiHost: PROD }), "unknown");
  assert.equal(classify(rec(`https://evil.${PROD}.example/x`), { apiHost: PROD }), "unknown", "a look-alike is not the gateway");
  assert.equal(classify(rec(`https://x.${PROD}/x`), { apiHost: PROD }), "unknown", "a subdomain is not the gateway");
});

test("a URL that cannot be parsed is not trusted", () => {
  for (const url of ["not a url", "", "//no-scheme.example/x"]) {
    assert.equal(classify(rec(url), { apiHost: PROD }), "unknown", JSON.stringify(url));
  }
});

test("the check passes a clean capture and says what it saw", () => {
  const result = check(
    [
      rec(`https://${PROD}/charts/api/Chart/Config`),
      rec("https://appassets.androidplatform.net/chart/v4/js/main.js"),
      rec("https://cdnjs.cloudflare.com/ajax/libs/twemoji/13.0.1/svg/1f600.svg"),
    ],
    { apiHost: PROD },
  );

  assert.equal(result.ok, true);
  assert.deepEqual(result.failures, []);
  assert.equal(result.byClass.expected, 2);
  assert.equal(result.byClass["known-library"], 1);
  assert.deepEqual(result.hosts[PROD], 1);
});

test("the check fails on the first kind of bad request and lists every one", () => {
  const result = check(
    [
      rec(`https://${PROD}/charts/api/Chart/Config`),
      rec("https://tradingapi.motilaloswaluat.com/chart/api/Chart/Symbols"),
      rec("https://tracker.example/pixel.gif"),
      rec(`http://${PROD}/x`),
    ],
    { apiHost: PROD },
  );

  assert.equal(result.ok, false);
  assert.deepEqual(result.failures.map((f) => f.class).sort(), ["insecure", "uat", "unknown"]);
  assert.ok(result.failures.every((f) => f.url));
});

test("an empty capture is not a pass: it proves nothing was seen", () => {
  const result = check([], { apiHost: PROD });

  assert.equal(result.ok, false);
  assert.match(result.reason, /no requests/i);
});

test("a capture that saw no call to the API gateway is not a pass either", () => {
  const result = check([rec("https://appassets.androidplatform.net/chart/v4/js/main.js")], { apiHost: PROD });

  assert.equal(result.ok, false);
  assert.match(result.reason, /api/i);
});

test("failed and OPTIONS requests are still requests to a host", () => {
  const result = check(
    [
      rec(`https://${PROD}/charts/api/x`, { method: "OPTIONS", status: 204 }),
      rec("https://tracker.example/x", { failed: "net::ERR_BLOCKED" }),
    ],
    { apiHost: PROD },
  );

  assert.equal(result.ok, false, "a blocked request to a bad host was still attempted");
  assert.equal(result.failures.length, 1);
});
