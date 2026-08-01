#!/usr/bin/env bash
# hooks/_smoke/check-push-only-gates-smoke-test.sh — #2205 prevention, red-armed.
#
# WHY THIS FILE EXISTS. scripts/check-push-only-gates.mjs is a guard, and an unexercised guard is
# indistinguishable from a guard that silently stopped working. Its whole value is DISCRIMINATION —
# red on the #2205 shape, green on the legitimate look-alikes — so every case below is paired with a
# control that inverts exactly one thing. A green run here is evidence; the checker returning 0 on the
# real repo is not, on its own, evidence of anything (case 8 is why).
#
# The fixture seam is PUSH_ONLY_GATE_ROOT, an explicit env override the checker reads. The real
# repository is never mutated; case 7 is the only arm that touches it, and it is read-only.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-push-only-gates.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP — node not available; #2205 push-only-gate cases not run"
  exit 0
fi
[ -f "$CHECKER" ] || { echo "FAIL: checker not found at $CHECKER"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixture"
mkdir -p "$FIX/.github/workflows"

run_checker() { PUSH_ONLY_GATE_ROOT="$FIX" node "$CHECKER" 2>&1; }

# $1 = the `on:` block, $2 = optional comment line above the step, $3 = the step's `if:` value
write_wf() {
  { printf 'name: fixture\n'
    printf '%s\n' "$1"
    printf 'jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - uses: actions/checkout@v4\n'
    [ -n "$2" ] && printf '      %s\n' "$2"
    printf '      - name: the suspect step\n'
    printf '        if: %s\n' "$3"
    printf '        run: echo hi\n'
  } > "$FIX/.github/workflows/fixture.yml"
}

BOTH=$'on:\n  push:\n    branches: [master]\n  pull_request:\n    branches: [master]'
PUSH_ONLY_WF=$'on:\n  push:\n    branches: [master]'

# ── Case 1 — THE RED-ARM. The exact #2205 shape: workflow reachable pre-merge, step opts out.
write_wf "$BOTH" "" "github.event_name == 'push'"
OUT1=$(run_checker); RC1=$?
{ [ "$RC1" != "0" ] && printf '%s' "$OUT1" | command grep -q 'the suspect step' \
    && printf '%s' "$OUT1" | command grep -q 'CANNOT'; } \
  && ok "case-1 (RED-ARM): an unannotated push-only step in a pull_request-reachable workflow is flagged by name" \
  || bad "case-1 failed — the #2205 shape was NOT flagged (rc=$RC1 out=$OUT1)"

# ── Case 2 — POWER CONTROL for case 1. Identical file, one annotation added. Proves case-1's red
#    comes from the missing annotation and not from the fixture being malformed.
write_wf "$BOTH" "# push-only-ok: publishes the release tag, which only exists after the merge" "github.event_name == 'push'"
OUT2=$(run_checker); RC2=$?
{ [ "$RC2" = "0" ] && printf '%s' "$OUT2" | command grep -q 'push-only-ok: publishes the release tag'; } \
  && ok "case-2 (power control): the SAME step with a stated reason passes, and the reason is echoed" \
  || bad "case-2 failed — annotation did not clear the flag (rc=$RC2 out=$OUT2)"

# ── Case 3 — the annotation must be a REASON, not a rubber stamp. A token that merely matches the
#    pattern must not buy an exemption, or the escape hatch becomes the new default.
write_wf "$BOTH" "# push-only-ok: ok" "github.event_name == 'push'"
OUT3=$(run_checker); RC3=$?
{ [ "$RC3" != "0" ] && printf '%s' "$OUT3" | command grep -q 'too short to be a reason'; } \
  && ok "case-3: a sub-threshold annotation is rejected — the escape hatch cannot be rubber-stamped" \
  || bad "case-3 failed (rc=$RC3 out=$OUT3)"

# ── Case 4 — SCOPE control. A workflow with no pull_request trigger has no pre-merge reachability to
#    opt out of, so its push-only steps are not this defect. Flagging them would be pure noise.
write_wf "$PUSH_ONLY_WF" "" "github.event_name == 'push'"
OUT4=$(run_checker); RC4=$?
{ [ "$RC4" = "0" ] && printf '%s' "$OUT4" | command grep -q 'does not trigger on pull_request'; } \
  && ok "case-4 (scope control): a push-only WORKFLOW is out of scope by construction, and says so" \
  || bad "case-4 failed — false positive on a push-only workflow (rc=$RC4 out=$OUT4)"

# ── Case 5 — the same defect wearing a different hat. `!= 'pull_request'` excludes exactly the event
#    that matters; a checker that only knew the `== 'push'` spelling would be trivially evaded.
write_wf "$BOTH" "" "github.event_name != 'pull_request'"
OUT5=$(run_checker); RC5=$?
{ [ "$RC5" != "0" ] && printf '%s' "$OUT5" | command grep -q 'the suspect step'; } \
  && ok "case-5: the negative spelling (!= 'pull_request') is caught too — not just == 'push'" \
  || bad "case-5 failed — negative spelling evaded the checker (rc=$RC5 out=$OUT5)"

# ── Case 6 — CONTROL for case 5. An `if:` that admits BOTH events is not push-only and must pass,
#    even though it mentions github.event_name and 'push'.
write_wf "$BOTH" "" "github.event_name == 'push' || github.event_name == 'pull_request'"
OUT6=$(run_checker); RC6=$?
[ "$RC6" = "0" ] \
  && ok "case-6 (control): an if: that admits BOTH events is not push-only and passes" \
  || bad "case-6 failed — false positive on a both-events condition (rc=$RC6 out=$OUT6)"

# ── Case 7 — the REAL repo, read-only. This is the arm that would have caught #2205 before it merged,
#    and the arm that goes red the day someone reintroduces the shape.
REAL=$(cd "$REPO_ROOT" && node scripts/check-push-only-gates.mjs 2>&1); RC7=$?
[ "$RC7" = "0" ] \
  && ok "case-7 (real repo): this repository has no unannotated push-only steps" \
  || bad "case-7 failed — the real repo carries the #2205 shape (rc=$RC7):
$REAL"

# ── Case 8 — DELETE-THE-INPUT ORACLE. Remove every workflow and the checker must report scanning
#    ZERO files. Without this, case 7's green is unfalsifiable: a checker that silently found no
#    files would look exactly the same as one that found files and cleared them.
rm -f "$FIX/.github/workflows/fixture.yml"
OUT8=$(run_checker); RC8=$?
{ [ "$RC8" = "0" ] && printf '%s' "$OUT8" | command grep -q 'scanned 0 workflow'; } \
  && ok "case-8 (delete-the-input oracle): with no workflows the checker reports scanning 0 — so a green above means files were actually read" \
  || bad "case-8 failed (rc=$RC8 out=$OUT8)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
