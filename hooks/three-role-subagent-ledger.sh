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

INPUT=$(cat)

# Kill-switch (uniform with the sibling gates).
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0

# Parse the SubagentStop payload. The REAL payload carries TWO transcript fields: `agent_transcript_path` is the
# stopping SUBAGENT's own transcript (…/subagents/agent-<id>.jsonl) and `transcript_path` is the MAIN session's
# transcript (NOT under /subagents/). We PREFER agent_transcript_path; fall back to transcript_path ONLY when
# agent_transcript_path is absent/empty (back-compat with old fixtures + a main-session Stop). The payload also
# carries `agent_id` directly — prefer it for the agentId; fall back to the filename parse below when absent.
read -r TRANSCRIPT SESSION PAYLOAD_AGENTID < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const atp=(d.agent_transcript_path||"").toString();
    const tp=(atp!=="" ? atp : (d.transcript_path||"").toString());
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const aid=(d.agent_id||"").toString().replace(/[^0-9A-Za-z_-]/g,"");
    const enc=(s)=> (s===""? "-" : encodeURIComponent(s));
    process.stdout.write([enc(tp), session||"-", aid||"-"].join(" "));
  ' 2>/dev/null
)
dec(){ [ "$1" = "-" ] && { printf ''; return; }; printf '%b' "${1//%/\\x}"; }
TRANSCRIPT="$(dec "$TRANSCRIPT")"
[ "$PAYLOAD_AGENTID" = "-" ] && PAYLOAD_AGENTID=""

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
    const mRole = brief.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
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
node "$HELPER" append --session "$SESSION" --task "$TASKID" --role "$ROLE" --agent "$AGENTID" $SELF_FLAG >/dev/null 2>&1
exit 0
