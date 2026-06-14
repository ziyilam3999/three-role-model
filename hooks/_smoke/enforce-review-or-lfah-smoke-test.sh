#!/bin/bash
# Smoke test for enforce-review-or-lfah.sh (#749).
# Self-contained: builds throwaway repo dirs, feeds JSON payloads, asserts exit codes.
set -u
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
HOOK="$ROOT/hooks/enforce-review-or-lfah.sh"
PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

run() { # name expected_rc payload
  local name="$1" exp="$2" payload="$3"
  local rc
  echo "$payload" | bash "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); echo "ok   - $name (rc=$rc)"
  else FAIL=$((FAIL+1)); echo "FAIL - $name (got rc=$rc, want $exp)"; fi
}

# 1. Non-merge command -> allow (exit 0).
run "non-merge command allowed" 0 \
  "{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"$TMPROOT\"}"

# 2. Merge with NO review/lfah artifact -> block (exit 2). (gh fails in a non-repo dir ->
#    base-ref + release carve-outs fall through to the artifact check.)
REPO_BARE="$TMPROOT/bare"; mkdir -p "$REPO_BARE"
run "merge with no artifact blocked" 2 \
  "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_BARE\"}"

# 3. Merge WITH a passing stateless-review artifact -> allow.
REPO_REV="$TMPROOT/reviewed"; mkdir -p "$REPO_REV/tmp"
printf '## Review Iteration 1\n### Verdict\n- Decision: PASS\n' > "$REPO_REV/tmp/ship-review-1.md"
run "merge with ship-review PASS allowed" 0 \
  "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_REV\"}"

# 3b. A BLOCK-verdict review artifact must NOT satisfy the gate -> still blocked.
REPO_REVB="$TMPROOT/reviewed-block"; mkdir -p "$REPO_REVB/tmp"
printf '## Review Iteration 1\n### Verdict\n- Decision: BLOCK\n' > "$REPO_REVB/tmp/ship-review-1.md"
run "merge with ship-review BLOCK still blocked" 2 \
  "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_REVB\"}"

# 4. Merge WITH an lfah BUILD-SUMMARY.json -> allow.
REPO_LFAH="$TMPROOT/lfah"; mkdir -p "$REPO_LFAH/out"
printf '{"verdict":"SHIP"}' > "$REPO_LFAH/out/BUILD-SUMMARY.json"
run "merge with lfah BUILD-SUMMARY allowed" 0 \
  "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_LFAH\"}"

# 5. Kill-switch -> allow even with no artifact (would otherwise block like test 2).
ENFORCE_REVIEW_OR_LFAH_DISABLE=1 bash "$HOOK" >/dev/null 2>&1 <<< "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_BARE\"}"; KILLRC=$?
if [ "$KILLRC" = "0" ]; then PASS=$((PASS+1)); echo "ok   - kill-switch allows (rc=0)"; else FAIL=$((FAIL+1)); echo "FAIL - kill-switch (got rc=$KILLRC, want 0)"; fi

# 6. cd-prefixed merge resolves the TARGET repo (not cwd) for the artifact check.
run "cd-prefixed merge into reviewed repo allowed" 0 \
  "{\"tool_input\":{\"command\":\"cd $REPO_REV && gh pr merge 9 --squash\"},\"cwd\":\"$TMPROOT\"}"

# ── Regression cases for the #749 ship-review (B1 + B2). Each MUST block (rc=2). ──────────────
# B1: the idiomatic no-PR-number form. The inner grep finds no number; the script must NOT die
# (no `set -e`) and must fall through to the artifact gate, which blocks. (REPO_BARE has no artifact.)
run "B1: no-PR-number merge (gh pr merge --squash) blocked" 2 \
  "{\"tool_input\":{\"command\":\"gh pr merge --squash\"},\"cwd\":\"$REPO_BARE\"}"

# B2a: `;`-chained merge must not be dismissed as a grep false-positive.
run "B2: ;-chained merge blocked" 2 \
  "{\"tool_input\":{\"command\":\"echo hi; gh pr merge 9 --squash\"},\"cwd\":\"$REPO_BARE\"}"

# B2b: leading whitespace must not defeat the start-of-string anchor.
run "B2: leading-whitespace merge blocked" 2 \
  "{\"tool_input\":{\"command\":\"  gh pr merge 9 --squash\"},\"cwd\":\"$REPO_BARE\"}"

# E1: an UNPARSEABLE payload whose raw text still contains `gh pr merge` must fail CLOSED. The
# pre-filter matches the raw text, JSON.parse throws -> COMMAND is empty -> the gate must block (2),
# not fall through to the confirm-regex allow. (Review iteration-2 E1 — fail-open hardening.)
run "E1: unparseable payload containing 'gh pr merge' fails closed" 2 \
  "{ this is not valid json but mentions gh pr merge 9 somewhere"

# E2: a review artifact whose verdict is BLOCK but mentions the word PASS on the same line must NOT
# satisfy the gate. (Review iteration-2 E2 — anchored PASS detection.)
REPO_REVTRAP="$TMPROOT/reviewed-trap"; mkdir -p "$REPO_REVTRAP/tmp"
printf '## Review\n- Decision: BLOCK (downgraded from a prior PASS)\n' > "$REPO_REVTRAP/tmp/ship-review-1.md"
run "E2: 'BLOCK ... PASS' same-line does not satisfy the gate" 2 \
  "{\"tool_input\":{\"command\":\"gh pr merge 9 --squash\"},\"cwd\":\"$REPO_REVTRAP\"}"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
