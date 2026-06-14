import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const HOME = process.env.HOME || process.env.USERPROFILE || os.homedir();

export const CAIRN_HOME = path.join(HOME, ".claude", "cairn");
export const SKILL_RUNS_DIR = path.join(CAIRN_HOME, "skill-runs");

// PERSIST_ROOT: explicit env first, else walk up from this file to repo root.
// skills/cairn/lib/paths.mjs → repo root is three levels up.
function defaultPersistRoot() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, "..", "..", "..", "hive-mind-persist");
}
export const PERSIST_ROOT = process.env.CAIRN_PERSIST_ROOT || defaultPersistRoot();

export const T1_ROOT = path.join(CAIRN_HOME, "t1-run-scratch");
export const T2_DIR = path.join(PERSIST_ROOT, "session-notes");
export const GRADUATED_DIR = path.join(T2_DIR, "graduated");
export const QUARANTINE_DIR = path.join(T2_DIR, "quarantine");
export const KB_DIR = path.join(PERSIST_ROOT, "knowledge-base");
// Root-level governance/reference files outside knowledge-base/ but still T3-grade.
export const KB_ROOT_FILES = [
  "constitution.md", "design-system.md", "document-guidelines.md", "memory.md",
].map((f) => path.join(PERSIST_ROOT, f));
export const RESERVATIONS_FILE = path.join(KB_DIR, ".reservations.json");
export const HEARTBEATS_LOG = path.join(CAIRN_HOME, "heartbeats.log");
export const LAST_GLOBAL_INDEX = path.join(CAIRN_HOME, "last-global-index.md");
// Working-memory tier-b topics root. Read-only consumer for /cairn find.
// Env-var seam mirrors PERSIST_ROOT / CAIRN_HOME — tests stub via WORKING_MEMORY_ROOT.
export const WM_ROOT = process.env.WORKING_MEMORY_ROOT
  || path.join(HOME, ".claude", "agent-working-memory", "tier-b", "topics");
export const LAST_SESSION_ID_FILE = path.join(CAIRN_HOME, "last-session-id");
export const AUDIT_LATEST = path.join(CAIRN_HOME, "audit", "latest.md");
export const H6_PENDING = path.join(CAIRN_HOME, "h6-pending-issues.jsonl");
