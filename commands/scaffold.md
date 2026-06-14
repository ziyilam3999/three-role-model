---
description: Stamp out a new primitive (skill / agent / hook / command) already pre-wired to the 3-role development model.
---

# /three-role-model:scaffold

Create a new plugin primitive from a pre-wired template, so a freshly authored skill,
agent, hook, or command is correct-by-default under the 3-role development model.

## Usage

```
/three-role-model:scaffold <kind> <name>
```

- `<kind>` — one of `skill`, `agent`, `hook`, `command`.
- `<name>` — the primitive's name (a short kebab-case slug, e.g. `release-notes`).

If `<kind>` is not one of the four known kinds, or `<name>` is missing, print a one-line
usage message naming the four kinds and stop without writing anything.

## What it does

Copy the matching template at `${CLAUDE_PLUGIN_ROOT}/templates/<kind>.*.tmpl` to the right
destination, substituting every `__NAME__` placeholder token with `<name>`:

| kind | template | destination |
|---|---|---|
| `skill` | `templates/skill.SKILL.md.tmpl` | `skills/<name>/SKILL.md` |
| `command` | `templates/command.md.tmpl` | `commands/<name>.md` |
| `hook` | `templates/hook.sh.tmpl` | `hooks/<name>.sh` |
| `agent` | `templates/agent.md.tmpl` | `agents/<name>.md` |

Mechanically:

1. Resolve the template path under `${CLAUDE_PLUGIN_ROOT}/templates/`. If it is missing,
   stop and report which template was not found.
2. Create the destination directory if needed (`skills/<name>/` for a skill).
3. Refuse to overwrite an existing destination file — if it already exists, stop and tell
   the user the path, rather than clobbering their work.
4. Substitute `__NAME__` -> `<name>` throughout the template body
   (`sed 's/__NAME__/<name>/g'` is the canonical substitution) and write the result to the
   destination.
5. **For `hook` only**, also wire it up: the template carries a ready-to-paste `hooks.json`
   entry stub (its `command` is `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`). Append that
   entry to the appropriate matcher block in `hooks/hooks.json` so the new hook actually
   fires. If you cannot determine the right matcher, leave the stub in the generated file's
   header comment and tell the user to wire it manually.
6. Make a generated `hook` executable (`chmod +x hooks/<name>.sh`).

After writing, print the destination path and a one-line reminder that the generated
skeleton still has `TODO` markers to fill in.

## Why the templates are pre-wired

Every template ships already carrying the 3-role model's shape so a new primitive is
correct by default — you do not have to remember to add any of it:

- a **`## Execution model`** block that declares both an executor-placement keyword
  (`delegate`) and an evaluator keyword (`reviewer`) — the load-bearing shape declaration
  the model's gates recognize;
- the **role-ledger spawn snippet** — the `3ROLE_TASK:<id> ROLE:<role>` tag line plus the
  `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append …` lines the orchestrator uses
  to record each role;
- a one-line **doctrine pointer** to `${CLAUDE_PLUGIN_ROOT}/3-role-model.md`.

So scaffolding a primitive is the default way to author one — the model is baked in, not
bolted on. Hand-writing a primitive that skips the model is the exception, not the default.
