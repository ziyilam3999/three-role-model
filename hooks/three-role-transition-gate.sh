#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE TRANSITION GATE (#851 PR2, Phase 3b). Enforces SEQUENCING of the
# 3-role model at SPAWN time: you cannot spawn the EXECUTOR for a task before the PLAN has been REVIEWED.
#
# Mechanism: the orchestrator prepends "3ROLE_TASK:<id> ROLE:<role>" to every role subagent's prompt (the same
# tag PR1's ledger + Phase 3a read). When an Agent/Task spawn carries ROLE:executor for task <id>, this gate
# BLOCKS (exit 2) unless a "plan-review" ledger line already exists for <id> in this session's role-ledger
# (~/.claude/3role-ledger/<session>/<id>.jsonl). That plan-review line is written either by the orchestrator
# (PR1) or harness-side by the SubagentStop writer (Phase 3a) when the plan-reviewer subagent stopped — so by
# the time you spawn the executor honestly, the line exists.
#
# HONEST LIMITATION (stated, not hidden): an UNTAGGED spawn (no 3ROLE_TASK / no ROLE) FAIL-OPENS (allow) — the
# gate cannot classify it, so it cannot sequence it. This is deliberate: the per-transition gate raises the
# floor, it does not make untagged bypass impossible. The COMPLETION gate (three-role-instrumentation-gate.sh,
# PR1) is the backstop — an untagged executor still cannot get the task marked done without a resolvable
# execution-review ledger line. Tagging is orchestrator-discipline; this gate enforces the ORDER once tagged.
#
# Only the EXECUTOR transition is gated. planner / plan-review / execution-review spawns are always ALLOWED
# (planner has no precondition; reviewer spawns must be free to run). Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1,
# SHIP_PIPELINE=1. Fail-open on any missing/unparseable state. No `set -e` (a non-block non-zero must not be
# read as a permission decision — #749 fail-closed-smoke lesson).
# PORT-NOTE: cites `parent-claude.md Invariant #2` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment/advisory only — nothing reads the file; safe forward-ref.
# Reference: parent-claude.md Invariant #2 ("the plan is reviewed by a STATELESS reviewer before execution"),
# hooks/3role-ledger.mjs (ledger format + THREE_ROLE_LEDGER_DIR), the plan #851 Phase 3b.

INPUT=$(cat)

# Kill-switches.
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# Parse tool_input.prompt (Agent) / fall back to tool_input.description (some Task shapes) + session_id, and
# extract the 3ROLE_TASK + ROLE tags. Emits: "<taskId> <role>" or "" when untagged (-> fail-open allow).
read -r TASKID ROLE SESSION < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    if(!mTask || !mRole){ process.stdout.write("- - "+(session||"-")); process.exit(0); }
    process.stdout.write(mTask[1] + " " + mRole[1].toLowerCase() + " " + (session||"-"));
  ' 2>/dev/null
)

# Untagged spawn -> FAIL-OPEN (allow). Honest limitation documented in the header + block msg.
[ -n "$TASKID" ] && [ "$TASKID" != "-" ] && [ -n "$ROLE" ] && [ "$ROLE" != "-" ] || exit 0

# Only the executor transition is sequenced. Other roles always allowed.
[ "$ROLE" = "executor" ] || exit 0

# A tagged executor spawn with no usable session cannot have its precondition verified — but a missing session
# on a real spawn is anomalous; fail-OPEN here (allow) and let the completion gate (which fails CLOSED on a
# tagged completion with no session) be the backstop. The transition gate only ever ADDS ordering on tagged
# spawns that carry a session.
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# Does a plan-review ledger line already exist for this task in this session? Read the ledger file directly
# (honors THREE_ROLE_LEDGER_DIR for the smoke); we do NOT call the helper's `check` (that requires ALL four
# roles — here we need ONLY the plan-review precondition). Emits "HAS" or "MISSING".
HAS_PLANREVIEW=$(
  SESSION_ENV="$SESSION" TASK_ENV="$TASKID" node -e '
    const fs=require("fs"), os=require("os"), path=require("path");
    const sanitize=(s)=> String(s==null?"":s).replace(/[^0-9A-Za-z._-]/g,"");
    const dir=process.env.THREE_ROLE_LEDGER_DIR || path.join(os.homedir(),".claude","3role-ledger");
    const f=path.join(dir, sanitize(process.env.SESSION_ENV), sanitize(process.env.TASK_ENV)+".jsonl");
    let txt=""; try{ txt=fs.readFileSync(f,"utf8"); }catch(e){ process.stdout.write("MISSING"); process.exit(0); }
    for(const ln of txt.split("\n")){ if(!ln.trim()) continue; try{ const j=JSON.parse(ln); if(j && j.role==="plan-review"){ process.stdout.write("HAS"); process.exit(0); } }catch(e){} }
    process.stdout.write("MISSING");
  ' 2>/dev/null
)

if [ "$HAS_PLANREVIEW" = "HAS" ]; then
  exit 0
fi

# BLOCK: executor spawn before the plan was reviewed.
{
  echo "THREE-ROLE TRANSITION GATE (three-role-transition-gate): cannot spawn the EXECUTOR for task #${TASKID} yet."
  echo "  No 'plan-review' ledger line exists for #${TASKID} in this session (${SESSION})."
  echo "  The 3-role model requires the PLAN to be reviewed by a STATELESS reviewer BEFORE execution"
  echo "  (parent-claude.md Invariant #2). Run the plan-review role first (spawn an Explore reviewer tagged"
  echo "    3ROLE_TASK:${TASKID} ROLE:plan-review"
  echo "  — the SubagentStop ledger writer records it on stop, or append it explicitly:"
  echo "    node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" append --session ${SESSION} --task ${TASKID} --role plan-review --agent <agentId> --artifact <plan-or-review-path>"
  echo "  If #${TASKID} is a LEG of a parent plan that was ALREADY reviewed, INHERIT that review instead"
  echo "  (verified — it fails closed unless the parent has a real, transcript-backed plan-review):"
  echo "    node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" inherit-plan-review --session ${SESSION} --task ${TASKID} --parent <parentTaskId>"
  echo "  then re-spawn the executor)."
  echo "  Honest limitation: an UNTAGGED spawn dodges this gate (it can't be classified) — the completion gate"
  echo "    (three-role-instrumentation-gate.sh) is the backstop. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1 (or SHIP_PIPELINE=1)."
} >&2
exit 2
