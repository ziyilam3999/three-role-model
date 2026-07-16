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
SPAWN_LEDGER="$DIR/three-role-spawn-ledger.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
# convenience: an Agent spawn payload with prompt $1, session $2
agent() { printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"prompt":"%s"}}' "$2" "$1"; }

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
mk_bound "$S" "ag9c2" "$T" "plan-review"
LEDFILE9C2="$LEDGERDIR/$S/$T.jsonl"; mkdir -p "$(dirname "$LEDFILE9C2")"
{
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c2","verdict":"BLOCK","closedAt":"2026-07-11T00:00:00.000Z"}\n' "$S"
  printf '{"role":"plan-review","session_id":"%s","agentId":"ag9c2","verdict":"PASS","closedAt":"2026-07-11T00:00:01.000Z"}\n' "$S"
} > "$LEDFILE9C2"
run "$(agent "3ROLE_TASK:$T ROLE:executor" "$S")"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC-9(c) converse: stale BLOCK-shaped first, authoritative ALLOW-shaped+bound last -> ALLOW (kills last-line-only-if-it-blocks)" || bad "AC-9(c) converse case should allow (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
