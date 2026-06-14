---
name: double-critique
version: 1.5.0
description: >
 Deep multi-agent critique pipeline that finds logical gaps, unsupported claims, missing edge
 cases, and internal contradictions in any document — then fixes them. Two independent critics
 review the document cold (seeing nothing about how it was made) to catch problems the author
 is blind to. Sweet spot is outcome-focused plans (WHAT+WHY); the doctrine guard and mid-loop
 drift-into-how detection keep HOW-creep out across the loop. Use when the user wants to review,
 critique, stress-test, or improve a PRD, SPEC, design doc, outcome plan, RFC, or any important
 document before it ships. Also use when the user says "critique this", "review this document",
 "find problems in", "stress test", "is this document solid", "what did I miss", "double critique",
 "run critique pipeline", "/double-critique path/to/file". Do NOT use for simple proofreading,
 grammar fixes, or formatting — this is a deep structural and logical review.
---

# Double-Critique Pipeline

Run a looping critique pipeline on the document at `$ARGUMENTS`: one-shot Researcher and Drafter, then a bounded Critic-N / Corrector-N loop, then a 3-stage feedback loop that extracts learnings, tracks effectiveness, and updates the knowledge base.

## Loop Configuration

max_rounds: 4

The loop runs at most `max_rounds = 4` critic/corrector pairs. Exit conditions are checked in this exact order each round: (1) `clean` — `blocker_count == 0`; (2) `oscillation` — `round >= 2 AND blocker_count > previous round's blocker_count` (strictly greater — see v1.0.1 note below); (3) `drift-into-how` — corrector output's sweet-spot shape transitioned `in-sweet-spot` → `unbounded-how` (v1.2, see Stage 0 mid-loop re-run below); (4) `max_rounds` — `round == max_rounds`. Oscillation and drift-into-how are checked before `max_rounds` so that a run which both fails one of those checks and hits the cap reports the more informative reason.

**v1.0.1 oscillation-rule change (2026-04-15):** the prior rule used `>=` which halted whenever a round's blocker count failed to *strictly decrease*. Because critic rounds are fully isolated (see line "Critics are fully isolated" below) and each round's fresh perspective can legitimately surface a similar *count* of entirely different issues, `>=` was firing on perspective-diversity — not genuine stalling. The new `>` rule halts only when things get measurably worse (count strictly increases), letting stable counts continue so the corrector gets another chance. `max_rounds=4` remains the unconditional upper bound. Evidence: four consecutive runs in 2026-04-13..14 (cairn-packaging, cairn-gap2-heartbeat x2, gap3-slash-command) exited with `exit_reason="oscillation"` despite the corrector applying 41–67% of findings per round — i.e. the system was working but the exit rule was too tight.

**FORCING FUNCTION:** If `max_rounds` is not declared in this SKILL.md, the orchestrator MUST **halt** before Stage 1 and print a loud error mentioning `max_rounds`. This is the F58-driven gate that prevents silent fallback to the pre-loop 2-round shape. Do not run any agent if this line is missing. (refuse run without max_rounds)

## Disposition Axis (Bundle 2c — 3×3 matrix)

Severity (CRITICAL / MAJOR / MINOR — defined in `references/severity-rubric.md`) answers *how bad is this finding*. **Disposition** answers *what does the corrector do about it* and is orthogonal to severity. Every finding the corrector touches resolves to exactly one of three dispositions:

- **`block`** — the finding is a defect the corrector MUST address before the loop can exit clean. The corrector edits the document to fix it. Failure to fix means the round does not converge.
- **`iterate`** — the finding is a defect the corrector should address by editing the document, but it is not a hard merge-gate. Round-tripping through another corrector pass is acceptable; the loop's `max_rounds` cap protects against runaway iteration.
- **`accept`** — the finding is a real concern the corrector chooses NOT to fix, with explicit named rationale. This disposition is introduced as the third disposition (replacing the implicit re-loop behavior of pre-Bundle-2c versions), and is named `accept` to keep it distinct from the round-trip "iterate" disposition above. Accepted findings get recorded in the corrected document's `## Downsides accepted` section with one-line rationale per finding. Acceptance turns a real trade-off into an *explicit* trade-off — the document tells future readers "we know about this, here's why we shipped anyway."

The disposition axis crosses severity to form a 3×3 guidance matrix. Use this table when classifying findings:

| Severity \ Disposition | block | iterate | accept |
|------------------------|--------------------------------------------------------|------------------------------------------------------|-------------------------------------------------------------------------|
| **CRITICAL** | refuse to ship; halt the loop until fixed | corrector MUST address; another round is allowed | accept ONLY with explicit named trade-off — staff-engineer-level review |
| **MAJOR** | refuse to ship if any remain at exit | corrector should address; round-trip is acceptable | accept with rationale; record in `## Downsides accepted` (mandatory) |
| **MINOR** | never blocks ship — re-classify as iterate or accept | nice-to-have; corrector may skip without justifying (implemented via Corrector-N deferred-block append — see loop step 7) | silent accept allowed; no entry in `## Downsides accepted` required |

**Mechanical mapping to existing rubric fields.** For backward compatibility with the rubric's `blocks_ship` boolean and `doctrine` flag (frozen across rounds — see Stage 0 step 4a):
- `block` corresponds to `blocks_ship: true AND doctrine: outcome-defect AND evidence != "UNVERIFIED"` — these are the findings that already drive `blocker_count` today.
- `iterate` corresponds to `blocks_ship: false AND doctrine: outcome-defect` — non-blocking outcome defects the corrector may still fix.
- `accept` is the corrector's deliberate choice to record a finding (of any severity) under `## Downsides accepted` with rationale, rather than fix it. The corrector logs an `ACCEPT [F#]: <one-sentence rationale>` line in its agent output for every accepted finding.

The disposition axis does NOT replace the severity rubric — it sits on top. A finding still carries `severity` and `blocks_ship` per the rubric; the corrector reads those fields and chooses a disposition consistent with the matrix above.

## Why This Pipeline Works

The core insight: authors can't see their own blind spots. When you write a document, your brain fills in gaps automatically. Two independent critics who see ONLY the finished document — with zero context about how it was made — catch things you never would. Isolation is the key: an informed reviewer unconsciously confirms decisions; an uninformed one challenges them.

Each stage is an independent Agent subagent. No shared context between stages — only file artifacts passed forward. Each agent receives at most 2 inputs: the original document + one prior artifact. Critics are fully isolated: they see ONLY the document, nothing else.

The pipeline's sweet spot is **outcome-focused plans** (WHAT+WHY only, binary AC, mechanism left to the executor). Multi-round loops are the right tool for outcome plans because (a) one isolated critic's correction can introduce a contradiction only the *next* round's critic spots, and (b) outcome plans are exactly the documents where /auto-flow's single-pass P1→P2→P3→P4 reviewer chain cannot loop back. The loop's `how-defect` doctrine filter (severity rubric line 46) and mid-loop drift-into-how check (loop step 8) keep the corrector from pinning HOW under critic pressure — those two mechanical safety nets, not the Stage 0 gate, are what make it safe to escalate outcome plans here.

## How to Use

```
/double-critique path/to/document.md [--force]
```

Works on **outcome-focused** document types: outcome plans (binary AC + WHAT/WHY only, no pinned commands), PRDs, SPECs, design docs, RFCs, architecture decision records. The Stage 0 sweet-spot pre-flight ARMS the pipeline for outcome plans — the loop's doctrine guard (`how-defect` filter at `references/severity-rubric.md:46`) and mid-loop drift-into-how detection (loop step 8) are the load-bearing safety nets that prevent HOW-creep across rounds. Does NOT work on **prescriptive HOW** plans (the kind that pin every command — `bash_blocks >= 10 AND doc_lines >= 300`) — the Stage 0 unbounded-how branch HARD BLOCKS those and redirects to `/coherent-plan` or to a leaner WHAT-rewrite. The `--force` flag overrides the unbounded-HOW block for **non-plan documents** that happen to match the heuristic (e.g. a SPEC with a long literal "deployment runbook" subsection); it is a doctrine violation to use `--force` on an actual implementation plan that has drifted into HOW. The pipeline creates a `tmp/` directory and writes each stage's output to `tmp/dc-{N}-{role}.md` for auditability.

If `$ARGUMENTS` is empty or the file doesn't exist, stop and ask the user for the file path.

## Pipeline Overview

| Stage | Role | Inputs | Output | Why It Exists |
|-------|------|--------|--------|---------------|
| 1 | Researcher | Document + KB | `tmp/dc-1-researcher.md` | Check claims against reality + build document inventory |
| 2 | Drafter | Document + Research | `tmp/dc-2-drafter.md` | Apply fixes with an editor's red pen |
| 3..N | Critic-N / Corrector-N loop | Latest corrected doc (isolated critic) + rubric | `tmp/dc-{2N+1}-critic-round{N}.md`, `tmp/dc-{2N+2}-corrector-round{N}.md` | Loop until `blocker_count == 0`, oscillation, or `max_rounds` |
| 7 | Orchestrator | `tmp/dc-loop-state.json` + all critic files | Appended to `$ARGUMENTS` | Compile the Critique Log (not an agent call) |
| 7.5 | Orchestrator (advisory) | `$ARGUMENTS` Critical-files section | Optional `## Advisories` section appended to `$ARGUMENTS` | Plan-time foresight for `index-check:` PR trailer (advisory-only; never blocks) |
| 8 | Extractor | Round-1 + round-N artifacts + per-round count table | `tmp/dc-8-extractor.md` | Figure out which rounds actually helped + track regressions |
| 9 | Effectiveness | Extraction + history | `tests/double-critique/effectiveness-{date}.md` | Track trends across runs, including Loop Stats |
| 10 | Retrospective | Effectiveness + KB | `tests/double-critique/retrospective-{date}.md` | Update the knowledge base with what we learned |

---

## Stage 0 — PRE-FLIGHT (not an agent)

Before launching any agent, the orchestrator (you) performs these cleanup steps:

1. **Forcing-function check — halt on missing `max_rounds`:** re-read the Loop Configuration section above. If the `max_rounds:` line is missing or the value cannot be parsed as a positive integer, **halt** immediately with a loud error: `"double-critique: max_rounds not declared in SKILL.md; refuse to run without max_rounds. Add 'max_rounds: 4' to the Loop Configuration section and retry."` Do not continue. This prevents silent fallback to the pre-loop 2-round shape (F58). The halt must fire before Stage 1.
2. Create `tmp/` directory if it doesn't exist.
3. **Delete all stale artifacts:** `mv tmp/dc-*.md tmp/dc-loop-state.json` to a quarantine path if any exist (per the global mv-not-rm rule). Empty quarantines may be cleared with `mv` afterwards. The fresh-state requirement matters because stages must not read leftover files from prior runs (Run 11 bug: Critic-2 reviewed a stale document from 3 days earlier). The loop-state file must also never survive across runs.
4. Verify the source document at `$ARGUMENTS` exists and is non-empty.
4a. **Freeze the severity rubric (Q3 — Bundle 0c).** Read `references/severity-rubric.md` ONCE into memory at run-start (cache the full text as `RUBRIC_FROZEN`). Every critic round in the loop receives this byte-identical text via `<!-- SEVERITY RUBRIC -->` marker substitution in the Critic-N prompt template. Do NOT re-read the rubric file mid-loop; do NOT let the per-round critic prompt fetch the file at agent runtime. The single read at run-start is what makes the rubric frozen across rounds — even if the file is edited mid-run (e.g., by an unrelated process), every round of THIS run uses the snapshot taken at run-start. Verification: see `scripts/severity-rubric-pinning.test.sh` (AC-8).
5. **Sweet-spot pre-flight (v1.5.0, 2026-05-02 — inverted from v1.0.1):** double-critique's sweet spot is **outcome-focused plans (WHAT+WHY)** — the kind CLAUDE.md's "Plan Intent: What and Why, Never How" doctrine elevates. Prescriptive HOW plans with unbounded surface area now fall OUTSIDE the sweet spot and are hard-blocked. Classify the input document, emit the appropriate Stage 0 message, and either arm the pipeline or halt accordingly.

 **Detection heuristic (cheap, read-only — thresholds unchanged from v1.0.1):**
 - `bash_blocks` = count of fenced code blocks tagged `bash`/`sh`/`shell` in the document.
 - `ac_markers` = count of lines matching `(?i)^#+\s*(binary\s*ac|goal|invariant|outcome|out\s*of\s*scope)` — headings that signal outcome-focused structure.
 - `doc_lines` = total non-blank lines.

 **Sweet spot — outcome-focused (PIPELINE ARMED):** `ac_markers >= 3 AND bash_blocks <= 2`. These plans name *what* must be true and let the executor pick *how*. The loop's doctrine guard (`how-defect` filter at `references/severity-rubric.md:46`) and mid-loop drift-into-how detection (loop step 8) prevent HOW-creep across rounds. Emit a one-line confirmation and proceed to Stage 1:
 ```
 ✓ double-critique: input is outcome-focused ({ac_markers} AC-style headings, {bash_blocks} bash blocks) — this is the post-v1.5 sweet spot; pipeline armed; doctrine guard + drift-into-how detection enforced across rounds.
 ```
 Record `"sweetSpotShape": "outcome"` in `tmp/dc-loop-state.json` for effectiveness tracking and seed `shapeTransitions` (see below).

 **HARD BLOCK — prescriptive HOW with unbounded nit surface area:** `bash_blocks >= 10 AND doc_lines >= 300`. These plans pin every command; each perspective-isolated critic round (see "Critics are fully isolated" below) finds DIFFERENT nits at similar counts, and the loop oscillates without converging. They also violate the CLAUDE.md "Plan Intent: WHAT+WHY, never HOW" doctrine by leaving the executor no mechanism choice. Halt immediately — do NOT proceed to Stage 1. Emit:
 ```
 ✗ double-critique: input is prescriptive/how-focused ({bash_blocks} bash blocks across {doc_lines} lines) — HARD BLOCK. Plans focus on WHAT+WHY, never HOW (CLAUDE.md). Rewrite as outcomes + intent (binary AC, mechanism left to the executor) before re-running, or escalate to /coherent-plan if the rewritten plan is small enough. Halt immediately — do NOT proceed to Stage 1.

 If this is NOT a plan (e.g. a SPEC, PRD, or RFC with a long literal "deployment runbook" subsection that incidentally exceeds the threshold), re-run with --force to override. --force on an actual implementation plan is a doctrine violation — rewrite the plan as WHAT+WHY instead of overriding the gate.
 ```
 Exit 0 without continuing to Stage 1. Record `"sweetSpotShape": "unbounded-how"` and `"blockedAtPreFlight": true` in `tmp/dc-loop-state.json`. The `--force` flag overrides this hard-block for the non-plan edge case only.

 **Both shapes / ambiguous:** if the document matches neither sweet-spot nor unbounded-how (or both), skip the message silently and proceed. The pipeline runs with `"sweetSpotShape": "in-sweet-spot"` recorded for the mid-loop drift baseline. The sweet spot is outcome-focused and bounded; ambiguous inputs are advisory-pass.

 Emit the sweet-spot confirmation OR the unbounded-how hard-block message ONCE before Stage 1. Do not re-emit inside the critic loop. **Unbounded-how halts the pipeline at Stage 0** (unless `--force` was passed on a non-plan document); outcome-shaped and ambiguous inputs proceed. Record the detected shape in `tmp/dc-loop-state.json` as `"sweetSpotShape": "outcome" | "unbounded-how" | "in-sweet-spot"` for Stage 9 effectiveness tracking. When unbounded-how halts, also record `"blockedAtPreFlight": true`. **v1.2 mid-loop seed (unchanged):** also seed `"shapeTransitions": ["<detected-shape>"]` so the per-round drift check (loop step 8) has a baseline to compare against.

## Stages 1-2 — Single-shot Pre-Loop

Run these two stages **once**, sequentially. Full prompts are in `references/stage-prompts-core.md`.

### Stage 1 — RESEARCHER
**Role:** Fact-checker, librarian, and document analyst. Builds a structured inventory of the document, then verifies claims against the codebase and the full hive-mind-persist tree.
**Inputs:** Document at `$ARGUMENTS` + the full `hive-mind-persist/` tree. Reviewers MUST ground in ALL of the following nine members (not just `knowledge-base/` + `memory.md`):
- `hive-mind-persist/constitution.md`
- `hive-mind-persist/design-rules.md`
- `hive-mind-persist/design-system.md`
- `hive-mind-persist/document-guidelines.md`
- `hive-mind-persist/knowledge-base/`
- `hive-mind-persist/memory.md`
- `hive-mind-persist/proposals/`
- `hive-mind-persist/session-notes/`
- `hive-mind-persist/case-studies/`

**Output:** `tmp/dc-1-researcher.md`
**Why:** Documents often contain assumptions that sound right but aren't. The Researcher checks them against reality — environment compatibility, deployment feasibility, codebase evidence, failure modes, and prior governance/design decisions captured in the full hive-mind-persist tree (constitution, design rules, design system, document guidelines, proposals, session notes, case studies). Grounding only in `knowledge-base/` + `memory.md` misses constitutional violations, governance precedents, and design-system invariants.

Auto-detects its own environment — no manual placeholder injection needed.

See `references/stage-prompts-core.md` > Stage 1 for the full agent prompt.

### Stage 2 — DRAFTER
**Role:** Editor with a red pen. Applies research findings to improve the document.
**Inputs:** Document at `$ARGUMENTS` + `tmp/dc-1-researcher.md`
**Output:** `tmp/dc-2-drafter.md`
**Why:** Translates research findings into concrete document improvements while preserving the author's voice. Verifies upstream claims before incorporating them. Uses **evidence-gated verification** — must paste actual code/config evidence for every "I verified X" claim.

See `references/stage-prompts-core.md` > Stage 2 for the full agent prompt.

## Stages 3..N — Critic-N / Corrector-N Loop

The orchestrator runs a bounded loop. Each round spawns a fully isolated critic followed (conditionally) by a corrector. Full prompt templates are in `references/stage-prompts-core.md` > "Critic-N (ISOLATED) — Loop Template" and "Corrector-N — Loop Template". The critic must emit findings as a JSON array conforming to `references/severity-rubric.md`.

**Loop state** lives in `tmp/dc-loop-state.json`. The orchestrator owns this file. **No agent prompt ever references this file or any data it contains** — this preserves isolation (F24).

Initialize loop state before the first round:
```json
{"round": 0, "max_rounds": 4, "per_round": [], "exit_reason": null, "latest_corrected_doc": "tmp/dc-2-drafter.md", "shapeTransitions": ["<input-doc-shape-from-stage-0>"]}
```

The `shapeTransitions` array is seeded with the Stage 0 detected shape of the input document (`"in-sweet-spot"`, `"unbounded-how"`, or `"outcome"`). Each Corrector-N round appends one entry — the shape of that round's corrected doc — for the mid-loop drift-into-how check (step 8 below).

Then loop:

1. `round += 1`.
2. **Spawn Critic-N.** Render the Critic-N prompt by substituting (a) `{N}` with `round`, (b) `{CORRECTED_DOC_PATH}` with `latest_corrected_doc`, and (c) the `<!-- SEVERITY RUBRIC -->` marker with the `RUBRIC_FROZEN` text cached in Stage 0 step 4a. The marker substitution is byte-identical across rounds — the rubric text is captured ONCE at run-start (Stage 0) and reused for every round of this run. This is the Q3 mechanism that prevents per-round rubric drift. Write the critic's output to `tmp/dc-{2*round+1}-critic-round{round}.md`. For diagnostic purposes and AC-14, also save the exact prompt text sent to the critic at `tmp/dc-agent-prompts/critic-round{round}.txt` — this lets the pinning test (AC-8) verify the rendered rubric text is identical between rounds.
3. **Parse the critic JSON.** Locate the single fenced code block containing a JSON array. `JSON.parse` it. On parse failure: loud error, log the raw output, abort the pipeline (F45, P44 — never silent).
4. **Compute round metrics:**
 - `blocker_count = count(findings where blocks_ship == true AND evidence != "UNVERIFIED" AND doctrine != "how-defect")` — v1.2 adds the doctrine filter; same mechanic as `UNVERIFIED`. A finding missing the `doctrine` field aborts the pipeline (parse error per the rubric).
 - `critical = count(severity == "CRITICAL")`, `major = count(severity == "MAJOR")`, `minor = count(severity == "MINOR")`
 - `novel = count(novel == true)`, `unverified = count(evidence == "UNVERIFIED")`
 - `how_defect = count(doctrine == "how-defect")` — recorded for audit; does not affect `blocker_count` directly (already filtered above).
5. **Append to `per_round`:**
 ```json
 {"round": N, "blocker_count": B, "cm_count": (C + M), "critical": C, "major": M, "minor": m, "novel": X, "unverified": U, "how_defect": H}
 ```
 `cm_count = critical + major` is the Bundle 0c canonical name used by the runs/data.json `loop.per_round[*].cm_count` field (see Run Data Recording). It mirrors `blocker_count` exactly when no findings carry `evidence: UNVERIFIED` or `doctrine: how-defect` (i.e., when nothing is filtered out of the blocker total). The two fields are recorded side-by-side so post-hoc analyzers can read either name.
6. **Exit checks (in this exact order — matches Decision #3 of the plan and AC-7):**
 - If `blocker_count == 0` AND the latest corrected doc contains a `## Downsides accepted` section with at least one finding listed AND a non-empty rationale: set `exit_reason = "clean"`, break out of the loop. **Both gates apply — zero unaddressed CRITICAL/MAJOR AND a non-empty `## Downsides accepted` section.** (Bundle 2c — Edit E.) When the round genuinely produced no accepted trade-offs, the rationale itself MUST say so explicitly — sample wording: "no accepted trade-offs in this round; all findings either resolved or escalated". The corrector's job in that case is to author one explicit no-op line under `## Downsides accepted` rather than leave the section empty or absent. Silence is not allowed: an empty or missing section keeps the loop running. This turns the "we shipped without weighing trade-offs" failure mode into a forcing function — every passing run carries an explicit trade-off statement.
 - If `round >= 2 AND blocker_count > per_round[round-2].blocker_count`: set `exit_reason = "oscillation"`, break. (v1.0.1: strict `>`, not `>=`. Same count across perspective-isolated critic rounds is NOT oscillation — different critics legitimately find different-perspective issues. See Loop Configuration section.)
 - If `round == max_rounds`: set `exit_reason = "max_rounds"`, break. **Note:** the `## Downsides accepted` requirement does NOT apply on `oscillation` or `max_rounds` exit — those are failure modes, not clean exits. Only `exit_reason = "clean"` requires the section.
7. **Spawn Corrector-N.** Substitute `{N}`, `{CORRECTED_DOC_PATH}`, and `{CRITIC_FINDINGS_PATH}` (= the critic output path from step 2) in the Corrector-N template. Write the corrector's output to `tmp/dc-{2*round+2}-corrector-round{round}.md`. Set `latest_corrected_doc` to this new path.
8. **Mid-loop sweet-spot re-run (v1.2, drift-into-how detection).** After Corrector-N writes its output, re-run the Stage 0 sweet-spot heuristic against `tmp/dc-{2*round+2}-corrector-round{round}.md` using the same `bash_blocks` / `ac_markers` / `doc_lines` formula. Append the resulting shape to `shapeTransitions` in `tmp/dc-loop-state.json` (initial entry is the input doc's shape, recorded by Stage 0). Then check the **drift-into-how** condition:
 - If the recorded transition for the most recent two entries is `in-sweet-spot` → `unbounded-how`: set `exit_reason = "drift-into-how"`, persist the corrected doc as the final artefact, break out of the loop.
 - Otherwise continue.
 The `unbounded-how` shape uses the Shape-2 thresholds from Stage 0 (`bash_blocks >= 10 AND doc_lines >= 300`). The detection is intentionally conservative — only flags when the corrected doc has clearly drifted into the how-focused trap, not when a single new code block was added. The check fires AFTER the corrector writes, so the drifted doc is preserved at `tmp/dc-{2*round+2}-corrector-round{round}.md` for audit and is the final artefact (the doctrine guard in the corrector should have prevented the drift; if it fired anyway, halting prevents round (N+1)'s critic from attacking the new pinnings).
9. Persist `tmp/dc-loop-state.json` after each round so the state survives context loss (F30).
10. Return to step 1.

**On loop exit:**
- Copy `latest_corrected_doc` (if the loop exited via Corrector output) or the final corrector output to `$ARGUMENTS` and to `tmp/dc-final.md`.
- Note: when the loop exits with `exit_reason = "clean"` on round N, the last-applied document is the corrector output from round N-1 (or `tmp/dc-2-drafter.md` if round 1 was already clean). The round-N critic found zero blockers, so no further correction was needed.
- When the loop exits with `exit_reason = "drift-into-how"` on round N, the corrector for round N has already written its drifted output. That output IS the final artefact (the user gets the document as-drifted so the audit trail is intact); the orchestrator does NOT roll back to round N-1. The Critique Log must call out the drift transition explicitly.
- Persist `tmp/dc-loop-state.json` with the final `exit_reason`.

**exit_reason precedence (canonical):** `clean` → `oscillation` → `drift-into-how` → `max_rounds`.

---

## Stage 7 — ORCHESTRATOR EPILOGUE (not an agent)

**Telemetry signal (2026-05-06 harvest of 24 lifetime runs):** 19 `complete` + 1 `no-issues` outcomes; recurring observed pattern across runs is a **Corrector-1 regression count drifting upward (0 → 1 → 2 across consecutive runs)** even when `complete` is reported. The `complete` outcome is necessary but not sufficient — Corrector-1 quality is a separate trend worth watching. When the Corrector-1 regression count is non-zero in two consecutive runs, the orchestrator should flag this in the Stage 7 summary line (e.g., "watch: Corrector-1 regressions trending {prev}→{curr}") so the operator can intervene before the trend hardens. Corrector-2 self-catches have emerged as a strength — keep that signal visible too.

After the loop exits, the orchestrator (you) performs these steps directly:

1. Read `tmp/dc-loop-state.json` and every `tmp/dc-*-critic-round*.md` file it references.
2. For each round in `per_round`, tally `{critical, major, minor, blocker_count, novel, unverified, how_defect}` and list which findings were applied (blocking, now fixed) vs. deferred (non-blocking OR `doctrine == "how-defect"`, preserved in the `<!-- deferred:critic-N -->` block — note `planner-doctrine` reason on doctrine-deferred entries) vs. skipped (the corrector explicitly rejected a blocking outcome-defect finding — these MUST be listed with the corrector's stated reason). Doctrine-deferral counts go into `doctrineDeferralCount`; how-defect totals go into `howDefectCount`.
3. Append a `## Critique Log` section to the file at `$ARGUMENTS` using the template from `assets/critique-log-template.md`. The summary line must read:
 ```
 Loop ran {roundsRun} round(s), exit_reason={exit_reason}, final blocker_count={N}, total findings applied={N}, total findings deferred={N}, how-defect findings={N}, doctrine deferrals={N}, shape transitions={input → r1 → r2 →...}.
 ```
4. Report the same summary to the user along with the critique log.

---

## Stage 7.5 — INDEX-CHECK ADVISORY (not an agent, advisory-only)

After Stage 7 (ORCHESTRATOR EPILOGUE) and BEFORE Stage 8 (EXTRACTOR), the orchestrator (you) performs a **non-blocking** advisory scan. This step never affects the pipeline's exit code, never re-loops, and never edits the corrected document body — it only appends a small `## Advisories` section if the trigger fires. It is purely plan-time foresight; the hard `index-check:` trailer gate already lives in `/ship` Stage 5.5.

**What to scan:** open the plan file at `$ARGUMENTS` (the same file the rest of the pipeline already wrote to) and locate its `Critical files` section (or any equivalent heading the plan uses to enumerate touched paths — common variants: `## Critical files`, `### Critical files`, `## Critical files (master list across bundles)`, `## Modified files`, `## New files`, `## Files`). Read every path-shaped token under that section.

**Trigger condition:** at least ONE listed path matches any of the three cairn-trailer-gated trees:

- `hive-mind-persist/knowledge-base/**`
- `hive-mind-persist/memory.md` (exact path)
- `hive-mind-persist/session-notes/**`

The match is path-prefix based; a leading repo-name prefix is optional (some plans qualify the path with the repo prefix, others don't). Both `knowledge-base/01-proven-patterns.md` and `<repo>/knowledge-base/01-proven-patterns.md` count as matches.

**On match (≥1 gated path listed):** append a `## Advisories` section to the file at `$ARGUMENTS` (after the `## Critique Log` section emitted by Stage 7). The section header is the literal line `## Advisories` (grep-able from downstream automation). Body is a single one-line bullet:

```
## Advisories

- index-check: this plan touches `hive-mind-persist/` cairn-trailer-gated paths. Include `index-check: <ID-list> | none | skip -- <reason>` in the eventual PR body per `/ship` Stage 5.5 honor-system gate.
```

**On no match (zero gated paths listed):** emit NOTHING. Do not append a `## Advisories` section, do not add a placeholder, do not record a "no advisories" line. Deterministic absence — downstream automation that greps for `## Advisories` correctly returns zero lines on plans that don't touch the gated trees.

**Exit code unchanged:** this step is purely additive output. The pipeline's exit code is determined entirely by Stages 1–7 and Stage 8/9/10; Stage 7.5 cannot fail the pipeline.

**Why it exists:** plans that touch `hive-mind-persist/knowledge-base/**`, `hive-mind-persist/memory.md`, or `hive-mind-persist/session-notes/**` need an `index-check:` trailer in the eventual PR body. The hard gate fires at `/ship` time, but plan-time foresight reduces the round-trip cost — the executor sees the reminder when reading the corrected plan, not when the ship pipeline blocks them.

**Why advisory-only (not a hard gate here):** the hard gate exists in `/ship` Stage 5.5; double-gating is duplication. /double-critique runs against a plan file before any PR exists, so it cannot inspect a PR body — it can only flag the upcoming need. Hard enforcement stays at the place where a PR body actually exists.

**Why a stable header:** `## Advisories` is grep-able. Downstream automation can detect "this plan was flagged for index-check" with a single `grep -q '^## Advisories$'` against the corrected plan file, no prose parsing required.

---

## Stages 8-10 — Feedback Loop

Run these stages **sequentially** after Stage 7.5 (the advisory step never blocks; it either appends `## Advisories` or emits nothing, then control falls through to Stage 8). Full prompts are in `references/stage-prompts-feedback.md`.

### Stage 8 — EXTRACTOR
**Role:** Sports analyst reviewing game tape. Figures out which stages actually helped.
**Inputs:** All 6 `tmp/dc-*.md` artifacts + Critique Log
**Output:** `tmp/dc-8-extractor.md`
**Why:** Without this, we keep running all 6 stages forever even if some contribute nothing. This is how the pipeline learns about itself. Also tracks **regression counts** (defects introduced by Drafter and Corrector-1) and **evidence-gating compliance** as first-class metrics.

See `references/stage-prompts-feedback.md` > Stage 8 for the full agent prompt.

### Stage 9 — EFFECTIVENESS
**Role:** Doctor reviewing the patient's chart across multiple visits.
**Inputs:** `tmp/dc-8-extractor.md` + historical reports in `tests/double-critique/`
**Output:** `tests/double-critique/effectiveness-{date}.md`
**Why:** One run tells you nothing. Tracking trends across runs reveals which stages consistently help and which are dead weight. Now includes **regression tracking table** and **evidence-gating compliance** as first-class metrics alongside finding counts and application rates.

Replace `{date}` with today's date in YYYY-MM-DD format.

See `references/stage-prompts-feedback.md` > Stage 9 for the full agent prompt.

### Stage 10 — RETROSPECTIVE
**Role:** Team retrospective facilitator. Updates the knowledge base with what we learned.
**Inputs:** Effectiveness report + `hive-mind-persist/knowledge-base/` files + `hive-mind-persist/memory.md`
**Output:** `tests/double-critique/retrospective-{date}.md` + updates to `hive-mind-persist/memory.md` and optionally `hive-mind-persist/knowledge-base/`
**Why:** Like writing notes in a recipe book — if you don't write down what you learned, you'll make the same mistakes next time.

Replace `{date}` with today's date in YYYY-MM-DD format.

See `references/stage-prompts-feedback.md` > Stage 10 for the full agent prompt.

---

## Execution Notes

- Run stages 1-6 **sequentially** — each depends on the previous stage's output.
- Stage 7 is orchestrator work, not an agent call.
- Stage 7.5 is orchestrator advisory work, not an agent call. It appends `## Advisories` to `$ARGUMENTS` only when the plan's Critical-files section names ≥1 path under `hive-mind-persist/knowledge-base/**`, `hive-mind-persist/memory.md`, or `hive-mind-persist/session-notes/**`; otherwise it emits nothing. It never affects the pipeline's exit code.
- Run stages 8-10 **sequentially** after Stage 7.5 — this is the feedback loop.
- Stage 8 reads all `tmp/dc-*.md` artifacts. Stage 9 reads historical reports. Stage 10 updates KB/memory.
- Replace `{date}` in stage prompts with today's date (YYYY-MM-DD format).
- If `$ARGUMENTS` is empty or the file doesn't exist, stop and ask the user for the file path.
- Environment detection: Stage 1 (Researcher) auto-detects its own environment — no orchestrator injection needed.
- Create `tmp/` directory if it doesn't exist before starting.

## Run Data Recording

After the pipeline completes (or errors out), persist run data. This section always runs.

**Resolve the skill base directory** from the symlink target (the skill's source directory), not the current working directory.

### What to record

Append to `runs/data.json` (create with `{"skill":"double-critique","lastRun":null,"totalRuns":0,"runs":[]}` if missing):

```json
{
 "timestamp": "{ISO-8601}",
 "outcome": "complete|no-issues|error",
 "project": "{current project directory name}",
 "documentPath": "{path to reviewed document}",
 "totalFindings": "{N total findings summed across all rounds}",
 "criticalCount": "{N critical summed across rounds}",
 "majorCount": "{N major summed across rounds}",
 "minorCount": "{N minor summed across rounds}",
 "applicationRate": "{percentage of findings applied, e.g. 85}",
 "stagesCompleted": "{number of stages that ran, 0-10}",
 "roundsRun": "{N critic rounds actually executed, 1..max_rounds}",
 "exitReason": "clean|oscillation|drift-into-how|max_rounds",
 "maxRounds": "{value of max_rounds for this run, e.g. 4}",
 "perRoundBlockers": "[N_round1, N_round2,...] // blocker_count for each round, in order",
 "howDefectCount": "{N findings classified doctrine='how-defect', summed across rounds}",
 "doctrineDeferralCount": "{N findings deferred by the corrector with reason 'planner-doctrine', summed across rounds}",
 "shapeTransitions": "[shape_input, shape_after_corrector_1, shape_after_corrector_2,...] // sweet-spot shape per round, in order",
 "loop": {
 "rounds_run": "{N critic rounds actually executed, mirrors top-level roundsRun}",
 "exit_reason": "clean|oscillation|drift-into-how|max_rounds (mirrors top-level exitReason)",
 "max_rounds": "{value of max_rounds, mirrors top-level maxRounds}",
 "per_round": [
 {
 "round": "{1..rounds_run}",
 "critical": "{N critical findings this round}",
 "major": "{N major findings this round}",
 "minor": "{N minor findings this round}",
 "cm_count": "{critical + major this round — drives the strict-decrease oscillation check}"
 }
 ],
 "final_cm_count": "{cm_count of the last round actually run, 0 on clean exit}"
 },
 "summary": "{one-line: e.g., 'spec.md, 8 findings (2C/3M/3m), 88% applied, 3 rounds (clean)'}"
}
```

The loop fields are **additive and backward compatible** (P50). Existing runs without `roundsRun`/`exitReason`/`maxRounds`/`perRoundBlockers`/`howDefectCount`/`doctrineDeferralCount`/`shapeTransitions`/`loop` load cleanly — readers should treat missing fields as undefined, not as errors. The v1.2 doctrine fields (`howDefectCount`, `doctrineDeferralCount`, `shapeTransitions`) are forward-only — historical entries are not backfilled.

**Bundle 0c — `loop` object (Q5).** The nested `loop` object is the Bundle 0b plan's canonical schema for per-round telemetry. It is added alongside the existing flat `roundsRun`/`exitReason`/`maxRounds`/`perRoundBlockers` fields rather than replacing them — the flat fields stay for one release cycle for any reader that already consumes them, and the new nested shape is what post-hoc analyzers should read going forward. Both shapes are populated on every post-0c run; readers picking exactly one are explicitly correct. The `loop.per_round[*].cm_count` field is `critical + major` for that round and is the value the strict-decrease oscillation check compares across rounds. `loop.final_cm_count` equals the last round's `cm_count` (0 on `exit_reason="clean"`, > 0 on `oscillation` or `max_rounds`).

**Outcome values:**
- `complete` — review ran, findings were found and addressed (this includes runs that exited with `drift-into-how`; the run completed but tripped the doctrine guard, recorded via `exitReason`)
- `no-issues` — review ran, zero findings
- `error` — skill could not complete (file not found, agent failure, JSON parse error including missing `doctrine` field, etc.)

Keep last 50 runs (older runs are permanently discarded). Set `lastRun` and increment `totalRuns`.

Append one line to `runs/run.log` (keep last 100 lines):
```
{timestamp} | {outcome} | {documentPath} | {criticalCount}C/{majorCount}M/{minorCount}m | {applicationRate}% applied | {summary}
```

Do not fail the skill if recording fails — log a warning and continue.
