#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE MODEL-POLICY GATE (#1448). A LEADING-EDGE advisory sibling of
# three-role-attribution-gate.sh (same PreToolUse(Agent|Task) seam, same BLOCK-ONCE shape). It catches a
# per-role model MISCONFIG at SPAWN time — before a whole role run is wasted on the wrong tier — while the
# HARD, load-bearing enforcement stays at completion time (three-role-instrumentation-gate.sh reads the
# forgery-resistant transcript model). Defense-in-depth, not the primary block: a requested-model signal is
# weaker than the transcript, so this leg is advisory (block-once), not a true wall.
#
# POLICY: config/cc-roles.env maps each role -> a model TIER (Option A: Opus on planner + both review gates,
# Sonnet on the executor). `resolve-role-model` reads it fail-SAFE to opus. Today a role spawn carries
# model=(none) and INHERITS the session model (Opus) — correct for the opus seats, WRONG for the executor
# (should be Sonnet). So the violation condition is: the EFFECTIVE tier != the role's policy tier, where
#   effective = the requested tool_input.model if present, else "opus" (the documented session default).
# This fires ONLY when it matters (a non-opus seat left at the Opus default, or an explicit wrong tier) and
# stays SILENT on the majority opus seats whose absent-model default already satisfies policy — no nudge-noise.
#
# RESPONSE DECISION: BLOCK-ONCE (exit 2, VISIBLE to the model — a PreToolUse hook's stderr reaches the agent
# only on exit 2; the #769 lesson). First time a given taskId+role violation SIGNATURE is seen -> exit 2 (the
# orchestrator SEES it + re-launches passing model:<tier>), drop a per-signature marker, then fall through to
# exit 0 on the re-issue so a deliberate spawn is NEVER permanently wedged.
#
# EVERYTHING ELSE FAIL-OPENS (exit 0 silent): not a tagged role spawn (no 3ROLE_TASK + ROLE), policy satisfied,
# no resolvable policy (helper/config absent), parse error, no session. A bare Agent spawn with no model is the
# NORM and must never be false-blocked.
#
# BLOCK-ONCE keying: sha1(session + ":" + taskId + ":" + role) — per taskId+role (the plan's "block-once per
# taskId+role"). A genuinely different role OR task violation has a different signature and blocks again.
#
# Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1 (uniform family) OR CC_ROLE_MODEL_GATE_OFF=1 (dedicated feature
# switch, SAME one the completion-time model leg honors) OR SHIP_PIPELINE=1 (ship-pipeline exempt). Inline
# bypass token `[model-policy-ok]` in the prompt -> exit 0 for a deliberate one-off.
#
# Env overrides (for the smoke): CC_ROLE_MODEL_POLICY_STATE_DIR (default ~/.claude/.three-role-model-policy-state);
# CC_ROLES_ENV points resolve-role-model at a fixture config. No `set -e` (a non-block non-zero must never leak
# into a permission decision — #749).
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/three-role-attribution-gate.sh (the block-once sibling),
# hooks/3role-ledger.mjs (resolve-role-model), the plan .ai-workspace/plans/2026-07-03-1448-per-role-model-policy.md.

set -u

# Kill-switches (full exemption, no state mutation).
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0
[ "${CC_ROLE_MODEL_GATE_OFF:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

STATE_DIR="${CC_ROLE_MODEL_POLICY_STATE_DIR:-$HOME/.claude/.three-role-model-policy-state}"
TTL_DAYS="${CC_ROLE_MODEL_POLICY_TTL_DAYS:-14}"

INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Resolve the ledger helper (config logic lives there — this hook stays thin). Sibling flat file whether run
# from the repo or the ~/.claude/hooks/ symlink; the plugin sync rewrites this line to a ${CLAUDE_PLUGIN_ROOT}/bin block.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi

# Parse role, session, taskId, the requested model (lowercased tier), the inline bypass token, and the
# block-once SIGNATURE in ONE node pass. Emits "<role|-> <session|-> <taskId|-> <model|-> <bypass 0|1> <sig>"
# or "" on a fatal parse error (-> fail-open). Reads the joined prompt+description+message field set (same
# bypass-form coverage as the attribution gate — #749).
read -r ROLE SESSION TASKID REQMODEL BYPASS SIG < <(
  HOOK_INPUT="$INPUT" node -e '
    const crypto=require("crypto");
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    const role = mRole ? mRole[1].toLowerCase() : "-";
    const taskId = mTask ? mTask[1] : "-";
    const model = (ti.model==null?"":String(ti.model)).trim().toLowerCase().replace(/[^0-9a-z._-]/g,"") || "-";
    const bypass = /\[model-policy-ok\]/i.test(prompt) ? "1" : "0";
    const sig=crypto.createHash("sha1").update((session||"-")+":"+(taskId||"-")+":"+role).digest("hex");
    process.stdout.write([role, (session||"-"), taskId, model, bypass, sig].join(" "));
  ' 2>/dev/null
)

# Fatal parse error (node printed "") -> fail-open.
[ -n "$SIG" ] || exit 0
# Inline bypass -> exit 0 (deliberate one-off), even on a real violation.
[ "$BYPASS" = "1" ] && exit 0
# Not a tagged role spawn -> fail-open (the norm). Need BOTH the role AND a real task tag to attribute a policy.
[ "$ROLE" != "-" ] || exit 0
[ "$TASKID" != "-" ] || exit 0
# No usable session cannot be keyed reliably -> fail-open (the completion gate is the backstop).
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# Resolve the role's policy tier (+ effort) — fail-OPEN if the helper/config is unavailable (never block on
# infra). resolve-role-model fails SAFE to opus and always exits 0, so an empty EXPECTED means the helper
# itself is missing (not "policy is opus").
[ -f "$LEDGER_HELPER" ] || exit 0
read -r EXPECTED EFFORT < <(node "$LEDGER_HELPER" resolve-role-model --role "$ROLE" --with-effort 2>/dev/null)
[ -n "${EXPECTED:-}" ] || exit 0

# EFFECTIVE tier: the requested model if present, else the inherited session default (Opus today).
if [ "$REQMODEL" != "-" ] && [ -n "$REQMODEL" ]; then
  EFFECTIVE="$REQMODEL"; SRC="requested (model:${REQMODEL})"
else
  EFFECTIVE="opus"; SRC="inherited (no model: passed -> the session model, Opus)"
fi

# Policy satisfied -> silent allow. This is what keeps the opus seats quiet on an absent model.
[ "$EFFECTIVE" = "$EXPECTED" ] && exit 0

# --- per-signature block-once marker ---
mkdir -p "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (mirrors the attribution gate).
MARKER="$STATE_DIR/$SIG.notified"
# Already nudged for THIS taskId+role violation -> let the spawn proceed (block-once, not wedged).
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null

# Fable cost-cliff note when either side of the comparison is fable.
FABLE_NOTE=""
if [ "$EXPECTED" = "fable" ] || [ "$REQMODEL" = "fable" ]; then
  FABLE_NOTE="  Fable note: ~2x Opus and its subsidised bar expires ~July 7-8 — after that a Fable seat bills out-of-pocket. Use it only for the hardest one-off plans."
fi

cat >&2 <<EOF
<system-reminder>
THREE-ROLE MODEL-POLICY GATE (three-role-model-policy-gate hook, #1448): role subagent ROLE:${ROLE} for
3ROLE_TASK:${TASKID} is being spawned on the WRONG model tier. cc-roles.env policy = ${EXPECTED}${EFFORT:+/${EFFORT}}, but
this spawn's effective tier is ${EFFECTIVE} [${SRC}]. Re-launch passing the policy tier to the Agent tool:
    model: ${EXPECTED}${EFFORT:+   (reasoning effort: ${EFFORT})}
(prepend nothing else — keep the 3ROLE_TASK:${TASKID} ROLE:${ROLE} tags). The HARD block is at completion time
(the instrumentation gate reads the actual transcript model); this leading-edge nudge just saves a wasted run.
${FABLE_NOTE:+${FABLE_NOTE}
}This is ADVISORY + block-once PER taskId+role: you will see this ONCE for this spawn. Re-launch with the
right model to proceed (you will NOT be blocked again for this same spawn). Escapes: inline bypass token
[model-policy-ok] in the prompt for a deliberate one-off, or kill-switch CC_ROLE_MODEL_GATE_OFF=1 (or
THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1).
</system-reminder>
EOF
exit 2
