# <PLAN TITLE — replace with one-line outcome statement>

**Date:** <YYYY-MM-DD>
**Author:** <session name / operator>
**Status:** DRAFT — awaiting /auto-flow Stage-1 reviewer chain (P1→P2→P3→P4)
**Type:** <code change | rule change | hook change | doc change>

## ELI5

<1-paragraph plain-language summary. What's broken in plain English, what we're going to do, what'll be different after this PR merges. No jargon.>

## Context

<Real-history retrospective. What surfaced this issue? Which prior PRs / sessions / cairn stones connect to it? Cite specific commit SHAs and file paths.>

<!-- TOKEN-SHAPE: enumerate live emitters from `git show origin/master:hooks/session-bookmark.sh | grep -nE '_NUDGE:'` (or the equivalent grep against the relevant target file). Don't copy the count from a sibling plan; emitter counts drift fast under concurrent shipping. -->

## Goal

<After this PR merges, what is true that wasn't true before? Bullet list. Each bullet should be a checkable invariant.>

1. <Invariant 1>
2. <Invariant 2>
3. <Invariant 3>

## Why this scope

<Why this exact scope? What was considered and rejected (Option A, Option B)? Why is the chosen Option C the smallest sufficient scope?>

- **Option A — <name>.** <Description.> Rejected: <reason>.
- **Option B — <name>.** <Description.> Rejected: <reason>.
- **Option C (chosen) — <name>.** <Description.>

<!-- AC TEMPLATE: pin orientation. NEVER write "+N/-0 OR +0/-N" — that's ambiguous. Use literal `+5/-0` for added-only, or `+0/-5` for deleted-only. Pick one orientation per AC. -->

## Critical files

<Paths verified <YYYY-MM-DD> against `origin/master`. Re-verify if shipping more than a day after this draft.>

- `<path/to/file>` — <new | extend | refactor | delete>. <One-line role.>
- `<path/to/file>` — <new | extend | refactor | delete>. <One-line role.>

<!-- WORKTREE: use `git worktree add ~/coding_projects/<repo>/.claude/worktrees/<slug> -b <branch> origin/master`. NOT local master. Local master may be stale; origin/master is the canonical baseline. -->

## Approach (intent only — executor picks mechanics)

<Mechanism X1 — <name>.> <Intent: what changes, why. Do not prescribe HOW.>

<Mechanism X2 — <name>.> <Intent: what changes, why.>

<Mechanism X3 — <name>.> <Intent: what changes, why.>

<!-- COMPOUND-BASH: separate Bash invocations for marker write + `gh pr merge`. The enforce-ship hook substring-matches the entire compound, so `touch <marker> && gh pr merge` blocks the marker write. Two separate Bash tool calls. -->

<!-- CONFIG WARNING: `/config` runs in Claude Code can silently strip array entries from settings.json (hooks, permissions). Verify settings.json content vs origin/master before relying on a hook entry; do not assume `/config` is diff-preserving. -->

**Pattern grounding.**

<!-- CAIRN-CITATION: subagents search cairn via `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs" "<keyword>"` (the `/cairn find` Skill no-ops in a subagent shell). Fill the line below with a QUOTED hit OR "no hits for <queries>" — this is the honest signal the cairn leg actually ran. -->

- **cairn:** <quote one matched `cairn-find` result line, e.g. `[T1] …:NN <text>`> OR `cairn: no hits for <queries-tried>`.
- **<P-ID>** — <pattern name> (`hive-mind-persist/knowledge-base/01-proven-patterns.md:<line>`): <how it applies>.
- **<F-ID>** — <anti-pattern name> (`hive-mind-persist/knowledge-base/02-anti-patterns.md:<line>`, GUARDED AGAINST): <how this plan guards against it>.

**Preserved invariants:**

- <Invariant 1 — what's NOT changing>
- <Invariant 2>

## Out of scope

- <Explicitly NOT in this PR. Future enhancement.>
- <Explicitly NOT in this PR. Different concern.>

## Binary AC

All AC verifiable from outside the diff (exit code 0 on a verifier command, file presence, grep hit, API response).

1. **<AC name>.** <Verifier command + expected output. Pin orientation; do not write "+N/-0 OR +0/-N".>
2. **<AC name>.** <Verifier command + expected output.>
3. **<AC name>.** <Verifier command + expected output.>

## Verification (end-to-end)

**Pre-push (synthetic):**

- <ACs verified via `bash tests/<skill-or-area>/<harness>.sh`.>
- <`bash -n` syntax checks on any shell scripts touched.>
- <Skill-health audit if a skill is touched: `/skill-evolve audit <name>` reports `FAIL=0`.>

**Post-merge (real):**

1. <End-to-end smoke test description.>
2. <Confirm telemetry recorded (runs/data.json updated).>
3. <Confirm sister artefacts unchanged (ADDITIVE invariant).>

## Sequencing

<Where does this plan sit relative to in-flight plans? Does it touch shared files? Does it depend on a not-yet-shipped hook?>

<!-- CROSS-CONTAMINATION: don't mutate primary clone state while worktree subagents are active. Wait for active subagents to finish before pulling primary, OR rely on the cross-clone-contamination hook (when shipped) to refuse the mutation. -->

**Pre-flight Rule-10 check:** verify no open PR touches the exact files this plan introduces or modifies. Narrow regex to avoid false-positives from unrelated work in the same directory tree.

## Risks & mitigations

- **Risk: <name>.** Mitigation: <how this plan handles the risk>.
- **Risk: <name>.** Mitigation: <how this plan handles the risk>.

## Execution model

- Worktree: `~/coding_projects/<repo>/.claude/worktrees/<slug>` from `origin/master` (Rule 12).
- Branch: `<feat|fix|chore>/<slug>`.
- Commits: per-mechanism (X1, X2, X3) — NOT one megacommit.
- /ship: full Stages 0-10 pipeline.

<!-- CLEANUP: use `git worktree remove <path>` for worktree cleanup (Rule 14 worktree exception). NOT `mv` — `mv` of a registered worktree leaves stale `.git/worktrees/<name>/` metadata. NOT `rm -rf` — irreversible. -->

## Checkpoint

- [ ] Retrospective on the surfacing incident
- [ ] Identify repeating mistakes worth codifying
- [ ] File this plan
- [ ] P1 cold review
- [ ] P2 comparative review
- [ ] P3 cairn-grounded review
- [ ] P4 mechanical sweep
- [ ] User approval on ELI5 final plan (post-P4 show-and-wait gate)
- [ ] Implement Mechanism X1-Xn
- [ ] Run all ACs locally
- [ ] /ship the PR
- [ ] Post-merge smoke test

## Last updated

- <YYYY-MM-DD>T<HH:MM>Z — Plan filed. Awaiting /auto-flow Stage-1 reviewer chain.

<!-- MARKER PATH: `/ship` Stage 6 marker file is `.ai-workspace/ship-verified-<PR>`. NOT `tmp/.ship-verified-<PR>`. NOT `.ai-workspace/.ship-verified-<PR>`. The literal path is `.ai-workspace/ship-verified-<PR>`. Pin it canonically in your dispatch brief. -->
