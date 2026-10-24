#!/usr/bin/env node
// hooks/area-id-normalize.cjs — #3520 fix2 (B1-r2): the ONE shared #3520 area-id normaliser.
//
// WHY ONE HELPER (the class behind the finding): fix1 switched the area-id compare from Number() to
// strings without making the id canonical, so "Area: 04" passed the bind grammar, missed the string
// list ("04" != "4") and dispatched a safety-area review to z.ai. The class is "an area id names one
// area however it is written" — so EVERY consumer normalises through THIS file and compares
// normalised-vs-normalised strings: the dispatcher's Area: bind AND its pre-spend safety match
// (tools/openrouter-role-dispatch.sh), the route gate's silence parse (hooks/three-role-route-dispatch-gate.sh)
// and the smoke brief builder (tools/smoke-dispatch-brief.sh). Never a second copy of this logic.
//
// GRAMMAR: 1-3 digits plus an optional single lowercase-letter suffix ("4", "4b"). NORMAL FORM: the
// digit part with leading zeros stripped, the letter kept ("04" -> "4", "026" -> "26", "04b" -> "4b").
// MALFORMED (null): anything off the grammar, and an ALL-ZERO digit part ("0", "00", "0b") — area zero
// does not exist, so a zero-only spelling is refused, never guessed (the malformed-means-refusal
// discipline the PR:/Repo: binds already follow).
//
// CLI: node hooks/area-id-normalize.cjs <id>  — prints the normalised id (exit 0) or nothing (exit 1).
// MODULE: const { normaliseAreaId } = require("<this file>") — returns the normalised string or null.
const AREA_ID_RE = /^([0-9]{1,3})([a-z])?$/;
function normaliseAreaId(raw) {
  const m = AREA_ID_RE.exec(String(raw == null ? "" : raw));
  if (!m) return null;                          // off the grammar (e.g. "4B", "4bb", "1000")
  const digits = m[1].replace(/^0+/, "") || "0";
  if (digits === "0") return null;              // all-zero id ("0", "00", "0b"): malformed, never a guess
  return digits + (m[2] || "");
}
module.exports = { AREA_ID_RE, normaliseAreaId };
if (require.main === module) {
  const norm = normaliseAreaId(process.argv[2]);
  if (norm === null) process.exit(1);
  process.stdout.write(norm);
}
