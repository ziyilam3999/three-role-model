#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE MODEL-POLICY GATE (#1448, effective-tier sensor #1494, subagent_type
# effort-inert advisory #1513). A LEADING-EDGE advisory sibling of three-role-attribution-gate.sh (same
# PreToolUse(Agent|Task) seam, same BLOCK-ONCE shape). It catches a per-role model MISCONFIG at SPAWN time —
# before a whole role run is wasted on the wrong tier — while the HARD, load-bearing enforcement stays at
# completion time (three-role-instrumentation-gate.sh reads the forgery-resistant transcript model).
# Defense-in-depth, not the primary block: a requested-model signal is weaker than the transcript, so this leg
# is advisory (block-once), not a true wall.
#
# #1513 SUB-LEG (on the tier-satisfied path only): asserts that a tagged chain-role spawn actually used
# `subagent_type: cc-<ROLE>` when that dedicated definition IS installed. Per Invariant #6 lever 3, only the
# dedicated agents/cc-<ROLE>.md definition carries the `effort:` frontmatter that overrides inherited session
# effort — a chain role spawned as `general-purpose`/`claude` loads no such definition, so the role's
# configured effort is silently INERT even though its model TIER is correct (this is how 57/63 measured
# spawns rode the tier-satisfied silent-allow below undetected). CONDITIONAL on def-presence (`-f`, not `-L`
# — a dangling symlink reads as absent, the doctrine-sanctioned general-purpose fallback, never false-blocked)
# and INDEPENDENTLY KEYED ($SIG.effort-notified, distinct from $SIG.notified) so it can never be cannibalized
# by the tier-mismatch marker on a re-issue. See the design nuances inline below the tier-satisfied check.
#
# POLICY: config/cc-roles.env maps each role -> a model TIER (Option A: Opus on planner + both review gates,
# Sonnet on the executor). `resolve-role-model` reads it fail-SAFE to opus. So the violation condition is: the
# EFFECTIVE tier != the role's policy tier, where
#   effective = the requested tool_input.model if present, else the tier resolved by the EFFECTIVE-TIER SENSOR
#   (`resolve-effective-tier` in hooks/3role-ledger.mjs) reading the CURRENT session's own transcript tail —
#   never a hardcoded guess (#1494 — a badge-less spawn's effective tier used to be hardcoded to "opus", which
#   silently satisfied the opus seats' policy check under a Fable session while all four roles actually ran
#   Fable, across 19 tasks, in total silence).
# This fires ONLY when it matters (a non-opus seat left off-policy, or an explicit wrong tier) and stays SILENT
# on seats whose resolved effective tier already satisfies policy — no nudge-noise.
#
# RESPONSE DECISION: BLOCK-ONCE (exit 2, VISIBLE to the model — a PreToolUse hook's stderr reaches the agent
# only on exit 2; the #769 lesson). First time a given taskId+role violation SIGNATURE is seen -> exit 2 (the
# orchestrator SEES it + re-launches passing model:<tier>), drop a per-signature marker, then fall through to
# exit 0 on the re-issue so a deliberate spawn is NEVER permanently wedged. The sensor's can't-tell result
# (tier=unknown) is its OWN named block-once arm (below) — it is NEVER coerced to a concrete tier, and NEVER
# waved through as a silent allow (#1494's fail-closed direction: can't-tell must never satisfy an opus seat).
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
# CC_ROLES_ENV points resolve-role-model at a fixture config; CC_ROLE_AGENTS_DIR points the sensor's agent-def
# provenance lookup at a fixture dir (default ~/.claude/agents, never touched by the smoke); CC_TIER_SENSOR_TAIL_BYTES
# / CC_TIER_SENSOR_CAP_BYTES bound the sensor's transcript-tail read (see 3role-ledger.mjs). No `set -e` (a
# non-block non-zero must never leak into a permission decision — #749).
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/three-role-attribution-gate.sh (the block-once sibling),
# hooks/3role-ledger.mjs (resolve-role-model, resolve-effective-tier), the plans
# .ai-workspace/plans/2026-07-03-1448-per-role-model-policy.md and
# .ai-workspace/plans/2026-07-09-1494-effective-tier-sensor.md.

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
set -u

# Kill-switches (full exemption, no state mutation).
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-model-policy-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
if [ "${CC_ROLE_MODEL_GATE_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-model-policy-gate" "CC_ROLE_MODEL_GATE_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
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
# block-once SIGNATURE, PLUS (#1494) the payload's transcript_path (top-level — the MAIN session transcript,
# VERIFIED-present on an Agent-matcher PreToolUse payload; research capture
# .ai-workspace/research/2026-07-09-1494-agent-pretooluse-payload-capture.md) and tool_input.subagent_type, in
# ONE node pass. Emits the 6 sha1/sanitized fields space-joined on line 1 (unaffected by field content — none
# of the 6 legitimately contain whitespace), THEN transcript_path and subagent_type each on their OWN line
# (read separately below with `IFS= read -r`, NOT whitespace-split, so a path is never corrupted even if it
# somehow contained a space). "" on line 1 on a fatal parse error (-> fail-open). Reads the joined
# prompt+description+message field set (same bypass-form coverage as the attribution gate — #749).
ROLE=""; SESSION=""; TASKID=""; REQMODEL=""; BYPASS=""; SIG=""; TXPATH=""; SUBAGENT=""
{
  read -r ROLE SESSION TASKID REQMODEL BYPASS SIG
  IFS= read -r TXPATH
  IFS= read -r SUBAGENT
} < <(
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
    const txPath = (d.transcript_path==null?"":String(d.transcript_path)).replace(/\n/g,"");
    const subagentType = (ti.subagent_type==null?"":String(ti.subagent_type)).trim().replace(/\n/g,"");
    process.stdout.write([role, (session||"-"), taskId, model, bypass, sig].join(" ") + "\n" + txPath + "\n" + subagentType + "\n");
  ' 2>/dev/null
)

# Fatal parse error (node printed nothing) -> fail-open.
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

# EFFECTIVE tier (#1494): the requested model if present, else the EFFECTIVE-TIER SENSOR's read of the
# CURRENT session's own transcript tail — never a hardcoded guess. MODELARG is empty when no model: was
# passed (REQMODEL sentinel "-"). AGENTS_DIR is the agent-def provenance lookup dir (override for the smoke;
# defaults to the REAL installed agents dir, which the sensor only READS, never writes).
MODELARG=""
[ "$REQMODEL" != "-" ] && [ -n "$REQMODEL" ] && MODELARG="$REQMODEL"
AGENTS_DIR="${CC_ROLE_AGENTS_DIR:-$HOME/.claude/agents}"
TIER=""; SRCTOKEN=""; AGENTDEF=""
read -r TIER SRCTOKEN AGENTDEF < <(
  node "$LEDGER_HELPER" resolve-effective-tier \
    --model "$MODELARG" \
    --subagent-type "$SUBAGENT" \
    --transcript "$TXPATH" \
    --session "$SESSION" \
    --agents-dir "$AGENTS_DIR" 2>/dev/null
)
# Fail-CLOSED even on a sensor-invocation failure (empty stdout) — never fall back to a cheap/guessed tier.
EFFECTIVE="${TIER:-unknown}"

# --- named `unknown` branch (finding G) — the core fail-closed inversion of the #1494 bug: can't-determine
#     must NEVER silently satisfy an opus seat (or any seat). Its own block-once arm, same per-signature
#     marker mechanism as the policy-mismatch branch below (shared STATE_DIR/$SIG.notified — a genuinely
#     different taskId+role signature blocks again; the SAME spawn re-issued is not wedged). ---
if [ "$EFFECTIVE" = "unknown" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null
  find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null
  MARKER="$STATE_DIR/$SIG.notified"
  [ -f "$MARKER" ] && exit 0
  : > "$MARKER" 2>/dev/null
  cat >&2 <<EOF
<system-reminder>
THREE-ROLE MODEL-POLICY GATE (three-role-model-policy-gate hook, #1494 effective-tier sensor): role subagent
ROLE:${ROLE} for 3ROLE_TASK:${TASKID} is being spawned with an INDETERMINATE effective model tier — the sensor
could not read a last-assistant model from the session transcript (no transcript_path on the payload, an
unreadable/missing transcript file, or no last-assistant record within the bounded read window). cc-roles.env
policy for this role = ${EXPECTED}${EFFORT:+/${EFFORT}}. Because the effective tier cannot be verified, this
spawn is BLOCKED rather than silently assumed onto a default tier — a silent wrong-tier assumption is the
exact #1494 bug (it let 19 tasks run all four roles on Fable under a hardcoded opus guess). Re-launch passing
an EXPLICIT model tier to the Agent tool:
    model: ${EXPECTED}${EFFORT:+   (reasoning effort: ${EFFORT})}
(keep the 3ROLE_TASK:${TASKID} ROLE:${ROLE} tags). This is ADVISORY + block-once PER taskId+role: you will see
this ONCE for this spawn. Escapes: inline bypass token [model-policy-ok] in the prompt for a deliberate
one-off, or kill-switch CC_ROLE_MODEL_GATE_OFF=1 (or THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1).
</system-reminder>
EOF
  exit 2
fi

# Policy satisfied -> before silent-allowing, check the #1513 EFFORT-INERT sub-leg. A tagged chain-role spawn
# whose subagent_type is NOT `cc-<ROLE>` never loads the dedicated agents/cc-<ROLE>.md definition, so the
# role's configured EFFORT (Invariant #6 lever 3) is INERT -- the spawn silently runs at the SESSION's
# inherited effort instead. This sub-leg is CONDITIONAL on the dedicated definition being detectably present
# (`-f`, NOT `-L` -- a dangling/half-installed symlink must read as ABSENT, the sanctioned-fallback case, and
# must NEVER false-block; nuance A) and is INDEPENDENTLY KEYED (its own block-once marker, `$SIG.effort-notified`,
# distinct from `$SIG.notified` below) so a spawn that already fired the tier-mismatch advisory on a prior
# issue of this SAME taskId+role is never suppressed on re-issue by that unrelated marker (nuance C / AC-INDEP).
# An empty subagent_type is a malformed/edge payload -> fail-open, consistent with the hook's ambiguity-fail-
# open philosophy (nuance E / AC-EMPTY). ROLE:research is already excluded upstream (ROLE regex never matches
# it, so this line is unreached for research spawns -- nuance B / AC-RESEARCH).
if [ "$EFFECTIVE" = "$EXPECTED" ]; then
  CC_ROLE_DEF="$AGENTS_DIR/cc-$ROLE.md"
  if [ -n "$SUBAGENT" ] && [ "$SUBAGENT" != "cc-$ROLE" ] && [ -f "$CC_ROLE_DEF" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (shared with the tier marker).
    EFFORT_MARKER="$STATE_DIR/$SIG.effort-notified"
    # Already nudged for THIS taskId+role effort violation -> let the spawn proceed (block-once, not wedged).
    [ -f "$EFFORT_MARKER" ] && exit 0
    : > "$EFFORT_MARKER" 2>/dev/null
    cat >&2 <<EOF
<system-reminder>
THREE-ROLE MODEL-POLICY GATE (three-role-model-policy-gate hook, #1513 effort-inert advisory): role subagent
ROLE:${ROLE} for 3ROLE_TASK:${TASKID} is being spawned with subagent_type:${SUBAGENT}, which has NO
agents/cc-${ROLE}.md definition to inherit from. The dedicated definition IS installed (detected at
${CC_ROLE_DEF}), so this is a BYPASSED override, not the doctrine-sanctioned fallback. Because only the
cc-${ROLE} definition carries the effort: frontmatter that overrides inherited session effort, this
spawn's configured EFFORT${EFFORT:+ (${EFFORT})} is INERT -- it will silently run at the SESSION's inherited
effort instead of the role's policy effort (Invariant #6 lever 3). Re-launch passing the dedicated agent
definition:
    subagent_type: cc-${ROLE}
(keep model:${EXPECTED} and the 3ROLE_TASK:${TASKID} ROLE:${ROLE} tags). This is ADVISORY + block-once PER
taskId+role, INDEPENDENTLY KEYED from the model-tier advisory (a tier fix and an effort fix never suppress
each other): you will see this ONCE for this spawn. Escapes: inline bypass token [model-policy-ok] in the
prompt for a deliberate one-off, or kill-switch CC_ROLE_MODEL_GATE_OFF=1 (or THREE_ROLE_INSTRUMENT_OFF=1 /
SHIP_PIPELINE=1).
</system-reminder>
EOF
    exit 2
  fi
  exit 0
fi

# --- per-signature block-once marker ---
mkdir -p "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (mirrors the attribution gate).
MARKER="$STATE_DIR/$SIG.notified"
# Already nudged for THIS taskId+role violation -> let the spawn proceed (block-once, not wedged).
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null

# Human-readable source text for the block message (#1494: SRCTOKEN is the sensor's own source token).
case "$SRCTOKEN" in
  requested) SRC="requested (model:${REQMODEL})" ;;
  session)   SRC="the session's OWN transcript (the ACTUAL model this spawn will inherit — read, not assumed)" ;;
  *)         SRC="$SRCTOKEN" ;;
esac

# Fable cap-budget note when either side of the comparison is fable.
FABLE_NOTE=""
if [ "$EXPECTED" = "fable" ] || [ "$REQMODEL" = "fable" ]; then
  FABLE_NOTE="  Fable note: a capped seat (up to 50% of the weekly limit, not a deadline) at ~2x Opus API/usage-credit-billing rate. Use it for the highest-leverage plans, never a high-volume grunt seat."
fi

cat >&2 <<EOF
<system-reminder>
THREE-ROLE MODEL-POLICY GATE (three-role-model-policy-gate hook, #1448/#1494): role subagent ROLE:${ROLE} for
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
