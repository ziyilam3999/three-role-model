#!/bin/bash
# Hook: enforce an INDEPENDENT review (or an lfah build) before merging to master (#749).
#
# WHY (the gap this closes): enforce-ship.sh already blocks a master-bound `gh pr merge`
# unless a `.ai-workspace/ship-verified-<PR>` marker exists — but that marker is just a
# hand-writable file. Nothing proves an independent review ACTUALLY ran: you can
# `echo verified > .ai-workspace/ship-verified-<PR>` and merge with zero review. That is
# exactly the hole "one-shotting" falls through (build it yourself, eyeball it, write the
# marker, merge). This hook requires PROOF that the work was independently checked:
#   - a stateless-review artifact `tmp/ship-review-*.md` whose verdict is PASS  (the /ship
#     Stage-5 per-task review loop wrote it), OR
#   - an lfah `*BUILD-SUMMARY*.json` somewhere in the repo  (lfah built it test-first against
#     a real oracle — that IS the independent check).
# Either one is enough. With neither, the merge is one-shot and gets blocked.
#
# Both-ends-boolean (Rule 17 / feedback_mechanical_hook_both_ends_verifiable): the
# recurrence-condition (master-bound merge with no review/lfah artifact) and the fix-landed
# signal (such an artifact exists) are both objective file checks.
#
# Carve-outs mirror enforce-ship so this never false-blocks a legitimate flow:
#   - non-master/main base (integration-branch model) -> exempt.
#   - release PRs (title `^chore: release` or body `release-pr: true`) -> exempt: /ship
#     Stage 5 deliberately skips review for the mechanical version bump.
# Kill-switches: ENFORCE_REVIEW_OR_LFAH_DISABLE=1, or SHIP_PIPELINE=1 (inside /ship itself).
#
# NOTE: deliberately NO `set -e`. A gate must deterministically reach `exit 0` (allow) or `exit 2`
# (block) — it must never die mid-logic on a transient non-zero (e.g. a grep that finds nothing).
# PreToolUse only BLOCKS on exit 2; any other non-zero is a non-blocking error, so a `set -e` death
# would FAIL OPEN and let an unreviewed merge through. (Was B1 in the #749 ship-review.)

INPUT=$(cat)

# Kill-switches.
[ "${ENFORCE_REVIEW_OR_LFAH_DISABLE:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# Fast path: only `gh pr merge` matters. Broad pre-filter (may false-positive, never false-negative).
if ! echo "$INPUT" | grep -qE 'gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge'; then
  exit 0
fi

# Parse command, cwd, and a leading `cd <target> &&` prefix (the target repo) from the JSON
# payload. Kept simple: a single leading cd is the common shape; deeper chains fall back to cwd.
PARSED=$(echo "$INPUT" | node -e "
let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(d);
    const cmd=j.tool_input?.command||'';
    const cwd=j.cwd||'';
    let target='';
    const m=cmd.match(/^\s*cd\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s&;]+))\s*&&/);
    if(m){ let seg=m[1]||m[2]||m[3]||'';
      if(seg==='~') seg=process.env.HOME||seg;
      else if(seg.startsWith('~/')) seg=(process.env.HOME||'~')+'/'+seg.slice(2);
      target=seg;
    }
    console.log(cmd.replace(/\r?\n/g,' '));
    console.log(cwd);
    console.log(target);
  } catch { console.log(''); console.log(''); console.log(''); }
})")

COMMAND=""; CWD=""; TARGET_CWD=""
{ IFS= read -r COMMAND || true; IFS= read -r CWD || true; IFS= read -r TARGET_CWD || true; } <<< "$PARSED"

# Fail CLOSED if the parser produced no usable command. The pre-filter already proved the raw
# payload contains `gh pr merge`, so an empty COMMAND means we CANNOT rule out a real master merge
# (malformed JSON -> the node `catch` prints empty lines; or `node` missing from PATH -> empty
# PARSED). "Can't tell what this is" must BLOCK, not allow — anything else fails open, contradicting
# this hook's whole contract. (Review iteration-2 E1.)
if [ -z "$COMMAND" ]; then
  echo "BLOCKED (enforce-review-or-lfah): the raw payload contained 'gh pr merge' but could not be parsed (malformed JSON or node unavailable). Failing CLOSED so an unparseable merge can't slip the gate. Kill-switch: ENFORCE_REVIEW_OR_LFAH_DISABLE=1 (or SHIP_PIPELINE=1 inside /ship)." >&2
  exit 2
fi

# Confirm a real `gh pr merge` invocation, not a grep false positive from body text. Accept any
# common shell boundary before the command: start-of-string, whitespace, or a `; & | (` separator,
# then optional whitespace. (Was B2 in the #749 ship-review: the old `(^|&&...)` form let
# `;`-chained and leading-whitespace merges slip the gate.)
if ! echo "$COMMAND" | grep -qE '(^|[[:space:];&|(])[[:space:]]*gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge'; then
  exit 0
fi

REPO="${TARGET_CWD:-$CWD}"
[ -n "$REPO" ] || REPO="$CWD"

# Extract the PR number from the command, else resolve from the current branch. The `|| true`
# keeps a no-match grep from surfacing a non-zero status (defensive even without `set -e`).
PR_NUMBER=$(echo "$COMMAND" | grep -oE 'gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge[[:space:]][[:space:]]*[0-9]+' | grep -oE '[0-9]+' || true)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(cd "$REPO" 2>/dev/null && gh pr view --json number -q .number 2>/dev/null || true)
fi

# Integration-branch carve-out: non-master/main base is exempt (same as enforce-ship). Graceful
# degradation: if gh fails (auth/network) BASE_REF is empty and we fall through to the artifact check.
if [ -n "$PR_NUMBER" ]; then
  BASE_REF=$(cd "$REPO" 2>/dev/null && gh pr view "$PR_NUMBER" --json baseRefName -q .baseRefName 2>/dev/null || true)
  if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "master" ] && [ "$BASE_REF" != "main" ]; then
    exit 0
  fi
  # Release-PR carve-out: /ship Stage 5 skips review for the mechanical version bump.
  PR_META=$(cd "$REPO" 2>/dev/null && gh pr view "$PR_NUMBER" --json title,body -q '.title + "\n" + .body' 2>/dev/null || true)
  if printf '%s' "$PR_META" | grep -qiE '^chore: release [0-9]|release-pr:[[:space:]]*true'; then
    exit 0
  fi
fi

# ── The gate: require a real review OR an lfah build artifact in the repo. ───────────────────
# (1) A stateless-review artifact with a PASS verdict (the /ship Stage-5 per-task review loop).
REVIEW_OK=0
if ls "$REPO"/tmp/ship-review-*.md >/dev/null 2>&1; then
  # Anchor PASS immediately after the `Decision:` label. The looser `Decision:.*\bPASS\b` alt
  # would match `Decision: BLOCK (downgraded from a prior PASS)` and false-ALLOW. (Review E2.)
  if grep -liE 'Decision:[[:space:]]*PASS\b' "$REPO"/tmp/ship-review-*.md >/dev/null 2>&1; then
    REVIEW_OK=1
  fi
fi
# (2) An lfah BUILD-SUMMARY.json anywhere in the repo (bounded depth; lfah test-first IS the check).
LFAH_OK=0
if [ -d "$REPO" ] && find "$REPO" -maxdepth 4 -name '*BUILD-SUMMARY*.json' -print -quit 2>/dev/null | grep -q .; then
  LFAH_OK=1
fi

if [ "$REVIEW_OK" = "1" ] || [ "$LFAH_OK" = "1" ]; then
  exit 0
fi

{
  echo "BLOCKED (enforce-review-or-lfah): merging PR #${PR_NUMBER:-?} to master with NO proof of an independent review or an lfah build."
  echo "The ship-verified marker alone is hand-writable — it does not prove a review happened. Don't one-shot:"
  echo "  • run the per-task review loop (/ship spawns a stateless reviewer -> writes tmp/ship-review-N.md PASS), OR"
  echo "  • build it via lfah (leaves a *BUILD-SUMMARY*.json)."
  echo "Then re-run the merge. Kill-switch: ENFORCE_REVIEW_OR_LFAH_DISABLE=1 (or SHIP_PIPELINE=1 inside /ship)."
} >&2
exit 2
