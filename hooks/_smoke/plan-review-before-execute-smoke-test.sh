#!/usr/bin/env bash
# plan-review-before-execute-smoke-test.sh — self-contained smoke for plan-review-before-execute.sh (#781).
#
# Uses an overridable STATE_DIR + PLANS_DIR (mktemp) so it never pollutes real ~/.claude or repo state.
# The reminder MARKER on stderr fires on every TRIGGERED edit; the EXIT CODE makes it visible to the
# model. Default mode is "block-once": the first triggered edit in a batch exits 2, then the batch is
# "notified" and subsequent edits exit 0. ALLOW = exit 0 with NO marker (trivial / carve-out / escape /
# active plan carries a review marker).
#
# Covers:
#   (a) non-trivial edit + plan WITHOUT marker -> block once (exit 2) then allow (exit 0);
#   (b) plan WITH a `## Review` section -> allow; (b2) plan WITH a `plan-review:` trailer -> allow;
#       (b3) plan WITH a `reviewed:` trailer -> allow;
#   (c) trivial (1 file / <50 lines) -> allow; (c2) carve-out path -> allow;
#   (d) PLAN_REVIEW_OK / PLAN_REVIEW_OFF / SHIP_PIPELINE escape -> allow;
#   (e) Agent/Task + git-commit/gh-merge reset re-arms; (f) no plan at all -> still fires;
#   (g) malformed/empty JSON -> fail open. Prints "PASS=N FAIL=M"; exits non-zero if any FAIL.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HERE/../.." && pwd)}"
HOOK="$ROOT/hooks/plan-review-before-execute.sh"
MARKER="PLAN-REVIEW-BEFORE-EXECUTE"

PASS=0
FAIL=0

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t planrev)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fresh_dir() {
  local d
  d="$(mktemp -d "$TMP_ROOT/s.XXXXXX")"
  printf '%s' "$d"
}

# make a plans dir with one plan file; $2 = body content (may be empty / no marker)
make_plans_dir() {
  local body="$1"
  local pd
  pd="$(mktemp -d "$TMP_ROOT/plans.XXXXXX")"
  printf '%s\n' "$body" > "$pd/2026-06-09-781-some-plan.md"
  printf '%s' "$pd"
}

# run_hook <state_dir> <plans_dir> <json> [extra env assignments...] -> sets RC + OUT(stderr)
run_hook() {
  local sd="$1"; shift
  local pd="$1"; shift
  local json="$1"; shift
  OUT="$(printf '%s' "$json" | env "$@" PLAN_REVIEW_STATE_DIR="$sd" PLAN_REVIEW_PLANS_DIR="$pd" \
        PLAN_REVIEW_OFF="" PLAN_REVIEW_OK="" SHIP_PIPELINE="" \
        bash "$HOOK" 2>&1 1>/dev/null)"
  RC=$?
}

edit_json() {
  local sid="$1" file="$2" newstr="$3"
  python3 - "$sid" "$file" "$newstr" <<'PY'
import json,sys
sid,file,newstr=sys.argv[1],sys.argv[2],sys.argv[3]
print(json.dumps({"session_id":sid,"tool_name":"Edit","tool_input":{"file_path":file,"old_string":"x","new_string":newstr}}))
PY
}

nlines_str() {
  python3 - "$1" <<'PY'
import sys
n=int(sys.argv[1])
print("\n".join("line%d"%i for i in range(n)), end="")
PY
}

assert_nudge() {
  local label="$1"
  if printf '%s' "$OUT" | grep -q "$MARKER"; then
    PASS=$((PASS+1)); echo "PASS: $label (nudge fired)"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label (expected nudge, none)"
  fi
}
assert_allow() {
  local label="$1"
  if printf '%s' "$OUT" | grep -q "$MARKER"; then
    FAIL=$((FAIL+1)); echo "FAIL: $label (expected allow, got nudge)"
  else
    PASS=$((PASS+1)); echo "PASS: $label (allowed)"
  fi
}
assert_rc0() {
  local label="$1"
  if [ "$RC" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS: $label (exit 0)"
  else FAIL=$((FAIL+1)); echo "FAIL: $label (exit $RC, want 0)"; fi
}
assert_rc2() {
  local label="$1"
  if [ "$RC" -eq 2 ]; then PASS=$((PASS+1)); echo "PASS: $label (exit 2)"
  else FAIL=$((FAIL+1)); echo "FAIL: $label (exit $RC, want 2)"; fi
}
assert_out_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$OUT" | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "PASS: $label (found '$needle')"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label (missing '$needle')"
  fi
}

ONE="$(nlines_str 1)"
BIG="$(nlines_str 60)"   # 60-line edit -> > 50 threshold in a single file

NO_MARKER_PLAN="$(make_plans_dir "# Plan 781

## ELI5
do a thing

### Binary AC
- exit code 0")"
REVIEW_SECTION_PLAN="$(make_plans_dir "# Plan 781

## ELI5
do a thing

## Review
P1-P4 verdict: GO. Coherent, AC checkable.")"
TRAILER_PLAN="$(make_plans_dir "# Plan 781

## ELI5
do a thing

plan-review: P1-P4 GO 2026-06-09")"
REVIEWED_TRAILER_PLAN="$(make_plans_dir "# Plan 781

## ELI5
do a thing

reviewed: yes (auto-flow Stage 1)")"

# (a) non-trivial edit (3 files) + plan WITHOUT marker -> block ONCE then allow
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sA src/one.py "$ONE")";   assert_allow "(a) file 1 of 3"; assert_rc0 "(a) file 1 rc0"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sA src/two.py "$ONE")";   assert_allow "(a) file 2 of 3"; assert_rc0 "(a) file 2 rc0"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sA src/three.py "$ONE")"; assert_nudge "(a) file 3 triggers (unreviewed plan)"; assert_rc2 "(a) file 3 BLOCKS ONCE (exit 2)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sA src/four.py "$ONE")";  assert_rc0 "(a) file 4 ALLOWS (already notified this batch)"; assert_nudge "(a) file 4 still carries reminder"
assert_out_contains "(a) message names /per-task-review-loop" "/per-task-review-loop"
assert_out_contains "(a) message names /auto-flow Stage 1"    "/auto-flow Stage 1"
assert_out_contains "(a) message names /delegate default"     "/delegate"
assert_out_contains "(a) message bakes when-inline criteria (tightly coupled)" "tightly coupled"

# (a-lines) non-trivial by LINES (60-line single file) + unreviewed plan -> block once
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sAl src/big.py "$BIG")"
assert_nudge "(a-lines) 60-line single-file edit triggers on lines"; assert_rc2 "(a-lines) blocks once (exit 2)"

# (b) plan WITH a `## Review` section -> allow even at 3 files
SD="$(fresh_dir)"
run_hook "$SD" "$REVIEW_SECTION_PLAN" "$(edit_json sB src/one.py "$ONE")"
run_hook "$SD" "$REVIEW_SECTION_PLAN" "$(edit_json sB src/two.py "$ONE")"
run_hook "$SD" "$REVIEW_SECTION_PLAN" "$(edit_json sB src/three.py "$ONE")"
assert_allow "(b) reviewed plan (## Review section) -> allow"; assert_rc0 "(b) reviewed plan rc0"

# (b2) plan WITH a `plan-review:` trailer -> allow
SD="$(fresh_dir)"
run_hook "$SD" "$TRAILER_PLAN" "$(edit_json sB2 src/one.py "$ONE")"
run_hook "$SD" "$TRAILER_PLAN" "$(edit_json sB2 src/two.py "$ONE")"
run_hook "$SD" "$TRAILER_PLAN" "$(edit_json sB2 src/three.py "$ONE")"
assert_allow "(b2) plan-review: trailer -> allow"; assert_rc0 "(b2) plan-review: trailer rc0"

# (b3) plan WITH a `reviewed:` trailer -> allow
SD="$(fresh_dir)"
run_hook "$SD" "$REVIEWED_TRAILER_PLAN" "$(edit_json sB3 src/one.py "$ONE")"
run_hook "$SD" "$REVIEWED_TRAILER_PLAN" "$(edit_json sB3 src/two.py "$ONE")"
run_hook "$SD" "$REVIEWED_TRAILER_PLAN" "$(edit_json sB3 src/three.py "$ONE")"
assert_allow "(b3) reviewed: trailer -> allow"; assert_rc0 "(b3) reviewed: trailer rc0"

# (c) trivial: 1 file -> allow (even with unreviewed plan)
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC src/solo.py "$ONE")"
assert_allow "(c) single file trivial -> allow"; assert_rc0 "(c) single file rc0"

# (c2) carve-out paths never count -> allow even past 3, unreviewed plan
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC2 memory/notes.txt "$BIG")";             assert_allow "(c2) memory/ carve-out"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC2 .ai-workspace/x.txt "$BIG")";           assert_allow "(c2) .ai-workspace carve-out"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC2 project/plans/p1.txt "$BIG")";          assert_allow "(c2) plans/ carve-out"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC2 card.md "$BIG")";                       assert_allow "(c2) .md card carve-out"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sC2 .claude/settings.json "$BIG")";         assert_allow "(c2) .claude carve-out"

# (d) escape envs honored -> allow even at 3 files with unreviewed plan
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sD src/c.py "$ONE")" | env PLAN_REVIEW_STATE_DIR="$SD" PLAN_REVIEW_PLANS_DIR="$NO_MARKER_PLAN" PLAN_REVIEW_OK=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(d) PLAN_REVIEW_OK=1 suppresses"; assert_rc0 "(d) PLAN_REVIEW_OK rc0"
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD2 src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD2 src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sD2 src/c.py "$ONE")" | env PLAN_REVIEW_STATE_DIR="$SD" PLAN_REVIEW_PLANS_DIR="$NO_MARKER_PLAN" PLAN_REVIEW_OFF=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(d2) PLAN_REVIEW_OFF=1 suppresses"; assert_rc0 "(d2) PLAN_REVIEW_OFF rc0"
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD3 src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sD3 src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sD3 src/c.py "$ONE")" | env PLAN_REVIEW_STATE_DIR="$SD" PLAN_REVIEW_PLANS_DIR="$NO_MARKER_PLAN" SHIP_PIPELINE=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(d3) SHIP_PIPELINE=1 suppresses"; assert_rc0 "(d3) SHIP_PIPELINE rc0"

# (e) Agent/Task dispatch RESETS -> re-arms block-once
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/b.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/c.py "$ONE")"; assert_rc2 "(e) batch1 3rd file blocks once"
run_hook "$SD" "$NO_MARKER_PLAN" '{"session_id":"sE","tool_name":"Task","tool_input":{"description":"go"}}'; assert_allow "(e) Task dispatch allows + resets"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/d.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/e.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE src/f.py "$ONE")"; assert_rc2 "(e) post-reset re-arms block-once (exit 2)"

# (e2) git commit RESETS
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/b.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/c.py "$ONE")"; assert_rc2 "(e2) batch blocks once"
run_hook "$SD" "$NO_MARKER_PLAN" '{"session_id":"sE2","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'; assert_allow "(e2) git commit allows + resets"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/d.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/e.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE2 src/f.py "$ONE")"; assert_rc2 "(e2) post git-commit re-arms (exit 2)"

# (e3) gh pr merge RESETS
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE3 src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE3 src/b.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" '{"session_id":"sE3","tool_name":"Bash","tool_input":{"command":"gh pr merge 12 --squash"}}'; assert_allow "(e3) gh pr merge resets"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE3 src/c.py "$ONE")"
assert_allow "(e3) post gh-merge reset, file 1 of new batch"

# (e4) unrelated bash does NOT reset
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE4 src/a.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE4 src/b.py "$ONE")"
run_hook "$SD" "$NO_MARKER_PLAN" '{"session_id":"sE4","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sE4 src/c.py "$ONE")"
assert_nudge "(e4) unrelated bash does NOT reset (3rd file still triggers)"; assert_rc2 "(e4) still blocks (exit 2)"

# (f) NO plan at all (empty plans dir) -> still fires (can't prove it was reviewed)
EMPTY_PLANS="$(mktemp -d "$TMP_ROOT/emptyplans.XXXXXX")"
SD="$(fresh_dir)"
run_hook "$SD" "$EMPTY_PLANS" "$(edit_json sF src/a.py "$ONE")"
run_hook "$SD" "$EMPTY_PLANS" "$(edit_json sF src/b.py "$ONE")"
run_hook "$SD" "$EMPTY_PLANS" "$(edit_json sF src/c.py "$ONE")"
assert_nudge "(f) no plan present -> still fires"; assert_rc2 "(f) no plan blocks once (exit 2)"
assert_out_contains "(f) message notes no plan found" "no .ai-workspace/plans"

# (f2) newest-plan selection: an OLDER reviewed plan + a NEWER unreviewed plan -> fires
#      (the active = most-recently-modified plan governs).
MIXED_PLANS="$(mktemp -d "$TMP_ROOT/mixedplans.XXXXXX")"
printf '# old\n## Review\nGO\n' > "$MIXED_PLANS/2026-06-01-old.md"
sleep 1
printf '# new\n## ELI5\nbuild it\n' > "$MIXED_PLANS/2026-06-09-new.md"
SD="$(fresh_dir)"
run_hook "$SD" "$MIXED_PLANS" "$(edit_json sF2 src/a.py "$ONE")"
run_hook "$SD" "$MIXED_PLANS" "$(edit_json sF2 src/b.py "$ONE")"
run_hook "$SD" "$MIXED_PLANS" "$(edit_json sF2 src/c.py "$ONE")"
assert_nudge "(f2) newest (unreviewed) plan governs over older reviewed plan -> fires"; assert_rc2 "(f2) fires exit 2"
# and the reverse: newest reviewed plan governs over older unreviewed -> allow
MIXED2="$(mktemp -d "$TMP_ROOT/mixed2.XXXXXX")"
printf '# old\n## ELI5\nx\n' > "$MIXED2/2026-06-01-old.md"
sleep 1
printf '# new\n## Review\nGO\n' > "$MIXED2/2026-06-09-new.md"
SD="$(fresh_dir)"
run_hook "$SD" "$MIXED2" "$(edit_json sF2b src/a.py "$ONE")"
run_hook "$SD" "$MIXED2" "$(edit_json sF2b src/b.py "$ONE")"
run_hook "$SD" "$MIXED2" "$(edit_json sF2b src/c.py "$ONE")"
assert_allow "(f2b) newest (reviewed) plan governs -> allow"

# (g) malformed / empty JSON -> fail open
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" 'this is not json {{{'
assert_allow "(g) malformed JSON fails open (no nudge)"; assert_rc0 "(g) malformed JSON exit 0"
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" ''
assert_allow "(g2) empty stdin fails open"; assert_rc0 "(g2) empty stdin exit 0"

# (h) mode variants
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH src/a.py "$ONE")" PLAN_REVIEW_MODE=block; assert_rc0 "(h) block-mode file 1 allows"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH src/b.py "$ONE")" PLAN_REVIEW_MODE=block; assert_rc0 "(h) block-mode file 2 allows"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH src/c.py "$ONE")" PLAN_REVIEW_MODE=block; assert_nudge "(h) block-mode 3rd file emits reminder"; assert_rc2 "(h) block-mode 3rd file BLOCKS (exit 2)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH src/d.py "$ONE")" PLAN_REVIEW_MODE=block; assert_rc2 "(h) block-mode KEEPS blocking (exit 2, not block-once)"
SD="$(fresh_dir)"
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH2 src/a.py "$ONE")" PLAN_REVIEW_MODE=banana
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH2 src/b.py "$ONE")" PLAN_REVIEW_MODE=banana
run_hook "$SD" "$NO_MARKER_PLAN" "$(edit_json sH2 src/c.py "$ONE")" PLAN_REVIEW_MODE=banana; assert_rc0 "(h) unknown mode falls back to nudge (exit 0)"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
