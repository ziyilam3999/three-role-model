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

# #1354 portability: the post-append board resync is a MACHINE-LOCAL agent-kanban hook (kanban-resync.sh) that
# sits next to this hook in ai-brain but is NOT synced into the public three-role-model plugin. So `would-sync`
# only fires where that helper is present. Detect it so the both-ends assertions hold in BOTH trees: ai-brain
# (helper present) REQUIRES would-sync; the plugin (helper absent) requires the guarded call to cleanly NO-OP
# (the ledger write still happens, no would-sync). Either way the ledger-write half is always asserted.
RESYNC_PRESENT=no; [ -f "$(dirname "$HOOK")/kanban-resync.sh" ] && RESYNC_PRESENT=yes

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
# Threads KANBAN_SYNC_DRYRUN=1 (so the post-append resync echoes `would-sync` on stdout instead of touching
# the network) + KANBAN_AUTOSYNC_OFF_FILE at a guaranteed-absent temp path (so the shared resync launcher
# stays hermetic against the operator's real kill-switch). #1354 automated-edge both-ends coverage.
run() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env "$@" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
        KANBAN_SYNC_DRYRUN=1 KANBAN_AUTOSYNC_OFF_FILE="$TMP/none-kanban" bash "$HOOK" 2>&1); RC=$?
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

# ===== #1354 AUTOMATED-EDGE BOTH-ENDS: the JSONL write and the board resync live in the SAME hook block, so
#       on the automated spawn edge you cannot write the {role} ledger line WITHOUT firing the resync. =====

# ---- 11. POSITIVE both-ends: a both-tags spawn -> WRITES the {role} ledger line AND (where kanban-resync.sh is
#          present, i.e. ai-brain) emits `would-sync`. In the plugin (helper absent) the guarded resync cleanly
#          no-ops -> ledger line still written, no would-sync. The ledger half is asserted always; the resync
#          half flips on RESYNC_PRESENT, so the SAME synced smoke passes in both trees. ----
P11='{"session_id":"s1354a","tool_input":{"prompt":"3ROLE_TASK:1354 ROLE:planner\nYou are the planner."},"tool_response":{"agentId":"ag1354"}}'
run "$P11"
n11=$(ledger_count s1354a 1354 planner ag1354)
sync11=$(printf '%s' "$CAP" | grep -c 'would-sync'); [ -n "$sync11" ] || sync11=0
if [ "$RESYNC_PRESENT" = "yes" ]; then sync11_ok=$([ "$sync11" -ge 1 ] && echo yes || echo no); else sync11_ok=$([ "$sync11" = "0" ] && echo yes || echo no); fi
{ [ "$RC" = "0" ] && [ "$n11" = "1" ] && [ "$sync11_ok" = "yes" ]; } && ok "automated edge: {role} ledger line written AND resync half matches helper-presence ($RESYNC_PRESENT)" || bad "both-ends: should write {planner} AND resync-half per presence (rc=$RC n11=$n11 resync=$RESYNC_PRESENT sync11=$sync11 out=$CAP)"

# ---- 12. NEGATIVE untagged: a non-3-role spawn -> NO ledger line AND NO would-sync (resync never fires). ----
P12='{"session_id":"s1354b","tool_input":{"prompt":"Do some general research. No role tags."},"tool_response":{"agentId":"agZ"}}'
run "$P12"
empty12="$([ -z "$(ls -A "$LEDGERDIR/s1354b" 2>/dev/null)" ] && echo yes || echo no)"
sync12=$(printf '%s' "$CAP" | grep -c 'would-sync'); [ -n "$sync12" ] || sync12=0
{ [ "$RC" = "0" ] && [ "$empty12" = "yes" ] && [ "$sync12" = "0" ]; } && ok "automated edge: untagged spawn -> NO ledger line AND NO would-sync" || bad "untagged should fire neither half (rc=$RC empty12=$empty12 sync12=$sync12 out=$CAP)"

# ---- 13. NEGATIVE non-vacuity: the SAME positive payload as #11 but with the kill-switch on -> NO ledger
#          line AND NO would-sync (proves the switch suppresses a REAL resync, not a no-op). ----
P13='{"session_id":"s1354c","tool_input":{"prompt":"3ROLE_TASK:1354 ROLE:planner\nYou are the planner."},"tool_response":{"agentId":"ag1354"}}'
run "$P13" THREE_ROLE_SPAWN_LEDGER_OFF=1
f13a="$([ -f "$LEDGERDIR/s1354c/1354.jsonl" ] && echo yes || echo no)"; sync13a=$(printf '%s' "$CAP" | grep -c 'would-sync'); [ -n "$sync13a" ] || sync13a=0
run "$P13" THREE_ROLE_INSTRUMENT_OFF=1
f13b="$([ -f "$LEDGERDIR/s1354c/1354.jsonl" ] && echo yes || echo no)"; sync13b=$(printf '%s' "$CAP" | grep -c 'would-sync'); [ -n "$sync13b" ] || sync13b=0
{ [ "$f13a" = "no" ] && [ "$sync13a" = "0" ] && [ "$f13b" = "no" ] && [ "$sync13b" = "0" ]; } && ok "automated edge: kill-switch on POSITIVE payload -> NO ledger line AND NO would-sync (non-vacuous)" || bad "kill-switch should suppress BOTH halves (f13a=$f13a sync13a=$sync13a f13b=$f13b sync13b=$sync13b)"

# ===== #1516 RESEARCH-SEAT PreToolUse EDGE: RED-first cases (empirically confirmed against the pre-#1516
#       HEAD hook via git show — see the #1516 executor report — before being pinned here). =====

# ---- 14. PreToolUse + ROLE:research -> writes exactly ONE research row (mid-flight visibility win).
#          RED on pre-#1516: the old role alternation does not include "research" at all -> no-op always. ----
P14='{"session_id":"s1516a","hook_event_name":"PreToolUse","tool_input":{"prompt":"3ROLE_TASK:1516 ROLE:research\nDo research."}}'
run "$P14"
n14=$(ledger_count s1516a 1516 research)
{ [ "$RC" = "0" ] && [ "$n14" = "1" ]; } && ok "PreToolUse + ROLE:research -> writes exactly one research row" || bad "should write {research} at PreToolUse (rc=$RC n14=$n14 out=$CAP)"

# ---- 15. PreToolUse + ROLE:plan-review -> writes NOTHING (BLOCKER-1 regression control). This is the
#          load-bearing negative: it FAILS on a naive "just widen the role alternation, register PreToolUse,
#          don't gate by event" implementation (confirmed against pre-#1516 HEAD: that shape DOES write a
#          row here), and it is what keeps three-role-transition-gate.sh fail-closed (a plan-review row must
#          never exist before the reviewer actually runs). ----
P15='{"session_id":"s1516b","hook_event_name":"PreToolUse","tool_input":{"prompt":"3ROLE_TASK:1516 ROLE:plan-review\nReview it."}}'
run "$P15"
{ [ "$RC" = "0" ] && [ -z "$(ls -A "$LEDGERDIR/s1516b" 2>/dev/null)" ]; } && ok "PreToolUse + ROLE:plan-review -> writes NOTHING (BLOCKER-1 regression control)" || bad "PreToolUse chain-role payload must write nothing (rc=$RC out=$CAP)"

# ---- 16. PreToolUse + ROLE:executor -> writes NOTHING (same control, second chain role, cheap extra coverage). ----
P16='{"session_id":"s1516c","hook_event_name":"PreToolUse","tool_input":{"prompt":"3ROLE_TASK:1516 ROLE:executor\nImplement it."}}'
run "$P16"
{ [ "$RC" = "0" ] && [ -z "$(ls -A "$LEDGERDIR/s1516c" 2>/dev/null)" ]; } && ok "PreToolUse + ROLE:executor -> writes NOTHING (BLOCKER-1 regression control, 2nd chain role)" || bad "PreToolUse executor payload must write nothing (rc=$RC out=$CAP)"

# ---- 17. PostToolUse (explicit hook_event_name) four-role behaviour is BYTE-UNCHANGED: still writes on the
#          close/return edge exactly like fixtures 2-10 (which carry no hook_event_name at all). ----
P17='{"session_id":"s1516d","hook_event_name":"PostToolUse","tool_input":{"prompt":"3ROLE_TASK:1516 ROLE:executor\nImplement it."},"tool_response":{"agentId":"agPost"}}'
run "$P17"
n17=$(ledger_count s1516d 1516 executor agPost)
{ [ "$RC" = "0" ] && [ "$n17" = "1" ]; } && ok "PostToolUse (explicit) + ROLE:executor -> byte-unchanged, still writes" || bad "explicit PostToolUse chain-role should still write (rc=$RC n17=$n17 out=$CAP)"

# ---- 18. PreToolUse + tool_input.subagent_type == cc-research, NO ROLE token -> still writes a research row
#          (mechanism belt #2: a cc-research-typed spawn that omitted the ROLE tag is still filed). ----
P18='{"session_id":"s1516e","hook_event_name":"PreToolUse","tool_input":{"prompt":"3ROLE_TASK:1516\nGo look this up.","subagent_type":"cc-research"}}'
run "$P18"
n18=$(ledger_count s1516e 1516 research)
{ [ "$RC" = "0" ] && [ "$n18" = "1" ]; } && ok "PreToolUse + subagent_type=cc-research (no ROLE tag) -> writes research row" || bad "subagent_type fallback should still write (rc=$RC n18=$n18 out=$CAP)"

# ---- 19. PreToolUse + untagged spawn -> writes NOTHING (no task tag at all). ----
P19='{"session_id":"s1516f","hook_event_name":"PreToolUse","tool_input":{"prompt":"Just do some general work."}}'
run "$P19"
{ [ "$RC" = "0" ] && [ -z "$(ls -A "$LEDGERDIR/s1516f" 2>/dev/null)" ]; } && ok "PreToolUse + untagged -> writes NOTHING" || bad "PreToolUse untagged should write nothing (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
