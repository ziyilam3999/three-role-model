---
name: issue-to-ship
description: Orchestrator skill that takes a one-line issue statement, walks the operator through root-cause diagnosis, generates a Plan-First plan from template, dispatches the /auto-flow Stage-1 reviewer chain, gates on user approval, then triggers /delegate executor + /ship pipeline + push + pull. Use when an issue surfaces (incident, walk finding, retrospective, repeating mistake) and you want one entrypoint instead of weaving /auto-flow + /delegate + /ship + /cairn manually. Trigger phrases include "/issue-to-ship", "issue to ship", "diagnose and ship a fix for", "codify this as a plan and ship it", "we just hit X — turn it into a fix".
---

# /issue-to-ship — issue-to-ship orchestrator

## Overview

`/issue-to-ship "<one-line issue>"` is a single entrypoint for the diagnose → plan → reviewer-chain → ship → pull workflow that this repo runs every time a recurring mistake or fresh incident surfaces. The skill ORCHESTRATES the existing skills (`/auto-flow`, `/delegate`, `/ship`, `/cairn`) — it does NOT reimplement them. It saves drafting time on the plan template and prevents re-learning the same lessons every round (marker path, AC orientation, token-shape uniqueness, worktree-from-origin-master, etc.).

This skill assumes a workspace that follows the `.ai-workspace/` plan + worktree conventions this plugin installs. See **Cross-repo invocation** below for the v1 assumption and how the skill warns the operator when invoked outside such a workspace.

## When to use

Use when:

- An incident, walk finding, or retrospective surfaces an issue that needs a Plan-First fix.
- A recurring mistake (e.g., wrong marker path, AC orientation, missing emitter) is worth codifying.
- You want the four-reviewer planning pass (P1 → P2 → P3 → P4) plus dispatch + ship in one entrypoint.
- The fix is non-trivial (more than the Plan-First trivial-skip threshold of single file AND <10 lines AND no architectural decisions).

Do NOT use when:

- The fix is a trivial single-file < 10-line patch (just fix it inline).
- The plan is already reviewed equivalently elsewhere (use bare `/delegate`).
- The work is wrapped by a harness (forge-harness, bugfix-patrol — defer to harness).

## Workflow — six numbered stages

The skill walks through six stages. Each stage has one job and hands off cleanly to the next. The skill is an orchestrator: stages 3 and 5 hand off to existing skills (`/auto-flow`, `/delegate`, `/ship`).

### Stage 1 — Diagnose

Read `references/diagnosis-prompt.md`. Walk the operator through:

1. **What happened** — 1–3 sentence problem statement.
2. **Evidence** — file paths, commit SHAs, transcript anchors, log lines.
3. **Root cause categorization** — enumerate Category O/P/Q/R-style (O = shared infra, P = per-session hooks, Q = behavioral prose, R = no mechanical detection).
4. **Why existing prevention layers didn't catch it** — sweep live shipped layers (rule-12, drift sentinel, M2/N2/N3/T2, cross-repo-debt, settings-drift, cross-clone-contamination). Identify the gap.
5. **Goal mapping** — propose hook + nudge + AC.

### Stage 2 — File the Plan-First plan (planner = SUBAGENT)

**Dispatch-time instrument step (open the perf log — ${CLAUDE_PLUGIN_ROOT}/3-role-model.md Invariant #6).** When a 3-role run begins, **open or create the run's model-performance log** from the template `references/3role-perf-log-template.md` (write a card via `memory write --topic workflow --id <YYYY-MM-DD>-3role-model-performance-log`, or append a run section to the live one). Seed the **run header** (task/PR, the two knob choices + their task-nature rationale) and an empty per-round table; then append one perf entry per role dispatch (planner / plan-review / executor / execution-review) as Stages 2/3/5 proceed. **Tag the headline task** so the mechanical backstop can verify the log exists: set `metadata.model_run` on the headline `TaskUpdate` (value = the perf-log card id) and cite the card path with `metadata.model_perf_log=<abs path>`. The `hooks/three-role-instrumentation-gate.sh` gate blocks the headline `→ completed` unless the cited card carries an entry naming this taskId (untagged / trivial completions are never gated). This generalizes what Stages 2/3/5 already do role-by-role; the template is the single shape Invariant #6 points at.

**Role-ledger step (prove the roles RAN, not just that a perf entry was written).** The gate now has a SECOND leg backed by a per-task role-ledger. **PRIMARY mechanism = orchestrator-at-spawn (the tested, reliable path).** For EACH role spawn (planner / plan-review / executor / execution-review): (1) PREPEND `3ROLE_TASK:<taskId> ROLE:<role>` to the role subagent's Agent `prompt`; (2) **immediately** append a ledger line citing that role's agentId — `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append --session <sid> --task <taskId> --role <role> --agent <agentId>`. Get the agentId from the value the **Agent tool RETURNS** (full-tool writer spawns surface it); when it is NOT surfaced (e.g. an `Explore` reviewer spawn), resolve it with `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" resolve-agent --session <sid> --task <taskId> --role <role>` (prints the **newest-mtime** tagged transcript's agentId; empty + nonzero if none). Use it, NOT a bare first-match/`head -1` grep — a tag can repeat across transcripts (an earlier probe/retry reusing a role tag), so newest = the real spawn and first-match can grab a stale probe. (3) At role CLOSE append only `--role <role> --artifact <path>`; `append` now **overlay-merges** so the artifact composes onto the spawn-time agentId in ONE line — neither write clobbers the other, so the agentId is captured for free at spawn and you never re-cite it. **The SubagentStop auto-write hook is a BEST-EFFORT BACKUP only and is currently INERT on real Agent-subagent stops — do NOT rely on it; the orchestrator-at-spawn write is the path that actually runs.** The gate globs `~/.claude/projects/*/<session>/subagents/agent-<agentId>.jsonl` and BLOCKS the headline completion if any cited agentId has no real transcript (forgery-close). A non-review role you genuinely ran inline may instead be recorded as `--role <role> --skip-reason "<SPECIFIC reason it was inseparable from live session state>"` (empty / non-specific / "ran it inline myself" are rejected). **`execution-review` is NEVER inline-skippable** — give a real reviewer agentId, or `--role execution-review --oracle <path>` (a test-oracle output file that exists with a PASS token). At Stage 6 close-out, a complete ledger is the proof all four roles ran.

**Default: the orchestrator spawns a PLANNER SUBAGENT (Agent tool) to author the plan** — per the 3-role model (`${CLAUDE_PLUGIN_ROOT}/3-role-model.md → ### Development model — 3 roles, orchestrated`), the planner is a subagent so the main context stays lean and the plan is independent of the orchestrator's biases. The planner subagent's brief MUST do, in order:

1. **Search all three memory systems FIRST** (the `cairn-search-before-planning.sh` block-once hook, mechanically backstops this — do not reimplement it):
 - cairn — T1/T2/T3 lessons (patterns / anti-patterns / decisions). **In a subagent shell call the node CLI directly: `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"`** — the `/cairn find` Skill dispatch no-ops in an Agent subagent shell. Query with SINGLE salient keywords (the matcher is substring-based; multi-word now tokenizes, but one strong keyword is most reliable). The `${CLAUDE_PLUGIN_ROOT}` path resolves from any cwd, so no `cd` is needed.
 - read the working-memory tier-b cards under `~/.claude/agent-working-memory/tier-b/topics/` relevant to the topic.
 - read the project-index `.ai-workspace/PROJECT-INDEX.md`; **if it is MISSING or stale, the planner CREATES it FIRST via `/project-index`** before planning (the hook's index leg is never silently waived).
2. **Render + fill the Plan-First plan** via the existing renderer:
 ```
 bash skills/issue-to-ship/scripts/render-plan.sh "<problem-statement>".ai-workspace/plans/<YYYY-MM-DD>-<slug>.md
 ```
 then fill Goal / Critical files / Approach / Binary AC into the rendered file.
3. **CITE what it found** — a memory-citation line is part of the produced plan: pattern/anti-pattern IDs (e.g. P17, F9), relevant card ids, and file pointers the search surfaced. **The plan MUST carry a `cairn:` citation line that QUOTES at least one matched `cairn-find` result line OR states explicitly `cairn: no hits for <queries>`** — this is the cheapest honest signal that the cairn leg actually ran (vs was claimed). The plan-reviewer must likewise cite a hit or state "no hits".

**Tool requirement (explicit):** spawn the planner with a FULL-tool agent type (`general-purpose` / `claude`) — it WRITES the plan file and runs `/cairn find` + `/project-index`. **Do NOT use the `Plan` agent type: despite its name it is READ-ONLY (no Write/Edit) and cannot author a plan file.** See `## Role tooling` below.

The renderer carries 13 standard plan sections plus inline HTML-comment lessons (marker path, AC orientation, token-shape uniqueness, compound-Bash warning, worktree from `origin/master`, cleanup discipline, /config strip warning, cross-contamination wait). The template lives at `references/plan-template.md`; the 8 baked-in lessons are named `MARKER PATH`, `TOKEN-SHAPE`, `COMPOUND-BASH`, `WORKTREE`, `CONFIG WARNING`, `CROSS-CONTAMINATION`, `AC TEMPLATE`, `CLEANUP`.

**Fallback — operator fills the plan inline:** when the task is NOT briefable (tightly coupled to live session state — same carve-out as Invariant 1 / knob-A `inline`), skip the planner subagent and have the operator fill the rendered plan (Goal, Critical files, Approach, Binary AC) directly. The memory-search trio still applies (the hook fires on the plan write regardless of who authored it).

### Stage 3 — Auto-flow Stage-1 reviewer chain (handoff to `/auto-flow`)

Read `references/auto-flow-handoff.md`. Hand off to `/auto-flow` Stage 1: P1 cold review → P2 comparative → P3 cairn-grounded → P4 coherent-plan, dispatched as sequential background subagents per the established pattern.

**The plan-reviewer is a STATELESS, independent background subagent** that did NOT author the plan (it sees the plan cold). **It is memory-grounded**: the P3 cairn-grounded reviewer already searches cairn — extend that to ALL THREE memory systems so the verdict checks the plan against known lessons/decisions/file-map, not just the plan text:
- cairn (T1/T2/T3 lessons) — from the reviewer's subagent shell call `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"` (NOT `/cairn find`, which no-ops in a subagent); single salient keywords,
- the working-memory tier-b cards under `~/.claude/agent-working-memory/tier-b/topics/`,
- the project-index `.ai-workspace/PROJECT-INDEX.md`.

Spawn pure reviewers with the `Explore` agent type (read-only but keeps Bash + Read + Grep + Skill so they can run `/cairn find`) — see `## Role tooling`.

After each round, fold findings inline (bugs always; enhancements selectively). Update the plan's `## Last updated` section with the verdict + fixes-applied summary.

### Stage 4 — Show-and-wait gate

After P4 returns SHIP-CLEAN, render the ELI5 final-plan summary inline. Wait for explicit user approval (yes / approve / proceed / "ship it"). Silence is NOT approval. Adjacent activity is NOT approval. A reviewer's "SHIP" verdict is NOT user approval.

Pre-authorization counts only if quotable from the current session ("draft and ship", "auto mode just do it", "delegate after review without asking") OR a filed `/delegate` brief whose Binary AC encodes the contract.

### Stage 5 — Dispatch executor (handoff to `/delegate`)

Read `references/delegate-handoff.md`. Hand off to `/delegate` with the plan path. The brief includes worktree spec (`origin/master` source — NOT local master), critical files, Binary AC contract, out-of-scope list, full `/ship` Stages 0-10 pipeline with marker path pinned to `.ai-workspace/ship-verified-<PR>`, conventional commit prefix, Rule-12 + Rule-14 cleanup.

The executor runs `/ship` end-to-end. The skill does NOT reimplement `/ship` — it dispatches.

**Executor brief MUST carry the no-background-and-end rule.** The executor is a subagent — its turn is ONE-SHOT, so it can never receive the async completion of a `run_in_background` job. The brief instructs: run any heavy step you OWN **synchronously** (foreground, blocking) so its output exists before you return; if a step genuinely must be backgrounded, **hand the job id back to the orchestrator** and add `(bg handed to orchestrator: <id>)` to your final message — never end your turn with an un-awaited bg job you launched (it orphans with empty output — the capture failure). Mechanical backstop: `hooks/subagent-bg-orphan-gate.sh` (SubagentStop exit-2 BLOCK; override `SUBAGENT_BG_ORPHAN_OVERRIDE=1`). See `feedback_subagent_must_not_background_and_end_owned_job`.

**The executor's diff is reviewed by a STATELESS, independent reviewer** — `/ship` Stage 5's self-review spawns a fresh Agent that did NOT write the code, reviewing the diff cold. NEVER executor-self-review, NEVER orchestrator-inline-self-review (Invariant 3). Spawn it with `Explore` (read-only but retains Bash to run the test oracle) — see `## Role tooling`.

### Stage 6 — Post-ship: push, pull, cairn save

Read `references/post-ship-protocol.md`. After the executor merges:

1. Verify PR merged (`gh pr view <num> --json state` returns `MERGED`).
2. Run the cross-clone-contamination check (refuse the pull if any non-master worktree subagent is active; offer to wait until they finish).
3. Pull primary (`git pull --ff-only origin master`).
4. Drop pre-stash mods accumulated during the run.
5. File tier-b ship-run card at `~/.claude/agent-working-memory/tier-b/topics/ship-runs/<date>-pr-<N>-<slug>.md`.
6. If a novel lesson surfaced, `/cairn place "<lesson>"`.
7. **Harvest misses → file tasks / cairn (instrument close-out — ${CLAUDE_PLUGIN_ROOT}/3-role-model.md Invariant #6).** Sweep the run's perf log (`references/3role-perf-log-template.md` shape): for every `partial`/`no` round, ensure the loop CLOSED — a `/cairn place` stone and/or a working-memory defect card was written, AND a follow-up task was filed for any prevention that needs a hook (exactly how and were born). Fill the perf log's **SUMMARY** (model wins, defects filed with task ids). This close-out is instruction-class: there is no clean post-ship harness event to gate a Stop on a specific run's harvest (the gate at Stage-2/5 only verifies the log EXISTS + carries an entry, not that every miss was harvested) — so honor it explicitly.
8. Update `runs/data.json` with the run record, including the **harvested miss-count + filed task ids** from step 7.

## Role tooling

Each role subagent must be spawned with the tools its job needs (the Agent tool's `subagent_type` decides the toolset; a starved agent silently fails). Canonical rule: `${CLAUDE_PLUGIN_ROOT}/3-role-model.md → ### Role tooling — spawn each role with the tools it needs`.

- **Planner & executor** WRITE files → spawn a FULL-tool agent type (`general-purpose` / `claude`, tools `*`). **TRAP: never the `Plan` agent type for the planner — despite its name it is read-only (no Write/Edit) and cannot author the plan file.**
- **Pure reviewers** (plan-reviewer, execution-reviewer) → `Explore` (read-only, but keeps Bash + Read + Grep + Skill so they can run `/cairn find` + the test oracle). Must NOT be the executor (no self-review).

Rule of thumb: writers → full-tool type; reviewers → `Explore`. When unsure, grant MORE tools — a starved agent is the expensive failure.

## Orchestrator-not-replacer (composition)

This skill DELEGATES to:

- `/auto-flow` for the Stage-1 reviewer chain (P1 → P2 → P3 → P4 sequential background subagents).
- `/delegate` for the executor handoff post-show-and-wait.
- `/ship` for the Stages 0-10 pipeline.
- `/cairn` for lesson capture (via `/cairn place`).

It does NOT reimplement any of those skills. Drift between this skill and `/auto-flow` / `/delegate` / `/ship` is prevented by always naming them by their actual command surfaces in the handoff references.

## Cross-repo invocation

This skill assumes a workspace that follows the conventions this plugin installs. It is unsupported in v1 outside such a workspace. Required conventions:

- `.ai-workspace/plans/` exists for plan files.
- `skills/` is the source-of-truth for shareable skills.
- `${WORKING_MEMORY_ROOT}` (default `~/.claude/agent-working-memory/tier-b/topics/`) exists for working-memory cards.
- A cairn T3 knowledge base is reachable (via `${CAIRN_PERSIST_ROOT}`); absent one, cairn search degrades to the user's own T1/working-memory tiers.

If the working directory does not provide these conventions, the skill **warns and declines** rather than scattering garbage plan files: "/issue-to-ship assumes the `.ai-workspace/` workspace conventions this plugin installs; invoke from a workspace that has them. Cross-workspace applicability is out of scope for v1; v1.1 may add a CWD-gate hook." This is a prose-class refusal — operator-discipline, not mechanically enforced. The failure mode (garbage plan files in a non-conforming `.ai-workspace/`) is recoverable. v1.1 may add a CWD-gate hook that exits the skill before any other action.

## References

- `references/diagnosis-prompt.md` — root-cause categorization prompt; sister-plan sweep checklist; gap-analysis framing.
- `references/plan-template.md` — Plan-First plan template with 13 standard sections + 8 baked-in lessons as inline comments.
- `references/auto-flow-handoff.md` — exact contract for handing off to `/auto-flow` Stage-1 reviewer chain.
- `references/delegate-handoff.md` — exact contract for handing off to `/delegate` post show-and-wait.
- `references/post-ship-protocol.md` — push + pull discipline, cross-clone-contamination check, cairn lesson save trigger.
- `references/3role-perf-log-template.md` — reusable model-performance log template (run header + per-round rubric + run-close SUMMARY) the Stage-2 instrument step opens and the Stage-6 harvest closes; the shape ${CLAUDE_PLUGIN_ROOT}/3-role-model.md Invariant #6 + `hooks/three-role-instrumentation-gate.sh` point at.
- `scripts/render-plan.sh` — pre-written shell harness that substitutes date + slug into the plan template and writes the rendered file.

## Run Data Recording

Record each invocation in `runs/data.json`. Envelope shape (matches `auto-flow` and `delegate` conventions):

```json
{
 "skill": "issue-to-ship",
 "lastRun": "<ISO-8601 timestamp or null>",
 "totalRuns": 0,
 "runs": []
}
```

Per-run record fields (append to `runs[]`):

- `timestamp` — ISO-8601 invocation start.
- `outcome` — `complete` | `partial` | `aborted` | `error`.
- `problem_statement` — the operator's one-line issue.
- `slug` — slugified problem statement used in the plan filename.
- `p1_verdict` — `SHIP-CLEAN` | `SHIP-WITH-MINOR-FIXES` | `BLOCK` (or null if skipped).
- `p2_verdict` — same enum.
- `p3_verdict` — same enum.
- `p4_verdict` — same enum.
- `ship_pr_number` — integer PR number once merged (null until ship).
- `time_to_ship_seconds` — seconds from invocation to PR merge (null if not yet shipped).
- `lessons_learned` — array of cairn-stone strings placed during the run (empty array if none).

Retention: keep the last 50 runs. Older runs may be pruned manually by the operator.

## Out of scope (v1)

- Auto-triggering the skill on incidents (e.g., on subagent kill, on /ship failure). Reactive-only — operator invokes.
- Modifying `/auto-flow`, `/delegate`, or `/ship` skills. The skill ORCHESTRATES them; doesn't change them.
- Cross-workspace applicability beyond the conventions this plugin installs. v1 warns and declines. v1.1 may add a CWD-gate hook.
- Skipping the reviewer chain for trivial fixes. Plan-First trivial-skip threshold applies — if you hit it, skip this skill and just fix.
- Replacing `/cairn place` with skill-internal lesson capture. `/cairn place` stays the canonical lesson-capture surface.
- Telemetry visualization / dashboard. `runs/data.json` is JSON; no UI in v1.
