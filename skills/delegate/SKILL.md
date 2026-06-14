---
name: delegate
version: 1.2.0
description: Mechanical planner-to-executor handoff clerk for the planner/executor workflow. Validates a plan file, pre-flights its binary AC against master in an isolated worktree, renders a brief from a template, delivers it via subagent spawn or mailbox send, and records run data. Use when the user says "/delegate PLAN" to hand a plan to an implementer, "/delegate review PR" to spawn a stateless reviewer on shipped work, or "/delegate gate PLAN" on the executor side to run the plan's AC against the current branch before push. The skill never decides whether to delegate (user's call), never writes code (implementer's job), never edits plan files, and never commits on behalf of the implementer. It is the mechanical clerk — the judgment overlay stays in CLAUDE.md.
---

# Delegate

## Overview

`/delegate` codifies the mechanical steps of the Planner/Executor Workflow from CLAUDE.md. Every handoff does the same things: validate plan shape, classify the AC, check each AC's baseline against master, render a brief from a template with the learnings-so-far baked in, deliver it, and log the run. This skill is that checklist — it runs every time so nothing gets skipped.

## Three load-bearing rules (planner-side, enforced by convention)

These are planner responsibilities that live above the skill's mechanical steps. The skill does not and will not validate them automatically — they live here because every `/delegate` run depends on them, and the skill exists specifically to codify things that shouldn't be re-derived.

### Rule 1 — Task-sizing ladder

Match execution mode to task size on a three-rung ladder. Prefer the smallest rung that fits.

1. **Inline** — small enough to do in the main conversation without context bloat. Trivial fixes, single-file edits, 1–3 step sequences. No `/delegate`.
2. **`/delegate` to a stateless subagent** — default for non-trivial implementation tasks: 3+ files, multi-hour, context-bloating research+implement loops, or anything where a fresh reasoning pass is valuable.
3. **`/delegate` with phased sub-plans** — when one subagent realistically cannot finish in one session. Multi-repo, multi-auth, multi-hour, or a plan with ≥ 10 AC spanning ≥ 2 deliverables. See the "Phased delegation" section below for the mechanics.

Before starting any non-trivial task, the planner asks: *"Can I finish this inline without context bloat?"* If no → `/delegate`. Then asks: *"Can one subagent realistically finish this in one session?"* If no → carve phases. **When in doubt between inline and delegate, delegate.** Don't phase small tasks (overhead > benefit) and don't inline big ones (they stall halfway through).

### Rule 2 — Plans express intent (WHAT + WHY), never HOW

A plan handed to `/delegate` must describe the *outcome* the executor needs to achieve and the *intent* behind the outcome. It must NOT prescribe the command sequences, file edits, commit structure, or syntactic shape the executor uses to get there. That's the executor's job — and the reason the split exists is that the executor reasons better at edge cases when they understand the *why* than when they're mechanically following a recipe.

**What a plan should contain:**
- **WHAT:** goals as invariants that must hold when done. Binary AC observable from outside the diff.
- **WHY:** context, business/technical urgency, constraints that aren't visible from reading the code alone. Enough context that the executor can make judgment calls when something the planner didn't anticipate comes up.
- **What is explicitly NOT prescribed:** the planner names "how" choices left to the executor (language, test framework, file layout, commit granularity, CI setup, etc.).

**What a plan should NOT contain:**
- Step-by-step command sequences the executor must run in order.
- File-by-file edit instructions ("add this function to file X at line Y").
- Specific syntactic choices that don't affect the AC.
- Anything that reads like code review of a diff that hasn't been written yet.

A plan that reads like a how-to guide has gotten the split wrong. Rewrite it as outcomes + intent before running `/delegate`. **The executor needs room to pick the path; the planner's job is to define where the path ends and why it matters that it ends there.** Evidence for why: every run on 2026-04-14 to 2026-04-16 where the planner prescribed a command sequence either had the sequence ignored (best case) or dragged the executor into a worse path than they would have picked themselves. The AC gate is what makes this safe — as long as the AC are binary and observable, the planner doesn't need to own the route.

### Rule 3 — Always deep-research task and source files before planning or implementing

Before writing a plan, the planner deep-researches the task, reads the relevant source files, and confirms the current state of master — they do NOT rely on what they recall from earlier conversation or from pre-loaded context. Before writing code, the executor deep-reads the Critical files section of the plan and the files it references — they do NOT start typing based on what the plan's summary says.

This is the direct consequence of CLAUDE.md hard rule 9 ("measure your own infrastructure before describing it") applied to planning and execution. Planners who skip research write plans grounded in recall, and recall drifts silently from reality — every "I remember file X does Y" is one refactor away from being wrong. Executors who skip research write code that fights the existing codebase's conventions because they didn't see them before coding.

**Practical minimum before writing a plan:**
- `ls` / `Glob` the directories the plan will touch.
- `Read` or `Grep` the files named in Critical files.
- Run the AC's proposed commands against master in a scratch worktree to catch pre-existing debt (this is what Step 3 automates — but it's not a substitute for reading the source).
- If research is >3 queries, spawn an `Explore` subagent and summarize the findings inline in the plan's Context section so the executor inherits the research.

**Practical minimum before writing code (executor):**
- Read every file listed in Critical files, not just open them.
- Run `git log -n 10` on the files about to be edited — recent commits reveal conventions and invariants that aren't documented.
- Read the sub-plan's Context end-to-end. The planner put the load-bearing facts there for a reason.

The skill does not automate this. It lives here because skipping it is the most common preventable failure mode, and documenting it once means future planners and executors don't have to re-learn the lesson.

## Subcommands

The skill has three subcommands:

1. **`/delegate <plan-path> [--via subagent|mailbox <name>]`** — the main path. Plan → brief → delivery.
2. **`/delegate review <pr-url-or-thread-id>`** — spawns a stateless reviewer on shipped work.
3. **`/delegate gate <plan-path>`** — executor-side counterpart. Runs the plan's AC against the current branch and writes a PR-body-ready status table. Read-only, no mutations.

## When to use which subcommand

| User says | Route to |
|---|---|
| "delegate this plan to X" / "hand off to Y" | `/delegate <plan>` |
| "review the PR" / "stateless review on <url>" | `/delegate review <ref>` |
| "run the AC against my branch" / "gate check before push" | `/delegate gate <plan>` |
| "phase this plan" / "deliver phase by phase" / "too big for one handoff" | See "Phased delegation" section below — carve into sub-plans, `/delegate` each |

If the user invokes `/delegate` with no arguments, emit usage help covering all three subcommands and exit.

## Subcommand 1 — `/delegate <plan-path>`

### Step 1: Load and structurally validate the plan

Read the plan file. Assert the plan contains the following required sections as markdown `##` headings. Each bullet lists accepted synonyms — match case-insensitively and allow trailing parenthetical suffixes (e.g., `## Out of scope (explicit)` matches `Out of scope`):

1. **Context** — required.
2. **Goal** OR **Scope** OR **Outcomes** — at least one, required. Accept the CLAUDE.md "invariants that must hold when done" phrasing.
3. **Binary AC** OR **Binary acceptance criteria** — required.
4. **Out of scope** — required.
5. **Ordering constraints** OR **Ordering constraint** — **optional**. Per CLAUDE.md plan-structure rule, omit when ACs have no causal dependencies. Only assert presence when the plan actually declares cross-AC ordering; if absent, skip silently.
6. **Verification procedure** OR **Verification** — required.
7. **Critical files** — required.
8. **Checkpoint** — required.

If a required section is missing (after synonym matching), print `reject: missing section: <canonical-name>` and exit non-zero. Do NOT proceed to delivery. The optional section is never a rejection cause.

### Step 2: Classify each AC

Parse each AC in the "Binary AC" section. Classify into one of four buckets:

- **`observable-command`** — a single command whose pass/fail is visible from outside the diff (e.g., `grep -c foo file.md` returns 1, `test -f path`, `jq -r .key file.json`). The happy path.
- **`diff-inspection`** — can only be checked by reading the diff or the implementation (e.g., "the commit message explains the why"). Flag as a warning, not a rejection. Require an `allow-diff-inspection: <reason>` override line per offending AC; record overrides in run data.
- **`post-merge`** — observable but only after the PR merges (e.g., `gh run list --workflow=foo.yml --limit 1` on a workflow triggered by push-to-master). Satisfied pre-delivery by an explicit existence proxy (`test -f .github/workflows/foo.yml`) and auto-registered in run data with `reverify_after: "ship+48h"` so `/delegate review` re-checks later.
- **`vague`** — not objectively checkable ("code is well-structured", "responses are reasonable"). Reject delivery with a kickback naming the offending AC number.

Classification mechanism is your call — regex, structured parse, or small LLM check all work. What matters is the classification is deterministic on the same input.

### Step 3: Active baseline check (A3-hardened)

For every AC classified as `observable-command`, run the command against **master** and record pass/fail. Do NOT mutate the planner's working tree. Use `git worktree add <tempdir> <master-sha>` into a fresh tempdir, run the command there, tear down on exit. Never `git stash` in the planner's main checkout — a stash+crash loses work.

Any AC that fails baseline is flagged. The skill halts with a kickback message naming the failing AC and suggests delta-based rewording:

    reject: AC-N runs `<command>` which <exits non-zero | prints wrong value> on master.
    Executor cannot satisfy this AC without touching out-of-scope files.
    Rewrite as delta-based ("no new errors vs master baseline") or move to out-of-scope.

The kickback message MUST contain the substrings: the AC number (`AC-N`), the failing tool name (`lint`, `test`, `build`, or `pack` — whichever matches), and `master`.

### Step 4: CI enforcement check

For every AC referencing a tool in `{lint, test, build, pack}`, grep `.github/workflows/*.yml` for the tool command. If the command is not invoked in any workflow, print a warning: `warn: AC-N claims CI enforces <command> but .github/workflows/*.yml does not invoke it`. Non-blocking.

### Step 5: Render the brief

Output a brief containing all of the following:

1. **Inline copy of the plan file** OR a pinned `plan_sha` reference the executor can resolve with `git show`.
2. **Why now** — one paragraph of business/technical urgency from the plan's Context section.
3. **Explicit "not prescribing" list** — surface the "how" choices left to the executor (file layout, commit structure, exact syntax). Gives the executor license to deviate from plan suggestions as long as AC hold.
4. **Tool manifest line** — list the tools the executor can assume are installed (`node`, `npm`, `git`, `grep`, `jq`, `vitest`, etc.) with a fallback clause: "if a listed tool is missing, substitute an equivalent and note the substitution in the ack." This line is load-bearing — it's why the Phase B run burned time on `jq`. The manifest MUST surface `jq` explicitly (or a fallback to `node -e`) when the plan has any JSON-parsing AC.
5. **Dirty-worktree pre-flight requirement for the ack** — executor's ack reply must include `git status --porcelain`, HEAD SHA, expected base branch, and tool availability check. If the worktree has unrelated modifications, the executor either stashes and notes it or flags back.
6. **Stop-on-mode-halt** rule — if the executor hits a tool permission block, plan-mode activation, or any non-recoverable halt, emit a status report via mailbox and stop. Do NOT try to work around.
7. **Stop-on-contradiction** rule — if executing would violate out-of-scope AND satisfy an AC simultaneously, stop and send a `priority: blocker` mail with `reply_sla_seconds: 600` and `auto_schedule_wakeup: true`. Never push through.
8. **Windows MSYS path safety** — any reviewer command in the brief that uses `<rev>:<path>` syntax (`git show origin/master:foo.json`, `git cat-file blob origin/master:bar.ts`, etc.) must be prefixed with `MSYS_NO_PATHCONV=1 ` when it appears inside the verification procedure OR inside the "Reviewer command:" half of a binary AC. Rationale: on Windows MSYS bash, unescaped `:` and `/` in a rev:path argument get silently mangled into `;` and `\`, producing a nonsense ref that git rejects — the command then either errors or (worse) falsely passes with empty-string comparisons. The executor's acceptance wrapper can export the env var once at top of the script to cover all uses inside the wrapper, but the brief's own reviewer-command examples must carry the prefix so a human reviewer running them verbatim on Windows works. Evidence: a real task's AC-3 — the executor's wrapper caught the silent false-pass; without that catch the stateless reviewer would have blown up on AC-3.
9. **Branch-state mode** declaration (see C5 below). Default: `commit-per-task`.
10. **Ordering constraints** (if the plan has any).
11. **Closing line** with ack SLA.
12. **`## Memory systems available` section** — eager-load the memory-systems orientation snippet so the spawned subagent (which likely does not inherit SessionStart hooks) starts with the same cairn / agent-working-memory / project-index pointer that main sessions get. Source: extract the block between `<!-- ORIENTATION-SNIPPET-START -->` and `<!-- ORIENTATION-SNIPPET-END -->` from `${CLAUDE_PLUGIN_ROOT}/3-role-model.md` (the same canonical anchor that `hooks/cairn-session-start.sh` reads). Render verbatim under a `## Memory systems available` heading in the brief output. Implementation note: `awk '/<!-- ORIENTATION-SNIPPET-START -->/,/<!-- ORIENTATION-SNIPPET-END -->/' ${CLAUDE_PLUGIN_ROOT}/3-role-model.md` is the canonical extraction pattern; both hook and brief use it so structural drift is impossible by construction. If `${CLAUDE_PLUGIN_ROOT}/3-role-model.md` is unreachable from the brief-render context, emit the heading with a one-line fallback pointer (`See ${CLAUDE_PLUGIN_ROOT}/3-role-model.md > Memory Systems orientation snippet.`) rather than skipping the section.
13. **`## Git safety constraints` section** — paste-quotable block included verbatim in every brief so the spawned subagent inherits the same discipline forge-execute spawns its subagent with. The block MUST contain all three rules together as one logical unit (force ban + force-with-lease ban + rebase fallback):

    - **NEVER use `git push --force`.** It rewrites remote history and can clobber unrelated commits pushed between your last fetch and now.
    - **NEVER use `git push --force-with-lease`.** It is the false-friend of `--force`: it checks only that the remote tip matches your last fetch, which on a stale local branch is exactly the wrong invariant. monday-bot's US-10 implementation subagent reached for `--force-with-lease` to recover from a rejected push; the user's deny rules caught it, but on a shared branch it would have overwritten unrelated work.
    - **Fallback when a plain push is rejected:** `git pull --rebase origin <branch>`, resolve any conflicts surfaced by the rebase, then retry the plain `git push`. If conflicts cannot be cleanly resolved, surface them in the final summary as a blocker — do not force-overwrite.
    - The deny rules at the harness layer are a backstop, not a contract. Treat this rule as the subagent's own discipline.

**AC-9 allowlist note (auto-injected when the brief mandates an acceptance wrapper):** when a brief includes the acceptance-wrapper-script hard rule (per CLAUDE.md's Planner/Executor brief structure — "the executor must build a plan-mandated acceptance wrapper at `scripts/<task>-acceptance.sh`"), the AC-9-or-equivalent "no drive-by edits" AC's allowlist glob MUST auto-include `scripts/<task-slug>-acceptance.sh`. The skill need not guess the exact slug — inject this placeholder line verbatim in the rendered brief:

> (AC-9 allowlist note: this brief's hard-rule mandating an acceptance wrapper at `scripts/<task-slug>-acceptance.sh` means the executor may commit that wrapper to the PR; it is automatically in-scope for AC-9 regardless of whether the plan's AC-9 allowlist names it explicitly. If the plan's AC-9 allowlist contradicts this, treat the wrapper as in-scope anyway — the acceptance-wrapper hard-rule dominates.)

Evidence: two separate tasks both required executor self-amendments on AC-9 to widen the glob for the mandated wrapper — twice is a pattern, not a coincidence.

The brief MUST NOT contain any language suggesting the skill will edit plan files or that the implementer should commit on behalf of the delegating session via an automated mechanism. The handoff is mechanical, not automated.

#### Branch-state mode (C5)

The brief's Hard Rules section states one of two modes:

- **`mode: commit-per-task`** (default) — implementer commits each logical task unit to the feature branch as they go. Reviewer uses `git diff master...HEAD`. PR has at least one commit at review time.
- **`mode: staged-only`** (legacy) — implementer stages but does not commit. Reviewer inspects the working tree. PR has zero commits at review time.

Select the mode from a `--branch-state` flag, defaulting to `commit-per-task` per the global commit-per-task feedback rule. The reviewer's brief inherits the mode so it knows where to look for the diff.

### Step 6: Deliver

**Subagent delivery is the default. Mailbox delivery requires an explicit user request.**

Mode is inferred from a `--via` flag with the hard-default `subagent`. The skill MUST NOT pick mailbox mode on its own — even when the task looks long-running, cross-machine, or durable. Those are good signals but they are *suggestions*, not decisions. The decision to use mailbox belongs to the user because mailbox mode has operational costs the user has to live with: waking up on wakeup prompts, maintaining a thread across sessions, reading through the mail trail during reviews, paying the cross-session coordination tax on a task that a single subagent could have shipped in one pass.

- **`--via subagent`** (default) — spawn an `Agent` tool call with the rendered brief as the prompt. The agent's only context is the brief. Record the agent id (if emitted) into run data. Use this unless the user has explicitly asked for mailbox.
- **`--via mailbox <recipient>`** — call `/mailbox send to <recipient>` with `thread_id`, `reply_to` (the skill's own inbox), `reply_expected: true`, `reply_sla_seconds: <from brief>`, `auto_schedule_wakeup: true`, and `max_retries` derived from priority (`blocker: 1`, `normal: 2`, `research: 3`). **Only enter this mode when the user has explicitly requested it** — via the `--via mailbox <name>` flag, via plain-English "use mailbox" / "deliver via mailbox" / "hand this off cross-session", or via durable instructions in CLAUDE.md for a specific project that mandates mailbox delivery. If none of those apply, default to subagent; if the user's intent is ambiguous, ask before switching modes.

**Why the mode decision is user-owned, not skill-owned.** Earlier iterations of the /delegate skill let the planner pick mailbox mode when the task "looked big." In practice that chose mailbox for tasks that shipped cleanly as a single subagent delivery (cairn Gap 4 Phase B, agent-working-memory P1/P2/P3/P5), adding cross-session coordination overhead with no corresponding benefit. The forge-harness q05/Q1 mailbox run was a success, but only because the user *wanted* that cross-session trail. Without the user's explicit request, the default is always subagent.

**Dry-run / test mode:** when invoked with `--test` (used by evals), the delivery step is a no-op that returns the rendered brief without spawning or sending. Evals verify brief shape; they do NOT spawn real subagents.

### Step 7: Record the run

Append an entry to `skills/delegate/runs/data.json` with these fields:

```json
{
  "timestamp": "<ISO-8601>",
  "subcommand": "delegate",
  "mode": "real|test",
  "input": "<plan-path>",
  "plan_sha": "<resolved sha>",
  "master_sha_at_capture": "<current master sha>",
  "ac_count": 14,
  "baseline_fail_count": 0,
  "warnings": ["ci-not-enforced:AC-N"],
  "post_merge_acs": ["AC-M"],
  "delivery": {"mode": "subagent|mailbox", "recipient": "<name>", "agent_id": "<id-or-null>"},
  "outcome": "accept|reject",
  "summary": "<one line>"
}
```

## Subcommand 2 — `/delegate review <pr-url-or-thread-id>`

### Step 1: Forge-harness exception

If the target repo has a `.forge/` directory OR a `ship-verified-<pr>` marker file, log `skipped: forge-harness /ship handles stateless review` and exit 0 without spawning anything. The `/ship` pipeline already runs stateless review via its Stage 6; double-reviewing is wasted compute.

### Step 2: Empty-diff sanity (C7)

Pre-flight: `git rev-list --count master..HEAD` on the feature branch. If count is zero, log `empty-diff: branch has zero commits ahead of master` and prompt the planner with three options:

1. Skip review.
2. Review the working tree with a `--dirty-review` flag.
3. Send the implementer an explicit "please commit per task" follow-up.

Never silently proceed to spawn a reviewer on an empty diff.

### Step 3: Stateless reviewer spawn

Spawn a fresh `Agent` subagent. Its ONLY context is:

- The plan's AC list (read from the plan path stored in run data from the original `/delegate` invocation, or passed explicitly).
- The PR diff (`git diff master...HEAD` or `gh pr diff <n>`).
- The branch-state mode (`commit-per-task` → review commits; `staged-only` → review working tree).

The reviewer NEVER sees:

- The original planner conversation.
- Commit messages.
- Mailbox thread history.
- The executor's ack / status reports.

The reviewer runs each AC command against the branch state and returns a binary pass/fail per AC. No "soft pass."

### Step 4: Record the review run

Append a `{"subcommand": "review", ...}` entry to `runs/data.json` with the verdict per AC.

## Subcommand 3 — `/delegate gate <plan-path>`

Executor-side counterpart to the planner's Step 3 baseline check. Read-only.

1. Parse the binary AC from the plan file (same parser as the main path).
2. Run each AC command against **the current branch** (not master). Do NOT check out anything; do NOT mutate the working tree beyond temporary subprocess invocations.
3. Fail-fast on the first failing AC, OR run all and produce a full report (your call — the design leaves this open).
4. Write a PR-body-ready markdown table to stdout:

    | AC | Status | Evidence |
    |---|---|---|
    | AC-1 | PASS | `grep -c foo file.md` returns 1 |
    | AC-2 | FAIL | `test -f missing/path` exit 1 |

5. Exit 0 iff all AC pass; non-zero on any fail. This is the executor's pre-push self-check — if gate fails, they fix before invoking `/ship`.

## Phased delegation (multi-phase plans)

Some plans are too large to ship in one executor handoff — e.g., a plan that creates a new public repo AND a private content repo AND an integration PR against a third repo. A single subagent invocation against the full plan is likely to stall mid-flight (context exhaustion, needed user auth, multi-hour runtime). The canonical pattern for these plans is **one sub-plan file per phase, one `/delegate` invocation per phase**, with the planner updating the master plan's Checkpoint between phases to reflect shipped reality.

This is a convention, not a skill flag. The skill itself still does "one plan → one brief → one subagent" — phasing lives in how the planner carves the work, not in the skill's code path.

### When to phase

Phase a plan when any of the following is true:
- The plan has ≥ 10 Binary AC spanning ≥ 2 distinct deliverables (separate repos, separate PRs, separate machines).
- Executing end-to-end would require ≥ 2 hours of continuous subagent runtime.
- Some AC depend on the user completing a manual step (OAuth, private repo creation, hand-written content) that a subagent cannot automate.
- The plan has natural causal phase boundaries in its Ordering constraints section.

If none of these hold, deliver the plan as one atomic handoff and skip this section.

### Phase workflow

1. **Planner carves the master plan into N sub-plan files**, one per phase. Each sub-plan is a **complete, standalone plan** with its own Context, Goal, Binary AC (a subset of the master's), Out of scope, Critical files, Verification procedure, and Checkpoint. File naming convention: `<master-slug>-phase-<name>.md` under the same `.ai-workspace/plans/` directory. The sub-plan MUST include a **`Parent plan:`** frontmatter field or prose reference pointing at the master plan path, plus a **`Phase:`** field naming this phase. The master plan is never passed to the executor — only the sub-plan is.
2. **Each sub-plan's Context section summarizes prior-phase shipped reality** (not the full master context). The executor's only job is to make this sub-plan's AC green; it does not need to know about phases N+1 or later.
3. **Planner invokes `/delegate <sub-plan-path>` per phase**, in order. Default `--via subagent` spawns a fresh Agent with zero context from prior phases — the previous phase's agent id is NOT reused. Each phase gets its own clean context window.
4. **Between phases, the planner updates the master plan's Checkpoint** to mark the phase complete and records any deviations from the original sub-plan (file paths the executor chose, AC relaxations, surprises). This is a manual `Edit` on the master plan file in the planner's own working tree. `/delegate` never edits plan files (see Out-of-scope list).
5. **Each phase gets its own stateless review** via `/delegate review` (unless the harness exception in Subcommand 2 applies). A PASS on phase N closes that phase; the next phase's sub-plan is then delivered.
6. **On BLOCK at any phase**, the planner decides: amend the sub-plan (and re-run `/delegate` on the amended version) OR fix the master plan and re-carve downstream sub-plans.

### Sub-plan AC numbering

Sub-plan AC renumber from AC-1 locally. The master plan's AC numbers are **NOT** preserved in sub-plans — that creates confusion when a reviewer runs "AC-7" and finds it's the only AC in the sub-plan. Instead, each sub-plan has its own AC-1..AC-K numbering, and the master plan's Checkpoint cross-references master-AC → sub-plan-AC mappings for audit.

### Run data

Phased delegations are recorded as independent runs in `runs/data.json` — one entry per phase. Each run's `input` field points to the sub-plan path, and an additional `parent_plan` field (optional) points to the master plan for cross-reference. The skill does not track phase sequencing — that lives in the planner's task list or the master plan's Checkpoint.

### What this section does NOT change

- `/delegate` still does not edit plan files. Sub-plan creation and master-plan checkpoint updates are manual `Edit` actions by the planner.
- The skill has no `--phase <N>` flag, no resume semantics, no cross-phase state. Phase boundaries live in filenames and prose, not in skill code.
- Each `/delegate` invocation is still stateless from the skill's perspective — it sees one plan, one AC list, one brief, one delivery.

### Evidence

This convention was ratified on 2026-04-15 during the `agent-working-memory` ship (master plan: `.ai-workspace/plans/2026-04-15-agent-working-memory.md`), a 12-AC green-field plan spanning one public repo, two private repos, and a shared-memory integration PR. A single-subagent delivery was judged structurally infeasible; phased delivery with six sub-plans (P0 this section, P1 public scaffold, P2 private content repos, P3 install+cards, P4 integration, P5 smoke) was adopted instead. Each sub-plan shipped through its own `/delegate` → review → checkpoint cycle.

## Out of scope (hard boundaries)

The skill MUST NOT do any of the following. These are load-bearing boundaries drawn from the design plan's "What I deliberately did NOT propose" sections:

- **Edit plan files.** If AC need amendment, that is a manual `Edit` + mail instruction, not a skill action. Mechanical plan amendment invites the same class of bug as auto-resolving merge conflicts.
- **Commit on behalf of the implementer.** Commit-per-task is a rule the implementer follows via their task flow, not a skill action. The skill never automates a commit.
- **Wrap `/ship`.** In forge-harness and similar harness-wrapped repos, `/delegate review` is a no-op on PRs. Forward direction (`/delegate <plan>`) emits a warning in harness repos but still proceeds.
- **Synchronous wait-for-reply.** `/delegate` ends at executor-starts. `/delegate review` is a separate later invocation. No "fire and wait for hours" inside one skill call.
- **Decide whether to delegate.** The user decides from judgment; the skill is the clerk.
- **Auto-strip CRLF from files.** Surface the landmine in the baseline check; the fix belongs in a plan amendment or the implementer's sed, not in the skill mutating shared files.
- **Run against the live forge-harness design file without snapshotting.** Eval inputs MUST be pinned snapshots, not live cross-repo links.

## v1 scope and deferred items

The v1 subset of the full design (26 AC, in `forge-harness/.ai-workspace/plans/2026-04-14-delegate-skill-design.md`) implements:

- Core mechanics: AC-1 through AC-14 from the design.
- A1 gate subcommand (this file, Subcommand 3).
- A3 worktree hardening (this file, Step 3 of Subcommand 1).
- A5 eval frontmatter SHA pinning (see `evals/*.md` frontmatter).
- C3 post-merge AC bucket (this file, Step 2 of Subcommand 1).
- C5 branch-state mode (this file, Step 5 of Subcommand 1).
- C7 empty-diff sanity (this file, Step 2 of Subcommand 2).

**Deferred to v1.1:** ack subcommand (A2), planner-side regression check (C1), `.gitkeep` enforcement (C4). These ship after three real runs expose whether they're needed.

**Deferred to v1.2+:** wrapper drift linter (C2), retry budget tuning (A6), forward-harness warning (A7), SendMessage continuity (C6), AC-4 escape hatch (A8). Ship when real-run data shows they matter.

## Evals

Three eval inputs live at `evals/`, each with YAML frontmatter pinning `plan_sha` and `master_sha_at_capture`. Before running an eval, check out `master_sha_at_capture` into an isolated worktree so the baseline check is reproducible — otherwise a CI workflow change between record-time and run-time silently breaks the test.

- **`input-a-cairn-gap4-phaseb.md`** — positive test. Expected: `accept`. Brief must contain tool manifest line with `jq` or explicit fallback.
- **`input-b-q05-q1-pre-amendment.md`** — negative test (critical). Expected: `reject`. Kickback must contain `AC-11` AND `lint` AND `master`. Must fire before brief render.
- **`input-c-q05-q1-post-amendment.md`** — sanity test. Expected: `accept`. Brief has zero warnings.

Cross-input invariants and full expected strings live in `evals/expected-outputs.md`.

## Run Data Recording

After every invocation (any subcommand, real or test mode), persist a run entry so `/skill-evolve improve delegate` can refine this skill from observed failures after 5+ runs.

**Location:** `skills/delegate/runs/data.json` (resolve via the symlink target, not the current working directory).

**Schema:**

```json
{
  "skill": "delegate",
  "lastRun": "2026-04-15T10:00:00Z",
  "totalRuns": 12,
  "runs": [
    {
      "timestamp": "2026-04-15T10:00:00Z",
      "subcommand": "delegate|review|gate",
      "mode": "real|test",
      "outcome": "accept|reject|skip|error",
      "input": "<plan-path or pr-ref>",
      "plan_sha": "<sha>",
      "master_sha_at_capture": "<sha>",
      "ac_count": 14,
      "baseline_fail_count": 0,
      "warnings": ["ci-not-enforced:AC-N"],
      "post_merge_acs": ["AC-M"],
      "delivery": {"mode": "subagent|mailbox", "recipient": "<name>", "agent_id": "<id>"},
      "duration_ms": 1234,
      "summary": "<one line>"
    }
  ]
}
```

**Outcome values:** `accept` | `reject` | `skip` | `error`.

**Retention:** keep last 50 runs in the `runs` array. Older entries are truncated. `totalRuns` is the lifetime count and is NOT reset by truncation.

**Metric fields beyond timestamp/outcome:** `subcommand`, `mode`, `ac_count`, `baseline_fail_count`, `warnings` (array), `post_merge_acs` (array), `delivery.mode`, `delivery.recipient`, `duration_ms`, `plan_sha`, `master_sha_at_capture`. These are the fields `/skill-evolve improve` mines to suggest template refinements.

Also append a one-line-per-run entry to `runs/run.log` with `<iso-timestamp> <subcommand> <outcome> <summary>` for quick tail-inspection.

