#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE TRANSITION GATE (#851 PR2, Phase 3b; hardened #1575). Enforces
# SEQUENCING of the 3-role model at SPAWN time: you cannot spawn the EXECUTOR for a task before the PLAN has
# been REVIEWED — and "reviewed" now means a COMPLETED review carrying an AFFIRMATIVE verdict, not merely a
# ledger LINE.
#
# Mechanism: the orchestrator prepends "3ROLE_TASK:<id> ROLE:<role>" to every role subagent's prompt (the same
# tag PR1's ledger + Phase 3a read). When an Agent/Task spawn carries ROLE:executor for task <id>, this gate
# shells out to `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" gate-plan-review --session <session> --task <id>` — the SAME
# evaluator a node-level smoke exercises directly, so there is ONE implementation of the admission contract,
# not two. That evaluator reads the LAST PARSEABLE plan-review line, fail-closes on trailing junk, runs a
# universal verdict ALLOWLIST screen, then dispatches to exactly two sanctioned arms:
#   (1) completed-review — affirmative verdict + closedAt (the SubagentStop punch-out) + an agentId whose
#       transcript is SPAWN-RECORD-bound (its FIRST record, not merely a later mention) to
#       `3ROLE_TASK:<id> ROLE:plan-review`;
#   (2) inherited-review — `inherited_from` + agentId + artifact_path, with the agentId PARENT-bound the same
#       way, keyed on the row's own `inherited_from`.
# #1575 (operator decision, round 3): there is NO skip arm at this gate any more — a `skip_reason`-only line,
# however specific, does NOT satisfy the executor precondition. A genuinely session-coupled lane runs its
# executor INLINE (untagged; see the honest limitation below) and never meets this gate.
#
# #1575 D1/round-4: the "bound" test opens ONLY the CITED agentId's own transcript and reads its SPAWN
# RECORD — never a whole-file substring scan (which binds to MENTIONS, e.g. a plan-review tag arriving in a
# planner's transcript via the plan's own required `## Review` byline — measured 4-of-7 on a real session) and
# never a newest-mtime "winner" search (a contaminated, newer sibling transcript must never decide another
# row's binding).
#
# HONEST LIMITATION (stated, not hidden): an UNTAGGED spawn (no 3ROLE_TASK / no ROLE) FAIL-OPENS (allow) — the
# gate cannot classify it, so it cannot sequence it. This is deliberate: the per-transition gate raises the
# floor, it does not make untagged bypass impossible. The COMPLETION gate (three-role-instrumentation-gate.sh,
# PR1) is the backstop — an untagged executor still cannot get the task marked done without a resolvable
# execution-review ledger line. Tagging is orchestrator-discipline; this gate enforces the ORDER once tagged.
# Nothing in the ledger is unforgeable (every field has a plain CLI flag) — this gate closes the one-command
# SHORTCUTS (the backgrounded-dispatch race, the convenience skip, the quiet downgrade via skip/inherit/flip,
# the mention-borrowed agentId), never a determined forger who actually spawns a real reviewer and forges its
# verdict before it returns (the named residual — see the #1575 plan's `Deferred-follow-ups:`).
#
# Only the EXECUTOR transition is gated. planner / plan-review / execution-review spawns are always ALLOWED
# (planner has no precondition; reviewer spawns must be free to run). Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1,
# SHIP_PIPELINE=1. Fail-open on any missing/unparseable state. No `set -e` (a non-block non-zero must not be
# read as a permission decision — #749 fail-closed-smoke lesson).
# PORT-NOTE: cites `parent-claude.md Invariant #2` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment/advisory only — nothing reads the file; safe forward-ref.
# Reference: parent-claude.md Invariant #2 ("the plan is reviewed by a STATELESS reviewer before execution"),
# hooks/3role-ledger.mjs (ledger format + THREE_ROLE_LEDGER_DIR + gate-plan-review), the plan #851 Phase 3b,
# and .ai-workspace/plans/2026-07-11-1575-spawn-gate-integrity.md (the hardening).

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
INPUT=$(cat)

# Kill-switches.
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-transition-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
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

# #1575 — the ENTIRE plan-review-admission decision lives in `gate-plan-review` (hooks/3role-ledger.mjs):
# last-parseable-line semantics, trailing-junk fail-closed, the universal verdict allowlist screen, and the
# two sanctioned arms (completed-review / inherited-review), each spawn-record-bound to the CITED agentId
# (never a whole-file mention scan, never a newest-mtime "winner"). This hook is a thin caller so there is
# exactly ONE implementation of the contract — node-level smokes exercise `gate-plan-review` directly, and
# this bash smoke exercises it through the real hook.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LED_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LED_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
GATE_STDERR=$(node "$LED_HELPER" gate-plan-review --session "$SESSION" --task "$TASKID" 2>&1 >/dev/null)
GATE_RC=$?

if [ "$GATE_RC" = "0" ]; then
  exit 0
fi

# BLOCK: the ledger has no COMPLETED, AFFIRMATIVE plan-review for this task yet. $GATE_STDERR names the
# specific evidence class that failed (not-finished / no-verdict / negative-verdict / no-bound-reviewer-spawn /
# inherited-row-unbound-to-parent / deliberate-skip-closed / junk-line) plus the ledger file + line evaluated
# (a misconfigured THREE_ROLE_LEDGER_DIR is otherwise silently permissive-looking and undiagnosable).
{
  echo "THREE-ROLE TRANSITION GATE (three-role-transition-gate): cannot spawn the EXECUTOR for task #${TASKID} yet."
  echo "  No COMPLETED, AFFIRMATIVE plan-review verdict is recorded for #${TASKID} in this session (${SESSION})."
  echo "  ${GATE_STDERR}"
  echo "  The 3-role model requires the PLAN to be reviewed by a STATELESS reviewer BEFORE execution, and that"
  echo "  review must FINISH with an affirmative verdict (parent-claude.md Invariant #2). The reviewer — not the"
  echo "  orchestrator — records its verdict. Run the plan-review role and let it complete honestly:"
  echo "    node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" append --session ${SESSION} --task ${TASKID} --role plan-review \\"
  echo "      --agent <agentId> --artifact <plan-or-review-path> --verdict PASS --closed-at <ISO-8601-timestamp>"
  echo "  If #${TASKID} is a LEG of a parent plan whose plan-review already PASSED, inherit it instead (fails"
  echo "  closed unless the parent has a real, transcript-backed, AFFIRMATIVE plan-review that names this leg):"
  echo "    node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" inherit-plan-review --session ${SESSION} --task ${TASKID} --parent <parentTaskId>"
  echo "  then re-spawn the executor. There is NO skip path for plan-review at this gate (operator decision) —"
  echo "  a deliberate skip cannot satisfy this precondition, however specific the reason."
  echo "  Honest limitation: an UNTAGGED spawn dodges this gate (it can't be classified) — the completion gate"
  echo "    (three-role-instrumentation-gate.sh) is the backstop. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1 (or SHIP_PIPELINE=1)."
} >&2
exit 2
