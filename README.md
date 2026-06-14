# three-role-model

A [Claude Code](https://claude.com/claude-code) **plugin** that packages the **3-role development model** —
a way of building software where four separate AI subagents each do one job and *nobody grades their own
homework*:

```
planner  ->  plan-review  ->  executor  ->  execution-review
 (what)      (vet the plan)    (the how)     (vet the result)
```

The orchestrator coordinates; each role is an independent subagent. Two knobs pick the shape per task:
**executor placement** (test-loop / one subagent / parallel / inline) and **evaluator** (a real passing test
/ an independent reviewer / both). The model is mechanically enforced by hooks and recorded in a
forgery-resistant role-ledger, so "we followed the process" is provable, not claimed.

> **Status: building in public.** This repo is being assembled leg-by-leg (see the roadmap). The
> scaffold + CI + manifests are live now; the role-enforcing hooks, the orchestration skills, the bundled
> memory-search shim, the standalone doctrine, and the scaffolding command land in the following legs, each
> as its own PR + release bump.

## Install (once the legs land)

```
/plugin marketplace add ziyilam3999/three-role-model
/plugin install three-role-model@three-role-model
```

Skills then invoke as `/three-role-model:<skill>` (auto-namespaced). A project's own `.claude/` always
overrides the plugin. Plugin hooks **compose** with your existing `settings.json` hooks (both fire).

## What's inside (target layout)

| Path | What |
|---|---|
| `.claude-plugin/plugin.json` | the plugin manifest |
| `.claude-plugin/marketplace.json` | single-plugin marketplace (`/plugin marketplace add`) |
| `hooks/` | the role-enforcing hooks + `hooks.json` bindings |
| `bin/` | the role-ledger CLI + a bundled, dependency-free memory-search shim |
| `skills/` | the orchestration skills (plan-review, execute, ship, …) |
| `commands/` | `/three-role-model:scaffold` — stamps new primitives pre-wired to the model |
| `templates/` | the pre-wired skeletons the scaffold command emits |
| `3-role-model.md` | the standalone doctrine |

## Portability

Every hook and bundled script resolves its paths via `${CLAUDE_PLUGIN_ROOT}` (the directory the plugin is
installed into), so the plugin works from the plugin cache on any machine — no per-user symlink setup. The
role-ledger directory and the memory-search root are configurable env vars with sane defaults; see each
leg's docs as they land.

## Build roadmap

1. **Scaffold + manifests** ✅ (this release)
2. **Port + re-path the role-enforcing hooks**
3. **Port the orchestration skills + bundle the memory-search shim**
4. **Extract the standalone `3-role-model.md` doctrine**
5. **The `/three-role-model:scaffold` command + the default-doctrine line**
6. **Live install test + finalized docs**

## License

[MIT](./LICENSE).
