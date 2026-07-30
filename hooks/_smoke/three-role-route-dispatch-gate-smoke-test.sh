#!/usr/bin/env bash
# Smoke for hooks/three-role-route-dispatch-gate.sh (#1989). Exit 0 = all cases pass.
#
# The hook is a PreToolUse(Agent|Task) BLOCK-ONCE nudge: on the POSITIVE condition (a tagged chain-role spawn
# whose seat the routes SSOT declares `dispatch: subprocess-openrouter`) it exits 2 the FIRST time per
# session:task:role signature, then exits 0 (block-once); everything else fail-opens exit 0 silent. Both-ends:
# each fixture FAILS on wrong behavior, PASSES on correct. No `set -e` (a non-block non-zero must never leak
# into a permission decision — #749).
#
# Self-contained via CC_ROUTES_JSON fixtures the smoke writes itself (the 3role-ledger-smoke-test.sh
# precedent, 15 existing uses), so it passes in BOTH populations — ai-brain (real config/cc-routes.json) and
# the three-role-model plugin (which ships no config/cc-routes.json; the smoke's own fixture drives the
# resolve-route read). A synced smoke must never FAIL on an ai-brain-only dependency.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-route-dispatch-gate.sh"
# The bypass-audit writer (hook_log_bypass) lives in lib-hook-override.sh, which ai-brain ships in hooks/ but
# the three-role-model plugin does NOT port (it is not a SYNCED entry). So in a plugin install the hook's
# `type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass ...` call sites are guarded no-ops — escapes still
# exit 0, but NO audit rows are written. The AC-5e/AC-5g row-count assertions (an ai-brain-only dep) are gated
# on this so the smoke passes in BOTH populations (a synced smoke must never FAIL on an ai-brain-only dep).
HAS_OVERRIDE_LIB=0
[ -f "$(dirname "$HOOK")/lib-hook-override.sh" ] && HAS_OVERRIDE_LIB=1

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
LOG="$TMP/bypass.log"

# #2105 D3 backstop mode fixtures. This hook's positive block-once path (AC-3/AC-4 below) now ALSO requires
# mode=conservative (the new mode gate at three-role-route-dispatch-gate.sh:147-161) -- so those assertions
# must explicitly pin CC_MODE_FILE=$CONS_PIN or they'll silently stop firing under whatever mode this dev
# machine's real environment happens to resolve to (normally normal/default, since this smoke never sets
# HOME). CC_MODE_FILE is an isolated scratch path per pin -- this smoke NEVER reads or writes the real
# ~/.config/cc-mode.json. NO_PIN is deliberately never created -> resolves to mode=normal via source=default
# (the AC-11a arm). SB_PIN pins speed-boost (the AC-11c arm).
LED="$ROOT/bin/3role-ledger.mjs"
CONS_PIN="$TMP/cons-pin.json"
CC_MODE_FILE="$CONS_PIN" node "$LED" set-mode --mode conservative --reason smoke >/dev/null 2>&1
NO_PIN="$TMP/no-pin-never-created.json"
SB_PIN="$TMP/sb-pin.json"
CC_MODE_FILE="$SB_PIN" node "$LED" set-mode --mode speed-boost --reason smoke >/dev/null 2>&1

# Fixture A — BOTH plan-review and executor declared subprocess-openrouter (real #1947 shape). Drives AC-3/4
# (the two declared seats each have their OWN session:task:role signature -> distinct markers, no
# cannibalization). task_classes + provider data_posture are present so resolve-route's capability (C-2) and
# sensitivity (C-3) guards clear and JSON (with the dispatch field) actually reaches stdout.
ROUTES_SUBPROC="$TMP/routes-subproc.json"
cat > "$ROUTES_SUBPROC" <<'J'
{
  "providers": {
    "openrouter": { "auth": "env:OPENROUTER_API_KEY", "endpoint": "https://openrouter.ai/api",
                    "data_posture": { "class": "unverified-or-trains" } }
  },
  "task_classes": { "sustained-agentic": { "allowed_providers": ["anthropic", "openrouter"] } },
  "seats": {
    "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter",
                     "agent_tool_fallback": "opus", "task_class": "sustained-agentic", "data_sensitivity": "public" },
    "executor":    { "provider": "openrouter", "model": "z-ai/glm-5.2", "dispatch": "subprocess-openrouter",
                     "agent_tool_fallback": "sonnet", "task_class": "sustained-agentic", "data_sensitivity": "public" }
  }
}
J

# Fixture B — a seat with NO dispatch field (e.g. plan-review acting as a plain Anthropic seat). The hook must
# fail-OPEN: resolve-route emits JSON with no `dispatch` key -> SEAT_DISPATCH empty -> exit 0 silent. This is
# the "seat has no dispatch field" arm of AC-5 (genuinely reachable — planner/execution-review/research all
# resolve this way, and a fixture-only seat with dispatch omitted reproduces it deterministically).
ROUTES_NODISP="$TMP/routes-nodisp.json"
cat > "$ROUTES_NODISP" <<'J'
{
  "providers": {
    "anthropic": { "auth": "keychain:Claude Code-credentials", "endpoint": "https://api.anthropic.com",
                   "data_posture": { "class": "anthropic-baseline" } }
  },
  "task_classes": { "sustained-agentic": { "allowed_providers": ["anthropic"] } },
  "seats": {
    "plan-review": { "provider": "anthropic", "model": "claude-opus-5", "task_class": "sustained-agentic",
                     "data_sensitivity": "public" }
  }
}
J

# runh <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Pins CC_ROUTES_JSON=$1 (default the subprocess fixture)
# and an ISOLATED STATE_DIR (override via env arg). Captures stderr+stdout merged so the exit-2 <system-reminder>
# is visible; the hook writes the nudge to stderr only, so CAP carries it exactly when RC=2.
runh() {
  local routes="$1" payload="$2"; shift 2
  CAP=$(printf '%s' "$payload" \
    | env CC_ROUTES_JSON="$routes" "$@" CC_ROUTE_DISPATCH_STATE_DIR="$STATE" bash "$HOOK" 2>&1); RC=$?
}
run() { runh "$ROUTES_SUBPROC" "$@"; }

echo "== SECTION 0: static syntax checks =="

# ---- AC-0: bash -n on every shell file this ticket touches. ----
bash -n "$HOOK" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0a: bash -n three-role-route-dispatch-gate.sh -> syntax OK" || bad "AC-0a: bash -n three-role-route-dispatch-gate.sh FAILED"
bash -n "$DIR/three-role-route-dispatch-gate-smoke-test.sh" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0b: bash -n three-role-route-dispatch-gate-smoke-test.sh (self) -> syntax OK" || bad "AC-0b: bash -n (self) FAILED"

echo "== SECTION 1: positive block-once + no home-path leak — AC 3-4 =="

# ---- AC-3: plan-review, SSOT-declared subprocess, FIRST issue -> exit 2; stderr names the helper
#      repo-relatively (tools/openrouter-role-dispatch.sh) and contains NO /Users/ substring (N5); the IDENTICAL
#      second issue -> exit 0 (block-once, never wedged). ----
P3='{"session_id":"9989","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:plan-review\nreview the plan"}}'
run "$P3" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "tools/openrouter-role-dispatch.sh" && ! echo "$CAP" | grep -q "/Users/"; } \
  && ok "AC-3 first issue: plan-review subprocess seat -> exit 2, stderr names tools/openrouter-role-dispatch.sh, no /Users/ leak" \
  || bad "AC-3 first issue should block + name helper + leak no home path (rc=$RC out=$CAP)"
run "$P3" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-3 second issue: identical re-issue -> exit 0 silent (block-once, not wedged)" \
  || bad "AC-3 second issue should exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-4: executor arm + independence. A DIFFERENT role (executor) on the SAME session/task has a DIFFERENT
#      signature -> it blocks on FIRST issue EVEN AFTER AC-3's plan-review marker exists in the same STATE_DIR
#      (distinct signature, no cannibalization). ----
P4='{"session_id":"9989","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:executor\nimplement the plan"}}'
run "$P4" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "executor" && echo "$CAP" | grep -q "tools/openrouter-role-dispatch.sh"; } \
  && ok "AC-4: executor subprocess seat -> exit 2 even after AC-3's plan-review marker exists (distinct session:task:role signature)" \
  || bad "AC-4 executor should block on first issue independent of the plan-review marker (rc=$RC out=$CAP)"
# and its own re-issue exits 0 (block-once per signature).
run "$P4" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-4 second issue: executor re-issue -> exit 0 silent (block-once)" \
  || bad "AC-4 second issue should exit 0 silent (rc=$RC out=$CAP)"

echo "== SECTION 2: fail-open + escapes (escapes LOGGED) — AC 5 =="

# ---- AC-5a: untagged spawn (no 3ROLE_TASK/ROLE tags) -> exit 0 silent (the norm; a bare Agent spawn must
#      never be false-blocked). Non-vacuous: the SAME plan-review seat blocks when tagged (AC-3). ----
P5a='{"session_id":"ac5a","tool_input":{"prompt":"general research, no role tags at all"}}'
run "$P5a"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-5a: untagged spawn -> exit 0 silent (fail-open, the norm)" \
  || bad "AC-5a untagged should fail-open exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-5b: tagged spawn under a fixture whose seat has NO dispatch field -> exit 0 silent (resolve-route
#      emits JSON with no dispatch -> SEAT_DISPATCH empty -> fail-open). ----
P5b='{"session_id":"ac5b","tool_input":{"prompt":"3ROLE_TASK:9501 ROLE:plan-review\nreview"}}'
runh "$ROUTES_NODISP" "$P5b"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-5b: tagged spawn, seat has NO dispatch field -> exit 0 silent (fail-open, not in scope)" \
  || bad "AC-5b no-dispatch seat should fail-open exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-5c: dedicated kill-switch CC_ROUTE_DISPATCH_GATE_OFF=1 -> exit 0 (escape suppresses a REAL block —
#      the same plan-review payload blocks when ungated, AC-3). ----
P5c='{"session_id":"ac5c","tool_input":{"prompt":"3ROLE_TASK:9502 ROLE:plan-review\nreview"}}'
run "$P5c" CC_ROUTE_DISPATCH_GATE_OFF=1
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-5c: CC_ROUTE_DISPATCH_GATE_OFF=1 -> exit 0 (kill-switch suppresses a real block)" \
  || bad "AC-5c kill-switch should exit 0 (rc=$RC out=$CAP)"

# ---- AC-5d: inline token [route-dispatch-fallback-ok] in the prompt -> exit 0 (deliberate sanctioned
#      fallback, suppresses a real block). ----
P5d='{"session_id":"ac5d","tool_input":{"prompt":"3ROLE_TASK:9503 ROLE:plan-review [route-dispatch-fallback-ok]\nreview"}}'
run "$P5d"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-5d: [route-dispatch-fallback-ok] inline token -> exit 0 (deliberate fallback)" \
  || bad "AC-5d inline token should exit 0 (rc=$RC out=$CAP)"

# ---- AC-5e (N1): the inline-token escape AND the CC_ROUTE_DISPATCH_GATE_OFF=1 escape are AUDIT-LOGGED
#      (never silent — the exact class of invisible bypass this ticket exists to kill). With RULE12_LOG pointed
#      at a scratch file, BOTH invocations append an audit row NAMING this hook; >=2 rows total. The cited
#      precedent (three-role-model-policy-gate.sh:126) exits 0 on its inline token WITHOUT logging — this hook
#      must NOT copy that. ----
rm -f "$LOG"
runh "$ROUTES_SUBPROC" "$P5d" RULE12_LOG="$LOG"
runh "$ROUTES_SUBPROC" "$P5c" RULE12_LOG="$LOG" CC_ROUTE_DISPATCH_GATE_OFF=1
ROWS=0; [ -f "$LOG" ] && ROWS=$(grep -c "three-role-route-dispatch-gate" "$LOG")
if [ "$HAS_OVERRIDE_LIB" = "1" ]; then
  { [ "$ROWS" -ge 2 ]; } \
    && ok "AC-5e (N1): inline-token + CC_ROUTE_DISPATCH_GATE_OFF escapes each append an audit row naming the hook ($ROWS rows) — never silent" \
    || bad "AC-5e (N1) escapes should be audit-logged >=2 rows naming the hook (got $ROWS rows; log=$(cat "$LOG" 2>/dev/null))"
else
  { [ "$ROWS" = "0" ]; } \
    && ok "AC-5e (N1) plugin-safe: lib-hook-override.sh absent -> hook_log_bypass is a guarded no-op, escapes still exit 0, logging dormant (rows=0) — the ai-brain-only audit dep this smoke must not hard-require" \
    || bad "AC-5e (N1) plugin: with no override lib NO rows should be written (got $ROWS) — a plugin install has no log-bypass writer"
fi

# ---- AC-5f: SSOT-unresolvable seat (resolve-route --seat <unknown> exits 2 with a non-JSON line) -> exit 0
#      silent. The fail-open keys on JSON-parse success, NEVER on empty output (round-1 nuance). ----
P5f='{"session_id":"ac5f","tool_input":{"prompt":"3ROLE_TASK:9504 ROLE:plan-review\nreview"}}'
# A fixture with NO seats block at all -> resolve-route exits 2 ROUTE-SEAT-NOT-FOUND -> fail-open.
ROUTES_NOSEAT="$TMP/routes-noseat.json"
printf '{"seats":{}}' > "$ROUTES_NOSEAT"
runh "$ROUTES_NOSEAT" "$P5f"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-5f: SSOT-unresolvable seat (ROUTE-SEAT-NOT-FOUND, non-JSON stdout) -> exit 0 silent (fail-open keys on JSON-parse, not empty output)" \
  || bad "AC-5f unresolvable seat should fail-open exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-5g: family switches THREE_ROLE_INSTRUMENT_OFF=1 and SHIP_PIPELINE=1 -> exit 0 (the plan's prose says
#      every escape is audit-logged; these are logged too — verified by an extra RULE12_LOG row each). ----
run "$P5c" THREE_ROLE_INSTRUMENT_OFF=1
rcTri=$RC
run "$P5c" SHIP_PIPELINE=1
rcShip=$RC
rm -f "$LOG"
runh "$ROUTES_SUBPROC" "$P5c" RULE12_LOG="$LOG" THREE_ROLE_INSTRUMENT_OFF=1
runh "$ROUTES_SUBPROC" "$P5c" RULE12_LOG="$LOG" SHIP_PIPELINE=1
ROWS2=0; [ -f "$LOG" ] && ROWS2=$(grep -c "three-role-route-dispatch-gate" "$LOG")
if [ "$HAS_OVERRIDE_LIB" = "1" ]; then
  { [ "$rcTri" = "0" ] && [ "$rcShip" = "0" ] && [ "$ROWS2" -ge 2 ]; } \
    && ok "AC-5g: THREE_ROLE_INSTRUMENT_OFF + SHIP_PIPELINE -> exit 0 AND audit-logged ($ROWS2 rows, prose implemented as written)" \
    || bad "AC-5g family switches should exit 0 + log >=2 rows (rcTri=$rcTri rcShip=$rcShip rows=$ROWS2)"
else
  { [ "$rcTri" = "0" ] && [ "$rcShip" = "0" ] && [ "$ROWS2" = "0" ]; } \
    && ok "AC-5g plugin-safe: family switches -> exit 0, logging dormant (rows=0, no override lib) — exits still proven" \
    || bad "AC-5g plugin: family switches should exit 0 with no rows (rcTri=$rcTri rcShip=$rcShip rows=$ROWS2)"
fi

echo "== SECTION 3: #2105 D3 mode-awareness backstop — AC 11(a)/(b)/(c) =="

# ---- AC-11(a): mode=normal (default, NO_PIN never created -> source=default) -- the SAME subprocess-declared
#      plan-review payload that blocks under conservative (AC-3) now stays COMPLETELY SILENT on its FIRST
#      issue: outside conservative mode the Agent-tool spawn of this seat IS the sanctioned primary (D3's own
#      dispatch helpers refuse the subprocess route themselves in normal/speed-boost), so nudging it here
#      would just train every routine normal-mode spawn to carry the bypass token. Distinct session id so no
#      STATE_DIR marker collision with AC-3's own signature. ----
P11A='{"session_id":"ac11a","tool_input":{"prompt":"3ROLE_TASK:9601 ROLE:plan-review\nreview the plan"}}'
run "$P11A" CC_MODE_FILE="$NO_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11a: mode=normal (default) -> exit 0 silent on FIRST issue (non-conservative = Agent-tool IS sanctioned primary)" \
  || bad "AC-11a normal mode should stay silent even on first issue (rc=$RC out=$CAP)"

# ---- AC-11(b): mode=conservative -> byte-identical to today's (pre-#2105) behavior. Re-derive independently
#      of AC-3 (fresh session id, fresh signature) so this arm doesn't just inherit AC-3's already-proven
#      marker state. ----
P11B='{"session_id":"ac11b","tool_input":{"prompt":"3ROLE_TASK:9602 ROLE:plan-review\nreview the plan"}}'
run "$P11B" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "tools/openrouter-role-dispatch.sh" && ! echo "$CAP" | grep -q "/Users/"; } \
  && ok "AC-11b: mode=conservative -> exit 2 first issue, byte-identical shape to pre-#2105 (helper named, no home-path leak)" \
  || bad "AC-11b conservative mode should block first issue exactly as before #2105 (rc=$RC out=$CAP)"
run "$P11B" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11b: mode=conservative re-issue -> exit 0 silent (block-once still holds under the mode gate)" \
  || bad "AC-11b conservative re-issue should exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-11(c): mode=speed-boost (a SECOND non-conservative mode, not just "not pinned") -> also silent,
#      proving the gate keys on "== conservative", not merely "!= normal" / "no pin present". ----
P11C='{"session_id":"ac11c","tool_input":{"prompt":"3ROLE_TASK:9603 ROLE:executor\nimplement the plan"}}'
run "$P11C" CC_MODE_FILE="$SB_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11c: mode=speed-boost -> exit 0 silent (gate keys on ==conservative, not merely !=normal)" \
  || bad "AC-11c speed-boost mode should stay silent (rc=$RC out=$CAP)"

# ---- AC-11(d): a crashed/unreadable mode resolver still fails OPEN (silent), matching the hook's own
#      documented convention -- point CC_MODE_FILE at a directory (not a file) so resolve-mode's fs.readFileSync
#      throws a NON-ENOENT error (EISDIR), which loadModePolicy/resolveMode surface as invalid-pin-fallback,
#      never "conservative". ----
P11D='{"session_id":"ac11d","tool_input":{"prompt":"3ROLE_TASK:9604 ROLE:plan-review\nreview the plan"}}'
run "$P11D" CC_MODE_FILE="$TMP"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11d: unreadable/crashed mode pin -> fails OPEN (silent), never mistaken for conservative" \
  || bad "AC-11d a broken mode resolution should fail open silent, not block (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
