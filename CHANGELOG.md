## [0.11.0] - 2026-07-04

### Added
- **Per-role MODEL-VERSION pins (assert-latest / fail-on-drift)** — completes the
  per-role control surface alongside the existing MODEL TIER lever. `config/cc-roles.env`
  gains a per-TIER concrete-version pin table (`CC_TIER_OPUS_VERSION`,
  `CC_TIER_SONNET_VERSION`, `CC_TIER_HAIKU_VERSION`, `CC_TIER_FABLE_VERSION`, seeded with
  the current-latest ids) plus an optional per-ROLE assertion override
  (`CC_ROLE_<ROLE>_MODEL_VERSION`, default unset). A tier alias (`sonnet`) always
  resolves to the tier's LATEST concrete version at spawn time, revealed only in the
  subagent transcript's `message.model` — so the platform can silently bump a tier's
  latest without any visible signal. The completion-time `check --enforce-role-models`
  leg in `bin/3role-ledger.mjs` now compares the transcript's actual model id to the
  configured pin (inside the already-matched-tier branch, so a genuine tier mismatch
  stays the headline `MODEL-POLICY:` problem and version is never double-reported): a
  mismatch pushes a `MODEL-VERSION:` problem -> exit 2. No pin configured for a
  tier/role leaves the version sub-leg DORMANT (no behavior change) so a consumer can
  adopt tier enforcement without opting into drift-detection. Fail-CLOSED on
  can't-tell (unreadable/unparseable transcript model) ONLY when a pin is configured.
- `hooks/three-role-instrumentation-gate.sh` routes a `MODEL-VERSION:` ledger problem
  to a distinct `block_version` message (a version drift means "update the pin
  deliberately," never "just re-run the role" — `block_model` stays the tier-mismatch
  message). Dedicated kill-switch `CC_ROLE_VERSION_GATE_OFF=1` disables ONLY the
  version sub-leg; `CC_ROLE_MODEL_GATE_OFF=1` still disables the whole model+version
  leg. The leading-edge `hooks/three-role-model-policy-gate.sh` is UNCHANGED — at
  spawn time the tool sees a tier alias, never a concrete version, so it structurally
  cannot check version drift (completion-time-only by design, not an omission).
- `bin/3role-ledger.mjs` gains an `INVALID-VERSION` config lint (a `CC_TIER_*_VERSION`
  or `CC_ROLE_*_MODEL_VERSION` value that doesn't look like a concrete `claude-*` id)
  and a `resolve-role-model` role list extended to name the new `research` seat.
- **New seat: `research`/search** — `config/cc-roles.env` adds
  `CC_ROLE_RESEARCH_MODEL=sonnet` + `CC_ROLE_RESEARCH_EFFORT=high` for the ad-hoc
  Explore/research subagents. Not one of the four transcript-enforced roles, so it is
  resolvable at spawn time but never completion-gate-blocked.
- **Seat-value tweaks**: `CC_ROLE_ORCHESTRATOR_EFFORT` `high` -> `xhigh`;
  `CC_ROLE_EXECUTOR_EFFORT` `medium` -> `high`.
- **Effort-honesty documentation**: `config/cc-roles.env`'s header now carries a
  per-lever enforcement matrix stating exactly which of MODEL TIER / MODEL VERSION /
  EFFORT is a mechanical hard block vs an advisory note. EFFORT remains advisory/doc-only
  for Agent-spawned roles (the spawn tool has no effort param and the transcript never
  records it) — no gate anywhere pretends to enforce it. A documented forward CONTRACT
  covers the Workflow `agent()` API (which DOES accept an effort param): any future
  call site for a chain role must resolve `--with-effort` and pass it through.
- Both `hooks/_smoke/3role-ledger-smoke-test.sh` and
  `hooks/_smoke/three-role-instrumentation-gate-smoke-test.sh` gain both-ends coverage
  for the version leg on a DEDICATED pinned fixture (RED drift / GREEN match / no-pin
  dormant / fail-closed can't-tell / both kill-switches) — the pre-existing pin-free
  `claude-sonnet-4-6` tier arms are untouched and stay green, proving the tier leg is
  version-agnostic.

## [0.10.0] - 2026-07-03

### Added
- **Per-role model policy** — a config-driven control surface that pins each role
  in the chain (orchestrator, planner, plan-review, executor, execution-review)
  to a model tier, with the tier MECHANICALLY enforced against the subagent's
  actual transcript `message.model`. New file `config/cc-roles.env` holds the
  per-role `_MODEL` (enforced) and `_EFFORT` (doc/spawn-advisory only — the Agent
  spawn tool has a `model` param but no `effort` param) settings. FAIL-SAFE is
  `opus` — a missing/garbled config never fails open to a cheaper tier.
- New hook `hooks/three-role-model-policy-gate.sh` (PreToolUse `Agent|Task`,
  leading-edge, block-once advisory) — surfaces the resolved per-role model when a
  role subagent is spawned on a tier that disagrees with policy. Kill-switch
  `CC_ROLE_MODEL_GATE_OFF=1`; `SHIP_PIPELINE=1` exempts.
- `bin/3role-ledger.mjs` gains `resolve-role-model`, model-policy lint, and an
  opt-in completion-time enforcement leg (`--enforce-role-models`) reused by the
  instrumentation gate. Kill-switch `THREE_ROLE_INSTRUMENT_OFF=1`.
- A portability smoke test under `hooks/_smoke/` covering the model-policy gate's
  no-op / bypass / fire / fail-safe paths.

## [0.9.0] - 2026-06-26

### Added
- **Autonomous Pipeline Mode** — the "approve once, then run the pipeline"
  discipline, packaged alongside the 3-role model. Two new hooks:
  - `hooks/autonomous-approval-stop-check.sh` — a `Stop` hook that catches a turn
    ending by asking the operator to approve continuing its OWN next step (e.g.
    "should I ship X now, or later?") when that step is already in the approved
    plan or a standing workflow. Blocks once (loop-safe), degrades to a no-op on
    a host without the author's infra, and carries the `AUTONOMOUS_STOP_OVERRIDE=1`
    single-use override.
  - `hooks/post-compact-resume-sequencer.sh` — surfaces the Post-Compact Resume &
    Sequencing Protocol (ELI5 the plan + re-sequence remaining work into 3 tiers +
    one approve-gate) at `SessionStart` for the `compact` and `clear` matchers and
    via a `UserPromptSubmit` resume-intent backstop. Non-blocking (always exits 0);
    sentinel dir is overridable via `POST_COMPACT_SESS_DIR`.
- **Bundled doctrine** `post-compact-resume-sequencing-protocol.md` at the repo
  root, with a Packaging note clarifying that the scheduled "wake up and continue"
  autonomous-loop tick is a Claude Code runtime feature and is NOT packaged by this
  plugin.
- Two portability smoke tests under `hooks/_smoke/` (auto-discovered by CI),
  covering the no-op / bypass / fire paths of both hooks — the stop-check smoke
  asserts a positive fixture for each of the three fire-condition OR-disjuncts.
- `hooks/hooks.json` gains `Stop`, `SessionStart` (compact + clear matchers), and
  `UserPromptSubmit` registrations, all via `${CLAUDE_PLUGIN_ROOT}`.

### Changed
- `plugin.json` version corrected to `0.9.0` (it had drifted to `0.7.0` behind the
  `package.json` / git-tag release line) and `package.json` bumped in lockstep.
  Both manifest descriptions now mention Autonomous Pipeline Mode.

## [0.8.1](https://github.com/ziyilam3999/three-role-model/compare/v0.8.0...v0.8.1) (2026-06-21)

### Chore

* sync canonical from ai-brain #1100 Slice 1 — agent self-record + self_authored provenance + CODEWORK released?-arm regex tighten + subagent-ledger overlay (#15)

## [0.8.0](https://github.com/ziyilam3999/three-role-model/compare/v0.7.0...v0.8.0) (2026-06-21)

### Features

* **sync:** regenerate ported hooks/ledger from ai-brain canonical (v0.66) — brings the plugin current with the #1098 opt-IN→opt-OUT fail-closed instrumentation gate (now 11 fail-closed markers / 265 lines), the ledger `--verdict` field, and the #897 worktree-path warn. Generated by the deterministic sync transform; a drift-gate in ai-brain CI now prevents future divergence. ([#13](https://github.com/ziyilam3999/three-role-model/pull/13))

# Changelog

All notable changes to the three-role-model plugin are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and the
project adheres to [Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-06-14

### Added
- **Ignore-orientation preamble for spawned subagent prompts.** Both the
  bundled stateless reviewer prompt (`skills/ship/references/reviewer-prompt.md`)
  and the scaffold agent template (`templates/agent.md.tmpl`) now open with a
  preamble that tells a one-shot role subagent to IGNORE any post-compact
  resume protocol, orientation block, or "ELI5 the plan + 3-tier" instruction
  that leaks into its context — it targets the main session, not the subagent.
  This hardens role subagents (which share the parent session id) against being
  derailed into reconciling a TaskList or presenting a tiered plan instead of
  doing the single task they were briefed for. The main-session scaffold
  command template is deliberately left untouched, because a slash command runs
  in the main session where the resume protocol legitimately should fire.

## [0.6.0] - 2026-06-14

### Added
- **Build leg 6 — install-proven and parity-synced.** The bundled
  `bin/3role-ledger.mjs` now carries the `inherit-plan-review` subcommand,
  bringing it to parity with the upstream ledger: it copies a parent task's
  verified planner + plan-review onto a child leg and fails closed unless the
  parent review resolves to a real subagent transcript. `cmdAppend` was
  refactored to share the same overlay-merge core.
- **Live install proof** under `hooks/_smoke/`: a runbook plus a scrubbed
  transcript of validating, marketplace-adding, installing, listing, and
  inspecting the plugin in a sandbox config dir — a hook fires from the
  installed cache with `${CLAUDE_PLUGIN_ROOT}` resolved, and the ledger CLI
  round-trips from the installed copy.

### Changed
- **README** finalized with the two install commands, the env-var config table
  (`THREE_ROLE_LEDGER_DIR` / `THREE_ROLE_PROJECTS_ROOT` / `CAIRN_PERSIST_ROOT`),
  the `${CLAUDE_PLUGIN_ROOT}` portability note, and the doctrine link.
- **`hooks/three-role-transition-gate.sh`** BLOCK message now points to
  `inherit-plan-review … --parent <parentTaskId>`.
- **`.claude-plugin/marketplace.json`** gained a top-level `description` so
  `claude plugin validate --strict` passes.

## [0.5.0] - 2026-06-14

### Added
- **Build leg 5 — the default mechanism.** Added `/three-role-model:scaffold
  <kind> <name>`, the command that stamps out a new skill, command, hook, or
  agent from a pre-wired template, plus the four `templates/*.tmpl` it copies.
  Each template ships a real `## Execution model` block (placement + evaluator
  keywords, so the generated artifact passes the plan-shape gate out of the
  box), the role-ledger spawn snippet citing
  `${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs`, and a doctrine pointer; the
  hook template also carries a ready `hooks.json` entry stub.
- **The default-development-model doctrine line** in both `3-role-model.md` and
  `README.md`: new primitives run through the 3-role model by default and are
  scaffolded pre-wired — hand-writing one that skips the model is the exception.

## [0.4.0] - 2026-06-14

### Added
- **Build leg 4 — the standalone doctrine.** Replaced the placeholder
  `3-role-model.md` with the full, self-contained doctrine for the 3-role
  development model: the planner → plan-review → executor → execution-review
  flow, the two knobs (executor placement / evaluator) as tables, the role
  invariants (never self-review, stateless reviewers, search-memory-first,
  instrumented ledger), the skills-as-role-primitives mapping, role-tooling
  rules, the never-background-and-end rule, and the four not-briefable inline
  criteria. Written to be understood by a reader with no external context; all
  bundled-artifact references use `${CLAUDE_PLUGIN_ROOT}`.

## [0.3.0] - 2026-06-14

### Added
- **Build leg 3 — the workflow skills + bundled memory search.** Ported the 7
  role/workflow skills (issue-to-ship, auto-flow, delegate, per-task-review-loop,
  ship, coherent-plan, double-critique) with every ledger/memory invocation
  re-pathed to `${CLAUDE_PLUGIN_ROOT}`, and bundled a self-contained cairn search
  shim (`bin/cairn-find.mjs` + `bin/cairn-lib/`) so the search-before-plan step
  works with zero external dependencies.

### Changed
- **`/ship` made portable for public use.** Removed the private employer-brand
  denylist gate entirely; the repo-specific release + index-check gates now
  degrade-skip when their helper is absent, so `/ship` runs anywhere.

## [0.2.0] - 2026-06-14

### Added
- **Build leg 2 — the role-enforcing hooks.** Ported all 10 three-role hooks
  (plan/review/execute/ship gates, the transition + completion + instrumentation
  gates, the SubagentStop ledger + background-orphan guard) plus the
  forgery-resistant role-ledger CLI (`bin/3role-ledger.mjs`) and `hooks/hooks.json`
  bindings. Every hook resolves its paths via `${CLAUDE_PLUGIN_ROOT}` with a
  relative-path fallback, so the plugin works from the install cache on any machine.
- 9 smoke tests covering the ported hooks (all green in CI with
  `CLAUDE_PLUGIN_ROOT` set to the workspace).

## [0.1.0] - 2026-06-14

### Added
- Initial public scaffold: plugin manifest (`.claude-plugin/plugin.json`),
  single-plugin marketplace (`.claude-plugin/marketplace.json`), CI workflow,
  PR + issue templates, MIT license, and the plugin directory skeleton
  (`hooks/`, `bin/`, `skills/`, `commands/`, `templates/`).
- `scripts/ci-validate.mjs` — zero-dependency manifest + bin syntax/test gate.

_The role-enforcing hooks, orchestration skills, the bundled memory-search
shim, the standalone doctrine, and the scaffolding command land in the
subsequent build legs (see the README roadmap)._
