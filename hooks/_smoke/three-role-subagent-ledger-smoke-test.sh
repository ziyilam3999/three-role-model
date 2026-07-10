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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1100 — AC1 (self-record + agentId merge) + AC3 (provenance stamp). LED is the sibling helper (line ~110).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
APLAN="$TMP/ac-plan.md"; printf '## ELI5\nx\n### Binary AC\n- AC1\n' > "$APLAN"
AREV="$TMP/ac-rev.md";  printf '## Review\nverdict: PASS\n' > "$AREV"
appendLED() { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" append "$@" >/dev/null 2>&1; }
checkLED() { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" check "$@" 2>&1; }
# add an assistant Bash tool_use self-append line for <role> to transcript <file>: add_selfappend <file> <role>
add_selfappend() {
  ROLE="$2" node -e '
    const fs=require("fs");
    const cmd="node hooks/3role-ledger.mjs append --session S --task 1100 --role "+process.env.ROLE+" --artifact /tmp/a.md";
    const line=JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",input:{command:cmd}}]}});
    fs.appendFileSync(process.argv[1], line+"\n");
  ' "$1"
}

# ---- AC1. SELF-RECORD first (artifact ONLY, no agentId) -> SubagentStop MERGES the harness agentId ->
#          3role-ledger.mjs check reports the planner role RESOLVED (one line carrying BOTH fields). ----
appendLED --session sAC1 --task 1100 --role planner --artifact "$APLAN"          # self-record: artifact, NO agentId
TP=$(mk_transcript sAC1 agP1 "3ROLE_TASK:1100 ROLE:planner"$'\n'"You are the planner.")
run "$TP" sAC1 agP1                                                              # hook overlay-merges agentId agP1
# complete the other 3 roles (real resolvable transcripts) so `check` can exit 0
mk_transcript sAC1 agR1 "x" >/dev/null; appendLED --session sAC1 --task 1100 --role plan-review      --agent agR1 --artifact "$AREV"
mk_transcript sAC1 agE1 "x" >/dev/null; appendLED --session sAC1 --task 1100 --role executor         --agent agE1 --artifact "branch feat/x"
mk_transcript sAC1 agV1 "x" >/dev/null; appendLED --session sAC1 --task 1100 --role execution-review --agent agV1 --artifact "$AREV"
merged=$(grep -E '"role":"planner"' "$LEDGERDIR/sAC1/1100.jsonl" 2>/dev/null | grep -c '"agentId":"agP1"')
OUT1=$(checkLED --session sAC1 --task 1100); C1=$?
{ [ "$RC" = "0" ] && [ "$merged" = "1" ] && [ "$C1" = "0" ] && echo "$OUT1" | grep -qi "complete"; } \
  && ok "AC1 self-record(artifact) + SubagentStop agentId MERGE -> check RESOLVED (exit 0)" \
  || bad "AC1 self-record+merge broken (RC=$RC merged=$merged C1=$C1 out=$OUT1)"

# ---- AC3+. transcript WITH the agent's own self-append (Bash append --role planner) -> self_authored:true ----
TPA=$(mk_transcript sAC3a agPA "3ROLE_TASK:1100 ROLE:planner"$'\n'"You are the planner.")
add_selfappend "$TPA" planner
appendLED --session sAC3a --task 1100 --role planner --artifact "$APLAN"          # the agent's self-record line
run "$TPA" sAC3a agPA                                                            # hook scans -> stamps self_authored
stamped=$(grep -E '"role":"planner"' "$LEDGERDIR/sAC3a/1100.jsonl" 2>/dev/null | grep -c '"self_authored":true')
{ [ "$RC" = "0" ] && [ "$stamped" = "1" ]; } \
  && ok "AC3+ transcript WITH self-append -> self_authored:true stamped on the merged line" \
  || bad "AC3+ should stamp self_authored (rc=$RC stamped=$stamped)"

# ---- AC3-. complete ledger with NO self_authored stamps -> check SURFACES a PROVENANCE flag, still exit 0 ----
mk_transcript sAC3b agPb "x" >/dev/null; appendLED --session sAC3b --task 1100 --role planner          --agent agPb --artifact "$APLAN"
mk_transcript sAC3b agRb "x" >/dev/null; appendLED --session sAC3b --task 1100 --role plan-review       --agent agRb --artifact "$AREV"
mk_transcript sAC3b agEb "x" >/dev/null; appendLED --session sAC3b --task 1100 --role executor          --agent agEb --artifact "branch feat/x"
mk_transcript sAC3b agVb "x" >/dev/null; appendLED --session sAC3b --task 1100 --role execution-review  --agent agVb --artifact "$AREV"
OUT3=$(checkLED --session sAC3b --task 1100); C3=$?
{ [ "$C3" = "0" ] && echo "$OUT3" | grep -qi "PROVENANCE"; } \
  && ok "AC3- no self_authored stamps -> check surfaces PROVENANCE flag (exit 0, not bricked)" \
  || bad "AC3- should flag provenance (C3=$C3 out=$OUT3)"

# ---- AC3 strict. --require-provenance promotes a missing stamp to a BLOCK (opt-in strict, never default) ----
OUT3r=$(checkLED --session sAC3b --task 1100 --require-provenance); C3r=$?
{ [ "$C3r" = "2" ] && echo "$OUT3r" | grep -qi "self_authored provenance stamp"; } \
  && ok "AC3 --require-provenance -> missing stamp BLOCKs (opt-in strict)" \
  || bad "AC3 require-provenance should block (C3r=$C3r out=$OUT3r)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1495 — research seat ledger-visibility (non-gating, tier-audited). Widen ONLY the explicit `ROLE:`
# alternation at `:104` to accept `research`; the keyword-classifier (`:107-113`) gains NO research keyword.
# Fixture bodies are deliberately keyword-clean (no "build"/"implement"/"executor"/etc — F8 fixture hygiene).
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# ---- [proof] S-RESEARCH (the core bug): ROLE:research + keyword-clean body -> exactly 1 research line.
#      RED on HEAD (no `research` arm at :104, keyword-classifier has no research keyword -> exit 0, 0 rows).
#      GREEN post-fix (n=1). RED baseline independently hand-confirmed pre-edit via git-stash probe.
TSR=$(mk_transcript sRSCH agR "3ROLE_TASK:1495 ROLE:research"$'\n'"You are the research seat. Investigate X.")
run "$TSR" sRSCH agR
n=$(ledger_count sRSCH 1495 research agR)
{ [ "$RC" = "0" ] && [ "$n" = "1" ]; } && ok "[proof] S-RESEARCH: ROLE:research tagged brief -> 1 ledger line" || bad "[proof] S-RESEARCH should write 1 research line (rc=$RC n=$n out=$CAP)"

# ---- [proof] S-RESEARCH-MODEL (green side, model fields): a research brief whose transcript ALSO carries a
#      message.model line -> the written line's modelTier + modelVersion are both non-empty (resolveModelFields
#      reached for free once cmdAppend's guard admits research). RED on HEAD: no row at all -> nothing to grep.
TSRM_D="$PROJROOT/proj/sRSCHM/subagents"; mkdir -p "$TSRM_D"
node -e '
  const fs=require("fs");
  const lines=[
    JSON.stringify({isSidechain:true,agentId:"agRM",sessionId:"sRSCHM",type:"user",message:{role:"user",content:"3ROLE_TASK:1495 ROLE:research\nYou are the research seat. Investigate X."}}),
    JSON.stringify({type:"assistant",agentId:"agRM",message:{model:"claude-sonnet-5",role:"assistant",content:[]}}),
  ];
  fs.writeFileSync(process.argv[1], lines.join("\n")+"\n");
' "$TSRM_D/agent-agRM.jsonl"
run "$TSRM_D/agent-agRM.jsonl" sRSCHM agRM
RMFILE="$LEDGERDIR/sRSCHM/1495.jsonl"
{ [ "$RC" = "0" ] && grep -q '"role":"research"' "$RMFILE" 2>/dev/null && grep -q '"modelTier":"sonnet"' "$RMFILE" 2>/dev/null && grep -q '"modelVersion":"claude-sonnet-5"' "$RMFILE" 2>/dev/null; } \
  && ok "[proof] S-RESEARCH-MODEL: research line carries resolved modelTier+modelVersion" \
  || bad "[proof] S-RESEARCH-MODEL should have modelTier+modelVersion (rc=$RC file=$(cat "$RMFILE" 2>/dev/null))"

# ---- [control] S-UNTAGGED-ZERO (AC8, negative guard): 3ROLE_TASK present, NO ROLE: tag, body free of the
#      keyword-classifier tokens -> ZERO rows (research AND executor both 0). PASSES on HEAD (untagged ->
#      classifier misses -> exit 0, 0 rows) AND post-fix (research arm only matches explicit ROLE:research —
#      widening the alternation must NOT start writing rows for untagged spawns).
TUNT=$(mk_transcript sUNT agU "3ROLE_TASK:1495"$'\n'"You are a helper. Investigate topic X and summarize.")
run "$TUNT" sUNT agU
nr=$(ledger_count sUNT 1495 research agU); ne=$(ledger_count sUNT 1495 executor agU)
{ [ "$RC" = "0" ] && [ "$nr" = "0" ] && [ "$ne" = "0" ]; } && ok "[control] S-UNTAGGED-ZERO: no ROLE: tag -> 0 rows (research not auto-classified)" || bad "[control] S-UNTAGGED-ZERO should write nothing (rc=$RC nr=$nr ne=$ne out=$CAP)"

# ---- [control] S-FOUR-UNCHANGED (regression guard): ROLE:planner still writes exactly 1 planner line;
#      ROLE:executor stays authoritative over a "review the plan" body. PASSES on HEAD AND post-fix.
TFP=$(mk_transcript sFOURp agFP "3ROLE_TASK:1495 ROLE:planner"$'\n'"You are the planner. Author a plan.")
run "$TFP" sFOURp agFP
npl=$(ledger_count sFOURp 1495 planner agFP)
TFE=$(mk_transcript sFOURe agFE "3ROLE_TASK:1495 ROLE:executor"$'\n'"Please review the plan thoroughly before you implement.")
run "$TFE" sFOURe agFE
nex=$(ledger_count sFOURe 1495 executor agFE); npr=$(ledger_count sFOURe 1495 plan-review agFE)
{ [ "$npl" = "1" ] && [ "$nex" = "1" ] && [ "$npr" = "0" ]; } && ok "[control] S-FOUR-UNCHANGED: the four roles unregressed by widening the alternation" || bad "[control] S-FOUR-UNCHANGED broken (npl=$npl nex=$nex npr=$npr)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
