#!/usr/bin/env bash
# PostToolUse(Agent|Task) + PreToolUse(Agent|Task) hook — THREE-ROLE SPAWN LEDGER WRITER (#1187, #1516).
# Spawn/launch-time corroboration:
# the instant a tagged role subagent is launched, write its {role[, agentId]} line to the per-task role-ledger
# so an IN-FLIGHT role is visible on the board WITHOUT anyone running the manual CLI. This is the SPAWN-time
# complement to three-role-subagent-ledger.sh (SubagentStop) — they overlay-merge (idempotent per role): #1187
# gives EARLY visibility, SubagentStop gives the AUTHORITATIVE agentId + self_authored provenance at stop.
#
# It is a side-effect WRITER, never a gate: it exits 0 on EVERY path (a PostToolUse exit-2 cannot steer the
# spawn that already ran; recording is all it does). Fail-OPEN on any parse/extract error -> no append.
#
# THE LOAD-BEARING SPLIT (why this is SAFE): #1187 writes ONLY {role[, agentId]} — NEVER --artifact. The
# artifact path is written by the role itself at CLOSE (the #1100 self-record flow), to a STABLE committed
# path; because #1187 passes no --artifact it can NEVER write a worktree-relative path that dangles at
# quarantine (the #897 hazard fires only when --artifact matches /\.claude\/worktrees\//). The ledger's
# overlay-merge (3role-ledger.mjs overlayAppend) composes the later artifact-at-close line ONTO this
# spawn-time line without either writer clobbering the other (#855) — order-independent.
#
# AGENTID at PostToolUse — HONEST EVIDENCE GAP (Rule 18): the exact JSON path of an agentId inside
# `tool_response` is NOT byte-confirmed by a live probe in this build (a swept sample of on-disk transcripts
# did not surface a structured agentId key in a PostToolUse-Agent tool_response). So this hook uses a
# DEFENSIVE multi-source extractor over tool_response and DEGRADES GRACEFULLY:
#   - agentId FOUND  -> append {role, agentId} at spawn (full early-agentId win).
#   - agentId ABSENT -> append a {role}-only placeholder (early "which roles are running" visibility); the
#                       SubagentStop writer overlay-merges the authoritative agentId at stop. Still a net win,
#                       no new agentId source invented.
# The degraded {role}-only line is NOT sufficient for completion by itself — it relies on SubagentStop /
# self-record to fill agentId + artifact (plan-review confirmation #3). When the probe pins the real path,
# add it as source (a) below; the extractor already survives whichever shape it reveals.
#
# TIMING (honest, not oversold — rewritten #1516, was overstated as "removes the manual-CLI requirement,
# early win realized mainly for backgrounded spawns"): this hook now fires on TWO edges with DIFFERENT
# scopes, and the timing story is different on each.
#   - PostToolUse (the four chain roles + research): fires when the tool call RETURNS. For a FOREGROUND
#     spawn that is COMPLETION (≈ the same moment as SubagentStop) — the "early" win is realized only for a
#     run_in_background spawn, where PostToolUse fires at DISPATCH. Unchanged since #1187.
#   - PreToolUse (research ONLY — #1516): fires at DISPATCH, always, foreground or backgrounded. This is
#     what makes a research row genuinely MID-FLIGHT-visible: the badge renders the instant the spawn is
#     sent, carrying the role's ASSIGNED {tier, effort, version}, not just at completion.
#   Chain roles are DELIBERATELY excluded from the PreToolUse edge (a chain-role PreToolUse payload writes
#   NOTHING — see the load-bearing `hookEvent==="PreToolUse" && role!=="research"` no-op above). Moving a
#   chain role's row to dispatch-time would let a spawn's mere EXISTENCE satisfy
#   three-role-transition-gate.sh's presence-only plan-review check before the review ever ran — defeating a
#   fail-closed gate. Research has no such gate reading it (see the plan's "why a phantom research row is
#   genuinely harmless" section), so it is the one role safe to move earlier.
#
# Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1 (uniform family switch) OR THREE_ROLE_SPAWN_LEDGER_OFF=1 (dedicated).
# Tag regexes are the EXACT sibling enum-anchored forms (group [1]) — see three-role-transition-gate.sh:39-40
# and three-role-subagent-ledger.sh:95,99 (both stay the FOUR-role form; only THIS hook's role alternation
# is widened to include "research" — #1516). No `set -e` (a recorder must never let a non-zero leak into a
# decision — #749). Env overrides for the smoke: THREE_ROLE_LEDGER_DIR, THREE_ROLE_PROJECTS_ROOT.
#
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/3role-ledger.mjs (append + overlay-merge), the plans
# `.ai-workspace/plans/2026-06-24-1185-1187-spawn-ledger-hooks.md` and
# `.ai-workspace/plans/2026-07-11-1516-research-spawn-ledger.md`.

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
INPUT=$(cat)

# Kill-switches.
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-spawn-ledger" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
if [ "${THREE_ROLE_SPAWN_LEDGER_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-spawn-ledger" "THREE_ROLE_SPAWN_LEDGER_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi

command -v node >/dev/null 2>&1 || exit 0

# Parse: tags from tool_input.prompt (+ .description, .message, joined), session_id, and the agentId via a
# DEFENSIVE multi-source extractor over tool_response. Emits "<taskId> <role> <session> <agentId>" (each "-"
# when absent) or "" when the task tag is absent, no role can be resolved (tag NOR subagent_type==cc-research),
# OR (#1516) the event is PreToolUse and the resolved role is not "research" (-> no-op). R2-PINNED regex: the
# EXACT sibling form /ROLE:\s*(planner|...)/i with the role at capture group [1] — NO left-boundary variant
# (one form only) — #1516 widens the alternation to include "research", nothing else.
read -r TASKID ROLE SESSION AGENTID < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    // #1516 -- widened to include "research" (was the four chain roles only). A ROLE:research tag is the
    // PRIMARY signal (mechanism belt #1: the tag).
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor|research)/i);
    // require the task tag always; else un-attributable -> no-op (parent prints "").
    if(!mTask){ process.exit(0); }
    let role = mRole ? mRole[1].toLowerCase() : "";
    // #1516 mechanism belt #2: a spawn that used the cc-research agent definition but omitted the ROLE
    // token still files a row when the task id is present -- tool_input.subagent_type is an OBSERVABLE
    // field on this payload (captured on disk, read in production by three-role-model-policy-gate.sh).
    // Fail-open to tag-only: if subagent_type is absent/other, role stays whatever the tag resolved (or "").
    if(!role){
      const stype=String(ti.subagent_type||"").toLowerCase();
      if(stype==="cc-research") role="research";
    }
    if(!role){ process.exit(0); }
    // #1516 -- THE LOAD-BEARING LINE. hook_event_name is the NAMED edge discriminator (present on the
    // captured payload). On a PreToolUse event, ONLY the research seat may write -- a chain-role spawn
    // caught here writes NOTHING. This is what keeps three-role-transition-gate.sh fail-closed: moving the
    // recorder to PreToolUse for chain roles would let a dispatched-but-never-run plan-review satisfy the
    // gate on intent alone (see the plan'\''s "why PreToolUse is safe" section). Do NOT widen this to any
    // other role, ever.
    const hookEvent=String(d.hook_event_name||"");
    if(hookEvent==="PreToolUse" && role!=="research"){ process.exit(0); }

    // --- DEFENSIVE multi-source agentId extractor over tool_response (string OR object). ---
    const tr=d.tool_response;
    let agent="";
    const clean=(s)=> String(s==null?"":s).replace(/[^0-9A-Za-z_-]/g,"");
    // (a) structured keys (the probe will pin the real one here; harmless if absent).
    if(tr && typeof tr==="object"){
      const cands=[tr.agentId, tr.agent_id,
                   (tr.agent&&tr.agent.id), (tr.subagent&&tr.subagent.id),
                   tr.agentID, tr.id];
      for(const c of cands){ if(c){ agent=clean(c); if(agent) break; } }
    }
    // (b) regex over the STRINGIFIED tool_response: an agentId/agent_id label then a hex/uuid-ish token.
    if(!agent){
      let s=""; try{ s=(typeof tr==="string")? tr : JSON.stringify(tr||""); }catch(e){ s=""; }
      const m=s.match(/agent[_-]?id["'"'"'\s:=]+["'"'"']?([0-9a-fA-F][0-9a-fA-F_-]{6,})/);
      if(m) agent=clean(m[1]);
      // (b2) a bare subagents/agent-<id>.jsonl path occasionally echoed back in the response.
      if(!agent){ const m2=s.match(/subagents\/agent-([0-9A-Za-z_-]+)\.jsonl/); if(m2) agent=clean(m2[1]); }
    }
    // (c) empty -> degrade to {role}-only.
    process.stdout.write(mTask[1] + " " + role + " " + (session||"-") + " " + (agent||"-"));
  ' 2>/dev/null
)

# BOTH tags absent (node printed "") -> no-op.
[ -n "$TASKID" ] && [ -n "$ROLE" ] || exit 0
# A spawn with no usable session cannot be filed -> no-op (fail-open).
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

HOOK_DIR="$(dirname "${BASH_SOURCE[0]}")"
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
[ -f "$HELPER" ] || exit 0

# #1466 — resolve the role's ASSIGNED {tier, effort, version} via the SAME resolver the model-policy gate and
# the orchestrator use (config/cc-roles.env, fail-safe to opus), and stamp it onto THIS spawn-time line. This
# is what makes the badge render WHILE the role is still running (a non-empty modelVersion is all cardModel()
# needs) with the role's OWN policy effort — NOT the orchestrator's inherited session effort (the bug this
# fixes: the prior stamp came from process.env.CLAUDE_EFFORT, i.e. the ORCHESTRATOR's effort). Fail-open: a
# helper error leaves all three at the "-" sentinel, so nothing extra is passed and today's degraded-but-safe
# {role}-only or {role,agentId} line still gets written below.
ATIER="-"; AEFFORT="-"; AVERSION="-"
read -r ATIER AEFFORT AVERSION < <(node "$HELPER" resolve-role-model --role "$ROLE" --with-effort --with-version 2>/dev/null)
[ -n "${ATIER:-}" ] || ATIER="-"
[ -n "${AEFFORT:-}" ] || AEFFORT="-"
[ -n "${AVERSION:-}" ] || AVERSION="-"
ASSIGNED_FLAGS=""
[ "$ATIER" != "-" ] && ASSIGNED_FLAGS="$ASSIGNED_FLAGS --model-tier $ATIER"
[ "$AVERSION" != "-" ] && ASSIGNED_FLAGS="$ASSIGNED_FLAGS --model-version $AVERSION"
[ "$AEFFORT" != "-" ] && ASSIGNED_FLAGS="$ASSIGNED_FLAGS --effort $AEFFORT"

# Append. NEVER --artifact (no path -> no dangle; artifact composes later via overlay-merge). Pass --agent
# ONLY when an agentId was extracted; otherwise the degraded {role}-only line (SubagentStop fills agentId).
# Always pass the ASSIGNED_FLAGS resolved above (when resolvable) so the badge renders the instant this line
# lands, carrying the role's OWN policy values.
if [ -n "$AGENTID" ] && [ "$AGENTID" != "-" ]; then
  node "$HELPER" append --session "$SESSION" --task "$TASKID" --role "$ROLE" --agent "$AGENTID" $ASSIGNED_FLAGS >/dev/null 2>&1
else
  node "$HELPER" append --session "$SESSION" --task "$TASKID" --role "$ROLE" $ASSIGNED_FLAGS >/dev/null 2>&1
fi

# Both append branches merge here. Resync the live board on this AUTOMATED write
# edge so the role BADGE refreshes the instant the ledger line lands — the gap
# #1354 closes (the Bash-matcher resync hook never saw this internal node spawn).
# The helper backgrounds the real sync internally, so the spawn path takes no
# added latency; it is fail-open and always exits 0, so it can never block the
# spawn. A SINGLE post-block call covers BOTH append branches by control-flow
# merge. Co-symlinked next to this hook by setup.sh's flat-file loop. Guarded by
# a presence test so the ported plugin copy (which does NOT carry this machine-local
# agent-kanban helper) fails open cleanly instead of erroring on a missing file.
[ -f "$HOOK_DIR/kanban-resync.sh" ] && bash "$HOOK_DIR/kanban-resync.sh"

exit 0
