#!/usr/bin/env bash
# inline-delegate-nudge.sh — PreToolUse hook (#755).
#
# WHY: the main agent keeps doing whole multi-file tasks INLINE with no independent
# review (one-shotting) instead of taking one of the two good escape paths. Inline work
# bloats the main context -> forces frequent /compact -> shorter task lists, AND unreviewed
# inline work ships defects. This hook watches edit-tool calls and, once an inline batch
# crosses a "delegate-sized" threshold (>=3 distinct task-work files OR >50 cumulative
# changed lines since the last reset), surfaces a message pointing at BOTH escape paths:
#   - HANDOFF: /delegate <PLAN> (spawn a worker subagent) + /delegate review <PR> (stateless review).
#   - INLINE + REVIEW: /per-task-review-loop (stay inline, but dispatch a stateless reviewer
#     per task so the inline work still gets an independent per-task quality gate).
# The reset already fires on ANY Agent/Task dispatch, which BOTH paths use, so the sensor
# is identical for either escape — only the nudge MESSAGE names both.
#
# RESPONSE DECISION: BLOCK-ONCE per batch (default since #769), NOT a pure nudge and NOT a
# permanent block. WHY this shape:
#   - A pure NUDGE (exit 0 + stderr) was the original default — but a PreToolUse hook's stderr
#     is only fed to the MODEL on exit 2; on exit 0 it reaches the user transcript only. So the
#     nudge was INVISIBLE to the agent and silently failed (2026-06-09: the main agent one-shot a
#     3-file/415-line change inline with the sensor firing the whole time — see
#     feedback_exit0_stderr_hook_nudge_invisible_to_model). Invisible == not a guard.
#   - A PERMANENT block (every triggered edit -> exit 2) WOULD be visible, but this hook fires on
#     the MAIN AGENT'S edit path CONSTANTLY and the "glue vs real task work" carve-out is a
#     heuristic (path-prefix denylist + a line estimate). A false BLOCK on every 3rd-file inline
#     edit anywhere (fixing this very hook, a coupled refactor, a one-file tweak that grew) is
#     catastrophically expensive.
#   - BLOCK-ONCE is the balance: exit 2 the FIRST time the trigger crosses in a batch (so the
#     agent SEES the reminder and must make a conscious delegate/review/lfah choice), then mark
#     the batch "notified" and fall through to exit 0 for the rest — visible, but never a
#     permanent wall. Re-issue the edit to continue inline; the batch re-arms after any reset.
# The threshold (>=3 files / >50 lines) is a coarse proxy for "delegate-sized", so the SENSOR is
# mechanical but the RESPONSE preserves judgment (one interrupt, then the agent decides). Modes:
# INLINE_DELEGATE_MODE=block (strict, blocks every triggered edit) | block-once (default) | nudge
# (legacy, invisible). Escape hatches bypass all modes: INLINE_DELEGATE_OK=1 silences for the
# batch; INLINE_DELEGATE_OFF=1 is the kill-switch; SHIP_PIPELINE=1 exempts the ship pipeline.
#
# BOTH-ENDS-BOOLEAN (Rule 17 / feedback_mechanical_hook_both_ends_verifiable): the TRIGGER
# is an objective boolean over session state — (distinct non-carve-out files since reset >= N)
# OR (cumulative est. changed-lines since reset > L). The state is mechanically maintained:
# every Edit/Write/MultiEdit/NotebookEdit ADDS to it; every Agent/Task dispatch, every
# git-commit / gh-pr-merge Bash, and SHIP_PIPELINE=1 RESET it. Both the accumulate side and
# the reset side are objective events, so the sensor is mechanical; only the RESPONSE is a
# nudge (because "is THIS edit really delegate-worthy task work" is the judgment we refuse
# to false-block on). This is the correct shape: mechanical sensor, judgment-preserving action.
#
# RESET on: PreToolUse Agent|Task (delegation happened) OR a Bash `git commit` / `gh pr merge`
# (the inline batch shipped) OR SHIP_PIPELINE=1.
# CARVE-OUTS (never count toward the trigger): memory/, .ai-workspace/, agent-working-memory/,
# */plans/*, MEMORY.md, tmp/, .claude/, and *.md session cards. Plus full exemption when
# SHIP_PIPELINE=1 or INLINE_DELEGATE_OK=1.
#
# NO set -e (a gate must deterministically reach its exit; a mid-logic non-zero must not
# change behavior). Fail-open on ANY parse/read error -> exit 0, never blocks normal work.

set -u

# Kill-switch + escape hatches (full exemption, no state mutation needed).
[ "${INLINE_DELEGATE_OFF:-}" = "1" ] && exit 0
[ "${INLINE_DELEGATE_OK:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# Thresholds (env-configurable, no hardcode lock-in).
INLINE_DELEGATE_FILES="${INLINE_DELEGATE_FILES:-3}"   # distinct task-work files >= this -> trigger
INLINE_DELEGATE_LINES="${INLINE_DELEGATE_LINES:-50}"  # cumulative changed-lines > this -> trigger
STATE_DIR="${INLINE_DELEGATE_STATE_DIR:-$HOME/.claude/.inline-delegate-state}"
INLINE_DELEGATE_TTL_DAYS="${INLINE_DELEGATE_TTL_DAYS:-14}"
# Response mode — THREE values:
#   "block-once" (DEFAULT, set 2026-06-09 / #769): exit 2 the FIRST time the trigger crosses
#     in a batch (so the reminder actually REACHES THE MODEL — a PreToolUse hook's stderr is
#     only fed to the agent on exit 2; on exit 0 it goes to the user transcript only, so the
#     old "nudge" default was INVISIBLE to the agent and silently failed — see
#     feedback_exit0_stderr_hook_nudge_invisible_to_model). After that one block the batch is
#     marked "notified" and subsequent edits fall through to exit 0, so block-once GUARANTEES
#     one visible interruption (forcing a conscious delegate/review/lfah choice) WITHOUT
#     permanently walling legitimate multi-file inline work.
#   "block": exit 2 on EVERY triggered edit until you delegate or set INLINE_DELEGATE_OK=1
#     (stricter; opt-in via env).
#   "nudge": legacy exit-0 + stderr (INVISIBLE to the model — kept only for back-compat /
#     explicit opt-out; do NOT rely on it to steer the agent).
# Any unrecognised value is treated as "nudge" (safe, non-blocking). The escape hatches
# (INLINE_DELEGATE_OK=1 / _OFF=1 / SHIP_PIPELINE=1) bypass ALL modes.
INLINE_DELEGATE_MODE="${INLINE_DELEGATE_MODE:-block-once}"

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# --- parse session_id + tool_name + file_path/notebook_path + an added-lines estimate ---
# One field per line; the line estimate counts newlines in content (Write) or new_string (Edit).
# MultiEdit: sum new_string across edits[]; file_path is shared. NotebookEdit: notebook_path + new_source.
META="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
def nlines(s):
    if not s: return 0
    # estimate added lines as number of lines in the new text
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
    # emit: tool / sid / fp / lines / has_command(0|1) — command body on its own trailing block
    print(tool)
    print(sid)
    print(fp)
    print(lines)
    print('1' if cmd else '0')
    # command body LAST, may contain anything; read to EOF
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
find "$STATE_DIR" -type f -mtime +"$INLINE_DELEGATE_TTL_DAYS" -delete 2>/dev/null
STATE="$STATE_DIR/$SID_SAFE"

reset_state() {
  rm -f "$STATE" "$STATE.notified" 2>/dev/null  # clear the batch + its block-once "seen" marker
}

# --- RESET branches ---------------------------------------------------------
# Delegation happened: a worker/reviewer was spawned -> the inline batch is over.
if [ "$TOOL" = "Agent" ] || [ "$TOOL" = "Task" ]; then
  reset_state
  exit 0
fi

# The inline batch shipped via Bash: `git commit` or `gh pr merge` -> reset.
if [ "$TOOL" = "Bash" ]; then
  if [ "$HASCMD" = "1" ] && printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:](])git[[:space:]]+commit\b|gh[[:space:]]+pr[[:space:]]+merge\b'; then
    reset_state
  fi
  # Bash never accumulates task-work; nothing more to do.
  exit 0
fi

# Only the edit tools accumulate from here.
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[ -n "$FP" ] || exit 0

# --- CARVE-OUT: bookkeeping / glue / ritual paths never count ----------------
# Normalize: match on the path as given (absolute or relative). Use case globs.
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
  # *.md session cards (any markdown is treated as a session card / doc, not task work).
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

# Is this file already counted?
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

# --- TRIGGER evaluation ------------------------------------------------------
TRIG=0
REASON=""
if [ "$NFILES" -ge "$INLINE_DELEGATE_FILES" ]; then
  TRIG=1
  REASON="${NFILES} distinct task-work files edited inline"
elif [ "$NEW_LINES" -gt "$INLINE_DELEGATE_LINES" ]; then
  TRIG=1
  REASON="~${NEW_LINES} changed lines across ${NFILES} file(s) inline"
fi

if [ "$TRIG" -eq 1 ]; then
  cat >&2 <<EOF
<system-reminder>
INLINE-DELEGATE NUDGE (inline-delegate-nudge hook, #755): this turn has accumulated ${REASON}
since the last delegation/review/ship/reset — this is DELEGATE-SIZED work being done INLINE in the
main context with no independent review (one-shotting). Inline multi-file work bloats the main
context -> forces frequent /compact -> shorter task lists, and unreviewed inline work ships defects.
Pick ONE of the three good paths instead of one-shotting (/delegate is the DEFAULT — reach for it first):
  - PREFER — hands work to a fresh subagent, keeps the main context lean: /delegate <PLAN> spawns a
    fresh worker subagent to build from a brief alone; then /delegate review <PR> for a stateless review
    of the diff. This is the default-preferred path — offloading keeps the main context lean (fewer
    /compact cycles, longer task lists survive).
  - WHEN DELEGATE DOESN'T FIT — testable code (red test -> build): lfah — the greenfield builder. Write
    a failing test first, then let lfah build it to green in its own context. Best when the work is code
    with a clear oracle.
  - WHEN DELEGATE DOESN'T FIT — must work inline (keep the build here): /per-task-review-loop dispatches
    an independent stateless reviewer in the background after each task, so inline work still gets a
    per-task quality gate.
Quick guide: hand off a self-contained task -> /delegate (DEFAULT, keeps context lean) · testable code
(red test -> build) -> lfah · must work inline -> /per-task-review-loop.
If this is genuinely one small coherent edit that needs neither (e.g. fixing this hook, a tightly
coupled refactor), continue — set INLINE_DELEGATE_OK=1 to silence for the rest of this batch. The
counter RESETS automatically on the next /delegate OR /per-task-review-loop dispatch (any Agent/Task
spawn), on git commit / gh pr merge, or under SHIP_PIPELINE=1. Kill-switch: INLINE_DELEGATE_OFF=1.
</system-reminder>
EOF
  # Response by mode. The reminder above already went to stderr; whether it REACHES THE MODEL
  # depends on the exit code (exit 2 surfaces to the agent; exit 0 goes to the user transcript
  # only — the reason the old nudge default was invisible, #769).
  case "$INLINE_DELEGATE_MODE" in
    block)
      # Strict: block EVERY triggered edit until delegated / OK=1.
      echo "(INLINE_DELEGATE_MODE=block) Blocked — /delegate this work, run /per-task-review-loop or lfah, or set INLINE_DELEGATE_OK=1 to proceed inline." >&2
      exit 2
      ;;
    block-once)
      # Default: block exactly ONCE per batch so the reminder is SEEN, then fall through to
      # allow so legitimate multi-file inline work is not permanently walled.
      if [ ! -f "$STATE.notified" ]; then
        : > "$STATE.notified" 2>/dev/null  # mark this batch as already-warned
        echo "(INLINE_DELEGATE_MODE=block-once) Blocked ONCE so you see this — now choose: /delegate, /per-task-review-loop, or lfah. Re-issue the edit to continue inline (you will NOT be blocked again this batch), or set INLINE_DELEGATE_OK=1." >&2
        exit 2
      fi
      # already warned this batch -> allow (exit 0 below)
      ;;
    *)
      # "nudge" / unrecognised -> legacy exit-0 (invisible to the model; back-compat only).
      ;;
  esac
fi

exit 0
