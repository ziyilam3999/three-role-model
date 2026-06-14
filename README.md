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

## Install

```
claude plugin marketplace add ziyilam3999/three-role-model
claude plugin install three-role-model@three-role-model
```

The first command registers this GitHub repo as a single-plugin marketplace; the second installs the plugin
into your Claude Code config. To develop against a **local clone** instead of the public repo, point the
marketplace at the clone's path:

```
claude plugin marketplace add /path/to/your/clone/of/three-role-model
claude plugin install three-role-model@three-role-model
```

Verify it landed with `claude plugin list --json` and `claude plugin details three-role-model`. Skills then
invoke as `/three-role-model:<skill>` (auto-namespaced). A project's own `.claude/` always overrides the
plugin. Plugin hooks **compose** with your existing `settings.json` hooks (both fire).

## Configuration (env vars)

Every path the plugin touches is an env var with a sane default — set them to point the plugin at your own
dirs; leave them unset to use the defaults.

| Env var | What it controls | Default |
|---|---|---|
| `THREE_ROLE_LEDGER_DIR` | Where the per-task role-ledger JSONL files are written + read (the forgery-resistant "which roles actually ran" record). | `~/.claude/3role-ledger` |
| `THREE_ROLE_PROJECTS_ROOT` | Where the ledger looks for the real subagent-spawn transcripts (`*/<session>/subagents/agent-<id>.jsonl`) it resolves an `agentId` against. | `~/.claude/projects` |
| `CAIRN_PERSIST_ROOT` | Root of the memory knowledge base the bundled cairn-search shim reads (T2 session-notes + T3 knowledge-base). | a `hive-mind-persist/` directory resolved relative to the bundled shim (the plugin's own root) |

## Portability — `${CLAUDE_PLUGIN_ROOT}`

Every hook and bundled script resolves its files via `${CLAUDE_PLUGIN_ROOT}` — the directory Claude Code
installs the plugin into. So the plugin runs from the install cache on any machine with **no per-user symlink
wiring and no edits to a global `CLAUDE.md`**. A hook bound in `hooks/hooks.json` (e.g.
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/enforce-plan.sh"`) finds its bundled siblings (`bin/3role-ledger.mjs`, the
other hooks) wherever the cache lands. Nothing is hard-coded to a home directory.

## What's inside

| Path | What |
|---|---|
| `.claude-plugin/plugin.json` | the plugin manifest |
| `.claude-plugin/marketplace.json` | single-plugin marketplace (`claude plugin marketplace add`) |
| `hooks/` | the role-enforcing hooks + `hooks.json` bindings |
| `bin/` | the role-ledger CLI + a bundled, dependency-free memory-search shim |
| `skills/` | the orchestration skills (plan-review, execute, ship, …) |
| `commands/` | `/three-role-model:scaffold` — stamps new primitives pre-wired to the model |
| `templates/` | the pre-wired skeletons the scaffold command emits |
| `3-role-model.md` | the standalone doctrine |

There is **no `agents/` directory, on purpose.** The four roles are not pre-declared agent files — the
orchestrator spawns each role on demand via the Agent tool (a full-tool agent for the writer roles, a
read-only `Explore` agent for the reviewers), tagging each spawn so the role-ledger can bind it to a real
transcript. Read **[`3-role-model.md`](./3-role-model.md)** for the full doctrine — roles, the two knobs, the
never-self-review invariant, and how the hooks + ledger enforce it.

## The default development model

> **Default development model.** Every non-trivial skill, agent, hook, or command authored in a workspace that installs this plugin runs through the 3-role model — planner → plan-review → executor → execution-review, each a separate subagent, never self-review. New primitives are scaffolded pre-wired via `/three-role-model:scaffold <skill|agent|hook|command> <name>`; the generated skeleton already carries its `## Execution model` shape declaration, the role-ledger spawn snippet, and this doctrine pointer. Hand-writing a primitive that skips the model is the exception, not the default.

## Walkthrough

A longer walkthrough post is tracked as a follow-up.

## License

[MIT](./LICENSE).
