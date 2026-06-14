import { promises as fs } from "node:fs";
import path from "node:path";
import { SKILL_RUNS_DIR } from "./paths.mjs";

const MAX_ROWS = 20;
const MAX_LOG_LINES = 100;

const DATA_FILE = path.join(SKILL_RUNS_DIR, "data.json");
const LOG_FILE = path.join(SKILL_RUNS_DIR, "run.log");

function redactArgs(argv) {
  return argv.map((a) => {
    if (typeof a !== "string") return String(a);
    if (a.includes("/") || a.includes("\\")) return path.basename(a);
    return a;
  }).join(" ");
}

export async function recordRun(row) {
  try {
    await fs.mkdir(SKILL_RUNS_DIR, { recursive: true });
    let data = { skill: "cairn", lastRun: null, totalRuns: 0, runs: [] };
    try {
      const txt = await fs.readFile(DATA_FILE, "utf8");
      data = JSON.parse(txt);
      if (!Array.isArray(data.runs)) data.runs = [];
    } catch (err) {
      if (err.code !== "ENOENT") {
        // corrupt file: start fresh, keep going
      }
    }
    data.runs.push(row);
    if (data.runs.length > MAX_ROWS) data.runs = data.runs.slice(-MAX_ROWS);
    data.lastRun = row.ts;
    data.totalRuns = (data.totalRuns || 0) + 1;

    // Write atomically: temp + rename, LF-only, no CRLF.
    const tmp = `${DATA_FILE}.tmp.${process.pid}.${Math.random().toString(16).slice(2, 8)}`;
    await fs.writeFile(tmp, JSON.stringify(data, null, 2).replace(/\r/g, "") + "\n");
    await fs.rename(tmp, DATA_FILE);

    // Append log line, LF-only.
    const logLine = `${row.ts} | ${row.outcome} | ${row.subcommand} | ${row.args_redacted || ""} | ${row.duration_ms}ms\n`;
    await fs.appendFile(LOG_FILE, logLine);

    // Trim log file to MAX_LOG_LINES (last-writer-wins, best-effort).
    try {
      const cur = await fs.readFile(LOG_FILE, "utf8");
      const lines = cur.split("\n").filter(Boolean);
      if (lines.length > MAX_LOG_LINES) {
        const trimmed = lines.slice(-MAX_LOG_LINES).join("\n") + "\n";
        const tmp2 = `${LOG_FILE}.tmp.${process.pid}.${Math.random().toString(16).slice(2, 8)}`;
        await fs.writeFile(tmp2, trimmed);
        await fs.rename(tmp2, LOG_FILE);
      }
    } catch {}
  } catch (err) {
    process.stderr.write(`cairn: run recording failed: ${err.message}\n`);
  }
}

export function makeRow({ subcommand, args, outcome, durationMs, sessionId }) {
  return {
    ts: new Date().toISOString(),
    session_id: sessionId || null,
    subcommand,
    args_redacted: redactArgs(args || []),
    outcome,
    duration_ms: durationMs,
  };
}
