#!/usr/bin/env bash
# Smoke test for the #683 enforce-ship combined-marker-write hint. Exit 0 = all pass.
# Note: enforce-ship calls `gh pr view` for BASE_REF; for the fake PR numbers below that call fails
# gracefully (|| true -> empty BASE_REF) and the hook falls through to the marker check, which is what we test.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/enforce-ship.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.ai-workspace"

# payload <command> <cwd>
payload() { printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2"; }
run() { CAP=$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
HINT="SEPARATE command FIRST"
MARKER=".ai-workspace/ship-verified"   # #767: every block must name the manual-merge marker

# (a) combined marker-write + merge, NO marker present -> block + the combined-write hint
run "$(payload "echo verified > $TMP/.ai-workspace/ship-verified-99001 && gh pr merge 99001 --squash" "$TMP")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "$HINT"; } && ok "combined write+merge, no marker -> block + hint" || bad "combined write should block + hint (rc=$RC out=$CAP)"

# (b) plain merge, no marker -> block; NO combined-write hint, but (NEW #767) DOES name the manual marker
run "$(payload "gh pr merge 99002 --squash" "$TMP")"
{ [ "$RC" = "2" ] && ! echo "$CAP" | grep -q "$HINT"; } && ok "plain merge, no marker -> block, no combined-write hint" || bad "plain merge should block without the combined-write hint (rc=$RC out=$CAP)"

# (b2) #767 AC: triggering the block (plain merge, no marker) prints a line naming the marker escape
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "$MARKER-99002"; } && ok "plain merge block names .ai-workspace/ship-verified-<PR> (#767)" || bad "plain merge block must name the manual marker (rc=$RC out=$CAP)"

# (c) marker present -> allow (no regression to the allow path)
touch "$TMP/.ai-workspace/ship-verified-99003"
run "$(payload "gh pr merge 99003 --squash" "$TMP")"
[ "$RC" = "0" ] && ok "marker present -> allow (exit 0)" || bad "present marker should allow (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
