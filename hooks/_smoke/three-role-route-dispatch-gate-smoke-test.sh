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
# (the AC-11a arm). SB_PIN pins boost (the AC-11c arm).
LED="$ROOT/bin/3role-ledger.mjs"
CONS_PIN="$TMP/cons-pin.json"
CC_MODE_FILE="$CONS_PIN" node "$LED" set-mode --mode conservative --reason smoke >/dev/null 2>&1
NO_PIN="$TMP/no-pin-never-created.json"
SB_PIN="$TMP/sb-pin.json"
CC_MODE_FILE="$SB_PIN" node "$LED" set-mode --mode boost --reason smoke >/dev/null 2>&1
# #2518 D3 generalization fixture — a `hybrid` pin (zai_dispatch=permitted, openrouter_dispatch=forbidden,
# local_dispatch=forbidden). Reads the REAL config/cc-mode-policy.json (no CC_MODE_POLICY_JSON override, same
# as the conservative/boost pins above), which now carries the `hybrid` mode this ticket added.
HYB_PIN="$TMP/hyb-pin.json"
CC_MODE_FILE="$HYB_PIN" node "$LED" set-mode --mode hybrid --reason smoke >/dev/null 2>&1

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

# Fixture A-zai (#2518) — a seat declared subprocess-zai (real hybrid-mode shape: the executor dispatched to
# z.ai direct). Same task_class/data_posture shape as Fixture A so resolve-route's C-2/C-3 guards clear.
ROUTES_SUBPROC_ZAI="$TMP/routes-subproc-zai.json"
cat > "$ROUTES_SUBPROC_ZAI" <<'J'
{
  "providers": {
    "zai": { "auth": "env:ZAI_API_KEY", "endpoint": "https://api.z.ai/api/anthropic",
             "data_posture": { "class": "no-training-default" } }
  },
  "task_classes": { "sustained-agentic": { "allowed_providers": ["anthropic", "zai"] } },
  "seats": {
    "executor": { "provider": "zai", "model": "glm-5.3-flash", "dispatch": "subprocess-zai",
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
#      dispatch helpers refuse the subprocess route themselves in normal/boost), so nudging it here
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

# ---- AC-11(c): mode=boost (a SECOND non-conservative mode, not just "not pinned") -> also silent,
#      proving the gate keys on "== conservative", not merely "!= normal" / "no pin present". ----
P11C='{"session_id":"ac11c","tool_input":{"prompt":"3ROLE_TASK:9603 ROLE:executor\nimplement the plan"}}'
run "$P11C" CC_MODE_FILE="$SB_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11c: mode=boost -> exit 0 silent (gate keys on ==conservative, not merely !=normal)" \
  || bad "AC-11c boost mode should stay silent (rc=$RC out=$CAP)"

# ---- AC-11(d): a crashed/unreadable mode resolver still fails OPEN (silent), matching the hook's own
#      documented convention -- point CC_MODE_FILE at a directory (not a file) so resolve-mode's fs.readFileSync
#      throws a NON-ENOENT error (EISDIR), which loadModePolicy/resolveMode surface as invalid-pin-fallback,
#      never "conservative". ----
P11D='{"session_id":"ac11d","tool_input":{"prompt":"3ROLE_TASK:9604 ROLE:plan-review\nreview the plan"}}'
run "$P11D" CC_MODE_FILE="$TMP"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-11d: unreadable/crashed mode pin -> fails OPEN (silent), never mistaken for conservative" \
  || bad "AC-11d a broken mode resolution should fail open silent, not block (rc=$RC out=$CAP)"

echo "== SECTION 4: #2518 D3 generalization — subprocess-zai under hybrid, per-provider axis isolation =="

# ---- AC-12a: hybrid + subprocess-zai seat -> exit 2 on FIRST issue (zai_dispatch=permitted under hybrid is
#      the live axis for this seat's own provider), naming subprocess-zai (not a hard-coded provider) and the
#      helper path, no home-path leak; identical RE-ISSUE -> exit 0 silent (block-once, same as every other
#      provider). ----
# #2985: an executor spawn on a subprocess-zai seat must now name its plan (size-label routing), so this arm
# cites a smoke-written S plan (bound to task 9701 by its basename) and runs the hook with that dir as cwd. The
# plan is written by the smoke itself so the arm needs no committed fixture (plugin-safe).
AC12A_DIR="$TMP/ac12a"; mkdir -p "$AC12A_DIR/.ai-workspace/plans"
printf 'size: S\n' > "$AC12A_DIR/.ai-workspace/plans/2026-10-03-9701-plan.md"
P12A='{"session_id":"ac12a","tool_input":{"prompt":"3ROLE_TASK:9701 ROLE:executor\nPLAN: .ai-workspace/plans/2026-10-03-9701-plan.md\nimplement the plan"}}'
runh_in() { local d="$1" routes="$2" payload="$3"; shift 3; CAP=$(cd "$d" && printf '%s' "$payload" | env CC_ROUTES_JSON="$routes" "$@" CC_ROUTE_DISPATCH_STATE_DIR="$STATE" bash "$HOOK" 2>&1); RC=$?; }
runh_in "$AC12A_DIR" "$ROUTES_SUBPROC_ZAI" "$P12A" CC_MODE_FILE="$HYB_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "subprocess-zai" && echo "$CAP" | grep -q "tools/openrouter-role-dispatch.sh" && ! echo "$CAP" | grep -q "/Users/"; } \
  && ok "AC-12a: hybrid + subprocess-zai seat -> exit 2 first issue, names subprocess-zai + helper, no home-path leak" \
  || bad "AC-12a hybrid+zai should block first issue naming subprocess-zai + helper (rc=$RC out=$CAP)"
runh_in "$AC12A_DIR" "$ROUTES_SUBPROC_ZAI" "$P12A" CC_MODE_FILE="$HYB_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-12a second issue: hybrid + subprocess-zai re-issue -> exit 0 silent (block-once, not wedged)" \
  || bad "AC-12a second issue should exit 0 silent (rc=$RC out=$CAP)"

# ---- AC-12b: hybrid + subprocess-openrouter seat -> silent on FIRST issue. Under hybrid,
#      openrouter_dispatch=forbidden (hybrid opens ONLY the z.ai door), so an Agent-tool spawn of an
#      OpenRouter-declared seat is the sanctioned fallback (the dispatch helper would refuse the subprocess
#      route too) -- proves the axis isolation is per-PROVIDER, not "any subprocess-* seat under hybrid". ----
P12B='{"session_id":"ac12b","tool_input":{"prompt":"3ROLE_TASK:9702 ROLE:plan-review\nreview the plan"}}'
run "$P12B" CC_MODE_FILE="$HYB_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-12b: hybrid + subprocess-openrouter seat -> exit 0 silent (openrouter stays shut under hybrid)" \
  || bad "AC-12b hybrid+openrouter should stay silent (rc=$RC out=$CAP)"

# ---- AC-12c: normal + subprocess-zai seat -> silent on FIRST issue. Under normal, zai_dispatch=forbidden, so
#      the same seat that blocks under hybrid (AC-12a) is silent here -- the axis, not the seat, decides. ----
P12C='{"session_id":"ac12c","tool_input":{"prompt":"3ROLE_TASK:9703 ROLE:executor\nimplement the plan"}}'
runh "$ROUTES_SUBPROC_ZAI" "$P12C" CC_MODE_FILE="$NO_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-12c: normal + subprocess-zai seat -> exit 0 silent (zai stays shut outside hybrid)" \
  || bad "AC-12c normal+zai should stay silent (rc=$RC out=$CAP)"

# ---- AC-12d: conservative + subprocess-openrouter -> exit 2 (UNCHANGED regression check under the
#      generalized per-provider code path -- re-derived independently of AC-11b's own session id/signature). ----
P12D='{"session_id":"ac12d","tool_input":{"prompt":"3ROLE_TASK:9704 ROLE:plan-review\nreview the plan"}}'
run "$P12D" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "subprocess-openrouter" && echo "$CAP" | grep -q "tools/openrouter-role-dispatch.sh" && ! echo "$CAP" | grep -q "/Users/"; } \
  && ok "AC-12d: conservative + subprocess-openrouter -> exit 2 (unchanged), naming subprocess-openrouter under the generalized code path" \
  || bad "AC-12d conservative+openrouter should still block first issue (rc=$RC out=$CAP)"


echo "== SECTION 5: #2985 — executor routed by plan size label; z.ai plan-review 2-strike rule; data-class =="
# Fixtures: hooks/fixtures/2985-size-label/ (override FIX2985=<dir>). Absent in a plugin install -> honest SKIP.
# The hook runs with cwd = the fixture dir so the prompt's repo-relative `.ai-workspace/plans/...` path resolves.
FX2985="${FIX2985:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/2985-size-label}"
if [ ! -d "$FX2985/.ai-workspace/plans" ]; then
  echo "SKIP: #2985 gate arms: fixture dir '$FX2985' absent (plugin install) — section not run"
else
RZ2985="$FX2985/routes-zai.json"
ST2985="$TMP/state2985"; mkdir -p "$ST2985"
KEY_OK="$TMP/zai-key-present.env"; : > "$KEY_OK"          # empty file: presence is all the gate tests
KEY_GONE="$TMP/zai-key-absent.env"                          # never created
LOG2985="$TMP/bypass2985.log"
PLD="2026-10-03-777-plan"
# g2985 <payload> [env KEY=VAL ...] -> RC, CAP. hybrid pin, zai fixture routes, cwd = fixture dir.
g2985() {
  local payload="$1"; shift
  CAP=$(cd "$FX2985" && printf '%s' "$payload" | env CC_ROUTES_JSON="$RZ2985" CC_ROLES_ENV="$FX2985/roles.env" CC_MODE_FILE="$HYB_PIN" \
    ZAI_KEY_FILE="$KEY_OK" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-0.md" "$@" CC_ROUTE_DISPATCH_STATE_DIR="$ST2985" RULE12_LOG="$LOG2985" bash "$HOOK" 2>&1); RC=$?
}
mk2985() { printf '{"session_id":"%s","tool_input":{"prompt":"%s"}}' "$1" "$2"; }
nmark() { ls "$ST2985" 2>/dev/null | grep -c '\.notified$'; }
nrows() { [ -f "$LOG2985" ] && grep -c "three-role-route-dispatch-gate" "$LOG2985" || echo 0; }
rowsok() { if [ "$HAS_OVERRIDE_LIB" = "1" ]; then [ "$(nrows)" = "$1" ]; else true; fi; }

# ---- AC-4 executor arms (tagged 3ROLE_TASK:777 ROLE:executor) ----
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g4L "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md\nimplement")
g2985 "$P"
{ [ "$RC" = "0" ] && [ -z "$CAP" ] && [ "$(nmark)" = "0" ] && rowsok 0; } \
  && ok "#2985 AC-4: executor spawn citing an L plan -> exit 0 silent, no marker, no bypass-audit row (first-class path)" || bad "#2985 AC-4 L plan (rc=$RC markers=$(nmark) rows=$(nrows) out=$CAP)"
P=$(mk2985 g4S "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-S.md\nimplement")
g2985 "$P"; rc1=$RC; out1="$CAP"; m1=$(nmark)
g2985 "$P"; rc2=$RC; out2="$CAP"
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ] && [ -z "$out2" ] && printf '%s' "$out1" | grep -q "tools/openrouter-role-dispatch.sh"; } \
  && ok "#2985 AC-4: executor + S plan -> exit 2 first (marker), exit 0 second (today's block-once, unchanged)" || bad "#2985 AC-4 S plan (rc1=$rc1 m1=$m1 rc2=$rc2 out1=$out1)"
P=$(mk2985 g4M "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-M.md\nimplement")
g2985 "$P"; rc1=$RC; g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "0" ]; } && ok "#2985 AC-4 held-out: an M plan behaves exactly as S (block-once)" || bad "#2985 AC-4 M plan (rc1=$rc1 rc2=$rc2)"
for pair in "none:SIZE-LABEL-MISSING" "indent:SIZE-LABEL-MISSING" "lower:SIZE-LABEL-INVALID" "xl:SIZE-LABEL-INVALID" "two:SIZE-LABEL-AMBIGUOUS"; do
  nm="${pair%%:*}"; tok="${pair#*:}"
  P=$(mk2985 "g4$nm" "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-$nm.md\nimplement")
  g2985 "$P"; rc1=$RC; out1="$CAP"; g2985 "$P"; rc2=$RC
  { [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && printf '%s' "$out1" | grep -q "$tok"; } \
    && ok "#2985 AC-4: executor + $nm plan -> exit 2 on BOTH calls naming $tok (repeat-block, fail closed)" || bad "#2985 AC-4 $nm (rc1=$rc1 rc2=$rc2 out=$out1)"
done
# two plans named in one prompt (both orders) -> ambiguous, repeat, no marker, no audit row
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
for order in "L S" "S L"; do
  set -- $order
  P=$(mk2985 "g4two$1$2" "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-$1.md\nalso see .ai-workspace/plans/$PLD-$2.md\nimplement")
  g2985 "$P"; rc1=$RC; out1="$CAP"; g2985 "$P"; rc2=$RC
  { [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && printf '%s' "$out1" | grep -qi "ambiguous"; } \
    && ok "#2985 AC-4/M11: prompt naming plan-$1 THEN plan-$2 -> exit 2 on both calls, 'ambiguous'" || bad "#2985 AC-4 two-plan $order (rc1=$rc1 rc2=$rc2 out=$out1)"
done
{ [ "$(nmark)" = "0" ] && rowsok 0; } && ok "#2985 AC-4: the two-plan prompts wrote no marker and no audit row" || bad "#2985 AC-4 two-plan side effects (markers=$(nmark) rows=$(nrows))"
# the same plan cited twice is ONE distinct path -> not ambiguous
P=$(mk2985 g4dup "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md\nsee .ai-workspace/plans/$PLD-L.md again")
g2985 "$P"
{ [ "$RC" = "0" ]; } && ok "#2985 AC-4: one L plan cited twice is one distinct path -> exit 0" || bad "#2985 AC-4 duplicate cite of one plan (rc=$RC out=$CAP)"
# no plan / nonexistent plan -> unresolvable
P=$(mk2985 g4noplan "3ROLE_TASK:777 ROLE:executor\nimplement the plan")
g2985 "$P"; rc1=$RC; out1="$CAP"; g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && printf '%s' "$out1" | grep -qi "unresolvable"; } && ok "#2985 AC-4: executor prompt naming no plan -> exit 2 'unresolvable' (repeat)" || bad "#2985 AC-4 no plan (rc1=$rc1 rc2=$rc2 out=$out1)"
P=$(mk2985 g4ghost "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/x.md")
g2985 "$P"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -qi "unresolvable"; } && ok "#2985 AC-4: nonexistent plan path -> exit 2 'unresolvable'" || bad "#2985 AC-4 ghost plan (rc=$RC out=$CAP)"
# L + inline token -> exit 0 + INLINE_TOKEN audit row (the unchanged escape)
rm -f "$LOG2985"
P=$(mk2985 g4tok "3ROLE_TASK:777 ROLE:executor [route-dispatch-fallback-ok]\nPLAN: .ai-workspace/plans/$PLD-L.md")
g2985 "$P"
{ [ "$RC" = "0" ] && rowsok 1; } && ok "#2985 AC-4: L plan + inline token -> exit 0 with one INLINE_TOKEN audit row (unchanged)" || bad "#2985 AC-4 L + token (rc=$RC rows=$(nrows))"
# task binding (AC-15): a spawn tagged 778 citing the 777-bound L plan
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g15 "3ROLE_TASK:778 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md")
g2985 "$P"; rc1=$RC; out1="$CAP"; g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && [ "$(nmark)" = "0" ] && rowsok 0 && printf '%s' "$out1" | grep -qi "task-mismatch"; } \
  && ok "#2985 AC-15/M12: 3ROLE_TASK:778 citing the 777-bound L plan -> exit 2 (repeat), task-mismatch, no marker, no audit row" || bad "#2985 AC-15 mismatch (rc1=$rc1 rc2=$rc2 markers=$(nmark) out=$out1)"
# executor + operator-private S plan -> the SAME block-once path as a public S plan (#3078 privacy arm)
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g7ex "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-private.md")
g2985 "$P"; rc1=$RC; m1=$(nmark); g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ] && rowsok 0; } && ok "#3078 AC-7: executor + operator-private S plan -> SAME path as public S: exit 2 + marker first, exit 0 second, no audit row" || bad "#3078 AC-7 executor private (rc1=$rc1 m1=$m1 rc2=$rc2 rows=$(nrows) out=$CAP)"
P=$(mk2985 g7bad "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-dcbad.md")
g2985 "$P"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "DATA-CLASS-INVALID"; } && ok "#2985 AC-7: malformed data-class -> exit 2 DATA-CLASS-INVALID" || bad "#2985 AC-7 dcbad (rc=$RC out=$CAP)"

# ---- AC-6 plan-review arms: z.ai first, Opus fallback only after 2 same-round strikes ----
TK="[route-dispatch-fallback-ok]"
pr() { mk2985 "$1" "3ROLE_TASK:777 ROLE:plan-review $2\n$3.ai-workspace/plans/$PLD-S.md under review"; }
R1="$FX2985/receipts-1.md"; R2="$FX2985/receipts-2.md"; RR="$FX2985/receipts-rounds.md"
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(pr g6a "$TK" "ROUND: 1\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R1"; rc1=$RC; out1="$CAP"; g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R1"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && rowsok 0 && [ "$(nmark)" = "0" ] && printf '%s' "$out1" | grep -q "zai-strikes"; } \
  && ok "#2985 AC-6/M5: plan-review + token at strikes=1 -> exit 2 on BOTH calls (repeat-block), no audit row, no marker" || bad "#2985 AC-6 strikes=1 (rc1=$rc1 rc2=$rc2 rows=$(nrows) out=$out1)"
rm -f "$LOG2985"
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R2"
{ [ "$RC" = "0" ] && rowsok 1; } && ok "#2985 AC-6: plan-review + token at strikes=2 (same round) -> exit 0 with one INLINE_TOKEN audit row" || bad "#2985 AC-6 strikes=2 (rc=$RC rows=$(nrows) out=$CAP)"
P=$(pr g6c "" "ROUND: 1\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R2"
{ [ "$RC" = "2" ]; } && ok "#2985 AC-6: strikes=2 WITHOUT the token -> exit 2" || bad "#2985 AC-6 no token (rc=$RC out=$CAP)"
P=$(pr g6d "$TK" "ROUND: 2\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R2"
{ [ "$RC" = "2" ]; } && ok "#2985 AC-6/M13: strikes=2 in round 1 do not carry to ROUND: 2 -> exit 2" || bad "#2985 AC-6 round 2 carry (rc=$RC out=$CAP)"
P=$(pr g6e "$TK" "no round line here\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R2"
{ [ "$RC" = "2" ]; } && ok "#2985 AC-6: prompt with no ROUND: line -> strikes treated as 0 -> exit 2" || bad "#2985 AC-6 no round (rc=$RC out=$CAP)"
P=$(pr g6f "$TK" "round: 1\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$R2"
{ [ "$RC" = "2" ]; } && ok "#2985 AC-6: lowercase 'round: 1' is not a ROUND: line -> exit 2" || bad "#2985 AC-6 lowercase round (rc=$RC out=$CAP)"
P=$(pr g6g "$TK" "ROUND: 1\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$RR"
{ [ "$RC" = "0" ]; } && ok "#2985 AC-6: rounds fixture, ROUND: 1 has 2 strikes -> exit 0 (held-out round split)" || bad "#2985 AC-6 rounds r1 (rc=$RC out=$CAP)"
P=$(pr g6h "$TK" "ROUND: 2\nplan: ")
g2985 "$P" OPENROUTER_DISPATCH_RECEIPT_FILE="$RR"
{ [ "$RC" = "2" ]; } && ok "#2985 AC-6: rounds fixture, ROUND: 2 has 1 strike -> exit 2 (held-out round split)" || bad "#2985 AC-6 rounds r2 (rc=$RC out=$CAP)"
# plan-review below 2 strikes without a token: z.ai first, repeat-block
P=$(pr g6i "" "ROUND: 1\nplan: ")
g2985 "$P"; rc1=$RC; g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "2" ]; } && ok "#2985 AC-6: plan-review with 0 strikes -> exit 2 on both calls (z.ai first, not block-once)" || bad "#2985 AC-6 strikes=0 (rc1=$rc1 rc2=$rc2)"
# key file absent -> structurally unavailable -> token honoured at strikes=0
rm -f "$LOG2985"
P=$(pr g6j "$TK" "ROUND: 1\nplan: ")
g2985 "$P" ZAI_KEY_FILE="$KEY_GONE"
{ [ "$RC" = "0" ] && rowsok 1; } && ok "#2985 AC-6: z.ai key file absent -> route unavailable -> token honoured at strikes=0 (audited)" || bad "#2985 AC-6 key absent (rc=$RC rows=$(nrows) out=$CAP)"
# #3078 plan-review + private plan, strikes=0, no token -> the SAME ZAI-FIRST repeat as public
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g7pr "3ROLE_TASK:777 ROLE:plan-review\nROUND: 1\nplan .ai-workspace/plans/$PLD-private.md under review")
g2985 "$P"; rc1=$RC; g2985 "$P"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$rc2" = "2" ] && [ "$(nmark)" = "0" ] && rowsok 0; } && ok "#3078 AC-7: plan-review citing an operator-private plan, strikes=0, no token -> exit 2 on both calls, no marker (z.ai first, same as public)" || bad "#3078 AC-7 plan-review private (rc1=$rc1 rc2=$rc2 markers=$(nmark) rows=$(nrows) out=$CAP)"
# kill-switch still wins (unchanged)
P=$(pr g6k "" "ROUND: 1\nplan: ")
g2985 "$P" CC_ROUTE_DISPATCH_GATE_OFF=1
{ [ "$RC" = "0" ]; } && ok "#2985: CC_ROUTE_DISPATCH_GATE_OFF=1 still exits 0 on a plan-review spawn" || bad "#2985 kill-switch (rc=$RC)"

# ---- #3060 AC-7: size-L executor on routes WITH size_models -- z.ai first (block-once) until 2 strikes ----
RZ3060="$FX2985/routes-zai-3060.json"
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g3L "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md\nimplement")
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-0.md"; rc1=$RC; m1=$(nmark)
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-0.md"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ] && rowsok 0; } \
  && ok "#3060 AC-7: L plan + 0 strikes (size_models routes) -> exit 2 first call (marker), exit 0 second, no audit row (S/M block-once path)" || bad "#3060 AC-7 L/0 strikes (rc1=$rc1 m1=$m1 rc2=$rc2 rows=$(nrows))"
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g3L2 "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md\nimplement")
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-2.md"
{ [ "$RC" = "0" ] && [ -z "$CAP" ] && [ "$(nmark)" = "0" ] && rowsok 0; } \
  && ok "#3060 AC-7: L plan + 2 strikes -> exit 0 silent, no marker, no audit row (first-class Sonnet fallback)" || bad "#3060 AC-7 L/2 strikes (rc=$RC markers=$(nmark) out=$CAP)"
P=$(mk2985 g3Lr "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-L.md\nimplement")
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-retry.md"; rc1=$RC
{ [ "$rc1" = "2" ]; } && ok "#3060 AC-7: L plan after ONE invocation that retried internally -> still z.ai first (exit 2)" || bad "#3060 AC-7 retry shape (rc=$rc1 out=$CAP)"
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g3priv "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-private.md\nimplement")
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-0.md"; rc1=$RC; m1=$(nmark)
g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-0.md"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ]; } && ok "#3078: operator-private S plan (size_models routes, 0 strikes) -> same block-once as public S (exit 2 + marker, then exit 0)" || bad "#3078 private S block-once (rc1=$rc1 m1=$m1 rc2=$rc2 out=$CAP)"
for nm in none dcbad; do
  P=$(mk2985 "g3$nm" "3ROLE_TASK:777 ROLE:executor\nPLAN: .ai-workspace/plans/$PLD-$nm.md\nimplement")
  g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-2.md"; rc1=$RC; g2985 "$P" CC_ROUTES_JSON="$RZ3060" OPENROUTER_DISPATCH_RECEIPT_FILE="$FX2985/receipts-exec-2.md"; rc2=$RC
  { [ "$rc1" = "2" ] && [ "$rc2" = "2" ]; } && ok "#3060 AC-7: plan '$nm' still fails closed with a repeating block, even at 2 strikes" || bad "#3060 AC-7 $nm (rc1=$rc1 rc2=$rc2)"
done

# ---- #3060 AC-11: research on z.ai -- every Agent-tool research spawn takes the generic block-once path ----
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g11a "3ROLE_TASK:777 ROLE:research\ndata-class: operator-private\nlook up the options")
g2985 "$P" CC_ROUTES_JSON="$RZ3060"; rc1=$RC; m1=$(nmark)
g2985 "$P" CC_ROUTES_JSON="$RZ3060"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ] && rowsok 0; } \
  && ok "#3060 AC-11: ROLE:research WITH data-class: operator-private -> exit 2, marker, exit 0 on re-issue, no audit row (no private exemption)" || bad "#3060 AC-11 private (rc1=$rc1 m1=$m1 rc2=$rc2)"
rm -rf "$ST2985"; mkdir -p "$ST2985"; rm -f "$LOG2985"
P=$(mk2985 g11b "3ROLE_TASK:777 ROLE:research\nlook up the options")
g2985 "$P" CC_ROUTES_JSON="$RZ3060"; rc1=$RC; m1=$(nmark)
g2985 "$P" CC_ROUTES_JSON="$RZ3060"; rc2=$RC
{ [ "$rc1" = "2" ] && [ "$m1" = "1" ] && [ "$rc2" = "0" ] && rowsok 0; } \
  && ok "#3060 AC-11: ROLE:research WITHOUT a data-class line -> the same block-once path" || bad "#3060 AC-11 plain (rc1=$rc1 m1=$m1 rc2=$rc2)"
P=$(mk2985 g11c "3ROLE_TASK:777 ROLE:execution-review\nreview the diff")
g2985 "$P" CC_ROUTES_JSON="$RZ3060"
{ [ "$RC" = "0" ] && [ "$(nmark)" = "1" ]; } && ok "#3060 AC-11 control: ROLE:execution-review -> exit 0, no new marker (seat has no subprocess dispatch)" || bad "#3060 AC-11 control (rc=$RC markers=$(nmark))"
rm -rf "$ST2985"; mkdir -p "$ST2985"
P=$(mk2985 g11d "3ROLE_TASK:777 ROLE:research\nlook up the options")
g2985 "$P" CC_ROUTES_JSON="$RZ2985"
{ [ "$RC" = "0" ] && [ "$(nmark)" = "0" ]; } && ok "#3060 AC-11 rollback: research seat with no dispatch field (HEAD row) -> fail-open, no marker" || bad "#3060 AC-11 rollback (rc=$RC markers=$(nmark))"
fi
[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
