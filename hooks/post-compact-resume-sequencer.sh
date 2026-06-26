#!/usr/bin/env bash
# post-compact-resume-sequencer.sh — surface the Post-Compact Resume & Sequencing Protocol at the right
# moment. NON-blocking; exit 0 always (a SessionStart/UserPromptSubmit reminder must never wedge a session).
#
# WHY (Rule 17 / feedback_mechanical_gate_over_memory): the agent carries a pocket-card resume protocol but
# does NOT reliably ELI5 + re-sequence into 3 tiers + gate for approval after a /compact — the operator had
# to ask "eli5 the plan and next steps" manually (2026-05-31). The mechanically-verifiable part is "reliably
# SURFACE the protocol"; the EXECUTION (ELI5 quality, ordering correctness) is judgment and is NOT graded here.
#
# TWO SURFACES, one snippet (so the text can never drift):
#   * SessionStart (registered with matcher "compact" → the harness fires this ONLY post-compact): write a
#     COMPACT-SPECIFIC sentinel ~/.claude/cairn/sessions/{sid}.compact AND print the reminder to stdout
#     (SessionStart stdout is injected into model context). NOTE: we rely on the harness matcher, NOT an
#     in-script `source`-field read — no existing hook reads a SessionStart `source` field, so asserting its
#     shape would be an unverified runtime assumption (Rule 8). The matcher is the confirmed-working gate.
#   * UserPromptSubmit (`--prompt-mode`, fires on every prompt): emit ONLY when BOTH (a) the {sid}.compact
#     sentinel is fresh (now-mtime < window — i.e. a COMPACT happened recently, NOT merely any session start;
#     the every-start {sid}.start file deliberately is NOT used because it can't distinguish compact from
#     startup/resume) AND (b) the prompt is resume-intent. Then it consumes the sentinel (one-shot).
#
# Bypasses (distinct semantics): POST_COMPACT_RESUME_SEQUENCER_OVERRIDE=1 suppresses the SURFACING entirely
# (operator/smoke). An in-prompt pre-auth ("resume and just run it") suppresses only the WAIT — the agent
# still SHOWS the ELI5 + 3-tier plan; that is the agent's judgment, not this hook's concern.
set -uo pipefail

[ "${POST_COMPACT_RESUME_SEQUENCER_OVERRIDE:-0}" = "1" ] && exit 0

MODE="primary"
case "${1:-}" in
  --prompt-mode) MODE="prompt" ;;
  --clear-mode) MODE="clear" ;;   # SessionStart:clear — plant the clear sentinel only, do NOT emit
esac
SESS_DIR="${POST_COMPACT_SESS_DIR:-$HOME/.claude/cairn/sessions}"   # overridable for smoke tests
WINDOW_MIN="${POST_COMPACT_RESUME_WINDOW_MIN:-30}"   # recency window (minutes) since COMPACT, for --prompt-mode
RESUME_RE='resume|continue|next step|what.?s next|carry on|pick up|where were we|eli5 the plan'

INPUT="$(cat 2>/dev/null)"

# --- resolve session_id (mirrors cairn-session-start.sh / cairn-user-prompt-submit.sh two-tier extractor) ---
sid=""
if command -v python3 >/dev/null 2>&1; then
  sid="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('session_id','') or '')
except Exception: print('')" 2>/dev/null)"
fi
[ -z "$sid" ] && sid="$(printf '%s' "$INPUT" | grep -o '\"session_id\"[^,}]*' | head -1 | sed 's/.*\"session_id\"[[:space:]]*:[[:space:]]*\"//;s/\".*//')"

# --- subagent (sidechain) guard (#887) ---
# A subagent SHARES the parent session_id, so it shares the <sid>.compact sentinel. The resume
# protocol is a MAIN-session orientation gate; firing it inside a sidechain derails the role
# subagent AND steals the one-shot sentinel from the parent. Detect the sidechain by its transcript
# path (same convention as three-role-subagent-ledger.sh) and stay completely silent + side-effect-free.
# FAIL-SAFE: suppress ONLY on a POSITIVE subagent match; absent/ambiguous transcript_path => proceed
# normally (better to occasionally over-show than to silently break the main-session gate).
# EMPIRICAL NOTE (#887 probe): UserPromptSubmit does NOT fire in sidechains today and SessionStart is
# matcher-gated to compact, so this guard is currently DORMANT defense-in-depth — it can never suppress
# a true main-session event, only a future sidechain firing.
tpath="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('transcript_path','') or '')
except Exception: print('')" 2>/dev/null)"
case "$tpath" in
  *"/subagents/agent-"*) exit 0 ;;   # sidechain → no plant, no emit, no sentinel consume
esac

# The protocol reminder (single source of truth — both surfaces print this exact block).
emit_reminder() {
  cat <<'REMINDER'

[post-compact resume protocol] You are resuming after a /compact or /clear. BEFORE any task work, do this IN ORDER:
1. ELI5 the plan + next steps in plain language (CLAUDE.md ELI5 rule). Re-orient FROM SOURCE first — read the
   latest session-state-pre-compact card's Pickup pointer, OPEN AND READ THE BIG PLAN it names (the overarching
   plan doc itself, not just the pointer — that is where the full remaining scope lives), and the live TaskList
   (don't narrate from memory; post-compact memory is what was lost).
2. RECONCILE the live TaskList against reality FIRST: mark finished/obsolete tasks completed and DELETE the
   already-done ones so the list reflects what is actually still open. A stale list (dozens of done tasks) hides
   the real remaining work and corrupts the sequencing in step 3.
3. Build a SEQUENCED list of ALL remaining work in THREE tiers by impact + dependency, drawn from the UNION of
   (a) the BIG PLAN's not-yet-done steps AND (b) every still-OPEN task in the reconciled TaskList — so no open
   task or plan step is dropped: Tier 1 QUICK+EASY first (momentum; often unblocks others), Tier 2 the
   MOST-DEPENDED-UPON / blocking tasks (unblock the graph), Tier 3 LONG-RUNNING tasks last (usually kicked off
   detached AFTER the quick wins so their clock overlaps).
4. PRESENT the 3-tier plan and WAIT for the operator to review + approve (silence is not approval).
5. ONLY AFTER approval: create/update the TaskList in that sequenced order (Tier 1 → lowest IDs, headline-first)
   and execute. This is the ONE initial post-compact gate, NOT per-slice — once approved, Autonomous Pipeline
   Mode resumes (no further per-task approval). Full spec: post-compact-resume-sequencing-protocol.md
REMINDER
}

if [ "$MODE" = "primary" ]; then
  # SessionStart:compact — matcher guarantees this is post-compact. Plant the compact-specific sentinel + surface.
  if [ -n "$sid" ]; then
    mkdir -p "$SESS_DIR" 2>/dev/null || true
    date +%s > "$SESS_DIR/$sid.compact" 2>/dev/null || true
  fi
  emit_reminder
  exit 0
fi

if [ "$MODE" = "clear" ]; then
  # SessionStart:clear — matcher guarantees this is a /clear. Plant the clear-specific sentinel ONLY; do NOT
  # emit (most /clears START FRESH work — let the UserPromptSubmit backstop gate on resume-intent). Mirrors
  # the compact primary branch minus emit_reminder. The subagent/sidechain guard above already protects this
  # path (it runs BEFORE this branch and exits on a */subagents/agent-* transcript regardless of mode).
  if [ -n "$sid" ]; then
    mkdir -p "$SESS_DIR" 2>/dev/null || true
    date +%s > "$SESS_DIR/$sid.clear" 2>/dev/null || true
  fi
  exit 0
fi

# --- prompt mode (UserPromptSubmit backstop) ---
# Honors BOTH sentinels: {sid}.compact AND {sid}.clear. Correct two-sentinel logic (NOT a naive compact-first
# port, which would (a) MASK a fresh .clear behind a stale .compact and (b) double-fire if both are fresh):
#   * gather every PRESENT sentinel; if NONE present → silent.
#   * compute freshness (now-mtime < window) per present sentinel.
#   * if AT LEAST ONE is fresh AND the prompt is resume-intent → emit ONCE and rm -f BOTH sentinels (one-shot).
#   * if NONE fresh → rm -f ALL present (stale) sentinels and exit silent.
#   * if fresh-but-not-resume-intent → exit 0 and LEAVE the sentinels (a later in-window resume can still fire).
[ -n "$sid" ] || exit 0
COMPACT_SENT="$SESS_DIR/$sid.compact"
CLEAR_SENT="$SESS_DIR/$sid.clear"

present=""
[ -f "$COMPACT_SENT" ] && present="$present $COMPACT_SENT"
[ -f "$CLEAR_SENT" ]   && present="$present $CLEAR_SENT"
[ -n "$present" ] || exit 0                                # neither sentinel present → silent

# recency gate: at least one PRESENT sentinel is fresh (a compact/clear happened within the window)
now=$(date +%s); any_fresh=0
for s in $present; do
  mt=$(stat -f %m "$s" 2>/dev/null || echo 0)
  [ $(( now - mt )) -lt $(( WINDOW_MIN * 60 )) ] && any_fresh=1
done
if [ "$any_fresh" -eq 0 ]; then
  rm -f "$COMPACT_SENT" "$CLEAR_SENT" 2>/dev/null || true   # all stale → clean both, silent
  exit 0
fi

# intent gate: prompt reads as a resume request
prompt=""
if command -v python3 >/dev/null 2>&1; then
  prompt="$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('prompt','') or '')
except Exception: print('')" 2>/dev/null)"
fi
[ -n "$prompt" ] || exit 0
printf '%s' "$prompt" | grep -iqE "$RESUME_RE" || exit 0    # fresh but not resume-intent → leave sentinels, silent

rm -f "$COMPACT_SENT" "$CLEAR_SENT" 2>/dev/null || true     # one-shot: consume BOTH so it fires exactly once
emit_reminder
exit 0
