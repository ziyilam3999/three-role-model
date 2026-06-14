---
name: ship
description: >
 Full git shipping pipeline: commit, branch, push, create PR, wait for CI,
 self-review loop (with bug fix iterations), and merge. Use when the user says
 "/ship", "ship it", "ship this", "commit and merge", "push and merge",
 "create PR and merge", or wants to go from working changes to a merged PR
 in one command. Do NOT use for simple git operations like just committing
 or just pushing -- this is the full end-to-end pipeline.
---

# Ship Pipeline

Execute the full git shipping pipeline on the current working directory. If `$ARGUMENTS` is provided, use it as a hint for the commit message.

## Pipeline Overview

| Stage | Name | Action | Abort condition |
|-------|------|--------|-----------------|
| 0 | Pre-flight | Check for changes, branch, gh auth | Nothing to commit |
| 1 | Branch | Create feature branch if on master | -- |
| 2 | Commit | Stage files and commit | -- |
| 3 | Push + PR | Push and create PR via gh | -- |
| 4 | CI Wait | Poll `gh pr checks` up to 10 min | CI failure |
| 5 | Self-review | Stateless reviewer loop (max 5) | 5 iterations exhausted |
| 5.5 | Cairn index-check | Honor-system trailer gate (knowledge-base touches) | Missing/invalid trailer |
| 6 | Merge | Squash merge via gh | Merge conflict |
| 7 | Release | Version bump, changelog, tag, GitHub Release | -- |
| 8 | Cleanup | Switch to master, pull, delete branch | -- |
| 9 | Record | Persist run data to `runs/data.json` and `runs/run.log` | -- |
| 10 | Card | Emit working-memory decision card (success runs only) | -- |

Print a status line before each stage:
```
[SHIP {N}/10] {description}...
```

**Stage 9 is NOT optional.** Prior versions of this SKILL.md placed Run Data Recording as an appendix below the main stages, which made it structurally easy to skip — operators executing the pipeline manually would finish Stage 8 Cleanup, feel the work was done, and exit before reaching the recording. That silent-skip failure mode was caught by a 2026-04-15 `/skill-evolve improve` pass after three consecutive `/ship` invocations in one session left no `data.json` trace. Promoting recording to a numbered stage with its own `[SHIP 9/10]` status line makes the final step visible in the pipeline progression. The recording itself remains best-effort (do not fail the pipeline on recording errors — log a warning and continue) but the **decision to record** is now unconditional.

---

## Stage 0 -- PRE-FLIGHT

Run these checks. Abort with a clear message if any fail.

```bash
git status --porcelain # empty = nothing to ship
git branch --show-current # detect master vs feature branch
gh auth status # verify gh is authenticated
```

- If `git status --porcelain` is empty, print "Nothing to ship." and stop (still record this as an aborted run — see Run Data Recording).
- Store the current branch name for later decisions.
- Capture `run_start_time` as the current ISO-8601 timestamp. Initialize an in-memory run record to accumulate metrics throughout the pipeline.

## Stage 0.5 -- PLAN-REFRESH GATE (forge-harness only)

**Applies only when `.forge/` directory exists in the repo root.** Non-forge repos skip this stage entirely. This gate ensures every PR in a forge-harness-style repo carries a plan-refresh signal indicating whether `forge_plan(documentTier: "update")` has been invoked against the current state. Enforced by Q0/L1 of the post-v0.20.1 execution plan (`.ai-workspace/plans/2026-04-12-next-execution-plan.md`).

1. **Applicability check:** `test -d.forge` — if absent, record `planRefreshGate: "skipped-no-forge"` in the run record and skip to Stage 1.

2. **Marker read (server-side, NEVER working tree — immune to shallow clones and `git clean`):**
 ```bash
 MSYS_NO_PATHCONV=1 git show origin/master:.forge/.plan-refresh-initialized 2>/dev/null
 MARKER_EXIT=$?
 ```
 The `MSYS_NO_PATHCONV=1` prefix is required on Windows Git Bash (MSYS2), which otherwise mangles the `ref:path` colon into a semicolon and breaks the command. The env var has no effect on Linux/Mac..
 - `MARKER_EXIT != 0` → marker absent on master → **bootstrap/empty-history case** → set `PLAN_REFRESH_LINE="plan-refresh: baseline"` and proceed. Record `planRefreshMarkerPresent: false`.
 - `MARKER_EXIT == 0` → marker present on master → require an explicit non-`baseline` line (see step 3). Emit `baseline` is **forbidden** in this branch. Record `planRefreshMarkerPresent: true`.

3. **Line value determination when marker is present:**
 - If `$ARGUMENTS` contains a literal `plan-refresh:` token (e.g., `/ship plan-refresh: 3 items`), extract and use that line verbatim.
 - Otherwise, check the current session for a recent `forge_plan(documentTier: "update")` invocation in the current working session — if present, derive the line from its outcome (`no-op` if the update produced zero rewrites, `<N> items` if it rewrote N items, `error: <reason>` if it errored).
 - If neither source is available, **abort** with: `"Plan-refresh gate: no signal available. The marker.forge/.plan-refresh-initialized is present on origin/master, meaning forge_plan(update) has run at least once. Run forge_plan(documentTier: 'update') again in this session, or pass the line explicitly via '/ship plan-refresh: <form>'. Valid forms: no-op, <N> items, error: <reason>."`

4. **Accepted line forms (exact literal match enforced in Stage 6):**
 - `plan-refresh: no-op`
 - `plan-refresh: <N> items` (where `<N>` is an integer ≥ 1)
 - `plan-refresh: baseline` (only when marker is absent on master)
 - `plan-refresh: error: <reason>` (requires `plan-refresh-override: <reason>`)
 - `plan-refresh: error: halted-blocking-note:<noteId>` (added by Q0/L2 A1.2 amendment 2026-04-12; also requires override)

5. **Error-form override handling:** if `PLAN_REFRESH_LINE` starts with `plan-refresh: error:`, the gate requires a matching `plan-refresh-override: <reason>` line in either `$ARGUMENTS` or the PR body. If `$ARGUMENTS` contains a literal `plan-refresh-override:` token, extract and set `PLAN_REFRESH_OVERRIDE_LINE` accordingly. If neither `$ARGUMENTS` nor any existing PR body contains the override line, **abort** with: `"Plan-refresh errored (<reason>). Merge is blocked by default. To proceed, supply 'plan-refresh-override: <reason>' via '/ship' arguments or add it to the PR body."`

6. **Validation:** the computed `PLAN_REFRESH_LINE` must match the regex `^plan-refresh: (no-op|[1-9][0-9]* items|baseline|error:.+)$` — if not, abort with: `"Plan-refresh line malformed: '<value>'. Expected one of: 'plan-refresh: no-op', 'plan-refresh: <N> items' (N ≥ 1), 'plan-refresh: baseline', 'plan-refresh: error: <reason>'."` Note: `0 items` is deliberately rejected — use `no-op` for the zero case. (n=2 graduation).

7. **Store** `PLAN_REFRESH_LINE` (and `PLAN_REFRESH_OVERRIDE_LINE` if applicable) for use in Stage 3 (body composition) and Stage 6 (pre-merge re-verification).

8. **Record** in the run record:
 - `planRefreshGate: "passed"` (or `"skipped-no-forge"` per step 1, or `"aborted-no-signal"` / `"aborted-missing-override"` / `"aborted-malformed"` on the respective abort paths)
 - `planRefreshLine: "<value>"`
 - `planRefreshMarkerPresent: true|false`
 - `planRefreshOverride: "<value or null>"`

## Stage 1 -- BRANCH

**On master/main:** Analyze the diff to derive a branch name with a conventional prefix:
- `feat/` for new features
- `fix/` for bug fixes
- `chore/` for maintenance, config, docs

Create the branch: `git checkout -b {prefix}/{slug}`

**On feature branch:** Skip. Log "Already on branch {name}".

## Stage 2 -- COMMIT

1. Stage relevant files with `git add` (list specific files, never use `-A` or `.`)
2. Craft a conventional commit message from the diff. If `$ARGUMENTS` is provided, use it as a hint.
3. Commit using a HEREDOC for the message, including `Co-Authored-By` trailer.

## Stage 3 -- PUSH + PR

1. `git push -u origin {branch}`
2. Check if a PR already exists:
 ```bash
 gh pr view --json number,url,body 2>/dev/null
 ```
 - **Exists:** Log the URL. **Plan-refresh gate check (added by Q0/L1):** if Stage 0.5 ran (forge-harness repo) and `PLAN_REFRESH_LINE` is set, verify the existing body contains a line matching `^plan-refresh: (no-op|[1-9][0-9]* items|baseline|error:.+)$`. If absent, append `PLAN_REFRESH_LINE` (and `PLAN_REFRESH_OVERRIDE_LINE` if set) to the body. Compose the new body with real newlines via `printf` (bash double-quoted `\n` is literal backslash-n and produces a broken body —):
 ```bash
 if [ -n "$PLAN_REFRESH_OVERRIDE_LINE" ]; then
 NEW_BODY=$(printf '%s\n\n---\n%s\n%s' "$EXISTING_BODY" "$PLAN_REFRESH_LINE" "$PLAN_REFRESH_OVERRIDE_LINE")
 else
 NEW_BODY=$(printf '%s\n\n---\n%s' "$EXISTING_BODY" "$PLAN_REFRESH_LINE")
 fi
 gh pr edit {pr-number} --body "$NEW_BODY"
 ```
 Record `planRefreshLineInjected: true`. If the line is already present, skip the edit and record `planRefreshLineInjected: false`.
 - **Does not exist:** Create via `gh pr create --title "..." --body "..."` with a summary and test plan. **Plan-refresh gate check (added by Q0/L1):** if Stage 0.5 ran, the PR body MUST include `PLAN_REFRESH_LINE` as a trailer line (after the summary and test plan), separated from the rest of the body by a `---` horizontal rule. If `PLAN_REFRESH_OVERRIDE_LINE` is set, include it on the line immediately after `PLAN_REFRESH_LINE`. Body template:
 ```
 ## Summary...

 ## Test plan...

 ---
 {PLAN_REFRESH_LINE}
 [{PLAN_REFRESH_OVERRIDE_LINE if set}]
 ```
 Record `planRefreshLineEmbedded: true` in the run record.
3. Store the PR number for subsequent stages.

## Stage 4 -- CI WAIT

Poll CI checks every 30 seconds, up to 10 minutes:

```bash
gh pr checks {pr-number}
```

- **All pass:** Record `ciOutcome: "pass"`. Proceed to Stage 5.
- **Any fail:**
 1. Parse failing check names from `gh pr checks` output.
 2. **If any failing check name contains `code-review`** (case-insensitive) AND this is the **first** retry attempt:
 a. Print: `"Code-review CI failed — checking OAuth token freshness..."`
 b. Read `$USERPROFILE/.claude/.credentials.json`, extract `claudeAiOauth.expiresAt` (unix ms).
 c. If token is **expired or expiring within 30 minutes**:
 - Look for the OAuth token sync script at `~/.claude/skills/housekeep/tools/sync-oauth-token.sh` (resolved via the housekeep skill symlink, not the current repo). If the script exists, run it. If not found, skip sync and abort as normal.
 - If sync succeeds: re-trigger with `gh run rerun --failed -R {owner/repo}` on the failing run, record `ciOauthSynced: true` and `ciRetried: true`, reset CI poll timer, **resume polling** (fresh 10-min timeout).
 - If sync fails: report the sync error and abort.
 d. If token is **fresh** (>30 min remaining): not a token issue — abort as normal.
 3. **Otherwise** (non-code-review failure, or second attempt after retry): Record `ciOutcome: "fail"`. Report failing check names and log URLs. **Abort** — do not auto-fix CI config issues.
- **No checks configured** (empty output): Record `ciOutcome: "none"`. Skip, proceed to Stage 5.
- **Timeout (10 min):** Record `ciOutcome: "timeout"`. Report current status and ask the user whether to continue or abort.

Record `ciWaitSeconds` as the elapsed time from the first poll to resolution.

## Stage 5 -- SELF-REVIEW LOOP

**Telemetry signal (2026-05-06 harvest of 59 lifetime runs):** outcomes are 28 success / 1 aborted in window — Stage 5 self-review is a load-bearing safety net, NOT a formality. Stale bug categories caught by self-review across runs include:
- `stale-coupling-warnings` — `detectCouplings` produced warnings against state that no longer matched the current diff.
- `stage-name-mismatch` — `buildStageList` used a stage name not present in the run record's stages map (drift between SKILL.md stage names and code).
- `dangling-symlink-regression` — backup-restore worktree paths produced symlinks whose targets had been removed.

Reviewers should watch for these specific patterns explicitly when running on diffs that touch (a) coupling-detection logic, (b) stage-name strings or stage-list builders, (c) worktree backup/restore paths.

**Release-PR short-circuit (runs first).** If this `/ship` invocation is operating on a release PR, skip the reviewer loop entirely. Detection: the PR title matches `^chore: release [0-9]` OR the PR body contains a `release-pr: true` trailer. Both signals are written by Stage 7 when it opens the release PR. On a match, log `releaseSelfReview: skipped: release-pr-detected`, write the standard PASS verification marker (`echo "{ISO-8601 timestamp}" >.ai-workspace/ship-verified-{pr-number}` — this is the *release PR's own number* returned by `gh pr create`, not the feature PR's; Stage 5's marker-write logic already keys on the active PR), record `cardEmission`/`reviewIterations` as 0, and proceed directly to Stage 6. Rationale: release PRs are mechanical version bumps; the feature PR's Stage 5 already vetted the substantive diff.

Iterate up to **5 times**. Each iteration:

### 5a. Spawn Stateless Reviewer

Launch a fresh Agent subagent using the full prompt in `references/reviewer-prompt.md` (relative to this skill's base directory, NOT the current working directory). The reviewer must have NO context about the implementation -- fresh eyes only.

### 5b. Process the Review

Read `tmp/ship-review-{N}.md` and act on the verdict:

**PASS (no bugs):**
- Write verification marker: `echo "{ISO-8601 timestamp}" >.ai-workspace/ship-verified-{pr-number}` (in the project's `.ai-workspace/` dir). This marker allows the enforce-ship hook to permit the merge in Stage 6.
- For each enhancement found, auto-create a GitHub issue:
 ```bash
 gh issue create --title "{summary}" --body "{description}" --label "enhancement" --label "ship-review"
 ```
- Log created issue URLs. Record `enhancementsCreated` (count of issues created). Proceed to Stage 6.

**BLOCK (bugs found):**
1. For each bug found, append to the run record's `issues` array: `{ "stage": "selfReview", "type": "{bug_type}", "description": "{bug_summary}", "iteration": {N} }`.
2. Increment `bugsFound` counter. Add each bug's type to `bugCategories` (deduplicated).
3. Create a micro-plan at `.ai-workspace/plans/{date}-ship-fix-{N}.md` (satisfies the enforce-plan hook).
4. Fix all reported bugs.
5. `git add` the fixed files. Create a **new commit** (not amend). `git push`.
6. Re-poll CI checks (Stage 4 mini-loop).
7. Increment iteration counter (`reviewIterations`).
 - If counter >= 5: print remaining bugs and escalate to user. **Do NOT merge.**
 - Otherwise: re-enter Stage 5 (next iteration).

## Stage 5.5 -- CAIRN INDEX-CHECK GATE (Phase B, client-side only)

> **ai-brain-only — no-op when the checker is absent.** This stage relies on the repo-level helper `cairn/bin/phase-b-checks.mjs`, which ships in the ai-brain workspace, not in this plugin. The invocation below is existence-guarded: when the helper is missing (the common case for a plugin installer), the gate logs a skip note and proceeds. Keep the guidance for workspaces that DO have the checker.

**This is a Tier-2 client-side gate, not a hard branch-protection required check.** UI merges and admin overrides bypass it by design; the monthly audit (M7) is the retroactive signal. Do not describe this as a merge-required check anywhere.

Applies to any PR whose diff touches:
- `hive-mind-persist/knowledge-base/**/*.md`
- `hive-mind-persist/memory.md`
- `hive-mind-persist/session-notes/**/*.md`

Steps:

1. **Gated-path detection:**
 ```bash
 CHANGED=$(gh pr view {pr-number} --json files -q '.files[].path')
 GATED=0
 for f in $CHANGED; do
 case "$f" in
 hive-mind-persist/knowledge-base/*.md|hive-mind-persist/memory.md|hive-mind-persist/session-notes/*.md)
 GATED=1; break;;
 esac
 done
 ```
 If `GATED=0`, print `[SHIP] index-check gate: no gated paths — skipping` and proceed. No prompt.

2. **Re-fetch PR body** (catch manual UI edits since Stage 3):
 ```bash
 gh pr view {pr-number} --json body -q.body >.ai-workspace/ship-pr-body-{pr-number}.txt
 ```
 Do NOT write the body back to the remote after reading — the gate is read-only.

3. **Validate via the cairn Phase B checker (existence-guarded — skip if the helper is absent):**
 ```bash
 if [ -f cairn/bin/phase-b-checks.mjs ]; then
 node cairn/bin/phase-b-checks.mjs ship-gate \
 --pr-body-file .ai-workspace/ship-pr-body-{pr-number}.txt --gated
 else
 echo "[SHIP] index-check gate: cairn/bin/phase-b-checks.mjs not found — ai-brain-only helper absent, skipping" >&2
 fi
 ```
 If the helper is absent, this gate is a no-op (record `cairnIndexCheckGate: "skipped-no-helper"`). When present, the checker strips CRLF, rejects blockquoted `> index-check:` lines, and accepts exactly one of:
 - `index-check: P<N>[, F<M>,...]` (IDs, comma separated, optional spaces)
 - `index-check: none`
 - `index-check: skip -- <non-empty reason>` (ASCII `--`, not em-dash)

4. **On non-zero exit:** abort with:
 ```
 Merge blocked: PR body missing a valid index-check: trailer. See ${CLAUDE_PLUGIN_ROOT}/3-role-model.md
 "Cairn Index-Check Trailer" section. Valid forms:
 index-check: P46, F36
 index-check: none
 index-check: skip -- <reason>
 ```

5. Record `cairnIndexCheckGate: "passed"|"skipped-no-gated"|"aborted-invalid"` in the run record.

## Stage 6 -- MERGE

**Pre-merge plan-refresh re-verification (added by Q0/L1) — applies only when Stage 0.5 ran (forge-harness repo):**

1. Re-fetch the live PR body to catch any manual edits that happened between Stage 3 and Stage 6:
 ```bash
 BODY=$(gh pr view {pr-number} --json body -q.body)
 ```
2. **Assert a valid plan-refresh line is present:**
 ```bash
 echo "$BODY" | grep -qE '^plan-refresh: (no-op|[1-9][0-9]* items|baseline|error:.+)$'
 ```
 If the grep returns non-zero, **abort** with: `"Merge blocked: PR body missing valid plan-refresh line. Expected one of: 'plan-refresh: no-op', 'plan-refresh: <N> items', 'plan-refresh: baseline', or 'plan-refresh: error: <reason>'. Re-run /ship or add the line manually via 'gh pr edit {pr-number} --body'."`
3. **Error-form override enforcement:** if the plan-refresh line starts with `plan-refresh: error:`, additionally assert the override line is present:
 ```bash
 echo "$BODY" | grep -qE '^plan-refresh-override:.+$'
 ```
 If the grep returns non-zero, **abort** with: `"Merge blocked: plan-refresh reported an error ('<reason>') and merge is blocked by default. To proceed, add 'plan-refresh-override: <reason>' to the PR body via 'gh pr edit {pr-number} --body'."`
4. **Baseline sanity check:** if the plan-refresh line is `plan-refresh: baseline`, re-verify the marker is still absent on master via `MSYS_NO_PATHCONV=1 git show origin/master:.forge/.plan-refresh-initialized 2>/dev/null` (the `MSYS_NO_PATHCONV=1` prefix is required on Windows Git Bash —). If the command now exits zero (marker was committed between Stage 0.5 and Stage 6 by a concurrent merge), **abort** with: `"Merge blocked: plan-refresh line is 'baseline' but the.forge/.plan-refresh-initialized marker is now present on origin/master. Re-run /ship to recompute the plan-refresh signal against the current master state."`
5. Record `planRefreshMergeGate: "passed"` in the run record.

**BEHIND-PR sync (default path — server-side, force-push-free, added).**

Concurrent same-repo ships make it common for the feature PR to fall BEHIND `master` between push and merge (a sibling PR merged first). Sync it **server-side** so the merge can proceed. Do NOT use a local rebase + `git push --force-with-lease` on this default path: in a subagent/worker context the auto-mode safety classifier BLOCKS a force-push that was not in the original `/ship` authorization, and the ship STALLS (prior force-push STALL incidents). `gh pr update-branch` is a GitHub server-side operation (no local rebase, no force-push), so the classifier never fires.

1. **Detect staleness** right before the merge:
 ```bash
 MSS=$(gh pr view {pr-number} --json mergeStateStatus -q.mergeStateStatus)
 ```
 - `BEHIND` → the branch is out of date with base; sync it (step 2).
 - `BLOCKED` / `UNKNOWN` → GitHub has not finished computing mergeability (common right after a push). Poll `gh pr view {pr-number} --json mergeStateStatus -q.mergeStateStatus` every ~5s for up to ~60s until it settles to `BEHIND`, `CLEAN`, or `DIRTY`, then branch on the settled value.
 - `CLEAN` / `HAS_HOOKS` / `UNSTABLE` → up to date (or only CI pending); skip the sync, go to Merge.
 - `DIRTY` → real merge conflict; report the conflicting files and **abort** (do not auto-resolve).
2. **If BEHIND → sync server-side (NO force-push):**
 ```bash
 gh pr update-branch {pr-number}
 ```
 This merges the latest base into the PR branch **on GitHub's servers** — no local rebase, no `git push --force-with-lease`, so the classifier never fires. Then **re-poll CI** until green, because the branch update re-triggers checks (Stage 4 mini-loop on `gh pr checks {pr-number}`), and **re-check** `mergeStateStatus` is no longer `BEHIND`:
 ```bash
 # wait for the update-branch push's CI, then confirm no longer behind
 gh pr checks {pr-number} --watch # or the Stage 4 poll loop if --watch is unavailable
 MSS=$(gh pr view {pr-number} --json mergeStateStatus -q.mergeStateStatus)
 ```
 If it is still `BEHIND` (another sibling merged in the meantime), repeat step 2.
3. **Why this stays clean:** `gh pr update-branch` adds a merge commit to the PR branch, but Stage 6 **squash-merges** — GitHub collapses the whole PR (including that merge commit) into a single commit on `master`, so the final master history stays linear and clean. The update-branch merge commit is never visible on master.
4. **Fallback (narrow — linear/rebase-history repos ONLY):** a repo whose branch protection requires **linear history** (rebase-merge; a merge commit is unacceptable) cannot absorb the merge commit `update-branch` creates. ONLY for such a repo, sync via a local rebase + `git push --force-with-lease origin {branch}` instead. **This fallback path is the exception, not the default.** In a subagent/worker context the force-push needs **explicit per-step authorization** (the safety classifier WILL block it otherwise) — so pause and request it before running the force-push. For the common case (this repo and any squash-merge repo) the DEFAULT is `gh pr update-branch` and no authorization stall occurs.

**Merge:**

```bash
gh pr merge {pr-number} --squash --delete-branch
```

If merge fails due to conflicts, report the conflicting files and **abort**. Do not auto-resolve.

## Stage 7 -- RELEASE

> **ai-brain-only release mechanics — no-op when the prerequisites are absent.** This stage encodes the ai-brain workspace's release conventions (semver bump in `package.json`, `CHANGELOG.md` prepend, git tag, GitHub Release, and the `hooks/release-version-collision-guard.sh` backstop). The whole stage is already existence-guarded by step 1: when there is **no `package.json` at the repo root** (the common case for a workspace that does not follow these conventions), the stage logs "No package.json -- skipping release" and proceeds straight to Stage 8 — so the release mechanics degrade to a clean no-op. The guidance below is kept verbatim for workspaces that DO release this way.

Version bump + changelog land on master via a **squash-merged release PR**, not a direct push. The release worktree mirrors Rule 12 worktree discipline used elsewhere in the pipeline. Tagging happens **after** the release PR merges so the tag points at the squash-merge commit on master.

**Concurrent-ship safety.** Two same-repo ships running at the same time (different feature worktrees) only ever contend on `master`'s shared release state: the `package.json` version, the git tag, and the *top* of `CHANGELOG.md` (both prepend there). Staggered releases already self-serialize because step 2 computes the next version from the *latest published tag*. Three residual hazards remain under TRUE concurrency, and Stage 7 closes all three: (a) two release worktrees forked off the same base both prepend to `CHANGELOG.md`, so the second release PR merge conflicts at the changelog top — closed by the **rebase-before-merge** sub-step (13a) below; (b) the *content* of a release PR's CHANGELOG, snapshotted at fork time, MISSES a sibling PR that merged in between (a stale-changelog miss — a release PR carried a changelog missing the builder-demo entry → had to close + re-cut) — closed by the **regenerate-changelog-from-the-real-merged-range + completeness-assertion** sub-step (13b) below; (c) a seconds-wide race where two releases compute and push the **same** tag — closed by the **recompute-before-tag + retry** sub-step (14a) below, and mechanically backstopped by `hooks/release-version-collision-guard.sh` (a PreToolUse Bash gate that blocks a `git tag` / `git push` / `gh release create` of a `vX.Y.Z` that already exists on origin **at a different commit** — the gate AUTO-EXEMPTS a tag that points at this ship's own release commit, so an idempotent re-tag/re-push of your own release is never false-blocked and the blanket `RELEASE_COLLISION_GUARD_OFF=1` workaround is no longer needed). Because Stage 7 recomputes the version right before tagging, that guard should **never** trip on a correct run; if it does, the run genuinely picked a stale version and must re-fetch + bump.

1. **Check if repo is releasable:** Look for `package.json` at the repo root.
 - If not found: log "No package.json -- skipping release." Proceed to Stage 8.

 <!-- BLOCK-4-N4-STASH-CHECK-START -->
 **Pre-release stash check (Block 4 N4).** Stashes are per-clone in `.git/refs/stash`, so this check runs on the primary clone *before* step 6 forks off a fresh release worktree. Soft warning, not a gate.

 ```bash
 # Test mode: SHIP_STAGE7_TEST=1 suppresses real release operations so the
 # acceptance harness can exercise this block in isolation.
 STAGE7_STASH_HITS="$(git stash list 2>/dev/null \
 | grep -E '(pre-v[0-9]|drain-stage|v[0-9]+\.[0-9]+|q[0-9]+(-[A-Za-z0-9_-]+)?-)' \
 || true)"
 if [ -n "$STAGE7_STASH_HITS" ]; then
 echo "[ship] Stage 7 found release-relevant stash:"
 printf '%s\n' "$STAGE7_STASH_HITS"
 echo "[ship] Soft warning — review or drop these stashes before continuing."
 # Default action: continue. Operator may abort manually.
 if [ "${SHIP_STAGE7_TEST:-0}" != "1" ]; then
 echo "[ship] Continuing in 5s (Ctrl+C to abort)..."
 sleep 5
 fi
 fi
 ```

 Regex anchors:
 - `pre-v[0-9]` — pre-version-bump scratch (e.g. `pre-v0.34.3-executor`)
 - `drain-stage` — drain-stage release scratch
 - `v[0-9]+\.[0-9]+` — explicit version-marker stashes
 - `q[0-9]+(-...)?-` — quarter/sprint scratch (e.g. `q05-q1-gitignore-pre-existing-noise`)

 The check is a soft warning. Default behavior continues the pipeline (no abort). The `SHIP_STAGE7_TEST=1` env var lets `tests/ship/stage-7-stash-check-acceptance.sh` exercise this block without invoking the rest of Stage 7.
 <!-- BLOCK-4-N4-STASH-CHECK-END -->

2. **Get last tag (read-only on master):**
 ```bash
 git fetch origin master --tags
 git describe --tags --abbrev=0 origin/master 2>/dev/null
 ```
 - If no tags exist: use `0.0.0` as baseline, default bump = minor (→ `0.1.0`).

3. **Collect commits since last tag:**
 ```bash
 git log {last_tag}..origin/master --format="%s"
 ```

4. **Determine version bump** from conventional commit prefixes:
 - Any commit with `!` suffix (e.g., `feat!:`) or `BREAKING CHANGE` in body → **major**
 - Any `feat` or `feat(scope)` prefix → **minor**
 - Only `fix`, `chore`, `docs`, `refactor`, `test`, `style`, `perf`, `ci`, `build` → **patch**
 - No conventional commits found → **patch** (default)

5. **Compute new version:** Increment the appropriate semver component of the last tag.

6. **Create a fresh release worktree from `origin/master`:**
 ```bash
 git worktree add.claude/worktrees/release-{version} -b chore/release-{version} origin/master
 cd.claude/worktrees/release-{version}
 ```
 This is the same Rule 12 pattern used everywhere else in the pipeline. Editing happens here, not in the primary clone.

7. **Inside the release worktree, bump `package.json`** to `"version": "{new_version}"` via a targeted edit. Do not touch other fields.

8. **Inside the release worktree, generate CHANGELOG entry:**
 - Group commits by type: `### Features` (feat), `### Bug Fixes` (fix), `### Miscellaneous` (everything else)
 - Format: `## [{version}](https://github.com/{owner/repo}/compare/{last_tag}...v{version}) ({date})`
 - Prepend to `CHANGELOG.md` (create the file if missing).

9. **Sanity-check the diff before committing.** Run:
 ```bash
 git status --porcelain
 git diff --shortstat
 ```
 Only `package.json` and `CHANGELOG.md` should appear. If any other file shows up (notably a phantom whole-file reformat from CRLF/LF mismatch on Windows), halt with a clear error pointing at the line-ending mismatch — do **not** commit.

10. **Commit (no tag yet):**
 ```bash
 git add package.json CHANGELOG.md
 git commit -m "chore: release {version}"
 ```
 Do not tag and do not attempt to publish to master from the worktree at this point.

11. **Push the release branch:**
 ```bash
 git push -u origin chore/release-{version}
 ```

12. **Open the release PR.** The body's first line MUST contain a recognizable release-PR marker (`release-pr: true` trailer) so Stage 5 can short-circuit when this PR is the next one inspected:
 ```bash
 gh pr create --title "chore: release {version}" --body "$(printf '%s\n\n%s\n' 'release-pr: true' "$CHANGELOG_ENTRY")"
 ```
 Capture the returned PR number/URL into `RELEASE_PR_URL` and `RELEASE_PR_NUMBER` for Stage 9.

13a. **(Concurrent-ship safety) Bring the release branch up to date with the latest `origin/master` before merging.** Between when this release worktree was forked off `origin/master` (step 6) and now, a *different* concurrent release may have merged — and it prepended its own entry to the top of `CHANGELOG.md`. If we merge our branch as-is, the two changelog prepends collide at the same top-of-file region and the release PR merge conflicts. Bring our changelog prepend up to date with whatever merged in between, so it lands cleanly.

 **Default path — server-side, force-push-free.** Mirror the Stage 6 BEHIND-PR sync: if the release PR is `BEHIND`, prefer `gh pr update-branch` over a local rebase + `git push --force-with-lease`. The release PR squash-merges too, so the extra merge commit `update-branch` creates is collapsed on master. In a subagent/worker context this avoids the safety-classifier force-push STALL (the same hazard as the feature PR):
 ```bash
 MSS=$(gh pr view {release-pr-number} --json mergeStateStatus -q.mergeStateStatus)
 if [ "$MSS" = "BEHIND" ]; then
 gh pr update-branch {release-pr-number} # server-side merge of master into the release branch
 git fetch origin "chore/release-{version}" # pull the update-branch commit into the worktree for 13b
 fi
 ```
 After this, step 13b STILL runs (its changelog-recompute + completeness assertion is unchanged and stays AFTER the sync) — it regenerates the CHANGELOG entry from the now-up-to-date merged range.

 **Fallback (narrow — linear/rebase-history repos ONLY).** A repo whose release PR must keep **linear history** (rebase-merge; a merge commit is unacceptable) cannot absorb the merge commit `update-branch` creates. ONLY for such a repo, sync via a local rebase from inside the release worktree (`.claude/worktrees/release-{version}`):
 ```bash
 cd.claude/worktrees/release-{version}
 git fetch origin master --tags
 # Rebase our release commit on top of the now-latest master. Our diff is only
 # package.json + the CHANGELOG top-prepend, so the only possible conflict is the
 # CHANGELOG top — and a prepend-on-top resolution is always "keep both, ours above
 # the intervening release". If a clean rebase fails, fall back to merging master in:
 git rebase origin/master || {
 git rebase --abort
 git merge --no-edit origin/master # resolve any CHANGELOG-top conflict: keep both entries
 }
 git push --force-with-lease origin chore/release-{version}
 ```
 `--force-with-lease` (never bare `--force`) updates the already-pushed branch only if no one else moved it. **This force-push fallback needs explicit per-step authorization in a subagent/worker context (the safety classifier will block it otherwise) — it is the exception, not the default.** If a concurrent release ALSO bumped `package.json` to the *same* version (the seconds-wide race), the recompute-before-tag step (14a) is the authoritative guard — the sync here only guarantees the CHANGELOG prepend is conflict-free.

13b. **(Concurrent-ship safety) RECOMPUTE the CHANGELOG entry from the ACTUAL merged range AFTER the 13a sync — then assert completeness.** The 13a sync guarantees the prepend *lands* cleanly, but the entry's CONTENT was snapshotted back at step 8 from the commit range *at fork time*. If a **sibling release PR merged between fork and now**, the synced master contains that sibling's commits but our snapshotted CHANGELOG body does NOT mention them — exactly the stale-changelog failure (a stale release PR carried a CHANGELOG missing the builder-demo entry, forcing a close + re-cut). So after the 13a sync, REGENERATE the entry from the real merged range and OVERWRITE the snapshotted one, then **assert every PR/commit in the range is referenced** — fail loud if one is missing. Run this from inside the release worktree, immediately after 13a finishes.

 **Note on the re-push below:** the regenerate ends in `git commit --amend`, which rewrites the release commit — so re-publishing it REQUIRES `git push --force-with-lease` (this is an *amend* re-push of our OWN release branch, NOT a rebase sync, and `gh pr update-branch` cannot replace it because update-branch does not rewrite commit content). In a subagent/worker context this amend re-push needs **explicit per-step authorization** (the safety classifier will block a force-push that was not in the original `/ship` authorization) — request it before running the push. It only ever fires when 13b actually had to regenerate (a sibling merged in between); when the changelog was already complete there is nothing to amend and no force-push happens.
 ```bash
 cd.claude/worktrees/release-{version}
 git fetch origin master --tags
 # The TRUE merged range for this release: from the latest published tag to the rebased HEAD.
 LAST_TAG=$(git describe --tags --abbrev=0 origin/master 2>/dev/null || echo "")
 RANGE="${LAST_TAG:+$LAST_TAG..}HEAD" # "vX.Y.Z..HEAD", or just "HEAD" if no prior tag
 # Re-derive the entry body from the ACTUAL commits now in the range (same grouping as step 8:
 # ### Features / ### Bug Fixes / ### Miscellaneous), capturing each squash-merge's PR number
 # (the "(#NN)" suffix conventional squash-merges carry). This REPLACES the step-8 snapshot —
 # do not append; rebuild the entry, then re-prepend it as the new top block of CHANGELOG.md.
 MERGED_SUBJECTS=$(git log --no-merges --format='%s' "$RANGE")
 #... rebuild CHANGELOG_ENTRY from MERGED_SUBJECTS, regroup, re-prepend, commit --amend...

 # COMPLETENESS ASSERTION: every PR number AND every non-merge commit subject in the real
 # merged range MUST be referenced in the regenerated CHANGELOG entry. If any is missing, the
 # snapshot was stale and the regenerate dropped a sibling -> HALT (do not ship a release whose
 # changelog under-reports what shipped). This is the load-bearing fail-loud guard.
 MISSING=""
 # (a) PR-number coverage: each "(#NN)" that appears in a merged subject must appear in the entry.
 for pr in $(printf '%s\n' "$MERGED_SUBJECTS" | grep -oE '\(#[0-9]+\)' | tr -d '#' | sort -u); do
 grep -q "#${pr}" CHANGELOG.md || MISSING="${MISSING} PR#${pr}"
 done
 # (b) commit-subject coverage (catches direct-to-master commits with no PR number): each merged
 # non-merge subject's leading text must surface in the entry.
 while IFS= read -r subj; do
 [ -z "$subj" ] && continue
 key=$(printf '%s' "$subj" | sed -E 's/ \(#[0-9]+\)$//')
 grep -qF "$key" CHANGELOG.md || MISSING="${MISSING} \"${subj}\""
 done <<< "$MERGED_SUBJECTS"
 if [ -n "$MISSING" ]; then
 echo "[ship] FATAL (Stage 7 /): regenerated CHANGELOG for {version} is MISSING merged items:${MISSING}" >&2
 echo "[ship] The release entry must reference every PR/commit in ${RANGE}. Re-run the regenerate; do not merge an incomplete release." >&2
 exit 1
 fi
 git add CHANGELOG.md && git commit -q --amend --no-edit
 git push --force-with-lease origin chore/release-{version}
 ```
 Why AFTER the 13a sync, not at step 8: only post-sync does the worktree contain the sibling release's commits, so only here can the regenerate SEE them. The assertion is what makes this load-bearing — a silently-incomplete changelog (the symptom) becomes a hard `exit 1` rather than a stale PR that ships and must be re-cut. (`SHIP_STAGE7_TEST=1` may stub the network/`gh` calls for `tests/ship` acceptance.)

13. **Merge the release PR.** Use auto-merge so GitHub waits for CI; the operator does not poll:
 ```bash
 gh pr merge {release-pr-number} --squash --auto --delete-branch
 ```
 If `--auto` is unsupported on the local `gh` version, fall back to the Stage 4 CI-wait pattern: poll `gh pr checks` every 30s for up to 10 minutes, then `gh pr merge {release-pr-number} --squash --delete-branch`. If branch protection requires a different merge mode (rebase or merge), adapt accordingly. If the release PR's CI fails, log the failure clearly and stop — leave the open PR for manual recovery; do not spawn a fixer (Stage 5 was already skipped for release PRs).

14a. **(Concurrent-ship safety) Recompute the version against the now-latest tags RIGHT before tagging, and retry-bump on collision.** The version `{version}` was computed back at step 2/5 from the latest tag *at that time*. Between then and now, a concurrent release may have grabbed that exact `vX.Y.Z`. Re-fetch tags and verify our intended tag is still free; if a concurrent ship took it, bump the same semver component until we find the next free `vX.Y.Z`, and re-stamp `package.json` + the CHANGELOG heading to the new number before tagging. This is the seconds-wide-race guard: it makes a duplicate tag impossible to push rather than failing late on a rejected push. Illustrative shape (re-resolve `{version}` from the latest tag, then bump-while-taken — substitute the real version each iteration, do not push the literal `{version}` placeholder):
 ```bash
 git fetch origin master --tags
 # Re-resolve from the latest published tag and re-apply the SAME bump kind ({bump}).
 # Then bump again while the candidate already exists as a remote tag (re-evaluate the
 # ls-remote condition against the UPDATED $version each iteration, not the literal {version}).
 while git ls-remote --tags origin "refs/tags/v${version}" | grep -q "refs/tags/v${version}"; do
 echo "[ship] v{version} already exists on origin (concurrent release grabbed it) -- bumping to next free version"
 # increment the same semver component used for this release ({bump}: major|minor|patch)
 version="$(next_free_semver "{version}" "{bump}")" # bump major/minor/patch by one, re-check
 done
 ```
 If the version changed here (a collision was hit), the release PR has already merged with the *old* number in `package.json` + `CHANGELOG.md` — that is acceptable: the published tag is the source of truth for "which version this is", and the next release will compute from it. Prefer to have caught the collision BEFORE merge via the rebase in 13a; this step is the final backstop. Rationale: under true concurrency two releases can compute the same next-version off the same base; recompute-immediately-before-tag + retry guarantees a unique tag. The `hooks/release-version-collision-guard.sh` PreToolUse gate enforces this mechanically — if it blocks the tag/push below, this recompute loop was skipped or raced and must be re-run.

14. **After the release PR merges, tag the squash-merge commit.** Fetch master, confirm HEAD is the squash-merge commit, then tag and push the single tag:
 ```bash
 cd "$PRIMARY_CLONE_OR_RELEASE_WORKTREE"
 git fetch origin master --tags
 MERGE_SHA=$(gh pr view {release-pr-number} --json mergeCommit -q.mergeCommit.oid)
 git tag v{version} "$MERGE_SHA"
 git push origin v{version}
 ```
 If pushing the single tag is rejected (e.g., tag protection on the remote), log `release tag rejected by remote -- stopping; manual tag push needed before GitHub Release can be created` and stop. Do not attempt to bypass the rejection. If the rejection is specifically a *duplicate-tag* error (a concurrent release won the race after step 14a), re-run step 14a (re-fetch tags + bump to the next free version) before retrying the tag push.

15. **Create the GitHub Release:**
 ```bash
 gh release create v{version} --title "v{version}" --notes "{changelog_entry}"
 ```

16. Log: `[SHIP] Released v{version} via PR #{release-pr-number} -- tag, changelog, and GitHub Release created.`
17. Record release fields in the run record. See Stage 9's schema for the field list (`releaseVersion`, `releaseBump`, `releaseViaPR`, `releasePrUrl`). When this stage skips because no `package.json` is present, record `releaseVersion: null`, `releaseBump: "skipped"`, `releaseViaPR: false`, `releasePrUrl: null`.

**Important:** This stage is non-fatal. The feature PR is already merged. Any failure here should log a warning and continue to Stage 8, never abort. Stage 8 will quarantine the release worktree regardless of whether step 14/15 succeeded.

## Stage 8 -- CLEANUP

Cleanup is **worktree-aware** because the worktree rule ("always use a worktree for branched work in shared repos") routes most ships through a secondary worktree. The legacy `git checkout master` path fails inside a secondary worktree with `fatal: 'master' is already used by worktree at <primary>` — master is already checked out by the shared clone — and the rest of the cleanup chain (delete branch, remove verification marker) gets skipped. Detect the worktree case once and branch.

```bash
GIT_DIR=$(git rev-parse --git-dir)
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)

if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ]; then
 # Primary clone — legacy path.
 git checkout master && git pull
 git branch -d {branch} 2>/dev/null # delete local if still exists
 rm -f.ai-workspace/ship-verified-{pr-number} # clean up verification marker

 # L1-B [gone]-prune (repo-hygiene-prevention plan): after the pull, any
 # locals whose origin upstream was deleted on PR merge are vestigial.
 # Delete them silently UNLESS they carry unpushed work (commits not in
 # origin/master). Per-branch ≤50ms, total ≤500ms; failures are non-fatal.
 git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null \
 | grep '\[gone\]' | awk '{print $1}' \
 | while read -r gone_branch; do
 [ -z "$gone_branch" ] && continue
 # Preserve unmerged work: skip if the branch has commits not in origin/master.
 unpushed="$(git log "$gone_branch" --not origin/master --oneline 2>/dev/null | head -1)"
 if [ -z "$unpushed" ]; then
 git branch -D "$gone_branch" >/dev/null 2>&1
 fi
 done

 # L1-C fast-forward primary (repo-hygiene-prevention plan): leave the
 # primary clone exactly at origin/master so a stale-primary PR-from-primary
 # accident can't happen. Fast-forward only — never destructive.
 #
 # FF-skip sentinel (prevent-primary-clone-drift plan, 2026-05-02):
 # When the FF skips (dirty tree, non-FF history, etc.), write a structured
 # sentinel file at $HOME/.claude/.ship-stage8-skipped.log so SessionStart
 # consumers (hooks/session-bookmark.sh) can surface a gap-independent
 # _NUDGE: line. Single line, key=value space-separated, last-event-wins.
 # On a successful FF, delete any stale sentinel so a one-time skip does
 # not surface forever. F69 anti-pattern avoided (file-based sentinel,
 # not stderr-grep across process boundaries); architectural precedent
 # (housekeep-runner status sentinel).
 git fetch origin master --quiet 2>/dev/null
 PRIMARY_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
 if [ "$PRIMARY_BRANCH" = "master" ]; then
 SHIP_SENTINEL="${HOME}/.claude/.ship-stage8-skipped.log"
 SHIP_FF_STDERR=$(git pull --ff-only origin master 2>&1 >/dev/null)
 SHIP_FF_RC=$?
 if [ "$SHIP_FF_RC" -eq 0 ]; then
 # FF succeeded — delete any stale sentinel from a prior skip.
 rm -f "$SHIP_SENTINEL" 2>/dev/null
 else
 # FF skipped — write structured sentinel for SessionStart surfacing.
 SHIP_LOCAL_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
 SHIP_ORIGIN_SHA=$(git rev-parse origin/master 2>/dev/null || echo "unknown")
 SHIP_GAP=$(git rev-list --count HEAD..origin/master 2>/dev/null || echo "unknown")
 SHIP_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
 [ -z "$SHIP_DIRTY" ] && SHIP_DIRTY="n/a"
 SHIP_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
 # Replace newlines/whitespace in stderr so the sentinel stays single-line.
 SHIP_FF_STDERR_ONELINE=$(printf '%s' "$SHIP_FF_STDERR" | tr '\n\r\t' ' ' | sed 's/ */ /g')
 mkdir -p "${HOME}/.claude" 2>/dev/null
 printf 'iso_ts=%s local_sha=%s origin_sha=%s gap=%s dirty_count=%s stderr=%s\n' \
 "$SHIP_TS" "$SHIP_LOCAL_SHA" "$SHIP_ORIGIN_SHA" "$SHIP_GAP" "$SHIP_DIRTY" "$SHIP_FF_STDERR_ONELINE" \
 > "$SHIP_SENTINEL"
 echo "[ship] primary FF skipped (gap=$SHIP_GAP, dirty=$SHIP_DIRTY); sentinel written to $SHIP_SENTINEL — run 'git pull --ff-only origin master' manually after resolving the blocker"
 fi
 fi
else
 # Secondary worktree (rule case). Pull in the shared clone, remove
 # this worktree, delete the local branch, and prune the verification marker
 # from the worktree before it's removed.
 WORKTREE_PATH=$(pwd -P)
 PRIMARY_PATH=$(cd "$GIT_COMMON_DIR/.." && pwd -P)
 rm -f.ai-workspace/ship-verified-{pr-number} # clean marker before worktree is removed
 cd "$PRIMARY_PATH"
 # Intentional per CLAUDE.md rule: do NOT `git checkout master` here.
 # The shared primary clone may legitimately be on a non-master branch for
 # other agents; we pull whatever branch it's on. A future maintainer might
 # be tempted to add `git checkout master` for symmetry with the primary-
 # clone path above — don't. That would yank HEAD out from under any
 # concurrent agent working in the shared clone.
 git pull

 # L1-B [gone]-prune (repo-hygiene-prevention plan): in the shared clone,
 # delete locals whose upstream is gone (preserve unpushed work). Same
 # contract as the primary path above.
 git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null \
 | grep '\[gone\]' | awk '{print $1}' \
 | while read -r gone_branch; do
 [ -z "$gone_branch" ] && continue
 unpushed="$(git log "$gone_branch" --not origin/master --oneline 2>/dev/null | head -1)"
 if [ -z "$unpushed" ]; then
 git branch -D "$gone_branch" >/dev/null 2>&1
 fi
 done

 # NOTE: L1-C (fast-forward primary) is intentionally NOT applied here.
 # The shared primary clone may legitimately be on a non-master branch for
 # other agents (see comment above); blindly forcing master-FF would yank
 # HEAD. The primary-clone branch above is the only path that asserts FF.

 git worktree remove "$WORKTREE_PATH" 2>/dev/null \
 || git worktree remove --force "$WORKTREE_PATH"
 git branch -d {branch} 2>/dev/null # delete local if still exists
 # Remote branch was already deleted by `gh pr merge --delete-branch` in Stage 6.
 # If it lingers (gh's local-branch deletion sometimes fails on Windows when
 # HEAD-switching is blocked by a worktree), prune the dangling remote ref:
 git push origin --delete {branch} 2>/dev/null || true
fi
```

**Hygiene additions (L1-B + L1-C, from `.ai-workspace/plans/2026-05-02-repo-hygiene-warning-mechanisms.md`):**
- L1-B: after the `git pull` in BOTH branches (primary + worktree), enumerate locals with `[gone]` upstreams and delete those with no unpushed work. Preserves unmerged commits.
- L1-C: in the primary branch only, fast-forward primary clone to `origin/master` if HEAD is on master. Never destructive (FF-only).

**Release-worktree quarantine** (runs after the feature-worktree branch above when Stage 7 created a release worktree). The release worktree at `.claude/worktrees/release-{version}` is no longer needed once the release PR has merged and the tag has been pushed. Move it (do NOT `rm -rf` — Rule 14) into a quarantine path, then prune the worktree registry:

```bash
RELEASE_WT=".claude/worktrees/release-{version}"
if [ -d "$RELEASE_WT" ]; then
 # Operate from the primary clone so the worktree path is reachable.
 cd "$PRIMARY_PATH"
 QUARANTINE_DIR=".claude/worktrees/_quarantine-release-{version}-$(date +%Y%m%d)"
 mv "$RELEASE_WT" "$QUARANTINE_DIR"
 git worktree prune
 git branch -d chore/release-{version} 2>/dev/null || true
fi
```

The `mv`-not-`rm` step is mandatory per CLAUDE.md Rule 14 ("Always Use `mv`, Never `rm`"). The quarantine dir is a sibling under `.claude/worktrees/`, so a future operator can recover the release worktree if anything went wrong with the GitHub Release creation.

**Auto-publish skills** (conditional): If `scripts/publish-skills.sh` exists in the repo root AND the merged PR touched files under `skills/`, run the publish script. Log the result but do not fail the pipeline if publishing fails. This only triggers in repos that have the publish script.

**Persist run data** (see Run Data Recording section below), then print a final summary:
- PR URL and merge commit SHA
- Number of review iterations performed
- GitHub issues created (if any)
- Release version (if Stage 7 created a tag)

---

## Stage 9 -- RECORD (always runs)

Print the status line: `[SHIP 9/10] Recording run data...`

This stage executes regardless of whether earlier stages succeeded or failed. If the pipeline aborts at any stage, Stage 9 still runs before stopping. This is the observability contract — every invocation MUST produce a run record, including aborted runs (a "nothing to ship" abort is still a run worth tracking because it reveals invocation patterns). Prior versions made this an appendix-style "Run Data Recording (always runs)" section which was structurally easy to skip; it is now an explicit numbered stage.

### What to record

Build the run record from metrics accumulated throughout the pipeline:

```json
{
 "timestamp": "{run_start_time}",
 "durationSeconds": "{now - run_start_time in seconds}",
 "outcome": "success|partial|failure|aborted",
 "project": "{current project directory name}",
 "trigger": "/ship {$ARGUMENTS or empty}",
 "stages": {
 "preflight": "pass|fail|skip",
 "branch": "pass|fail|skip",
 "commit": "pass|fail|skip",
 "pushPr": "pass|fail|skip",
 "ciWait": "pass|fail|skip",
 "selfReview": "pass|fail|skip",
 "merge": "pass|fail|skip",
 "release": "pass|fail|skip",
 "cleanup": "pass|fail|skip",
 "card": "pass|fail|skip"
 },
 "metrics": {
 "prUrl": "{PR URL or null}",
 "prNumber": "{PR number or null}",
 "branchName": "{branch name}",
 "reviewIterations": "{count, 0 if not reached}",
 "bugsFound": "{total bugs across all iterations}",
 "bugCategories": ["{deduplicated list of bug types}"],
 "enhancementsCreated": "{count of GH issues created}",
 "ciWaitSeconds": "{seconds spent polling CI}",
 "ciOutcome": "pass|fail|timeout|none|null",
 "ciOauthSynced": "{true if token was synced during CI wait, omit otherwise}",
 "ciRetried": "{true if CI was re-triggered after token sync, omit otherwise}",
 "ciRetryOutcome": "pass|fail|timeout|null",
 "releaseVersion": "{version or null}",
 "releaseBump": "major|minor|patch|skipped|null",
 "releaseViaPR": "{true if Stage 7 used the PR-merge flow; false if Stage 7 was skipped because no package.json; null if Stage 7 errored before deciding}",
 "releasePrUrl": "{URL of the release PR, or null if no release}",
 "commitCount": "{number of commits: initial + fix iterations}",
 "cardEmission": "emitted:<path> | emitted:<path>+refresh-warn | skipped:no-root | skipped:no-tool | skipped:outcome-<value> | error:<one-line>"
 },
 "issues": [
 { "stage": "{stage}", "type": "{issue_type}", "description": "{description}" }
 ],
 "summary": "{one-line description of what happened}"
}
```

**Outcome values:**
- `success` — merged and released (or merged + release skipped because no package.json)
- `partial` — merged but release failed
- `failure` — merge failed (conflicts, branch protection)
- `aborted` — pipeline stopped early (nothing to ship, CI failure, auth failure, 5 iterations exhausted, network error)

For aborted runs, also set:
- `metrics.abortStage`: the stage name where the pipeline stopped
- `metrics.abortReason`: one-line explanation

### Where to write

All paths are relative to this skill's base directory (resolved from the symlink, i.e., the skill's source directory):

1. **`runs/data.json`** — Read the existing file (create if missing with `{"skill":"ship","lastRun":null,"totalRuns":0,"runs":[]}`). Append the new run record to the `runs` array. If `runs.length > 50`, remove the oldest entries to keep exactly 50 (older runs are permanently discarded). Increment `totalRuns` by 1. Set `lastRun` to the run's timestamp. Write the file.

2. **`runs/run.log`** — Append one line: `{timestamp} | {outcome} | {durationSeconds}s | {summary}`. If the log exceeds 100 lines, trim the oldest lines to keep exactly 100.

### Important

- **Always record**, even on abort. A "nothing to ship" abort is still a run worth tracking (it reveals invocation patterns).
- **Do not fail the pipeline** if recording fails (e.g., file permission error). Log a warning and continue.
- **Resolve the skill base directory** from the symlink target, not the current working directory. The runs/ folder lives alongside SKILL.md.

## Stage 10 -- CARD (decision card emission, success runs only)

Print the status line: `[SHIP 10/10] Emitting decision card...`

**Stage 10 is the same class of "feels done, exits early" problem that Stage 9 itself was promoted to fix.** When card emission was a sub-stage nested inside Stage 9's text wall, operators treated `data.json` + `run.log` as "recording done" and bailed. Promoting it to a numbered stage with its own status line makes the final-final step visible in the pipeline progression. Like Stage 9, this stage is best-effort (never fails the pipeline) but the **decision to attempt it** is now unconditional for success runs.

After the run record has been written to `runs/data.json` and `runs/run.log`, emit a working-memory decision card under the user's agent-working-memory tree if the user has opted in. This is how shipped work flows into the causal memory tier described in `.ai-workspace/plans/2026-04-15-agent-working-memory.md`.

**Gating conditions — ALL must hold for emission to proceed. If any fails, skip silently and record the reason in `metrics.cardEmission`:**

**IMPORTANT — run these gate checks as actual bash commands. Do NOT read the prose and guess the outcome; past /ship runs failed Stage 10 silently because the agent interpreted "check if X exists" as a prompt to substitute an assumption rather than invoke the filesystem. Execute the bash blocks below verbatim and branch on their exit codes / output.**

1. **Memory root discoverable.** Either `$WORKING_MEMORY_ROOT` is set in the environment, OR the default path `~/.claude/agent-working-memory/` exists on disk. In **both** cases, the resolved root must contain a `tier-b/` subdirectory — if `$WORKING_MEMORY_ROOT` is set but has no `tier-b/` inside, the gate fails fast as `skipped:no-root` rather than cascading into a write-time error. If neither source resolves to a valid root: skip with `cardEmission: "skipped:no-root"`.

 Concrete gate check (run this; pass iff it prints `root=<path>`):

 ```bash
 ROOT="${WORKING_MEMORY_ROOT:-$HOME/.claude/agent-working-memory}"
 if [ -d "$ROOT/tier-b" ]; then
 echo "root=$ROOT"
 else
 echo "skipped:no-root"
 fi
 ```

2. **Mechanism tool discoverable.** The public mechanism repo's `src/write-card.mjs` must be reachable. Look for it at (a) `$WORKING_MEMORY_TOOL` if set, (b) `$HOME/coding_projects/agent-working-memory/src/write-card.mjs`, (c) a `memory` binary on `$PATH`. If none resolve: skip with `cardEmission: "skipped:no-tool"`.

 Concrete gate check (run this; pass iff it prints `tool=<path>` or `tool=memory`):

 ```bash
 if [ -n "${WORKING_MEMORY_TOOL:-}" ] && [ -f "$WORKING_MEMORY_TOOL" ]; then
 echo "tool=$WORKING_MEMORY_TOOL"
 elif [ -f "$HOME/coding_projects/agent-working-memory/src/write-card.mjs" ]; then
 echo "tool=$HOME/coding_projects/agent-working-memory/src/write-card.mjs"
 elif command -v memory >/dev/null 2>&1; then
 echo "tool=memory"
 else
 echo "skipped:no-tool"
 fi
 ```

3. **Run outcome is `success`.** Aborted, partial, and failure runs do NOT emit cards — they add noise to the memory tier without adding signal. If outcome is anything other than `success`: skip with `cardEmission: "skipped:outcome-<value>"`. This gate is checked against the in-memory run outcome variable — no filesystem probe needed.

**When all three gates pass, emit the card:**

1. **Extract the WHY from the PR body.** Fetch the merged PR body via `gh pr view <pr-number> --json body -q.body`. Extract the Summary section: the text between `## Summary` and the next `##` heading. If the body has no `## Summary` heading, use the first 500 characters of the body as a fallback. Trim whitespace.
2. **Derive card metadata.**
 - `topic`: `ship-runs`
 - `id`: `pr-<pr-number>-<slug>` where `<slug>` is the branch name with conventional prefix stripped (e.g., `feat/add-foo` → `add-foo`), lowercased, non-alphanumerics collapsed to `-`, truncated to 40 chars.
 - `title`: the PR title verbatim.
 - `created`: today's date in `YYYY-MM-DD` form.
 - `pinned`: `false`.
 - `tags`: `[]`. Auto-emitted cards are never pinned — they accumulate as an activity stream, not a rule set.
3. **Card body.** The `## Decision` section contains the extracted Summary text. `## Context` and `## Consequences` can use placeholder text (`(auto-emitted by /ship Stage 10 on PR <num>)`) — these are machine-generated cards, not hand-curated rules, and the Decision field carries the signal.
4. **Write the card.** Since `memory write` (the CLI subcommand) only fills the `## Decision` body slot and cannot accept frontmatter tweaks, write the card file directly via a heredoc or equivalent. Path: `<root>/tier-b/topics/ship-runs/<created>-<id>.md`. Create `ship-runs/` if missing.
5. **Refresh the pocket card.** Invoke `node <mechanism-repo>/src/memory-cli.mjs refresh --root <root>` so `tier-a.md` reflects the new card. Best-effort; a refresh failure does not fail the pipeline.
6. **Record the outcome.** On success with clean refresh: `cardEmission: "emitted:<relative-path-from-root>"`. On success with refresh failure: `cardEmission: "emitted:<relative-path-from-root>+refresh-warn"` — the card was written but the pocket card was not updated (it will catch up on next `memory refresh` or session start). On any error during extraction or writing (before the card exists on disk): `cardEmission: "error:<one-line-reason>"` — the pipeline proceeds regardless.

**Graceful degradation is mandatory.** This stage NEVER fails the pipeline. Any error — missing tool, disk full, malformed PR body, refresh script crash — logs a warning, records the error in `metrics.cardEmission`, and continues. The ship pipeline is already complete by the time this stage runs; card emission is a bonus, not a contract.

**Privacy note.** The card body is derived from the PR body, which is already public on GitHub. No new information leakage surface is introduced by copying it into the user's private content repo.

**Why emission is conditional on success only.** The working-memory tier is for *decisions that shipped*. An aborted run is not a decision; a partially-merged release is ambiguous. Filtering to `success` keeps the card stream clean and makes the Tier A pocket card more valuable (no noise). If richer coverage is wanted later, a follow-up can open the gate to `partial`; do not expand the gate silently here.

---

## Final output

User-facing reply at the end of a `/ship` invocation is capped at ≤5 lines. Stage-9 RECORD and Stage-10 CARD continue to write full data to `runs/data.json`, `runs/run.log`, and the working-memory tier-b card — those internal artefacts are unchanged. This cap governs only the prose Claude prints back to the user. Verbose detail is opt-in via `--verbose`; default is terse.

- Outcome line: success/partial/abort + PR number + merge SHA (or abort reason).
- Key metric line: stages run, CI pass count, review iterations, release tag (if any).
- Pointer line: `see skills/ship/runs/run.log for full history`.
- Last status line: card-emission status (`emitted:<path>` / `error:<reason>`) when Stage 10 ran.
- (blank line)

Grounded in F20 (Verbose Gate Ceremony vs Brevity Directive) — the platform's terseness preference wins every conflict; the skill must produce a compact final reply by design rather than relying on the agent to compress it post-hoc.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No changes to commit | Abort: "Nothing to ship." |
| Already on feature branch | Skip branch creation |
| PR already exists for branch | Skip PR creation, use existing |
| CI fails | Report check names + URLs, abort |
| Merge conflicts | Report conflicting files, abort |
| 5 review iterations exhausted | List remaining bugs, escalate to user |
| No CI checks configured | Skip CI wait, proceed to review |
| `gh` auth failure | Report error, abort |
| Network error during any `gh` call | Report the error, abort cleanly |
| No package.json in repo | Skip Stage 7 entirely |
| No git tags exist | Use 0.0.0 baseline, bump to 0.1.0 |
| No conventional commits since last tag | Default to patch bump |
| Tag/push fails | Log warning, skip — feature is already merged |
| GitHub Release creation fails | Log warning, skip — tag still exists |
