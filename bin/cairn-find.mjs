#!/usr/bin/env node
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  T1_ROOT, T2_DIR, KB_DIR, KB_ROOT_FILES, LAST_GLOBAL_INDEX, GRADUATED_DIR, QUARANTINE_DIR, WM_ROOT,
} from "./cairn-lib/paths.mjs";
import { recordRun, makeRow } from "./cairn-lib/runs.mjs";
import { resolveSessionId } from "./cairn-lib/session-id.mjs";

const TIER_ORDER = { T1: 0, T2: 1, T3: 2, PRIMER: 3, WM: 4 };

// Ranking tiers. An exact full-query PHRASE match always outranks a tokenized
// (per-term) match, so single-word and exact-phrase callers keep byte-identical
// ordering to the original 3/2/1 scheme. Multi-word queries ADDITIONALLY surface
// lines that contain SOME of the terms (ranked by how many) — which the old
// whole-query substring match dropped to zero hits.
const RANK_PHRASE_EXACT = 1_000_000; // whole line === query
const RANK_PHRASE_START = 900_000; //   line starts with the full query
const RANK_PHRASE_SUB = 800_000; //     line contains the full query as a substring

function rank(line, query) {
  // Full-phrase match (also covers EVERY single-word query) — highest tiers,
  // same relative ordering as the original exact > startsWith > includes scheme.
  if (line === query) return RANK_PHRASE_EXACT;
  if (line.startsWith(query)) return RANK_PHRASE_START;
  if (line.includes(query)) return RANK_PHRASE_SUB;
  // No full-phrase match. For a MULTI-word query, fall back to per-term matching:
  // rank by the count of distinct terms the line contains (always below any
  // full-phrase match). A single-word query has no extra terms here → 0 (unchanged).
  const terms = [...new Set(query.split(/\s+/).filter(Boolean))];
  if (terms.length <= 1) return 0;
  let matched = 0;
  for (const t of terms) {
    if (line.includes(t)) matched += 1;
  }
  return matched; // 0 if the line contains none of the terms → hit dropped
}

async function listDir(dir) {
  try { return await fs.readdir(dir); } catch { return []; }
}

// Recursively walk a directory and return absolute paths of files matching `endsWith`.
// Silent on ENOENT (matches the missing-root policy used by the other tier walks).
async function walkFiles(root, endsWith) {
  const out = [];
  let entries;
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch { return out; }
  for (const ent of entries) {
    const full = path.join(root, ent.name);
    if (ent.isDirectory()) {
      const nested = await walkFiles(full, endsWith);
      for (const n of nested) out.push(n);
    } else if (ent.isFile() && full.endsWith(endsWith)) {
      out.push(full);
    }
  }
  return out;
}

async function readFileLines(file) {
  try {
    const txt = await fs.readFile(file, "utf8");
    return txt.split("\n").map((l) => l.replace(/\r$/, ""));
  } catch { return null; }
}

function pushHit(out, query, tier, file, lineNo, lineText) {
  const r = rank(lineText, query);
  if (r === 0) return;
  out.push({ rank: r, tier, file, line: lineNo, excerpt: lineText.slice(0, 80) });
}

async function main() {
  const start = Date.now();
  // A downstream consumer that closes early (e.g. `cairn-find … | head`) makes
  // the stdout write loop throw EPIPE. That bare crash reads as "cairn-find is
  // broken" from a subagent shell — the exact false signal #844 fights — so
  // treat a closed pipe as a clean exit instead.
  process.stdout.on("error", (err) => {
    if (err && err.code === "EPIPE") process.exit(0);
    throw err;
  });
  const sessionId = await resolveSessionId();
  const query = process.argv.slice(2).join(" ").trim();
  if (!query) {
    process.stderr.write("find: missing query\n");
    await recordRun(makeRow({ subcommand: "find", args: [], outcome: "error", durationMs: Date.now() - start, sessionId }));
    process.exit(2);
  }

  const hits = [];
  try {
    // T1 — jsonl lesson.payload.marker lines
    const dayDirs = await listDir(T1_ROOT);
    for (const d of dayDirs) {
      const dayDir = path.join(T1_ROOT, d);
      const files = await listDir(dayDir);
      for (const f of files) {
        if (!f.endsWith(".jsonl")) continue;
        const full = path.join(dayDir, f);
        const lines = await readFileLines(full);
        if (!lines) continue;
        for (let i = 0; i < lines.length; i++) {
          const raw = lines[i];
          if (!raw) continue;
          let e;
          try { e = JSON.parse(raw); } catch { continue; }
          if (e.kind === "lesson" && e.payload && e.payload.marker) {
            pushHit(hits, query, "T1", full, i + 1, String(e.payload.marker));
          }
        }
      }
    }
    // T2 — session-notes/*.md (excluding graduated/ and quarantine/)
    const t2Files = await listDir(T2_DIR);
    for (const f of t2Files) {
      if (!f.endsWith(".md")) continue;
      const full = path.join(T2_DIR, f);
      if (full.startsWith(GRADUATED_DIR) || full.startsWith(QUARANTINE_DIR)) continue;
      const lines = await readFileLines(full);
      if (!lines) continue;
      for (let i = 0; i < lines.length; i++) pushHit(hits, query, "T2", full, i + 1, lines[i]);
    }
    // T3 — knowledge-base/*.md
    const t3Files = await listDir(KB_DIR);
    for (const f of t3Files) {
      if (!f.endsWith(".md")) continue;
      const full = path.join(KB_DIR, f);
      const lines = await readFileLines(full);
      if (!lines) continue;
      for (let i = 0; i < lines.length; i++) pushHit(hits, query, "T3", full, i + 1, lines[i]);
    }
    // T3 — root-level governance/reference files (constitution, design-system, etc.)
    for (const rootFile of KB_ROOT_FILES) {
      const lines = await readFileLines(rootFile);
      if (!lines) continue;
      for (let i = 0; i < lines.length; i++) pushHit(hits, query, "T3", rootFile, i + 1, lines[i]);
    }
    // PRIMER
    const primerLines = await readFileLines(LAST_GLOBAL_INDEX);
    if (primerLines) {
      for (let i = 0; i < primerLines.length; i++) pushHit(hits, query, "PRIMER", LAST_GLOBAL_INDEX, i + 1, primerLines[i]);
    }
    // WM — agent-working-memory tier-b cards under topics/<topic>/<id>.md.
    // Recursive walk because the tree is 2-level deep (vs T2's flat one-level).
    // Silent ENOENT on missing root, same policy as the other tiers.
    const wmFiles = await walkFiles(WM_ROOT, ".md");
    for (const full of wmFiles) {
      const lines = await readFileLines(full);
      if (!lines) continue;
      for (let i = 0; i < lines.length; i++) pushHit(hits, query, "WM", full, i + 1, lines[i]);
    }

    hits.sort((a, b) => {
      if (b.rank !== a.rank) return b.rank - a.rank;
      const t = TIER_ORDER[a.tier] - TIER_ORDER[b.tier];
      if (t !== 0) return t;
      if (a.file !== b.file) return a.file < b.file ? -1 : 1;
      return a.line - b.line;
    });

    for (const h of hits) {
      process.stdout.write(`[${h.tier}] ${h.file}:${h.line} ${h.excerpt}\n`);
    }
  } catch (err) {
    process.stderr.write(`find: ${err.message}\n`);
    await recordRun(makeRow({ subcommand: "find", args: [query.slice(0, 40)], outcome: "error", durationMs: Date.now() - start, sessionId }));
    process.exit(1);
  }
  await recordRun(makeRow({ subcommand: "find", args: [query.slice(0, 40)], outcome: "ok", durationMs: Date.now() - start, sessionId }));
}

// Only run when invoked directly (e.g. `node cairn-find.mjs <q>`), NOT when the
// test file imports `rank` — keeps the module side-effect-free under import.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}

export { rank };
