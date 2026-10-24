// Turns the files run_block.sh collected (one app launch each) into comparison tables.
//
//   node analyze.mjs <dir>        prints the tables; writes <dir>/summary.json
//
// File names are `<block>__<variant>__<scenario>__<cache>__<n>.tsv` (see run_block.sh). `cache` is
// `cold` (app data cleared), `warm` (cache kept, app stopped and relaunched) or `prime` (a launch whose
// only job is to fill the cache; never counted).
//
// A run counts only if its open ended in `chartSuccess` and every number was read. A missing value is
// a reason to drop the run, never a zero: a table of zeros looks like a fast page.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const median = (xs) => {
  if (xs.length === 0) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

/** `{block, variant, scenario, cache, n}` for a result file name, or null for any other file. */
export function parseFileName(name) {
  const m = /^([^_]+(?:_[^_]+)*?)__([^_]+(?:_[^_]+)*?)__([A-Za-z0-9]+)__(cold|warm|prime)__(\d+)\.tsv$/.exec(name);
  if (!m) return null;
  return { block: m[1], variant: m[2], scenario: m[3], cache: m[4], n: Number(m[5]) };
}

const FIELDS = ["nav", "doc", "jsBoot", "authRtt", "render", "e2e"];

/** A metric as the harness prints it: `123.4ms`, or `-` when that phase was never reached. */
const ms = (line, key) => {
  const m = new RegExp(`\\b${key}=(\\S+)`).exec(line);
  if (!m) return { missing: key };
  // Negative is possible and real: a phase can finish a hair before its start event is logged.
  const v = /^(-?\d+(?:\.\d+)?)ms$/.exec(m[1]);
  return v ? { value: Number(v[1]) } : { missing: key };
};

const megabytes = (amount, unit) => (unit === "KB" ? Number(amount) / 1024 : unit === "B" ? Number(amount) / 1048576 : Number(amount));

/** What one launch's HBRESULT lines say. `ok` is false, with `why`, when it cannot be used. */
export function parseRun(text) {
  const metrics = /metrics: (.*)/.exec(text);
  const open = /open\.\d+\t([^\n]*)/.exec(text);
  if (!metrics || !open) return { ok: false, why: "no metrics or open line" + (text.includes("__DONE__") ? "" : " (never finished)") };
  if (!text.includes("__DONE__")) return { ok: false, why: "never finished" };

  const line = metrics[1];
  const r = { ok: true };
  for (const key of FIELDS) {
    const v = ms(line, key);
    if (v.missing) return { ok: false, why: `${v.missing} missing from the metrics line` };
    r[key] = v.value;
  }
  const req = /\breq=(\d+)/.exec(line);
  r.req = req ? Number(req[1]) : NaN;
  const lib = /lib=h(\d+)\/r(\d+)\/d(\d+)\/o(\d+) xfer=([\d.]+) (KB|MB|B)\//.exec(line);
  r.lib = lib
    ? { hit: +lib[1], revalidated: +lib[2], download: +lib[3], opaque: +lib[4], netMB: Math.round(megabytes(lib[5], lib[6]) * 100) / 100 }
    : null;
  const outcome = /outcome=(\w+)/.exec(open[1]);
  r.outcome = outcome ? outcome[1] : null;
  const bars = /bars=(\d+)/.exec(text);
  r.bars = bars ? Number(bars[1]) : null;
  if (r.outcome !== "chartSuccess") return { ...r, ok: false, why: `outcome=${r.outcome}` };
  return r;
}

const stat = (xs) => {
  const sorted = [...xs].sort((a, b) => a - b);
  return {
    median: median(xs),
    min: sorted[0],
    max: sorted[sorted.length - 1],
    medianWithoutSlowest: sorted.length > 1 ? median(sorted.slice(0, -1)) : NaN,
  };
};

/**
 * One row per variant, scenario and cache state: the usable runs' statistics, how many were not
 * usable, and each block's median (so the emulator or network drifting on its own is visible).
 */
export function summarize(runs) {
  const groups = new Map();
  for (const r of runs) {
    if (r.cache === "prime") continue;
    const key = [r.variant, r.scenario, r.cache].join("|");
    if (!groups.has(key)) groups.set(key, { variant: r.variant, scenario: r.scenario, cache: r.cache, ok: [], unusable: 0 });
    const g = groups.get(key);
    if (r.ok) g.ok.push(r);
    else g.unusable++;
  }
  return [...groups.values()].map((g) => {
    const row = { variant: g.variant, scenario: g.scenario, cache: g.cache, n: g.ok.length, unusable: g.unusable };
    for (const f of [...FIELDS, "req"]) row[f] = stat(g.ok.map((r) => r[f]));
    row.libNetMB = median(g.ok.map((r) => r.lib?.netMB ?? NaN));
    row.libHit = median(g.ok.map((r) => r.lib?.hit ?? NaN));
    row.libDownload = median(g.ok.map((r) => r.lib?.download ?? NaN));
    const blocks = {};
    for (const b of new Set(g.ok.map((r) => r.block))) blocks[b] = median(g.ok.filter((r) => r.block === b).map((r) => r.e2e));
    row.byBlock = blocks;
    row.e2eRuns = g.ok.map((r) => r.e2e);
    return row;
  });
}

const fmt = (x, d = 0) => (Number.isFinite(x) ? x.toFixed(d) : "-");

export function render(rows) {
  const out = [];
  out.push(`${"variant".padEnd(14)} ${"scn".padEnd(3)} ${"cache".padEnd(5)} ${"n".padStart(2)} | ${["nav", "doc", "jsBoot", "authRtt", "render"].map((h) => h.padStart(8)).join("")} ${"e2e med".padStart(8)} ${"min".padStart(6)} ${"max".padStart(6)} ${"w/o slow".padStart(9)} | ${"req".padStart(4)} ${"lib hit".padStart(7)} ${"lib dl".padStart(6)} ${"lib MB".padStart(7)}`);
  for (const r of rows.sort((a, b) => (a.scenario + a.cache + a.variant).localeCompare(b.scenario + b.cache + b.variant))) {
    out.push(
      `${r.variant.padEnd(14)} ${r.scenario.padEnd(3)} ${r.cache.padEnd(5)} ${String(r.n).padStart(2)} | ${["nav", "doc", "jsBoot", "authRtt", "render"].map((k) => fmt(r[k].median).padStart(8)).join("")} ${fmt(r.e2e.median).padStart(8)} ${fmt(r.e2e.min).padStart(6)} ${fmt(r.e2e.max).padStart(6)} ${fmt(r.e2e.medianWithoutSlowest).padStart(9)} | ${fmt(r.req.median).padStart(4)} ${fmt(r.libHit).padStart(7)} ${fmt(r.libDownload).padStart(6)} ${fmt(r.libNetMB, 2).padStart(7)}${r.unusable ? `   (${r.unusable} unusable)` : ""}`,
    );
  }
  out.push("", "every end-to-end value (ms), in file order:");
  for (const r of rows) out.push(`  ${r.variant.padEnd(14)} ${r.scenario} ${r.cache.padEnd(5)} ${JSON.stringify(r.e2eRuns.map(Math.round))}`);
  out.push("", "median end-to-end per block (drift between blocks of the same variant):");
  for (const r of rows) out.push(`  ${r.variant.padEnd(14)} ${r.scenario} ${r.cache.padEnd(5)} ${Object.entries(r.byBlock).map(([b, v]) => `${b}=${fmt(v)}`).join("  ")}`);
  return out.join("\n");
}

function main(argv) {
  const dir = argv[0];
  if (!dir) {
    console.error("usage: node analyze.mjs <dir>");
    return 2;
  }
  const runs = [];
  for (const f of fs.readdirSync(dir).sort()) {
    const meta = parseFileName(f);
    if (!meta) continue;
    runs.push({ ...meta, ...parseRun(fs.readFileSync(path.join(dir, f), "utf8")), file: f });
  }
  const bad = runs.filter((r) => !r.ok);
  console.log(`${runs.length} launches, ${runs.length - bad.length} usable${bad.length ? ", not usable:" : ""}`);
  for (const r of bad) console.log(`   ${r.file}: ${r.why}`);
  const rows = summarize(runs);
  console.log("\n" + render(rows));
  fs.writeFileSync(path.join(dir, "summary.json"), JSON.stringify({ rows, unusable: bad.map((r) => ({ file: r.file, why: r.why })) }, null, 1));
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(main(process.argv.slice(2)));
