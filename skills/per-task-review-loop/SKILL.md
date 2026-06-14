---
name: per-task-review-loop
description: Inline implementation quality gate that fills the gap /auto-flow and /delegate don't cover — serial single-session work where each task could break independently and parallel-dispatch isn't applicable. Two modes: (a) per-task — after each implementation task dispatch a stateless reviewer in background while you continue; PASS log+continue, FAIL pause+fix+re-dispatch, IMPROVE apply if cheap. (b) plan-chain — before locking a plan, run 4 reviewers in series (P1 stateless → P2 comparative → P3 cairn-grounded → P4 coherence) so each builds on the prior verdict. Make sure to invoke this skill whenever the user says "/per-task-review-loop", "use the review loop", "review every task", "review per task", "review every step", "stateless reviewer per task", "post each task review", or starts a multi-task arc that mutates system state (config files, env vars, services, processes), writes custom code (shell scripts, helper binaries), updates non-trivial config (settings.json, plist, env files), or has load-bearing assumptions worth catching pre-implementation. Also trigger on plan reviews when the plan has external pulls, downloaded models, threshold calibrations, or option/alternative selections. Skip ONLY for pure install/download (`brew install X`, `npm install Y` — exit code is the verifier), user-action with no CLI cross-check (toggle a system setting), file-content writes that are byte-for-byte deterministic from a contract already reviewed, or pure read-for-diagnosis. Empirically validated 2026-05-08 with 9+ GREAT-tier catches across 20+ reviewer dispatches in a single session, including catches that saved 30 GB of wasted Ollama pull and proved an `ollama create -q q8_0` no-op live.
---

# Per-Task Review Loop

A two-mode review pattern: (a) **per-task** stateless reviewer dispatched in background after each implementation task, (b) **plan-chain** of 4 series-dependent reviewers (P1→P2→P3→P4) for plan-review work. Both modes have proven empirically valuable across 20+ reviewer dispatches with 9+ GREAT-tier catches in a single session.

## Why this skill exists (gap coverage)

`/auto-flow` and `/delegate` solve adjacent but different problems:

| Skill | What it solves | Where it doesn't fit |
|---|---|---|
| `/auto-flow` | Multi-bundle parallel work — worktree-per-surface, briefs, /ship pipeline | Single-session inline work where there's nothing to parallelize |
| `/delegate` | Planner → executor handoff to a separate session via subagent or mailbox | Same session is doing the work; no handoff |
| **`/per-task-review-loop` (this skill)** | **Serial inline single-session implementation, every task gets an independent reviewer cross-check** | Pure install / mechanical copy / user-only actions |

The pattern: you're in the middle of a 30-50 task implementation arc on your own machine in your own session. You cannot parallelize across worktrees (the work is sequential — each task depends on prior state). You cannot handoff to a different executor (you ARE the executor). But every task could break in a way that wouldn't be caught by your own ACs. This skill dispatches an independent reviewer in the background after each task while you continue, so defects are caught while still cheap to fix.

## When to use

**USE per-task mode when**:
- Implementing tasks that mutate system state (config files, env vars, services, processes)
- Writing custom code (shell scripts, helper binaries) where defects could be load-bearing
- Updating non-trivial config (settings.json, plist, env files with cross-system effects)
- Any artifact where a 3-month-later debugger would benefit from independent verification

**USE plan-chain mode when**:
- Reviewing a non-trivial plan before implementation commits (≥1-hour effort or external pulls / installs)
- The plan has a load-bearing assumption (a downloaded model, an external API shape, a measured threshold)
- Multiple options or alternatives need cross-comparison

**SKIP when**:
- Pure install / download / `brew install X` / `npm install Y` (mechanical, exit-code is the verifier)
- User-action with no CLI cross-check (e.g., toggle a system setting; user reports done)
- File-content writes that are byte-for-byte deterministic from a contract already reviewed
- Reading existing state for diagnosis (already inspectable; reviewer adds no signal)

## Per-task mode (8 steps per task)

For each task #N:

1. `TaskUpdate #N status=in_progress`
2. **Execute task inline** (do the work)
3. **Capture completion artifact** (file diff / command output / user-confirmation log)
4. `TaskUpdate #N status=completed`
5. **Dispatch stateless reviewer in background** (`Agent run_in_background=true`):
   - Inputs: plan §spec + artifact + task description
   - Reviewer returns one of: `PASS` / `FAIL-WITH-FIX` / `IMPROVE-SUGGESTION`
6. **Continue to task #N+1** — do NOT block on the reviewer
7. **On reviewer notification**:
   - `PASS` → log to evidence file, continue
   - `FAIL` → pause, fix per reviewer's suggestion, re-dispatch reviewer
   - `IMPROVE` → apply if cheap (≤2 min); else log and continue
8. **Phase boundary**: BLOCK on all in-flight reviewers from this phase returning PASS before next phase starts

### Per-task reviewer prompt template

```
You are a stateless reviewer for Task #N of plan <plan-path>.

**Task:** <task description>
**Plan §spec excerpt** (relevant section): <quoted spec>
**Implementer's claimed artifact:**
- Files modified: <list>
- Output captured: <verbatim>
- ACs claimed: <list of AC-N: PASS/FAIL>

**Independent cross-checks (GREAT-tier signal only on real defects):**

1. <cross-check 1 — something the implementer could not easily run themselves>
2. <cross-check 2>
3. ... (3-6 checks total)

**Verdict format:**
- VERDICT: PASS / PASS-WITH-FOLLOW-UP / FAIL
- Signal class: GREAT / MEH / REDUNDANT / NOISE
- Findings (bullet list)
- Specific fix-ups (file:line if any)
- Plan amendment proposed (if any)

Keep response under 400 words.
```

## Plan-chain mode (4 reviewers in series)

For plan review BEFORE implementation, dispatch 4 stateless reviewers in **series** (each sees prior verdicts):

| Reviewer | Role | Sees |
|---|---|---|
| **P1 stateless** | Cold-read; opinionated independent judgement on ACs, hypotheses, threshold calibration | Plan only (no prior context) |
| **P2 comparative** | Cross-tool / cross-method comparison; answers P1's open questions; finds alternatives the plan missed | Plan + P1 verdict |
| **P3 cairn-grounded** | Searches `hive-mind-persist/knowledge-base/` (P/F patterns), session-notes, retrospectives, cairn t1-pending/scratch for prior art that supports/contradicts the plan; answers P2's open questions | Plan + P1 + P2 verdicts |
| **P4 coherence** | Internal-consistency audit (AC-vs-contract symmetry, line-anchored conflicts, run-count drift, verdict-rule precedence trace); rolls up final chain decision | Plan + P1 + P2 + P3 verdicts |

### Plan-chain reviewer prompts (template structure)

Each reviewer prompt includes:
1. **Background** (1 paragraph: plan version history, what changed)
2. **Prior verdicts** (verbatim from previous reviewers in chain)
3. **Your job** (5-7 specific concrete questions to answer)
4. **Hard constraints** (host facts, user preferences, "don't re-flag fixed defects")
5. **Verdict format** (concrete output schema with placeholders)

### Plan-chain final synthesis

After P4 returns, the orchestrator (the assistant running the chain):
1. Collates all 4 verdicts into a delta-list of fixes to fold
2. Folds fixes into the plan as v-N+1
3. Either:
   - All 4 APPROVE → present plan + delta-list to user; ask for merge approval
   - Any REJECT → either rewrite plan as v-N+2 + dispatch fresh chain, OR if blocking issue is empirically disprovable (e.g., target tag doesn't exist), pivot to alternative without further chain rounds

## Signal classification (record after every reviewer verdict)

Append to a durable evidence log (`<repo>/.ai-workspace/retrospectives/<date>-per-task-review-loop-evidence.md`) after every reviewer returns:

| Signal | When to record | Examples |
|---|---|---|
| **GREAT** | Reviewer caught a REAL defect via INDEPENDENT cross-check the implementer could not easily run | "Tag `qwen3.6:27b-coding-q8_0` doesn't exist on Ollama Hub — saved 30 GB pull"; "AC-3 verifier `grep -qv` is vacuous-pass; needs `! grep -q`"; "env-card-probe.sh hardcodes `~/.claude/...` — would pollute planner state from executor SessionStart" |
| **MEH** | Reviewer audited the artifact correctly but found no defect; audit value but no fault to fix | "AC-2 byte-for-byte file-write check: clean" |
| **REDUNDANT** | Reviewer ran the same check the implementer's own ACs already ran | "PID-equality verified by both implementer and reviewer using same shell command" |
| **NOISE** | Reviewer had no programmatic verification path available; produced subjective audit only | "Power Mode user-action; reviewer cannot verify GUI setting" |

## Pre-flight checks (cheap insurance, ~30 sec — 5 min)

Before committing significant effort (≥30 min, ≥10 GB pull, ≥10 file edits), do at least ONE of:

1. **Tag/path existence check** — does the resource the plan calls for actually exist?
   - For Ollama: `curl -s https://ollama.com/library/<model>/tags | grep -oE "<model>:[a-zA-Z0-9_\-\.]+" | grep <variant>`
   - For npm: `npm view <pkg>` exits 0
   - For brew: `brew info <formula>` succeeds
   - For files: `[ -f <path> ]`
2. **Doc-level pre-verify** — if the plan depends on an external behavior, search the upstream issue tracker for known-broken: `gh search issues "<keywords>" --repo <upstream>/<repo> --limit 5`
3. **Disk / resource precheck** — `df -h <target>`; `vmmap` peak; `nvidia-smi`/`vmmap`/etc. before workload
4. **Live empirical** — for ≤30-sec one-shot tests (e.g., "does `ollama create -q q8_0` actually requantize from this source?"), just RUN it and inspect the output

GREAT-tier catches consistently come from pre-flight discovery of broken assumptions BEFORE the implementer commits to the load-bearing step.

## Cost estimate (so you can budget)

- Per-task reviewer: ~3-5K tokens per dispatch
- Plan-chain (4 reviewers in series): ~15-25K tokens total
- Wall-clock impact: ~zero (background dispatch; reviewers complete in 30 sec - 3 min while implementer continues)
- Money: ~$0.80-$2 per implementation arc on Sonnet; ~$2-$5 on Opus

For a 40-task implementation arc with 30 reviewable tasks (10 skipped per "When to use" rules above): ~120K tokens of review traffic, ~$2 on Sonnet, ~$5 on Opus. Well below most session budgets.

## Promotion-to-skill criteria (this skill itself, retrospective)

This skill was promoted from inline pattern to canonical skill on 2026-05-08 after empirical validation:
- 20+ reviewer dispatches in a single session
- Sustained ~50% GREAT-rate
- Real defects caught BEFORE implementation: missing Ollama tag (saved 30 GB pull), silent mxfp8→q8_0 no-op (proven live), AC-3 vacuous-pass verifier, env-card-probe planner-state pollution, cc-env.sh executor-vs-cron-dir bug, prompt-4-had-no-actual-bug
- Pattern stable across 4+ plan domains (memory monitoring, dual-model A/B test, executor profile, hybrid-LLM workstation setup)

If you replicate this pattern in another arc and get sustained GREAT-rate, that's evidence the loop is generalizable beyond the original domain. If you instead get sustained MEH/REDUNDANT, the loop is over-applied for that work type — narrow the "When to use" criteria.

## Evidence log format

Each entry (one per reviewer return) is 5 lines:

```markdown
### Task #N — <subject>
- **Built**: <one-line summary of what implementer did>
- **Reviewer verdict**: PASS / FAIL / IMPROVE — <one-line reason>
- **Wall-clock / Tokens**: <reviewer wall-clock>s / <token count>
- **Signal**: GREAT / MEH / REDUNDANT / NOISE
- **Why**: <one-line classification rationale>
```

Preface the file with: hypotheses being tested, taxonomy reference, plan paths, and a running scoreboard summary.

## Worked example (per-task mode)

**Setup**: User has a 30-task implementation arc for "set up a hybrid LLM workstation." Task #11 is "Create `~/.cc-executor` profile dir + symlinks + trimmed settings.json."

**Input** (what the implementer just did):
- 8 mkdir / symlink commands run; 1 settings.json written via jq transform from planner's settings (3226 → 2984 bytes)
- AC verifications: AC-1 (skills symlink resolves) PASS, AC-2 (trimmed settings.json valid JSON) PASS, AC-3 (private write paths created) PASS

**Output** (reviewer dispatched in background):
- Reviewer reads the v3 plan §"Executor profile" + the implementer's claim of 8 ACs PASS
- Reviewer runs 6 INDEPENDENT cross-checks the implementer didn't run themselves
- Reviewer returns: `VERDICT: PASS-WITH-FOLLOW-UP, Signal: GREAT — env-card-probe.sh hardcodes ~/.claude/{cairn,session-bookmarks,agent-working-memory,.host-id-local}; when executor SessionStart fires, it will write to PLANNER state. Phase-2 isolation VIOLATED. Fix: drop env-card-probe.sh from executor SessionStart entirely OR thread 4 override env vars.`
- Implementer (now on Task #12) gets notification, pauses, applies fix to settings.json (drops env-card-probe from SessionStart hooks via 1 jq edit, re-validates, re-dispatches reviewer)
- Reviewer #2 returns PASS. Implementer continues to Task #13.
- Evidence log records: `### Task #11 ... Signal: GREAT ... Why: caught real cross-profile pollution risk via independent code-read of hook scripts`

**Key insight**: the catch was something the implementer's own ACs couldn't have surfaced — it required an independent read of `env-card-probe.sh:46-49` looking for hardcoded paths. The reviewer was the cheapest possible source of that cross-check.

## Run Data Recording

Per ${CLAUDE_PLUGIN_ROOT}/3-role-model.md skill-evolve discipline, this skill records run data to enable `/skill-evolve improve` after 5+ invocations. After each invocation (each implementation arc), append one entry to `runs/data.json` (relative to skill source dir; resolve via symlink target).

### Canonical schema (skill-evolve compatible)

```json
{
  "timestamp": "{ISO-8601}",
  "outcome": "complete|no-action|error",
  "project": "{current project directory name}",
  "metrics": {
    "arc_description": "<one-line summary of the arc>",
    "tasks_total": 30,
    "tasks_reviewed": 22,
    "tasks_skipped_per_when_to_use_rules": 8,
    "reviewer_verdicts": {"PASS": 18, "FAIL": 2, "IMPROVE": 2},
    "signals": {"GREAT": 9, "MEH": 8, "REDUNDANT": 4, "NOISE": 1},
    "great_rate": 0.41,
    "wall_clock_minutes": 240,
    "tokens_used": 145000,
    "money_usd_estimate": 2.10,
    "model_used": "claude-sonnet-4-6"
  },
  "issues": [
    { "stage": "<per-task|plan-chain>", "type": "<missed-defect|over-applied>", "description": "<text>" }
  ],
  "summary": "{one-line}",
  "evidence_log_path": "<repo>/.ai-workspace/retrospectives/<date>-per-task-review-loop-evidence.md",
  "notable_catches": ["<one-line GREAT-catch summary>", "..."],
  "lessons": ["<one-line takeaway for future arcs>", "..."]
}
```

**Outcome values:**
- `complete` — arc finished, GREAT-rate ≥ 30% (loop earned its keep)
- `no-action` — arc finished but all reviewers were MEH/REDUNDANT/NOISE (loop over-applied for this work type — narrow When-to-use)
- `error` — arc aborted before sufficient reviewers fired

Keep last 50 runs. Set `lastRun` and increment `totalRuns` on append. Append one line to `runs/run.log` (keep last 100 lines): `{timestamp} | {outcome} | <arc-name> | <one-line summary>`.

After 5+ runs accumulate, run `/skill-evolve improve per-task-review-loop` to refine "When to use" rules based on which task types actually produced GREAT vs MEH/REDUNDANT signal.

## See also

- `/auto-flow` — heavier-ceremony 4-reviewer chain for production planning (this skill's plan-chain mode is the lighter cousin)
- `/coherent-plan` — bounded-loop plan critic+corrector (orthogonal — used during plan WRITING; this skill is used during plan REVIEW + implementation)
- `/double-critique` — heavier-ceremony plan critique (use for 200+-line implementation specs)
- `/delegate` — handoff for committable PRs (orthogonal — this skill stays inline)
