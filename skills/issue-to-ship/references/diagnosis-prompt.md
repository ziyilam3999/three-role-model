# Diagnosis prompt — root-cause categorization

Use this prompt to walk the operator from a one-line problem statement to a goal-mapped fix proposal. The output of this prompt feeds the plan template's `## Context`, `## Goal`, and `## Approach` sections.

## 1. What happened

In 1–3 sentences, state the problem. Plain language. No analysis yet — just the facts.

- What you observed.
- When you observed it.
- What was supposed to happen instead.

## 2. Evidence

Anchor the problem in concrete artefacts. The plan reviewers will check these.

- Commit SHAs of the culprit changes (use `git log --oneline -5` against the suspect file).
- File paths + line numbers of the affected code.
- Transcript anchors (session ID + approximate turn) if the failure surfaced in chat.
- Log lines (PM2, GitHub Actions, hook stderr).
- Sister plans that share the failure mode.

## 3. Root cause categorization

Sort the failure into one of these categories. The category determines what kind of fix is needed.

- **Category O — Shared infrastructure.** Hook, runner, settings file, cron job, mailbox. Symptom: "all sessions hit it." Fix shape: change the shared infra (hooks/, runners/).
- **Category P — Per-session hooks.** SessionStart / SessionEnd / PreToolUse / PostToolUse hook fires unexpectedly or fails to fire. Symptom: "this session got it; that session didn't." Fix shape: hook code path or registration.
- **Category Q — Behavioral prose.** A rule lived in CLAUDE.md / ${CLAUDE_PLUGIN_ROOT}/3-role-model.md / SKILL.md as prose, agents ignored it. Symptom: "the rule is documented but agents keep violating it." Fix shape: hooks-first doctrine (Rule 17) — convert prose to mechanical detection.
- **Category R — No mechanical detection.** Failure mode has no hook, no AC, no nudge. Symptom: "we caught it by reading the diff." Fix shape: add the missing detection layer (hook + nudge + AC).

## 4. Why existing prevention layers didn't catch it

Sweep the live shipped layers. For each, state whether it COULD have caught the failure mode (and didn't, because of a gap), or whether it's structurally unable to (different concern).

- **Rule-12 guard hook** (`hooks/rule-12-guard.sh`) — refuses primary-clone state mutations during worktree subagent activity.
- **Drift sentinel** — refuses commits that mutate target files without a corresponding test.
- **M2 untracked-tools nudge** — flags new tools without registration.
- **N2 / N3 / T2 nudges** — Block-4 walk emitters for repo-hygiene findings.
- **Cross-repo-debt block** — Block 5 production-vs-test gate.
- **Settings-drift detector** — Block 6 stash-accumulation prevention.
- **Cross-clone-contamination hook** — primary-busy gate during worktree activity.
- **Enforce-ship hook** — `/ship` marker requirement.
- **Repo-hygiene-block** — refuses commits to ignored paths.

Identify the **gap**: which layer could have caught this if it existed, didn't catch it because it doesn't exist, OR caught it but was too late to prevent damage. The gap is the input to Goal mapping.

## 5. Goal mapping

From the gap, the goal is **mechanical detection of the failure mode**. Propose a hook + nudge + AC triple:

- **Hook** — what file, what trigger event (PreToolUse / PostToolUse / SessionStart / SessionEnd), what condition fires the refusal/nudge.
- **Nudge** — emitter token (matches the existing `<TOKEN>_NUDGE:` shape per `hooks/session-bookmark.sh`); message text.
- **AC** — binary verifier, exit code 0 means PASS. Pin orientation. Test the hook fires on the failure pattern AND does NOT fire on the legitimate pattern.

Sister-plan sweep checklist:

- Are there in-flight plans that touch the same hook file? If yes, sequence carefully (likely shared write surface — serialize, don't parallelize).
- Are there sister tier-b cards that document a related decision? Cross-reference them.
- Does the gap match a known F-ID anti-pattern (F2, F36, F50, F65, F66, F68)? Cite the F-ID in the plan's `## Approach → Pattern grounding` section.

## Output shape

After walking through 1–5, the operator has the inputs to fill the plan template:

- `## ELI5` — derived from #1 + #5.
- `## Context` — derived from #2.
- `## Goal` — derived from #5.
- `## Why this scope` — derived from the option enumeration in #5.
- `## Approach` — derived from #5's hook + nudge + AC triple.
