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
