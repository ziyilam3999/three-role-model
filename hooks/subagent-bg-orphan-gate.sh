#!/usr/bin/env bash
# SubagentStop hook — BG-ORPHAN GATE (#846). Blocks a SUBAGENT from ending its ONE-SHOT turn while it still
# owns an un-awaited background job it launched this turn. A subagent never receives the async completion of a
# `run_in_background` Bash job (its turn is one-shot — there is no later turn to hear the "done" notification),
# so a job it backgrounds and then stops on is ORPHANED with empty/partial output (this is what left the #824
# demo-capture with empty frames). This gate exit-2 BLOCKS the stop so the subagent is re-driven to either
# foreground the step, await it now, or hand the job id back to the orchestrator.
#
# AC-0 PROBE VERDICT (#846, recorded in the plan + 3-role perf log): BLOCK is real.
#   U1 (does SubagentStop fire + WHICH field points at the subagent .jsonl?) — CORRECTED #857:
#       SubagentStop DOES fire on real Agent subagents (live-probed 2026-06-12), BUT the stopping subagent's own
#       transcript is in `agent_transcript_path` (…/subagents/agent-<id>.jsonl) — NOT `transcript_path`, which is
#       the MAIN session transcript (all isSidechain:false). The earlier "PROVEN LIVE … the sibling #851-PR2 hook
#       reads /subagents/ on every real subagent stop" claim was FALSE: that sibling was ALSO silently no-opping
#       for this SAME wrong-field bug. Both hooks were fixed in #857 to read agent_transcript_path (preferred,
#       transcript_path only as fallback); firing + subagent-transcript access are now genuinely established.
#   U2 (does exit 2 re-drive the stopping subagent?) — established by the AUTHORITATIVE harness contract:
#       Claude Code's official hooks reference documents exit 2 on SubagentStop as "Prevents the subagent from
#       stopping" (the subagent continues working). The feedback_exit0_stderr_hook_nudge_invisible_to_model
#       lesson CORROBORATES the choice: an exit-0 stderr Stop nudge is invisible to the model; exit-2 BLOCK is
#       the only mechanism that reaches it — so exit 2 is exactly right here, NOT a warn.
#   DOMINANCE: exit 2 strictly dominates exit 0 for this gate. If re-drive works (documented) → the subagent is
#       steered (best). If a future harness build silently did NOT re-drive a SubagentStop, exit 2 degrades to
#       surfacing the stderr to the transcript/operator post-hoc — i.e. exactly the WARN outcome — so there is
#       no downside vs exit 0, as long as a loop guard is present. Hence BLOCK regardless of residual U2 doubt.
#
# This is a SECOND SubagentStop hook, registered ALONGSIDE three-role-subagent-ledger.sh (multiple hooks per
# event coexist) — it does NOT re-wire or replace the ledger hook. It reuses that hook's transcript-reading
# pattern (agent_transcript_path → subagent .jsonl, node-based JSON scan).
#
# The instruction-class FLOOR is the real fix (a one-shot subagent that can't receive a completion is a
# discipline problem first): feedback_subagent_must_not_background_and_end_owned_job + the executor brief in
# skills/issue-to-ship/SKILL.md. This hook is the mechanical backstop, not a substitute.
#
# Fire conditions (ALL must hold, else no-op exit 0):
#   (a) NOT a re-driven stop — stop_hook_active is falsy (block at most once per turn-end; loop guard).
#   (b) the resolved subagent transcript (agent_transcript_path when present, else transcript_path) is a readable
#       file that IS a subagent transcript: path contains "/subagents/agent-"  OR  its entries carry
#       "isSidechain":true. (Main-session stops — no agent_transcript_path, plain transcript_path — never block.)
#   (c) the transcript shows a self-launched `run_in_background:true` Bash whose background shell id was NOT
#       later awaited/terminated (no BashOutput/KillShell referencing that id) — i.e. an orphan at stop time.
#   (d) the subagent did NOT consciously hand the job back — its last assistant message lacks the bypass token
#       "(bg handed to orchestrator" / "(bg-orphan-ok)".
# Then: exit 2 with steering stderr naming the orphaned shell id and the three remedies.
#
# Kill-switch (audit-logged): SUBAGENT_BG_ORPHAN_OVERRIDE=1 -> log + exit 0.
# Fail-open everywhere: empty stdin / no node / malformed JSON / missing transcript -> exit 0 (never break a
# subagent stop on our own error). No `set -e` (a non-block non-zero must not fail-open into a spurious block).
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

# Kill-switch (single-use override), audit-logged to the unified override log.
if [ "${SUBAGENT_BG_ORPHAN_OVERRIDE:-}" = "1" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | SUBAGENT_BG_ORPHAN_OVERRIDE=1" >> "$HOME/.claude/.rule-12-overrides.log" 2>/dev/null || true
  exit 0
fi

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

HOOK_INPUT="$INPUT" node <<'NODE'
const fs = require("fs");

// Fail-open wrapper: ANY unexpected error -> exit 0 (never break a subagent stop on our own bug).
try {
  let d = {};
  try { d = JSON.parse(process.env.HOOK_INPUT || "{}"); } catch (e) { process.exit(0); }

  // (a) loop guard — if we already blocked this turn-end (re-drive in progress), do not block again.
  if (d.stop_hook_active) process.exit(0);

  // #857: PREFER the SUBAGENT's own transcript (agent_transcript_path); fall back to transcript_path ONLY when
  // agent_transcript_path is ABSENT. On a REAL SubagentStop payload BOTH fields are present and transcript_path
  // is the MAIN session (all isSidechain:false, not under /subagents/) — reading it would make isSubPath AND
  // sawSidechain false -> the gate would no-op on every real subagent stop (the exact #857 defect). So we must
  // NOT read transcript_path when agent_transcript_path is present.
  const atp = (d.agent_transcript_path || "").toString();
  const tp = atp !== "" ? atp : (d.transcript_path || "").toString();
  if (!tp) process.exit(0);
  const isSubPath = tp.includes("/subagents/agent-");

  let txt = "";
  try { txt = fs.readFileSync(tp, "utf8"); } catch (e) { process.exit(0); }

  const lines = txt.split("\n");
  let sawSidechain = false;
  const bgShells = new Map();        // backgroundShellId -> launching tool_use id (from the bg launch tool_result)
  const bgBashToolUses = new Set();  // tool_use ids of Bash(run_in_background:true) — fallback if no shell id parsed
  const awaited = new Set();         // shell ids referenced by a later BashOutput / KillShell tool_use
  let lastAssistantText = "";

  for (const ln of lines) {
    if (!ln.trim()) continue;
    let j; try { j = JSON.parse(ln); } catch (e) { continue; }
    if (j.isSidechain === true) sawSidechain = true;

    const msg = j.message;
    const content = msg && msg.content;
    const isAssistant = (j.type === "assistant") || (msg && msg.role === "assistant");

    if (Array.isArray(content)) {
      for (const b of content) {
        if (!b || typeof b !== "object") continue;

        if (b.type === "tool_use") {
          if (b.name === "Bash" && b.input && b.input.run_in_background === true) {
            if (b.id) bgBashToolUses.add(String(b.id));
          }
          if ((b.name === "BashOutput" || b.name === "KillShell") && b.input) {
            const id = b.input.bash_id || b.input.shell_id || b.input.shellId || b.input.id;
            if (id) awaited.add(String(id));
          }
        }

        if (b.type === "tool_result") {
          // A backgrounded Bash returns: "Command running in background with ID: <shellId>. Output is ..."
          let s = "";
          const c = b.content;
          if (typeof c === "string") s = c;
          else if (Array.isArray(c)) s = c.map(x => (x && typeof x.text === "string") ? x.text : "").join("\n");
          const m = s.match(/running in background with ID:\s*([A-Za-z0-9_-]+)/i);
          if (m) bgShells.set(m[1], (b.tool_use_id || ""));
        }
      }

      if (isAssistant) {
        const t = content.map(b => (b && typeof b.text === "string") ? b.text : "").join("\n").trim();
        if (t) lastAssistantText = t;
      }
    } else if (typeof content === "string") {
      if (isAssistant && content.trim()) lastAssistantText = content.trim();
    }
  }

  // (b) subagent gate — path under /subagents/ OR transcript carries sidechain entries. Else: main session -> no-op.
  if (!isSubPath && !sawSidechain) process.exit(0);

  // (d) conscious hand-back bypass.
  const low = lastAssistantText.toLowerCase();
  if (low.includes("(bg handed to orchestrator") || low.includes("(bg-orphan-ok)")) process.exit(0);

  // (c) orphan test — a launched bg shell whose id was never awaited/terminated.
  let orphanId = null;
  for (const sid of bgShells.keys()) {
    if (!awaited.has(String(sid))) { orphanId = sid; break; }
  }
  // Fallback: a bg Bash launch exists but we could not parse a shell id AND nothing was ever awaited -> orphan.
  if (!orphanId && bgBashToolUses.size > 0 && bgShells.size === 0 && awaited.size === 0) {
    orphanId = "(unresolved id)";
  }
  if (!orphanId) process.exit(0);

  process.stderr.write(
    "BLOCKED (subagent-bg-orphan): you launched a background job (" + orphanId + ") this turn and are ENDING. " +
    "A subagent's turn is ONE-SHOT — you never receive the job's async completion, so it will ORPHAN with " +
    "empty/partial output (this is how the #824 capture got empty frames). Do ONE of:\n" +
    "  • run the step SYNCHRONOUSLY — drop run_in_background and block on it so its output exists before you return; OR\n" +
    "  • AWAIT it now — poll BashOutput on " + orphanId + " until it reports completed/terminal, THEN end; OR\n" +
    "  • HAND IT BACK — return the job id to the orchestrator (whose turn is not one-shot) and add " +
    "'(bg handed to orchestrator: " + orphanId + ")' to your final message.\n" +
    "  • single-use override: SUBAGENT_BG_ORPHAN_OVERRIDE=1.\n" +
    "See feedback_subagent_must_not_background_and_end_owned_job.\n");
  process.exit(2);
} catch (e) {
  process.exit(0); // fail-open
}
NODE
exit $?
