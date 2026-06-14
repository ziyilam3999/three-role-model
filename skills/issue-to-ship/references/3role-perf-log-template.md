# 3-role run — model-performance log (TEMPLATE)

> Reusable template for the **per-run instrumentation** of the 3-role development model
> (`${CLAUDE_PLUGIN_ROOT}/3-role-model.md → ### Development model — 3 roles, orchestrated`, **Invariant #6**).
> The standing per-round ritual is the standing per-round ritual; this is its 3-role specialization.
>
> **How to use.** At dispatch, copy this into the run's perf-log card
> (`~/.claude/agent-working-memory/tier-b/topics/workflow/<YYYY-MM-DD>-3role-model-performance-log.md`,
> created via `memory write --topic workflow --id <slug>`), fill the run header, then append one
> **round block** per role dispatch as the run proceeds. At close, fill the **SUMMARY**. The headline
> completion cites this card: `metadata.model_run=<card-id>`, `metadata.model_perf_log=<abs path>` —
> the `three-role-instrumentation-gate.sh` backstop requires the card to mention the run's taskId.
>
> **Role-ledger — prove each role actually RAN. PRIMARY mechanism = orchestrator-at-spawn (the
> tested, reliable path).** When you spawn a role subagent, PREPEND one token line to its Agent `prompt`:
> `3ROLE_TASK:<taskId> ROLE:<planner|plan-review|executor|execution-review>`. **Immediately** append a
> role-ledger line citing that role's agentId:
> `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append --session <sid> --task <taskId> --role <role> --agent <agentId>`.
> Get the agentId from the value the **Agent tool RETURNS** (full-tool writer spawns surface it); when it
> is NOT surfaced (e.g. an `Explore` reviewer spawn), resolve it with
> `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" resolve-agent --session <sid> --task <taskId> --role <role>` (prints the
> **newest-mtime** tagged transcript's agentId; empty + nonzero if none) — NOT a bare first-match/`head -1`
> grep, since a tag can repeat across transcripts (a probe/retry) so newest = the real spawn. At role CLOSE append only
> `--role <role> --artifact <path>`; `append` now **overlay-merges** so the artifact composes onto
> the spawn-time agentId in ONE line (neither write clobbers the other) — the agentId is captured for free
> at spawn and you never re-cite it. **The SubagentStop auto-write hook is a BEST-EFFORT BACKUP only and is
> currently INERT on real Agent-subagent stops — do NOT rely on it; the orchestrator-at-spawn write
> is the path that actually runs.** The gate's second leg verifies each ledger agentId resolves to a real
> `~/.claude/projects/*/<session>/subagents/agent-<id>.jsonl` transcript (a forged agentId → BLOCK). A
> non-review role may instead be inline-skipped with a SPECIFIC reason
> (`--role planner --skip-reason "<why this role was inseparable from live session state>"`);
> **`execution-review` is NEVER skippable** — give a real reviewer agentId or
> `--role execution-review --oracle <path>` (a test-oracle output file that exists with a PASS token).
>
> Lineage: derived from the live exemplar
> `~/.claude/agent-working-memory/tier-b/topics/workflow/2026-06-12-3role-model-performance-log.md`.

---

## Run header

- **Run**: #<headline-task-or-PR> — <one-line subject>
- **Date**: <YYYY-MM-DD>
- **Knob A — executor placement**: `lfah` | `delegate` | `parallel` | `inline` (+ task-nature rationale)
- **Knob B — evaluator**: `test-oracle` | `reviewer` | `both` (+ rationale)
- **Notes on fit**: <if the task only partially fits the dev-shaped model, say so — that partial-fit is itself a finding>

## Per-round scoring rubric (keep terse — one block per role dispatch)

For each role-round, append a block keyed by these fields:

- **role**: planner | plan-review | executor | execution-review
- **task**: which task / PR this round served
- **agent_type used**: (verify it carried the tools the role needed — Invariant #5; writers→full-tool, reviewers→`Explore`)
- **did its job?** (`did-its-job`): yes | partial | no
- **miss + root cause**: (if any — the objective recurrence-condition for the loop below)
- **fix applied**: (the inline correction made this round)
- **prevention**: (instruction-class note, OR a hook follow-up task # when the recurrence + fix-landed signals are both objective)

### Round <N><a/b/...> — <ROLE> (<agent_type>, <tools ok?>)
- **did its job?**: <yes|partial|no>
- **miss + root cause**: <…or (none)>
- **fix applied**: <…or (none)>
- **prevention**: <…or (none)>

---

## SUMMARY (fill at run close — Stage-6 harvest)

- **Model wins**: <what the model did well this run>
- **Misses harvested**: for every `partial`/`no` round, confirm the loop CLOSED —
 - root-cause → save-learning (`/cairn place` stone; + a working-memory card when it is a decision/defect, not just a warning) → fix → **prevent** (Rule-17 both-ends eval: objective recurrence-condition + objective fix-landed signal → hook; else instruction-class with the reason stated).
- **Defects filed**: <task #ids filed for any prevention that needs a hook> (this is exactly how + were born)
- **Harvested miss-count + filed task ids**: <record in the run record `runs/data.json`>
