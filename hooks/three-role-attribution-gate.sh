#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE ATTRIBUTION GATE (#1185). A SIBLING of three-role-transition-gate.sh,
# NOT a replacement: the transition-gate sequences the EXECUTOR (requires BOTH tags + a prior plan-review) and
# FAIL-OPENS on a spawn that lacks the task tag — explicitly an "honest limitation." This gate targets exactly
# that gap: a spawn carrying ROLE:<role> but NO 3ROLE_TASK:<id> is UN-ATTRIBUTABLE (it cannot be filed against
# any task, so its role-attribution is silently lost). This gate surfaces a one-time visible nudge to add the
# task tag so the spawn becomes attributable.
#
# RESPONSE DECISION: BLOCK-ONCE (exit 2, visible), advisory — the SAME shape as new-project-bootstrap-nudge.sh
# and inline-delegate-nudge.sh. A PreToolUse hook's stderr reaches the MODEL only on exit 2; an exit-0 nudge
# lands in the user transcript only and is INVISIBLE to the agent (feedback_exit0_stderr_hook_nudge_invisible_
# to_model, the #769 lesson). So we exit 2 the FIRST time a given un-attributable spawn SIGNATURE is seen (the
# orchestrator SEES the message + consciously re-launches with the task tag), drop a per-signature marker, then
# fall through to exit 0 on the next matching spawn so a legitimately-non-3-role spawn (or a deliberate
# re-launch) is NEVER permanently wedged.
#
# POSITIVE CONDITION (the only thing that blocks) = ROLE tag matches AND 3ROLE_TASK tag does NOT match.
# Everything else FAIL-OPENS (exit 0 silent): both tags (the transition-gate's job), task-only, neither
# (normal non-3-role spawn), parse error, no session. This reconciles the fail-open principle with the
# deliberate block: a BUG must never wall real work (everything unclear -> allow), but the clean positive
# detection is the whole point and is safe because it is block-once + kill-switchable.
#
# BLOCK-ONCE keying: a per-signature sentinel file under a state dir, keyed on
#   sha1(session_id + ":" + role + ":" + prompt[:200])
# Per-signature (strictly better than per-session) so each DISTINCT un-attributable spawn earns its own
# one-time nudge — and a genuinely DIFFERENT second offense (different role OR different prompt[:200], same
# session) has a different signature and BLOCKS AGAIN (exactly the property block-once exists to guarantee;
# proven by smoke fixtures 2 + R1). Only the identical re-launch is suppressed.
#
# Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1 (uniform family) OR THREE_ROLE_ATTRIBUTION_OFF=1 (dedicated) OR
# SHIP_PIPELINE=1 (ship-pipeline exempt). Inline bypass token `[role-no-task-ok]` in the prompt -> exit 0 for a
# deliberate one-off. R2-PINNED regex: the EXACT sibling enum-anchored form /ROLE:\s*(planner|...)/i with the
# role at capture group [1] — NO left-boundary variant (one form only, consistent with the hook + smoke). The
# role enum cannot match arbitrary prose, and `3ROLE_TASK:` ends with `_` (not `:`) so /ROLE:/ never mis-fires
# on the task tag. No `set -e` (a non-block non-zero must never leak into a permission decision — #749).
#
# HONEST residual false-positive (plan-review O1): a spawn whose prompt literally contains an enum tag like
# `ROLE:executor` in PROSE but no real numeric 3ROLE_TASK:<digits> (e.g. a meta-spawn quoting this system's
# tags) trips the positive condition and blocks ONCE. Acceptable: the fail direction is a single visible
# block-once the operator clears via re-launch / inline bypass / kill-switch.
#
# Env overrides (for the smoke): THREE_ROLE_ATTRIBUTION_STATE_DIR (default ~/.claude/.three-role-attribution-state).
# PORT-NOTE: cites `parent-claude.md Invariant #2` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment/advisory only — nothing reads the file; safe forward-ref.
# Reference: parent-claude.md Invariant #2, hooks/three-role-transition-gate.sh (the sibling),
# hooks/new-project-bootstrap-nudge.sh (the block-once shape), the plan
# `.ai-workspace/plans/2026-06-24-1185-1187-spawn-ledger-hooks.md`.

set -u

# Kill-switches (full exemption, no state mutation).
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0
[ "${THREE_ROLE_ATTRIBUTION_OFF:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

STATE_DIR="${THREE_ROLE_ATTRIBUTION_STATE_DIR:-$HOME/.claude/.three-role-attribution-state}"
TTL_DAYS="${THREE_ROLE_ATTRIBUTION_TTL_DAYS:-14}"

INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Parse prompt (+ description + message, joined), session_id, the inline bypass token, and the block-once
# SIGNATURE in ONE node pass. Emits: "<role|-> <session|-> <hasTask 0|1> <bypass 0|1> <sig>" or "" on a fatal
# parse error (-> fail-open). The signature = sha1(session:role:prompt[:200]).
read -r ROLE SESSION HASTASK BYPASS SIG < <(
  HOOK_INPUT="$INPUT" node -e '
    const crypto=require("crypto");
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    const role = mRole ? mRole[1].toLowerCase() : "-";
    const hasTask = mTask ? "1" : "0";
    const bypass = /\[role-no-task-ok\]/i.test(prompt) ? "1" : "0";
    const sig=crypto.createHash("sha1").update((session||"-")+":"+role+":"+prompt.slice(0,200)).digest("hex");
    process.stdout.write([role, (session||"-"), hasTask, bypass, sig].join(" "));
  ' 2>/dev/null
)

# Fatal parse error (node printed "") -> fail-open.
[ -n "$SIG" ] || exit 0

# Inline bypass token -> exit 0 (deliberate one-off), even on the positive condition.
[ "$BYPASS" = "1" ] && exit 0

# POSITIVE CONDITION = ROLE matches AND 3ROLE_TASK does NOT. Anything else fail-opens (exit 0 silent):
#   - no role  -> $ROLE == "-"             (normal non-3-role spawn / task-only)
#   - has task -> $HASTASK == "1"          (both tags -> the transition-gate's job)
[ "$ROLE" != "-" ] || exit 0
[ "$HASTASK" = "0" ] || exit 0

# A positive spawn with no usable session cannot be keyed reliably; fail-open (allow) — anomalous, let the
# completion gate be the backstop.
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# --- per-signature block-once marker ---
mkdir -p "$STATE_DIR" 2>/dev/null
# Best-effort GC so STATE_DIR stays bounded (mirrors new-project-bootstrap-nudge.sh).
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null
MARKER="$STATE_DIR/$SIG.notified"

# Already nudged for THIS signature -> let the spawn proceed (block-once, not wedged).
[ -f "$MARKER" ] && exit 0

# First time for this signature: surface the nudge (exit 2 = VISIBLE to the model — #769) and drop the marker
# so the re-launch (same signature) proceeds.
: > "$MARKER" 2>/dev/null
cat >&2 <<EOF
<system-reminder>
THREE-ROLE ATTRIBUTION GATE (three-role-attribution-gate hook, #1185): a role subagent was launched carrying
ROLE:${ROLE} but NO 3ROLE_TASK:<id> tag — so it is UN-ATTRIBUTABLE (the role-ledger cannot file it against any
task, and its attribution is silently lost). Add the task tag so the spawn is recorded:
    3ROLE_TASK:<id> ROLE:${ROLE}
(prepend BOTH tags to the subagent's prompt, then re-launch). With both tags present this gate stays SILENT and
the spawn-ledger (#1187) records the role automatically.
This is ADVISORY + block-once PER SIGNATURE: you will see this ONCE for this spawn. Re-launch with the task tag
to proceed (you will NOT be blocked again for this same spawn). A genuinely different role-without-task spawn
will nudge once on its own. Escapes: inline bypass token [role-no-task-ok] in the prompt for a deliberate
one-off, or kill-switch THREE_ROLE_ATTRIBUTION_OFF=1 (or THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1).
</system-reminder>
EOF
exit 2
