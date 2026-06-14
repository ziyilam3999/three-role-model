#!/usr/bin/env bash
# Smoke for three-role-subagent-ledger.sh (#851 PR2, Phase 3a). Exit 0 = all cases pass.
# The hook is a SubagentStop side-effect WRITER: on a tagged subagent transcript it appends a role-ledger line
# (via 3role-ledger.mjs); on any non-subagent / untagged / kill-switched input it writes NOTHING. Always exit 0.
# No `set -e` — a recorder must never let a non-zero leak into a decision (#749).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-subagent-ledger.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LEDGERDIR="$TMP/ledger"; PROJROOT="$TMP/projects"

# Build a subagent transcript fixture under <PROJROOT>/<slug>/<session>/subagents/agent-<id>.jsonl whose FIRST
# type:user message has the given brief.  mk_transcript <session> <agentId> <brief>
mk_transcript() {
  local s="$1" aid="$2" brief="$3"
  local d="$PROJROOT/proj/$s/subagents"; mkdir -p "$d"
  BRIEF_ENV="$brief" AID="$aid" S="$s" node -e '
    const fs=require("fs");
    const line=JSON.stringify({isSidechain:true,agentId:process.env.AID,sessionId:process.env.S,type:"user",message:{role:"user",content:process.env.BRIEF_ENV}});
    process.stdout.write(line+"\n");
  ' > "$d/agent-$aid.jsonl"
  printf '%s' "$d/agent-$aid.jsonl"
}

# Run the hook with the REAL SubagentStop payload shape (#857):
#   agent_transcript_path = the SUBAGENT transcript $1, transcript_path = a SEPARATE main-session file,
#   agent_id = $3 (the agentId the hook should prefer).
# run <subTranscript> <session> [agentId] [mode]
#   mode=main -> emit the MAIN-session shape instead: NO agent_transcript_path; transcript_path = $1 directly
#   (used to assert the main-session no-op). agent_id is omitted in main mode.
run() {
  local sub="$1" sess="$2" aid="${3:-}" mode="${4:-real}"
  local main="$TMP/main-$sess.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"main-session work, no tags"}}\n' > "$main"
  local payload
  if [ "$mode" = "main" ]; then
    payload=$(printf '{"session_id":"%s","transcript_path":"%s"}' "$sess" "$sub")
  else
    payload=$(printf '{"session_id":"%s","transcript_path":"%s","agent_transcript_path":"%s","agent_id":"%s"}' "$sess" "$main" "$sub" "$aid")
  fi
  CAP=$(printf '%s' "$payload" \
    | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1); RC=$?
}
# Count ledger lines with role=$3 agentId=$4 in <LEDGERDIR>/<session>/<task>.jsonl
ledger_count() {
  local s="$1" t="$2" role="$3" aid="$4" f="$LEDGERDIR/$1/$2.jsonl"
  [ -f "$f" ] || { echo 0; return; }
  ROLE="$role" AID="$aid" node -e '
    const fs=require("fs"); let n=0;
    for(const ln of fs.readFileSync(process.argv[1],"utf8").split("\n")){ if(!ln.trim())continue; try{const j=JSON.parse(ln); if(j.role===process.env.ROLE && (!process.env.AID || j.agentId===process.env.AID)) n++;}catch(e){} }
    process.stdout.write(String(n));
  ' "$f"
}

# ---- 1. REAL shape: tagged brief (3ROLE_TASK:851 ROLE:planner) in agent_transcript_path -> ledger line ----
T1=$(mk_transcript s851a agX "3ROLE_TASK:851 ROLE:planner"$'\n'"You are the planner. Author a plan.")
run "$T1" s851a agX
n=$(ledger_count s851a 851 planner agX)
{ [ "$RC" = "0" ] && [ "$n" = "1" ]; } && ok "tagged planner brief -> 1 ledger line (851,planner,agX)" || bad "tagged planner should write 1 line (rc=$RC n=$n out=$CAP)"

# ---- 2. ROLE: absent, 3ROLE_TASK present + 'review the plan' -> keyword-classified plan-review ----
T2=$(mk_transcript s851b agR "3ROLE_TASK:851 You are a stateless reviewer. Please review the plan for consistency.")
run "$T2" s851b agR
n=$(ledger_count s851b 851 plan-review agR)
{ [ "$RC" = "0" ] && [ "$n" = "1" ]; } && ok "untagged-ROLE + 'review the plan' -> keyword plan-review" || bad "keyword plan-review should write 1 line (rc=$RC n=$n out=$CAP)"

# ---- 3. main-session shape (NO agent_transcript_path; transcript_path NOT under /subagents/, even if tagged)
#         -> writes nothing, rc 0 ----
MAIN="$TMP/proj/s851c/main.jsonl"; mkdir -p "$(dirname "$MAIN")"
printf '%s\n' "$(node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:"3ROLE_TASK:851 ROLE:planner"}}))')" > "$MAIN"
run "$MAIN" s851c "" main
{ [ "$RC" = "0" ] && [ ! -f "$LEDGERDIR/s851c/851.jsonl" ]; } && ok "non-subagent transcript -> no-op (nothing written)" || bad "main-session shape should write nothing (rc=$RC out=$CAP)"

# ---- 4. subagent with NO 3ROLE_TASK tag -> writes nothing, rc 0 ----
T4=$(mk_transcript s851d agZ "You are a general helper. Do some work. No tags here.")
run "$T4" s851d agZ
{ [ "$RC" = "0" ] && [ ! -f "$LEDGERDIR/s851d/851.jsonl" ]; } && ok "untagged subagent -> no-op (nothing written)" || bad "untagged subagent should write nothing (rc=$RC out=$CAP)"

# ---- 5. run TWICE on the same input -> exactly one line (idempotent — cairn Stop-dedup lesson) ----
T5=$(mk_transcript s851e agE "3ROLE_TASK:851 ROLE:executor"$'\n'"Implement the feature.")
run "$T5" s851e agE
run "$T5" s851e agE
n=$(ledger_count s851e 851 executor agE)
{ [ "$RC" = "0" ] && [ "$n" = "1" ]; } && ok "run twice -> exactly one line (idempotent)" || bad "double-run should be idempotent (rc=$RC n=$n out=$CAP)"

# ---- 6. kill-switch THREE_ROLE_INSTRUMENT_OFF=1 (real shape) -> writes nothing ----
T6=$(mk_transcript s851f agF "3ROLE_TASK:851 ROLE:planner")
CAP=$(printf '{"session_id":"s851f","transcript_path":"%s","agent_transcript_path":"%s","agent_id":"agF"}' "$TMP/main-s851f.jsonl" "$T6" \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ ! -f "$LEDGERDIR/s851f/851.jsonl" ]; } && ok "THREE_ROLE_INSTRUMENT_OFF=1 -> no-op" || bad "kill-switch should write nothing (rc=$RC out=$CAP)"

# ---- 7. malformed stdin -> no-op, rc 0 (fail-open recorder) ----
CAP=$(printf '%s' 'not json {{{' | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ]; } && ok "malformed stdin -> no-op rc0 (fail-open)" || bad "malformed should fail-open rc0 (rc=$RC out=$CAP)"

# ---- 8. ROLE: present is AUTHORITATIVE over a misleading keyword body -> labels by ROLE, not keyword ----
T8=$(mk_transcript s851g agA "3ROLE_TASK:851 ROLE:executor"$'\n'"Please review the plan thoroughly before you implement.")
run "$T8" s851g agA
ne=$(ledger_count s851g 851 executor agA); nr=$(ledger_count s851g 851 plan-review agA)
{ [ "$RC" = "0" ] && [ "$ne" = "1" ] && [ "$nr" = "0" ]; } && ok "ROLE:executor authoritative over 'review the plan' keyword" || bad "ROLE tag should win over keyword (rc=$RC exec=$ne planrev=$nr out=$CAP)"

# ---- 9. #855 cross-writer compose (AC5): hook auto-writes {agentId} from a tagged transcript, then the
#         orchestrator appends --artifact ONLY -> ONE planner line carrying BOTH fields (agentId NOT dropped),
#         and 3role-ledger.mjs `check` reports the planner role as RESOLVED (not among the problems). ----
LED="$ROOT/bin/3role-ledger.mjs"
printf '## Binary acceptance criteria\n- AC1\n' > "$TMP/plan855.md"
T9=$(mk_transcript s855 agP "3ROLE_TASK:855 ROLE:planner"$'\n'"You are the planner. Author the plan.")
run "$T9" s855 agP                                         # hook writes {role:planner, agentId:agP}
LF9="$LEDGERDIR/s855/855.jsonl"
# orchestrator close-out: artifact ONLY (no --agent) -> must MERGE onto the hook's agentId
THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
  node "$LED" append --session s855 --task 855 --role planner --artifact "$TMP/plan855.md" >/dev/null
both=$(grep -E '"agentId":"agP"' "$LF9" 2>/dev/null | grep -cE '"artifact_path":')
# check: incomplete ledger BLOCKs on the 3 missing roles, but the planner role must NOT be a problem.
OUT=$(THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
  node "$LED" check --session s855 --task 855 2>&1); CRC=$?
{ [ "$RC" = "0" ] && [ "$both" = "1" ] && [ "$CRC" = "2" ] && ! echo "$OUT" | grep -qiE 'planner (agentId|artifact|[a-z ]*skip)'; } \
  && ok "compose: hook agentId + orchestrator --artifact -> one line BOTH fields, planner RESOLVED" \
  || bad "cross-writer compose broken (RC=$RC both=$both CRC=$CRC out=$OUT)"

# ---- 10. #857 REGRESSION: real SubagentStop shape with BOTH fields present + a DELIBERATELY MISLEADING
#         transcript_path. agent_transcript_path -> the SUBAGENT transcript tagged 857/planner; transcript_path
#         -> a SEPARATE main file tagged with a DIFFERENT task (999/executor). The hook MUST read the SUBAGENT
#         (agent_transcript_path) and write 857/planner, and MUST NOT read the main file's 999 tag. This case
#         FAILS against the pre-#857 transcript_path-only code (which read the main file -> not a /subagents/
#         path -> no-op -> zero lines for 857) and PASSES after the fix. ----
SUB10=$(mk_transcript s857 ag857 "3ROLE_TASK:857 ROLE:planner"$'\n'"You are the planner.")
MAIN10="$TMP/main-s857-tagged.jsonl"
printf '%s\n' "$(node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:"3ROLE_TASK:999 ROLE:executor"}}))')" > "$MAIN10"
CAP=$(printf '{"session_id":"s857","transcript_path":"%s","agent_transcript_path":"%s","agent_id":"ag857"}' "$MAIN10" "$SUB10" \
  | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1); RC=$?
n857=$(ledger_count s857 857 planner ag857); n999=$(ledger_count s857 999 executor "")
{ [ "$RC" = "0" ] && [ "$n857" = "1" ] && [ "$n999" = "0" ]; } \
  && ok "real SubagentStop shape: reads agent_transcript_path (857/planner) NOT transcript_path (999)" \
  || bad "real-shape regression broken (rc=$RC n857=$n857 n999=$n999 out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
