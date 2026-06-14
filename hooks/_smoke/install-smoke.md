# Live install smoke — three-role-model plugin

A scriptable, headless proof that a stranger's install of the `three-role-model`
Claude Code plugin works end-to-end: validate -> add marketplace -> install ->
list/details -> a bundled hook fires live with `${CLAUDE_PLUGIN_ROOT}` resolved ->
the bundled ledger CLI writes+reads under a configured dir (incl. the
`inherit-plan-review` subcommand). Captured output lives in
`install-smoke-transcript.txt` (same dir).

This is the Rule-18 prove-primary for the plugin: a real `claude plugin install`
into a throwaway config dir + real hook/ledger runs from the installed cache copy —
NOT a fixture parse.

## How it runs (headless, no TTY needed)

The whole `claude plugin` surface is scriptable. We sandbox the install with a
throwaway `CLAUDE_CONFIG_DIR` so nothing touches the real user config.

```bash
# 1) throwaway sandbox config dir
SANDBOX=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$SANDBOX/config"
mkdir -p "$CLAUDE_CONFIG_DIR"

# The marketplace SOURCE. Two forms:
#   - public (what a stranger uses):  ziyilam3999/three-role-model   (a GitHub repo)
#   - local/dev (what this smoke uses): a path to a local clone/worktree of this repo
REPO=<path-to-a-local-clone-of-this-repo>   # the local clone IS the marketplace (marketplace.json source = "./")

# 2) validate the manifest (strict = warnings are errors)
claude plugin validate "$REPO"
claude plugin validate --strict "$REPO"

# 3) add the local marketplace + install
claude plugin marketplace add "$REPO"
claude plugin install three-role-model@three-role-model --scope user

# 4) prove it's installed
claude plugin list --json
claude plugin details three-role-model
```

### Locate the install cache (where `${CLAUDE_PLUGIN_ROOT}` resolves)

`claude plugin list --json` reports `installPath`. For a sandboxed install it is:

```
$CLAUDE_CONFIG_DIR/plugins/cache/three-role-model/three-role-model/<version>
```

Export it for the runtime ACs below:

```bash
CACHE="$CLAUDE_CONFIG_DIR/plugins/cache/three-role-model/three-role-model/0.5.0"
```

## The three runtime ACs

### AC-a — installed + components registered
`claude plugin list --json` shows `three-role-model@three-role-model`,
`enabled: true`. `claude plugin details three-role-model` shows the inventory:
8 skills (auto-flow, coherent-plan, delegate, double-critique, issue-to-ship,
per-task-review-loop, scaffold, ship), 2 hook events (PreToolUse, SubagentStop),
0 agents (deliberate — roles spawn via the Agent tool).

### AC-b — a bundled hook fires LIVE with `${CLAUDE_PLUGIN_ROOT}` resolved
Fire one hook from the installed cache copy with `CLAUDE_PLUGIN_ROOT` set to the
cache path, against a synthetic event. A Write of a NEW
`.ai-workspace/plans/x.md` with NO `## Execution model` section must BLOCK (exit 2):

```bash
PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"/tmp/does-not-exist/.ai-workspace/plans/x.md","content":"# A plan\n\nNo execution model heading.\n"}}'
CLAUDE_PLUGIN_ROOT="$CACHE" bash "$CACHE/hooks/enforce-plan.sh" <<< "$PAYLOAD"
echo "exit=$?"   # expect 2 (BLOCK)
```

This is the Rule-18 live tool-run: it proves the installed copy runs with the
variable resolved (not a repo-relative fixture parse).

### AC-c — the ledger CLI writes+reads under a configured dir (incl. inherit-plan-review)
Point `THREE_ROLE_LEDGER_DIR` / `THREE_ROLE_PROJECTS_ROOT` at the sandbox and
round-trip the installed cache copy of `bin/3role-ledger.mjs`:

```bash
LEDGER="$SANDBOX/ledger"; PROJ="$SANDBOX/projects"; SESS=s1
# basic append + check (reports missing other roles — expected)
THREE_ROLE_LEDGER_DIR="$LEDGER" THREE_ROLE_PROJECTS_ROOT="$PROJ" \
  node "$CACHE/bin/3role-ledger.mjs" append --session $SESS --task t1 --role planner --agent a1 --artifact <some-file>
THREE_ROLE_LEDGER_DIR="$LEDGER" THREE_ROLE_PROJECTS_ROOT="$PROJ" \
  node "$CACHE/bin/3role-ledger.mjs" check --session $SESS --task t1

# inherit-plan-review: a parent task with a transcript-backed planner+plan-review
# is inherited onto a leg, leaving only executor+execution-review to satisfy.
#   (the smoke seeds fake subagent transcripts under $PROJ/.../<sess>/subagents/
#    and PASS-bearing artifacts, then:)
node "$CACHE/bin/3role-ledger.mjs" inherit-plan-review --session $SESS --task leg1 --parent parent
node "$CACHE/bin/3role-ledger.mjs" check --session $SESS --task leg1
#   -> BLOCK: missing executor ledger line; missing execution-review ledger line
#      (planner+plan-review satisfied via inheritance — proves the fold shipped)
```

## Cleanup

```bash
claude plugin uninstall three-role-model --scope user -y
claude plugin marketplace remove three-role-model
# the sandbox is a system mktemp dir; mv it to quarantine if you want it gone (Rule 14 — never rm)
```

## Result of the captured run (see install-smoke-transcript.txt)

The live install genuinely worked, no substitution: validate passed (and
`--strict` passes once the marketplace has a `description`), marketplace add +
install succeeded, `list --json` showed it enabled, `details` showed the full
inventory, `enforce-plan.sh` BLOCKED with exit 2 from the cache copy with
`${CLAUDE_PLUGIN_ROOT}` resolved, and the ledger CLI (incl. `inherit-plan-review`)
round-tripped under `THREE_ROLE_LEDGER_DIR`. Uninstall + marketplace remove left
`plugin list --json` == `[]`.

Substitution note: the captured run used a LOCAL clone path as the marketplace
source (the dev/local-path form) rather than the public GitHub source, because the
fold under test is not yet on the public repo. The public install path is identical
except `REPO` becomes the GitHub repo `ziyilam3999/three-role-model`. Sandbox
`/var/folders/...` mktemp paths and the resolved cache path in the transcript are
machine output; home-dir paths were scrubbed to `<REPO>` / `<HOME>`.
