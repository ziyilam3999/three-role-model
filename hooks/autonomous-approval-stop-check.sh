#!/bin/bash
# autonomous-approval-stop-check.sh — Stop hook (Rule 17) against the STOP-WHEN-ALREADY-APPROVED
# anti-pattern: in autonomous/pipeline mode (after the operator approved the plan), ending a turn by
# asking permission for a NEXT step that is ALREADY in the approved plan OR part of a standing workflow
# (root-cause→fix→PREVENT→ship: the prevention/cleanup follow-ups are standing-approved, not fresh asks).
#
# Failure mode this prevents (2026-06-05 incident, #601 / task #623):
#   After committing the JS-benchmark verdict, I ended the turn with "ship #623 (the harness INFRA-SKIP
#   prevention) now, or pick it up later?" and WAITED — at 4am, operator asleep. But #623 was a prevention
#   follow-up in the standing root-cause→prevent→ship loop AND was listed in the approved verdict pipeline.
#   Stopping wasted a full cycle for a step that needed no approval. Operator: "verify if it is already
#   approved in the plan; if approved, no need to stop, can proceed."
#
# Trigger (recurrence-condition): the turn's FINAL assistant message ENDS with an approval-seeking OFFER to
#   proceed/defer the agent's OWN next step — yes/no "should I proceed / want me to ship / shall I continue"
#   or a "now, or later/wait/hold" defer-offer. Deliberately NARROW: it targets PROSE asks to continue own
#   tracked work, NOT genuine substantive forks (those should use AskUserQuestion, and carry the bypass).
#
# Exempt (objective): an explicit bypass token "(operator decision required)" / "(your call)" /
#   "(genuinely new decision)" / "[decision]" in the message. The "is this action already approved?" half is
#   JUDGMENT (semantic match of the question against the approved plan), so per
#   feedback_mechanical_hook_both_ends_verifiable this is a high-precision DETECTOR + conscious-classify
#   nudge, not a pure both-ends-boolean gate — it forces "verify approved → proceed, else mark it the
#   operator's call" at the exact stop moment rather than letting ask-on-autopilot drift.
#
# Loop-safe: if stop_hook_active is set (we previously blocked this turn-end), exit 0 — block ONCE.
# Override (audit-logged): AUTONOMOUS_STOP_OVERRIDE=1.
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
if [ "${AUTONOMOUS_STOP_OVERRIDE:-}" = "1" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | AUTONOMOUS_STOP_OVERRIDE=1" >> "$HOME/.claude/.rule-12-overrides.log" 2>/dev/null || true
  exit 0
fi
INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_INPUT="$INPUT" python3 <<'PYEOF'
import json, os, re, sys
try:
    d = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    sys.exit(0)

# loop guard: never block more than once per turn-end
if d.get("stop_hook_active"):
    sys.exit(0)

msg = (d.get("last_assistant_message") or "")
low = msg.lower()

# explicit bypass: author consciously marks this as genuinely the operator's decision
for tok in ("(operator decision required)", "(your call)", "(genuinely new decision)",
            "(needs your call)", "[decision]", "(decision required)"):
    if tok in low:
        sys.exit(0)

# TRIGGER: approval-seeking offer to PROCEED/DEFER the agent's own next step.
# The PROCEED / NOW-OR-LATER shapes additionally require the message to END as a question (the stop-to-ask
# shape — an offer buried mid-message that the turn then acts past is not a stop). An LMK offer
# ("let me know if you want me to X") is an explicit wait-for-input deferral even WITHOUT a '?'.
PROCEED = (r"\b(should|shall|can|do you want me to|want me to|would you like me to|ok(ay)? (for me )?to|"
           r"shall i|should i)\b.{0,40}\b(proceed|ship|continue|go ahead|kick (it )?off|start|run|do it|"
           r"land|merge|carry on|move on|pick (it|this) up|tackle)\b")
NOW_OR_LATER = (r"\b(now|go ahead|proceed|ship it)\b[^?]{0,40}\bor\b[^?]{0,40}"
                r"\b(later|wait|hold|defer|next session|next time|leave it|pick (it|this) up|after)\b")
LMK = r"\blet me know (if|whether) you('?d| would)? (want|like|prefer)\b|\b(lmk|let me know) (before|if) i\b"

has_q = "?" in low[-400:]
proceed_trig = (re.search(PROCEED, low) or re.search(NOW_OR_LATER, low)) is not None
lmk_trig = re.search(LMK, low) is not None
if not ((proceed_trig and has_q) or lmk_trig):
    sys.exit(0)

# BLOCK the turn-end: force verify-approval-then-proceed (or conscious "operator's call").
sys.stderr.write(
    "BLOCKED (autonomous-approval-stop): your final message ENDS by asking the operator to approve "
    "continuing your own next step (e.g. 'should I ship X now, or later?'). In autonomous/pipeline mode "
    "(post-plan-approval), a NEXT step that is already in the approved plan OR part of a standing workflow "
    "(root-cause→fix→PREVENT→ship; the next sequenced task; post-merge cleanup) is ALREADY approved — "
    "stopping to ask stalls the pipeline (the operator may be away/asleep — #601, 4am #623).\n"
    "Do ONE of:\n"
    "  • VERIFY the step against the approved plan / standing workflow — if it's there, PROCEED (don't ask); OR\n"
    "  • if it is genuinely a NEW decision the operator hasn't delegated (a real fork / destructive / "
    "outward-facing / scope change), add '(operator decision required)' to the message (or use "
    "AskUserQuestion); OR\n"
    "  • single-use override: AUTONOMOUS_STOP_OVERRIDE=1.\n"
    "See feedback_no_stop_for_already_approved_step.\n")
sys.exit(2)
PYEOF
