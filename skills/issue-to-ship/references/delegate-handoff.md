# Delegate handoff contract

After the show-and-wait gate (Stage 4) confirms user approval, hand off to `/delegate` for executor dispatch. This document is the exact contract for that handoff.

## Pre-conditions

- P4 returned SHIP-CLEAN.
- The user has explicitly approved the ELI5 final-plan summary (yes / approve / proceed / "ship it"). Silence is NOT approval. A reviewer's "SHIP" verdict is NOT user approval.
- Pre-authorization counts only if quotable from the current session ("draft and ship", "auto mode just do it", "delegate after review without asking").

## Dispatch — bare `/delegate` or via `/auto-flow` Step 7+

Two patterns:

- **Bare `/delegate <plan-path>`** — when the four-reviewer pass already ran in this skill's Stage 3. The reviewer chain is the value-add of `/auto-flow`; once it's done, bare `/delegate` is the appropriate handoff (the plan has been reviewed equivalently elsewhere).
- **`/auto-flow` from Step 7** — if you want the autonomous-arc dispatch behaviour (worktree-from-`origin/master`, 8-section briefs, single-message dispatch, task-list track). Use when the plan is multi-bundle.

For most `/issue-to-ship` invocations, **bare `/delegate`** is the right shape: this skill's Stage 3 already ran the reviewer chain.

## Brief contents — required sections

The `/delegate` skill renders a brief from a template; ensure the plan supplies the inputs it expects.

1. **Worktree spec.**
 - Path: `<repo>/.claude/worktrees/<slug>`.
 - Branch: `<feat|fix|chore>/<slug>`.
 - Source: **`origin/master`** — NOT local master. Local master may be stale.
2. **Critical files list.** Every file the executor will create/edit/delete. New files marked `(new)`. Re-verify paths against live `origin/master` at dispatch time.
3. **Binary AC contract.** All N ACs from the plan, verbatim. Pin orientation (no "+N/-0 OR +0/-N" ambiguity).
4. **Out of scope list.** Verbatim from plan.
5. **Ship pipeline — full `/ship` Stages 0-10.** Marker path pinned: `.ai-workspace/ship-verified-<PR>` (NOT `tmp/.ship-verified-<PR>`). Conventional commit prefix (`feat(...)`, `fix(...)`, `chore(...)`). Rule-12 worktree discipline. Rule-14 cleanup via `git worktree remove`.
6. **Cohort sequencing notes.** In-flight PRs that share files. Likely-shared write surfaces. Wait-for-subagent dependencies.
7. **Pre-existing failure inventory.** Known-failing ACs on origin/master baseline that this PR does NOT fix (e.g., `tests/session-bookmark/drift-nudge-acceptance.sh` AC-9 PATH="" rc=127). The executor must NOT treat these as regressions.
8. **Self-checks pre-push.** Plan-supplied verification recipe (`bash tests/<area>/<harness>.sh`, `git diff --stat origin/master..HEAD`, etc.).

## Compound-Bash warning

When the executor reaches the marker-write + merge step, the marker write and `gh pr merge` MUST be in **separate Bash invocations**. Compound `touch <marker> && gh pr merge` triggers the enforce-ship hook's substring-match against the entire compound, blocking the marker write.

Pin this in the brief: "Stage 6 — write marker file at `.ai-workspace/ship-verified-<PR>` in a SEPARATE Bash invocation from `gh pr merge`."

## Post-merge — hand to post-ship-protocol

After `/delegate` returns the merged PR number, hand off to `references/post-ship-protocol.md` (Stage 6 of this skill's workflow).
