#!/usr/bin/env bash
# SubagentStop hook — THREE-ROLE SUBAGENT LEDGER WRITER (#851 PR2, Phase 3a). Harness-driven corroboration:
# every time a REAL role subagent stops, the harness has already written its transcript
# (~/.claude/projects/*/<session>/subagents/agent-<agentId>.jsonl). This hook reads the stopping subagent's
# transcript and, when its brief carries the 3ROLE_TASK tag, appends a per-task role-ledger line for that
# task/role/agentId — WITHOUT the orchestrator having to remember to write it. It is a side-effect WRITER,
# never a gate: it exits 0 on every path (a Stop hook that only emits exit-0 stderr cannot steer the model;
# steering is the COMPLETION gate's job — this just records).
#
# Why this exists (the #850 leg, harness-side): the role agent self-records its OWN {role, artifact} line
# (#1100), but the agentId is harness-only. This hook is the AUTHORITATIVE agentId writer (#1100 item 2,
# promoted from best-effort backup): it overlay-merges {agentId} onto the agent-authored line (#855) the
# instant the subagent stops — forgery-resistant because the transcript file only exists if a real spawn
# happened. It ALSO stamps self_authored:true (#1100 item 3) when the transcript shows the agent's own
# self-append for this role, so `check` can flag orchestrator-fabricated (un-self-authored) lines.
#
# Fire conditions (ALL must hold, else no-op exit 0 writing nothing):
#   (a) the RESOLVED subagent transcript (agent_transcript_path when present, else transcript_path) contains
#       "/subagents/agent-"  — i.e. it IS a subagent, not the main session's own Stop (a main-session Stop has no
#       agent_transcript_path AND its transcript_path is not under /subagents/ -> no-op). #857: the real payload
#       puts the subagent transcript in agent_transcript_path; transcript_path is the MAIN session.
#   (b) the subagent's brief (first type:user message) carries "3ROLE_TASK:<id>".
# Then: agentId <- payload agent_id (else transcript filename); role <- "ROLE:<role>" in the brief (AUTHORITATIVE) else keyword-classify
# (corroboration only — plan-review > planner > execution-review > executor, longest-match-first). Append via
# the flat sibling helper 3role-ledger.mjs (idempotent PER ROLE — re-stop does not duplicate).
#
# Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1. (No SHIP_PIPELINE gate needed — a pure recorder during /ship is
# harmless; but we honor THREE_ROLE_INSTRUMENT_OFF so the whole instrumentation can be switched off uniformly.)
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/3role-ledger.mjs (the helper), the cairn 2026-05-28 lesson
# (SubagentStop fires once PER subagent -> writer must be idempotent + cheap; we no-op fast before any file read
# when untagged).
#
# Env overrides (for the smoke): THREE_ROLE_LEDGER_DIR, THREE_ROLE_PROJECTS_ROOT are passed through to the helper.
#
# #1516 — this is also the ONLY writer that stamps the EXPLICIT `closedAt` field (an ISO timestamp, passed
# via 3role-ledger.mjs's --closed-at flag) — because this hook fires exclusively at a real SubagentStop, it
# is the one trustworthy place to say "this role is truly done". The research seat's agent-kanban board
# punch-out depends on this stamp being close-exclusive (never inferred from agentId, which can also be
# present at spawn/dispatch for a backgrounded role — see the #1516 plan's rationale).

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
INPUT=$(cat)

# Kill-switch (uniform with the sibling gates).
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-subagent-ledger" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi

# Parse the SubagentStop payload. The REAL payload carries TWO transcript fields: `agent_transcript_path` is the
# stopping SUBAGENT's own transcript (…/subagents/agent-<id>.jsonl) and `transcript_path` is the MAIN session's
# transcript (NOT under /subagents/). We PREFER agent_transcript_path; fall back to transcript_path ONLY when
# agent_transcript_path is absent/empty (back-compat with old fixtures + a main-session Stop). The payload also
# carries `agent_id` directly — prefer it for the agentId; fall back to the filename parse below when absent.
read -r TRANSCRIPT SESSION PAYLOAD_AGENTID PAYLOAD_EFFORT < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const atp=(d.agent_transcript_path||"").toString();
    const tp=(atp!=="" ? atp : (d.transcript_path||"").toString());
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const aid=(d.agent_id||"").toString().replace(/[^0-9A-Za-z_-]/g,"");
    // #1466 -- the OBSERVED reasoning-effort signal on a SubagentStop payload: a nested effort.level string
    // (the harness'\''s own record of what the STOPPING subagent actually ran at -- not the transcript, which
    // never carries it). Absent/malformed -> "" (fail-open; the append below then omits --effort entirely).
    const eff=(d.effort && typeof d.effort.level==="string") ? d.effort.level : "";
    const enc=(s)=> (s===""? "-" : encodeURIComponent(s));
    process.stdout.write([enc(tp), session||"-", aid||"-", enc(eff)].join(" "));
  ' 2>/dev/null
)
dec(){ [ "$1" = "-" ] && { printf ''; return; }; printf '%b' "${1//%/\\x}"; }
TRANSCRIPT="$(dec "$TRANSCRIPT")"
[ "$PAYLOAD_AGENTID" = "-" ] && PAYLOAD_AGENTID=""
PAYLOAD_EFFORT="$(dec "$PAYLOAD_EFFORT")"

# (a) must be a SUBAGENT transcript. No-op otherwise (main-session Stop shape / unparseable).
case "$TRANSCRIPT" in
  *"/subagents/agent-"*) : ;;
  *) exit 0 ;;
esac
[ -f "$TRANSCRIPT" ] || exit 0

# agentId: PREFER the payload's agent_id; fall back to the filename .../subagents/agent-<id>.jsonl
if [ -n "$PAYLOAD_AGENTID" ]; then
  AGENTID="$PAYLOAD_AGENTID"
else
  BASE="$(basename "$TRANSCRIPT")"
  AGENTID="${BASE#agent-}"; AGENTID="${AGENTID%.jsonl}"
  AGENTID="$(printf '%s' "$AGENTID" | tr -cd '0-9A-Za-z_-')"
fi
[ -n "$AGENTID" ] || exit 0

# (b) read the brief (first type:user message) + classify the role, AND scan the transcript for the agent's OWN
# self-append (provenance, #1100 item 3). Emits: "<taskId> <role> <selfAuthored 0|1>" or "" (no tag).
read -r TASKID ROLE SELFAUTH < <(
  TRANSCRIPT_PATH="$TRANSCRIPT" node -e '
    const fs=require("fs");
    let txt=""; try{ txt=fs.readFileSync(process.env.TRANSCRIPT_PATH,"utf8"); }catch(e){ process.exit(0); }
    const lines=txt.split("\n").filter(l=>l.trim());
    let brief="";
    for (const ln of lines) {
      let j; try{ j=JSON.parse(ln); }catch(e){ continue; }
      const isUser = j && (j.type==="user" || (j.message && j.message.role==="user"));
      if (!isUser) continue;
      const c = j.message && j.message.content;
      if (typeof c === "string") brief=c;
      else if (Array.isArray(c)) brief=c.map(b=> (b && typeof b.text==="string") ? b.text : "").join("\n");
      break;  // FIRST user message is the brief
    }
    if (!brief) process.exit(0);
    const mTask = brief.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    if (!mTask) process.exit(0);                 // untagged subagent -> no-op (parent prints "")
    const taskId = mTask[1];
    let role="";
    const mRole = brief.match(/ROLE:\s*(planner|plan-review|execution-review|executor|research)/i);
    if (mRole) { role = mRole[1].toLowerCase(); }
    else {
      // keyword-classify (CORROBORATION only) — longest/most-specific match first.
      const b = brief.toLowerCase();
      if (/plan[\s-]*review|review (the )?plan/.test(b)) role="plan-review";
      else if (/execution[\s-]*review|review (the )?(execution|code|pr|implementation|diff)/.test(b)) role="execution-review";
      else if (/\bplanner\b|author (a |the )?plan|write (a |the )?plan/.test(b)) role="planner";
      else if (/\bexecutor\b|\bimplement\b|\bbuild\b/.test(b)) role="executor";
      else process.exit(0);                      // unclassifiable -> no-op
    }
    // #1100 item 3 PROVENANCE SCAN: did THIS agent self-author its OWN ledger line for THIS role? The strongest
    // signal is an assistant Bash tool_use invoking `3role-ledger.mjs append ... --role <thisRole>` in the
    // agent`s own transcript. Found -> stamp self_authored:true (a forged line written only by the orchestrator
    // has NO such authoring turn, so it stays unstamped and `check` surfaces it).
    let selfAuthored=false;
    const roleRe=new RegExp("--role\\s+"+role);
    for (const ln of lines) {
      let j; try{ j=JSON.parse(ln); }catch(e){ continue; }
      const isAsst = j && (j.type==="assistant" || (j.message && j.message.role==="assistant"));
      if (!isAsst) continue;
      const c = j.message && j.message.content;
      if (!Array.isArray(c)) continue;
      for (const blk of c) {
        if (!blk || blk.type!=="tool_use") continue;
        if (String(blk.name||"").toLowerCase()!=="bash") continue;
        const cmd=String((blk.input&&blk.input.command)||"");
        if (/3role-ledger\.mjs[\s\S]*?\bappend\b/.test(cmd) && roleRe.test(cmd)) { selfAuthored=true; break; }
      }
      if (selfAuthored) break;
    }
    process.stdout.write(taskId + " " + role + " " + (selfAuthored?"1":"0"));
  ' 2>/dev/null
)
[ -n "$TASKID" ] && [ -n "$ROLE" ] || exit 0
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# Append the ledger line via the flat sibling helper (idempotent per role). Never block: this is a recorder.
# When the agent self-authored (provenance), stamp self_authored:true; the agentId here is AUTHORITATIVE
# (harness-captured) and overlay-merges onto any agent-authored {role, artifact} line (#855, #1100 item 2).
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
[ -f "$HELPER" ] || exit 0
SELF_FLAG=""
[ "$SELFAUTH" = "1" ] && SELF_FLAG="--self-authored"
# #1466 -- pass the OBSERVED effort (payload effort.level) ONLY when the payload actually carried one; an
# absent/malformed value means --effort is omitted entirely, so overlayAppend's per-key "provided" discipline
# leaves whatever the spawn-time ASSIGNED stamp (or a prior line) already carries untouched -- never a blank
# clobber. When present, this OBSERVED value OVERWRITES the ASSIGNED one (observed wins at close).
EFFORT_FLAG=""
[ -n "$PAYLOAD_EFFORT" ] && EFFORT_FLAG="--effort $PAYLOAD_EFFORT"
# #1516 -- the EXPLICIT close-stamp. This hook is the ONLY writer that fires exclusively at close (a real
# SubagentStop, gated above on "must resolve to a real /subagents/agent-*.jsonl transcript"), so it is the
# ONE place a close-stamp can be trustworthy -- never inferred from agentId (which is also present at
# spawn/dispatch for a backgrounded role, see the plan's "why explicit, not inferred" section). Stamped on
# EVERY role's close (harmless additive field for the four chain roles; load-bearing for research's
# board punch-out in agent-kanban).
CLOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# #1640 S11 -- re-sense the reroute stamp at CLOSE too (not just at spawn): a role resumed mid-session under a
# base-url that changed since spawn gets its stamp refreshed at its own authoritative close edge. Same
# fail-open semantics as the spawn edge (see three-role-spawn-ledger.sh) -- a no-op for an ordinary session.
node "$HELPER" append --session "$SESSION" --task "$TASKID" --role "$ROLE" --agent "$AGENTID" $SELF_FLAG $EFFORT_FLAG --closed-at "$CLOSED_AT" --sense-reroute >/dev/null 2>&1
exit 0
