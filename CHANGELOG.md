# Changelog

All notable changes to the three-role-model plugin are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and the
project adheres to [Semantic Versioning](https://semver.org/).

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
