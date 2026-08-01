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
  && printf '%s' "$REAL" | command grep -q "scanned ${WF_COUNT} workflow file(s)" \
  && printf '%s' "$REAL" | command grep -q "(${WF_COUNT} examined,"; } \
  && ok "case-7 (real repo): scanned AND examined all $WF_COUNT workflow file(s), finding no unannotated push-only steps" \
  || bad "case-7 failed — either the real repo carries the #2205 shape, or the checker did not examine the $WF_COUNT workflow file(s) that are actually there (rc=$RC7 independent_count=$WF_COUNT):
$REAL"
#    The `examined` half is NOT redundant with `scanned` (#2205 review round 2, blocker 3). `scanned`
#    increments when a file is OPENED, BEFORE the not-pull_request-triggered `continue`, so a file the
#    checker opened and immediately skipped still counts toward it. Asserting only on `scanned` proved
#    the directory was read, never that anything was checked -- and a trigger the detector fails to
#    recognise skips the file silently. Demonstrated: reordering `jobs:` above `on:` in a workflow
#    carrying the verbatim #2205 defect held `scanned 1` while examining nothing. Case 15 below is the
#    red arm for that specific evasion; this line is the general oracle.

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

# ── Case 13 — RED-ARM for the round-2 reopening of case 9. Case 9 proved the annotation no longer
#    leaks DOWN-to-UP when the comment is flush against its step. It had no power over the shape
#    below, which differs by exactly ONE BLANK LINE: the annotation sits above the blank, the step
#    below it. The walk-up used to stop at the first non-comment line, so the blank line orphaned the
#    comment into the PREVIOUS step's body — the annotation exempted the gate above it and the
#    genuinely-annotated `publish` got flagged instead. Both errors at once, in opposite directions.
#    NOTE: this is the arrangement that actually reproduces. The round-2 review described the blank as
#    sitting between the first step's body and the comment; that placement was always handled
#    correctly, and a fixture built to it would be green on the unfixed code (verified before fixing).
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
      - name: unannotated REAL GATE
        if: github.event_name == 'push'
        run: echo gate
      # push-only-ok: publishes the release tag, which only exists after the merge lands

      - name: publish
        if: github.event_name == 'push'
        run: echo publish
YML
OUT13=$(run_checker); RC13=$?
{ [ "$RC13" != "0" ] \
  && printf '%s' "$OUT13" | command grep -q 'FAIL.*unannotated REAL GATE' \
  && printf '%s' "$OUT13" | command grep -q 'allow .*"publish"'; } \
  && ok "case-13 (RED-ARM): a blank line between an annotation and its step no longer swaps which step the exemption lands on" \
  || bad "case-13 failed — the blank-line preamble leak is back (rc=$RC13 out=$OUT13)"

# ── Case 14 — FALSE-POSITIVE control, and the most important control in this file. Both steps below
#    are PR-ONLY — the standard fork guard and the standard draft guard — i.e. the exact OPPOSITE of
#    the #2205 defect. A `\b` after `github.event.pull_request` is satisfied by the following `.`, so
#    the round-1 checker matched inside `...head.repo.fork` and flagged both. The only escape it
#    offered was a `# push-only-ok:` annotation, which would have required the author to write a
#    false statement to get past the lint. A guard satisfiable only by lying teaches people to
#    disable it, so this arm is load-bearing, not politeness.
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
      - name: skip forks
        if: ${{ !github.event.pull_request.head.repo.fork }}
        run: echo hi
      - name: skip drafts
        if: ${{ !github.event.pull_request.draft }}
        run: echo hi
YML
OUT14=$(run_checker); RC14=$?
{ [ "$RC14" = "0" ] && printf '%s' "$OUT14" | command grep -q '0 push-only step(s) found'; } \
  && ok "case-14 (control): fork/draft guards are PR-ONLY steps and are not mistaken for push-only ones" \
  || bad "case-14 failed — false positive on a PR-only fork/draft guard (rc=$RC14 out=$OUT14)"

# ── Case 15 — RED-ARM for the worst failure this checker can have: skipping a whole file while
#    exiting 0. YAML mappings are UNORDERED and GitHub accepts `jobs:` before `on:`. The trigger scan
#    used to slice lines[0..indexOf('jobs:')], so this ordering left an EMPTY head region, found no
#    pull_request trigger, and skipped the file — carrying the verbatim #2205 defect, silently, green.
#    Asserting on `examined` is what gives this case teeth: `scanned` was 1 either way.
cat > "$FIX/.github/workflows/fixture.yml" <<'YML'
name: fixture
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: unannotated REAL GATE
        if: github.event_name == 'push'
        run: echo gate
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
YML
OUT15=$(run_checker); RC15=$?
{ [ "$RC15" != "0" ] \
  && printf '%s' "$OUT15" | command grep -q 'unannotated REAL GATE' \
  && printf '%s' "$OUT15" | command grep -q '(1 examined,'; } \
  && ok "case-15 (RED-ARM): 'jobs:' written above 'on:' no longer makes the whole workflow invisible" \
  || bad "case-15 failed — key order skipped the file (rc=$RC15 out=$OUT15)"

# ── Case 16 — the FOURTH spelling, and per the round-2 review the commonest one in the wild. It names
#    neither the event nor the PR object: it pins the ref to the default branch. On a pull_request
#    event `github.ref` is `refs/pull/<n>/merge`, never `refs/heads/<branch>`, so this is
#    push-to-that-branch-only in effect. Paired with its control on the next case.
write_wf "$BOTH" "" "github.ref == 'refs/heads/master'"
OUT16=$(run_checker); RC16=$?
{ [ "$RC16" != "0" ] && printf '%s' "$OUT16" | command grep -q 'the suspect step'; } \
  && ok "case-16: a default-branch ref pin is caught — the spelling that names neither the event nor the PR object" \
  || bad "case-16 failed — github.ref spelling evaded the checker (rc=$RC16 out=$OUT16)"

# ── Case 17 — CONTROL for case 16. Same ref pin, but the condition also admits pull_request, so it is
#    not push-only. Without this, case 16 could be green because the checker flags any mention of
#    github.ref.
write_wf "$BOTH" "" "github.ref == 'refs/heads/master' || github.event_name == 'pull_request'"
OUT17=$(run_checker); RC17=$?
[ "$RC17" = "0" ] \
  && ok "case-17 (control): a ref pin that ALSO admits pull_request is not push-only" \
  || bad "case-17 failed — false positive on a both-events ref condition (rc=$RC17 out=$OUT17)"

# ── Case 18 — the counter's OWN oracle. Cases 7 and 15 both lean on `examined`, but neither can tell
#    `examined` apart from a second name for `scanned`: in both, every file present IS examined. This
#    is the only arm where the two numbers must DIFFER. A push-only workflow is opened and then
#    skipped, so the honest report is 1 scanned / 0 examined / 1 skipped. Without this case, a
#    regression that incremented `examined` before the skip would leave the whole suite green while
#    destroying the very distinction the counter exists to make (#2205 review round 2, blocker 3).
write_wf "$PUSH_ONLY_WF" "" "github.event_name == 'push'"
OUT18=$(run_checker); RC18=$?
{ [ "$RC18" = "0" ] && printf '%s' "$OUT18" | command grep -q 'scanned 1 workflow file(s) (0 examined, 1 skipped'; } \
  && ok "case-18 (counter oracle): a skipped workflow counts as scanned-but-NOT-examined — the two numbers are not synonyms" \
  || bad "case-18 failed — 'examined' does not distinguish a skipped file from a checked one (rc=$RC18 out=$OUT18)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
