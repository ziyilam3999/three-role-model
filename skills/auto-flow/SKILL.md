---
name: auto-flow
description: Autonomous arc orchestration with chained-reviewer planning + (when applicable) parallel-stateless-subagent dispatch. Nineteen-step pipeline across plan, dispatch+run, and implement+ship+save+cleanup stages — including chained reviewer pipeline (P1 stateless → P2 comparative → P3 cairn-grounded → P4 coherent-plan; I1 + I2 post-code), trust-but-verify protocol on subagent reports, self-improvement cairn save points, and post-arc worktree cleanup per Rule 14 (mv-not-rm). Use for non-trivial multi-step work — any size from one bundle (single PR) upward — when the four-reviewer planning pass should run before dispatch. For multi-bundle arcs (≥2 disjoint write surfaces) the parallel-dispatch engine fires; for single-bundle (N=1) plans the dispatch and ship stages trivially short-circuit (one worktree, one brief, one /delegate, one /ship). Refuses (refusal-class) for serial work that pretends to be parallel, shared write paths across bundles, near-/compact contexts, or trivial-skip-threshold work. Trigger phrases include "/auto-flow", "ship this arc", "ship this multi-bundle arc", "dispatch parallel bundles", "orchestrate the multi-PR work".
---

# Auto Flow — Autonomous Arc Orchestration

## Overview

Auto-flow walks an agent through 19 numbered steps to ship one or more PRs with disciplined guard rails — the chained-reviewer planning pass (Stage 1) runs before *every* delegation regardless of bundle count, and the parallel-dispatch engine (Stage 2) only fires when there are ≥2 disjoint bundles. The workflow earned its keep on the 9-bundle reviewer-grounded arc that shipped 2026-04-27 (3-hour wall-clock vs ~10-hour serial estimate). Source retrospective: `.ai-workspace/retrospectives/2026-04-28-multi-bundle-autonomous-arc.md`.

**Three stages:** Plan (steps 1-6) → Dispatch + Run (steps 7-13) → Implement-review + Ship + Save + Cleanup (steps 14-19).

## When to use — decision table

Choose `/auto-flow` vs `/delegate` (vs just-fix) based on plan shape, not bundle count alone. The Stage 1 four-reviewer chain is the value of `/auto-flow`; Stage 2's parallelism is a bonus when multi-bundle.

| Situation | Route to |
|---|---|
| Single file AND <10 lines AND no architectural decisions (Plan-First trivial-skip) | **Just fix** — no orchestration, no review chain |
| 1 bundle (single PR target, one disjoint write surface), non-trivial | **`/auto-flow`** — Stage 1 reviewer chain runs; Stages 2+3 short-circuit (one worktree, one brief, one /delegate, one /ship) |
| ≥2 bundles, disjoint write surfaces, stable dependency graph | **`/auto-flow`** — full parallel dispatch via Stage 2 |
| Multi-bundle but shared write paths OR fundamentally serial OR near-/compact | **Refused** by Stage 1 refuse-class checklist; serialize with `/delegate` per slice instead |
| Plan already passed an equivalent four-reviewer pass elsewhere; user wants thin handoff only | **`/delegate`** — bare clerk; skips the review chain |

## Refuse-class checklist (run BEFORE invoking the workflow)

If ANY of the following hold, refuse to dispatch and explain which guard fired:

1. **Work is fundamentally serial** — each unit's output is the next unit's input. Parallelism gains nothing; only adds dispatch overhead and correlated-failure risk.
2. **Units share write paths to the same file.** Even with independent intent, two parallel agents editing the same file produce 3-way merge conflicts at PR-merge time.
3. **Units need each other's intermediate outputs in real time.** Sequence, not parallel batch.
4. **Token budget tight** (each parallel report-back lands in main-session context; 4 × ~1.5 KB = 6 KB at next turn boundary).
5. **Dependency graph unstable** (rewriting "X depends on Y" mid-arc means the graph isn't ready).
6. **Single-repo correlated success** (one failure invalidates the whole batch — serialize so one failure aborts cleanly).
7. **Near a `/compact` boundary** (parallel completions arriving across compaction are partially lost).
8. **Trivial work** (single file AND <10 lines AND no architectural decisions — Plan-First's trivial-skip threshold). Just fix and ship.

## Stage 1 — Plan stage (steps 1-6)

**Dispatch mode for Stage 1 reviewers — sequential ≠ foreground; ALL four reviewers run via background subagent.** P1→P2→P3→P4 is a serial chain (each later reviewer's prompt requires the prior reviewer's output as input — P2 explicitly compares "original + P1's revision," etc.), but "serial" does NOT mean "synchronous main turn." Each reviewer is dispatched as an Agent tool call with `run_in_background: true`. The orchestrator waits for the runtime's completion notification before dispatching the next reviewer (sequencing preserved); during each wait, the main turn does prep work (snapshot the plan, apply prior-reviewer fixes, draft the next reviewer's prompt template). **P4 is dispatched the same way** — even though `/coherent-plan` is encoded as a Skill, do NOT invoke the Skill directly on the main turn; inline a copy of its instructions into the subagent's prompt and dispatch via Agent with `run_in_background: true`. Foreground / inline-Skill dispatch blocks the main turn for the full review window (~3 min/reviewer) with zero benefit and no preserved sequencing guarantee — same wall-clock, less prep done. (Source incident: 2026-05-01; cross-reference: ${CLAUDE_PLUGIN_ROOT}/3-role-model.md Workflow Heuristics → Subagent Strategy → "Sequential ≠ foreground.")

| # | Step | What it fixes |
|---|---|---|
| 1 | **File a Plan-First plan** at `.ai-workspace/plans/<date>-<slug>.md` with sections: Goal / Binary AC / Out of scope / Critical files / Verification | Inline conversation context disappears at /compact; executor + reviewer can't see the contract. Filed plan = durable handshake |
| 2 | **P1 — Stateless generalist reviewer** reads the plan cold (no cairn access, no prior version). Dispatch: Agent tool, `run_in_background: true` | Author's blind spots — missing actors, incomplete context, unclear AC. Cold read forces what the author skipped because they "knew" |
| 3 | **P2 — Comparative-vs-prior-revision reviewer** sees both original + P1's revision; asks "Did the revision actually help? Where is it still worse?" Dispatch: Agent tool, `run_in_background: true` after P1's completion notification arrives | P1 over-correction, scope creep, regressions where P1 deleted load-bearing context |
| 4 | **P3 — Cairn-grounded plan reviewer** with full `hive-mind-persist/` access; cites F-/P-IDs for every flagged violation; searches cairn from its subagent shell via `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"` (NOT `/cairn find`, which no-ops in a subagent) before producing findings. Dispatch: Agent tool, `run_in_background: true` after P2's completion notification arrives | Repeating known anti-patterns (F36 grep-only AC, F50 exact-string match, F66 hybrid-first, F65 plan-without-measure). Turns institutional memory into review pressure |
| 5 | **P4 — Coherent-plan mechanical sweep** runs LAST in plan stage (cheapest gate, most value at end). Dispatch: Agent tool with the `/coherent-plan` instructions inlined into the prompt, `run_in_background: true` after P3's completion notification — NOT a direct Skill invocation on the main turn. Use `/coherent-plan` for ≤150-line plans, `/double-critique` for larger architectural specs | Cumulative drift introduced by P1+P2+P3 — label drift, dead refs, contradicting AC. Foreground Skill invocation here would block the main turn the same way foreground Agent dispatch does on P1/P2/P3 |
| 6 | **Final ELI5 + Rule 15 wait gate (initial-plan-only)** — author posts a structured chat block in the **ELI5 narrative format** (see below) walking the user through the plan in plain English; waits for explicit user approval *for the initial plan blessing only*. Subsequent inter-phase transitions use drift-conditional pause (see Operational rule (d)) | Implementation against an unblessed plan → mid-flight "I don't like this fix" → undo → re-fix waste loop |

The Step 6 ELI5 block uses the **ELI5 narrative format** — user-blessed 2026-05-10 as the canonical wait-gate format. Full template + rationale in user-memory card `feedback_eli5_final_report_format.md`. Required sections in order:

1. Title `# ELI5 — what the plan actually does`
2. Bold one-liner stating fix count + lightness ("X tiny problems on your laptop, X tiny fixes")
3. Per-fix `## Problem N — <plain-English name>` section with three subsections: **The issue (kid version)** (analogy first, technical names parenthetical) → **The fix** (one paragraph plain-English) → optional **Twist** (subtle gotcha that drove a non-obvious decision)
4. Steps table — three columns: `Step | What happens | How long`. Time estimates per task. Total at bottom.
5. "How we know it actually worked" — plain-English ✅ translation of every Binary AC. Do NOT dump bash. Translate semantics.
6. "Risk = X. Reversibility = X." one-line callout, then bullet list of safety nets (snapshots, rollback procedures, worst-case recovery)
7. "After this ships" — what comes next per autonomous-next-tasks / pre-compact card, so user knows scope of what they're greenlighting beyond immediate plan
8. **Plan path** in bold + 3-shape approval prompt: `approve all defaults` / `approve X only, stop after Y` / `flip D-X.Y to <choice>`

**Do NOT use the prior decision-matrix format** (workflow-steps table → operational rules → D-N.M decisions matrix). That format buries the plan content under workflow meta-information; user explicitly rejected it 2026-05-10 in favor of the ELI5 narrative above. The umbrella plan file is the durable record; the chat block is the visibility gate.

## Stage 2 — Dispatch + Run stage (steps 7-13, the parallelism engine)

| # | Step | What it prevents |
|---|---|---|
| 7 | **Decompose into units with disjoint write surfaces.** Read each candidate unit's "files modified" against every other candidate. Any overlap → serialize, not parallelize | Two parallel agents editing the same SKILL.md / CHANGELOG.md / plan file → guaranteed merge conflict |
| 8 | **One worktree per unit, branched from `origin/master`.** Convention: `git worktree add.claude/worktrees/<slug> -b <branch> origin/master`. Branch from `origin/master` (not local `master`) to get the canonical clean base | Rule HEAD-switch race in shared clones; content contamination from another agent's uncommitted drift |
| 9 | **Write a self-contained brief per unit** with 8 sections: Mission / Background / Worktree setup / Edits / Binary AC / Ship procedure / Coordination notes / Report-back format. Treat the subagent like a colleague who walked in 5 minutes ago | Subagent has to ask orchestrator for clarification mid-build → blocks parallelism → defeats throughput |
| 10 | **Dispatch all units in a SINGLE message** with multiple `Agent` tool-use blocks marked `run_in_background: true` | Accidentally-serial dispatch (one agent per turn) — same wall-clock as serial, no throughput gain |
| 11 | **Track via the task list.** One `[HEADLINE]`-prefixed task per dispatched bundle, created BEFORE dispatch, marked `in_progress` at dispatch, `completed` on notification | Orchestrator forgetting in-flight subagents as context bloats with parallel updates |
| 12 | **Continue with non-overlapping work in main session.** Plan downstream sequenced bundles, write design docs, edit master plan with mid-arc learnings. **Do NOT poll** — runtime delivers `<task-notification>` automatically | Polling burns context for no signal; idle waiting wastes orchestrator wall-clock |
| 13 | **On notification: trust-but-verify.** PR URL: ALWAYS verify via `gh pr view`. AC table: sample at least one binary AC and re-run its verifier locally. Blocker: read the actual error log if claimed. Narrative: trust unless contradicted | Hallucinated reports landing on master (under-verify) OR re-running every AC manually (over-verify negates throughput) |

## Stage 3 — Implement-review + Ship + Save + Cleanup stage (steps 14-19)

| # | Step | What it fixes |
|---|---|---|
| 14 | **I1 — Comparative reviewer (post-code)** reads real diff vs base branch; asks "Better than before? Still worse where?" | Plan-vs-implementation semantic divergence. Functionally identical to forge-harness `/ship` Stage 5 stateless reviewer |
| 15 | **I2 — Cairn-grounded reviewer (post-code)** with full hive-mind-persist access; cites F-/P-IDs against the real diff; searches cairn from its subagent shell via `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"` (NOT `/cairn find`, which no-ops in a subagent) before producing findings | Implementation-level rule violations P3 couldn't see (PII logging, hidden hybrids that match plan intent but violate KB) |
| 16 | **`/ship` merge + release** (Stages 0-10: pre-flight → branch → push → CI wait → review → marker → merge → version bump → CHANGELOG → tag → Release → cleanup → record) | Untracked merges, manual version drift, missing Release notes |
| 17 | **Post-`/ship` checkpoint ritual** — write a working-memory **tier-b card** (decisions: what shipped, what was rejected, why) AND optionally `/cairn place` (lessons: warnings for next time) | Decisions + lessons evaporate after /compact; next arc re-discovers everything. Role split: decisions → working memory; lessons → cairn |
| 18 | **Cron graduation cadence** — H4 hourly heartbeat promotes T1 stones → T2 session-notes (low gates); H5 daily promotes T2 → T3 KB (high gates: ≥2 distinct sessions, no hardcoded paths, Jaccard dedup); H6 weekly drift audit | Lessons stuck in T1 never reach future arcs as primer; KB drifts as old entries contradict newer. H4→H5 is the path arc-level lessons take to become future-arc primer content |
| 19 | **Cleanup** — `mv` each arc worktree to `.claude/worktrees/_quarantine-<YYYY-MM-DD>-<arc-slug>/<original-name>/` per Rule 14 (mv-not-rm); `git worktree prune` to clear stale `.git/worktrees/` refs; `git branch -D <branch>` for each fully-merged-and-deleted-on-remote local branch. Optionally garbage-collect quarantine directories older than 30 days. **Run AFTER Step 17 + Step 18** so the tier-b card and cron graduation can reference worktree paths if needed; running cleanup before the lesson-save would risk premature deletion of evidence | Worktree clutter accumulates across arcs (this very arc had 30+ worktrees in `.claude/worktrees/` from prior sessions before cleanup); orphaned local branches mask actual in-flight work; the `_quarantine-` prefix + date stamp keeps cleanup reversible per Rule 14 |

## Single-bundle (N=1) short-circuit

When `/auto-flow` is invoked against a plan with one disjoint write surface (one PR target, one bundle), the Stage 1 reviewer chain runs unchanged — that's the value of using `/auto-flow` over bare `/delegate`. Stages 2 and 3 trivially compress: one worktree, one brief, one Agent dispatch, one trust-but-verify, one `/ship`, one tier-b card, one worktree quarantine. The 19 numbered steps still apply; several become no-ops because there is nothing else to coordinate. Per-step behavior:

| /auto-flow step | N=1 behavior |
|---|---|
| Step 1 (file Plan-First plan) | unchanged |
| Step 2 (P1 stateless cold-read) | unchanged — runs once |
| Step 3 (P2 vs-prior comparative) | unchanged — runs once |
| Step 4 (P3 cairn-grounded) | unchanged — runs once |
| Step 5 (P4 coherent-plan mechanical sweep) | unchanged — runs once |
| Step 6 (ELI5 + Rule 15 wait gate) | unchanged |
| Step 7 (decompose disjoint write surfaces) | trivially: one bundle, one write surface, one task |
| Step 8 (worktrees from origin/master) | one worktree |
| Step 9 (8-section briefs) | one brief |
| Step 10 (SINGLE-message dispatch with `run_in_background: true`) | one Agent call; `run_in_background: true` is still recommended so the planner can continue without blocking, but a foreground call is also acceptable when the planner has nothing else queued |
| Step 11 (task-list track) | one HEADLINE task |
| Step 12 (continue non-overlapping work) | no-op (no other bundles) |
| Step 13 (trust-but-verify on notification) | unchanged — runs once when the bundle reports done |
| Step 14 (I1 comparative post-code review) | unchanged — runs once |
| Step 15 (I2 cairn-grounded post-code review) | unchanged — runs once |
| Step 16 (`/ship` per unit) | runs once |
| Step 17 (tier-b card + `/cairn place`) | runs once |
| Step 18 (H4→H5 graduation) | unchanged — cron-driven, not bundle-count gated |
| Step 19 (mv worktree to `_quarantine-`) | runs once for the single worktree |

The trivial-skip refuse rule (checklist item 8 above) still applies: a single-file <10-LOC change with no architectural decisions skips `/auto-flow` entirely and just fixes inline. The fundamentally-serial refuse rule (item 1) also still applies: an N=1 plan whose dependencies are not yet shipped is still refused — N=1 means "one bundle right now," not "one bundle that depends on another bundle still in flight."

## Operational rules (apply at every step where applicable)

- **(a) `respect-the-prior-reviewer`** — a later reviewer can override a prior reviewer's edit ONLY by citing specific evidence: a regressed AC, a violated cairn ID, a contradiction. Style preferences ("I'd word it differently") are NOT grounds for override. Prevents reviewer Rube-Goldberg loops.
- **(b) `intent-anchor`** — Step 1's plan declares a one-line north-star intent in a labelled prose block. Every reviewer preserves it verbatim. Step 6's ELI5 reads it aloud so the user notices drift.
- **(c) `fast-path skip`** — if the plan meets Plan-First's trivial-skip threshold (single file AND <10 lines AND no architectural decisions), skip the entire chain. The chain is for non-trivial plans only.
- **(d) `drift-conditional pause`** (auto-mode default) — between phases, the orchestrator runs trust-but-verify and writes an internal status report as a quality check. It surfaces a user-facing pause + ELI5 status report ONLY if outputs drift from the plan's intent. *Drift definition:* outputs deviate from plan intent in ways the plan did NOT anticipate. NOT drift: version-measurement-at-ship-time differing from predicted (plan-aware per `feedback_verify_master_version_before_planning.md`); corrected briefs mid-arc that respond to a discovered constraint; blocker mitigations that resolve without changing binary AC. Cited as cairn lesson F-AUTOFLOW-DRIFT-CONDITIONAL-PAUSE.

## Git safety constraints (paste-quotable, include verbatim in every Step 9 brief)

Every brief written in Step 9 MUST include this block verbatim under a "Git safety constraints" heading so the dispatched subagent inherits the same discipline forge-execute spawns its subagent with:

- **NEVER use `git push --force`.** It rewrites remote history and can clobber unrelated commits pushed between your last fetch and now.
- **NEVER use `git push --force-with-lease`.** It is the false-friend of `--force`: it checks only that the remote tip matches your last fetch, which on a stale local branch is exactly the wrong invariant. monday-bot's US-10 implementation subagent reached for `--force-with-lease` to recover from a rejected push; the user's deny rules caught it, but on a shared branch it would have overwritten unrelated work.
- **Fallback when a plain push is rejected:** `git pull --rebase origin <branch>`, resolve any conflicts surfaced by the rebase, then retry the plain `git push`. If conflicts cannot be cleanly resolved, surface them in the final summary as a blocker — do not force-overwrite.
- The deny rules at the harness layer are a backstop, not a contract. Treat this rule as the subagent's own discipline.

## Trust model (for Step 13 — what to verify vs trust)

| Subagent claim | Policy | Why |
|---|---|---|
| PR URL | **Always** verify via `gh pr view {PR} --json state,mergedAt,mergeCommit` | One-call cost; catches both fabricated and miscopied PR numbers |
| Binary AC pass/fail table | **Sample at least one AC** by re-running its verifier locally | Spot-check disincentivizes hallucinated PASS rows without re-running everything |
| Blocker description | **Read the actual error log** if a blocker is claimed | Subagents under stress sometimes generalize a transient blocker into a structural one |
| Narrative summary | **Trust unless contradicted** by other evidence | Re-reading every narrative defeats the workflow |

## Cairn save points (the self-improvement loop, woven into steps 4, 15, 17, 18)

Without explicit cairn integration the pipeline would *use* prior lessons (P3/I2 cite IDs) but never *contribute* new ones. Each pipeline run encodes:

- **Read (search-before-review)** — Stage P3 + Stage I2 search cairn before producing findings. From a subagent shell use the node CLI `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"` (the `/cairn find` Skill no-ops in a subagent shell). Citation discipline: every flagged violation cites an existing F-/P-ID OR explicitly says "no direct citation — judgment call."
- **Write — in-session capture** — when a reviewer or executor learns something non-obvious mid-arc, drop a `#cairn-stone:` marker inline in conversation OR invoke `/cairn place <text>` directly. The H2b Stop-event hook scans every message for the marker; matched lessons land in T1 scratch automatically (`~/.claude/cairn/t1-run-scratch/{date}/{session-id}.jsonl`).
- **Write — post-pipeline lesson save** — Step 17's ritual writes a working-memory tier-b card AND optionally `/cairn place`s lessons. Role split per CLAUDE.md `## Memory Systems`: decisions → working memory; lessons → cairn.
- **Graduation cadence** — Step 18's H4 hourly heartbeat (low gates) → T2 session-notes; H5 daily heartbeat (high gates: ≥2 sessions, no hardcoded paths, Jaccard dedup) → T3 knowledge-base; H6 weekly drift audit. **H4→H5 is the path** by which arc-level lessons become future-arc primer content.

## Known false-failure patterns (mid-flight obstacles + mitigations)

These come from real arc experience. Encoded so future executors don't re-discover.

- **`enforce-ship.sh` PreToolUse hook blocking the merge.** Symptom: `gh pr merge` blocked with "no ship-verification marker." Cause: chained `echo … > marker && gh pr merge` fires hook BEFORE chain runs; chain hadn't started; marker absent. **Mitigation:** split into TWO Bash calls — first `echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >.ai-workspace/ship-verified-<PR>`, then separately `gh pr merge <PR> --squash --delete-branch`.
- **`enforce-ship.sh` worktree-relative marker path (F-ENFORCE-SHIP-WORKTREE-MARKER).** When `/ship` happens inside a worktree (not the primary clone), the hook resolves marker path relative to the `cd` target inside the chained bash invocation. **Mitigation:** write the marker INSIDE the worktree's own `.ai-workspace/`, not just the primary clone's.
- **`gh pr merge` worktree quirk.** Symptom: `fatal: 'master' is already used by worktree at /path/to/parent`, non-zero exit. Cause: gh's local fast-forward step fails when the parent clone is on master AND there's an active worktree on master. The remote merge already succeeded by that point. **Mitigation:** verify state via `gh pr view {PR} --json state,mergedAt,mergeCommit`. If `state == "MERGED"`, merge worked — proceed.
- **Master drift during long-running slices.** Symptom: parallel slow bundle finds master rolled forward N tags during its window. **Mitigation:** merge-commit (NOT rebase) the master drift INTO the feature branch — `git fetch origin master && git merge origin/master`. Force-push protection blocks rebase.
- **GNU awk no `\b` (F-AWK-NO-WORDBOUNDARY).** GNU awk does not support `\b` for word boundaries. **Mitigation:** use anchored regexes like `^####? 10\.10\.8` followed by space-then-text instead of `^####? 10\.10\.8\b`.
- **Rate-limit kills background subagents (F-RATE-LIMIT-KILLS-SUBAGENTS).** Background subagents share account quota with parent session. When parent rate-limits, subagents stall on next inference call and do NOT auto-resume. Diagnostic fingerprint: both JSONL files stop writing within seconds, no `<task-notification>` arrives. **Mitigation:** inspect side-effects (worktrees + branches + PRs + commit logs); re-dispatch focused fresh subagents from recovered state. Don't try to resume via SendMessage.

## Project-index handling

Before invoking auto-flow, ensure `.ai-workspace/PROJECT-INDEX.md` is fresh:

| State | Action |
|---|---|
| **Absent** | Auto-invoke `/project-index`, emit status message |
| **Stale (>24h)** | Auto-invoke `/project-index`, emit status: "Refreshed PROJECT-INDEX.md (was N hours old)" |
| **Fresh (<24h)** | Proceed |
| **Refresh fails** | Abort — agent navigation depends on accurate index |

Auto-invoke is safe per the deterministic-skill-composition criterion (deterministic, short-running, single-file write).

## Quick start — typical invocation shape

```
1. User: "Ship the X arc — 4 bundles, disjoint write surfaces, dependency graph stable."
2. Agent: refuse-class checklist passes → file Plan-First plan → run P1→P2→P3→P4 chain
 → post Step 6 ELI5 + Rule 15 wait gate.
3. User: "approve all defaults".
4. Agent: decompose → 4 worktrees from origin/master → 4 self-contained briefs
 → SINGLE-message dispatch with run_in_background: true → task-list track.
5. Agent (while subagents run): drafts downstream brief, writes design doc, no polling.
6. Agent (on each notification): trust-but-verify per Step 13. Drift-conditional pause check.
7. After all units shipped: I1 + I2 reviews → /ship → tier-b card + /cairn place.
8. Cron does Step 18 graduation overnight.
9. Step 19 cleanup: mv arc worktrees to `.claude/worktrees/_quarantine-<date>-<arc-slug>/` per Rule 14, `git worktree prune`, delete merged local branches.
```

## Run Data Recording

After every arc (success, failure, or partial), persist run data to `runs/data.json` (create with `{"skill":"auto-flow","lastRun":null,"totalRuns":0,"runs":[]}` if missing). Append to `runs/run.log` (keep last 100 lines).

```json
{
 "timestamp": "{ISO-8601}",
 "outcome": "complete|partial|failed",
 "project": "{current project directory name}",
 "trigger": "{invocation string}",
 "planPath": "{path to filed plan}",
 "bundleCount": "{number of dispatched units}",
 "parallelBatchSizes": [3, 1],
 "wallClockMinutes": "{total elapsed}",
 "throughputRatio": "{wall-clock vs serial estimate}",
 "stagesReached": "{1|2|3|complete}",
 "blockersHit": ["F-ENFORCE-SHIP-WORKTREE-MARKER", "..."],
 "cairnIDsCited": {"P3": ["F36", "F66"], "I2": ["F50"]},
 "cairnStonesPlanted": "{count of #cairn-stone: markers + /cairn place invocations}",
 "tierBCardsWritten": "{count}",
 "driftPauseTriggered": "{true|false}",
 "summary": "{one-line outcome}"
}
```

Keep last 50 runs (older runs discarded). Do not fail the skill if recording fails — log a warning and continue.

After 5+ runs, invoke `/skill-evolve improve auto-flow` to mine the run data for refinement opportunities.

## Source provenance

- Source retrospective: `.ai-workspace/retrospectives/2026-04-28-multi-bundle-autonomous-arc.md` (+851 lines, 15 round-2 reviewer ACs PASS).
- Umbrella shipping plan: `.ai-workspace/plans/2026-04-28-auto-flow-skill-arc.md`.
- Phase 3 brief: `.ai-workspace/plans/2026-04-28-auto-flow-skill-creator-brief.md`.
- Foundational cairn lessons: F-AUTOFLOW-DRIFT-CONDITIONAL-PAUSE, F-DOCS-DEFER-UNTIL-DETERMINISTIC, F-ENFORCE-SHIP-WORKTREE-MARKER, F-AWK-NO-WORDBOUNDARY, F-RATE-LIMIT-KILLS-SUBAGENTS (all 2026-04-28).
- Demonstrated arcs: 2026-04-27 9-bundle reviewer-grounded arc (3-hour wall-clock); 2026-04-28..30 auto-flow shipping arc (this skill's own dogfood, 6 phases including the post-ship /coherent-plan sweep that produced this very entry).
