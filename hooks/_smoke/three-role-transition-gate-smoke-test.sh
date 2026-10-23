#!/usr/bin/env bash
# Smoke for three-role-transition-gate.sh (#851 PR2, Phase 3b; HARDENED #1575). Exit 0 = all cases pass.
#
# #1575 changed the gate's contract from PRESENCE-keyed ("does a plan-review line exist?") to
# COMPLETION+VERDICT-keyed ("did a plan-review actually run, for THIS task, and pass?"). This suite covers
# the plan's full Binary AC set for Lane 1 (hooks/3role-ledger.mjs gate-plan-review + the two 1a
# terminal-evidence-guard clauses + the three cmdInherit preconditions + the Lane-1c spawn-record predicate),
# each case labeled with its AC id from `.ai-workspace/plans/2026-07-11-1575-spawn-gate-integrity.md`.
# AC-4j (the role x clause uniformity matrix) lives in hooks/3role-ledger-smoke-test.sh — it tests the
# overlayAppend guard only, with no gate-side sub-check (the gate reads plan-review lines only).
#
# No `set -e` (a non-block non-zero must not be read as a permission decision — #749 fail-closed-smoke lesson).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-transition-gate.sh"
SPAWN_LEDGER="$ROOT/hooks/three-role-spawn-ledger.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export RULE12_LOG="$TMP/rule12.log"  # #3109: never write the operator's real audit log during a suite run.
LEDGERDIR="$TMP/ledger"; PROJROOT="$TMP/projects"

appendL()      { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" append "$@" >/dev/null 2>&1; }
appendL_out()  { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" append "$@" 2>&1; }
inheritL_out() { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" inherit-plan-review "$@" 2>&1; }
# positive control: prove a grep PATTERN correctly matches a KNOWN synthetic line (catches a broken pattern
# silently reporting a false PASS/FAIL on the real fixture) — required by AC-4b(ii)/AC-4c(ii)/AC-4f(ii).
grep_ctrl() { printf '%s\n' "$2" | grep -Ec "$1"; }

printf '## Review\nverdict: PASS\n' > "$TMP/rev.md"

# run the gate with a raw payload string
run() { CAP=$(printf '%s' "$1" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# #2051 AC-7: variant that ALSO forwards CC_ROUTES_JSON to the hook subprocess — the existing run() helper
# forwards only THREE_ROLE_LEDGER_DIR + THREE_ROLE_PROJECTS_ROOT, so an arm that omitted this would silently
# evaluate against the shipped config/cc-routes.json (non-hermetic) and NOT satisfy AC-7.
run_routes() { CAP=$(printf '%s' "$1" | CC_ROUTES_JSON="$OR_ROUTES" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# #2051 AC-7 hermeticity discriminator: the SAME row under a fixture SSOT-SILENT routes (plan-review has no
# dispatch field). If CC_ROUTES_JSON is genuinely delivered + consulted, this BLOCKs not-finished (arm 3
# returns null -> fall through -> no closedAt/agentId); run_routes() ALLOWs the same row under the fixture
# subprocess routes. The ONLY variable between the two is CC_ROUTES_JSON — collapsing to the same answer
# would mean the fixture SSOT was never consulted (the green arm was riding the shipped config, not the fixture).
run_routes_none() { CAP=$(printf '%s' "$1" | CC_ROUTES_JSON="$OR_ROUTES_NONE" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# convenience: an Agent spawn payload with prompt $1, session $2
agent() { printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"prompt":"%s"}}' "$2" "$1"; }
# #2051/#2700: a validly-bound subprocess-openrouter transcript (a `claude -p` one-shot's own transcript
# shape) in the MEASURED shape (#2700 R3, all three #2694-plan transcripts): record 1 = queue-operation/
# enqueue carrying `3ROLE_TASK:<task> ROLE:plan-review` + this dispatch's nonce at the TOP-LEVEL `content`
# field, NO `cwd`; record 2 = queue-operation/dequeue, no `cwd`; record 3 = a `user` record — the FIRST
# record that carries `cwd` (when $5 is given) — repeating the tag+nonce; record 4 = an `assistant` record
# serving the SSOT-declared model, carrying the SAME `cwd`. A transcript with `cwd` on record 1 is NOT a
# valid fixture (the harness never writes it, #2700 D1) — this builder never produces one. Mirrors the node
# smoke's mk_or_transcript (kept identical by hand, #2051 "one evaluator, no mirror" discipline extended to
# fixtures).
mk_or_transcript() { # $1=path $2=task $3=nonce $4=served-model $5=dispatch-cwd (optional; omit for no cwd on any record)
  node -e '
    const fs = require("fs");
    const [ , outPath, task, nonce, model, cwd ] = process.argv;
    const lines = [];
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "or-fixture", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview this plan" }));
    lines.push(JSON.stringify({ type: "queue-operation", operation: "dequeue", timestamp: "2026-01-01T00:00:01.000Z", sessionId: "or-fixture" }));
    const userRec = { type: "user", timestamp: "2026-01-01T00:00:02.000Z",
      message: { role: "user", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce } };
    if (cwd) userRec.cwd = cwd;
    lines.push(JSON.stringify(userRec));
    const asstRec = { type: "assistant", timestamp: "2026-01-01T00:00:03.000Z", message: { model, content: [ { type: "text", text: "ok" } ] } };
    if (cwd) asstRec.cwd = cwd;
    lines.push(JSON.stringify(asstRec));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3" "$4" "${5:-}"
}
# #2051: append a plan-review row carrying the subprocess provenance fields under the fixture routes env.
or_append() { # $1=session $2=task <append-args...>
  local S="$1" T="$2"; shift 2
  CC_ROUTES_JSON="$OR_ROUTES" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
    node "$LED" append --session "$S" --task "$T" --role plan-review "$@" >/dev/null 2>&1
}

# ---- BOUND transcript fixture builder (round-4 fixture vocabulary): the FIRST record IS the spawn record —
#      the realistic shape a real subagent transcript has (first record = spawn prompt). ----
mk_bound() { # <session> <agentId> <task> <role>
  mkdir -p "$PROJROOT/proj/$1/subagents"
  printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4" \
    > "$PROJROOT/proj/$1/subagents/agent-$2.jsonl"
}
# ---- CONTAMINATED planner transcript (round-4 D1 realistic fixture): FIRST record = the planner's OWN spawn
#      tag (right task, WRONG role — the agentId every orchestrator holds for free); a LATER record is
#      tool-result-shaped and carries the plan-review tag as a MENTION (the plan file's own required
#      `## Review` byline arriving via Read — Invariant 6). A whole-file scan binds to this; a spawn-record
#      scan must not. ----
mk_contaminated_planner() { # <session> <agentId> <task>
  mkdir -p "$PROJROOT/proj/$1/subagents"
  {
    printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:planner -- author the plan"}}\n' "$3"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"plan file:\\n## Review\\n\\n3ROLE_TASK:%s ROLE:plan-review\\n\\ndecision: PASS"}]}]}}\n' "$3"
  } > "$PROJROOT/proj/$1/subagents/agent-$2.jsonl"
}
# a parent planner artifact naming a leg id (the #1064 discipline: tag CHILD ids in the plan).
mk_plan_naming_leg() { printf '## ELI5\na plan\n### Binary AC\n- AC1\nleg: %s\n' "$2" > "$1"; } # <path> <legId>
# a FULLY legit inherit-able parent: bound planner (artifact names the leg) + bound, affirmative plan-review.
mk_legit_parent() { # <session> <parentTask> <legId>
  local pplan="$TMP/parent-$2-plan.md"
  mk_plan_naming_leg "$pplan" "$3"
  mk_bound "$1" "pp-$2" "$2" "planner"
  appendL --session "$1" --task "$2" --role planner --agent "pp-$2" --artifact "$pplan"
  mk_bound "$1" "pr-$2" "$2" "plan-review"
  appendL --session "$1" --task "$2" --role plan-review --agent "pr-$2" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
}
# the NEW happy-path shape: a COMPLETED, bound, affirmative plan-review row (a bare presence-only line no
# longer satisfies the hardened gate — that is exactly AC-1's HERO fix).
add_planreview() { # <session> <task>
  local agent="agR-$2"
  mk_bound "$1" "$agent" "$2" "plan-review"
  appendL --session "$1" --task "$2" --role plan-review --agent "$agent" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# REGRESSION — the original #851 PR2 cases, updated where the hardened contract changed the expected outcome.
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# ---- R1. untagged Agent prompt -> allow silent (honest fail-open) ----
run "$(agent 'just go do some research, no tags' sR1)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R1 untagged spawn -> allow silent (fail-open)" || bad "R1 untagged should allow silent (rc=$RC out=$CAP)"

# ---- R2. ROLE:planner spawn -> ALLOW (no precondition), even with no ledger ----
run "$(agent '3ROLE_TASK:851 ROLE:planner -- author the plan' sR2)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R2 planner spawn -> ALLOW (no precondition)" || bad "R2 planner should allow (rc=$RC out=$CAP)"

# ---- R2b. ROLE:plan-review spawn -> ALLOW (reviewer must be free to run) ----
run "$(agent '3ROLE_TASK:851 ROLE:plan-review -- review the plan' sR2b)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R2b plan-review spawn -> ALLOW" || bad "R2b plan-review should allow (rc=$RC out=$CAP)"

# ---- R2c. ROLE:execution-review spawn -> ALLOW ----
run "$(agent '3ROLE_TASK:851 ROLE:execution-review -- review the diff' sR2c)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R2c execution-review spawn -> ALLOW" || bad "R2c execution-review should allow (rc=$RC out=$CAP)"

# ---- R3. kill-switches -> ALLOW even for executor w/o plan-review ----
CAP=$(printf '%s' "$(agent '3ROLE_TASK:851 ROLE:executor' sR3)" | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R3 THREE_ROLE_INSTRUMENT_OFF=1 -> ALLOW" || bad "R3 OFF kill-switch should allow (rc=$RC out=$CAP)"
CAP=$(printf '%s' "$(agent '3ROLE_TASK:851 ROLE:executor' sR3)" | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R3 SHIP_PIPELINE=1 -> ALLOW" || bad "R3 SHIP_PIPELINE kill-switch should allow (rc=$RC out=$CAP)"

# ---- R4. malformed stdin -> allow silent (fail-open) ----
run 'not json at all {{{'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R4 malformed input -> allow silent (fail-open)" || bad "R4 malformed should fail-open (rc=$RC out=$CAP)"

# ---- R5. BYPASS-FORM: tag delivered via tool_input.description (not prompt) -> still BLOCK executor ----
run '{"tool_name":"Task","session_id":"sR5","tool_input":{"description":"3ROLE_TASK:851 ROLE:executor build it"}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "R5 tag via description field -> BLOCK executor (bypass-form closed)" || bad "R5 description-field executor should block (rc=$RC out=$CAP)"

# ---- R6. BYPASS-FORM: tag mid-prompt with surrounding noise -> still BLOCK executor ----
run "$(agent 'preamble text ... 3ROLE_TASK:851 ROLE:executor ... trailing instructions here' sR6)"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "R6 tag mid-prompt+noise -> BLOCK executor (bypass-form closed)" || bad "R6 mid-prompt executor should block (rc=$RC out=$CAP)"

# ---- R7. executor tagged but NO session -> documented fail-open ALLOW (completion gate is the backstop) ----
run '{"tool_name":"Agent","tool_input":{"prompt":"3ROLE_TASK:851 ROLE:executor"}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "R7 executor tagged + no session -> ALLOW (documented fail-open)" || bad "R7 no-session executor should fail-open allow (rc=$RC out=$CAP)"

# ---- R8. a COMPLETED plan-review for a DIFFERENT task does NOT satisfy 851's executor -> BLOCK (per-task isolation) ----
add_planreview sR8 999
run "$(agent '3ROLE_TASK:851 ROLE:executor' sR8)"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "R8 plan-review for task 999 does NOT unlock 851 executor -> BLOCK" || bad "R8 cross-task plan-review must not satisfy (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-1 (HERO) — backgrounded dispatch no longer satisfies. Also satisfies AC-9(a): the run_in_background
# dispatch fixture, piped through the REAL hooks/three-role-spawn-ledger.sh writer.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac1"; T="1575"
DISPATCH_PAYLOAD='{"hook_event_name":"PostToolUse","tool_name":"Agent","session_id":"'"$S"'","run_in_background":true,"tool_input":{"prompt":"3ROLE_TASK:'"$T"' ROLE:plan-review -- review the plan"}}'
printf '%s' "$DISPATCH_PAYLOAD" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$SPAWN_LEDGER" >/dev/null 2>&1
run "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "verdict"; } && ok "AC-1 (HERO) backgrounded dispatch line no longer satisfies -> BLOCK" || bad "AC-1 dispatch-only should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-1b (HERO) — CONTAMINATED planner transcript does not bind (D1 realistic fixture).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac1b"; T="1b-task"
mk_contaminated_planner "$S" "AGPLANNER" "$T"
appendL --session "$S" --task "$T" --role plan-review --agent "AGPLANNER" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not spawn-record-bound"; } && ok "AC-1b (HERO) contaminated planner transcript does not bind -> BLOCK (names failed spawn-record binding)" || bad "AC-1b should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-1c — unbound-form sub-checks: (i) absent agentId; (ii) ghost agentId.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac1c"; T="1ci-task"
appendL --session "$S" --task "$T" --role plan-review --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-1c(i) verdict+closedAt, NO --agent -> BLOCK" || bad "AC-1c(i) should block (rc=$RC out=$CAP)"

T2="1cii-task"
appendL --session "$S" --task "$T2" --role plan-review --agent "ghost-does-not-exist" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T2 ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-1c(ii) ghost agentId (no matching transcript) -> BLOCK" || bad "AC-1c(ii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-1d (HERO) — converse positive control: contamination must not OVER-block the honest path. A NEWER
# contaminated sibling transcript on disk (the r3-measured normal post-round-2 state) must not steal the slot
# from the ROW'S OWN cited (older, but genuinely bound) agentId.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac1d"; T="1d-task"
mk_bound "$S" "AGREV" "$T" "plan-review"
sleep 1
mk_contaminated_planner "$S" "AGPLANNER" "$T"   # written AFTER -> strictly NEWER mtime than AGREV
appendL --session "$S" --task "$T" --role plan-review --agent "AGREV" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-1d (HERO) contaminated NEWER sibling does not steal the honestly-cited real reviewer's slot -> ALLOW" || bad "AC-1d should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-2 — transcribed PASS at dispatch (no closedAt) blocks.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac2"; T="2-task"
appendL --session "$S" --task "$T" --role plan-review --artifact "$TMP/rev.md" --verdict PASS
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-2 verdict PASS with NO closedAt (dispatch-transcribed) -> BLOCK" || bad "AC-2 should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-3 — finished but verdict-less blocks.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac3"; T="3-task"
appendL --session "$S" --task "$T" --role plan-review --agent "agX3" --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-3 closedAt present but NO verdict -> BLOCK" || bad "AC-3 should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4 — negative verdict blocks, with a message distinct from AC-3's "not finished" class.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4"; T="4-task"
appendL --session "$S" --task "$T" --role plan-review --agent "agX4" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "did not pass"; } && ok "AC-4 negative verdict (BLOCK) -> BLOCK, distinct re-plan/re-review message" || bad "AC-4 should block with a distinct message (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4b (HERO) — downgrade-to-skip REFUSED, three sub-checks.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4b"; T="4b-task"
mk_bound "$S" "ag1-4b" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "ag1-4b" --artifact "$TMP/rev.md" --verdict BLOCK --closed-at "2026-07-11T00:00:00.000Z"
SKIP_OUT=$(appendL_out --session "$S" --task "$T" --role plan-review --skip-reason "design tightly coupled to live session state"); SKIP_RC=$?
LEDFILE="$LEDGERDIR/$S/$T.jsonl"
vcount=$(grep -Ec '"verdict":"BLOCK"' "$LEDFILE"); ctrl=$(grep_ctrl '"verdict":"BLOCK"' '{"role":"plan-review","verdict":"BLOCK","agentId":"x"}')
{ [ "$SKIP_RC" != "0" ] && echo "$SKIP_OUT" | grep -qi "completed verdict"; } && ok "AC-4b(i) skip-append exits NONZERO, names the existing BLOCK verdict" || bad "AC-4b(i) failed (rc=$SKIP_RC out=$SKIP_OUT)"
{ [ "$vcount" = "1" ] && [ "$ctrl" = "1" ]; } && ok "AC-4b(ii) ledger line STILL carries the verdict (positive control included)" || bad "AC-4b(ii) verdict not retained (count=$vcount ctrl=$ctrl)"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4b(iii) executor spawn still BLOCKed" || bad "AC-4b(iii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4c (HERO) — downgrade-to-INHERIT refused (parent fully legit; only the leg's own verdict can refuse).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4c"; P="4c-parent"; LEG="4c-leg"
mk_legit_parent "$S" "$P" "$LEG"
mk_bound "$S" "AGB-4c" "$LEG" "plan-review"
appendL --session "$S" --task "$LEG" --role plan-review --agent "AGB-4c" --artifact "$TMP/rev.md" --verdict BLOCK --closed-at "2026-07-11T00:00:00.000Z"
INH_OUT=$(inheritL_out --session "$S" --task "$LEG" --parent "$P"); INH_RC=$?
LEGFILE="$LEDGERDIR/$S/$LEG.jsonl"
vcount=$(grep -Ec '"verdict":"BLOCK"' "$LEGFILE"); icount=$(grep -Ec '"inherited_from"' "$LEGFILE")
ctrl_v=$(grep_ctrl '"verdict":"BLOCK"' '{"verdict":"BLOCK"}'); ctrl_i=$(grep_ctrl '"inherited_from"' '{"inherited_from":"x"}')
{ [ "$INH_RC" != "0" ] && echo "$INH_OUT" | grep -qi "completed plan-review verdict"; } && ok "AC-4c(i) inherit exits NONZERO, names the existing BLOCK verdict" || bad "AC-4c(i) failed (rc=$INH_RC out=$INH_OUT)"
{ [ "$vcount" = "1" ] && [ "$icount" = "0" ] && [ "$ctrl_v" = "1" ] && [ "$ctrl_i" = "1" ]; } && ok "AC-4c(ii) verdict retained, nothing laundered (positive controls included)" || bad "AC-4c(ii) failed (v=$vcount i=$icount ctrl_v=$ctrl_v ctrl_i=$ctrl_i)"
run "$(agent "3ROLE_TASK:$LEG ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4c(iii) executor spawn for the leg still BLOCKed" || bad "AC-4c(iii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4d — unrelated parent refused (the relation check; leg is verdict-less so ONLY the relation check
# can refuse).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4d"; P="4d-parent"; LEG="4d-leg"
pplan="$TMP/parent-4d-plan.md"; mk_plan_naming_leg "$pplan" "some-other-leg-not-4d"
mk_bound "$S" "pp-4d" "$P" "planner"; appendL --session "$S" --task "$P" --role planner --agent "pp-4d" --artifact "$pplan"
mk_bound "$S" "pr-4d" "$P" "plan-review"; appendL --session "$S" --task "$P" --role plan-review --agent "pr-4d" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
INH_OUT=$(inheritL_out --session "$S" --task "$LEG" --parent "$P"); INH_RC=$?
LEGFILE="$LEDGERDIR/$S/$LEG.jsonl"
icount=0; [ -f "$LEGFILE" ] && icount=$(grep -Ec '"inherited_from"' "$LEGFILE")
{ [ "$INH_RC" != "0" ]; } && ok "AC-4d(i) inherit exits NONZERO (relation check refuses)" || bad "AC-4d(i) should refuse (rc=$INH_RC out=$INH_OUT)"
{ [ "$icount" = "0" ]; } && ok "AC-4d(ii) leg ledger gains no inherited_from line" || bad "AC-4d(ii) failed (icount=$icount)"
run "$(agent "3ROLE_TASK:$LEG ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4d(iii) executor spawn for the leg still BLOCKed" || bad "AC-4d(iii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4e — non-affirmative verdict on an INHERITED row blocks at the gate (the every-arm universal screen).
# Built via RAW write (the hardened helper refuses to produce this shape) -- the stated ceiling residual.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4e"; T="4e-task"
LEDFILE="$LEDGERDIR/$S/$T.jsonl"; mkdir -p "$(dirname "$LEDFILE")"
printf '{"role":"plan-review","session_id":"%s","verdict":"BLOCK","inherited_from":"parentX","agentId":"agX4e","artifact_path":"%s"}\n' "$S" "$TMP/rev.md" > "$LEDFILE"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4e non-affirmative verdict on an inherited row -> BLOCK (universal screen)" || bad "AC-4e should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4f (HERO) — DOWNGRADE-TO-VERDICT-FLIP refused (the r3 D5 live repro), four sub-checks incl. (iv) the
# mid-run variant (prior row has no closedAt yet).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4f"; T="4f-task"
mk_bound "$S" "AGB-4f" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "AGB-4f" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK
FLIP_OUT=$(appendL_out --session "$S" --task "$T" --role plan-review --verdict PASS); FLIP_RC=$?
LEDFILE="$LEDGERDIR/$S/$T.jsonl"
bcount=$(grep -Ec '"verdict":"BLOCK"' "$LEDFILE"); pcount=$(grep -Ec '"verdict":"PASS"' "$LEDFILE")
ctrl_b=$(grep_ctrl '"verdict":"BLOCK"' '{"verdict":"BLOCK"}'); ctrl_p=$(grep_ctrl '"verdict":"PASS"' '{"verdict":"PASS"}')
{ [ "$FLIP_RC" != "0" ] && echo "$FLIP_OUT" | grep -qi "completed verdict"; } && ok "AC-4f(i) bare verdict flip refused (exits NONZERO, names the existing BLOCK)" || bad "AC-4f(i) failed (rc=$FLIP_RC out=$FLIP_OUT)"
{ [ "$bcount" = "1" ] && [ "$pcount" = "0" ] && [ "$ctrl_b" = "1" ] && [ "$ctrl_p" = "1" ]; } && ok "AC-4f(ii) BLOCK survives, PASS never lands (positive controls included)" || bad "AC-4f(ii) failed (b=$bcount p=$pcount ctrl_b=$ctrl_b ctrl_p=$ctrl_p)"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4f(iii) executor spawn still BLOCKed" || bad "AC-4f(iii) should block (rc=$RC out=$CAP)"

# (iv) mid-run variant: the prior row has NO closedAt yet (a reviewer that self-appended a verdict but has
# not been close-stamped) -- the same bare flip must STILL be refused.
S2="s-ac4fiv"; T2="4fiv-task"
mk_bound "$S2" "AGB-4fiv" "$T2" "plan-review"
appendL --session "$S2" --task "$T2" --role plan-review --agent "AGB-4fiv" --verdict BLOCK
FLIP_OUT2=$(appendL_out --session "$S2" --task "$T2" --role plan-review --verdict PASS); FLIP_RC2=$?
{ [ "$FLIP_RC2" != "0" ]; } && ok "AC-4f(iv) mid-run variant (prior row has no closedAt) -> bare flip STILL refused" || bad "AC-4f(iv) failed (rc=$FLIP_RC2 out=$FLIP_OUT2)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4g — same-agent flip refused (distinctness, not mere presence).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4g"; T="4g-task"
mk_bound "$S" "AGB-4g" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "AGB-4g" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK
FLIP_OUT=$(appendL_out --session "$S" --task "$T" --role plan-review --verdict PASS --agent "AGB-4g" --closed-at "2026-07-11T00:00:01.000Z"); FLIP_RC=$?
LEDFILE="$LEDGERDIR/$S/$T.jsonl"
bcount=$(grep -Ec '"verdict":"BLOCK"' "$LEDFILE")
{ [ "$FLIP_RC" != "0" ] && [ "$bcount" = "1" ]; } && ok "AC-4g same-agent verdict change refused (bound + present is not enough -- must be DISTINCT)" || bad "AC-4g failed (rc=$FLIP_RC bcount=$bcount out=$FLIP_OUT)"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4g executor spawn still BLOCKed" || bad "AC-4g should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4h — genuine re-review SUPERSEDES (the clause-2 positive control -- the ONLY sanctioned re-review path
# must stay open, or an honest BLOCK bricks the lane forever).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4h"; T="4h-task"
mk_bound "$S" "AGB-4h" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "AGB-4h" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK
mk_bound "$S" "AGB2-4h" "$T" "plan-review"
SUP_OUT=$(appendL_out --session "$S" --task "$T" --role plan-review --verdict PASS --agent "AGB2-4h" --closed-at "2026-07-11T00:00:01.000Z"); SUP_RC=$?
LEDFILE="$LEDGERDIR/$S/$T.jsonl"
{ [ "$SUP_RC" = "0" ] && grep -q '"verdict":"PASS"' "$LEDFILE" && grep -q '"agentId":"AGB2-4h"' "$LEDFILE"; } && ok "AC-4h genuine NEW-bound-reviewer supersede succeeds" || bad "AC-4h failed (rc=$SUP_RC out=$SUP_OUT)"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-4h executor spawn now ALLOWED after the genuine supersede" || bad "AC-4h executor should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-4i — allowlist, not denylist: SHIP-WITH-FIXES and an unknown/typo'd token both BLOCK.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac4i"; T="4i-a"
mk_bound "$S" "ag4i" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "ag4i" --artifact "$TMP/rev.md" --verdict "SHIP-WITH-FIXES" --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4i(i) SHIP-WITH-FIXES (a real documented non-affirmative value) -> BLOCK" || bad "AC-4i(i) should block (rc=$RC out=$CAP)"

T2="4i-b"
mk_bound "$S" "ag4i2" "$T2" "plan-review"
appendL --session "$S" --task "$T2" --role plan-review --agent "ag4i2" --artifact "$TMP/rev.md" --verdict "PASSS" --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T2 ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-4i(ii) unknown/typo'd token (PASSS) -> BLOCK" || bad "AC-4i(ii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-5 — legit completed PASS allows (positive arm 1).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac5"; T="5-task"
mk_bound "$S" "ag5" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent "ag5" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-07-11T00:00:00.000Z"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-5 legit completed PASS allows -- positive control" || bad "AC-5 should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-6 — GENUINE inherited review allows (positive arm 2).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac6"; P="6-parent"; LEG="6-leg"
mk_legit_parent "$S" "$P" "$LEG"
INH_OUT=$(inheritL_out --session "$S" --task "$LEG" --parent "$P"); INH_RC=$?
{ [ "$INH_RC" = "0" ]; } && ok "AC-6 inherit-plan-review from a genuinely legit parent -> exit 0" || bad "AC-6 inherit should succeed (rc=$INH_RC out=$INH_OUT)"
run "$(agent "3ROLE_TASK:$LEG ROLE:executor" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-6 executor spawn for the leg -> ALLOWED" || bad "AC-6 executor should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-6b — a BLOCKed parent cannot be inherited (the verdict VALUE check, not just an artifact TOKEN).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac6b"; P="6b-parent"; LEG="6b-leg"
pplan="$TMP/parent-6b-plan.md"; mk_plan_naming_leg "$pplan" "$LEG"
mk_bound "$S" "pp-6b" "$P" "planner"; appendL --session "$S" --task "$P" --role planner --agent "pp-6b" --artifact "$pplan"
mk_bound "$S" "pr-6b" "$P" "plan-review"; appendL --session "$S" --task "$P" --role plan-review --agent "pr-6b" --artifact "$TMP/rev.md" --verdict BLOCK --closed-at "2026-07-11T00:00:00.000Z"
INH_OUT=$(inheritL_out --session "$S" --task "$LEG" --parent "$P"); INH_RC=$?
LEGFILE="$LEDGERDIR/$S/$LEG.jsonl"
icount=0; [ -f "$LEGFILE" ] && icount=$(grep -Ec '"inherited_from"' "$LEGFILE")
{ [ "$INH_RC" != "0" ] && [ "$icount" = "0" ]; } && ok "AC-6b BLOCKed parent (verdict VALUE, artifact still token-bearing) cannot be inherited" || bad "AC-6b should refuse (rc=$INH_RC icount=$icount out=$INH_OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-7 — skip arm CLOSED: the STRONGEST legal-looking skip (61+ chars, specific, passes NONSPECIFIC_RE) is
# still BLOCKed -- the deliberate inversion of the pre-round-3 "specific skip allows" behavior.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac7"; T="7-task"
appendL --session "$S" --task "$T" --role plan-review --skip-reason "design tightly coupled to live session state, reviewed inline per Invariant 6 carve-out"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "no skip path"; } && ok "AC-7 the strongest legal-looking skip -> BLOCK (no skip path at this gate)" || bad "AC-7 should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-8 — fail-closed on corrupt evidence: (i) pure substring-rich junk; (ii) trailing junk after a VALID line.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s-ac8"; T="8a-task"
LEDFILE="$LEDGERDIR/$S/$T.jsonl"; mkdir -p "$(dirname "$LEDFILE")"
printf 'plan-review verdict PASS closedAt now\n' > "$LEDFILE"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-8(i) substring-rich unparseable line -> BLOCK (JSON-parsing, not grep-shaped)" || bad "AC-8(i) should block (rc=$RC out=$CAP)"

T2="8b-task"
mk_bound "$S" "ag8b" "$T2" "plan-review"
LEDFILE2="$LEDGERDIR/$S/$T2.jsonl"; mkdir -p "$(dirname "$LEDFILE2")"
{
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag8b","verdict":"PASS","closedAt":"2026-07-11T00:00:00.000Z"}\n' "$S"
  printf 'plan-review verdict PASS closedAt now\n'
} > "$LEDFILE2"
run "$(agent "3ROLE_TASK:$T2 ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-8(ii) a valid ALLOW-shaped line FOLLOWED by trailing junk -> BLOCK (fail-closed on junk)" || bad "AC-8(ii) should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-9 — regression + heroes encoded in the repo smoke (this file). (a) is proven above (AC-1's fixture uses
# the real run_in_background spawn-ledger writer); (b) is proven above (AC-4b's downgrade sequence); (c) the
# LAST-MATCH cases, built via RAW two-line fixtures (the helper cannot produce two lines for one role today
# -- probe D measured exactly 1 line from a two-step append; raw >> is the only two-line builder, previewing
# the multi-line shape #1580 makes normal).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
[ "$(grep -c run_in_background "${BASH_SOURCE[0]}")" -ge 1 ] && ok "AC-9(a) smoke embeds a run_in_background dispatch fixture" || bad "AC-9(a) missing run_in_background fixture"

S="s-ac9c1"; T="9c1-task"
mk_bound "$S" "ag9c1" "$T" "plan-review"
LEDFILE9C1="$LEDGERDIR/$S/$T.jsonl"; mkdir -p "$(dirname "$LEDFILE9C1")"
{
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c1","verdict":"PASS","closedAt":"2026-07-11T00:00:00.000Z"}\n' "$S"
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c1","verdict":"BLOCK","closedAt":"2026-07-11T00:00:01.000Z"}\n' "$S"
} > "$LEDFILE9C1"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ]; } && ok "AC-9(c) last-match: stale ALLOW-shaped first, authoritative BLOCK-shaped last -> BLOCK (kills first-match)" || bad "AC-9(c) first case should block (rc=$RC out=$CAP)"

S="s-ac9c2"; T="9c2-task"
mk_bound "$S" "ag9c3" "$T" "plan-review"
LEDFILE9C2="$LEDGERDIR/$S/$T.jsonl"; mkdir -p "$(dirname "$LEDFILE9C2")"
{
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c2","verdict":"BLOCK","closedAt":"2026-07-11T00:00:00.000Z"}\n' "$S"
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c3","verdict":"PASS","closedAt":"2026-07-11T00:00:01.000Z"}\n' "$S"
} > "$LEDFILE9C2"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
# #2701 D3: a SAME-agent flip (ag9c2 BLOCK -> ag9c2 PASS) is now correctly BLOCKED by supersedesNegative's
# distinct-agent test -- re-fixtured with a DISTINCT, newer, bound agent (ag9c3) so this arm keeps its
# original last-match purpose (a stale BLOCK-shaped row must not out-rank an authoritative later ALLOW).
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-9(c) converse: stale BLOCK-shaped first, authoritative ALLOW-shaped+bound last by a DISTINCT newer agent -> ALLOW (kills last-line-only-if-it-blocks; #2701 D3 blocks a same-agent flip)" || bad "AC-9(c) converse case should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #2701 AC-4 (fix-cycle-1 B3; D3's M2 reorder, THROUGH THE REAL BASH GATE) -- execution-review's B3 finding:
# hooks/3role-ledger-smoke-test.sh's own #2701 AC-4 proves this at the ledger-CLI level, but the plan also
# names "one arm of the same shape ... through three-role-transition-gate.sh" and this file (unlike
# 3role-ledger-smoke-test.sh's cw_agent_round) never carried it. [agA PASS 01:00, agB FAIL 02:00], then a
# same-agent re-touch of the OLDER row (an artifact re-point, no verdict change -- the sanctioned repair the
# cross-wire memory itself prescribes) moves agA's PASS to the file's tail. Base (pre-D3): the gate reads the
# last LINE -> ALLOW. Head: D3's latest-round pre-screen reads the last ROUND -> BLOCK, naming agB.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
S="s2701-ac4"; T="2701ac4"
mk_bound "$S" "ag2701A" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent ag2701A --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00.000Z"
mk_bound "$S" "ag2701B" "$T" "plan-review"
appendL --session "$S" --task "$T" --role plan-review --agent ag2701B --artifact "$TMP/rev.md" --verdict FAIL --closed-at "2026-01-01T02:00:00.000Z"
appendL --session "$S" --task "$T" --role plan-review --agent ag2701A --artifact "$TMP/rev.md"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "did not pass" && echo "$CAP" | grep -q "ag2701B"; } \
  && ok "#2701 AC-4: D3 latest-round pre-screen through the REAL bash gate -- an M2 same-agent re-touch reorder must not resurrect an older PASS over a newer FAIL (base: ALLOW)" \
  || bad "#2701 AC-4 FAILED (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #2051 AC-7 — end-to-end through the REAL bash hook. The gate's third arm (subprocess-openrouter provenance
# via checkSubprocessProvenance) must fire for a real executor spawn, and the existing run() helper does NOT
# forward CC_ROUTES_JSON (only THREE_ROLE_LEDGER_DIR + THREE_ROLE_PROJECTS_ROOT), so these arms use run_routes()
# to demonstrably deliver CC_ROUTES_JSON to the hook's node subprocess — an arm that silently evaluated
# against the shipped config/cc-routes.json would be non-hermetic and would NOT satisfy this AC.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
OR_FIX="$TMP/or-fixtures"; mkdir -p "$OR_FIX/transcripts" "$OR_FIX/artifacts"
OR_ROUTES="$OR_FIX/routes.json"
cat > "$OR_ROUTES" <<'ORJSON'
{ "seats": { "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter", "agent_tool_fallback": "opus" } } }
ORJSON
# A SECOND fixture routes with plan-review as an ordinary anthropic seat (NO dispatch field) — the SSOT-silent
# control for the hermeticity discriminator below.
OR_ROUTES_NONE="$OR_FIX/routes-none.json"
cat > "$OR_ROUTES_NONE" <<'ORJSON'
{ "seats": { "plan-review": { "provider": "anthropic", "model": "claude-opus-5" } } }
ORJSON

# ---- AC-7 green: a real subprocess-openrouter plan-review PASS, piped through the real hook with
#      CC_ROUTES_JSON forwarded -> exit 0 (ALLOW silent). ----
S="s-ac7-2051"; T="t7-2051"
mk_or_transcript "$OR_FIX/transcripts/f-ac7.jsonl" "$T" "N-AC7-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC7-2051\n' > "$OR_FIX/artifacts/p-ac7.md"
or_append "$S" "$T" --dispatch subprocess-openrouter --transcript "$OR_FIX/transcripts/f-ac7.jsonl" \
  --nonce "N-AC7-2051" --artifact "$OR_FIX/artifacts/p-ac7.md" --verdict PASS
run_routes "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "#2051 AC-7 green: real subprocess plan-review PASS through the real bash hook (CC_ROUTES_JSON forwarded) -> ALLOW silent" \
  || bad "#2051 AC-7 green should ALLOW silent (rc=$RC out=$CAP)"

# ---- AC-7 red: the AC-2(a) forged-nonce mutation through the real hook -> exit 2, block message names
#      subprocess-unverified (the third arm's class token flows through the bash hook with no code change). ----
S="s-ac7r-2051"; T="t7r-2051"
mk_or_transcript "$OR_FIX/transcripts/f-ac7r.jsonl" "$T" "WRONG-NONCE-AC7R" "moonshotai/kimi-k3"   # forged nonce
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC7R-2051\n' > "$OR_FIX/artifacts/p-ac7r.md"
or_append "$S" "$T" --dispatch subprocess-openrouter --transcript "$OR_FIX/transcripts/f-ac7r.jsonl" \
  --nonce "N-AC7R-2051" --artifact "$OR_FIX/artifacts/p-ac7r.md" --verdict PASS
run_routes "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "subprocess-unverified"; } \
  && ok "#2051 AC-7 red: forged-nonce subprocess row through the real bash hook -> BLOCK, names subprocess-unverified (third-arm class flows through unchanged)" \
  || bad "#2051 AC-7 red should BLOCK naming subprocess-unverified (rc=$RC out=$CAP)"

# ---- AC-7 hermeticity discriminator: the SAME green-arm row, run through the real hook under a fixture
#      SSOT-SILENT routes (plan-review has no dispatch field) -> BLOCK not-finished. The green arm above
#      ALLOWs the identical row under the fixture subprocess routes. The ONLY variable between the two is
#      CC_ROUTES_JSON, so a collapse (same answer both ways) would mean the fixture SSOT was never consulted
#      and the green arm was riding the shipped config/cc-routes.json — non-hermetic, a FAIL for this AC. ----
S="s-ac7h-2051"; T="t7h-2051"
mk_or_transcript "$OR_FIX/transcripts/f-ac7h.jsonl" "$T" "N-AC7H-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC7H-2051\n' > "$OR_FIX/artifacts/p-ac7h.md"
or_append "$S" "$T" --dispatch subprocess-openrouter --transcript "$OR_FIX/transcripts/f-ac7h.jsonl" \
  --nonce "N-AC7H-2051" --artifact "$OR_FIX/artifacts/p-ac7h.md" --verdict PASS
run_routes_none "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not-finished"; } \
  && ok "#2051 AC-7 hermeticity: the green-arm row under fixture SSOT-SILENT routes -> BLOCK not-finished (the same row ALLOWs under the fixture subprocess routes via run_routes); CC_ROUTES_JSON is genuinely delivered + consulted, the green arm is hermetic" \
  || bad "#2051 AC-7 hermeticity discriminator FAILED: the green-arm row did NOT block not-finished under the SSOT-silent fixture routes (rc=$RC out=$CAP) — the green arm may be riding the shipped config, not the fixture"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #2700 — vantage-first artifact resolution, Fixture F, through the REAL bash hook. The dispatch's own
# recorded `cwd` (the FIRST transcript record that carries one — record 3, the first `user` record; never
# record 1, the bound `enqueue` record) is consulted BEFORE the checker's own vantage; the FIRST candidate
# that carries the nonce wins; a non-absolute recorded cwd contributes no candidate.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
F2700="$TMP/f2700"; mkdir -p "$F2700/wt/.ai-workspace/plans" "$F2700/primary" "$F2700/transcripts"
or_append_from() { # $1=cwd $2=session $3=task <append-args...>
  local CWDIR="$1" S="$2" T="$3"; shift 3
  ( cd "$CWDIR" && CC_ROUTES_JSON="$OR_ROUTES" THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" \
    node "$LED" append --session "$S" --task "$T" --role plan-review "$@" >/dev/null 2>&1 )
}
run_or_vantage() { # $1=payload $2=primary-cwd
  CAP=$(cd "$2" && printf '%s' "$1" | CC_ROUTES_JSON="$OR_ROUTES" CLAUDE_PROJECT_DIR="$2" \
    THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?
}
stored_artifact_path() { # $1=session $2=task
  node -e '
    const fs = require("fs");
    let lines = [];
    try { lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean); } catch (e) {}
    let last = null;
    for (const ln of lines) { try { const r = JSON.parse(ln); if (r.role === "plan-review" && r.artifact_path) last = r; } catch (e) {} }
    process.stdout.write(last ? last.artifact_path : "");
  ' "$LEDGERDIR/$1/$2.jsonl"
}
# a transcript whose FIRST record (enqueue) carries the tag but NOT the nonce -- record 3 (user) still
# carries `cwd` + tag + nonce, and the artifact still carries the nonce (#2700 AC-3b).
mk_or_transcript_unbound_enqueue() { # $1=path $2=task $3=nonce $4=served-model $5=dispatch-cwd
  node -e '
    const fs = require("fs");
    const [ , outPath, task, nonce, model, cwd ] = process.argv;
    const lines = [];
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "or-fixture", content: "3ROLE_TASK:" + task + " ROLE:plan-review\n\nreview this plan" }));   // NO nonce here (M2 control)
    lines.push(JSON.stringify({ type: "queue-operation", operation: "dequeue", timestamp: "2026-01-01T00:00:01.000Z", sessionId: "or-fixture" }));
    const userRec = { type: "user", timestamp: "2026-01-01T00:00:02.000Z",
      message: { role: "user", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce } };
    if (cwd) userRec.cwd = cwd;
    lines.push(JSON.stringify(userRec));
    const asstRec = { type: "assistant", timestamp: "2026-01-01T00:00:03.000Z", message: { model, content: [ { type: "text", text: "ok" } ] } };
    if (cwd) asstRec.cwd = cwd;
    lines.push(JSON.stringify(asstRec));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3" "$4" "${5:-}"
}

# ---- AC-1 (the bug): artifact present ONLY under the dispatch's recorded vantage (wt), absent under the
#      checker's own primary vantage -> ALLOW. Base (pre-#2700) BLOCKs this exact row "not found". ----
S="s-2700-ac1"; T="t-2700-ac1"
mk_or_transcript "$F2700/transcripts/f-ac1.jsonl" "$T" "N-AC1-2700" "moonshotai/kimi-k3" "$F2700/wt"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac1.jsonl" \
  --nonce "N-AC1-2700" --artifact ".ai-workspace/plans/p.md" --verdict PASS
[ "$(stored_artifact_path "$S" "$T")" = ".ai-workspace/plans/p.md" ] \
  && ok "#2700 fixture sanity (AC-1): stored artifact_path stayed relative" \
  || bad "#2700 fixture trap (AC-1): stored artifact_path is not relative ('$(stored_artifact_path "$S" "$T")')"
printf '## Review\nDISPATCH-NONCE:N-AC1-2700\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p.md"
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "#2700 AC-1: artifact present ONLY at the dispatch's recorded vantage (wt), absent at the checker's primary vantage -> ALLOW" \
  || bad "#2700 AC-1 should ALLOW (rc=$RC out=$CAP)"

# ---- AC-2a: truly missing everywhere -> BLOCK not found. ----
S="s-2700-ac2a"; T="t-2700-ac2a"
mk_or_transcript "$F2700/transcripts/f-ac2a.jsonl" "$T" "N-AC2A-2700" "moonshotai/kimi-k3" "$F2700/wt"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac2a.jsonl" \
  --nonce "N-AC2A-2700" --artifact ".ai-workspace/plans/p-ac2a.md" --verdict PASS
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "subprocess-unverified" && echo "$CAP" | grep -qi "not found"; } \
  && ok "#2700 AC-2a: artifact missing at every candidate -> BLOCK not found" \
  || bad "#2700 AC-2a should BLOCK not found (rc=$RC out=$CAP)"

# ---- AC-2b: artifact present under wt WITHOUT the nonce, nothing at primary -> BLOCK names the nonce
#      (never "not found" -- the vantage copy IS found, it just isn't bound to this dispatch). ----
S="s-2700-ac2b"; T="t-2700-ac2b"
mk_or_transcript "$F2700/transcripts/f-ac2b.jsonl" "$T" "N-AC2B-2700" "moonshotai/kimi-k3" "$F2700/wt"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac2b.jsonl" \
  --nonce "N-AC2B-2700" --artifact ".ai-workspace/plans/p-ac2b.md" --verdict PASS
printf '## Review\nDISPATCH-NONCE:SOME-OTHER-NONCE\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac2b.md"
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "does not contain this dispatch's nonce"; } \
  && ok "#2700 AC-2b: vantage copy exists but lacks this dispatch's nonce -> BLOCK names the nonce (not 'not found')" \
  || bad "#2700 AC-2b should BLOCK naming the nonce (rc=$RC out=$CAP)"

# ---- AC-2c: recorded cwd is an ABSENT directory -> vantage contributes no reachable candidate -> BLOCK
#      not found (fail-closed, never fail-open on a missing/odd vantage). ----
S="s-2700-ac2c"; T="t-2700-ac2c"
mk_or_transcript "$F2700/transcripts/f-ac2c.jsonl" "$T" "N-AC2C-2700" "moonshotai/kimi-k3" "$F2700/gone-vantage-dir"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac2c.jsonl" \
  --nonce "N-AC2C-2700" --artifact ".ai-workspace/plans/p-ac2c.md" --verdict PASS
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not found"; } \
  && ok "#2700 AC-2c: recorded cwd is an absent directory -> BLOCK not found (fail-closed)" \
  || bad "#2700 AC-2c should BLOCK not found (rc=$RC out=$CAP)"

# ---- AC-2d: recorded cwd is non-absolute (bare-relative, then ~/-form) -> IGNORED, never joined against
#      process.cwd()/HOME -- the real wt copy exists WITH the nonce, yet resolution still misses it because
#      the vantage candidate is never added; today's chain (checker cwd = primary) has no copy either. ----
S="s-2700-ac2d1"; T="t-2700-ac2d1"
mk_or_transcript "$F2700/transcripts/f-ac2d1.jsonl" "$T" "N-AC2D1-2700" "moonshotai/kimi-k3" "wt"
mkdir -p "$F2700/wt/.ai-workspace/plans"
printf '## Review\nDISPATCH-NONCE:N-AC2D1-2700\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac2d1.md"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac2d1.jsonl" \
  --nonce "N-AC2D1-2700" --artifact ".ai-workspace/plans/p-ac2d1.md" --verdict PASS
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not found"; } \
  && ok "#2700 AC-2d (bare-relative recorded cwd 'wt'): ignored, never joined -> BLOCK not found" \
  || bad "#2700 AC-2d (bare-relative) should BLOCK not found (rc=$RC out=$CAP)"

S="s-2700-ac2d2"; T="t-2700-ac2d2"
mk_or_transcript "$F2700/transcripts/f-ac2d2.jsonl" "$T" "N-AC2D2-2700" "moonshotai/kimi-k3" "~/wt"
printf '## Review\nDISPATCH-NONCE:N-AC2D2-2700\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac2d2.md"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac2d2.jsonl" \
  --nonce "N-AC2D2-2700" --artifact ".ai-workspace/plans/p-ac2d2.md" --verdict PASS
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not found"; } \
  && ok "#2700 AC-2d (tilde-form recorded cwd '~/wt'): ignored, never joined -> BLOCK not found" \
  || bad "#2700 AC-2d (tilde-form) should BLOCK not found (rc=$RC out=$CAP)"

# ---- AC-3b: record 1 (the bound enqueue record) lacks the nonce, even though record 3 carries the cwd and
#      the artifact carries the nonce -- a replayed/reused transcript must not bind (M2, unchanged). ----
S="s-2700-ac3b"; T="t-2700-ac3b"
mk_or_transcript_unbound_enqueue "$F2700/transcripts/f-ac3b.jsonl" "$T" "N-AC3B-2700" "moonshotai/kimi-k3" "$F2700/wt"
printf '## Review\nDISPATCH-NONCE:N-AC3B-2700\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac3b.md"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac3b.jsonl" \
  --nonce "N-AC3B-2700" --artifact ".ai-workspace/plans/p-ac3b.md" --verdict PASS
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "first record does"; } \
  && ok "#2700 AC-3b: bound record (enqueue) lacks the nonce -> BLOCK, never reaches artifact resolution (M2)" \
  || bad "#2700 AC-3b should BLOCK on the binding check (rc=$RC out=$CAP)"

# ---- AC-4: a nonce-less copy appears at the PRIMARY vantage AFTER the row is appended (stored path stays
#      relative) -- must NOT shadow the nonce-bound vantage copy. ----
S="s-2700-ac4"; T="t-2700-ac4"
mk_or_transcript "$F2700/transcripts/f-ac4.jsonl" "$T" "N-AC4-2700" "moonshotai/kimi-k3" "$F2700/wt"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac4.jsonl" \
  --nonce "N-AC4-2700" --artifact ".ai-workspace/plans/p-ac4.md" --verdict PASS
[ "$(stored_artifact_path "$S" "$T")" = ".ai-workspace/plans/p-ac4.md" ] \
  && ok "#2700 fixture sanity (AC-4): stored artifact_path stayed relative" \
  || bad "#2700 fixture trap (AC-4): stored artifact_path is not relative ('$(stored_artifact_path "$S" "$T")')"
printf '## Review\nDISPATCH-NONCE:N-AC4-2700\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac4.md"
mkdir -p "$F2700/primary/.ai-workspace/plans"
printf '## Review\nDISPATCH-NONCE:SOME-OTHER-NONCE\nDecision: PASS\n' > "$F2700/primary/.ai-workspace/plans/p-ac4.md"
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "#2700 AC-4: a nonce-less primary copy created after append must not shadow the nonce-bound vantage copy -> ALLOW" \
  || bad "#2700 AC-4 should ALLOW (rc=$RC out=$CAP)"

# ---- AC-4b (monotone, PASS at both ends): roles swapped -- the VANTAGE copy lacks the nonce, the PRIMARY
#      copy carries it. A "vantage-first, first-EXISTING-wins" implementation fails this (#1590 class); the
#      nonce must choose among candidates regardless of which one is tried first. ----
S="s-2700-ac4b"; T="t-2700-ac4b"
mk_or_transcript "$F2700/transcripts/f-ac4b.jsonl" "$T" "N-AC4B-2700" "moonshotai/kimi-k3" "$F2700/wt"
or_append_from "$F2700/primary" "$S" "$T" --dispatch subprocess-openrouter --transcript "$F2700/transcripts/f-ac4b.jsonl" \
  --nonce "N-AC4B-2700" --artifact ".ai-workspace/plans/p-ac4b.md" --verdict PASS
[ "$(stored_artifact_path "$S" "$T")" = ".ai-workspace/plans/p-ac4b.md" ] \
  && ok "#2700 fixture sanity (AC-4b): stored artifact_path stayed relative" \
  || bad "#2700 fixture trap (AC-4b): stored artifact_path is not relative ('$(stored_artifact_path "$S" "$T")')"
printf '## Review\nDISPATCH-NONCE:SOME-OTHER-NONCE\nDecision: PASS\n' > "$F2700/wt/.ai-workspace/plans/p-ac4b.md"
mkdir -p "$F2700/primary/.ai-workspace/plans"
printf '## Review\nDISPATCH-NONCE:N-AC4B-2700\nDecision: PASS\n' > "$F2700/primary/.ai-workspace/plans/p-ac4b.md"
run_or_vantage "$(agent "3ROLE_TASK:$T ROLE:executor -- implement it" "$S")" "$F2700/primary"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "#2700 AC-4b: nonce-less VANTAGE copy + nonce-bearing PRIMARY copy -> the nonce still wins -> ALLOW (kills first-existing-wins, M5)" \
  || bad "#2700 AC-4b should ALLOW (rc=$RC out=$CAP) -- a first-existing-wins implementation blocks this"


# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #3154 -- size-S plan-review waiver at the transition gate. Labels size-s-01 .. size-s-13 = plan cases 1-8,
# 13 and 14a-14d. REAL shape (plan fold B1): each fixture is a throw-away repo holding a COPY of the helper
# and of this hook, the plan lives ONLY at refs/remotes/origin/<task>-fixture (never on the cwd's disk), and
# every must-pass is first run against the pre-#3154 snapshot, where it must FAIL (RED-first).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
export THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" PROGRESS_TASKS_DIR="$TMP/s3154-tasks"
. "$DIR/_fixtures/size-s-fixture-lib.sh"
SZ_SNAP="$DIR/_fixtures/3role-ledger-pre3154-size-s-snapshot.mjs"
SZS="sess-3154g"
# sz_case <label> <task> <ticket-size|-> <plan-variant|-> : build a fixture repo (helper + hook copies) and a planner row.
sz_case() {
  local repo="$TMP/s3154-$2"
  sz_mk_repo "$repo" "$LED" "$2" "$4"
  cp "$HOOK" "$repo/hooks/three-role-transition-gate.sh"
  sz_ticket "$SZS" "$2" "$3"
  sz_planner "$repo/hooks/3role-ledger.mjs" "$SZS" "$2"
  SZ_REPO="$repo"
}
# gate through the helper copy in the fixture repo, from the repo cwd (plan not on disk there)
sz_gate() { sz_run "$SZ_REPO/hooks/3role-ledger.mjs" "$SZ_REPO" gate-plan-review --session "$SZS" --task "$1"; }
# the REAL hook, executor spawn payload, from the fixture repo. CLAUDE_PLUGIN_ROOT pins the hook's
# helper resolution at the fixture repo (#3154 R2-F1): the plugin copy of this hook prefers
# ${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs, and the plugin's CI runs this smoke with
# CLAUDE_PLUGIN_ROOT at the plugin checkout -- unpinned, that copy reads the PLUGIN's refs (never the
# fixture's refs/remotes/origin/<task>-fixture) and every must-pass arm goes plan-unresolvable. The
# fixture repo carries its own bin/ copy (sz_mk_repo), so pinning gives the SAME result in ai-brain
# (the canonical hook ignores the var) and in the plugin checkout.
sz_hook() { CAP=$(cd "$SZ_REPO" && printf '%s' "$(agent "3ROLE_TASK:$1 ROLE:executor -- implement it" "$SZS")" | CLAUDE_PLUGIN_ROOT="$SZ_REPO" bash "$SZ_REPO/hooks/three-role-transition-gate.sh" 2>&1 >/dev/null); RC=$?; }
# sz_hook_env <plugin-root|-> <task> : the REAL hook under an EXPLICIT CLAUDE_PLUGIN_ROOT ("-" = unset)
# -- the seam the R2-F1 held-out arms drive (a stand-in shaped like a plugin checkout, or the pin).
sz_hook_env() {
  if [ "$1" = "-" ]; then
    CAP=$(cd "$SZ_REPO" && printf '%s' "$(agent "3ROLE_TASK:$2 ROLE:executor -- implement it" "$SZS")" | env -u CLAUDE_PLUGIN_ROOT bash "$SZ_REPO/hooks/three-role-transition-gate.sh" 2>&1 >/dev/null); RC=$?
  else
    CAP=$(cd "$SZ_REPO" && printf '%s' "$(agent "3ROLE_TASK:$2 ROLE:executor -- implement it" "$SZS")" | CLAUDE_PLUGIN_ROOT="$1" bash "$SZ_REPO/hooks/three-role-transition-gate.sh" 2>&1 >/dev/null); RC=$?
  fi
}

# size-s-01 (case 1): RED on the snapshot, GREEN on the new helper, GREEN through the real hook
sz_case 01 92001 S S
sz_run "$SZ_SNAP" "$SZ_REPO" gate-plan-review --session "$SZS" --task 92001; RED=$SZ_RC
sz_gate 92001; G=$SZ_RC; sz_hook 92001
{ [ "$RED" = "2" ] && [ "$G" = "0" ] && [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "size-s-01 ok: ticket S + plan S, no plan-review -> snapshot BLOCK(2), new gate ALLOW(0), real hook ALLOW silent" || bad "size-s-01 (snapshot=$RED gate=$G hook=$RC/$CAP)"
# size-s-02: ticket M, plan S -> BLOCK naming ticket-size-M; the real hook's text names the S rule + keeps the no-skip line
sz_case 02 92002 M S; sz_gate 92002; G=$SZ_RC; GO=$SZ_OUT; sz_hook 92002
{ [ "$G" = "2" ] && printf '%s' "$GO" | command grep -q 'size-s: ticket-size-M' && [ "$RC" = "2" ] \
  && printf '%s' "$CAP" | command grep -q 'There is NO skip path for plan-review' && printf '%s' "$CAP" | command grep -q 'size-S' \
  && printf '%s' "$CAP" | command grep -q 'size-s: ticket-size-M'; } \
  && ok "size-s-02 ok: ticket M, plan S -> BLOCK 'size-s: ticket-size-M'; hook text keeps 'There is NO skip path' and names the size-S rule" || bad "size-s-02 (gate=$G/$GO hook=$RC/$CAP)"
# size-s-03: ticket L, plan L
sz_case 03 92003 L L; sz_gate 92003
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: ticket-size-L'; } && ok "size-s-03 ok: ticket L, plan L -> BLOCK 'size-s: ticket-size-L'" || bad "size-s-03 (rc=$SZ_RC out=$SZ_OUT)"
# size-s-04: ticket file absent
sz_case 04 92004 - S; sz_gate 92004
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: ticket-size-none'; } && ok "size-s-04 ok: ticket file absent -> BLOCK 'size-s: ticket-size-none'" || bad "size-s-04 (rc=$SZ_RC out=$SZ_OUT)"
# size-s-05: ticket S, plan M
sz_case 05 92005 S M; sz_gate 92005
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: plan-size-M'; } && ok "size-s-05 ok: ticket S, plan size: M -> BLOCK 'size-s: plan-size-M'" || bad "size-s-05 (rc=$SZ_RC out=$SZ_OUT)"
# size-s-06: upgrade mid-flight -- case 1 passes, ticket rewritten to M, gate AND check both block (live read)
sz_case 06 92006 S S
printf '## Review\nverdict: PASS\n' > "$TMP/s3154-rev.md"
sz_chain_tail "$SZ_REPO/hooks/3role-ledger.mjs" "$SZS" 92006 "$TMP/s3154-rev.md"
sz_gate 92006; P1=$SZ_RC
sz_run "$SZ_REPO/hooks/3role-ledger.mjs" "$SZ_REPO" check --session "$SZS" --task 92006; P2=$SZ_RC; P2O=$SZ_OUT
sz_ticket "$SZS" 92006 M
sz_gate 92006; P3=$SZ_RC; P3O=$SZ_OUT
sz_run "$SZ_REPO/hooks/3role-ledger.mjs" "$SZ_REPO" check --session "$SZS" --task 92006; P4=$SZ_RC; P4O=$SZ_OUT
{ [ "$P1" = "0" ] && [ "$P2" = "0" ] && [ "$P3" = "2" ] && [ "$P4" = "2" ] && printf '%s' "$P3O" | command grep -q 'ticket-size-M' && printf '%s' "$P4O" | command grep -q 'size-s: ticket-size-M'; } \
  && ok "size-s-06 ok: S passes gate+check, then ticket rewritten to M -> both exit 2 'ticket-size-M' (live read)" || bad "size-s-06 ($P1 $P2 $P3 $P4 | $P3O | $P4O)"
# size-s-07: ticket S, plan S, plus a NEEDS-WORK plan-review row -> BLOCK (the review governs; negative-verdict wins)
sz_case 07 92007 S S; sz_review_row "$SZ_REPO/hooks/3role-ledger.mjs" "$SZS" 92007 "$TMP/s3154-rev.md" NEEDS-WORK; sz_gate 92007
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'negative-verdict' && printf '%s' "$SZ_OUT" | command grep -q 'size-s: review-row-present'; } \
  && ok "size-s-07 ok: S + S with a NEEDS-WORK plan-review row -> BLOCK negative-verdict (size-s: review-row-present)" || bad "size-s-07 (rc=$SZ_RC out=$SZ_OUT)"
# size-s-08: plan unbound to the task (no Ticket line, no task id in the file name)
sz_mk_repo "$TMP/s3154-92008" "$LED" 92008 unbound ".ai-workspace/plans/2026-10-16-unrelated-plan.md"; SZ_REPO="$TMP/s3154-92008"
sz_ticket "$SZS" 92008 S; sz_planner "$SZ_REPO/hooks/3role-ledger.mjs" "$SZS" 92008 ".ai-workspace/plans/2026-10-16-unrelated-plan.md"; sz_gate 92008
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: plan-unbound'; } && ok "size-s-08 ok: plan lacks 'Ticket: #<task>' and the task id in its name -> BLOCK 'size-s: plan-unbound'" || bad "size-s-08 (rc=$SZ_RC out=$SZ_OUT)"
# size-s-09 (case 13): audit -- one SIZE-S-SKIP PERMIT per ALLOWING evaluation, none for blocked ones; carries plan + ticket_size
export RULE12_LOG="$TMP/s3154-r12.log"; : > "$RULE12_LOG"
sz_case 09 92009 S S; sz_gate 92009; A1=$SZ_RC
sz_ticket "$SZS" 92009 M; sz_gate 92009; A2=$SZ_RC
N=$(command grep -c 'SIZE-S-SKIP' "$RULE12_LOG"); LINE=$(command grep 'SIZE-S-SKIP' "$RULE12_LOG" | tail -1)
{ [ "$A1" = "0" ] && [ "$A2" = "2" ] && [ "$N" = "1" ] && printf '%s' "$LINE" | command grep -q '"decision":"PERMIT"' && printf '%s' "$LINE" | command grep -q '"task":"92009"' \
  && printf '%s' "$LINE" | command grep -q '"plan":".ai-workspace/plans/' && printf '%s' "$LINE" | command grep -q '"ticket_size":"S"'; } \
  && ok "size-s-09 ok: exactly one SIZE-S-SKIP PERMIT line (allowing eval), none for the blocked one; carries plan + ticket_size" || bad "size-s-09 (a1=$A1 a2=$A2 n=$N line=$LINE)"
# size-s-10 .. size-s-13 (cases 14a-14d)
sz_case 10 92010 XL S; sz_gate 92010
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: ticket-size-invalid'; } && ok "size-s-10 ok: ticket metadata.size \"XL\" -> BLOCK 'size-s: ticket-size-invalid'" || bad "size-s-10 (rc=$SZ_RC out=$SZ_OUT)"
sz_case 11 92011 S nosize; sz_gate 92011
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: plan-size-missing'; } && ok "size-s-11 ok: plan with no flush-left size: line -> BLOCK 'size-s: plan-size-missing'" || bad "size-s-11 (rc=$SZ_RC out=$SZ_OUT)"
sz_case 12 92012 S twosize; sz_gate 92012
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: plan-size-ambiguous'; } && ok "size-s-12 ok: plan with two flush-left size: lines -> BLOCK 'size-s: plan-size-ambiguous'" || bad "size-s-12 (rc=$SZ_RC out=$SZ_OUT)"
sz_case 13 92013 S S; printf 'this line is not json\n' >> "$LEDGERDIR/$SZS/92013.jsonl"; sz_gate 92013
{ [ "$SZ_RC" = "2" ] && printf '%s' "$SZ_OUT" | command grep -q 'size-s: ledger-junk'; } && ok "size-s-13 ok: ledger with trailing junk after the planner row -> BLOCK 'size-s: ledger-junk'" || bad "size-s-13 (rc=$SZ_RC out=$SZ_OUT)"

# size-s-ho1..ho4 (R2-F1 held-out arms, BOTH directions, invented for this fix round -- none taken from
# any review round). SZ_PLUG is a stand-in shaped like a plugin checkout: its own throw-away git repo
# carrying bin/3role-ledger.mjs (sz_mk_repo layout) whose refs hold NO fixture plan, so a hook that
# resolves its helper there reads the stand-in's refs, never the fixture's.
SZ_PLUG="$TMP/s3154-plugin-standin"; sz_mk_repo "$SZ_PLUG" "$LED" 92020 "-"
# ho1 MUST-fire: S ticket, plan blob absent everywhere, hook UNPINNED under the stand-in -> BLOCK
sz_case ho1 92021 S -; sz_hook_env "$SZ_PLUG" 92021
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | command grep -q 'plan-unresolvable'; } \
  && ok "size-s-ho1 ok: S ticket with the plan missing, hook under a foreign CLAUDE_PLUGIN_ROOT -> BLOCK plan-unresolvable (fails closed, never waived)" || bad "size-s-ho1 (rc=$RC out=$CAP)"
# ho2 MUST-fire: M ticket (live stamp), S plan, no plan-review, hook UNPINNED under the stand-in -> BLOCK
sz_case ho2 92022 M S; sz_hook_env "$SZ_PLUG" 92022
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | command grep -q 'size-s: ticket-size-M'; } \
  && ok "size-s-ho2 ok: M ticket with no plan-review under a foreign CLAUDE_PLUGIN_ROOT -> BLOCK ticket-size-M (the live stamp decides before any plan lookup)" || bad "size-s-ho2 (rc=$RC out=$CAP)"
# ho3 MUST-NOT-fire: correctly stamped S ticket + S plan, hook PINNED to the fixture repo (the plugin-CI shape)
sz_case ho3 92023 S S; sz_hook_env "$SZ_REPO" 92023
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "size-s-ho3 ok: S + plan with CLAUDE_PLUGIN_ROOT at the fixture repo -> ALLOW silent (same result in both layouts)" || bad "size-s-ho3 (rc=$RC out=$CAP)"
# ho4 MUST-NOT-fire: the same shape with CLAUDE_PLUGIN_ROOT unset (the ai-brain layout)
sz_case ho4 92024 S S; sz_hook_env - 92024
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "size-s-ho4 ok: S + plan with CLAUDE_PLUGIN_ROOT unset -> ALLOW silent (the ../bin fallback lands on the fixture copy)" || bad "size-s-ho4 (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #3333 — session alias: the plan-review lives under the OTHER ledger session this chat works for.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
SA="s-alias-chat"; SB="s-alias-ledger"; TA="3333-task"
add_planreview "$SB" "$TA"
# al1 MUST-NOT-fire (pre-alias answer kept): no alias file -> the executor spawn under SA still BLOCKs.
run "$(agent "3ROLE_TASK:$TA ROLE:executor" "$SA")"
[ "$RC" = "2" ] && ok "alias-1 no alias file -> plan-review under another session does not admit -> BLOCK" || bad "alias-1 (rc=$RC out=$CAP)"
# al2 MUST-fire: alias SA -> SB, the same spawn is admitted by SB's real completed PASS.
mkdir -p "$LEDGERDIR/.session-alias"; printf '%s\n' "$SB" > "$LEDGERDIR/.session-alias/$SA"
run "$(agent "3ROLE_TASK:$TA ROLE:executor" "$SA")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "alias-2 alias SA->SB + completed PASS under SB -> ALLOW" || bad "alias-2 (rc=$RC out=$CAP)"
# al3 MUST-NOT-fire: the alias session holds a PASS for a DIFFERENT task only -> BLOCK.
run "$(agent "3ROLE_TASK:3333-other ROLE:executor" "$SA")"
[ "$RC" = "2" ] && ok "alias-3 alias session has a PASS for a different task only -> BLOCK" || bad "alias-3 (rc=$RC out=$CAP)"
# al4 MUST-NOT-fire: the alias session's plan-review is NOT finished (no closedAt) -> BLOCK.
TA4="3333-open"; mk_bound "$SB" "agOpen" "$TA4" "plan-review"
appendL --session "$SB" --task "$TA4" --role plan-review --agent "agOpen" --artifact "$TMP/rev.md"
run "$(agent "3ROLE_TASK:$TA4 ROLE:executor" "$SA")"
[ "$RC" = "2" ] && ok "alias-4 alias session's plan-review unfinished -> BLOCK" || bad "alias-4 (rc=$RC out=$CAP)"
# al5 MUST-fire: the admitting alias is the 2nd line (a dead alias first) -> ALLOW.
printf 's-alias-dead\n%s\n' "$SB" > "$LEDGERDIR/.session-alias/$SA"
run "$(agent "3ROLE_TASK:$TA ROLE:executor" "$SA")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "alias-5 admitting alias on line 2 -> ALLOW" || bad "alias-5 (rc=$RC out=$CAP)"
# al6 MUST-NOT-fire: the admitting alias sits past the 8-alias bound -> not read -> BLOCK.
{ for i in 1 2 3 4 5 6 7 8; do echo "s-alias-dead$i"; done; echo "$SB"; } > "$LEDGERDIR/.session-alias/$SA"
run "$(agent "3ROLE_TASK:$TA ROLE:executor" "$SA")"
[ "$RC" = "2" ] && ok "alias-6 admitting alias past the 8-line bound -> BLOCK" || bad "alias-6 (rc=$RC out=$CAP)"
mv "$LEDGERDIR/.session-alias/$SA" "$TMP/alias-$SA.bak"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #3422 — the spawn's role is read from the HEADER pair (first non-empty line carrying 3ROLE_TASK + ROLE), never
# from a quoted ROLE: in the body. Both-ends: a PINNED pre-#3422 snapshot of this hook vs the live hook, in one run.
# The snapshot is materialized next to the live hook (its LED_HELPER sibling resolution must find the real ledger).
# Do NOT regenerate the snapshot from the live hook — the non-decay guard fails if they are byte-identical.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
BASE3422_HOOK="$(dirname "$HOOK")/.smoke-3422-base-$$.sh"
trap 'rm -rf "$TMP" "$BASE3422_HOOK"' EXIT
cat > "$BASE3422_HOOK" <<'PREFIX3422_EOF'
#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE TRANSITION GATE (#851 PR2, Phase 3b; hardened #1575). Enforces
# SEQUENCING of the 3-role model at SPAWN time: you cannot spawn the EXECUTOR for a task before the PLAN has
# been REVIEWED — and "reviewed" now means a COMPLETED review carrying an AFFIRMATIVE verdict, not merely a
# ledger LINE.
#
# Mechanism: the orchestrator prepends "3ROLE_TASK:<id> ROLE:<role>" to every role subagent's prompt (the same
# tag PR1's ledger + Phase 3a read). When an Agent/Task spawn carries ROLE:executor for task <id>, this gate
# shells out to `node hooks/3role-ledger.mjs gate-plan-review --session <session> --task <id>` — the SAME
# evaluator a node-level smoke exercises directly, so there is ONE implementation of the admission contract,
# not two. That evaluator reads the LAST PARSEABLE plan-review line, fail-closes on trailing junk, runs a
# universal verdict ALLOWLIST screen, then dispatches to exactly three sanctioned arms (the #2051 subprocess
# arm consulted FIRST after the verdict screen, mirroring checkRole's own consult-order):
#   (3) subprocess-openrouter (#2051) — affirmative verdict + a `dispatch=subprocess-openrouter` marker whose
#       SSOT seat is declared subprocess-dispatched, verified by the SAME checkSubprocessProvenance the
#       completion gate already trusts (a per-dispatch nonce stamped into the transcript's FIRST record AND
#       the artifact, the served model == the SSOT seat model, the transcript exists). A forged/replayed
#       nonce, a missing transcript, or an SSOT mismatch blocks `subprocess-unverified`. A bare marker with
#       the SSOT silent admits NOTHING (falls through to arms 1/2). Never a hand-typed ledger append — the
#       sanctioned route is re-running the dispatch via tools/openrouter-role-dispatch.sh.
#   (1) completed-review — affirmative verdict + closedAt (the SubagentStop punch-out) + an agentId whose
#       transcript is SPAWN-RECORD-bound (its FIRST record, not merely a later mention) to
#       `3ROLE_TASK:<id> ROLE:plan-review`;
#   (2) inherited-review — `inherited_from` + agentId + artifact_path, with the agentId PARENT-bound the same
#       way, keyed on the row's own `inherited_from`.
# #1575 (operator decision, round 3): there is NO skip arm at this gate any more — a `skip_reason`-only line,
# however specific, does NOT satisfy the executor precondition. A genuinely session-coupled lane runs its
# executor INLINE (untagged; see the honest limitation below) and never meets this gate.
#
# #1575 D1/round-4: the "bound" test opens ONLY the CITED agentId's own transcript and reads its SPAWN
# RECORD — never a whole-file substring scan (which binds to MENTIONS, e.g. a plan-review tag arriving in a
# planner's transcript via the plan's own required `## Review` byline — measured 4-of-7 on a real session) and
# never a newest-mtime "winner" search (a contaminated, newer sibling transcript must never decide another
# row's binding).
#
# HONEST LIMITATION (stated, not hidden): an UNTAGGED spawn (no 3ROLE_TASK / no ROLE) FAIL-OPENS (allow) — the
# gate cannot classify it, so it cannot sequence it. This is deliberate: the per-transition gate raises the
# floor, it does not make untagged bypass impossible. The COMPLETION gate (three-role-instrumentation-gate.sh,
# PR1) is the backstop — an untagged executor still cannot get the task marked done without a resolvable
# execution-review ledger line. Tagging is orchestrator-discipline; this gate enforces the ORDER once tagged.
# Nothing in the ledger is unforgeable (every field has a plain CLI flag) — this gate closes the one-command
# SHORTCUTS (the backgrounded-dispatch race, the convenience skip, the quiet downgrade via skip/inherit/flip,
# the mention-borrowed agentId), never a determined forger who actually spawns a real reviewer and forges its
# verdict before it returns (the named residual — see the #1575 plan's `Deferred-follow-ups:`).
#
# Only the EXECUTOR transition is gated. planner / plan-review / execution-review spawns are always ALLOWED
# (planner has no precondition; reviewer spawns must be free to run). Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1,
# SHIP_PIPELINE=1. Fail-open on any missing/unparseable state. No `set -e` (a non-block non-zero must not be
# read as a permission decision — #749 fail-closed-smoke lesson).
# #3154: a size-S ticket (ticket metadata.size S AND the plan's `size: S`, no plan-review row) is admitted by the SAME
# gate-plan-review evaluator (its size-s-exempt arm) -- this hook stays a thin caller and the block text names the S rule.
# Reference: parent-claude.md Invariant #2 ("the plan is reviewed by a STATELESS reviewer before execution"),
# hooks/3role-ledger.mjs (ledger format + THREE_ROLE_LEDGER_DIR + gate-plan-review), the plan #851 Phase 3b,
# and .ai-workspace/plans/2026-07-11-1575-spawn-gate-integrity.md (the hardening).

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
INPUT=$(cat)

# Kill-switches.
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-transition-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# Parse tool_input.prompt (Agent) / fall back to tool_input.description (some Task shapes) + session_id, and
# extract the 3ROLE_TASK + ROLE tags. Emits: "<taskId> <role>" or "" when untagged (-> fail-open allow).
read -r TASKID ROLE SESSION < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    if(!mTask || !mRole){ process.stdout.write("- - "+(session||"-")); process.exit(0); }
    process.stdout.write(mTask[1] + " " + mRole[1].toLowerCase() + " " + (session||"-"));
  ' 2>/dev/null
)

# Untagged spawn -> FAIL-OPEN (allow). Honest limitation documented in the header + block msg.
[ -n "$TASKID" ] && [ "$TASKID" != "-" ] && [ -n "$ROLE" ] && [ "$ROLE" != "-" ] || exit 0

# Only the executor transition is sequenced. Other roles always allowed.
[ "$ROLE" = "executor" ] || exit 0

# A tagged executor spawn with no usable session cannot have its precondition verified — but a missing session
# on a real spawn is anomalous; fail-OPEN here (allow) and let the completion gate (which fails CLOSED on a
# tagged completion with no session) be the backstop. The transition gate only ever ADDS ordering on tagged
# spawns that carry a session.
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# #1575 — the ENTIRE plan-review-admission decision lives in `gate-plan-review` (hooks/3role-ledger.mjs):
# last-parseable-line semantics, trailing-junk fail-closed, the universal verdict allowlist screen, and the
# three sanctioned arms (subprocess-openrouter / completed-review / inherited-review), each verified by the
# SAME checkSubprocessProvenance + spawn-record-bound to the CITED agentId (never a whole-file mention scan,
# never a newest-mtime "winner"). This hook is a thin caller so there is exactly ONE implementation of the
# contract — node-level smokes exercise `gate-plan-review` directly, and this bash smoke exercises it through
# the real hook.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LED_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LED_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
GATE_STDERR=$(node "$LED_HELPER" gate-plan-review --session "$SESSION" --task "$TASKID" 2>&1 >/dev/null)
GATE_RC=$?

if [ "$GATE_RC" = "0" ]; then
  exit 0
fi

# #3333 (2026-10-22): one chat can own a ticket's rows under more than one ledger session (z.ai dispatches
# under the carried ledger session, Agent-tool seats under the chat's own). `<ledger>/.session-alias/<session>`
# lists those other sessions (same file + bound as hooks/sole_lane_math.py session_aliases). Re-run the SAME
# gate-plan-review under each alias: only a real COMPLETED, AFFIRMATIVE plan-review for THIS task, passing every
# check that evaluator applies, admits. Missing/unreadable alias file -> no retry (the pre-alias answer).
ALIAS_FILE="${THREE_ROLE_LEDGER_DIR:-$HOME/.claude/3role-ledger}/.session-alias/${SESSION}"
if [ -f "$ALIAS_FILE" ] && [ -r "$ALIAS_FILE" ]; then
  ALIAS_N=0
  while IFS= read -r ALIAS_SID || [ -n "$ALIAS_SID" ]; do
    ALIAS_SID="$(printf '%s' "$ALIAS_SID" | tr -cd '0-9A-Za-z._-')"
    [ -n "$ALIAS_SID" ] && [ "$ALIAS_SID" != "$SESSION" ] || continue
    ALIAS_N=$((ALIAS_N + 1))
    [ "$ALIAS_N" -le 8 ] || break
    if node "$LED_HELPER" gate-plan-review --session "$ALIAS_SID" --task "$TASKID" >/dev/null 2>&1; then
      exit 0
    fi
    GATE_STDERR="${GATE_STDERR} | alias session ${ALIAS_SID}: no admitting plan-review either"
  done < "$ALIAS_FILE"
fi

# BLOCK: the ledger has no COMPLETED, AFFIRMATIVE plan-review for this task yet. $GATE_STDERR names the
# specific evidence class that failed (not-finished / no-verdict / negative-verdict / no-bound-reviewer-spawn /
# inherited-row-unbound-to-parent / deliberate-skip-closed / junk-line / subprocess-unverified) plus the
# ledger file + line evaluated (a misconfigured THREE_ROLE_LEDGER_DIR is otherwise silently permissive-looking
# and undiagnosable).
{
  echo "THREE-ROLE TRANSITION GATE (three-role-transition-gate): cannot spawn the EXECUTOR for task #${TASKID} yet."
  echo "  No COMPLETED, AFFIRMATIVE plan-review verdict is recorded for #${TASKID} in this session (${SESSION})."
  echo "  ${GATE_STDERR}"
  echo "  The 3-role model requires the PLAN to be reviewed by a STATELESS reviewer BEFORE execution, and that"
  echo "  review must FINISH with an affirmative verdict (parent-claude.md Invariant #2). The reviewer — not the"
  echo "  orchestrator — records its verdict. Run the plan-review role and let it complete honestly."
  echo "  If the plan-review seat is dispatched via the subprocess-openrouter route (the #1947 norm — e.g. Kimi K3"
  echo "    via OpenRouter), the SANCTIONED route is to RE-RUN that dispatch, never a hand-typed ledger append for a"
  echo "    subprocess row (a hand-append is the very forgery this gate exists to block):"
  echo "    bash tools/openrouter-role-dispatch.sh --role plan-review --brief <brief-path> --task ${TASKID} --session ${SESSION}"
  echo "    (the dispatch self-stamps dispatch/transcript_path/nonce; the gate verifies them via the SAME"
  echo "    checkSubprocessProvenance the completion gate already trusts.)"
  echo "  Otherwise, run an Agent-tool-dispatched plan-review and let it complete honestly:"
  echo "    node hooks/3role-ledger.mjs append --session ${SESSION} --task ${TASKID} --role plan-review \\"
  echo "      --agent <agentId> --artifact <plan-or-review-path> --verdict PASS --closed-at <ISO-8601-timestamp>"
  echo "  If #${TASKID} is a LEG of a parent plan whose plan-review already PASSED, inherit it instead (fails"
  echo "  closed unless the parent has a real, transcript-backed, AFFIRMATIVE plan-review that names this leg):"
  echo "    node hooks/3role-ledger.mjs inherit-plan-review --session ${SESSION} --task ${TASKID} --parent <parentTaskId>"
  echo "  then re-spawn the executor. There is NO skip path for plan-review at this gate (operator decision) —"
  echo "  a deliberate skip cannot satisfy this precondition, however specific the reason."
  echo "  The ONE exemption is size-S (#3154): a ticket whose metadata.size is S AND whose plan says \`size: S\`, with no"
  echo "    plan-review row yet, is admitted without a plan-review. The \`size-s: <reason>\` text above says why #${TASKID}"
  echo "    is NOT size-S here (a ticket stamped M/L, a plan saying anything but S, an unresolvable plan, or an existing review row)."
  echo "  Honest limitation: an UNTAGGED spawn dodges this gate (it can't be classified) — the completion gate"
  echo "    (three-role-instrumentation-gate.sh) is the backstop. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1 (or SHIP_PIPELINE=1)."
} >&2
exit 2
PREFIX3422_EOF
if cmp -s "$BASE3422_HOOK" "$HOOK"; then
  bad "#3422 non-decay: pinned pre-#3422 snapshot is BYTE-IDENTICAL to the live hook (the base arms are vacuous)"
else
  ok "#3422 non-decay: pinned pre-#3422 snapshot differs from the live hook"
fi
run_base() { CAP=$(printf '%s' "$1" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$BASE3422_HOOK" 2>&1 >/dev/null); RC=$?; }
# both-ends helper: <label> <prompt-with-\n-escapes> <expected base rc> <expected head rc> [stderr-needle-at-base]
both() {
  local label="$1" prompt="$2" erb="$3" erh="$4" needle="${5:-}" rb ob rh oh
  run_base "$(agent "$prompt" "34220000-0000-4000-8000-000000000001")"; rb=$RC; ob=$CAP
  run "$(agent "$prompt" "34220000-0000-4000-8000-000000000001")"; rh=$RC; oh=$CAP
  local good=1
  [ "$rb" = "$erb" ] || good=0
  [ "$rh" = "$erh" ] || good=0
  [ -z "$needle" ] || printf '%s' "$ob" | command grep -q "$needle" || good=0
  [ "$erh" != "0" ] || [ -z "$oh" ] || good=0
  [ "$good" = "1" ] && ok "#3422 $label: base rc=$rb head rc=$rh" || bad "#3422 $label (base rc=$rb/$erb out=$ob; head rc=$rh/$erh out=$oh)"
}
# AC-6 positive control: the needle used by the hero arm matches a known synthetic stderr line.
[ "$(grep_ctrl 'cannot spawn the EXECUTOR for task #3422' 'x cannot spawn the EXECUTOR for task #3422 y')" = "1" ] && ok "#3422 AC-6 grep_ctrl: block-text needle matches a known line" || bad "#3422 AC-6 grep_ctrl failed"
# AC-1 hero: header research + quoted executor in the body, no plan-review -> blocked at BASE, allowed at HEAD.
both "AC-1 hero header research + body ROLE:executor" 'FT-CHECK:3422 3ROLE_TASK:3422 ROLE:research\n\nquoted: 3ROLE_TASK:<id> ROLE:executor\n' 2 0 'cannot spawn the EXECUTOR for task #3422'
# AC-2 control: header executor, no plan-review -> blocked at both ends.
both "AC-2 control header executor" '3ROLE_TASK:3422 ROLE:executor\nGo.' 2 2 'cannot spawn the EXECUTOR for task #3422'
# AC-2b monotone: header line has NO ROLE; executor only on a later line -> fallback scan -> blocked at both ends.
both "AC-2b header without ROLE, executor on line 4" '3ROLE_TASK:3422 build it\n\n\nROLE:executor\n' 2 2
# AC-2c first-pair-wins dodge: prose line 1, a quoted research pair, then the real executor pair -> blocked at both ends.
both "AC-2c line 1 prose, research pair then executor pair" 'please build\n3ROLE_TASK:3422 ROLE:research\n3ROLE_TASK:3422 ROLE:executor\n' 2 2
# AC-2c control: pair on line 1 + quoted executor pair below -> allowed at HEAD (blocked at base).
both "AC-2c control pair on line 1, quoted executor below" '3ROLE_TASK:3422 ROLE:research\n3ROLE_TASK:3422 ROLE:executor\n' 2 0
# AC-4 real FT-CHECK brief shape: template header line + an Oracle smoke section quoting ROLE:executor.
both "AC-4 real FT-CHECK shape" 'FT-CHECK:3415 3ROLE_TASK:3415 ROLE:research\n\n## Oracle smoke\nrun(agent 3ROLE_TASK:3415 ROLE:executor)\n' 2 0
# named risk 3422-pr-r2-header-role-case: an upper-case header role is lowercased, so EXECUTOR still blocks.
both "risk r2-header-role-case header ROLE:EXECUTOR" '3ROLE_TASK:3422 ROLE:EXECUTOR\nGo.' 2 2
# header ROLE:planner / plan-review are not executors -> allowed (as base).
both "control header planner" '3ROLE_TASK:3422 ROLE:planner\nGo.' 0 0
# blank leading lines are skipped; header research, body executor.
both "leading blank lines then header research" '\n\n3ROLE_TASK:3422 ROLE:research\nROLE:executor\n' 2 0

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
