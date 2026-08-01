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
#
#    rc=0 ALONE IS NOT ENOUGH (#2205 review, blocker B4). The checker returns 0 both when it read
#    every workflow and cleared them AND when it read NOTHING -- `workflowFiles()` swallows a
#    readdir failure and returns [] (:46 "no workflows yet -> clean"), so a moved/renamed
#    .github/workflows, a wrong ROOT, or a permissions problem all produce a silent, confident
#    green. Case 8 proves the checker CAN report zero, but it runs against the FIXTURE tree, so it
#    says nothing about whether THIS run touched the real repo.
#    So case 7 carries its own oracle: an INDEPENDENTLY computed count of the real repo's workflow
#    files (same extension filter as :47, via find rather than the checker's own readdir) must equal
#    the count the checker reports, and must be >= 1. Now a green here can only mean "read N files
#    and cleared them", never "read nothing".
REAL=$(cd "$REPO_ROOT" && node scripts/check-push-only-gates.mjs 2>&1); RC7=$?
# /usr/bin/find, not bare `find`: the interactive shell aliases find to bfs, which does not
# accept every GNU-ism and can fail silently -- producing a 0 count and a vacuous pass.
WF_COUNT=$(/usr/bin/find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | command wc -l | command tr -d ' ')
{ [ "$RC7" = "0" ] \
  && [ "${WF_COUNT:-0}" -ge 1 ] \
  && printf '%s' "$REAL" | command grep -q "scanned ${WF_COUNT} workflow file(s)"; } \
  && ok "case-7 (real repo): scanned all $WF_COUNT workflow file(s) and found no unannotated push-only steps" \
  || bad "case-7 failed — either the real repo carries the #2205 shape, or the checker did not read the $WF_COUNT workflow file(s) that are actually there (rc=$RC7 independent_count=$WF_COUNT):
$REAL"

# ── Case 8 — DELETE-THE-INPUT ORACLE. Remove every workflow and the checker must report scanning
#    ZERO files. Without this, case 7's green is unfalsifiable: a checker that silently found no
#    files would look exactly the same as one that found files and cleared them.
rm -f "$FIX/.github/workflows/fixture.yml"
OUT8=$(run_checker); RC8=$?
{ [ "$RC8" = "0" ] && printf '%s' "$OUT8" | command grep -q 'scanned 0 workflow'; } \
  && ok "case-8 (delete-the-input oracle): with no workflows the checker reports scanning 0 — so a green above means files were actually read" \
  || bad "case-8 failed (rc=$RC8 out=$OUT8)"

# ── Case 9 — RED-ARM for the #1590 monotonicity defect in stepsOf(). Two steps: the FIRST is a real
#    gate with NO annotation of its own, the SECOND carries a valid `push-only-ok:`. Before the fix,
#    step 1's body ran to step 2's START LINE, so step 2's comment sat inside BOTH steps and
#    annotationReason() let step 2's justification exempt step 1 — a weaker claim erasing a stronger
#    gate. The checker must flag step 1 BY NAME and still allow step 2.
cat > "$FIX/.github/workflows/fixture.yml" <<'YML'
name: fixture
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: unannotated gate
        if: github.event_name == 'push'
        run: echo gate
      # push-only-ok: publishes the release tag, which only exists after the merge lands
      - name: annotated publish
        if: github.event_name == 'push'
        run: echo publish
YML
OUT9=$(run_checker); RC9=$?
{ [ "$RC9" != "0" ] \
  && printf '%s' "$OUT9" | command grep -q 'unannotated gate' \
  && printf '%s' "$OUT9" | command grep -q 'allow .*annotated publish'; } \
  && ok "case-9 (RED-ARM, #1590 monotonicity): the NEXT step's annotation no longer exempts the preceding unannotated gate" \
  || bad "case-9 failed — step 2's push-only-ok leaked onto step 1 (rc=$RC9 out=$OUT9)"

# ── Case 10 — trigger FALSE-NEGATIVE guard: block-SEQUENCE `on:`. A missed trigger skips the WHOLE
#    file, so this is the most expensive way for the checker to be wrong while still exiting 0.
cat > "$FIX/.github/workflows/fixture.yml" <<'YML'
name: fixture
on:
  - push
  - pull_request
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: sequence-form suspect
        if: github.event_name == 'push'
        run: echo hi
YML
OUT10=$(run_checker); RC10=$?
{ [ "$RC10" != "0" ] && printf '%s' "$OUT10" | command grep -q 'sequence-form suspect'; } \
  && ok "case-10: block-sequence 'on:' is recognised as pull_request-reachable — the file is not silently skipped" \
  || bad "case-10 failed — block-sequence on: skipped the whole workflow (rc=$RC10 out=$OUT10)"

# ── Case 11 — the third spelling of push-only: a null pull_request CONTEXT OBJECT, which never
#    mentions github.event_name at all. Paired with its control on the next case.
write_wf "$(printf 'on:\n  push:\n    branches: [master]\n  pull_request:\n    branches: [master]')" "" "github.event.pull_request == null"
OUT11=$(run_checker); RC11=$?
{ [ "$RC11" != "0" ] && printf '%s' "$OUT11" | command grep -q 'the suspect step'; } \
  && ok "case-11: 'github.event.pull_request == null' is caught — the event_name-free spelling of the same defect" \
  || bad "case-11 failed — null-PR-context spelling evaded the checker (rc=$RC11 out=$OUT11)"

# ── Case 12 — CONTROL for case 11. Same context object, but a condition that also admits PRs must
#    NOT be flagged. Without this, case 11 could be passing because the checker flags everything.
write_wf "$(printf 'on:\n  push:\n    branches: [master]\n  pull_request:\n    branches: [master]')" "" "github.event.pull_request == null || github.event_name == 'pull_request'"
OUT12=$(run_checker); RC12=$?
[ "$RC12" = "0" ] \
  && ok "case-12 (control): a null-PR-context condition that ALSO admits pull_request is not push-only" \
  || bad "case-12 failed — false positive on a both-events context condition (rc=$RC12 out=$OUT12)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
