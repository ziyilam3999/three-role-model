#!/usr/bin/env bash
# plan-review-before-execute.sh — PreToolUse hook (#781).
#
# PORT-NOTE: cites `parent-claude.md` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md (Leg 4).
#   Comment only — safe forward-ref.
# WHY: the unifying workflow doctrine (#779, parent-claude.md) is plan → review-plan →
# execute → review-execute. The "review-execute" leg has mechanical gates (per-task-review-loop,
# /delegate review, stateless reviewers). The "execute" leg has a mechanical "are you one-shotting
# delegate-sized work inline?" gate (inline-delegate-nudge.sh, #755). But the "review-PLAN before
# you execute" leg had NO mechanical gate — nothing stops the agent from skipping straight from a
# freshly-written plan to building it, with the plan never vetted. This hook is that missing leg:
# it watches edit-tool calls and, once an inline batch crosses the same "non-trivial"/"delegate-sized"
# threshold inline-delegate-nudge uses, checks whether the ACTIVE plan (most-recently-modified
# .ai-workspace/plans/*.md) carries a REVIEW MARKER. If non-trivial code is being built AND the
# active plan was never reviewed, it BLOCKS ONCE so the agent stops and vets the plan first.
#
# This is the SIBLING of inline-delegate-nudge.sh — same SENSOR (the accumulation + threshold +
# carve-out logic is reused verbatim), same block-once RESPONSE shape, same reset signals. The only
# differences: (1) the TRIGGER also requires "active plan has no review marker" (no marker absent /
# no plan -> still fires the reminder; a marked plan -> ALLOW), and (2) the MESSAGE points at the
# plan-review escape paths and bakes in the when-inline-vs-delegate criteria.
#
# REVIEW MARKER: the active plan carries a review verdict if it has EITHER
#   - a `## Review` section header (the kind /per-task-review-loop plan-chain or /auto-flow Stage 1
#     append after running the P1->P2->P3->P4 reviewer chain), OR
#   - a trailer line matching `plan-review:` or `reviewed:` (a lightweight one-line attestation).
# Absence of BOTH on the active plan == "plan never vetted" -> the gate fires.
#
# RESPONSE DECISION: BLOCK-ONCE per batch (mirrors inline-delegate-nudge's proven #769 shape). WHY:
#   - A pure NUDGE (exit 0 + stderr) is INVISIBLE to the model — a PreToolUse hook's stderr is only
#     fed to the agent on exit 2; on exit 0 it reaches the user transcript only (see
#     feedback_exit0_stderr_hook_nudge_invisible_to_model). Invisible == not a guard.
#   - A PERMANENT block walls legitimate multi-file inline work (this hook fires on the MAIN AGENT'S
#     edit path constantly; the "plan reviewed?" check is a heuristic over a best-guess active plan).
#   - BLOCK-ONCE is the balance: exit 2 the FIRST time the trigger crosses in a batch (so the agent
#     SEES the reminder and consciously vets the plan or notes why it's trivial), then mark the batch
#     "notified" and fall through to exit 0 for the rest — visible, never a permanent wall.
#
# BOTH-ENDS-BOOLEAN (Rule 17 / feedback_mechanical_hook_both_ends_verifiable): the TRIGGER is an
# objective boolean over session + filesystem state — (distinct non-carve-out files since reset >= N)
# OR (cumulative est. changed-lines since reset > L), AND (the most-recently-modified
# .ai-workspace/plans/*.md does NOT contain a review marker). Both the accumulate side and the reset
# side are objective events; the marker check is a grep over a known file. Only the RESPONSE is a
# block-once nudge (because "is THIS edit really plan-needing task work" stays judgment we refuse to
# false-block on permanently).
#
# RESET on: PreToolUse Agent|Task (delegation/review happened) OR a Bash `git commit` / `gh pr merge`
# (the inline batch shipped) OR SHIP_PIPELINE=1.
# CARVE-OUTS (never count toward the trigger): memory/, .ai-workspace/, agent-working-memory/,
# */plans/*, MEMORY.md, tmp/, .claude/, and *.md session cards — IDENTICAL to inline-delegate-nudge.
# Plus full exemption when SHIP_PIPELINE=1 or PLAN_REVIEW_OK=1, kill-switch PLAN_REVIEW_OFF=1.
#
# NO set -e (a gate must deterministically reach its exit; a mid-logic non-zero must not change
# behavior). Fail-open on ANY parse/read error -> exit 0, never blocks normal work.

set -u

# Kill-switch + escape hatches (full exemption, no state mutation needed).
[ "${PLAN_REVIEW_OFF:-}" = "1" ] && exit 0
[ "${PLAN_REVIEW_OK:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# Thresholds (env-configurable, MIRROR inline-delegate-nudge defaults exactly).
PLAN_REVIEW_FILES="${PLAN_REVIEW_FILES:-3}"   # distinct task-work files >= this -> trigger
PLAN_REVIEW_LINES="${PLAN_REVIEW_LINES:-50}"  # cumulative changed-lines > this -> trigger
STATE_DIR="${PLAN_REVIEW_STATE_DIR:-$HOME/.claude/.plan-review-state}"
PLAN_REVIEW_TTL_DAYS="${PLAN_REVIEW_TTL_DAYS:-14}"
# The plans dir to scan for the active plan; overridable for tests.
PLANS_DIR="${PLAN_REVIEW_PLANS_DIR:-.ai-workspace/plans}"
# Response mode — same THREE values as inline-delegate-nudge:
#   "block-once" (DEFAULT): exit 2 the FIRST time the trigger crosses in a batch (reaches the model),
#     then mark "notified" and allow the rest — one visible interruption, no permanent wall.
#   "block": exit 2 on EVERY triggered edit until you review the plan or set PLAN_REVIEW_OK=1.
#   "nudge": legacy exit-0 + stderr (INVISIBLE to the model — back-compat only).
# Any unrecognised value is treated as "nudge" (safe, non-blocking). The escape hatches
# (PLAN_REVIEW_OK=1 / _OFF=1 / SHIP_PIPELINE=1) bypass ALL modes.
PLAN_REVIEW_MODE="${PLAN_REVIEW_MODE:-block-once}"

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# --- parse session_id + tool_name + file_path + an added-lines estimate -----
# Identical extraction to inline-delegate-nudge: one field per line; line estimate counts newlines
# in content (Write) or new_string (Edit); MultiEdit sums new_string across edits[]; NotebookEdit
# uses notebook_path + new_source. Bash carries its command body LAST.
META="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
def nlines(s):
    if not s: return 0
    return s.count(chr(10)) + (1 if s else 0)
try:
    d=json.load(sys.stdin)
    sid=str(d.get('session_id') or '-')
    tool=str(d.get('tool_name') or '-')
    ti=d.get('tool_input') or {}
    fp=''
    lines=0
    if tool in ('Edit','Write'):
        fp=str(ti.get('file_path') or '')
        if tool=='Write':
            lines=nlines(ti.get('content'))
        else:
            lines=nlines(ti.get('new_string'))
    elif tool=='MultiEdit':
        fp=str(ti.get('file_path') or '')
        for e in (ti.get('edits') or []):
            lines+=nlines(e.get('new_string'))
    elif tool=='NotebookEdit':
        fp=str(ti.get('notebook_path') or '')
        lines=nlines(ti.get('new_source'))
    cmd=str(ti.get('command') or '') if tool=='Bash' else ''
    print(tool)
    print(sid)
    print(fp)
    print(lines)
    print('1' if cmd else '0')
    sys.stdout.write(cmd)
except Exception:
    print('-'); print('-'); print(''); print('0'); print('0')
" 2>/dev/null)"
[ -n "$META" ] || exit 0

TOOL="$(printf '%s' "$META" | sed -n '1p')"
SID="$(printf '%s' "$META" | sed -n '2p')"
FP="$(printf '%s' "$META" | sed -n '3p')"
LINES="$(printf '%s' "$META" | sed -n '4p')"
HASCMD="$(printf '%s' "$META" | sed -n '5p')"
CMD="$(printf '%s' "$META" | sed -n '6,$p')"

[ -n "$TOOL" ] && [ "$TOOL" != "-" ] || exit 0
[ -n "$SID" ] && [ "$SID" != "-" ] || SID="default"
case "$LINES" in *[!0-9]*) LINES=0 ;; esac
[ -n "$LINES" ] || LINES=0

SID_SAFE="$(printf '%s' "$SID" | tr -c 'A-Za-z0-9._-' '_')"
mkdir -p "$STATE_DIR" 2>/dev/null
# Best-effort GC so STATE_DIR stays bounded.
find "$STATE_DIR" -type f -mtime +"$PLAN_REVIEW_TTL_DAYS" -delete 2>/dev/null
STATE="$STATE_DIR/$SID_SAFE"

reset_state() {
  rm -f "$STATE" "$STATE.notified" 2>/dev/null  # clear the batch + its block-once "seen" marker
}

# --- RESET branches ---------------------------------------------------------
# Delegation/review happened: a worker/reviewer was spawned -> the inline batch is over.
if [ "$TOOL" = "Agent" ] || [ "$TOOL" = "Task" ]; then
  reset_state
  exit 0
fi

# The inline batch shipped via Bash: `git commit` or `gh pr merge` -> reset.
if [ "$TOOL" = "Bash" ]; then
  if [ "$HASCMD" = "1" ] && printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:](])git[[:space:]]+commit\b|gh[[:space:]]+pr[[:space:]]+merge\b'; then
    reset_state
  fi
  exit 0
fi

# Only the edit tools accumulate from here. (Matcher is Edit|Write|MultiEdit, but NotebookEdit may
# still arrive if reused on a broader matcher elsewhere; handle it harmlessly.)
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[ -n "$FP" ] || exit 0

# --- CARVE-OUT: bookkeeping / glue / ritual paths never count ----------------
# IDENTICAL carve-out set to inline-delegate-nudge.
is_carveout() {
  local p="$1"
  case "$p" in
    */memory/*|memory/*) return 0 ;;
    */.ai-workspace/*|.ai-workspace/*) return 0 ;;
    */agent-working-memory/*|agent-working-memory/*) return 0 ;;
    */plans/*) return 0 ;;
    */tmp/*|tmp/*) return 0 ;;
    */.claude/*|.claude/*) return 0 ;;
    */MEMORY.md|MEMORY.md) return 0 ;;
  esac
  case "$p" in
    *.md) return 0 ;;
  esac
  return 1
}

if is_carveout "$FP"; then
  exit 0
fi

# --- ACCUMULATE: add this file (if new) + its line estimate ------------------
# State file format: line 1 = cumulative lines; lines 2.. = distinct file paths (one per line).
CUR_LINES=0
declare -a FILES=()
if [ -f "$STATE" ]; then
  CUR_LINES="$(sed -n '1p' "$STATE" 2>/dev/null | tr -dc '0-9')"
  [ -n "$CUR_LINES" ] || CUR_LINES=0
  while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
  done < <(sed -n '2,$p' "$STATE" 2>/dev/null)
fi
case "$CUR_LINES" in *[!0-9]*) CUR_LINES=0 ;; esac

already=0
for f in "${FILES[@]:-}"; do
  [ "$f" = "$FP" ] && already=1 && break
done
if [ "$already" -eq 0 ]; then
  FILES+=("$FP")
fi

NEW_LINES=$((CUR_LINES + LINES))

# Persist updated state.
{
  printf '%s\n' "$NEW_LINES"
  for f in "${FILES[@]:-}"; do
    [ -n "$f" ] && printf '%s\n' "$f"
  done
} > "$STATE" 2>/dev/null

NFILES="${#FILES[@]}"

# --- NON-TRIVIAL gate (same sensor as inline-delegate-nudge) -----------------
NONTRIVIAL=0
REASON=""
if [ "$NFILES" -ge "$PLAN_REVIEW_FILES" ]; then
  NONTRIVIAL=1
  REASON="${NFILES} distinct task-work files edited inline"
elif [ "$NEW_LINES" -gt "$PLAN_REVIEW_LINES" ]; then
  NONTRIVIAL=1
  REASON="~${NEW_LINES} changed lines across ${NFILES} file(s) inline"
fi

# Not yet delegate-sized -> nothing to gate.
[ "$NONTRIVIAL" -eq 1 ] || exit 0

# --- PLAN-REVIEW-MARKER check ------------------------------------------------
# Find the most-recently-modified .ai-workspace/plans/*.md (the "active" plan). If it carries a
# review marker, ALLOW; if no plan exists OR the active plan has no marker, the gate fires.
# Marker = a `## Review` section header OR a `plan-review:`/`reviewed:` trailer line.
ACTIVE_PLAN=""
if [ -d "$PLANS_DIR" ]; then
  # newest *.md by mtime; portable (no GNU-only flags). ls -t sorts by mtime desc.
  ACTIVE_PLAN="$(ls -t "$PLANS_DIR"/*.md 2>/dev/null | head -1)"
fi

plan_has_review_marker() {
  local plan="$1"
  [ -n "$plan" ] && [ -f "$plan" ] || return 1
  # `## Review` header (allow trailing words like "## Review (P1-P4)"); case-insensitive.
  if grep -Eiq '^[[:space:]]*#{1,6}[[:space:]]+review\b' "$plan" 2>/dev/null; then
    return 0
  fi
  # `plan-review:` or `reviewed:` trailer (anywhere, leading ws ok); case-insensitive.
  if grep -Eiq '(^|[[:space:]])(plan-review|reviewed):' "$plan" 2>/dev/null; then
    return 0
  fi
  return 1
}

if plan_has_review_marker "$ACTIVE_PLAN"; then
  # Active plan WAS reviewed -> the plan-review leg is satisfied; allow.
  exit 0
fi

# Non-trivial code edit + active plan has NO review marker (or no plan) -> the gate fires.
if [ -n "$ACTIVE_PLAN" ]; then
  PLAN_NOTE="active plan '$ACTIVE_PLAN' carries NO review marker (no '## Review' section and no plan-review:/reviewed: trailer)"
else
  PLAN_NOTE="no .ai-workspace/plans/*.md found to vet"
fi

cat >&2 <<EOF
<system-reminder>
PLAN-REVIEW-BEFORE-EXECUTE (plan-review-before-execute hook, #781): this turn has accumulated
${REASON} since the last delegation/review/ship/reset — that is non-trivial (delegate-sized) work
being BUILT, but the plan was never vetted: ${PLAN_NOTE}.
The unifying doctrine is plan -> REVIEW-PLAN -> execute -> review-execute (#779). You are skipping the
review-PLAN leg. Before building, VET THE PLAN:
  - Run /per-task-review-loop plan-chain (P1 stateless -> P2 comparative -> P3 cairn-grounded -> P4
    coherence) OR /auto-flow Stage 1 to run the four-reviewer planning pass and append a verdict.
  - The plan needs a review marker: a '## Review' section with a verdict, OR a plan-review:/reviewed:
    trailer line. Add one once the plan is vetted (or note in the plan why this is trivial).
DEFAULT DELIVERY IS /delegate — it keeps the main context lean (a fresh subagent builds from a brief,
so your own context stays small -> fewer /compact cycles -> longer task lists survive). Work INLINE
(+ /per-task-review-loop) ONLY when the task is NOT briefable — i.e. one of:
  (1) tightly coupled to live in-session context (state a brief can't carry);
  (2) interleaved with an in-session-only action (a paid/interactive/operator-loop step mid-task);
  (3) exploratory / shape-unknown (the plan itself is being discovered as you build);
  (4) handoff overhead > the interlocked work (the brief would cost more than just doing it here).
If none of those hold, hand it to /delegate. If this genuinely IS trivial, set PLAN_REVIEW_OK=1 to
silence for the rest of this batch. The counter RESETS automatically on the next /delegate OR
/per-task-review-loop dispatch (any Agent/Task spawn), on git commit / gh pr merge, or under
SHIP_PIPELINE=1. Kill-switch: PLAN_REVIEW_OFF=1.
</system-reminder>
EOF

# Response by mode (mirrors inline-delegate-nudge exactly).
case "$PLAN_REVIEW_MODE" in
  block)
    echo "(PLAN_REVIEW_MODE=block) Blocked — vet the plan (/per-task-review-loop plan-chain or /auto-flow Stage 1) and add a review marker, or set PLAN_REVIEW_OK=1 to proceed." >&2
    exit 2
    ;;
  block-once)
    if [ ! -f "$STATE.notified" ]; then
      : > "$STATE.notified" 2>/dev/null  # mark this batch as already-warned
      echo "(PLAN_REVIEW_MODE=block-once) Blocked ONCE so you see this — review the PLAN first (add a '## Review'/plan-review: marker), or set PLAN_REVIEW_OK=1. Re-issue the edit to continue (you will NOT be blocked again this batch)." >&2
      exit 2
    fi
    # already warned this batch -> allow (exit 0 below)
    ;;
  *)
    # "nudge" / unrecognised -> legacy exit-0 (invisible to the model; back-compat only).
    ;;
esac

exit 0
