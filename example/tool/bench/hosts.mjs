// Did every request a captured run made go somewhere it should have?
//
//   node hosts.mjs capture.json [--api-host <host>]
//
// A capture is what netcap.mjs writes: every request any frame of the app's WebView made. Each is
// classified, and the check fails (exit 1) on a request to a UAT host, a plain-http request, or a host
// nobody expected. That is how "the charting library uses production for all of its requests" is
// asserted on every run instead of read off a list.
import fs from "node:fs";
import { pathToFileURL } from "node:url";

/** The production chart API gateway. */
export const PRODUCTION_API_HOST = "6r8bhd8hwi.execute-api.ap-south-1.amazonaws.com";

/** Where the plugin serves the bundled page from: Android's virtual host, and iOS's custom scheme. */
const APP_ORIGINS = [
  (u) => u.protocol === "https:" && u.host === "appassets.androidplatform.net",
  (u) => u.protocol === "mochart:" && u.host === "app",
];

/**
 * Hosts the TradingView library requests on its own, hosted or bundled: an emoji picture, and (in
 * about 2% of opens, `Math.random() <= .02` in library.js) Google Analytics. Reported, not failures.
 */
export const KNOWN_LIBRARY_HOSTS = ["cdnjs.cloudflare.com", "www.google-analytics.com", "twemoji.maxcdn.com"];

const isUat = (host) => /motilaloswaluat|(^|\.)uat\./i.test(host);

/** One of: expected, known-library, uat, insecure, unknown. */
export function classify(record, { apiHost = PRODUCTION_API_HOST } = {}) {
  let url;
  try {
    url = new URL(record.url);
  } catch {
    return "unknown";
  }
  const host = url.host.toLowerCase();
  // blob: and data: carry no host; they are the page talking to itself.
  if (host === "" && (url.protocol === "blob:" || url.protocol === "data:")) return "expected";
  if (isUat(host)) return "uat";
  if (url.protocol === "http:") return "insecure";
  if (host === apiHost.toLowerCase()) return "expected";
  if (APP_ORIGINS.some((m) => m(url))) return "expected";
  if (KNOWN_LIBRARY_HOSTS.includes(host)) return "known-library";
  return "unknown";
}

const BAD = new Set(["uat", "insecure", "unknown"]);

/**
 * Checks a capture. `ok` is false for any bad request, for an empty capture (it proves nothing was
 * seen), and for a capture with no call to the API gateway (the run never reached the thing under
 * test, so a clean list would be a false pass).
 */
export function check(records, { apiHost = PRODUCTION_API_HOST } = {}) {
  const byClass = {};
  const hosts = {};
  const failures = [];
  for (const r of records) {
    const c = classify(r, { apiHost });
    byClass[c] = (byClass[c] ?? 0) + 1;
    const h = r.host ?? "";
    hosts[h] = (hosts[h] ?? 0) + 1;
    if (BAD.has(c)) failures.push({ class: c, method: r.method, url: r.url });
  }
  const result = { ok: true, failures, byClass, hosts };
  if (records.length === 0) return { ...result, ok: false, reason: "no requests were captured" };
  if (failures.length > 0) return { ...result, ok: false, reason: `${failures.length} request(s) went somewhere unexpected` };
  if (!records.some((r) => (r.host ?? "").toLowerCase() === apiHost.toLowerCase())) {
    return { ...result, ok: false, reason: `no call to the API gateway ${apiHost} was captured` };
  }
  return result;
}

function main(argv) {
  const file = argv.find((a) => !a.startsWith("--"));
  const i = argv.indexOf("--api-host");
  const apiHost = i >= 0 ? argv[i + 1] : PRODUCTION_API_HOST;
  if (!file) {
    console.error("usage: node hosts.mjs capture.json [--api-host <host>]");
    return 2;
  }
  const capture = JSON.parse(fs.readFileSync(file, "utf8"));
  const result = check(capture.records ?? [], { apiHost });
  console.log(`${capture.label ?? file}: ${result.ok ? "OK" : "FAIL"}  ${JSON.stringify(result.byClass)}`);
  for (const [host, n] of Object.entries(result.hosts).sort((a, b) => b[1] - a[1])) console.log(`   ${String(n).padStart(4)}  ${host || "(blob:/data:)"}`);
  for (const f of result.failures) console.log(`   BAD ${f.class}: ${f.method} ${f.url}`);
  if (!result.ok) console.log(`   ${result.reason}`);
  return result.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(main(process.argv.slice(2)));
