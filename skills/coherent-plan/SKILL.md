---
name: coherent-plan
version: 1.2.0
description: Quick consistency review for small plans and strategy docs. Finds contradictions, fixes them, and produces a coherent final version. Use when the user says "/coherent-plan", "review this plan", "check for contradictions", or wants a fast consistency pass on a plan file (under ~150 lines). For large implementation specs (200+ lines with architecture and file specs), use /double-critique instead.
---

# Coherent Plan

Bounded-loop consistency review for small plans. Lighter and faster than /double-critique. Loops at most twice; exits on clean / oscillation / max_rounds — same exit-reason vocabulary as /double-critique.

## Loop Configuration

max_rounds: 2

The loop runs at most `max_rounds = 2` critic/corrector pairs. Exit conditions are checked in this exact order each round: (1) `clean` — `cm_count == 0` where `cm_count = critical + major`; (2) `oscillation` — `round >= 2 AND cm_count >= previous round's cm_count` (strict-decrease violation per the Bundle 0b plan; same count or worse halts the loop because the corrector did not make progress); (3) `max_rounds` — `round == max_rounds`. Critical asymmetry (matches /double-critique): on `clean` and `oscillation`, the loop exits BEFORE running corrector_N (no work left, or corrector_N would re-attempt the same problem space). On `max_rounds`, the loop runs corrector_N before exit so the user gets one final round of corrections at the budget cap.

Why max_rounds=2 (not 4 like /double-critique): coherent-plan is the cheap skill — small plans, single-pass historically. A 2-round cap matches the historical envelope while still letting the corrector apply the critic's findings once and re-verify on round 2. Any plan that wants more than 2 rounds has outgrown coherent-plan and should escalate to /double-critique (the existing escalation rule above already handles this case).

**FORCING FUNCTION:** If `max_rounds` is not declared in this SKILL.md, the orchestrator MUST **halt** before Step 1 and print a loud error mentioning `max_rounds`. This is the F58-driven gate that prevents silent fallback to the pre-loop single-pass shape.

## When to Use

- Strategy docs, dogfood plans, workflow specs under ~150 lines
- Iterative plan refinement (multiple review rounds in one session)
- Any plan where a quick contradiction check beats a full 10-stage pipeline

## How to Use

```
/coherent-plan path/to/plan.md --topic "<topic>"
```

Both arguments are **required**:

- `path/to/plan.md` — the file under review.
- `--topic "<topic>"` — short phrase used to seed the cairn knowledge-base lookup that runs before Step 1 (Inventory). The topic is what you would pass to `/cairn find`; pick the smallest phrase that scopes the relevant prior art (e.g. `"decision capture"`, `"oscillation guard"`, `"plan precedence"`).

**FORCING FUNCTION — required `--topic`:** if `$ARGUMENTS` is missing the `--topic` argument (or `--topic` is present with an empty / whitespace-only value), the orchestrator MUST **halt** before Step 1 and exit non-zero with the literal usage message:

```
✗ coherent-plan: missing required argument --topic <topic>.
 Usage: /coherent-plan <path-to-plan> --topic "<topic>"
 The topic seeds the cairn knowledge-base lookup that runs before Step 1.
```

Do not run any review step if `--topic` is absent. This is the F58-driven gate that prevents the skill from silently regressing to its pre-1.1.0 shape (no cairn grounding).

If `path/to/plan.md` is omitted entirely, ask the user for the file path before exiting non-zero.

## Workflow

### Step 0: Cairn Lookup (always runs, deterministic shape)

Before Step 1 (Inventory), the orchestrator (you) executes `/cairn find <topic>` with the value of `--topic` and prepends a `## Cairn lookup` section to the review output (the report printed in Step 4 AND the corrected plan file written by the corrector inside the Steps 2+3 loop, if the section is not already present at the top). The section is **always emitted** — its presence is part of the deterministic shape, regardless of hit count.

**Section contract:**

- Header: literal line `## Cairn lookup` (grep-able from downstream automation).
- Sub-header: one line `Topic: <topic>` echoing the `--topic` value.
- Body: up to **3** entries from `/cairn find <topic>`, each entry showing the source path + a one-line relevance excerpt (the cairn skill already returns ranked top-N hits; take the first 3).
- Zero-hits case: when `/cairn find` returns no results, the body is the single literal line `no matching cairn entries`. The section is still emitted.

**Format:**

```
## Cairn lookup

Topic: <topic>

1. <source-path> — <one-line relevance excerpt>
2. <source-path> — <one-line relevance excerpt>
3. <source-path> — <one-line relevance excerpt>
```

Or, on zero hits:

```
## Cairn lookup

Topic: <topic>

no matching cairn entries
```

The section is the FIRST thing in the review output (before any inventory). Downstream tooling can grep for the literal `## Cairn lookup` header to detect that the lookup ran.

### Step 1: Inventory (runs once, pre-loop)

Read the plan file. Build an inventory of every claim, decision, stance, and step. List them as bullet points grouped by section. Note any version numbers, dates, or specific technical claims.

### Step 1a: Freeze the severity rubric (Bundle 0c)

Before entering the critic loop, read `${CLAUDE_PLUGIN_ROOT}/skills/double-critique/references/severity-rubric.md` ONCE into memory (cache as `RUBRIC_FROZEN`). Both rounds of the loop use this byte-identical text via `<!-- SEVERITY RUBRIC -->` marker substitution — same mechanism as /double-critique. The `${CLAUDE_PLUGIN_ROOT}`-relative path is the canonical mechanism (single source of truth shared across both skills); it resolves identically on any machine that installs this plugin.

**Fallback when /double-critique is not installed:** if `${CLAUDE_PLUGIN_ROOT}/skills/double-critique/references/severity-rubric.md` is not readable, log a warning to the run output (`coherent-plan: severity-rubric.md not found at canonical path; using inlined minimal rubric`) and use the inlined minimal rubric below. This is the resilience tail for machines that have only `/coherent-plan` installed.

> **Inlined minimal rubric (fallback only):**
> - **CRITICAL** — the plan ships broken OR violates a hard gate. `blocks_ship: true`.
> - **MAJOR** — the plan ships incorrect OR contradicts itself OR omits a load-bearing dependency. Typically `blocks_ship: true`.
> - **MINOR** — polish, naming, formatting. **Never** `blocks_ship: true`.
> - **Calibration anchor:** if you escalate to MAJOR because you "haven't flagged anything else this round," it is a MINOR. Spurious MAJORs cause the oscillation guard to fire on noise.

### Steps 2 + 3: Cross-check / Fix Loop (max_rounds = 2)

Initialize loop state in memory:

```
round = 0
per_round = []
exit_reason = null
cm_count_prev = null
```

Then loop:

1. `round += 1`.
2. **Cross-check (Critic-N).** Render the cross-check prompt by substituting the `<!-- SEVERITY RUBRIC -->` marker with `RUBRIC_FROZEN` (cached in Step 1a). Compare every item from Step 1's inventory against every other item. Flag:
 - **Contradictions** — X says A, Y says not-A
 - **Stale references** — version numbers, file paths, or states that were true earlier but got superseded
 - **Orphaned steps** — steps that reference removed or renamed concepts
 - **Scope drift** — items that don't serve the stated goal
 - **Missing links** — steps that assume context not present in the document
 Print findings as a numbered list with severity (CRITICAL / MAJOR / MINOR) and the two conflicting locations. Each finding carries `severity` and (per the rubric) `blocks_ship`.
3. **Compute round metrics:**
 - `critical = count(severity == "CRITICAL")`, `major = count(severity == "MAJOR")`, `minor = count(severity == "MINOR")`
 - `cm_count = critical + major`
4. **Append to per_round:** `{round: N, critical, major, minor, cm_count}`.
5. **Exit checks (in this exact order):**
 - If `cm_count == 0`: set `exit_reason = "clean"`, break out of the loop. The loop exits BEFORE running corrector_N (nothing to fix). The plan file is unchanged from its pre-loop state if N=1, or holds corrector_{N-1}'s output if N>1.
 - If `round >= 2 AND cm_count >= cm_count_prev`: set `exit_reason = "oscillation"`, break. The loop exits BEFORE running corrector_N (corrector would re-attempt the same problem space). The plan file holds corrector_{N-1}'s output.
 - If `round == max_rounds`: set `exit_reason = "max_rounds"`. Continue to step 6 — corrector_N still runs at the budget cap so the user gets one final round of edits before exit.
6. **Fix (Corrector-N).** For each finding:
 - CRITICAL/MAJOR: Fix directly in the plan. Take a clear stance (don't hedge).
 - MINOR: Fix if trivial, otherwise note as a comment for the author.
 Write the corrected plan back to the same file. Set `cm_count_prev = cm_count`.
7. If `exit_reason` was set in step 5 to `max_rounds`, break. Otherwise return to step 1.

After the loop exits, persist `loop = {rounds_run, exit_reason, max_rounds: 2, per_round, final_cm_count: per_round[-1].cm_count}` for Run Data Recording.

**Asymmetry note (Bundle 0c canonical):** `clean` and `oscillation` exits skip corrector_N for that round — its work would be wasted (clean) or redundant (oscillation). `max_rounds` exit runs corrector_N first because we paid for round N's critic pass; we may as well let the corrector apply its findings before exit.

### Step 4: Report (runs once, post-loop)

**Telemetry signal (2026-05-06 harvest of 45 lifetime runs):** outcomes are 100% `complete` across 22 in-window runs; zero recorded findings or escalations. Most invocations are trigger-less (called from auto-flow's P4 mechanical sweep, not direct `/coherent-plan` by the operator). If a run ever surfaces `critical >= 1` after a prolonged clean stretch, treat that as a high-signal escalation worth a sibling alert (e.g., a working-memory card under topic `coherent-plan-regressions`) rather than just printing the banner — the banner is easy to scroll past in long auto-flow sessions.

Print a summary. Findings counts are summed across all rounds the loop actually ran. The header line reports `rounds_run` and `exit_reason`:

```
## Coherent Plan Review

File: {path}
Loop: {rounds_run} round(s), exit_reason={exit_reason}, final cm_count={final_cm_count}
Findings: {N} ({critical} critical, {major} major, {minor} minor)
Fixed: {count}
Noted: {count}

### Changes
- {one-line description of each fix}
```

**Escalation rule:** If `critical >= 1` OR `major >= 3`, print the banner block below **above** the `## Coherent Plan Review` summary, so it lands before the summary in terminal scrollback and cannot be buried. Then print the summary as usual. Also print the numbered `Options after escalation` block below immediately after the banner.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ESCALATED — coherent-plan threshold exceeded
 {critical} critical, {major} major blocking-class findings
 Recommended next step: /double-critique {path}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Options after escalation:
 1. Run `/double-critique {path}` — deeper multi-round critique loop (recommended when the plan is complex or high-stakes).
 2. Fix the flagged issues yourself, then rerun `/coherent-plan {path}` — cheapest path when the findings are actionable and small.
 3. Ignore and ship as-is — only valid for low-stakes plans where you judge remaining findings as acceptable.
 4. Split the plan — extract the complex section into its own file, coherent-plan the simpler remainder, double-critique the complex extract.
 5. Reduce scope, rerun `/coherent-plan` — trim what the plan is trying to do until findings drop below threshold.

STATUS: ESCALATED
```

The final `STATUS: ESCALATED` sentinel is a machine-readable signal for any downstream automation. When the threshold is not crossed, omit the banner, options block, and sentinel entirely — no `STATUS: OK` line is printed, because absence is the default.

Also persist `"escalated": true|false` in the `runs/data.json` entry for this run (next section). The threshold is intentionally lightweight — coherent-plan never loops, and never attempts to emulate double-critique. It only flags when a plan has outgrown coherent-plan's single-pass scope.

## Run Data Recording

After the review completes (or errors out), persist run data. This section always runs.

**Resolve the skill base directory** from the symlink target (the skill's source directory), not the current working directory.

### What to record

Append to `runs/data.json` (create with `{"skill":"coherent-plan","lastRun":null,"totalRuns":0,"runs":[]}` if missing):

```json
{
 "timestamp": "{ISO-8601}",
 "outcome": "complete|no-issues|error",
 "project": "{current project directory name}",
 "trigger": "{invocation string — e.g. '/coherent-plan path/to/plan.md --topic \"decision capture\"'}",
 "filePath": "{path to reviewed plan file}",
 "topic": "{value of --topic argument, verbatim}",
 "cairnHits": "{N entries pasted into the ## Cairn lookup section, 0..3}",
 "findingsTotal": "{N total findings, summed across all rounds the loop ran}",
 "critical": "{N critical, summed across rounds}",
 "major": "{N major, summed across rounds}",
 "minor": "{N minor, summed across rounds}",
 "fixed": "{N fixes applied, summed across rounds}",
 "noted": "{N noted but not fixed, summed across rounds}",
 "escalated": "{true if critical >= 1 or major >= 3, else false}",
 "loop": {
 "rounds_run": "{N rounds actually executed, 1..max_rounds}",
 "exit_reason": "clean|oscillation|max_rounds",
 "max_rounds": 2,
 "per_round": [
 {
 "round": "{1..rounds_run}",
 "critical": "{N critical findings this round}",
 "major": "{N major findings this round}",
 "minor": "{N minor findings this round}",
 "cm_count": "{critical + major this round}"
 }
 ],
 "final_cm_count": "{cm_count of the last round actually run}"
 },
 "issues": [],
 "summary": "{one-line: e.g., 'plan.md, 5 findings (1 critical, 2 major, 2 minor), 4 fixed, 2 rounds (clean)'}"
}
```

**Schema fields added v1.0.1 (2026-04-15):**
- `trigger` — populate with the invocation string for cross-skill telemetry consistency. Historical runs (pre-v1.0.1) had this missing; readers should treat missing `trigger` as `null`, not an error.
- `issues: []` — placeholder field for cross-skill schema uniformity. coherent-plan itself does not typically produce "issues" (its output is the `findingsTotal`/`fixed`/`noted` split); the field is present so cross-skill telemetry tools that iterate `runs/*/data.json` expecting a consistent shape don't break on this skill. On rare runs where the skill itself hits an error (e.g., parse failure on the input plan), the error SHOULD be recorded here with the standard `{stage, type, description}` shape.

**Schema fields added v1.1.0 (2026-04-28):**
- `topic` — verbatim value of the required `--topic` argument. Historical runs (pre-v1.1.0) lack this field; readers should treat missing `topic` as `null`, not an error. On a halt before Step 1 (missing `--topic`), this field SHOULD be `null` and `outcome` SHOULD be `error`.
- `cairnHits` — number of entries actually pasted into the `## Cairn lookup` section (0, 1, 2, or 3). Zero-hits runs record `cairnHits: 0` while still emitting the deterministic-shape section. Historical runs lack this field; readers should treat missing `cairnHits` as `null`.

**Schema fields added v1.2.0 (Bundle 0c, 2026-04-28):**
- `loop` — nested object capturing per-round telemetry for the new bounded critique loop (max_rounds = 2). Fields:
 - `rounds_run`: integer, 1..2.
 - `exit_reason`: one of `"clean" | "oscillation" | "max_rounds"`.
 - `max_rounds`: integer, fixed at 2 for this skill.
 - `per_round[]`: array of length `rounds_run`, each entry `{round, critical, major, minor, cm_count}` where `cm_count = critical + major`.
 - `final_cm_count`: `per_round[rounds_run-1].cm_count` (0 on `clean` exit, > 0 on `oscillation` or `max_rounds` exit).
- Historical runs (pre-v1.2.0) lack this field; readers should treat missing `loop` as `null`. The single-pass shape is the implicit `rounds_run = 1, exit_reason = null` case.

**Outcome values:**
- `complete` — review ran, findings were found and addressed
- `no-issues` — review ran, zero findings
- `error` — skill could not complete (file not found, parse error, etc.)

Keep last 50 runs (older runs are permanently discarded). Set `lastRun` and increment `totalRuns`.

Append one line to `runs/run.log` (keep last 100 lines). When `escalated == true`, append the literal token ` | ESCALATED` at the end of the line so historical escalations are greppable via `grep ESCALATED skills/coherent-plan/runs/run.log`. When `escalated == false`, do not add any escalation marker (absence is the default).

Non-escalated line format:
```
{timestamp} | {outcome} | {project} | {critical}C/{major}M/{minor}m | {fixed} fixed | {rounds_run}rd/{exit_reason} | {summary}
```

Escalated line format:
```
{timestamp} | {outcome} | {project} | {critical}C/{major}M/{minor}m | {fixed} fixed | {rounds_run}rd/{exit_reason} | {summary} | ESCALATED
```

The `{rounds_run}rd/{exit_reason}` segment is added in v1.2.0 (e.g., `1rd/clean`, `2rd/oscillation`, `2rd/max_rounds`). Historical lines omit the segment; downstream `awk` consumers should accept lines with either 6 or 7 pipe-delimited fields.

Do not fail the skill if recording fails — log a warning and continue.
