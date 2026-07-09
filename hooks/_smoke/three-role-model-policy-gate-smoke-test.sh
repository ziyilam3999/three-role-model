#!/usr/bin/env bash
# Smoke for three-role-model-policy-gate.sh (#1448, effective-tier sensor #1494). Exit 0 = all cases pass.
# The hook is a PreToolUse(Agent|Task) BLOCK-ONCE nudge: on the POSITIVE condition (a tagged role spawn whose
# EFFECTIVE model tier != the role's cc-roles.env policy tier) it exits 2 the FIRST time per taskId+role
# signature, then exits 0 (block-once); everything else fail-opens exit 0 silent. Both-ends: each fixture FAILS
# on wrong behavior, PASSES on correct. No `set -e` (a non-block non-zero must never leak into a permission
# decision — #749).
#
# #1494 ADDS: (a) a SENSOR-UNIT section that calls `node hooks/3role-ledger.mjs resolve-effective-tier`
# directly and asserts its RESOLVED VALUE on stdout (not merely exit 0 — a smoke asserting only exit code on a
# CLI that always exits 0 is vacuous by construction); (b) a GATE section that feeds PreToolUse(Agent) payloads
# to the CURRENT hook AND, for the two REGRESSION-CATCH rows, to a snapshot of the PRE-FIX hook fetched from
# origin/master — proving the leak this ticket exists to close ACTUALLY existed on HEAD (RED-on-HEAD-first;
# a smoke whose red arm can pass via an unrelated fail-open path is vacuous — #1502's exact defect class).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-model-policy-gate.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
# The PRE-FIX hook snapshot MUST live in the SAME dir as the REAL (current) hook — i.e. `dirname "$HOOK"`,
# NOT `$DIR` (the smoke test's own dir). In ai-brain those are identical ($DIR IS hooks/), but the plugin
# port relocates this smoke test to hooks/_smoke/ while $HOOK stays ROOT-relative to hooks/ — so a
# `$DIR`-based drop site would silently land two levels deep and break the pre-fix hook's OWN sibling
# resolution (`dirname "${BASH_SOURCE[0]}"/3role-ledger.mjs` in ai-brain's historical hook, or
# `dirname "${BASH_SOURCE[0]}"/../bin/3role-ledger.mjs` in the plugin's historical hook) — it would find no
# helper, fall through `[ -f "$LEDGER_HELPER" ] || exit 0`, and exit 0 for EVERY payload regardless of the
# actual (pre-fix) bug, making the RED-on-HEAD-first comparison PASS VACUOUSLY (caught 2026-07-09 on the
# ported plugin copy: AC-12 HEAD read rc=0 out= until this was pinned to `dirname "$HOOK"`). Using the
# CURRENT (post-#1494) 3role-ledger.mjs for the pre-fix HOOK snapshot is correct: resolve-role-model itself
# was NOT changed by #1494 (only resolve-effective-tier was ADDED), so the pre-fix hook's own
# `resolve-role-model` call resolves identically either way — only the pre-fix HOOK's own hardcoded-opus logic
# is what we are isolating and re-running.
HEAD_HOOK_DIR="$(dirname "$HOOK")"
HEAD_HOOK="$HEAD_HOOK_DIR/.smoke-1494-head-hook-$$.sh"
trap 'rm -rf "$TMP" "$HEAD_HOOK"' EXIT

HEAD_AVAILABLE=1
if ! git -C "$HEAD_HOOK_DIR" show origin/master:hooks/three-role-model-policy-gate.sh > "$HEAD_HOOK" 2>/dev/null || [ ! -s "$HEAD_HOOK" ]; then
  HEAD_AVAILABLE=0
  bad "could not fetch origin/master's pre-fix hooks/three-role-model-policy-gate.sh for the RED-on-HEAD-first comparison (git show failed) — the two regression-catch rows (8, 11) cannot prove HEAD's silent-pass side without it"
fi

# A SINGLE pinned state dir shared by ALL fixtures, so the marker dropped by one fixture is visible to a
# same-signature re-issue (block-once tests) and unrelated signatures never collide (distinct session ids
# per test case below).
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

# CC_ROLE_AGENTS_DIR fixture — a fixture agent-def dir the gate/sensor read (the REAL ~/.claude/agents is
# NEVER touched). Only cc-executor.md exists here (frontmatter model: sonnet) — AC-7/13.
AGENTS_FIX="$TMP/agents_fix"
mkdir -p "$AGENTS_FIX"
cat > "$AGENTS_FIX/cc-executor.md" <<'EOF'
---
name: cc-executor
model: sonnet
---
Executor role definition fixture (smoke-only; never installed).
EOF

# ── Transcript fixtures (JSONL, mktemp-relative — no literal home paths) ──────────────────────────────────
FABLE_TX="$TMP/fable.jsonl"
printf '%s\n' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}' \
  '{"type":"user","isSidechain":false,"message":{"content":"intermediate turn"}}' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5"}}' \
  > "$FABLE_TX"

OPUS_TX="$TMP/opus.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}' > "$OPUS_TX"

SIDECHAIN_TX="$TMP/sidechain.jsonl"
printf '%s\n' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5"}}' \
  '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-4-8"}}' \
  > "$SIDECHAIN_TX"

# REALISTIC_OPUS_TX: opus assistant, then trailing non-assistant records, LAST ~0.8MB — proves the DEFAULT
# tail window (no env override) does not false-block a real opus spawn even behind a big trailing record.
REALISTIC_OPUS_TX="$TMP/realistic_opus.jsonl"
python3 - "$REALISTIC_OPUS_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-opus-4-8"}}) + "\n")
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": "small trailing turn"}}) + "\n")
    big = "x" * 819200   # ~0.8MB, exceeds a SMALL configured window but fits the 4MB default with margin.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# BIG_TAIL_TX: fable assistant, then a trailing record LARGER than a small configured initial window — forces
# the grow-with-cap path (AC-5).
BIG_TAIL_TX="$TMP/big_tail.jsonl"
python3 - "$BIG_TAIL_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-fable-5"}}) + "\n")
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": "small"}}) + "\n")
    big = "y" * 5000    # > the small 2048-byte initial window this AC uses below, forces >=2 growth doublings.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# OVERSIZE_TX: NO parseable last-assistant record reachable within a TINY cap (AC-6 — cap-exceeded fail-closed).
OVERSIZE_TX="$TMP/oversize.jsonl"
python3 - "$OVERSIZE_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-opus-4-8"}}) + "\n")
    big = "z" * 20000   # far past a tiny (e.g. 4096-byte) cap -> the assistant line at file-start is never reached.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# HUGE_TX: >=200MB, opus assistant as the LAST record (near-EOF) — proves the reverse-tail read is genuinely
# bounded at REAL scale (never a whole-file read) via a 1s timeout wrapper (AC-5 secondary bound).
HUGE_TX="$TMP/huge.jsonl"
{
  printf '{"type":"user","isSidechain":false,"message":{"content":"'
  dd if=/dev/zero bs=1m count=200 2>/dev/null | tr '\0' 'x'
  printf '"}}\n'
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}'
} > "$HUGE_TX"

EMPTY_TX="$TMP/does-not-exist.jsonl"   # never created -> unreadable/missing.

echo "-- fixtures built (HUGE_TX=$(wc -c < "$HUGE_TX" 2>/dev/null || echo '?') bytes) --"

# runh <hook-path> <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Pins CC_ROLES_ENV=$CFG and
# CC_ROLE_AGENTS_DIR=$AGENTS_FIX by default (later env args win); pins the POST-FIX STATE_DIR.
runh() {
  local hook="$1" payload="$2"; shift 2
  CAP=$(printf '%s' "$payload" \
    | env CC_ROLES_ENV="$CFG" CC_ROLE_AGENTS_DIR="$AGENTS_FIX" "$@" CC_ROLE_MODEL_POLICY_STATE_DIR="$STATE_DIR" bash "$hook" 2>&1); RC=$?
}
run() { runh "$HOOK" "$@"; }   # legacy alias -> always the CURRENT (post-fix) hook.

# run_head <payload-json> [env KEY=VAL ...] -> the PRE-FIX hook snapshot, an ISOLATED state dir
# (STATE_DIR_HEAD, never $STATE_DIR). Sharing state with the post-fix runs would let a HEAD-side block-once
# marker (written whenever HEAD legitimately blocks, e.g. AC-12's consistency arm) shadow the SAME
# session:taskId:role signature's post-fix assertion — a same-signature HEAD write must never suppress the
# post-fix run for that identical payload.
STATE_DIR_HEAD="$TMP/state-head"
run_head() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env CC_ROLES_ENV="$CFG" CC_ROLE_AGENTS_DIR="$AGENTS_FIX" "$@" CC_ROLE_MODEL_POLICY_STATE_DIR="$STATE_DIR_HEAD" bash "$HEAD_HOOK" 2>&1); RC=$?
}

echo "== SECTION 0: static syntax checks =="

# ---- AC-0: bash -n on every shell file this ticket touches (macOS /bin/bash 3.2.57 — no declare -A). ----
bash -n "$HOOK" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0a: bash -n three-role-model-policy-gate.sh -> syntax OK" || bad "AC-0a: bash -n three-role-model-policy-gate.sh FAILED"
bash -n "$DIR/three-role-model-policy-gate-smoke-test.sh" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0b: bash -n three-role-model-policy-gate-smoke-test.sh (self) -> syntax OK" || bad "AC-0b: bash -n (self) FAILED"
node --check "$LED" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0c: node --check 3role-ledger.mjs -> syntax OK" || bad "AC-0c: node --check 3role-ledger.mjs FAILED"

echo "== SECTION 1: sensor UNIT arms (resolve-effective-tier CLI, direct) — AC 1-7 =="

# ---- AC-1: explicit --model wins regardless of transcript. ----
OUT=$(node "$LED" resolve-effective-tier --model fable --transcript /dev/null 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable requested agentdef=none" ]; } \
  && ok "AC-1: explicit --model fable (any transcript) -> 'fable requested agentdef=none'" \
  || bad "AC-1 failed (rc=$RC out=$OUT)"

# ---- AC-2: session-read + last-assistant-wins (FABLE_TX has an earlier opus line). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$FABLE_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-2: empty --model + FABLE_TX -> 'fable session agentdef=none' (last-assistant wins)" \
  || bad "AC-2 failed (rc=$RC out=$OUT)"

# ---- AC-3: no transcript + no derivable session -> unknown (OR-disjunct a). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$TMP/nonexistent-ac3.jsonl" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "unknown unknown agentdef=none" ]; } \
  && ok "AC-3: no transcript, no session -> 'unknown unknown agentdef=none' (OR-disjunct a)" \
  || bad "AC-3 failed (rc=$RC out=$OUT)"

# ---- AC-4: sidechain filter — a subagent record can never leak in as the session model. ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$SIDECHAIN_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-4: SIDECHAIN_TX -> 'fable session agentdef=none' (isSidechain:true opus is excluded)" \
  || bad "AC-4 failed (rc=$RC out=$OUT)"

# ---- AC-5: tail-past-a-giant-trailing-record (grow path) + a real-scale speed bound. ----
OUT=$(env CC_TIER_SENSOR_TAIL_BYTES=2048 CC_TIER_SENSOR_CAP_BYTES=65536 \
  node "$LED" resolve-effective-tier --model "" --transcript "$BIG_TAIL_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-5a: BIG_TAIL_TX + small TAIL_BYTES -> grows through the giant trailing record -> 'fable session'" \
  || bad "AC-5a failed (rc=$RC out=$OUT)"
T0=$(date +%s)
OUT2=$(timeout 1 env CC_TIER_SENSOR_TAIL_BYTES=2048 CC_TIER_SENSOR_CAP_BYTES=65536 \
  node "$LED" resolve-effective-tier --model "" --transcript "$HUGE_TX" 2>&1); RC2=$?
T1=$(date +%s)
{ [ "$RC2" = "0" ] && [ "$OUT2" = "opus session agentdef=none" ]; } \
  && ok "AC-5b: HUGE_TX (>=200MB) resolves 'opus session' inside a 1s timeout ($((T1-T0))s) — whole-file read genuinely avoided" \
  || bad "AC-5b failed (rc=$RC2 out=$OUT2 elapsed=$((T1-T0))s)"

# ---- AC-6: cap-exceeded fail-closed, bounded time (OR-disjunct c). ----
T0=$(date +%s)
OUT=$(timeout 1 env CC_TIER_SENSOR_TAIL_BYTES=512 CC_TIER_SENSOR_CAP_BYTES=4096 \
  node "$LED" resolve-effective-tier --model "" --transcript "$OVERSIZE_TX" 2>&1); RC=$?
T1=$(date +%s)
{ [ "$RC" = "0" ] && [ "$OUT" = "unknown unknown agentdef=none" ]; } \
  && ok "AC-6: OVERSIZE_TX + tiny CAP_BYTES -> 'unknown unknown' inside 1s ($((T1-T0))s) (OR-disjunct c)" \
  || bad "AC-6 failed (rc=$RC out=$OUT elapsed=$((T1-T0))s)"

# ---- AC-7: agent-def is PROVENANCE-ONLY — tier stays the SESSION tier (opus), never the frontmatter (sonnet). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --subagent-type cc-executor --agents-dir "$AGENTS_FIX" --transcript "$OPUS_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "opus session agentdef=sonnet" ]; } \
  && ok "AC-7: cc-executor frontmatter=sonnet + OPUS_TX -> tier stays 'opus session', agentdef=sonnet reported only" \
  || bad "AC-7 failed (rc=$RC out=$OUT)"

echo "== SECTION 2: GATE arms (PreToolUse(Agent) payloads through the hook) — AC 8-15 =="

# ---- AC-8: REGRESSION — the measured leak. planner, NO model, general-purpose, FABLE_TX.
#      HEAD (pre-fix): exits 0 silent (the bug). Post-fix: exits 2, names fable + the session source. ----
P8='{"session_id":"ac8","tool_input":{"prompt":"3ROLE_TASK:9101 ROLE:planner\nPlan it.","subagent_type":"general-purpose"},"transcript_path":"'"$FABLE_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P8"
  { [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
    && ok "AC-8 HEAD: planner+no-model+FABLE_TX on the PRE-FIX hook -> exit 0 silent (the measured leak, reproduced)" \
    || bad "AC-8 HEAD should silently pass (the bug) (rc=$RC out=$CAP)"
fi
run "$P8"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "fable" && echo "$CAP" | grep -qi "session"; } \
  && ok "AC-8 post-fix: same payload -> exit 2, names fable + the session-transcript source" \
  || bad "AC-8 post-fix should block and name fable+session (rc=$RC out=$CAP)"

# ---- AC-9: GREEN majority path — robust tail, no false block, DEFAULT tail bytes (no override). ----
P9='{"session_id":"ac9","tool_input":{"prompt":"3ROLE_TASK:9102 ROLE:planner\nPlan it.","subagent_type":"general-purpose"},"transcript_path":"'"$REALISTIC_OPUS_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P9"; rc9h=$RC
else
  rc9h=0
fi
run "$P9"; rc9p=$RC
{ [ "$rc9h" = "0" ] && [ "$rc9p" = "0" ]; } \
  && ok "AC-9: planner+no-model+REALISTIC_OPUS_TX (opus behind a ~0.8MB trailing record) -> exit 0 both HEAD and post-fix" \
  || bad "AC-9 should never false-block (rc_head=$rc9h rc_postfix=$rc9p)"

# ---- AC-10: GREEN explicit — an explicit model:sonnet under a Fable-session transcript is NOT false-blocked. ----
P10='{"session_id":"ac10","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9103 ROLE:executor\nGo."},"transcript_path":"'"$FABLE_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P10"; rc10h=$RC
else
  rc10h=0
fi
run "$P10"; rc10p=$RC
{ [ "$rc10h" = "0" ] && [ "$rc10p" = "0" ]; } \
  && ok "AC-10: executor+model:sonnet under a Fable-session transcript -> exit 0 both HEAD and post-fix (term-1 wins)" \
  || bad "AC-10 should never false-block an explicitly-badged cheap seat (rc_head=$rc10h rc_postfix=$rc10p)"

# ---- AC-11: FAIL-CLOSED opus-seat can't-determine. plan-review, NO model, EMPTY_TX (unreadable).
#      HEAD: exits 0 silent (the DANGEROUS direction — old hardcoded opus == opus policy). Post-fix: exits 2
#      via the named `unknown` branch; stderr asks for an explicit model: and does NOT silently claim opus
#      was assumed (no "inherited"/"the session model, Opus" language — the exact phrasing the bug used). ----
P11='{"session_id":"ac11","tool_input":{"prompt":"3ROLE_TASK:9104 ROLE:plan-review\nReview it."},"transcript_path":"'"$EMPTY_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P11"
  { [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
    && ok "AC-11 HEAD: plan-review+no-model+unreadable-tx on the PRE-FIX hook -> exit 0 silent (the dangerous direction)" \
    || bad "AC-11 HEAD should silently pass (rc=$RC out=$CAP)"
fi
run "$P11"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "INDETERMINATE" && echo "$CAP" | grep -q "model:" \
  && ! echo "$CAP" | grep -qi "inherited"; } \
  && ok "AC-11 post-fix: unknown branch -> exit 2, asks explicit model:, no silent-opus-assumption language" \
  || bad "AC-11 post-fix should fail-closed via the named unknown branch (rc=$RC out=$CAP)"

# ---- AC-12: FAIL-CLOSED cheap-seat can't-determine (consistency arm — HEAD already exits 2, for a
#      different reason: hardcoded opus != sonnet policy). Post-fix exits 2 via the NEW unknown branch. ----
P12='{"session_id":"ac12","tool_input":{"prompt":"3ROLE_TASK:9105 ROLE:executor\nImplement."},"transcript_path":"'"$EMPTY_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P12"
  { [ "$RC" = "2" ]; } \
    && ok "AC-12 HEAD: executor+no-model+unreadable-tx on the PRE-FIX hook -> exit 2 (consistency: hardcoded opus != sonnet)" \
    || bad "AC-12 HEAD should already block (rc=$RC out=$CAP)"
fi
run "$P12"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "INDETERMINATE"; } \
  && ok "AC-12 post-fix: executor+no-model+unreadable-tx -> exit 2 via the named unknown branch" \
  || bad "AC-12 post-fix should fail-closed via the named unknown branch (rc=$RC out=$CAP)"

# ---- AC-13: agent-def does NOT rescue a badge-less cheap seat. executor, no model, subagent_type cc-executor
#      (frontmatter sonnet), OPUS_TX. Effective resolves to the SESSION tier (opus) != sonnet -> BLOCK. ----
P13='{"session_id":"ac13","tool_input":{"prompt":"3ROLE_TASK:9106 ROLE:executor\nImplement.","subagent_type":"cc-executor"},"transcript_path":"'"$OPUS_TX"'"}'
run "$P13"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "opus"; } \
  && ok "AC-13: cc-executor frontmatter=sonnet under an opus-session transcript -> exit 2 (frontmatter does not rescue)" \
  || bad "AC-13 should block on the session tier, not wave through on the frontmatter (rc=$RC out=$CAP)"

# ---- AC-14: escapes preserved (kill-switch, inline bypass, untagged) — each on a FRESH, otherwise-positive
#      signature (non-vacuity: proves the escape suppressed a REAL block, not an already-silent path). ----
P14a='{"session_id":"ac14a","tool_input":{"prompt":"3ROLE_TASK:9107 ROLE:planner\nPlan it."},"transcript_path":"'"$FABLE_TX"'"}'
runh "$HOOK" "$P14a" CC_ROLE_MODEL_GATE_OFF=1; rc14a=$RC
P14b='{"session_id":"ac14b","tool_input":{"prompt":"3ROLE_TASK:9108 ROLE:planner [model-policy-ok]\nPlan it."},"transcript_path":"'"$FABLE_TX"'"}'
run "$P14b"; rc14b=$RC
P14c='{"session_id":"ac14c","tool_input":{"prompt":"General research, no tags at all."},"transcript_path":"'"$FABLE_TX"'"}'
run "$P14c"; rc14c=$RC
{ [ "$rc14a" = "0" ] && [ "$rc14b" = "0" ] && [ "$rc14c" = "0" ]; } \
  && ok "AC-14: kill-switch / inline bypass / untagged spawn all -> exit 0 on an otherwise-positive FABLE_TX payload" \
  || bad "AC-14 escapes should suppress a real block (rc_a=$rc14a rc_b=$rc14b rc_c=$rc14c)"

# ---- AC-15: block-once — re-issuing the IDENTICAL AC-8 post-fix payload a second time -> exit 0
#      (the per-session:taskId:role marker was dropped on the first block). ----
run "$P8"
{ [ "$RC" = "0" ]; } \
  && ok "AC-15: AC-8 payload re-issued -> exit 0 (block-once marker dropped on first block, not wedged)" \
  || bad "AC-15 should fall through on re-issue (rc=$RC out=$CAP)"

echo "== SECTION 3: legacy explicit-model / escape-mechanics regression coverage (unaffected by #1494) =="

# ---- L1. executor + model:opus (violates sonnet policy), FRESH sig -> exit 2 + names role + expected tier. ----
PL1='{"session_id":"l1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9201 ROLE:executor\nImplement."}}'
run "$PL1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor" && echo "$CAP" | grep -q "sonnet"; } \
  && ok "L1: executor model:opus (fresh) -> exit 2, names role + sonnet policy" \
  || bad "L1 fresh violation should block visibly (rc=$RC out=$CAP)"

# ---- L2. SAME signature again (marker present) -> exit 0 (block-once, not wedged). ----
run "$PL1"
{ [ "$RC" = "0" ]; } && ok "L2: same signature again -> exit 0 (block-once, not wedged)" || bad "L2 second identical spawn should fall through (rc=$RC out=$CAP)"

# ---- L3. DIFFERENT signature (different taskId, same session) AFTER L1's marker exists -> exit 2 again. ----
PL3='{"session_id":"l1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9202 ROLE:executor\nDifferent task, same violation."}}'
run "$PL3"
{ [ "$RC" = "2" ]; } && ok "L3: DIFFERENT taskId offense after first fire -> STILL exit 2 (blocks again)" || bad "L3 different signature must still block (rc=$RC out=$CAP)"

# ---- L4. executor + model:sonnet (matches policy) -> exit 0 silent. ----
PL4='{"session_id":"l4","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9203 ROLE:executor\nGo."}}'
run "$PL4"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L4: executor model:sonnet (match) -> exit 0 silent" || bad "L4 matching model should be silent allow (rc=$RC out=$CAP)"

# ---- L5. planner + model:sonnet -> explicit WRONG tier on an opus seat -> exit 2. ----
PL5='{"session_id":"l5","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9204 ROLE:planner\nPlan it, wrong tier."}}'
run "$PL5"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "opus"; } && ok "L5: planner model:sonnet (explicit wrong on opus seat) -> exit 2" || bad "L5 explicit wrong tier should block (rc=$RC out=$CAP)"

# ---- L6. non-tagged spawn (no 3ROLE_TASK, no ROLE) -> exit 0 silent (the norm). ----
run '{"session_id":"l6","tool_input":{"prompt":"Do some general research. No tags."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L6: non-tagged spawn -> exit 0 silent" || bad "L6 untagged spawn should be silent allow (rc=$RC out=$CAP)"

# ---- L7. role-only, no task tag -> exit 0 silent. L7b. task-only, no role tag -> exit 0 silent. ----
run '{"session_id":"l7","tool_input":{"model":"opus","prompt":"ROLE:executor\nNo task tag here."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L7: role-only (no task tag) -> exit 0 silent" || bad "L7 role-only should be silent allow (rc=$RC out=$CAP)"
run '{"session_id":"l7b","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9205\nSome work, no role tag."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L7b: task-only (no role tag) -> exit 0 silent" || bad "L7b task-only should be silent allow (rc=$RC out=$CAP)"

# ---- L8. kill-switches on an OTHERWISE-POSITIVE explicit-model payload -> exit 0. ----
PL8a='{"session_id":"l8a","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9206 ROLE:executor\nviolation."}}'
run "$PL8a" CC_ROLE_MODEL_GATE_OFF=1; rcl8a=$RC
PL8b='{"session_id":"l8b","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9207 ROLE:executor\nviolation."}}'
run "$PL8b" THREE_ROLE_INSTRUMENT_OFF=1; rcl8b=$RC
PL8c='{"session_id":"l8c","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9208 ROLE:executor\nviolation."}}'
run "$PL8c" SHIP_PIPELINE=1; rcl8c=$RC
{ [ "$rcl8a" = "0" ] && [ "$rcl8b" = "0" ] && [ "$rcl8c" = "0" ]; } \
  && ok "L8: kill-switches on POSITIVE explicit-model payload -> exit 0" \
  || bad "L8 kill-switches should suppress a real block (rc_a=$rcl8a rc_b=$rcl8b rc_c=$rcl8c)"

# ---- L9. bypass-form coverage (#749): role tag in the description field + model in tool_input.model. ----
PL9='{"session_id":"l9","tool_input":{"model":"opus","description":"3ROLE_TASK:9209 ROLE:executor","prompt":"Implementation work, tags in description."}}'
run "$PL9"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor"; } \
  && ok "L9: tags in description field -> still detected -> exit 2" \
  || bad "L9 should read joined field set incl. description (rc=$RC out=$CAP)"

# ---- L10. malformed / empty payload -> exit 0 (fail-open). ----
run 'not json {{{'; rcl10a=$RC
run '{"session_id":"l10"}'; rcl10b=$RC
{ [ "$rcl10a" = "0" ] && [ "$rcl10b" = "0" ]; } && ok "L10: malformed / empty payload -> exit 0 (fail-open)" || bad "L10 malformed should fail-open exit 0 (rcl10a=$rcl10a rcl10b=$rcl10b)"

# ---- L11. NO-CONFIG fail-safe: CC_ROLES_ENV=/nonexistent -> policy resolves to opus for every role -> an
#      executor+model:opus spawn effective=opus == opus -> exit 0 (no false-block when config is absent). ----
PL11='{"session_id":"l11","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9210 ROLE:executor\nno config."}}'
run "$PL11" CC_ROLES_ENV=/nonexistent
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L11: no-config executor+opus -> exit 0 (fail-safe opus, no false-block)" || bad "L11 no-config should fail-safe to opus (rc=$RC out=$CAP)"

# ---- L12. FABLE config: executor=fable, spawn model:opus -> exit 2 with the (corrected) Fable cost-cliff note. ----
PL12='{"session_id":"l12","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9211 ROLE:executor\nfable policy."}}'
run "$PL12" CC_ROLES_ENV="$CFGF"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "Fable" && echo "$CAP" | grep -q "July 12"; } \
  && ok "L12: fable-executor config + model:opus -> exit 2 + corrected Fable cost-cliff note (July 12)" \
  || bad "L12 fable seat mismatch should block with the corrected note (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
