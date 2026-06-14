#!/usr/bin/env bash
# inline-delegate-nudge-smoke-test.sh — self-contained smoke for inline-delegate-nudge.sh (#755).
#
# Uses an overridable STATE_DIR (mktemp) so it never pollutes real ~/.claude state.
# The reminder MARKER on stderr fires on every TRIGGERED edit regardless of mode; the EXIT
# CODE is what makes it visible to the model. Default mode is now "block-once" (#769): the
# first triggered edit in a batch exits 2 (visible block), then the batch is "notified" and
# subsequent edits exit 0. ALLOW = exit 0 with NO marker (under threshold / carve-out / escape).
#
# Covers: (a) 1 file -> allow; (b) 3 distinct files -> trigger; (c) >50 lines in fewer files
# -> trigger; (d) carve-out paths never count; (e) Agent/Task resets; (f) git-commit/gh-merge
# resets; (g) INLINE_DELEGATE_OK / INLINE_DELEGATE_OFF -> allow; (h) SHIP_PIPELINE=1 -> allow;
# (i) malformed JSON -> fail open. Prints "PASS=N FAIL=M"; exits non-zero if any FAIL.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HERE/../.." && pwd)}"
HOOK="$ROOT/hooks/inline-delegate-nudge.sh"
MARKER="INLINE-DELEGATE NUDGE"

PASS=0
FAIL=0

TMP_STATE="$(mktemp -d 2>/dev/null || mktemp -d -t inldel)"
trap 'rm -rf "$TMP_STATE"' EXIT

# fresh state dir per logical scenario so independent cases do not bleed
fresh_dir() {
  local d
  d="$(mktemp -d "$TMP_STATE/s.XXXXXX")"
  printf '%s' "$d"
}

# run_hook <state_dir> <json>  [extra env assignments...] -> sets RC + OUT(stderr)
run_hook() {
  local sd="$1"; shift
  local json="$1"; shift
  OUT="$(printf '%s' "$json" | env "$@" INLINE_DELEGATE_STATE_DIR="$sd" \
        INLINE_DELEGATE_OFF="" INLINE_DELEGATE_OK="" SHIP_PIPELINE="" \
        bash "$HOOK" 2>&1 1>/dev/null)"
  RC=$?
}

# convenience: build an Edit JSON for a given file + new_string
edit_json() {
  local sid="$1" file="$2" newstr="$3"
  python3 - "$sid" "$file" "$newstr" <<'PY'
import json,sys
sid,file,newstr=sys.argv[1],sys.argv[2],sys.argv[3]
print(json.dumps({"session_id":sid,"tool_name":"Edit","tool_input":{"file_path":file,"old_string":"x","new_string":newstr}}))
PY
}

# build a new_string with N lines
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
# assert the captured stderr (OUT) contains a given substring
assert_out_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$OUT" | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "PASS: $label (found '$needle')"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label (missing '$needle')"
  fi
}
# assert that the FIRST occurrence of $before in OUT comes strictly before the
# first occurrence of $after (line-order assertion, not just presence).
assert_out_order() {
  local label="$1" before="$2" after="$3"
  local lb la
  lb="$(printf '%s\n' "$OUT" | grep -nF "$before" | head -1 | cut -d: -f1)"
  la="$(printf '%s\n' "$OUT" | grep -nF "$after"  | head -1 | cut -d: -f1)"
  if [ -n "$lb" ] && [ -n "$la" ] && [ "$lb" -lt "$la" ]; then
    PASS=$((PASS+1)); echo "PASS: $label ('$before' @L$lb before '$after' @L$la)"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $label (expected '$before' before '$after'; got L${lb:-?}/L${la:-?})"
  fi
}

ONE="$(nlines_str 1)"
BIG="$(nlines_str 60)"   # 60-line edit -> > 50 threshold in a single file

# (a) 1 task-work file edit -> allow
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sA src/foo.py "$ONE")"
assert_allow "(a) single task-work file"
assert_rc0  "(a) single task-work file rc"

# (b) reach 3 distinct task-work files -> trigger
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sB src/one.py "$ONE")";   assert_allow "(b) file 1 of 3"
run_hook "$SD" "$(edit_json sB src/two.py "$ONE")";   assert_allow "(b) file 2 of 3"
run_hook "$SD" "$(edit_json sB src/three.py "$ONE")"; assert_nudge "(b) file 3 of 3 triggers"; assert_rc2 "(b) file 3 of 3 blocks once (exit 2)"

# (b2) same file edited 3 times stays 1 distinct file -> allow (distinctness check)
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sB2 src/same.py "$ONE")"
run_hook "$SD" "$(edit_json sB2 src/same.py "$ONE")"
run_hook "$SD" "$(edit_json sB2 src/same.py "$ONE")"
assert_allow "(b2) same file x3 stays 1 distinct"

# (c) >50 lines in fewer than 3 files -> trigger
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sC src/big.py "$BIG")"
assert_nudge "(c) 60-line single-file edit triggers on lines"; assert_rc2 "(c) 60-line edit blocks once (exit 2)"

# (d) carve-out paths never count (stay allow even past 3)
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sD memory/notes.txt "$BIG")";              assert_allow "(d) memory/ carve-out"
run_hook "$SD" "$(edit_json sD .ai-workspace/PROJECT-INDEX.txt "$BIG")"; assert_allow "(d) .ai-workspace carve-out"
run_hook "$SD" "$(edit_json sD project/plans/p1.txt "$BIG")";          assert_allow "(d) plans/ carve-out"
run_hook "$SD" "$(edit_json sD tmp/scratch.txt "$BIG")";               assert_allow "(d) tmp/ carve-out"
run_hook "$SD" "$(edit_json sD agent-working-memory/x.txt "$BIG")";    assert_allow "(d) agent-working-memory carve-out"
run_hook "$SD" "$(edit_json sD card-session.md "$BIG")";              assert_allow "(d) .md session card carve-out"
run_hook "$SD" "$(edit_json sD .claude/settings.json "$BIG")";        assert_allow "(d) .claude carve-out"
# absolute-path carve-out
run_hook "$SD" "$(edit_json sD /Users/x/repo/memory/MEMORY.md "$BIG")"; assert_allow "(d) absolute MEMORY.md carve-out"

# (e) Agent/Task dispatch RESETS -> back to allow
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sE src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sE src/b.py "$ONE")"
# dispatch Task -> reset
run_hook "$SD" '{"session_id":"sE","tool_name":"Task","tool_input":{"description":"go"}}'
assert_allow "(e) Task dispatch itself allows"
run_hook "$SD" "$(edit_json sE src/c.py "$ONE")"
assert_allow "(e) post-reset file 1 of 3 (counter was cleared)"

# (e2) Agent dispatch also resets
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sE2 src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sE2 src/b.py "$ONE")"
run_hook "$SD" '{"session_id":"sE2","tool_name":"Agent","tool_input":{"prompt":"go"}}'
run_hook "$SD" "$(edit_json sE2 src/c.py "$ONE")"
assert_allow "(e2) Agent dispatch resets too"

# (f) git commit / gh pr merge Bash RESETS
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sF src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sF src/b.py "$ONE")"
run_hook "$SD" '{"session_id":"sF","tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
assert_allow "(f) git commit bash allows"
run_hook "$SD" "$(edit_json sF src/c.py "$ONE")"
assert_allow "(f) post git-commit reset, file 1 of 3"

SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sF2 src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sF2 src/b.py "$ONE")"
run_hook "$SD" '{"session_id":"sF2","tool_name":"Bash","tool_input":{"command":"gh pr merge 12 --squash"}}'
run_hook "$SD" "$(edit_json sF2 src/c.py "$ONE")"
assert_allow "(f2) gh pr merge resets too"

# (f3) an UNRELATED bash command does NOT reset (ls)
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sF3 src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sF3 src/b.py "$ONE")"
run_hook "$SD" '{"session_id":"sF3","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
run_hook "$SD" "$(edit_json sF3 src/c.py "$ONE")"
assert_nudge "(f3) unrelated bash does NOT reset (3rd file still triggers)"

# (g) INLINE_DELEGATE_OK=1 and INLINE_DELEGATE_OFF=1 -> allow even at 3 files
SD="$(fresh_dir)"
# prime to 2 then 3rd with OK set
run_hook "$SD" "$(edit_json sG src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sG src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sG src/c.py "$ONE")" | env INLINE_DELEGATE_STATE_DIR="$SD" INLINE_DELEGATE_OK=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(g) INLINE_DELEGATE_OK=1 suppresses"
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sG2 src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sG2 src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sG2 src/c.py "$ONE")" | env INLINE_DELEGATE_STATE_DIR="$SD" INLINE_DELEGATE_OFF=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(g2) INLINE_DELEGATE_OFF=1 suppresses"

# (h) SHIP_PIPELINE=1 -> allow
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sH src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sH src/b.py "$ONE")"
OUT="$(printf '%s' "$(edit_json sH src/c.py "$ONE")" | env INLINE_DELEGATE_STATE_DIR="$SD" SHIP_PIPELINE=1 bash "$HOOK" 2>&1 1>/dev/null)"; RC=$?
assert_allow "(h) SHIP_PIPELINE=1 suppresses"

# (i) malformed JSON -> fail open (allow, exit 0)
SD="$(fresh_dir)"
run_hook "$SD" 'this is not json {{{'
assert_allow "(i) malformed JSON fails open (no nudge)"
assert_rc0  "(i) malformed JSON exit 0"

# (i2) empty stdin -> fail open
SD="$(fresh_dir)"
run_hook "$SD" ''
assert_allow "(i2) empty stdin fails open"
assert_rc0  "(i2) empty stdin exit 0"

# (j) INLINE_DELEGATE_MODE=block -> the trigger HARD-BLOCKS (exit 2); default stays nudge/exit 0
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sJ src/a.py "$ONE")" INLINE_DELEGATE_MODE=block; assert_rc0 "(j) block-mode file 1 allows (exit 0)"
run_hook "$SD" "$(edit_json sJ src/b.py "$ONE")" INLINE_DELEGATE_MODE=block; assert_rc0 "(j) block-mode file 2 allows (exit 0)"
run_hook "$SD" "$(edit_json sJ src/c.py "$ONE")" INLINE_DELEGATE_MODE=block; assert_nudge "(j) block-mode 3rd file still emits the reminder"; assert_rc2 "(j) block-mode 3rd file BLOCKS (exit 2)"
# DEFAULT mode is now block-once (#769): the 3rd file emits the reminder AND blocks once (exit 2)
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sK src/a.py "$ONE")"; assert_rc0 "(j) default-mode file 1 allows (exit 0)"
run_hook "$SD" "$(edit_json sK src/b.py "$ONE")"; assert_rc0 "(j) default-mode file 2 allows (exit 0)"
run_hook "$SD" "$(edit_json sK src/c.py "$ONE")"; assert_nudge "(j) default-mode 3rd file emits reminder"; assert_rc2 "(j) default-mode 3rd file BLOCKS ONCE (exit 2)"
# an unrecognised mode value is treated as nudge (exit 0)
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sL src/a.py "$ONE")" INLINE_DELEGATE_MODE=banana
run_hook "$SD" "$(edit_json sL src/b.py "$ONE")" INLINE_DELEGATE_MODE=banana
run_hook "$SD" "$(edit_json sL src/c.py "$ONE")" INLINE_DELEGATE_MODE=banana; assert_rc0 "(j) unknown mode falls back to nudge (exit 0)"

# (m) the nudge message names ALL THREE escape paths (#760): lfah, /delegate, /per-task-review-loop
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sM src/a.py "$ONE")"
run_hook "$SD" "$(edit_json sM src/b.py "$ONE")"
run_hook "$SD" "$(edit_json sM src/c.py "$ONE")"
assert_nudge        "(m) nudge fires on 3rd file"
assert_out_contains "(m) nudge names TESTABLE-CODE path lfah"                  "lfah"
assert_out_contains "(m) nudge names HANDOFF path /delegate"                   "/delegate"
assert_out_contains "(m) nudge names INLINE+REVIEW path /per-task-review-loop" "/per-task-review-loop"

# (m2) #776: /delegate is the PRIORITIZED default path — the message must list /delegate
#      BEFORE lfah AND BEFORE /per-task-review-loop (order, not just presence).
assert_out_order "(m2) /delegate listed before lfah"                  "/delegate" "lfah"
assert_out_order "(m2) /delegate listed before /per-task-review-loop" "/delegate" "/per-task-review-loop"

# (n) #769 block-once contract: 1st trigger BLOCKS (exit 2, visible), then the SAME batch
#     ALLOWS subsequent edits (exit 0) — guarantees one visible interruption without walling.
SD="$(fresh_dir)"
run_hook "$SD" "$(edit_json sN src/a.py "$ONE")"; assert_rc0 "(n) block-once file 1 allows"
run_hook "$SD" "$(edit_json sN src/b.py "$ONE")"; assert_rc0 "(n) block-once file 2 allows"
run_hook "$SD" "$(edit_json sN src/c.py "$ONE")"; assert_rc2 "(n) block-once 3rd file BLOCKS (exit 2, visible)"
run_hook "$SD" "$(edit_json sN src/d.py "$ONE")"; assert_rc0 "(n) block-once 4th file ALLOWS (already notified this batch)"
assert_nudge "(n) 4th file still carries the reminder marker"
# after a reset, the batch is fresh -> the next trigger BLOCKS ONCE again
run_hook "$SD" '{"session_id":"sN","tool_name":"Task","tool_input":{"description":"go"}}'
run_hook "$SD" "$(edit_json sN src/e.py "$ONE")"; assert_rc0 "(n) post-reset file 1 allows"
run_hook "$SD" "$(edit_json sN src/f.py "$ONE")"; assert_rc0 "(n) post-reset file 2 allows"
run_hook "$SD" "$(edit_json sN src/g.py "$ONE")"; assert_rc2 "(n) post-reset re-arms block-once (exit 2)"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
