# Plan #1258 — Package "Autonomous Pipeline Mode" into the three-role-model plugin

- **Task:** #1258
- **Branch:** `feat/autonomous-pipeline-mode` (off `origin/master` `94bb24e`)
- **Role chain:** planner (this doc) → plan-review → executor → execution-review
- **Repo:** PUBLIC. No home paths, no employer/internal identifiers in any shipped file. Placeholders only (`<source-repo>`, `$HOME`, `~`, `${CLAUDE_PLUGIN_ROOT}`).

---

## ELI5

The plugin already teaches Claude Code the "3-role model" (planner → plan-review → executor → execution-review, nobody grades their own homework). We're adding a second, complementary habit called **Autonomous Pipeline Mode**: once you've approved a plan, Claude should keep working through the approved steps instead of stopping to ask "should I do the next thing?" every time — and after a `/compact` or `/clear` it should re-explain the plan in plain words, re-sort the remaining work into three tiers, and ask for approval **once** before resuming.

Two small bash hooks make this reliable: one **Stop** hook that catches Claude ending a turn by asking permission for a step it was already told to do, and one **SessionStart/UserPromptSubmit** hook that surfaces the resume-and-re-sequence protocol at the right moment. We copy both hooks (already verified clean of personal paths) into the plugin's `hooks/`, register them in `hooks.json`, bundle the written doctrine so installers can read the full spec, and bump the version. After this, anyone who installs the plugin gets Autonomous Pipeline Mode alongside the 3-role model — with the caveat that the optional scheduled "wake up and continue" loop is a Claude Code runtime feature, not something a plugin can ship.

---

## Execution model

**subagent (the 3-role chain) — NOT inline.** This change touches ≥7 files (2 new hooks, 2 new smoke tests, 1 new doctrine doc, plus `hooks.json` / `plugin.json` / `marketplace.json` / `package.json` / `CHANGELOG.md`) and carries an architectural decision (which `hooks.json` events to register + the version-drift resolution), which is well past the task-sizing ladder's DELEGATE threshold (3+ files / architectural decision / >10 LOC). The executor is a single write-capable subagent (the work is one cohesive bundle on one branch — no parallel split warranted), gated by this plan's plan-review before execution and an execution-review after. The hook copies are verbatim, but the `hooks.json` registration, version reconciliation, and two new smoke tests are real authored surface that must be reviewed, hence the full chain rather than an inline edit.

---

## Intent (what / why)

**What:** Extend the existing public plugin with the Autonomous Pipeline Mode pieces — two hooks, their `hooks.json` registrations, the bundled doctrine doc, manifest/version/changelog updates, and two portability smoke tests.

**Why:** The two behaviors already live in the author's private `ai-brain` repo and are proven there. The 3-role plugin is the natural public home for them — they are the same class of mechanical workflow-discipline gate the plugin already ships. Packaging them lets external installers adopt the "approve once, then run the pipeline" discipline without rebuilding it.

**Non-goal / out of scope:** No change to the existing 3-role hooks or ledger. No scheduled-wakeup runtime wiring (not plugin-packageable — see Caveats). No README rewrite required for AC (an optional one-line mention is welcome but not graded).

---

## Concrete deliverable surface (files to add / edit)

### Add
1. `hooks/autonomous-approval-stop-check.sh` — copy verbatim from `<source-repo>/hooks/autonomous-approval-stop-check.sh` (the `ai-brain` hooks dir). Stop hook. 90 lines. Mark executable (`chmod +x`).
2. `hooks/post-compact-resume-sequencer.sh` — copy verbatim from `<source-repo>/hooks/post-compact-resume-sequencer.sh`. SessionStart(compact|clear) + UserPromptSubmit hook. 151 lines. Mark executable.
3. `post-compact-resume-sequencing-protocol.md` — at **repo root** (matches `3-role-model.md`, the existing root-level doctrine doc). Copy from the author's tier-b workflow card. Keep this exact basename so the hook's `Full spec: post-compact-resume-sequencing-protocol.md` pointer stays truthful. Add a short **Packaging note** header (see "Doctrine doc adaptation" below).
4. `hooks/_smoke/autonomous-approval-stop-check-smoke-test.sh` — portability + fire smoke (CI auto-discovers `hooks/_smoke/*.sh`).
5. `hooks/_smoke/post-compact-resume-sequencer-smoke-test.sh` — portability + fire smoke.

### Edit
6. `hooks/hooks.json` — ADD a `Stop` block, a `SessionStart` block (matchers `compact` and `clear`), and a `UserPromptSubmit` block. Exact existing shape: `{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh\"","timeout":10}`. The resume-sequencer is the same script invoked three ways via an arg:
   - `SessionStart` matcher `"compact"` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-compact-resume-sequencer.sh"` (primary mode, no arg).
   - `SessionStart` matcher `"clear"` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-compact-resume-sequencer.sh" --clear-mode`.
   - `UserPromptSubmit` (no matcher) → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/post-compact-resume-sequencer.sh" --prompt-mode`.
   - `Stop` (no matcher) → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/autonomous-approval-stop-check.sh"`.
   - Use `timeout: 10` to match every existing block.
7. `.claude-plugin/plugin.json` — bump `version` to **0.9.0** (see SemVer note — the stale `0.7.0` in this file is corrected to the true next version, NOT 0.8.0). Extend `description` to mention Autonomous Pipeline Mode.
8. `.claude-plugin/marketplace.json` — extend the top-level `description` and the `plugins[0].description` to mention Autonomous Pipeline Mode.
9. `package.json` — bump `version` `0.8.1` → `0.9.0` (keep it in lockstep with plugin.json; it is currently the source of truth the tags follow).
10. `CHANGELOG.md` — add a dated `## [0.9.0] - 2026-06-26` entry in the existing "Keep a Changelog" `### Added` style used by the `[0.7.0]`/`[0.6.0]` hand-written entries.

---

## SemVer + version-drift finding (IMPORTANT — overrides the brief's "0.8.0")

The brief proposed `0.7.0 → 0.8.0` based on `plugin.json` reading `0.7.0`. **That `plugin.json` value is stale.** Ground truth in the worktree:
- `git tag` already includes `v0.8.0` AND `v0.8.1`.
- `package.json` is `0.8.1`.
- `CHANGELOG.md` top entries are `[0.8.1]` and `[0.8.0]`.

So `plugin.json` (`0.7.0`) drifted behind the release line (the ai-brain-sync `chore: release` PRs bumped `package.json` + tags + CHANGELOG but left `plugin.json` un-bumped). **Proposing `0.8.0` would collide with an already-released tag/changelog entry.** The correct next MINOR (additive, backward-compatible feature) is therefore **0.9.0**. The executor sets `plugin.json` AND `package.json` to `0.9.0` and adds the `[0.9.0]` CHANGELOG entry, which also repairs the `plugin.json` drift in the same PR.

- **Version:** `0.9.0`
- **Conventional-Commit subject:** `feat: add Autonomous Pipeline Mode (stop-check + resume-sequencer hooks + doctrine)`

---

## CRITICAL portability guard analysis (the load-bearing section)

Both source hooks were read in full. **Verdict: both are already portable and degrade gracefully on a host that lacks the author's infra. No new code guards are strictly required to satisfy the brief's "NO-OP cleanly, no spurious block, no error spew" bar.** The detail per external dependency:

### `autonomous-approval-stop-check.sh`
| Dependency on author infra | Line / form | Already degrades? | Action |
|---|---|---|---|
| `python3` | `command -v python3 >/dev/null 2>&1 \|\| exit 0` | YES — exits 0 if absent, no block | none |
| Override audit log `$HOME/.claude/.rule-12-overrides.log` | `echo ... >> "$HOME/.claude/.rule-12-overrides.log" 2>/dev/null \|\| true` | YES — `$HOME`-rooted, `2>/dev/null \|\| true`, only on `AUTONOMOUS_STOP_OVERRIDE=1` | none |
| Doctrine pointer string `feedback_no_stop_for_already_approved_step` | inside the `sys.stderr.write(...)` block message | Harmless — it is printed text, **not a file read**; no error if absent | OPTIONAL polish: repoint to the bundled `post-compact-resume-sequencing-protocol.md` for installer-friendliness. NOT required; do not block on it. |
| Home paths `/Users/<name>/...` | none | — | confirmed absent |

No ledger CLI, no cron, no `agent-working-memory` read. Self-contained.

### `post-compact-resume-sequencer.sh`
| Dependency on author infra | Line / form | Already degrades? | Action |
|---|---|---|---|
| `python3` | sid/prompt extraction guarded by `command -v python3` with a `grep`/sed fallback for sid, and `[ -n "$prompt" ] \|\| exit 0` for prompt | YES — silent exit 0 if absent | none |
| Sentinel dir `$HOME/.claude/cairn/sessions` | `SESS_DIR="${POST_COMPACT_SESS_DIR:-$HOME/.claude/cairn/sessions}"`; `mkdir -p "$SESS_DIR" ... \|\| true`; `date ... > "$SESS_DIR/$sid.compact" ... \|\| true` | YES — **self-created** under `$HOME` (not read from external infra), all writes `\|\| true`, overridable via `POST_COMPACT_SESS_DIR` | none (smoke uses the override to avoid touching real `$HOME`) |
| Doctrine pointer `post-compact-resume-sequencing-protocol.md` | inside `emit_reminder` heredoc | Resolves once we bundle the doc at repo root with that basename | satisfied by deliverable #3 |
| Internal cross-refs (`pre-compact-card-template.md`, `session-state-pre-compact-*`, `TaskList`) | in the emitted reminder text | Harmless printed text; degrade to "reminder mentions a concept the host may not have" | none (the reminder is advisory, never blocks) |
| Home paths `/Users/<name>/...` | none | — | confirmed absent |

`set -uo pipefail` + `exit 0` on every path; a SessionStart/UserPromptSubmit reminder can never wedge a session. Self-contained.

### ScheduleWakeup caveat (must be stated, not packaged)
Neither hook references `ScheduleWakeup`. The autonomous-loop **tick** (a scheduled "wake up and continue the pipeline") is a Claude Code **runtime** feature — it cannot be shipped inside a plugin. The plan states this here AND the bundled doctrine doc MUST carry an explicit caveat so installers are not misled into thinking the plugin schedules anything. Autonomous Pipeline Mode as shipped = the two advisory/gate hooks + the doctrine; the scheduled tick is the operator's own runtime config.

### Doctrine doc adaptation (on copy)
- The source card has **no `/Users/` paths** (uses `~/.claude/cairn/...`); the privacy-grep AC will confirm. No employer/internal tokens present.
- Prepend a short **Packaging note** at the top of the bundled copy stating: (a) this doc ships with the three-role-model plugin; (b) the surfacing hook is `post-compact-resume-sequencer.sh`; (c) the `ScheduleWakeup` autonomous-loop tick is a Claude Code runtime feature and is NOT part of this plugin; (d) `[[wikilink]]` / `feedback_*` / `*-template.md` references point to the author's private memory system and are informational only.
- Leave the body otherwise verbatim (it is the single source of truth the hook points to).

---

## cairn (subagent-memory) grounding
- `cairn-find "plugin"` → HIT: `When porting hooks into a Claude Code plugin, replace all ~/.claude/hooks/, n[ode paths] ...` and `Claude Code plugin hooks COMPOSE with (do not replace) a user's settings.json hooks` (t1-run-scratch 2026-06-14). Confirms the `${CLAUDE_PLUGIN_ROOT}` rewrite rule and that registering new event blocks composes with, not clobbers, an installer's own hooks.
- `cairn-find "hook portability"` → HIT: session-state card `full port of all hooks ... true ${CLAUDE_PLUGIN_ROOT} portability` and `The hooks call external node scripts + read ~/.claude/3role-ledger/ — biggest [portability risk]`. Reinforces: the two NEW hooks are lighter than the ledger hooks (no node, no external-state read) and are the easy case.

---

## Binary AC (externally checkable — run from the worktree root)

1. **Both hook files present + executable:** `test -x hooks/autonomous-approval-stop-check.sh && test -x hooks/post-compact-resume-sequencer.sh`.
2. **Hooks are byte-faithful copies** (no accidental edits beyond optional pointer-repoint): line counts ≈ 90 / 151; `bash -n` clean (CI also enforces this on every `hooks/*.sh`).
3. **`hooks.json` is valid JSON** and contains the three new event keys: `node -e "const h=require('./hooks/hooks.json').hooks; if(!h.Stop||!h.SessionStart||!h.UserPromptSubmit) process.exit(1)"`.
4. **Each new registration references the hook via `${CLAUDE_PLUGIN_ROOT}`** and uses `"type":"command"` + `"timeout":10`; `SessionStart` has both `compact` and `clear` matchers; the `clear` and `--prompt-mode` invocations pass their arg; the `Stop` block references `autonomous-approval-stop-check.sh`. (grep the rendered JSON for each command string.)
5. **Doctrine doc present at repo root:** `test -f post-compact-resume-sequencing-protocol.md` and it contains the Packaging note + the ScheduleWakeup caveat.
6. **Privacy grep returns EMPTY:** `grep -rnE '/Users/[a-zA-Z0-9._-]+/' hooks/autonomous-approval-stop-check.sh hooks/post-compact-resume-sequencer.sh post-compact-resume-sequencing-protocol.md hooks/_smoke/autonomous-approval-stop-check-smoke-test.sh hooks/_smoke/post-compact-resume-sequencer-smoke-test.sh` → no output, exit 1.
7. **No employer/internal token leak:** the same five files contain no employer/vendor proper nouns (manual scan + the repo's existing privacy expectations).
8. **`plugin.json` version = `0.9.0`** and its `description` mentions autonomous pipeline mode; `package.json` version = `0.9.0`.
9. **`marketplace.json`** top-level `description` AND `plugins[0].description` mention autonomous pipeline mode; valid JSON.
10. **`CHANGELOG.md`** has a `## [0.9.0] - 2026-06-26` dated entry in the existing format.
11. **Portability smoke — `autonomous-approval-stop-check-smoke-test.sh`** passes, asserting all of:
    - empty stdin → exit 0, no stderr block;
    - benign final message (e.g. `{"last_assistant_message":"All done — tests pass."}`) → exit 0, no `BLOCKED` stderr;
    - bypass token present (`{"last_assistant_message":"Should I ship X now, or later? (operator decision required)"}`) → exit 0;
    - **fire case** (proves the hook still works, per per-disjunct positive-fixture rule — one positive fixture PER OR-disjunct, #1179): **D1** a PROCEED+`?` message (e.g. `Should I ship #1258 now?`) → exit 2 with `BLOCKED` on stderr; AND **D2** a NOW_OR_LATER offer with no PROCEED lead-in and no LMK (`{"last_assistant_message":"Roll out #1258 now, or hold it until later?"}`) → exit 2 (covers the NOW_OR_LATER disjunct — the canonical #623 "now, or later?" shape that PROCEED does NOT match); AND **D3** an LMK message (`Let me know if you want me to continue.`) → exit 2;
    - `loop guard`: same fire message with `"stop_hook_active":true` → exit 0.
12. **Portability smoke — `post-compact-resume-sequencer-smoke-test.sh`** passes, asserting all of (using `POST_COMPACT_SESS_DIR="$(mktemp -d)"` so real `$HOME` is never touched):
    - `--prompt-mode` with empty stdin and no sentinel → exit 0, no output;
    - primary mode (`{"session_id":"smoke-1"}`) → exit 0, stdout contains `post-compact resume protocol`, and `$POST_COMPACT_SESS_DIR/smoke-1.compact` was planted;
    - `--prompt-mode` `{"session_id":"smoke-1","prompt":"resume"}` (fresh sentinel + resume intent) → exit 0, emits the reminder once, then the sentinel is consumed (file gone);
    - `--prompt-mode` `{"session_id":"smoke-1","prompt":"unrelated chatter"}` after a fresh plant → exit 0, NO emit, sentinel left intact;
    - `POST_COMPACT_RESUME_SEQUENCER_OVERRIDE=1` → exit 0, no emit.
    - Each smoke runs the hook with `CLAUDE_PLUGIN_ROOT` set (CI provides it) and a minimal env, satisfying the "minimal/empty env + assert exit 0 + no spurious block" requirement.
13. **CI stays green:** `node scripts/ci-validate.mjs` passes (manifests valid); `bash -n` passes on all hooks incl. the two new ones; both new `hooks/_smoke/*.sh` run clean under `CLAUDE_PLUGIN_ROOT=$GITHUB_WORKSPACE`; the HEAD commit subject matches the Conventional-Commits regex (the `feat: ...` subject above does).

---

## Notes for plan-review / executor
- Copy the hooks **verbatim** (the only sanctioned edit is the OPTIONAL stop-check pointer-repoint in AC-row "doctrine pointer"); do not refactor.
- `hooks/_smoke/` IS tracked (confirmed via `git ls-files`; `.gitignore` only ignores `.ai-workspace/_*/`, `tmp/`, `*-run/`, `.three-role-ledger/`). The new smoke files will ship and run in CI.
- Keep `plugin.json`/`package.json` versions identical (`0.9.0`).
- Do not touch any existing 3-role hook, the ledger, or the README's install block.

## Deferred-follow-ups:
- Plan-review per-disjunct AC fix (NOW_OR_LATER fixture) — NOT deferred; required before execution. Listed in the Review section below; here only for deferral-accounting completeness. → fix in this plan now.
- README mention of Autonomous Pipeline Mode — DEFERRED (not in AC, optional). → file a task only if the operator wants the public README to list the new mode; not required for this ship.
- Stop-check stderr doctrine-pointer repoint (`feedback_no_stop_for_already_approved_step` → bundled doc name) — OPTIONAL polish, not graded. → none (cosmetic; verbatim copy is acceptable).
- Scheduled-wakeup autonomous-loop tick — explicitly OUT (Claude Code runtime feature, not plugin-packageable). → none (documented as a caveat in the doctrine doc by design; never to be packaged here).

---

## Review (plan-review)

<!-- Deferred-follow-ups: accounted above. This section defers no new work. -->

**Decision: NEEDS-WORK** (1 MED blocking finding; 3 LOW advisories). One mechanically-trivial AC fix required before execution; everything else verified PASS.

**Rationale (one line):** Portability, matcher wiring, and version-drift repair all verified correct against the actual source files — but the stop-check smoke (AC11) lacks a positive fixture for one of its three OR-disjuncts (NOW_OR_LATER), which is the canonical #623 "ship now, or later?" incident shape, so a regression of exactly that disjunct would ship green.

### Verified PASS (evidence)
- **Portability (load-bearing claim) — CONFIRMED for BOTH hooks** (read in full from source `<source-repo>/hooks/`; not yet copied to worktree):
  - `autonomous-approval-stop-check.sh` (90 lines): `command -v python3 ... || exit 0` (L36); empty stdin `[ -n "$INPUT" ] || exit 0` (L35); override-log write is `$HOME`-rooted + `2>/dev/null || true`, only on `AUTONOMOUS_STOP_OVERRIDE=1` (L31); `set +e`. Only ever exit-2 BLOCKs on its intended trigger pattern — NEVER on missing infra. No hard-block / error path on a bare host.
  - `post-compact-resume-sequencer.sh` (151 lines): `set -uo pipefail` (no `-e`); override → exit 0 (L26); sentinel dir self-created under `$HOME`, overridable via `POST_COMPACT_SESS_DIR` (L33), all writes `|| true` (L92-93,105-106); python3 guarded with grep/sed fallback (L41-46); EVERY path exits 0 — the reminder can never wedge a session.
  - `grep -nE '/Users/[a-zA-Z0-9._-]+/'` over both source hooks → no hits (exit 1). No home-path literals.
- **hooks.json wiring — matchers + args correct against the source.** Source consumes `--prompt-mode` (UserPromptSubmit, L30), `--clear-mode` (SessionStart:clear, plant-only, L31), no-arg (SessionStart:compact primary, emits, L89-97). Plan's mapping matches exactly; SessionStart carries BOTH `compact` + `clear` matchers (AC4); new no-matcher Stop/UserPromptSubmit blocks mirror the existing SubagentStop no-matcher shape.
- **Version + drift — confirmed.** `git tag -l` includes `v0.8.0` AND `v0.8.1` → `0.9.0` is the correct non-colliding next MINOR. `plugin.json`=`0.7.0` (stale), `package.json`=`0.8.1`; plan sets BOTH to `0.9.0` (AC8), repairing the drift. The brief's 0.8.0 would have collided — plan correctly overrides it.
- **Doctrine doc** source exists, `grep /Users/` → no hits; AC5 requires the Packaging note + ScheduleWakeup caveat (verifiable).
- **CI** (`ci.yml` + `ci-validate.mjs`): `bash -n` on every `hooks/*.sh`; smokes auto-discovered from `hooks/_smoke/*.sh`, run with `CLAUDE_PLUGIN_ROOT=$GITHUB_WORKSPACE`; Conventional-Commit check (push only) accepts the `feat:` subject. Deliverables pass.
- **AC12** (resume-sequencer smoke) is both-ends + non-vacuous: emit cases (primary; prompt+resume) AND no-emit cases (empty stdin, non-resume prompt with sentinel intact, override); uses `POST_COMPACT_SESS_DIR=$(mktemp -d)` so real `$HOME` is untouched.

### Findings

**[MED — blocking] AC11 smoke lacks a per-disjunct positive fixture for the `NOW_OR_LATER` disjunct.** (AC11, fire-case bullet)
The fire condition is `((PROCEED or NOW_OR_LATER) and has_q) or LMK` — THREE positive disjuncts: D1 `PROCEED+?`, D2 `NOW_OR_LATER+?`, D3 `LMK`. AC11 supplies fixtures for D1 (`Should I ship #1258 now?`) and D3 (`Let me know if you want me to continue.`) but NOT D2. Per the OR-gate lesson (`feedback_or_gate_fire_condition_needs_per_disjunct_positive_fixture`, #1179), a partial positive set can't catch a single-disjunct regression. D2 is the **canonical motivating incident** ("ship #623 now, or pick it up later?" — a pure NOW_OR_LATER shape `PROCEED` does NOT match), so the smoke as written would stay green through a regression of the exact shape this hook exists to catch. Gating NEEDS-WORK because the fix is one trivial line and the brief explicitly elevated per-disjunct coverage.
**Fix (mechanical):** add to AC11's fire-case bullet — `AND a NOW_OR_LATER offer with no PROCEED lead-in and no LMK (e.g. {"last_assistant_message":"Roll out #1258 now, or hold it until later?"}) -> exit 2 (covers the third OR-disjunct — the #623 'now, or later?' shape PROCEED does not match)`. Verified: this string matches `NOW_OR_LATER` + `has_q` and does NOT match `PROCEED`.

**[LOW — advisory] CHANGELOG style mismatch + insertion point.** AC10 cites the hand-written `[0.7.0]`/`[0.6.0]` "Keep a Changelog" style, but the CURRENT top entries (`[0.8.1]`, `[0.8.0]`) use the release-please compare-link style (`## [0.8.1](…compare…) (date)` + `### Features`). Insert `## [0.9.0] - 2026-06-26` at the TOP (above `[0.8.1]`), not after `[0.7.0]`. AC10's grep passes either way; non-blocking.

**[LOW — advisory] hooks.json validity is not covered by CI.** `ci-validate.mjs` validates only `plugin.json` + `marketplace.json` and never parses `hooks.json`. AC3 (`node -e ... require('./hooks/hooks.json')`) is the SOLE gate on the new JSON — fine as long as AC3 is actually run at gate time. No change required; flagging so the executor does not assume CI catches a malformed hooks.json.

**[LOW — advisory] Stop-check stderr still references the private memory pointer `feedback_no_stop_for_already_approved_step`.** On a bare host this is a dangling reference, but only inside the exit-2 BLOCK message — printed text, not a file read, so it neither errors nor blocks. Plan already lists the repoint as optional; acceptable to ship verbatim.

**Required to flip to PASS:** apply the MED fix above (one fixture line in AC11). LOW items are advisory.
