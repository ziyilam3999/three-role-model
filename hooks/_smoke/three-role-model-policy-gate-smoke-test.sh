#!/usr/bin/env bash
# Smoke for three-role-model-policy-gate.sh (#1448). Exit 0 = all cases pass.
# The hook is a PreToolUse(Agent|Task) BLOCK-ONCE nudge: on the POSITIVE condition (a tagged role spawn whose
# EFFECTIVE model tier != the role's cc-roles.env policy tier) it exits 2 the FIRST time per taskId+role
# signature, then exits 0 (block-once); everything else fail-opens exit 0 silent. Both-ends: each fixture FAILS
# on wrong behavior, PASSES on correct. No `set -e` (a non-block non-zero must never leak into a permission
# decision — #749).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-model-policy-gate.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# A SINGLE pinned state dir shared by ALL fixtures, so the marker dropped by fixture 1 is visible to fixture 2
# and the R1 different-signature fixture reads the SAME location. Dependent fixtures run in order.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP/state"

# Fixture cc-roles.env (Option-A shape) — CC_ROLES_ENV points resolve-role-model at THIS file, so the smoke is
# independent of the repo/plugin config. executor=sonnet is the one non-opus seat.
CFG="$TMP/cc-roles.env"
cat > "$CFG" <<EOF
CC_ROLE_ORCHESTRATOR_MODEL=opus
CC_ROLE_PLANNER_MODEL=opus
CC_ROLE_PLAN_REVIEW_MODEL=opus
CC_ROLE_EXECUTOR_MODEL=sonnet
CC_ROLE_EXECUTOR_EFFORT=medium
CC_ROLE_EXECUTION_REVIEW_MODEL=opus
EOF
# A fable-executor config to exercise the cost-cliff note.
CFGF="$TMP/cc-roles-fable.env"
printf 'CC_ROLE_EXECUTOR_MODEL=fable\n' > "$CFGF"

# run <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Default CC_ROLES_ENV=$CFG (override by passing another
# CC_ROLES_ENV in the extra env — later wins). Every run pins the shared STATE_DIR.
run() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env CC_ROLES_ENV="$CFG" "$@" CC_ROLE_MODEL_POLICY_STATE_DIR="$STATE_DIR" bash "$HOOK" 2>&1); RC=$?
}

# ---- 1. executor + model:opus (violates sonnet policy), FRESH sig -> exit 2 + names role + expected tier. ----
P1='{"session_id":"s1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9001 ROLE:executor\nImplement."}}'
run "$P1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor" && echo "$CAP" | grep -q "sonnet"; } \
  && ok "executor model:opus (fresh) -> exit 2, names role + sonnet policy" \
  || bad "fresh violation should block visibly (rc=$RC out=$CAP)"

# ---- 2. SAME signature again (marker present) -> exit 0 (block-once, not wedged). ----
run "$P1"
{ [ "$RC" = "0" ]; } && ok "same signature again -> exit 0 (block-once, not wedged)" || bad "second identical spawn should fall through (rc=$RC out=$CAP)"

# ---- R1. DIFFERENT signature (different taskId, same session) AFTER fixture 1's marker exists -> exit 2
#          (blocks AGAIN — the property block-once exists to guarantee; a real second offense is NOT missed). ----
PR1='{"session_id":"s1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9002 ROLE:executor\nDifferent task, same violation."}}'
run "$PR1"
{ [ "$RC" = "2" ]; } && ok "R1: DIFFERENT taskId offense after first fire -> STILL exit 2 (blocks again)" || bad "R1 different signature must still block (rc=$RC out=$CAP)"

# ---- 3. executor + model:sonnet (matches policy) -> exit 0 silent. ----
P3='{"session_id":"s2","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9003 ROLE:executor\nGo."}}'
run "$P3"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "executor model:sonnet (match) -> exit 0 silent" || bad "matching model should be silent allow (rc=$RC out=$CAP)"

# ---- 4. executor + NO model -> the inherited session default (Opus) violates sonnet -> exit 2. ----
P4='{"session_id":"s3","tool_input":{"prompt":"3ROLE_TASK:9004 ROLE:executor\nNo model passed."}}'
run "$P4"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "sonnet" && echo "$CAP" | grep -qi "inherited"; } \
  && ok "executor NO model -> exit 2 (inherited Opus violates sonnet)" \
  || bad "absent model on a non-opus seat should block (rc=$RC out=$CAP)"

# ---- 5. planner + NO model -> inherited Opus == opus policy -> exit 0 silent (NO nudge-noise on opus seats). ----
P5='{"session_id":"s4","tool_input":{"prompt":"3ROLE_TASK:9005 ROLE:planner\nPlan it."}}'
run "$P5"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "planner NO model -> exit 0 silent (opus seat, absent default OK)" || bad "opus seat absent model must be silent (rc=$RC out=$CAP)"

# ---- 6. planner + model:sonnet -> explicit WRONG tier on an opus seat -> exit 2. ----
P6='{"session_id":"s5","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9006 ROLE:planner\nPlan it, wrong tier."}}'
run "$P6"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "opus"; } && ok "planner model:sonnet (explicit wrong on opus seat) -> exit 2" || bad "explicit wrong tier should block (rc=$RC out=$CAP)"

# ---- 7. non-tagged spawn (no 3ROLE_TASK, no ROLE) -> exit 0 silent (the norm). ----
run '{"session_id":"s6","tool_input":{"prompt":"Do some general research. No tags."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "non-tagged spawn -> exit 0 silent" || bad "untagged spawn should be silent allow (rc=$RC out=$CAP)"

# ---- 8. role-only, no task tag -> exit 0 silent (need BOTH tags to attribute a policy). ----
run '{"session_id":"s7","tool_input":{"model":"opus","prompt":"ROLE:executor\nNo task tag here."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "role-only (no task tag) -> exit 0 silent" || bad "role-only should be silent allow (rc=$RC out=$CAP)"

# ---- 8b. task-only, no role tag -> exit 0 silent. ----
run '{"session_id":"s8","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9008\nSome work, no role tag."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "task-only (no role tag) -> exit 0 silent" || bad "task-only should be silent allow (rc=$RC out=$CAP)"

# ---- 9. kill-switches on an OTHERWISE-POSITIVE payload (non-vacuity): a FRESH-signature violation that WOULD
#         block, but each switch -> exit 0 (proves the switch suppressed a real block). Fresh sessions. ----
P9='{"session_id":"s9a","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9009 ROLE:executor\nviolation."}}'
run "$P9" CC_ROLE_MODEL_GATE_OFF=1; rc9a=$RC
P9b='{"session_id":"s9b","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9010 ROLE:executor\nviolation."}}'
run "$P9b" THREE_ROLE_INSTRUMENT_OFF=1; rc9b=$RC
P9c='{"session_id":"s9c","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9011 ROLE:executor\nviolation."}}'
run "$P9c" SHIP_PIPELINE=1; rc9c=$RC
{ [ "$rc9a" = "0" ] && [ "$rc9b" = "0" ] && [ "$rc9c" = "0" ]; } \
  && ok "kill-switches on POSITIVE payload -> exit 0 (CC_ROLE_MODEL_GATE_OFF / THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE all suppress a real block)" \
  || bad "kill-switches should suppress a real block (rc9a=$rc9a rc9b=$rc9b rc9c=$rc9c)"

# ---- 10. inline bypass token on an OTHERWISE-POSITIVE payload -> exit 0 (fresh signature). ----
P10='{"session_id":"s10","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9012 ROLE:executor [model-policy-ok]\nDeliberate one-off."}}'
run "$P10"
{ [ "$RC" = "0" ]; } && ok "inline bypass [model-policy-ok] on POSITIVE payload -> exit 0 (non-vacuous)" || bad "inline bypass should suppress a real block (rc=$RC out=$CAP)"

# ---- 11. bypass-form coverage (#749): role tag in the `description` field (not prompt) + model in tool_input.model
#          -> still detected -> exit 2 (the regex reads the joined prompt+description+message field set). Fresh sig. ----
P11='{"session_id":"s11","tool_input":{"model":"opus","description":"3ROLE_TASK:9013 ROLE:executor","prompt":"Implementation work, tags in description."}}'
run "$P11"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor"; } \
  && ok "tags in description field -> still detected -> exit 2" \
  || bad "should read joined field set incl. description (rc=$RC out=$CAP)"

# ---- 12. malformed / empty payload -> exit 0 (fail-open). ----
run 'not json {{{'; rc12a=$RC
run '{"session_id":"s12"}'; rc12b=$RC
{ [ "$rc12a" = "0" ] && [ "$rc12b" = "0" ]; } && ok "malformed / empty payload -> exit 0 (fail-open)" || bad "malformed should fail-open exit 0 (rc12a=$rc12a rc12b=$rc12b)"

# ---- 13. NO-CONFIG fail-safe: CC_ROLES_ENV=/nonexistent -> policy resolves to opus for every role -> an
#          executor+model:opus spawn effective=opus == opus -> exit 0 (no false-block when config is absent). ----
P13='{"session_id":"s13","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9014 ROLE:executor\nno config."}}'
run "$P13" CC_ROLES_ENV=/nonexistent
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "no-config (CC_ROLES_ENV=/nonexistent) executor+opus -> exit 0 (fail-safe opus, no false-block)" || bad "no-config should fail-safe to opus and not false-block model:opus (rc=$RC out=$CAP)"

# ---- 14. FABLE config: executor=fable, spawn model:opus -> exit 2 with the Fable cost-cliff note. Fresh sig. ----
P14='{"session_id":"s14","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9015 ROLE:executor\nfable policy."}}'
run "$P14" CC_ROLES_ENV="$CFGF"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "Fable"; } \
  && ok "fable-executor config + model:opus -> exit 2 + Fable cost-cliff note" \
  || bad "fable seat mismatch should block with a Fable note (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
