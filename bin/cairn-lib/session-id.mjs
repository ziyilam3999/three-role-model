import { promises as fs } from "node:fs";
import { LAST_SESSION_ID_FILE } from "./paths.mjs";

export async function resolveSessionId() {
  if (process.env.CLAUDE_SESSION_ID) return process.env.CLAUDE_SESSION_ID.trim();
  try {
    const s = await fs.readFile(LAST_SESSION_ID_FILE, "utf8");
    const trimmed = s.trim();
    if (trimmed) return trimmed;
  } catch {}
  return null;
}
