#!/usr/bin/env bash
# Smoke for three-role-transition-gate.sh (#851 PR2, Phase 3b). Exit 0 = all cases pass.
# The gate BLOCKS (exit 2) only an executor spawn (3ROLE_TASK:<id> ROLE:executor) when NO plan-review ledger
# line exists for <id>; everything else ALLOWS (untagged fail-open, non-executor roles, kill-switches).
# Per #749 the bypass forms are asserted to BLOCK where the gate IS fail-closed (the executor transition):
# alternate prompt field (description), tag mid-prompt, leading/trailing noise. No `set -e`.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-transition-gate.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LEDGERDIR="$TMP/ledger"; PROJROOT="$TMP/projects"

appendL() { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" append "$@" >/dev/null 2>&1; }
# add a plan-review ledger line for (session,task) so the executor precondition is satisfied
add_planreview() { appendL --session "$1" --task "$2" --role plan-review --agent agR --artifact "$TMP/rev.md"; }
printf '## Review\nverdict: PASS\n' > "$TMP/rev.md"

# run the gate with a raw payload string
run() { CAP=$(printf '%s' "$1" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# convenience: an Agent spawn payload with prompt $1, session $2
agent() { printf '{"tool_name":"Agent","session_id":"%s","tool_input":{"prompt":"%s"}}' "$2" "$1"; }

# ---- 1. executor spawn, NO plan-review line for 851 -> BLOCK (rc 2) ----
run "$(agent '3ROLE_TASK:851 ROLE:executor — implement it' sX1)"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "executor w/o plan-review -> BLOCK" || bad "executor-no-review should block (rc=$RC out=$CAP)"

# ---- 2. same WITH a plan-review line present -> ALLOW (rc 0) ----
add_planreview sX2 851
run "$(agent '3ROLE_TASK:851 ROLE:executor — implement it' sX2)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "executor WITH plan-review -> ALLOW silent" || bad "executor-with-review should allow (rc=$RC out=$CAP)"

# ---- 3. untagged Agent prompt -> allow silent (honest fail-open) ----
run "$(agent 'just go do some research, no tags' sX3)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "untagged spawn -> allow silent (fail-open)" || bad "untagged should allow silent (rc=$RC out=$CAP)"

# ---- 4. ROLE:planner spawn -> ALLOW (no precondition), even with no ledger ----
run "$(agent '3ROLE_TASK:851 ROLE:planner — author the plan' sX4)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "planner spawn -> ALLOW (no precondition)" || bad "planner should allow (rc=$RC out=$CAP)"

# ---- 4b. ROLE:plan-review spawn -> ALLOW (reviewer must be free to run) ----
run "$(agent '3ROLE_TASK:851 ROLE:plan-review — review the plan' sX4b)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "plan-review spawn -> ALLOW" || bad "plan-review should allow (rc=$RC out=$CAP)"

# ---- 4c. ROLE:execution-review spawn -> ALLOW ----
run "$(agent '3ROLE_TASK:851 ROLE:execution-review — review the diff' sX4c)"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "execution-review spawn -> ALLOW" || bad "execution-review should allow (rc=$RC out=$CAP)"

# ---- 5. kill-switches -> ALLOW even for executor w/o plan-review ----
CAP=$(printf '%s' "$(agent '3ROLE_TASK:851 ROLE:executor' sX5)" | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "THREE_ROLE_INSTRUMENT_OFF=1 -> ALLOW" || bad "OFF kill-switch should allow (rc=$RC out=$CAP)"
CAP=$(printf '%s' "$(agent '3ROLE_TASK:851 ROLE:executor' sX5)" | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "SHIP_PIPELINE=1 -> ALLOW" || bad "SHIP_PIPELINE kill-switch should allow (rc=$RC out=$CAP)"

# ---- 6. malformed stdin -> allow silent (fail-open) ----
run 'not json at all {{{'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "malformed input -> allow silent (fail-open)" || bad "malformed should fail-open (rc=$RC out=$CAP)"

# ---- 7. BYPASS-FORM: tag delivered via tool_input.description (not prompt) -> still BLOCK executor ----
run '{"tool_name":"Task","session_id":"sX7","tool_input":{"description":"3ROLE_TASK:851 ROLE:executor build it"}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "tag via description field -> BLOCK executor (bypass-form closed)" || bad "description-field executor should block (rc=$RC out=$CAP)"

# ---- 8. BYPASS-FORM: tag mid-prompt with surrounding noise -> still BLOCK executor ----
run "$(agent 'preamble text ... 3ROLE_TASK:851 ROLE:executor ... trailing instructions here' sX8)"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "tag mid-prompt+noise -> BLOCK executor (bypass-form closed)" || bad "mid-prompt executor should block (rc=$RC out=$CAP)"

# ---- 9. executor tagged but NO session -> documented fail-open ALLOW (completion gate is the backstop) ----
run '{"tool_name":"Agent","tool_input":{"prompt":"3ROLE_TASK:851 ROLE:executor"}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "executor tagged + no session -> ALLOW (documented fail-open)" || bad "no-session executor should fail-open allow (rc=$RC out=$CAP)"

# ---- 10. plan-review for a DIFFERENT task does NOT satisfy 851's executor -> BLOCK (per-task isolation) ----
add_planreview sX10 999
run "$(agent '3ROLE_TASK:851 ROLE:executor' sX10)"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "cannot spawn the EXECUTOR"; } && ok "plan-review for task 999 does NOT unlock 851 executor -> BLOCK" || bad "cross-task plan-review must not satisfy (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
