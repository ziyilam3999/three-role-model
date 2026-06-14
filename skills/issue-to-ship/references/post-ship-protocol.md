# Post-ship protocol — push, pull, cairn save

After the executor merges the PR, run this protocol. It captures the operator-side discipline for non-master worktrees and the cross-clone-contamination check that prevents primary-clone corruption during concurrent worktree subagent activity.

## 1. Verify PR merged

```
gh pr view <num> --json state --jq '.state'
```

Expected output: `MERGED`. If `OPEN` or `CLOSED`, STOP and investigate before proceeding.

## 2. Cross-clone-contamination check (wait for active subagents)

Before pulling primary, check for active worktree subagents. Mutating primary clone state while a worktree subagent has primary's working tree mounted causes content contamination (the worktree's HEAD diverges from primary's checkout).

The cross-clone-contamination V1 hook (shipped 2026-05-03 on `origin/master`) refuses primary-clone state mutations during worktree subagent activity. The hook's signal is: `git worktree list` shows a non-master non-detached worktree with an in-flight branch.

Check before pull:

```
git worktree list | awk '$3 != "[master]" && $3 != "" && !/detached/'
```

If output is non-empty AND any of those worktrees have an active subagent dispatched from this session OR a sister session: **DEFER** the pull until they finish, OR rely on the cross-clone-contamination hook to refuse the mutation. Either way, do NOT force-route around the hook.

Wait-for-active-subagents protocol: poll `pm2 list` (or the equivalent) and the runtime's subagent-status surface. Pull only after the worktree branches show no in-flight commits / no pending pushes.

## 3. Pull primary

```
git pull --ff-only origin master
```

Expected: fast-forward update including the just-merged PR. If the pull fails (non-fast-forward), inspect — likely a sister merge landed between the executor's push and this pull. Resolve manually.

## 4. Drop pre-pull stashes

During the run, the operator may have accumulated stashes named like `block-X-pre-pull-mods-<date>` or `config-mods-pre-restore-<date>`. After successful pull, drop them:

```
git stash list | grep -E '<date-prefix>' | awk '{print $1}' | sed 's/://' | xargs -I{} git stash drop {}
```

CAUTION: verify the stash list before dropping. Block 6 stash-walk surfaced 15 historical stashes in one session — the prevention layer is to drop pre-pull stashes immediately after each pull, not let them accumulate.

## 5. File tier-b ship-run card

```
node ~/coding_projects/agent-working-memory/src/memory-cli.mjs write \
 --topic ship-runs \
 --id <YYYY-MM-DD>-pr-<N>-<slug> \
 --title "PR #<N>: <one-line outcome>"
```

Then edit the rendered card to fill in:

- PR number + URL.
- AC outcomes (which passed; which were known-failing on baseline).
- Deferred follow-ups (e.g., "v1.1 may add a CWD-gate hook").
- Novel lessons surfaced during execution.

## 6. Cairn lesson save (if novel)

If a novel lesson surfaced during the run — a mistake the operator made that isn't already a cairn stone — save it for the T1→T2→T3 graduation pipeline:

```
/cairn place "<one-line lesson>"
```

OR post `#cairn-stone: <one-line lesson>` inline. The H4 runner promotes T1 → T2 overnight; H5 promotes T2 → T3 KB if the lesson surfaces in ≥2 sessions.

## 7. Update runs/data.json

Append the run record to `skills/issue-to-ship/runs/data.json`:

```json
{
 "timestamp": "<ISO-8601 invocation start>",
 "outcome": "complete",
 "problem_statement": "<one-line issue>",
 "slug": "<slug>",
 "p1_verdict": "<verdict>",
 "p2_verdict": "<verdict>",
 "p3_verdict": "<verdict>",
 "p4_verdict": "<verdict>",
 "ship_pr_number": <N>,
 "time_to_ship_seconds": <int>,
 "lessons_learned": ["<lesson 1>", "<lesson 2>"]
}
```

Update the envelope's `lastRun` to the new timestamp and increment `totalRuns`.

## Failure modes to watch for

- **Pull blocked by classifier.** The Bash classifier may refuse `git pull` if it interprets the call as cross-clone-contamination-suspect. Treat the block as a REAL signal — the operation would have caused contamination. Wait for subagents or use the hook's override surface only with explicit operator approval.
- **Stash accumulation.** If pre-pull stashes accumulate beyond a single run, the cleanup command in step 4 may match unintended stashes. Filter narrowly by date prefix.
- **Tier-b card collision.** If a card already exists at the target ID, append to the existing card rather than overwriting.
