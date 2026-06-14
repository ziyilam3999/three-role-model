# Stage Prompts — Core Pipeline (Stages 1-2 + Critic-N / Corrector-N loop)

Full prompts for each agent in the core critique pipeline. The orchestrator (SKILL.md) calls each stage sequentially, passing only file artifacts between them. Stages 1-2 (Researcher, Drafter) run once. The Critic-N / Corrector-N pair runs in a loop bounded by `max_rounds`, with exit conditions defined in SKILL.md.

---

## Stage 1 — RESEARCHER

Use the Agent tool with this prompt:

> ENVIRONMENT CONTEXT (auto-detect):
> Before starting your analysis, detect your current development environment:
> - Run a platform detection command (e.g., `uname -a` or check environment variables)
> to determine the OS, shell, and filesystem type.
> - Note any relevant constraints: NTFS vs ext4, line endings (LF vs CRLF),
> path separator conventions, file permission model (chmod availability).
>
> When evaluating the document's implementation items, check each one against
> the detected environment:
> - Will shell scripts work on this OS without modification?
> - Are there line-ending concerns (LF vs CRLF)?
> - Do file permissions (chmod) apply on this filesystem?
> - Are paths written in a platform-compatible way?
>
> Flag any implementation item that assumes a different OS/shell as a
> COMPATIBILITY issue with severity MAJOR.
>
> DEPLOYMENT CONTEXT (if the document specifies a target platform):
> - Identify the target deployment platform from the document (e.g., Vercel,
> AWS Lambda, Azure, bare metal, Docker)
> - For each design decision, check whether it is feasible on that platform:
> - Does the platform support the required runtime features? (sessions,
> persistent state, long-running processes, file system access)
> - Are there cold start, timeout, or memory constraints that affect the design?
> - Does the architecture assume capabilities the platform does not provide?
> - Flag any design that is INFEASIBLE on the stated platform as a COMPATIBILITY
> issue with severity CRITICAL.
> - If the document does not specify a target platform, flag this as a gap.
>
> ---
>
> You're a librarian. Someone needs to improve a document. Read the document at `$ARGUMENTS`.
>
> First, build a structured inventory of the document:
> 1. What the document says (structure, sections, flow)
> 2. What it's trying to accomplish (goal, audience)
> 3. Every specific claim, decision, or implementation item — listed explicitly
>
> Then ground your review in the FULL `hive-mind-persist/` tree — not just `knowledge-base/` + `memory.md`. The full tree has nine members; you MUST scan each one for content relevant to the document under review. Each finding you emit should cite ≥1 hive-mind-persist pattern ID, anti-pattern ID, design-rule ID, constitutional rule, or other ID-bearing artefact (e.g., "P17", "F58", "design-rule-12") when relevant — or explicitly note "no matching prior art found" if your search came up empty for that finding.
>
> The nine tree members to scan:
> - `hive-mind-persist/constitution.md` — non-negotiable rules. A document that violates the constitution is broken regardless of how clever it is.
> - `hive-mind-persist/design-rules.md` — opinionated design heuristics; document deviations need explicit rationale.
> - `hive-mind-persist/design-system.md` — design-system invariants (colors, spacing, component shapes). Anything visual or structural must respect these.
> - `hive-mind-persist/document-guidelines.md` — formatting, header, voice, and audience norms for documents in this repo.
> - `hive-mind-persist/knowledge-base/` — proven patterns, anti-patterns, design constraints, essential core, compliance mechanics, process patterns, measurement reality (the original 7 KB files plus any newer additions).
> - `hive-mind-persist/memory.md` — chronological measurement log; check for past data on whatever the document claims.
> - `hive-mind-persist/proposals/` — open and accepted proposals. The document may already be subsumed by an in-flight proposal, or may need to defer to one.
> - `hive-mind-persist/session-notes/` — durable session-level decisions and outcomes from prior runs. Check for prior attempts at the same problem.
> - `hive-mind-persist/case-studies/` — write-ups of specific incidents, failures, or successes. Often the most relevant precedent for novel decisions.
>
> For each finding, explain in plain language WHY it matters for this document. Like checking a cookbook's advice against what actually worked in your kitchen.
>
> Also go to the actual repos and check any claims the document makes about the codebase.
>
> EVIDENCE RULE: For every factual claim you make about the codebase, you must
> include the evidence that supports it. Acceptable evidence:
> - Direct quote from a file you read (with file path)
> - Tool output (e.g., the actual list of tags, the actual content of package.json)
> - Explicit statement "I checked X and found nothing" for negative claims
>
> If you cannot provide evidence for a claim, mark it as UNVERIFIED and explain
> what you were unable to check.
>
> Do NOT state facts from memory or assumption. Every factual statement must
> trace back to something you actually read or ran during this session.
>
> JUSTIFICATION ANALYSIS: After completing your factual research, review every
> decision and claim in the document through a second lens:
>
> For each decision the document makes (tool choices, architectural decisions,
> what to include/exclude), ask:
> 1. Does the document explain WHY this decision was made?
> 2. Is the justification supported by evidence (from the document or your research)?
> 3. Could the justification be contradicted by what you found in the codebase?
>
> Flag any decision as UNJUSTIFIED if:
> - The document gives no reason for it
> - The reason given is contradicted by your research findings
> - The reason given is factually inaccurate
>
> For justified decisions, briefly note why they hold up. This helps the Drafter
> distinguish between "needs fixing" and "confirmed sound."
>
> FAILURE MODE CHECK: For each feature, integration, or external dependency
> the document describes:
> 1. Does the document specify what happens on failure? (API down, timeout, bad input)
> 2. Does the document specify what happens on overload? (rate limits, queue overflow)
> 3. Does the document specify what happens with missing/incomplete data?
>
> Flag any feature that lacks failure-mode specification as a GAP. This is not a
> judgment on the feature itself — just a flag that the document is incomplete.

Write the output to `tmp/dc-1-researcher.md`.

The Researcher auto-detects its own environment — no manual placeholder injection needed.

---

## Stage 2 — DRAFTER

Use the Agent tool with this prompt:

> You're an editor with a red pen. Read:
> - The original document at `$ARGUMENTS`
> - The research and justification analysis at `tmp/dc-1-researcher.md`
>
> Produce an improved version of the document:
> - Fix items flagged as UNJUSTIFIED
> - Add missing items surfaced by the research and justification analysis
> - Remove unsupported claims
> - Strengthen evidence and reasoning
> - Keep the author's voice, structure, and format
>
> If you can't explain why a change improves the document in plain language, don't make it.
>
> Before incorporating any factual claim from the Researcher into the rewritten
> document, verify it yourself if you have the ability to do so. Specifically:
> - If the Researcher claims a file exists/does not exist, check it.
> - If the Researcher claims a repo has/lacks tags, versions, or config, check it.
> - If you cannot verify a claim, include it but mark it as
> "[UNVERIFIED — from Researcher]" so downstream critics know to check it.
>
> Do NOT blindly trust upstream stages. You are the last stage before critique
> and the document you produce will be treated as authoritative.
>
> NOVELTY FLAG (mandatory): When you introduce ANY new claim, number, threshold,
> or constraint that does NOT come from the original document or the Researcher
> report, you MUST flag it inline using this format:
> `NEW_CLAIM: <claim> — <source: own analysis | inference from X | industry convention>`
> This includes: new numbers (token counts, thresholds, limits), new constraints
> not in the original, new edge cases you invented, new tool/dependency choices.
> Downstream critics will scrutinize these flagged items. Unflagged novel claims
> that are later caught by critics count as Drafter regressions.
>
> TEST CASE MECHANICAL SELF-CHECK (mandatory when the document contains test cases):
> After drafting, if your output contains ANY test cases, assertions, grep commands,
> or verification scripts, mechanically check EACH one:
> (a) **Runtime compatibility:** Each TC must be executable by the target project's declared runtime. Inspect `package.json` `"type"` (or equivalent runtime marker) and confirm each TC's constructs are consistent with it. Do NOT prescribe specific syntax in the document (no "use `import`, not `require`"-style rules) — the executor chooses the shape.
> Ask: "Would this TC run without modification on the target runtime?" If no, flag the incompatibility; do not rewrite with pinned syntax.
> (b) **Assertion target accuracy:** The assertion must test the CORRECT data source.
> Ask: "If the feature being tested is completely broken, would this assertion still pass?"
> If yes, the assertion is trivially true and must be rewritten.
> (c) **File extension correctness:** JSONL content uses `.jsonl`, JSON uses `.json`,
> YAML uses `.yaml`/`.yml`. Never put one format's content in another format's extension.
> (d) **Precondition realism:** Each TC must set up state that exercises the code path.
> Ask: "Does this test pass even if the feature was never implemented?" If yes, fix preconditions.
> (e) **Async observability:** Each async TC must observably fail (not silently pass) when the feature under test throws or hangs.
> Ask: "If the awaited operation rejects or never resolves, does the TC report the failure?" If no, the TC is unsound.
> Do NOT prescribe specific async syntax (no "use `void asyncFn` pattern"-style rules). Use `n/a` if the TC has no async code.
> (f) **Resource cleanup:** Tests that create files, servers, or child processes must guarantee cleanup even when the test fails mid-run.
> Do NOT prescribe the cleanup mechanism (no "use `finally` or `afterEach`"-style rules) — the executor picks the shape.
> Use `n/a` if no resources are created.
> (g) **Path portability:** TCs must resolve file paths consistently regardless of the caller's current working directory.
> Ask: "Would this TC pass if run from a different CWD?" If no, flag the CWD-dependency.
> Do NOT prescribe the anchoring mechanism (no "use `import.meta.url`" or "use `__dirname`"-style rules). Use `n/a` if the TC has no file paths.
>
> For each TC, write: `TC-CHECK: [TC name] — ESM:ok/fail, target:ok/fail, ext:ok/fail, precond:ok/fail, async:ok/fail/n/a, cleanup:ok/fail/n/a, paths:ok/fail/n/a`
> Fix any failures before proceeding. Unfixed TC failures count as Drafter regressions.
>
> Apply the self-review checklist from `references/self-review-checklist.md` after drafting.
> CRITICAL: For item 5 (evidence-gated verification), you MUST use the format
> `VERIFIED: <thing> found at <file:line> — "<quoted evidence>"` or `UNVERIFIED: could not locate <thing>`.
> Never claim "I verified X" without pasting the actual evidence.

Write the output to `tmp/dc-2-drafter.md`.

---

## Critic-N (ISOLATED) — Loop Template

This is the template for every critic round in the loop. The orchestrator substitutes `{N}` with the current round number and `{CORRECTED_DOC_PATH}` with the latest corrected-doc path (round 1 reads `tmp/dc-2-drafter.md`; round ≥2 reads the previous round's corrector output).

Isolation is what makes the critique valuable — if the critic sees the reasoning behind changes, it unconsciously confirms them instead of challenging them. A cold reviewer who sees only the latest corrected doc catches problems the author is blind to. **Each round is fully independent: the critic never sees prior rounds' critiques, running issue lists, or round counters.**

Use the Agent tool with this prompt:

> You're a fresh reviewer seeing this document for the first time. You know NOTHING about how it was made, what round of review this is, or what prior reviewers found. Do not attempt to coordinate with any other round.
>
> Read the document at `{CORRECTED_DOC_PATH}`. Read it cold.
>
> The severity rubric is embedded inline below. The orchestrator captured it once at run-start (Stage 0 step 4a) and substituted it here, so every round of this run sees byte-identical rubric text. **Do not look up `references/severity-rubric.md` at runtime** — use the inline text only. Your output MUST conform to the JSON schema described inline — including the mandatory `doctrine` field on every finding.
>
> ```
> <!-- SEVERITY RUBRIC -->
> ```
>
> The block above is the orchestrator's substitution point. Treat the substituted text as the authoritative rubric for this round.
>
> DOCUMENT IDENTITY CHECK (mandatory first step):
> Before reviewing, read the first 10 lines of the document. State the document's
> title and date. If the document appears to be about a completely different topic
> than what you would expect from a document currently under critique in this
> pipeline run, STOP immediately and write this single-finding output file:
> ```json
> [{"id":"IDENTITY","severity":"CRITICAL","blocks_ship":true,"novel":false,"evidence":"lines 1-10 of the input","finding":"IDENTITY MISMATCH: found [title/topic]; expected a document from this pipeline run","why_blocks_ship":"Stale input would cause the orchestrator to rewrite the wrong file."}]
> ```
> Do not proceed with the review.
>
> Find:
> - Logical gaps or leaps in reasoning
> - Unsupported claims (stated without evidence)
> - Missing edge cases or failure modes
> - Internal contradictions
> - Implementation details that don't add up
> - Feasibility issues — things that SOUND right but WON'T WORK in practice
> - Overly vague items that need specifics
> - Ordering or dependency issues
>
> EVIDENCE GATING (hard rule from the rubric):
> - Every finding must carry an `evidence` field pointing at concrete text in the document (quoted span + line or section reference), OR the literal string `UNVERIFIED`.
> - `UNVERIFIED` findings are allowed when you suspect a problem but cannot cite evidence. They are logged but **cannot be `blocks_ship: true`** — the orchestrator will not count them toward the blocker total regardless of what you set.
> - If you cannot cite evidence for a finding AND cannot articulate the concern in plain language, do not emit it. Silence is better than noise.
>
> HIVE-MIND-PERSIST GROUNDING (Bundle 2c — mechanical contract):
> - Every finding MUST cite ≥1 hive-mind-persist pattern ID, anti-pattern ID, design-rule ID, or constitutional rule (e.g., "P17", "F58", "design-rule-12", "constitution: File-over-memory") in its `finding` body OR explicitly note "no matching prior art found" if your search of the hive-mind-persist tree came up empty for that finding. Do NOT invent IDs; if you cannot cite a real pattern ID, say so explicitly with the "no matching prior art found" phrase.
> - This is the mechanical grounding-enforcement — without it, isolated critics review the document in a vacuum and miss the precedents that already settle most novel-looking concerns.
>
> `blocks_ship` FLAG (hard rule from the rubric):
> - `blocks_ship: true` iff a competent reviewer would reject the document at merge time for this specific finding.
> - Polish, phrasing, stylistic preference, and optional strengthening are **never** `blocks_ship: true`.
> - When `blocks_ship: true`, you MUST also provide a one-sentence `why_blocks_ship` field describing the merge-gate impact.
>
> `doctrine` FLAG (hard rule from the rubric, v1.2):
> - Every finding MUST carry a `doctrine` field with value `outcome-defect` or `how-defect`. Missing or other values cause the orchestrator to abort the pipeline.
> - **`outcome-defect`** — the document fails as a *what/why* artefact (missing AC, contradictory invariant, broken cross-reference, identity mismatch, unsupported claim the document itself makes). The fix lives inside the document.
> - **`how-defect`** — the document is fine as a *what/why* artefact but you wish it prescribed *how* (exact bash, regex syntax, env-var name, mechanism choice, command pinning). The fix would push implementation choice into the plan, violating the "Plan Intent: What and Why, Never How" doctrine.
> - When in doubt, ask: "If I were the executor with fresh code context, would I want the plan to choose this for me?" If the answer is "no, I'd rather choose myself" → `how-defect`. If the answer is "yes, this is a *what/why* I need decided up front" → `outcome-defect`.
> - "Overly vague items that need specifics" is THE category most prone to misclassification. Re-read the cited evidence: if the document has named the *outcome* and you only wish it had pinned the *mechanism*, that is a `how-defect`. Do not let "vague" pull you toward HOW-prescription.
> - The orchestrator does NOT count `how-defect` findings toward `blocker_count`, mirroring the `UNVERIFIED` mechanic. They are recorded for audit; the corrector's Doctrine guard will defer them with reason `planner-doctrine`.
>
> OUTPUT FORMAT (mandatory):
> Write a single JSON array of findings inside a fenced code block, followed by any free-text observations below the block. The orchestrator parses the JSON array only — free text is for the user. No prose allowed inside the code block; the fence must contain valid JSON and nothing else. Every finding MUST include `doctrine` — a finding without it fails JSON parse with a clear error.

Write the output to `tmp/dc-{2*N+1}-critic-round{N}.md`.

---

## Corrector-N — Loop Template

This is the template for every corrector round in the loop. The orchestrator substitutes `{N}` with the current round number, `{CORRECTED_DOC_PATH}` with the latest corrected doc path, and `{CRITIC_FINDINGS_PATH}` with `tmp/dc-{2*N+1}-critic-round{N}.md`.

Use the Agent tool with this prompt:

> You're a surgeon. Read:
> - The latest corrected document at `{CORRECTED_DOC_PATH}`
> - The critic findings at `{CRITIC_FINDINGS_PATH}`. The findings are a JSON array inside a fenced code block — parse them.
>
> DOCTRINE GUARD (mandatory first pass, v1.2):
>
> Before applying ANY fix, walk every finding and classify by its `doctrine` field. The plan you are correcting is an *intent* document — it carries WHAT and WHY, not HOW. The executor downstream has fresher code context than the plan author and chooses HOW. Your job is to fix WHAT/WHY defects, NOT to push HOW into the plan.
>
> - For each finding where `doctrine == "how-defect"`: **DO NOT apply the fix to the document.** Instead, defer it to the comment block (see deferred-comment template below) with reason `planner-doctrine: executor's call`. Even if `blocks_ship: true` was set on the finding, you must NOT pin commands, env-var names, regex syntax, mechanism choices, or any implementation detail that an executor with code context could reason about.
> - For each declined `how-defect` finding, write one paragraph in your agent output explaining why deferral was correct. Format: `DOCTRINE-DEFER [F#]: <one-sentence reason naming what would have been pinned>`. Silent deferrals are forbidden — the user must be able to audit your reasoning.
>
> Concrete deferral examples (the ≥3 reference cases — match the *shape* of the finding, not the exact words):
>
> 1. **Pinning an env-var name.** Critic finding: "The plan says 'reads heartbeat path from env var (test seam)' — should specify `CAIRN_HEARTBEAT_LOG`." → DEFER. The plan named the *outcome* (env-var test seam exists); the *exact name* is the executor's choice. Pinning it locks the plan to a name the executor may need to change for collision/clarity reasons. Output: `DOCTRINE-DEFER [F#]: would have pinned env-var name; outcome (test-seam exists) is already in the plan, name is executor's call.`
>
> 2. **Pinning a regex.** Critic finding: "The plan says 'extracts the audit-log moved-to commit ref' — should specify the exact pattern e.g. `grep -E 'audit-log moved to.* see (#\\d+|[0-9a-f]{7,40})'`." → DEFER. The plan named the *outcome* (commit ref is extracted); the *exact regex* is the executor's call and is likely to need iteration against real data. Output: `DOCTRINE-DEFER [F#]: would have pinned regex; outcome (extract commit ref) is already in the plan, pattern is executor's call.`
>
> 3. **Pinning a touch-mtime mechanism.** Critic finding: "The plan says 'simulate stale heartbeat' — should specify `touch -d '12 hours ago' <file>`." → DEFER. The plan named the *outcome* (simulated stale state); `touch -d` is GNU-only, and the executor may use Node `fs.utimesSync`, PowerShell, or any other mechanism. Pinning it would have caused round-2 critic to flag "GNU-only" as a fresh blocker. Output: `DOCTRINE-DEFER [F#]: would have pinned touch-mtime mechanism; outcome (simulated stale heartbeat) is already in the plan, mechanism is executor's call.`
>
> Additional deferral patterns (apply same logic):
> - Exact bash command sequences for setup/cleanup steps.
> - Specific jq function choice (`test` vs `endswith`).
> - Exact cron expression or PM2 ecosystem-config field shape.
> - Specific commit-message prefix or branch-name format.
> - Exact retry/backoff timings or thresholds beyond the WHY-stated bound.
>
> Edge case — a `how-defect` finding may legitimately need a `how`-shaped fix when the document IS the script (release scripts, lint configs, ecosystem files). In that rare case the critic should have classified it `outcome-defect` (the script's command shape *is* the outcome). If the critic mis-classified, override only with explicit reasoning in your agent output: `DOCTRINE-OVERRIDE [F#]: applying despite how-defect flag because document is a script not a plan; <evidence>`.
>
> APPLY FIXES ONLY TO BLOCKING OUTCOME-DEFECT FINDINGS:
> - For each finding where `doctrine == "outcome-defect"` AND `blocks_ship == true`: apply the fix precisely. Do not add new content beyond what the finding requires.
> - For each finding where `doctrine == "outcome-defect"` AND `blocks_ship == false` (MINOR, polish, non-blocking): **do NOT fix it.** Instead, append the finding as a comment inside the deferred block at the very end of the document (template below).
> - For each finding where `doctrine == "how-defect"`: defer regardless of `blocks_ship` — the Doctrine guard above governs.
>
> HIVE-MIND-PERSIST GROUNDING (Bundle 2c — mechanical contract):
> - When applying a fix, cite ≥1 hive-mind-persist pattern ID, anti-pattern ID, design-rule ID, or constitutional rule in the corrected text where the fix lands (e.g., a footnote reference like "(P17)" or an inline citation like "per design-rule-12"). If your search of the hive-mind-persist tree came up empty for the fix, explicitly note "no matching prior art found" rather than fabricate an ID. This makes the corrector's grounding auditable from the corrected document alone.
>
> DOWNSIDES-ACCEPTED SECTION (Bundle 2c — mandatory for clean exit):
> - Before ending the round, ensure the corrected document contains a `## Downsides accepted` section with at least one entry. Each entry is one bullet of the form `- <finding-id or short-name>: <one-sentence rationale for accepting rather than fixing>`.
> - If this round genuinely produced zero accepted trade-offs (everything was either resolved or escalated), the section MUST still exist with one explicit no-op entry — sample wording: `- (none) — no accepted trade-offs in this round; all findings either resolved or escalated.`
> - An empty or missing `## Downsides accepted` section will block the loop's clean-exit gate (see SKILL.md Stages 3..N exit checks). Silence is not allowed.
> - Deferred-comment block template (one block per round, all deferrals from this round inside it):
> ```
> <!-- deferred:critic-{N}
> - [F#] (reason: minor) <finding text>
> - [F#] (reason: planner-doctrine: executor's call) <finding text>
>...
> -->
> ```
> These are preserved for the user to read but do not modify document content.
> - For any finding you believe is wrong (blocking or not): explain why in plain language in your agent output. Do NOT silently skip a finding that you decline to apply.
>
> SECOND-ORDER EFFECT CHECK (mandatory after applying each blocking fix):
> After applying each fix, check all four dimensions and write:
> ```
> SIDE-EFFECT-CHECK: [fix description]
> format: ok | "<what changed and where refs were updated>"
> naming: ok | "<what was renamed and where refs were updated>"
> shape: ok | "<what field/type changed and where consumers were updated>"
> refs: ok | "<what cross-references were updated>"
> ```
> Use `ok` when unaffected. When affected, quote what changed and where.
>
> TC RE-CHECK (mandatory when the corrected document contains test cases):
> After applying all fixes, re-run the TC-CHECK. For each TC, write:
> `TC-CHECK: [TC name] — ESM:ok/fail, target:ok/fail, ext:ok/fail, precond:ok/fail, async:ok/fail/n/a, cleanup:ok/fail/n/a, paths:ok/fail/n/a`
> Fix any failures before proceeding.
>
> Apply the self-review checklist from `references/self-review-checklist.md` after applying all fixes.
> CRITICAL: For item 5 (evidence-gated verification), you MUST use the format
> `VERIFIED: <thing> found at <file:line> — "<quoted evidence>"` or `UNVERIFIED: could not locate <thing>`.
> Never claim "I verified X" without pasting the actual evidence.
>
> ROUND MARKER (mandatory): After all fixes are applied and the document is complete, append the literal line `<!-- round-{N}-corrected -->` at the very end of the file as a machine-readable round tag.

Write the output to `tmp/dc-{2*N+2}-corrector-round{N}.md`. This file becomes the "latest corrected doc" input for the next round's critic (or, on loop exit, the orchestrator copies it to `$ARGUMENTS` and `tmp/dc-final.md`).
