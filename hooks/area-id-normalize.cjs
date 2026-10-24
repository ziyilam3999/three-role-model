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

// #3520 fix3 (N2-r3): parse the Area: BIND the ONE way. The dispatcher's bind contract requires
// exactly one flush-left `Area:` line; the route gate used to classify by the FIRST well-formed
// match, so a prompt carrying two `Area:` lines was classified by whichever came first. The class is
// "area-id parsing is identical in every consumer": both parsers now call THIS function and treat a
// duplicated `Area:` line the way the dispatcher always did — refused, never classified, never a guess.
// Dup detection is SHAPE-BLIND (any flush-left `Area:` line counts, well-formed or not), matching the
// dispatcher's PR:/Repo: bind discipline. Returns one of:
//   { status: "none" }                      zero flush-left `Area:` lines
//   { status: "dup", count }                more than one (count included for refusal text)
//   { status: "malformed" }                 exactly one, but off the grammar or an all-zero id
//   { status: "ok", area }                  exactly one well-formed line; area is the CANONICAL id
function parseAreaBind(text) {
  const lines = String(text == null ? "" : text).split(/\r?\n/);
  const areaLines = lines.filter(l => /^Area:[^\n]*$/.test(l));
  if (areaLines.length === 0) return { status: "none" };
  if (areaLines.length > 1) return { status: "dup", count: areaLines.length };
  const m = areaLines[0].match(/^Area:\s*([0-9]{1,3}[a-z]?)\s*$/);
  if (!m) return { status: "malformed" };
  const area = normaliseAreaId(m[1]);
  return area === null ? { status: "malformed" } : { status: "ok", area };
}
module.exports = { AREA_ID_RE, normaliseAreaId, parseAreaBind };
if (require.main === module) {
  const norm = normaliseAreaId(process.argv[2]);
  if (norm === null) process.exit(1);
  process.stdout.write(norm);
}
