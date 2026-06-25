#!/usr/bin/env bash
# Smoke for three-role-spawn-ledger.sh (#1187). Exit 0 = all cases pass.
# The hook is a PostToolUse(Agent|Task) side-effect WRITER: on a both-tags spawn it appends a {role[,agentId]}
# role-ledger line (via 3role-ledger.mjs); on any un-attributable / untagged / kill-switched / malformed input
# it writes NOTHING and always exits 0. Both-ends: each fixture FAILS on wrong behavior, PASSES on correct.
# No `set -e` (a recorder must never let a non-zero leak into a decision — #749).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-spawn-ledger.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LEDGERDIR="$TMP/ledger"; PROJROOT="$TMP/projects"

# AC-0 PROBE NOTE (Rule 18, honest): the exact agentId JSON path inside a real PostToolUse-Agent `tool_response`
# is NOT byte-confirmed by a live probe in this build (a swept sample of on-disk transcripts surfaced no
# structured agentId key in a PostToolUse-Agent tool_response). So the hook uses the DEFENSIVE multi-source
# extractor + GRACEFUL DEGRADE, and the suite covers BOTH branches explicitly: fixture 2 (agentId present in
# tool_response -> {role, agentId}) AND fixture 3 (agentId ABSENT -> {role}-only, SubagentStop fills it later).
# When a live probe pins the real path, add it as structured source (a) in the hook; fixture 3 keeps the
# no-agentId branch covered regardless of the probe outcome.

# run <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Pins THREE_ROLE_LEDGER_DIR / _PROJECTS_ROOT.
run() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env "$@" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1); RC=$?
}
# Count ledger lines with role=$3 [agentId=$4] in <LEDGERDIR>/<session>/<task>.jsonl
ledger_count() {
  local s="$1" t="$2" role="$3" aid="${4:-}" f="$LEDGERDIR/$1/$2.jsonl"
  [ -f "$f" ] || { echo 0; return; }
  ROLE="$role" AID="$aid" node -e '
    const fs=require("fs"); let n=0;
    for(const ln of fs.readFileSync(process.argv[1],"utf8").split("\n")){ if(!ln.trim())continue; try{const j=JSON.parse(ln); if(j.role===process.env.ROLE && (!process.env.AID || j.agentId===process.env.AID)) n++;}catch(e){} }
    process.stdout.write(String(n));
  ' "$f"
}

# ---- 2. both-tags + agentId in tool_response -> {role, agentId} line. (Without the parse: empty file -> FAIL.) ----
P2='{"session_id":"s1187a","tool_input":{"prompt":"3ROLE_TASK:1187 ROLE:planner\nYou are the planner."},"tool_response":{"agentId":"agSPAWN1"}}'
run "$P2"
n=$(ledger_count s1187a 1187 planner agSPAWN1)
{ [ "$RC" = "0" ] && [ "$n" = "1" ]; } && ok "both-tags + agentId in tool_response -> {role,agentId} line" || bad "should write {planner,agSPAWN1} (rc=$RC n=$n out=$CAP)"

# ---- 3. both-tags, agentId ABSENT in tool_response -> {role}-only line, no agentId (graceful degrade). ----
P3='{"session_id":"s1187b","tool_input":{"prompt":"3ROLE_TASK:1187 ROLE:executor\nImplement."},"tool_response":{"status":"ok","totalDurationMs":123}}'
run "$P3"
nrole=$(ledger_count s1187b 1187 executor)
hasaid=$(grep -c '"agentId"' "$LEDGERDIR/s1187b/1187.jsonl" 2>/dev/null); [ -n "$hasaid" ] || hasaid=0
{ [ "$RC" = "0" ] && [ "$nrole" = "1" ] && [ "$hasaid" = "0" ]; } && ok "both-tags, no agentId -> {role}-only line (degrade, no agentId key)" || bad "should write {executor} only, no agentId (rc=$RC nrole=$nrole hasaid=$hasaid out=$CAP)"

# ---- 4. ROLE present, NO 3ROLE_TASK -> NO append (un-attributable -> no-op). ----
P4='{"session_id":"s1187c","tool_input":{"prompt":"ROLE:planner\nYou are the planner, but no task tag."},"tool_response":{"agentId":"agX"}}'
run "$P4"
{ [ "$RC" = "0" ] && [ ! -f "$LEDGERDIR/s1187c/1187.jsonl" ] && [ -z "$(ls -A "$LEDGERDIR/s1187c" 2>/dev/null)" ]; } && ok "ROLE without task -> NO append (no-op)" || bad "ROLE-without-task should write nothing (rc=$RC out=$CAP)"

# ---- 5. no ROLE (normal non-3-role spawn) -> NO append. ----
P5='{"session_id":"s1187d","tool_input":{"prompt":"Do some general research. No role tags."},"tool_response":{"agentId":"agY"}}'
run "$P5"
{ [ "$RC" = "0" ] && [ -z "$(ls -A "$LEDGERDIR/s1187d" 2>/dev/null)" ]; } && ok "no ROLE (normal spawn) -> NO append" || bad "untagged spawn should write nothing (rc=$RC out=$CAP)"

# ---- 6. malformed payload (garbage / missing tool_input) -> exit 0, NO append (fail-open). ----
run 'not json {{{'
rc6a=$RC
run '{"session_id":"s1187e"}'
rc6b=$RC
{ [ "$rc6a" = "0" ] && [ "$rc6b" = "0" ] && [ -z "$(ls -A "$LEDGERDIR/s1187e" 2>/dev/null)" ]; } && ok "malformed / missing tool_input -> exit 0, NO append (fail-open)" || bad "malformed should fail-open with no append (rc6a=$rc6a rc6b=$rc6b)"

# ---- 7. kill-switch on an OTHERWISE-POSITIVE payload (R3 non-vacuity): the SAME both-tags+agentId payload as
#         fixture 2, but with the switch on -> exit 0 + NO append (proves the switch suppressed a real write). ----
P7='{"session_id":"s1187f","tool_input":{"prompt":"3ROLE_TASK:1187 ROLE:planner\nYou are the planner."},"tool_response":{"agentId":"agSPAWN1"}}'
run "$P7" THREE_ROLE_SPAWN_LEDGER_OFF=1
rc7a=$RC; f7a="$([ -f "$LEDGERDIR/s1187f/1187.jsonl" ] && echo yes || echo no)"
run "$P7" THREE_ROLE_INSTRUMENT_OFF=1
rc7b=$RC; f7b="$([ -f "$LEDGERDIR/s1187f/1187.jsonl" ] && echo yes || echo no)"
{ [ "$rc7a" = "0" ] && [ "$rc7b" = "0" ] && [ "$f7a" = "no" ] && [ "$f7b" = "no" ]; } && ok "kill-switch on POSITIVE payload -> exit 0, NO append (R3 non-vacuous)" || bad "kill-switch should suppress a real write (rc7a=$rc7a f7a=$f7a rc7b=$rc7b f7b=$f7b)"

# ---- 8. NEVER writes --artifact: the appended {role,agentId} line (fixture 2) has NO artifact_path key. ----
hasart=$(grep -c '"artifact_path"' "$LEDGERDIR/s1187a/1187.jsonl" 2>/dev/null); [ -n "$hasart" ] || hasart=0
{ [ "$hasart" = "0" ]; } && ok "appended line has NO artifact_path key (no dangle possible)" || bad "line must not carry artifact_path (hasart=$hasart)"

# ---- 9. idempotent / overlay-compose: run twice -> exactly ONE planner line; then simulate the artifact-at-close
#         append --role planner --artifact <stable> -> ONE line carrying BOTH agentId and artifact_path. ----
P9='{"session_id":"s1187g","tool_input":{"prompt":"3ROLE_TASK:1187 ROLE:planner"},"tool_response":{"agentId":"agC"}}'
run "$P9"; run "$P9"
n9=$(ledger_count s1187g 1187 planner agC)
printf '## ELI5\nx\n### Binary AC\n- AC1\n' > "$TMP/plan1187.md"
THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
  node "$LED" append --session s1187g --task 1187 --role planner --artifact "$TMP/plan1187.md" >/dev/null 2>&1
both=$(grep -E '"agentId":"agC"' "$LEDGERDIR/s1187g/1187.jsonl" 2>/dev/null | grep -cE '"artifact_path":')
total=$(ledger_count s1187g 1187 planner)
{ [ "$RC" = "0" ] && [ "$n9" = "1" ] && [ "$both" = "1" ] && [ "$total" = "1" ]; } && ok "idempotent (1 line) + overlay-compose: ONE line carries BOTH agentId and artifact_path" || bad "overlay-compose broken (rc=$RC n9=$n9 both=$both total=$total)"

# ---- 10. tag in the `description` field (not prompt) -> still detected + appended (reads the joined field set). ----
P10='{"session_id":"s1187h","tool_input":{"description":"3ROLE_TASK:1187 ROLE:plan-review","prompt":"Review the plan."},"tool_response":{"agentId":"agD"}}'
run "$P10"
n10=$(ledger_count s1187h 1187 plan-review agD)
{ [ "$RC" = "0" ] && [ "$n10" = "1" ]; } && ok "tags in description field -> still detected + appended" || bad "should read joined field set (rc=$RC n10=$n10 out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
