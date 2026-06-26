# Execution Review — #1258 Autonomous Pipeline Mode plugin packaging

Decision: PASS

- **Role:** execution-review (stateless, independent — did NOT write this code)
- **Commit:** `dddef4c` on `feat/autonomous-pipeline-mode`
- **Plan:** `<repo>/.ai-workspace/plans/2026-06-26-1258-autonomous-pipeline-mode-plugin.md`
- **Method:** every check below was INDEPENDENTLY RE-RUN in the worktree; output pasted, not trusted.

## cairn grounding
`node skills/cairn/bin/cairn-find.mjs "plugin"` + `"portable"` (node CLI, run from the ai-brain repo root). HIT (T1, 2026-06-26):
> "When packaging hooks as a Claude Code plugin for others, verify they degrade gracefully [on a host without the author's infra]"
and
> "When bumping version for a Claude Code plugin, check BOTH `plugin.json` AND `package.json`".
Both directly motivate this review's portability crux (check 5) and version check (check 4).

## The 7 checks

### 1. Both new smokes PASS — including the D2 NOW_OR_LATER per-disjunct fixture — PASS
Ran both with `CLAUDE_PLUGIN_ROOT=<repo>`:
- `autonomous-approval-stop-check-smoke-test.sh` → `8/8 PASS`, exit 0. Covers ALL three fire OR-disjuncts: D1 (`Should I ship #1258 now?` → exit 2 + BLOCKED), **D2 (`Roll out #1258 now, or hold it until later?` → exit 2 + BLOCKED)**, D3 (`Let me know if you want me to continue.` → exit 2). D2 is present in the script (lines 53-57) and asserts `RC == 2` + `BLOCKED` on stderr — the #1179 OR-gate lesson is satisfied (the plan-review MED fold landed).
- `post-compact-resume-sequencer-smoke-test.sh` → `5/5 PASS`, exit 0.

### 2. Full CI-equivalent green — PASS
- `npm test` (= `node scripts/ci-validate.mjs`): `ci-validate: PASS` (plugin.json v0.9.0 valid, marketplace valid, 5 bin scripts node --check, cairn-find test passed).
- `npm run lint:hooks` (= `bash scripts/lint-hooks.sh`): `bash -n OK` on every hook + smoke incl. the two new ones. No FAIL lines.
- `bash -n` clean on both new hooks individually.

### 3. hooks.json validity + structure — PASS
`JSON.parse(...)` exits 0. Event keys: `PreToolUse, SubagentStop, Stop, SessionStart, UserPromptSubmit`.
- **Stop** → `bash "${CLAUDE_PLUGIN_ROOT}/hooks/autonomous-approval-stop-check.sh"`, timeout 10. ✓
- **SessionStart** has BOTH matchers: `compact` → resume-sequencer (no arg); `clear` → resume-sequencer `--clear-mode`. ✓
- **UserPromptSubmit** → resume-sequencer `--prompt-mode`. ✓
- **Pre-existing blocks intact (not clobbered):** PreToolUse still carries enforce-plan / inline-delegate-nudge / plan-review-before-execute / enforce-ship / enforce-review-or-lfah / three-role-instrumentation-gate / three-role-transition-gate; SubagentStop still carries three-role-subagent-ledger + subagent-bg-orphan-gate. ✓
- Every new block uses `"type":"command"` + `"timeout":10`.

### 4. Versions — PASS
`plugin.json` = `0.9.0`; `package.json` = `0.9.0`; CHANGELOG top entry = `## [0.9.0] - 2026-06-26` (with `### Added`). Tags v0.8.0/v0.8.1 already exist, so 0.9.0 is the correct non-colliding next MINOR and also repairs the stale plugin.json (was 0.7.0). plugin.json `description` mentions "Autonomous Pipeline Mode".

### 5. ★ PORTABILITY (the crux) — PASS
Read BOTH copied hook sources in the plugin `hooks/` dir (not the ai-brain originals):
- **`autonomous-approval-stop-check.sh`** — `set +e` (L28); empty stdin `[ -n "$INPUT" ] || exit 0` (L35); **`command -v python3 ... || exit 0` (L36)** so a host without python3 no-ops; the only external write is `$HOME`-rooted + `2>/dev/null || true`, gated on `AUTONOMOUS_STOP_OVERRIDE=1` (L31); exit 2 ONLY on the intended trigger. No `/Users/` literal, no ai-brain path, no external-file READ.
- **`post-compact-resume-sequencer.sh`** — `set -uo pipefail` (no `-e`, L24); override → exit 0 (L26); sentinel dir is `${POST_COMPACT_SESS_DIR:-$HOME/.claude/cairn/sessions}` — `$HOME`-rooted, overridable, **self-created** `mkdir -p ... || true` (L92,105), every write `|| true` (L93,106); python3 guarded with grep/sed fallback for sid (L41-46), `[ -n "$prompt" ] || exit 0` (L146); EVERY path exits 0. No `/Users/` literal, no hardcoded path, no dependency on any pre-existing infra file.

**PROVEN by execution on a bare host** (`HOME=$(mktemp -d)`, no ai-brain infra):
- stop-check: empty stdin / benign msg / `{}` → all `rc=0`, **zero stderr**.
- stop-check with `PATH=/nonexistent` (no python3) on a fire-shaped input → `rc=0` (clean no-op, does not crash).
- resume-sequencer: primary `{}`, primary `{"session_id":"bare-1"}`, `--prompt-mode {}`, `--clear-mode` → all `rc=0`, zero stderr.
Neither hook can error or exit-nonzero on a bare host for a non-trigger input.

### 6. Privacy (PUBLIC repo) — PASS
`grep -rnE '/Users/[a-zA-Z0-9._-]+/'` on the 5 new files → no output (exit 1). Same ERE over the FULL commit diff `git show dddef4c` → no output (exit 1). No employer/internal proper-noun tokens in the sources (full read of both hooks + doctrine; content is generic workflow-discipline doctrine). Clean.

### 7. Doctrine doc — PASS
`post-compact-resume-sequencing-protocol.md` at repo root carries BOTH:
- `## Packaging note (three-role-model plugin)` (L10), naming the surfacing hook + `${CLAUDE_PLUGIN_ROOT}`.
- `(c) The ScheduleWakeup autonomous-loop "tick" is NOT part of this plugin` (L26) — the runtime-feature caveat, explicit that nothing in the plugin schedules anything.

## Verdict
All of checks 1–7 hold, each independently re-run with pasted evidence. The operator's flagged portability concern is satisfied both by source reading AND by live bare-host execution (including a no-python3 host). **Decision: PASS.**
