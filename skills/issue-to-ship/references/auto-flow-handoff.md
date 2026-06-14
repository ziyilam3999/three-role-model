# Auto-flow Stage-1 handoff contract

After the operator files the plan via `scripts/render-plan.sh`, hand off to `/auto-flow` Stage 1 — the four-reviewer chain (P1 → P2 → P3 → P4). This document is the exact contract for that handoff.

## Pre-conditions

- Plan file exists at `.ai-workspace/plans/<YYYY-MM-DD>-<slug>.md`.
- Plan has all 13 standard sections (verify via the synonym-aware grep used in this skill's AC-2).
- Plan's `## Last updated` section is initialized with the draft timestamp.
- The plan is filed against `origin/master` (no inherited assumptions from a stale local branch).

## Dispatch shape — sequential background subagents

P1 → P2 → P3 → P4 runs **sequentially** (each later reviewer's prompt requires the prior reviewer's output as input). But "sequential" does NOT mean "synchronous main turn":

- Each reviewer is dispatched via the **Agent tool with `run_in_background: true`**.
- The orchestrator waits for the runtime's completion notification before dispatching the next reviewer.
- During each wait, the main turn does prep work (snapshot the plan, apply prior-reviewer fixes, draft the next reviewer's prompt template).

This applies even to P4 (which is encoded as the `/coherent-plan` Skill). Inline a copy of `/coherent-plan`'s instructions into the P4 subagent's prompt; do NOT invoke the Skill directly on the main turn. Foreground / inline-Skill dispatch blocks the main turn for the full review window with zero benefit.

Source incident: 2026-05-01. Cross-reference: ${CLAUDE_PLUGIN_ROOT}/3-role-model.md Workflow Heuristics → Subagent Strategy → "Sequential ≠ foreground."

## Reviewer prompts — one-line missions

Each reviewer's prompt should include the plan path and one mission line.

- **P1 — Stateless generalist** (cold read; no cairn access; no prior version): "Structural completeness + binary-AC verifiability + critical-files reality check. Verdict: BLOCK | SHIP-WITH-MINOR-FIXES | SHIP-CLEAN."
- **P2 — Comparative-vs-prior-revision** (sees both original + P1's revision): "Did the revision actually help? Where is it still worse? Sister-plan token-shape collision check. Live cross-checks via `git show origin/master`. Verdict: same enum."
- **P3 — Cairn-grounded** (full `hive-mind-persist/` access; cites F-/P-IDs; runs `/cairn find <topic>` first): "Pattern citations P50/P6/P13/F2/F65/F68/Rule17/P19/P15/P17. Sister card cross-references. Line-number verification. Verdict: same enum."
- **P4 — Coherent-plan mechanical sweep** (use `/coherent-plan` for ≤150-line plans, `/double-critique` for ≥150-line architectural specs): "Internal contradictions, AC numbering monotonic, citation correctness; verify prior-pass fixes hold. Verdict: same enum."

## Post-each-round protocol

After each reviewer returns:

1. Capture the verdict (BLOCK | SHIP-WITH-MINOR-FIXES | SHIP-CLEAN) and the bug list.
2. Fold findings inline:
 - **Bugs** — always fix in the plan file.
 - **Enhancements** — selectively fold; defer or reject with reason.
3. Append to the plan's `## Last updated` section: timestamp, reviewer (P1/P2/P3/P4), verdict, fixes-applied summary.
4. If verdict is BLOCK, fix all bugs before dispatching the next reviewer.

## Post-P4 — hand to show-and-wait

After P4 returns SHIP-CLEAN, hand off to the show-and-wait gate (Stage 4 of this skill's workflow). Do NOT proceed directly to `/delegate` — the gate is the user-approval checkpoint.

## Failure modes to watch for

- **P1 over-correction** — P1 deletes load-bearing context; P2 should catch it.
- **P2 missing a sister-plan** — P3 has full cairn access and may surface what P2 missed.
- **P3 inventing a citation** — F65 self-violation. Verify every cited file path / line number lives where claimed.
- **P4 cumulative drift** — label drift, dead refs, contradicting AC. P4's mechanical sweep is the last line of defence.
