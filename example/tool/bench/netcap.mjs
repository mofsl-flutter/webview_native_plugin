// Records every network request the app's WebView makes during one launch of a regression case.
//
//   node netcap.mjs --device emulator-5556 --out capture.json --label bundled_O1_cold \
//        [--scenario O1] [--cold] [--run-ms 40000] [--reload-ms 0]
//
// Launches the example app on an EMULATOR (never anything else), attaches to its WebView over
// DevTools as early as it can, and records each request from every frame: method, URL, resource type,
// status, bytes, whether the HTTP cache served it, and start and end times in ms since launch. With
// `--reload-ms N` it then reloads the page with the cache disabled and records that too, so the static
// files of a full load are seen even if the attach was late. `TRACE=1` also records a V8 trace
// (`<out>_trace.json`): which scripts were compiled and whether a code cache was used.
//
// Headers are never stored (Authorization carries the access token), and a query value whose name
// looks like a credential is masked in the stored URL. hosts.mjs checks the capture afterwards.
//
// The capture attaches several seconds after launch, so request counts are a lower bound.
import { spawnSync } from "node:child_process";
import fs from "node:fs";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const DEV = opt("device");
const out = opt("out");
const label = opt("label", "capture");
const scenario = opt("scenario", "O1");
const cold = args.includes("--cold") ? "1" : "0";
const runMs = opt("run-ms", "40000");
const reloadMs = opt("reload-ms", "0");
const PKG = "com.example.ios_webview_plugin_example";
if (!DEV || !out) {
  console.error("usage: node netcap.mjs --device emulator-NNNN --out capture.json [--label x] [--scenario O1] [--cold] [--run-ms N] [--reload-ms N]");
  process.exit(2);
}
if (!/^emulator-\d+$/.test(DEV)) {
  console.error(`refusing: '${DEV}' is not an emulator serial`);
  process.exit(2);
}
// One local port per emulator, so two emulators can be captured at once.
const PORT = 9335 + (Number(DEV.split("-")[1]) - 5554);

const adb = (...a) => spawnSync("adb", ["-s", DEV, ...a], { encoding: "utf8" }).stdout?.trim() ?? "";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const now = () => Date.now() - t0;

function redact(url) {
  try {
    const u = new URL(url);
    u.username = "";
    u.password = "";
    for (const k of [...u.searchParams.keys()]) {
      if (/session|token|auth|bearer|jwt|secret/i.test(k)) u.searchParams.set(k, "<redacted>");
    }
    return u.toString();
  } catch {
    return String(url).slice(0, 200);
  }
}

// ── launch ──
adb("forward", "--remove", `tcp:${PORT}`);
adb("shell", "am", "force-stop", PKG);
if (cold === "1") adb("shell", "pm", "clear", PKG);
await sleep(800);
adb("shell", "am", "start", "-n", `${PKG}/.MainActivity`, "--es", "scenario", scenario, "--ez", "autorun", "true");
const launchedAt = now();

// ── wait for the WebView's DevTools socket, as early as possible ──
let pid = "";
let socket = "";
for (let i = 0; i < 600 && !socket; i++) {
  if (!pid) pid = adb("shell", "pidof", PKG);
  if (pid) {
    const line = adb("shell", `grep -a -o 'webview_devtools_remote_${pid.split(" ")[0]}' /proc/net/unix | head -1`);
    if (line) socket = line;
  }
  if (!socket) await sleep(40);
}
if (!socket) {
  console.error("no DevTools socket appeared");
  process.exit(2);
}
adb("forward", `tcp:${PORT}`, `localabstract:${socket}`);
const attachDelayMs = now() - launchedAt;

let version;
for (let i = 0; i < 100 && !version; i++) {
  try {
    version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
  } catch {
    await sleep(40);
  }
}
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.onopen = resolve;
  ws.onerror = reject;
});

let seq = 0;
const waiting = new Map();
const send = (method, params = {}, sessionId) =>
  new Promise((resolve) => {
    const id = ++seq;
    waiting.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });

const sessions = new Map(); // sessionId -> targetInfo
const targetsSeen = new Set(); // one session per target, or every request is recorded twice
const reqs = new Map(); // `${sessionId}:${requestId}` -> record
const records = [];
let phase = "run";

function onEvent(method, p, sessionId) {
  const key = `${sessionId}:${p.requestId}`;
  switch (method) {
    case "Target.attachedToTarget":
      if (targetsSeen.has(p.targetInfo.targetId)) break;
      targetsSeen.add(p.targetInfo.targetId);
      sessions.set(p.sessionId, p.targetInfo);
      void send("Network.enable", {}, p.sessionId);
      void send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, p.sessionId);
      break;
    case "Network.requestWillBeSent": {
      const rec = {
        phase,
        t: now(),
        method: p.request.method,
        url: redact(p.request.url),
        type: p.type ?? "",
        initiator: p.initiator?.type ?? "",
        redirectFrom: p.redirectResponse ? redact(p.redirectResponse.url) : undefined,
      };
      reqs.set(key, rec);
      records.push(rec);
      break;
    }
    case "Network.responseReceived": {
      const rec = reqs.get(key);
      if (rec) {
        rec.tResp = now();
        rec.status = p.response.status;
        rec.mime = p.response.mimeType;
        rec.fromDiskCache = !!p.response.fromDiskCache;
        rec.protocol = p.response.protocol;
      }
      break;
    }
    case "Network.requestServedFromCache": {
      const rec = reqs.get(key);
      if (rec) rec.servedFromCache = true;
      break;
    }
    case "Network.loadingFinished": {
      const rec = reqs.get(key);
      if (rec) {
        rec.bytes = p.encodedDataLength;
        rec.tEnd = now();
      }
      break;
    }
    case "Network.loadingFailed": {
      const rec = reqs.get(key);
      if (rec) {
        rec.failed = p.errorText;
        rec.tEnd = now();
      }
      break;
    }
    case "Network.webSocketCreated":
      records.push({ phase, t: now(), method: "WS", url: redact(p.url), type: "WebSocket", initiator: "" });
      break;
    default:
  }
}

ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && waiting.has(d.id)) {
    waiting.get(d.id)(d.result ?? d.error);
    waiting.delete(d.id);
  } else if (d.method) {
    onEvent(d.method, d.params ?? {}, d.sessionId);
  }
};

await send("Target.setDiscoverTargets", { discover: true });
await send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
const have = await send("Target.getTargets");
for (const t of have.targetInfos ?? []) {
  if (t.type === "page" || t.type === "iframe") {
    // The attach event above does the rest; attaching twice is what doubled the first capture.
    if (!targetsSeen.has(t.targetId)) await send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
  }
}
const attachedAfterMs = now() - launchedAt;

// Optional V8 trace (TRACE=1): which scripts were compiled, and whether a code cache was used.
const traceEvents = [];
let traceDone;
if (process.env.TRACE === "1") {
  traceDone = new Promise((resolve) => {
    const prev = ws.onmessage;
    ws.onmessage = (m) => {
      const d = JSON.parse(m.data);
      if (d.method === "Tracing.dataCollected") {
        for (const e of d.params.value) traceEvents.push(e);
      } else if (d.method === "Tracing.tracingComplete") {
        resolve();
      } else {
        prev(m);
      }
    };
  });
  await send("Tracing.start", { categories: "v8,devtools.timeline", transferMode: "ReportEvents" });
}

await sleep(Math.max(0, Number(runMs) - now()));

let reloaded = false;
if (Number(reloadMs) > 0) {
  const page = [...sessions.entries()].find(([, t]) => t.type === "page" && /RiseApp_Mobile/.test(t.url ?? ""));
  const info = await send("Target.getTargets");
  const live = (info.targetInfos ?? []).find((t) => t.type === "page" && /RiseApp_Mobile/.test(t.url ?? ""));
  const sid = page?.[0] ?? [...sessions.entries()].find(([, t]) => t.targetId === live?.targetId)?.[0];
  if (sid) {
    phase = "reload";
    await send("Network.setCacheDisabled", { cacheDisabled: true }, sid);
    await send("Page.enable", {}, sid);
    await send("Page.reload", { ignoreCache: true }, sid);
    reloaded = true;
    await sleep(Number(reloadMs));
  }
}

if (process.env.TRACE === "1") {
  await send("Tracing.end");
  await Promise.race([traceDone, sleep(30000)]);
  fs.writeFileSync(out.replace(/\.json$/, "_trace.json"), JSON.stringify(traceEvents));
}

const hostOf = (u) => {
  try {
    return new URL(u).host;
  } catch {
    return "?";
  }
};
for (const r of records) r.host = hostOf(r.url);
fs.writeFileSync(
  out,
  JSON.stringify({ label, scenario, cold: cold === "1", attachDelayMs, attachedAfterMs, reloaded, records }, null, 1),
);
adb("forward", "--remove", `tcp:${PORT}`);
console.log(`${label}: ${records.length} requests recorded (attached ${attachedAfterMs} ms after launch, reload=${reloaded})`);
process.exit(0);
