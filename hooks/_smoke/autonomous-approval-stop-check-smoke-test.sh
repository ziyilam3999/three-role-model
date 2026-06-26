#!/usr/bin/env bash
# Smoke for autonomous-approval-stop-check.sh (Stop hook). Portability + fire smoke (AC11).
# Asserts the hook NO-OPs cleanly on benign / bypassed input, and FIRES (exit 2 + BLOCKED) on each of the
# THREE positive OR-disjuncts of its fire condition ((PROCEED or NOW_OR_LATER) and has_q) or LMK — one
# positive fixture PER DISJUNCT (feedback_or_gate_fire_condition_needs_per_disjunct_positive_fixture, #1179).
# NO `set -e` — a non-block non-zero must not fail-open into a spurious pass; every exit code is captured
# explicitly and tallied. Exit 0 = N/N PASS. The hook is invoked with CLAUDE_PLUGIN_ROOT set (CI provides it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/autonomous-approval-stop-check.sh"

fail=0; pass=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# run <json-payload> ['']  -> sets RC + CAP (combined stdout+stderr). Empty arg = empty stdin.
run() {
  CAP=$(printf '%s' "$1" | bash "$HOOK" 2>&1); RC=$?
}
# build a payload {"last_assistant_message": "<msg>"} with optional extra kv ($2 raw JSON snippet)
mk() {
  if [ -n "${2:-}" ]; then
    node -e 'process.stdout.write(JSON.stringify(Object.assign({last_assistant_message:process.argv[1]},JSON.parse(process.argv[2]))))' "$1" "$2"
  else
    node -e 'process.stdout.write(JSON.stringify({last_assistant_message:process.argv[1]}))' "$1"
  fi
}

# ---- portability: empty stdin -> exit 0, no stderr block ----
CAP=$(printf '' | bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! printf '%s' "$CAP" | grep -q "BLOCKED"; } \
  && ok "empty stdin -> exit 0, no block" || bad "empty stdin expected exit0/no-block (rc=$RC out=$CAP)"

# ---- portability: malformed JSON -> exit 0 ----
CAP=$(printf 'not json {{{' | bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ]; } && ok "malformed JSON -> exit 0" || bad "malformed JSON expected exit0 (rc=$RC out=$CAP)"

# ---- benign final message -> exit 0, no BLOCKED ----
run "$(mk 'All done — tests pass.')"
{ [ "$RC" = "0" ] && ! printf '%s' "$CAP" | grep -q "BLOCKED"; } \
  && ok "benign message -> exit 0, no block" || bad "benign expected exit0/no-block (rc=$RC out=$CAP)"

# ---- bypass token present (genuine operator decision) -> exit 0 even though it asks ----
run "$(mk 'Should I ship X now, or later? (operator decision required)')"
{ [ "$RC" = "0" ]; } && ok "bypass token -> exit 0" || bad "bypass expected exit0 (rc=$RC out=$CAP)"

# ---- FIRE D1: PROCEED + '?' -> exit 2 + BLOCKED on stderr ----
run "$(mk 'Should I ship #1258 now?')"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "BLOCKED"; } \
  && ok "D1 PROCEED+? -> exit 2 + BLOCKED" || bad "D1 expected exit2+BLOCKED (rc=$RC out=$CAP)"

# ---- FIRE D2: NOW_OR_LATER offer (no PROCEED lead-in, no LMK) -> exit 2 (the canonical #623 'now, or later?'
#      shape PROCEED does NOT match) ----
run "$(mk 'Roll out #1258 now, or hold it until later?')"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "BLOCKED"; } \
  && ok "D2 NOW_OR_LATER -> exit 2 + BLOCKED" || bad "D2 expected exit2+BLOCKED (rc=$RC out=$CAP)"

# ---- FIRE D3: LMK message (no '?') -> exit 2 ----
run "$(mk 'Let me know if you want me to continue.')"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "BLOCKED"; } \
  && ok "D3 LMK -> exit 2 + BLOCKED" || bad "D3 expected exit2+BLOCKED (rc=$RC out=$CAP)"

# ---- loop guard: same fire message with stop_hook_active:true -> exit 0 (block once) ----
run "$(mk 'Should I ship #1258 now?' '{"stop_hook_active":true}')"
{ [ "$RC" = "0" ]; } && ok "loop guard stop_hook_active -> exit 0" || bad "loop guard expected exit0 (rc=$RC out=$CAP)"

echo "----"
if [ "$fail" = "0" ]; then echo "$pass/$pass PASS"; exit 0; else echo "$pass passed, $fail FAILED"; exit 1; fi
