# Stage Prompts — Feedback Loop (Stages 8-10)

Full prompts for each agent in the post-critique feedback loop. These stages run sequentially after Stage 7 (orchestrator synthesis) to extract learnings, track effectiveness, and update the knowledge base.

---

## Stage 8 — EXTRACTOR

Use the Agent tool with this prompt:

> You're a sports analyst watching game replays. The game is over — 6 players (stages) each took turns improving a document. Now you're reviewing the tape to figure out who helped and who didn't.
>
> **Why this stage exists:**
> Imagine 6 people pass a drawing around a table. Each person adds or fixes something. At the end, you have a much better drawing — but you don't know WHO made it better. Was it the person who added color? The one who fixed proportions? The one who erased a mistake? This stage watches the replay to figure that out. Without it, we keep running all 6 stages forever, even if some contribute nothing. This is how the pipeline learns about itself.
>
> Read these artifacts only (the pipeline now runs a variable-length Critic/Corrector loop, so middle rounds are summarized via a count table rather than read in full):
> - `tmp/dc-1-researcher.md` (Researcher — checked knowledge base for relevant patterns + justification analysis + built document inventory)
> - `tmp/dc-2-drafter.md` (Drafter — improved the document based on research + justification)
> - `tmp/dc-3-critic-round1.md` (first round's critic, full text — cold review of the draft)
> - `tmp/dc-4-corrector-round1.md` (first round's corrector, full text — fixed what round 1 flagged as blocking)
> - The **final round** critic and corrector files (full text). These will be named `tmp/dc-{2*N+1}-critic-round{N}.md` and `tmp/dc-{2*N+2}-corrector-round{N}.md` where `N = roundsRun` from `tmp/dc-loop-state.json`.
> - `tmp/dc-loop-state.json` — contains the per-round count table (`per_round` array) that is **authoritative** for all middle rounds. Do NOT attempt to read `tmp/dc-*-critic-round*.md` or `tmp/dc-*-corrector-round*.md` files for middle rounds — the count table is authoritative for those rounds.
> - The original document at `$ARGUMENTS`.
>
> Also read the Critique Log at the end of `$ARGUMENTS`.
>
> For each stage, answer:
> 1. **What did this stage catch?** (Specific findings, not vague summaries. "Found 3 callers that would break" not "found some issues.")
> 2. **What did it miss that a later stage caught?** (Example: Drafter fixed unjustified claims but missed that the fix changed a return type — Critic-2 caught that later.)
> 3. **Did it introduce any problems?** (Fixing one thing can break another. Like patching a hole in a boat but accidentally blocking the drain.)
> 4. **One-sentence verdict:** Was this stage worth its cost for this document?
>
> **Regression tracking:** For Drafter and each corrector round whose full text you read (round 1 + final round), explicitly count how many NEW defects each introduced (not present in the input, present in the output). These are "regressions." For middle rounds, regressions are inferred from the per-round count table: if `blocker_count[round N] > blocker_count[round N-1]`, that is a signal of a middle-round regression that the subsequent critic round caught — report it as an inferred regression with the round number. Report as:
> - `drafter_regressions: N` (defects in dc-2-drafter.md not present in source document)
> - `corrector_round1_regressions: N` (defects in the round-1 corrector output not present in dc-2-drafter.md)
> - `corrector_round{final}_regressions: N` (defects in the final corrector output not present in its input)
> - `inferred_middle_round_regressions: [{round: N, delta: +X},...]` (from the count table)
>
> **Evidence-gating audit:** Check whether Drafter and Corrector-1 used the evidence-gated self-review format (`VERIFIED: <evidence>` or `UNVERIFIED`). Report:
> - How many verification claims used evidence format vs. bare "I verified" claims
> - Any false verification claims (claimed VERIFIED but evidence is wrong or missing)
>
> **Novelty-flag audit:** Check whether the Drafter flagged new claims using the `NEW_CLAIM:` format. Report:
> - How many `NEW_CLAIM:` tags appear in the Drafter's output
> - How many unflagged novel claims were caught by Critic-1 or Critic-2 (these are Drafter regressions that the flag should have prevented)
> - Novelty-flag compliance: `flagged / (flagged + unflagged novel claims caught by critics)` as a percentage
>
> Then add a summary section:
> - Which stages carried the most weight this run?
> - Were there any redundant stages (found nothing new)?
> - Did the Researcher reduce the critics' workload?
>
> Be blunt. If a stage added nothing, say so.
>
> **Output format:** Start the report with a 2-3 sentence summary for a reader who has never seen this pipeline. Example opening: "This document was reviewed by 6 specialists in sequence. Here's what each one contributed — think of it like a relay race where each runner adds value (or doesn't)." Then for each stage section, include a one-line plain-language explanation of what that stage's job was before diving into findings. End with a "Bottom Line" section: one paragraph a non-technical person could read and understand what the pipeline accomplished.

Write the output to `tmp/dc-8-extractor.md`.

---

## Stage 9 — EFFECTIVENESS

Replace `{date}` with today's date in YYYY-MM-DD format.

Use the Agent tool with this prompt:

> You're a doctor looking at a patient's chart over multiple visits — not just today's appointment, but the full history.
>
> **Why this stage exists:**
> If you go to the gym once and feel sore, you don't know if the workout was good or bad. But if you track every workout for a month — how much you lifted, how sore you were, which exercises helped — you start seeing what works. This stage is the workout tracker for the pipeline. It compares TODAY's run with ALL previous runs to spot trends. Maybe Critic-2 keeps finding the same type of bug (return type issues). That's a signal that earlier stages should catch it instead. Without tracking, every run is a one-off and we never learn.
>
> Read:
> - The extraction from this run: `tmp/dc-8-extractor.md`
> - All historical results reports in `tests/double-critique/` (every file matching `results-report*.md`)
> - All prior effectiveness reports in `tests/double-critique/` (every file matching `effectiveness-*.md`)
>
> Produce an effectiveness report with these sections:
>
> ## This Run
> - Document critiqued: [name and path]
> - Content type: [prose-only | includes-TCs | code-heavy] — classify based on whether the document contains test cases/assertions (includes-TCs), executable code blocks (code-heavy), or neither (prose-only). This field tracks correlation between document type and Drafter regression count.
> - Total findings: [N] (CRITICAL/MAJOR/MINOR breakdown, summed across all rounds)
> - Application rate: [N]% (blocking findings applied / total blocking findings — this tells us if findings are useful or just noise)
> - Drafter regressions: [N] (new defects introduced by Drafter)
> - Corrector regressions by round: round-1 [N], final-round [N], inferred middle rounds [list]
> - Evidence-gating compliance: [N]% (verification claims with evidence / total verification claims)
> - False verification claims: [N] (claimed VERIFIED but evidence wrong or missing)
> - Novelty-flag compliance: [N]% (NEW_CLAIM tags / (tags + unflagged novel claims caught by critics))
>
> ## Loop Stats (new)
> Read `tmp/dc-loop-state.json` and report:
> - `rounds_run`: N
> - `exit_reason`: clean | oscillation | max_rounds
> - Per-round blocker table:
> | Round | blocker_count | critical | major | minor | novel | unverified |
> - First-round blockers vs last-round blockers: did the loop converge?
>
> Cross-run loop stats (carry forward across prior effectiveness reports that contain Loop Stats sections):
> | Run | rounds_run | exit_reason | round_1_blockers | round_N_blockers | total_findings_applied |
> Trend: "rounds_run over last 10 runs" — if median is ≥3, the loop is doing real work. If median is 1–2, documents were already clean OR the `blocks_ship` flag is being under-applied (check against round-1 blocker counts from pre-loop runs to distinguish).
>
> ## Cross-Run Trends
> (Compare this run to ALL previous runs. If this is the first run with feedback loop, compare against the results reports from earlier manual runs.)
> - Compare finding counts, severity profiles, and application rates across ALL runs
> - **Regression tracking table** (carry forward from all prior runs):
> | Run | Drafter regressions | Corrector-1 regressions | Evidence-gating compliance | Novelty-flag compliance |
> Track these as first-class metrics alongside finding counts.
> - Are the same types of findings recurring? (List any pattern in 2+ runs.)
> - Is the pipeline finding fewer issues over time?
> - Is evidence-gating reducing false verification claims compared to pre-evidence-gating runs?
>
> ## Stage Effectiveness Rankings
> For each stage type (Researcher, Drafter, Critic-1, Corrector-1, Critic-2, Corrector-2):
> - Contribution: HIGH / MEDIUM / LOW based on findings caught or value added
> - Trend: IMPROVING / STABLE / DECLINING across runs
> - Think of it like grading employees on a team: who's carrying their weight, who's coasting, who's improving?
>
> ## What's Working
> - Pipeline behaviors that consistently produce value (with evidence from multiple runs)
> - Example format: "Pre-critique front-loading (Researcher) caught N items across M runs before critics saw the document"
>
> ## What's Not Working
> - Pipeline behaviors that consistently underperform or add no value
> - Example format: "Corrector-1 regression rate (mean N/run) unchanged despite M interventions"
>
> Be data-driven. Every claim needs a number from an actual run. No hand-waving. If you only have 1-2 data points, say so — don't pretend a trend exists from one example.
>
> **Output format:** Start every major section with a one-sentence summary explaining what the section measures and why someone should care. For any table, add a one-line explanation above it: what the columns mean and how to read the data. End the report with a "So What?" section: 3-5 bullet points a team lead could skim in 30 seconds to understand the pipeline's health.

Write the output to `tests/double-critique/effectiveness-{date}.md`.

---

## Stage 10 — RETROSPECTIVE

Replace `{date}` with today's date in YYYY-MM-DD format.

Use the Agent tool with this prompt:

> You're the team's retrospective facilitator. After a project sprint, the team sits down and asks: "What did we learn? What should we do differently next time?" That's your job.
>
> **Why this stage exists:**
> Think of a recipe book. Every time you cook a dish, you learn something — "add less salt," "cook 5 min longer," "this ingredient is useless." If you just think about it and forget, you'll make the same mistakes next time. But if you WRITE IT DOWN in the recipe book, every future cook benefits. This stage is the person who writes those notes in the recipe book.
>
> The "recipe book" has two levels:
> - **Sticky notes** (`hive-mind-persist/memory.md`) — Quick observations. "Last time I added too much salt." These are temporary and personal.
> - **The actual recipe book** (`hive-mind-persist/knowledge-base/`) — Proven, permanent knowledge. "Salt at 1tsp per cup is optimal (tested 5 times, always works)." Only sticky notes that prove true across 3+ attempts get written into the book.
>
> Read:
> - The effectiveness report: `tests/double-critique/effectiveness-{date}.md`
> - Current proven patterns: `hive-mind-persist/knowledge-base/01-proven-patterns.md`
> - Current anti-patterns: `hive-mind-persist/knowledge-base/02-anti-patterns.md`
> - Current process patterns: `hive-mind-persist/knowledge-base/06-process-patterns.md`
> - Current measurement data: `hive-mind-persist/knowledge-base/07-measurement-reality.md`
> - Current memory (the sticky notes): `hive-mind-persist/memory.md`
>
> Do three things:
>
> **1. Write a retrospective report** to `tests/double-critique/retrospective-{date}.md`:
> - **KEEP:** What's working well in the pipeline (with evidence). Like saying "the warm-up exercises are preventing injuries — keep doing them."
> - **CHANGE:** What should be modified (with specific proposals). Not "be better" — specific like "Researcher should also check hive-mind-persist/memory.md, not just knowledge-base files."
> - **ADD:** New pipeline stages or modifications to try next run. Only if there's a clear gap.
> - **DROP:** Anything that's consistently not pulling its weight. If a stage added nothing in 3 runs, it's dead weight.
> - **NEW PATTERNS:** Candidate patterns discovered this run. Format: one-sentence WHAT + WHY + EVIDENCE. Example: "Round 2 catches regression bugs from Round 1 fixes — because isolation means Critic-2 reads the corrected doc cold and spots side effects the corrector was blind to. Evidence: e2e-bugfix Round 2 CRITICAL was caused by Round 1 CRITICAL fix."
> - **NEW ANTI-PATTERNS:** Candidate anti-patterns discovered. Same format. Example: "Changing return types without listing callers breaks downstream code silently — because the fixer only sees the function, not its consumers."
>
> **2. Update hive-mind-persist/memory.md** (the sticky notes) — Append new entries to the appropriate sections:
> - PATTERNS section: date-stamped, with pattern ID cross-reference if applicable. Example: `- 2026-03-08: Round 2 serves as regression check on Round 1 fixes. (P5 update)`
> - MISTAKES section: date-stamped, with anti-pattern ID cross-reference. Example: `- 2026-03-08: Never change return type without listing every caller. (F31)`
> - DISCOVERIES section: date-stamped. Example: `- 2026-03-08: Pipeline catches its own corrections' side effects — emergent self-validation. (P5, 07)`
> - **Check existing entries first — don't duplicate.** Read every line of every section. If an existing entry says the same thing, update it with new evidence instead of adding a new line.
>
> **3. Update knowledge base IF warranted** (graduate sticky notes to the recipe book) — Only if a finding meets ALL three criteria:
> - **Stability:** observed in 3+ runs (not a one-off). Like a cooking tip that worked 3 times — not a fluke.
> - **Evidence:** has measured numbers (finding counts, rates, etc.). "Seems to help" doesn't count. "93% application rate across 3 runs" counts.
> - **Generalizability:** applies beyond just the double-critique pipeline. A pattern only useful for critique runs stays in memory. A pattern useful for ANY multi-stage pipeline belongs in KB.
>
> For KB updates:
> - Read current highest P-number in `hive-mind-persist/knowledge-base/01-proven-patterns.md` and F-number in `hive-mind-persist/knowledge-base/02-anti-patterns.md`. Assign next in sequence (e.g., if highest is P24, next is P25).
> - Use the graduation format: `### P-NN — [Name]` with WHAT / WHY IT WORKS / EVIDENCE / DESIGN IMPLICATION (4 bullet points).
> - Don't promote on the first or second run. Memory entries need to prove stability first. Think of it as a probation period — new hires don't get promoted in their first week.
>
> Rules:
> - Be conservative. One high-quality KB entry beats five marginal ones. The recipe book should have the BEST recipes, not every recipe ever tried.
> - If nothing meets the KB criteria, that's fine — just update hive-mind-persist/memory.md and say so explicitly: "No entries met graduation criteria this run."
> - Like a team retro: honest, specific, and focused on what actually changes behavior next time. Not "we should communicate better" — instead "Stage 8 should flag when Researcher output isn't referenced by any later stage."
>
> **Output format for the retrospective report:** Start with a 3-sentence summary: "What is this report? This is a team retrospective — like a post-game huddle where we decide what to keep doing, what to change, and what to stop doing. It covers [N] pipeline runs and distills them into actionable next steps."
>
> For each KEEP/CHANGE/ADD/DROP item, use this format:
> - **[Item name]** — [One sentence: what it is in plain language] — [Evidence: specific numbers from runs] — [Action: what exactly to do next]
>
> For NEW PATTERNS and NEW ANTI-PATTERNS, each entry should include:
> - **Plain-language name** (not jargon — "Second review catches mistakes from fixing mistakes" not "Round 2 regression detection")
> - **What:** One sentence a new team member could understand
> - **Why:** The root cause explained simply
> - **Evidence:** Specific numbers from specific runs
> - **Analogy:** One sentence comparing it to an everyday situation (this helps the reader AND future agents internalize it)
>
> End the report with a "Next Run Priorities" section: a numbered list of 1-3 concrete changes to make before the next pipeline run. Not aspirational goals — specific file edits or prompt changes.

Write the retrospective report to `tests/double-critique/retrospective-{date}.md`.
