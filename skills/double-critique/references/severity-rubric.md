# Severity Rubric (frozen — do not edit per round)

This rubric is read by every Critic-N in the double-critique and coherent-plan loops. The loop's exit condition depends on the `blocks_ship` boolean on every finding, so the rubric is the single source of truth for how that flag is set. **It is frozen across rounds within a single run** — the orchestrator reads this file once at run-start and substitutes the rendered text into every critic prompt via the `<!-- SEVERITY RUBRIC -->` marker, so every round receives byte-identical rubric text. No round can drift.

## Severity Levels

- **CRITICAL** — the plan ships broken OR violates a hard gate (Plan-First Workflow, Worktree-for-shared-repos, mv-not-rm, Privacy, Always-PR). Examples: missing binary AC entirely, an AC that's verifiable only by reading the diff, a step that hard-codes a credential, a plan-touching path that the user has explicitly said is read-only. A CRITICAL finding is almost always `blocks_ship: true`.
- **MAJOR** — the plan ships incorrect OR contradicts another part of itself OR omits a load-bearing dependency. Examples: an AC that's checkable but proves the wrong thing; two sections that disagree about scope; a critical file listed in one section and absent from another; a verification command that doesn't actually verify the AC. Typically `blocks_ship: true`.
- **MINOR** — polish, naming, formatting, or stylistic concerns that don't affect correctness. Examples: inconsistent capitalization; a section header in the wrong heading level; a missing closing punctuation mark; a paragraph that could be tighter. **MINOR is never `blocks_ship: true`.**

## Calibration Anchor (Q3, Bundle 0c)

If you find yourself escalating something to MAJOR because you "haven't flagged anything else this round," it is a MINOR. The loop's clean-exit condition is `critical + major == 0` (the `cm_count`); treating polish as MAJOR creates spurious oscillation. Each round is an independent cold read — your job is to flag what the document actually fails on, not to manufacture findings to justify the round's existence. Silence is a valid output.

## The `blocks_ship` Flag

`blocks_ship` is a boolean that every finding must carry. It is the mechanical exit condition for the critique loop:

- `blocks_ship: true` iff the finding would cause a competent reviewer to **reject the document at merge time**. If the reviewer would say "fix this before I approve," it blocks ship.
- `blocks_ship: false` otherwise — even for MAJOR findings that are informational or advisory. Polish, preference, stylistic nit, and "nice to have" are **never** `blocks_ship: true`.

Setting `blocks_ship: true` is a judgment call — but it is a judgment about merge-gate behavior, not about how interesting the finding is. When in doubt, ask: "Would a staff engineer block the PR on this?"

## Evidence Requirement (P55, P61)

Every finding must carry an `evidence` field. Acceptable values:

- A direct quote from the document with a line or section reference: `"line 42: \"<exact quoted span>\""`
- A structural reference: `"Section: Risks & Mitigations, row 3"`
- `"UNVERIFIED"` — use this when you suspect a problem but cannot point at concrete evidence in the document.

**`UNVERIFIED` findings do not count toward the blocker total.** They are logged so the user can investigate, but they cannot block the critique loop. This prevents critics from inventing blockers to justify another round.

## Novelty Flag

Every finding must carry a `novel: true|false` flag. A finding is `novel: true` if it introduces a concern not implied by the document itself — for example, a claim about codebase behavior the document does not make. Novel findings get heightened scrutiny downstream (P61).

## Doctrine Flag (v1.2, 2026-04-25)

Every finding must carry a `doctrine` flag with one of two values:

- **`outcome-defect`** — the document fails as a *what/why* artefact. Examples: missing AC, contradictory invariant, undeclared goal, unsupported claim that the document itself makes, broken cross-reference, wrong file path the document explicitly cites, identity mismatch. The fix lives *inside* the document.

- **`how-defect`** — the document is fine as a *what/why* artefact but the critic wishes it prescribed *how* to do something. Examples: "exact bash command not given," "regex syntax not pinned," "env-var name not declared," "the exact mechanism for X is missing," "needs more specifics about which jq function to use." The fix would push implementation choice into the plan, violating the "Plan Intent: What and Why, Never How" doctrine in `${CLAUDE_PLUGIN_ROOT}/3-role-model.md`. These belong in code, prompts, executor briefs, or PR descriptions — not in the plan.

**Orchestrator-counting rule.** A finding with `doctrine: how-defect` does **NOT count toward `blocker_count`** even if the critic set `blocks_ship: true`. Same mechanic as `evidence: UNVERIFIED` — the field is recorded for audit but cannot block the loop. The corrector treats every `how-defect` finding as a candidate for deferral (see Corrector-N "Doctrine guard" section) and must explain its deferral reasoning per declined finding.

**Why this exists.** Without doctrine classification, a cold critic asking "what exact command does this run?" looks like a legitimate "vague" finding to the corrector, which then pins a command, which the next round's cold critic attacks for being GNU-only / using the wrong jq function / having a malformed escape. This is the perspective-diversity oscillation failure mode that halted four consecutive runs in 2026-04-13..14 and recurred in the 2026-04-25 memory-status-pass run (264→514 lines in one corrector round, then round-2 oscillation with R2-F4=R1-F11, R2-F5=R1-F14, R2-F7=R1-F9, R2-F8=R1-F6 — same gripes, opposite severity calls). The doctrine field lets the corrector mechanically recognize "this is a how-defect" and defer rather than pin.

### Wrong example — how-defect mis-classified as outcome-defect

```json
{
 "id": "F3",
 "severity": "MAJOR",
 "blocks_ship": true,
 "novel": false,
 "doctrine": "outcome-defect",
 "evidence": "Section: Verification step 2: \"the script auto-creates the parent dir\"",
 "finding": "The phrase 'auto-creates the parent dir' is vague — the plan should specify `mkdir -p ~/.claude/cairn/` to make the behavior explicit.",
 "why_blocks_ship": "A downstream executor would not know which exact command to run."
}
```

Wrong because: the document has stated the *outcome* ("parent dir is auto-created"); the critic is asking for the *implementation choice* (which exact `mkdir` invocation, which path, which permission mask). That choice belongs to the executor with code context, not the plan author. Correct doctrine is `how-defect`. The orchestrator would still count this toward `blocker_count` under the wrong classification, allowing HOW-creep into the plan.

### Right example — same finding correctly classified

```json
{
 "id": "F3",
 "severity": "MAJOR",
 "blocks_ship": true,
 "novel": false,
 "doctrine": "how-defect",
 "evidence": "Section: Verification step 2: \"the script auto-creates the parent dir\"",
 "finding": "The phrase 'auto-creates the parent dir' is vague — a cold reviewer cannot tell what mechanism is intended.",
 "why_blocks_ship": "A reviewer might reject merge if they expect command-level pinning."
}
```

Right because: the doctrine flag now tells the orchestrator to skip this finding for `blocker_count` purposes. The corrector's Doctrine guard will defer it with reason `planner-doctrine` (see Corrector-N template) and the executor — who has fresher code context than the plan author — chooses the mechanism. The finding survives in the deferred-comment block for audit but does not push HOW into the plan.

## Required JSON Output Schema

Critics must emit findings as a JSON array inside a fenced code block. Each finding is one object:

```json
{
 "id": "F1",
 "severity": "CRITICAL",
 "blocks_ship": true,
 "novel": false,
 "doctrine": "outcome-defect",
 "evidence": "line 42: \"the API returns 200 on success\"",
 "finding": "Section 3 claims the API returns 200 on success but Section 7 lists 204 as the success code — contradiction.",
 "why_blocks_ship": "A downstream test author would implement the wrong assertion based on whichever section they read first."
}
```

Required keys: `id`, `severity`, `blocks_ship`, `novel`, `doctrine`, `evidence`, `finding`. When `blocks_ship: true`, `why_blocks_ship` is **also required** and must be one sentence describing the merge-gate impact. A finding missing the `doctrine` key is a parse error — the orchestrator must abort the pipeline with a loud error naming the rule (same severity as missing `id` or `severity`).

### Wrong example

```json
{
 "id": "F1",
 "severity": "MAJOR",
 "blocks_ship": true,
 "novel": false,
 "doctrine": "outcome-defect",
 "evidence": "UNVERIFIED",
 "finding": "The tone of Section 2 feels slightly unclear."
}
```

Wrong because: (1) tone/clarity is polish, not a merge-gate concern — should be MINOR with `blocks_ship: false`; (2) `blocks_ship: true` combined with `evidence: UNVERIFIED` is a contradiction — unverified findings never block; (3) no `why_blocks_ship` justification.

### Right example

```json
{
 "id": "F2",
 "severity": "MAJOR",
 "blocks_ship": true,
 "novel": false,
 "doctrine": "outcome-defect",
 "evidence": "AC-6: 'grep -A2 Stage 0 SKILL.md | grep -q max_rounds'",
 "finding": "AC-6 assumes the halt clause appears within 2 lines of a 'Stage 0' header; the plan's Step 4 places the halt clause at the end of the Stage 0 section, beyond that window.",
 "why_blocks_ship": "The AC would false-fail on a correct implementation because the grep window is narrower than the intended placement."
}
```

## Isolation Reminder

You will not see prior rounds' critiques or the running issue list. Do not attempt to coordinate with other rounds or reference prior findings. Flag only what you can evidence from the document you are reviewing right now. Each round is an independent cold read.
