#!/usr/bin/env bash
# Smoke for three-role-attribution-gate.sh (#1185). Exit 0 = all cases pass.
# The hook is a PreToolUse(Agent|Task) BLOCK-ONCE nudge: on the POSITIVE condition (ROLE tag present AND
# 3ROLE_TASK absent) it exits 2 the FIRST time per signature, then exits 0 (block-once); on everything else it
# fail-opens exit 0 silent. Both-ends: each fixture FAILS on wrong behavior, PASSES on correct.
# No `set -e` (a non-block non-zero must never leak into a permission decision — #749).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-attribution-gate.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# R4: a SINGLE pinned mktemp -d state dir shared by ALL fixtures, so the marker dropped by fixture 1 is visible
# to fixture 2, and the R1 different-signature fixture reads the SAME location. Dependent fixtures run in order.
STATE_DIR="$(mktemp -d)"; trap 'rm -rf "$STATE_DIR"' EXIT

# run <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Every run pins the shared STATE_DIR.
run() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env "$@" THREE_ROLE_ATTRIBUTION_STATE_DIR="$STATE_DIR" bash "$HOOK" 2>&1); RC=$?
}

# ---- 1. ROLE without task (fresh signature A) -> exit 2 + stderr names the role + the missing tag.
#         (Without the detection: exit 0 -> FAIL.) ----
P1='{"session_id":"sAG","tool_input":{"prompt":"ROLE:planner\nYou are the planner. Author a plan."}}'
run "$P1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:planner" && echo "$CAP" | grep -q "3ROLE_TASK"; } \
  && ok "ROLE-without-task (fresh) -> exit 2, names role + missing tag" \
  || bad "fresh positive should block visibly (rc=$RC out=$CAP)"

# ---- 2. SAME signature again (marker present) -> exit 0 (block-once, not wedged). ----
run "$P1"
{ [ "$RC" = "0" ]; } && ok "same signature again -> exit 0 (block-once, not wedged)" || bad "second identical spawn should fall through (rc=$RC out=$CAP)"

# ---- R1. DIFFERENT signature (different role, same session) AFTER fixture 1's marker exists -> exit 2 (blocks
#          AGAIN). This is the load-bearing property block-once exists to guarantee: a real second offense is
#          NOT silently missed. (Without per-signature keying, a per-session marker would suppress this -> exit 0
#          -> FAIL.) ----
PR1='{"session_id":"sAG","tool_input":{"prompt":"ROLE:executor\nImplement the feature, but no task tag here."}}'
run "$PR1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor"; } \
  && ok "R1: DIFFERENT-signature offense after first fire -> STILL exit 2 (blocks again)" \
  || bad "R1 different signature must still block (rc=$RC out=$CAP)"

# ---- 3. both tags -> exit 0 silent (the transition-gate's job, not this one). ----
P3='{"session_id":"sAG","tool_input":{"prompt":"3ROLE_TASK:1185 ROLE:planner\nYou are the planner."}}'
run "$P3"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "both tags -> exit 0 silent" || bad "both tags should be silent allow (rc=$RC out=$CAP)"

# ---- 4. no ROLE (normal non-3-role spawn) -> exit 0 silent. ----
P4='{"session_id":"sAG","tool_input":{"prompt":"Do some general research. No tags."}}'
run "$P4"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "no ROLE (normal spawn) -> exit 0 silent" || bad "untagged spawn should be silent allow (rc=$RC out=$CAP)"

# ---- 5. task present, no role -> exit 0 silent. ----
P5='{"session_id":"sAG","tool_input":{"prompt":"3ROLE_TASK:1185\nSome work for task 1185 but no role tag."}}'
run "$P5"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "task without role -> exit 0 silent" || bad "task-only should be silent allow (rc=$RC out=$CAP)"

# ---- 6. kill-switches on an OTHERWISE-POSITIVE payload (R3 non-vacuity): a FRESH-signature positive spawn that
#         WOULD block, but each switch -> exit 0 (proves the switch suppressed a real block). Fresh sessions so
#         no marker pre-exists. ----
P6='{"session_id":"sAG6","tool_input":{"prompt":"ROLE:plan-review\nReview something, no task tag."}}'
run "$P6" THREE_ROLE_ATTRIBUTION_OFF=1; rc6a=$RC
P6b='{"session_id":"sAG6b","tool_input":{"prompt":"ROLE:plan-review\nReview something, no task tag."}}'
run "$P6b" THREE_ROLE_INSTRUMENT_OFF=1; rc6b=$RC
P6c='{"session_id":"sAG6c","tool_input":{"prompt":"ROLE:plan-review\nReview something, no task tag."}}'
run "$P6c" SHIP_PIPELINE=1; rc6c=$RC
{ [ "$rc6a" = "0" ] && [ "$rc6b" = "0" ] && [ "$rc6c" = "0" ]; } \
  && ok "kill-switches on POSITIVE payload -> exit 0 (R3: ATTRIBUTION_OFF / INSTRUMENT_OFF / SHIP_PIPELINE all suppress a real block)" \
  || bad "kill-switches should suppress a real block (rc6a=$rc6a rc6b=$rc6b rc6c=$rc6c)"

# ---- 7. inline bypass token on an OTHERWISE-POSITIVE payload (R3 non-vacuity) -> exit 0 (proves the bypass
#         suppressed a block that would otherwise fire). Fresh signature. ----
P7='{"session_id":"sAG7","tool_input":{"prompt":"ROLE:executor [role-no-task-ok]\nDeliberate one-off, no task tag."}}'
run "$P7"
{ [ "$RC" = "0" ]; } && ok "inline bypass [role-no-task-ok] on POSITIVE payload -> exit 0 (R3 non-vacuous)" || bad "inline bypass should suppress a real block (rc=$RC out=$CAP)"

# ---- 8. bypass-form coverage (#749): role tag in the `description` field (not prompt) -> still detected -> exit 2
#         (asserts the regex reads the same joined field set as the siblings, not just prompt). Fresh signature. ----
P8='{"session_id":"sAG8","tool_input":{"description":"ROLE:executor","prompt":"Some implementation work, no task tag in prompt."}}'
run "$P8"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor"; } \
  && ok "role tag in description field -> still detected -> exit 2" \
  || bad "should read joined field set incl. description (rc=$RC out=$CAP)"

# ---- 8b. role tag MID-prompt with leading/trailing noise -> still detected -> exit 2 (regex not anchored to
#          start-of-string). Fresh signature. ----
P8b='{"session_id":"sAG8b","tool_input":{"prompt":"Please proceed. Note: ROLE:planner is your job. Carry on, no task tag."}}'
run "$P8b"
{ [ "$RC" = "2" ]; } && ok "role tag mid-prompt w/ noise -> still detected -> exit 2" || bad "mid-prompt role should still block (rc=$RC out=$CAP)"

# ---- 9. malformed payload -> exit 0 (fail-open). ----
run 'not json {{{'; rc9a=$RC
run '{"session_id":"sAG9"}'; rc9b=$RC
{ [ "$rc9a" = "0" ] && [ "$rc9b" = "0" ]; } && ok "malformed / empty payload -> exit 0 (fail-open)" || bad "malformed should fail-open exit 0 (rc9a=$rc9a rc9b=$rc9b)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
