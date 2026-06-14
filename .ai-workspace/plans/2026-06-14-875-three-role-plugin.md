# Plan — #875: package the 3-role development model as a public Claude Code plugin

> Planner output for task #875, produced THROUGH the 3-role model. Operator's 4 forks (A/B/C/D) are
> LOCKED in the SEED brief — this plan decomposes the build that satisfies them; it does not re-litigate.
> Companion input: `2026-06-14-875-three-role-plugin-SEED.md`.

## ELI5

We already have a "way of working" that makes our AI build software carefully: one helper writes the plan,
a second helper checks the plan, a third helper writes the code, and a fourth helper checks the code — and
nobody is allowed to grade their own homework. Right now that "way of working" only lives inside OUR private
toolbox (the `ai-brain` repo): a pile of little guard scripts (hooks), a pile of recipe cards (skills), and
a long rulebook page. A stranger can't use it.

We're going to put the whole thing in a **lunchbox** anyone can grab — a Claude Code **plugin** — and leave
that lunchbox on a **public shelf** (a new GitHub repo, `ziyilam3999/three-role-model`). Then anyone can say
two short commands and get all our guard scripts, recipe cards, and the rulebook page installed and working
on THEIR machine.

The hard part: our scripts currently point at hard-coded home addresses ("go to MY house, the `ai-brain`
folder next door"). When you put them in a lunchbox that gets copied to a stranger's computer, those
addresses are wrong. So we re-write every address to say "look inside THIS lunchbox" (the magic word is
`${CLAUDE_PLUGIN_ROOT}`). We also tuck a tiny copy of our memory-search tool (`cairn`) inside the lunchbox so
the "always search memory before planning" rule still works for a stranger who doesn't have our memory.

Finally, we add a **stamp machine**: one new command that, whenever you make a NEW guard script or recipe
card, stamps it so it already follows the 4-helper way of working — plus one sentence in the rulebook that
says "this is the default from now on." Building the lunchbox itself is done USING the 4-helper way of working.

**We do NOT create the public repo or push anything in this plan.** That is a separate, operator-approved
step (it's "outward" — it puts the user's name on a public shelf). This plan only builds the lunchbox
locally and proves it installs.

## Revised sequencing (operator amendment, 2026-06-14 — APPROVED)

The operator approved the 6 legs AND revised the order + **gave explicit authorization to create the public
repo NOW (up-front), not after Leg 6**. New sequence:
1. **Bootstrap (do first):** `gh repo create ziyilam3999/three-role-model --public`, clone, then COPY the repo
   infrastructure from a sibling (forge-harness / content-pipeline): CI workflow, PR template, issue
   templates, internal review, release-version + CHANGELOG mechanism. Push the initial scaffold to master.
   (This merges the plan's Leg 1 with the new infra-copy step; orchestrator-inline = outward + exploratory.)
2. **Iterate Legs 2→6 as PRs**, each shipping via `/ship` (CI + review + squash-merge) and **pumping the
   release version** as we go (like content-pipeline's auto-cut-per-ship). The "publish/repo-creation gated
   until Leg 6 green" line in the original Gated-steps section is SUPERSEDED by this explicit up-front
   authorization — the repo is created first, by operator instruction.
Privacy reaffirmed: the repo is PUBLIC, so every ported hook/skill/doctrine must be scrubbed of the employer
token + absolute home paths + internal #NNN refs before each push (Leg 3 AC 4 / Leg 4 AC 3 enforce it).

## Execution model

**Phased + subagent — run THROUGH the 3-role model.** Six ordered legs (each small enough for one executor).
The orchestrator coordinates only; every leg gets a planner-approved brief, a `delegate` executor (fresh
full-tool subagent — single coherent write surface per leg), and a stateless `Explore` reviewer that did NOT
write the leg (never self-review). No leg is jest-red→green (this repo has no jest project) — the build is
**structural**: shell hooks, node CLIs, markdown doctrine, repo layout. So the evaluator is the **reviewer**,
backed by a **test-oracle wherever one exists for free**: the ai-brain hooks ship companion
`*-smoke-test.sh` scripts and cairn ships `cairn-find.test.mjs` — these PORT alongside their subjects and
become the leg's oracle (re-run them green after re-pathing). Per-leg placement + evaluator:

| Leg | Executor placement | Evaluator | Oracle (if any) |
|---|---|---|---|
| 1 Repo scaffold + manifests | `delegate` | `both` | JSON-schema/`plugin validate` check |
| 2 Port + re-path 10 hooks + hooks.json | `delegate` | `both` | ported `hooks/*-smoke-test.sh` (9 scripts) |
| 3 Port 7 skills + bundle cairn shim | `delegate` | `both` | ported `cairn-find.test.mjs` |
| 4 Extract `3-role-model.md` doctrine | `delegate` | `reviewer` | grep-clean assertions |
| 5 Scaffolding command + doctrine line | `delegate` | `both` | ported `enforce-plan.sh` gate on a generated template |
| 6 Install-test + README (live prove-primary) | `delegate` | `reviewer` + live install smoke | the install smoke IS the oracle (Rule 18) |

Planner = THIS subagent. Plan-review = stateless `Explore` subagent before any leg executes. Each executor =
full-tool (`general-purpose`/`claude`) writer; each leg reviewer = `Explore` (read-only + Bash/Grep/Skill).
Knob rationale: every leg is a single coherent, briefable write surface → `delegate` is the default placement;
no leg splits into disjoint parallel surfaces, so `parallel` is not used; nothing is so coupled to live
session state that it must run `inline`.

## Plugin repo layout (exact tree)

The repo root IS the plugin (single-plugin marketplace). `strict:true` default → `plugin.json` is the source
of truth. ONLY the two manifests live in `.claude-plugin/`; everything else sits at root.

```
three-role-model/                        (repo root = the plugin dir)
├── .claude-plugin/
│   ├── plugin.json                      # manifest: name/description/version (+author/homepage/repo/license)
│   └── marketplace.json                 # lists the one plugin; source = "./" (relative-path, this repo)
├── hooks/
│   ├── hooks.json                       # binds all 10 hooks to events, commands use ${CLAUDE_PLUGIN_ROOT}
│   ├── three-role-transition-gate.sh
│   ├── three-role-instrumentation-gate.sh
│   ├── three-role-subagent-ledger.sh
│   ├── plan-review-before-execute.sh
│   ├── inline-delegate-nudge.sh
│   ├── enforce-review-or-lfah.sh
│   ├── enforce-ship.sh
│   ├── enforce-plan.sh
│   ├── subagent-bg-orphan-gate.sh
│   └── _smoke/                          # ported *-smoke-test.sh oracles (kept out of the hooks scan path)
├── bin/
│   ├── 3role-ledger.mjs                 # the ledger CLI (append/check/resolve-agent)
│   ├── cairn-find.mjs                   # bundled cairn SEARCH shim (the search-before-plan dependency)
│   ├── cairn-lib/                       #   its 3 local libs: paths.mjs, runs.mjs, session-id.mjs
│   └── cairn-find.test.mjs              # ported cairn oracle
├── skills/
│   ├── issue-to-ship/SKILL.md
│   ├── auto-flow/SKILL.md
│   ├── delegate/SKILL.md
│   ├── per-task-review-loop/SKILL.md
│   ├── ship/SKILL.md
│   ├── coherent-plan/SKILL.md
│   └── double-critique/SKILL.md         # (+ any references/ each skill needs, ported verbatim)
├── commands/
│   └── scaffold.md                      # the D-mechanism: /three-role-model:scaffold <kind> <name>
├── templates/                           # pre-wired skeletons the scaffold command stamps out
│   ├── skill.SKILL.md.tmpl
│   ├── command.md.tmpl
│   ├── hook.sh.tmpl
│   └── agent.md.tmpl
├── agents/                              # OMITTED (no files) — roles spawn via the Agent tool, not plugin
│                                        #   agent defs; plugin-agents also can't declare hooks/mcp (SEED §3).
│                                        #   A one-line note in README explains the deliberate absence.
├── 3-role-model.md                      # standalone doctrine (extracted from parent-claude.md)
└── README.md                            # install (marketplace-add + install), portability note, #841 anchor
```

Skills auto-namespace as `/three-role-model:<skill>`; project `.claude/` still overrides the plugin. Plugin
hooks COMPOSE with the user's own settings.json hooks (both fire) — so an ai-brain author who installs the
plugin would double-fire; flagged as an open question for the operator (see Risks R4).

## Per-blocker resolution (all 5)

**Blocker 1 — hard-coded `~/.claude` symlink wiring (setup.sh, 713 lines).** The plugin REPLACES setup.sh
entirely; there is no symlink step. Hook commands move from `bash ~/.claude/hooks/<name>.sh` (settings.json)
to `hooks/hooks.json` entries whose `command` is `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. The hooks'
INTERNAL sibling resolution is already portable for hook→hook (`$(dirname "${BASH_SOURCE[0]}")`), but TWO
hooks resolve the ledger helper as a flat sibling — `three-role-instrumentation-gate.sh:162`
(`LEDGER_HELPER="$(dirname …)/3role-ledger.mjs"`) and `three-role-subagent-ledger.sh:114`
(`HELPER="$(dirname …)/3role-ledger.mjs"`). Because the ledger moves to `bin/`, re-point both to
`"${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"` (with a `$(dirname …)/../bin/3role-ledger.mjs` fallback for
the case `${CLAUDE_PLUGIN_ROOT}` is unset in a SubagentStop shell — see Risk R1). Every in-message advisory
string that prints `node hooks/3role-ledger.mjs …` (instrumentation-gate, transition-gate, the SKILLs)
re-paths to `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" …`.

**Blocker 2 — session-local ledger `~/.claude/3role-ledger/`.** Already env-overridable
(`THREE_ROLE_LEDGER_DIR`, default `~/.claude/3role-ledger`; `THREE_ROLE_PROJECTS_ROOT`, default
`~/.claude/projects`). KEEP both defaults verbatim — `~/.claude/projects` is the REAL Claude Code transcript
location for ANY user (not ai-brain-specific), and `~/.claude/3role-ledger` is a harness-local scratch dir
that is correct for a stranger. Expose `THREE_ROLE_LEDGER_DIR` (and `CAIRN_PERSIST_ROOT`, blocker 5) as
documented plugin **config env vars** in README so power users can relocate them; the sane defaults mean a
stranger needs zero config. No code change beyond documentation.

**Blocker 3 — `parent-claude.md` global doctrine (symlinked to the user's global CLAUDE.md).** The plugin
NEVER touches the user's global CLAUDE.md. Instead Leg 4 extracts a self-contained `3-role-model.md` that
the plugin ships at root. It carries the canonical doctrine verbatim-in-substance: the two knob tables
(executor placement / evaluator), the 4 invariants, the role-tooling rules, the skill-as-role-primitive
mapping, the 4 not-briefable inline criteria, and the new default-doctrine line (Leg 5). Strip every
ai-brain-internal pointer (absolute `~/.claude/...` card paths, `#NNN` PR refs, the employer token — which
must NEVER appear in a public artifact) and replace cross-repo file pointers with `${CLAUDE_PLUGIN_ROOT}`
relative pointers or generic prose.

**Blocker 4 — cross-repo coordination (setup.sh assumes ai-brain sibling; cairn CLI absolute path).** No
sibling assumption survives: skills that today say `node skills/cairn/bin/cairn-find.mjs` (ai-brain-root
relative) re-path to `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs"`. `/ship`'s references to repo-level
helpers (`cairn/bin/phase-b-checks.mjs`, `housekeep/tools/sync-oauth-token.sh`) are made
**degrade-gracefully**: the ported SKILL.md guards each with "if the helper exists run it, else skip" (the
oauth ref already has this shape) so a stranger without those helpers gets a working `/ship` minus the
ai-brain-only gates. There is no `$AI_BRAIN_ROOT` in the shipped plugin — it is eliminated, not
parameterized.

**Blocker 5 — cairn dependency (search-before-plan invariant calls a cairn CLI).** BUNDLE a minimal cairn
SEARCH shim under `bin/`: `cairn-find.mjs` + its three local libs (`paths.mjs`, `runs.mjs`, `session-id.mjs`)
copied to `bin/cairn-lib/` (fix the relative imports accordingly). Verified zero npm dependencies (pure
`node:` builtins) and ~68 KB total, so bundling is cheap and self-contained. The shim searches the user's
OWN memory tiers (`~/.claude/cairn` T1 + `~/.claude/agent-working-memory` WM); its `PERSIST_ROOT` (the T3
knowledge-base) defaults to a walk-up that won't exist in the plugin cache — that's FINE: cairn-find returns
the tiers that DO exist and exits 0 with fewer hits rather than crashing. Expose `CAIRN_PERSIST_ROOT` so a
user with their own KB can point at it. Only the SEARCH path is bundled (the invariant needs find, not
place/promote/status) — this is the "self-contained shim", not the whole cairn skill.

## Leg decomposition

Each leg: scope, files, **binary AC checkable from OUTSIDE the diff**, gated? Legs are ordered; later legs
depend on earlier ones (2 needs 1's tree; 5 needs 2's ported enforce-plan + 4's doctrine; 6 needs all).

### Leg 1 — Repo scaffold + manifests
- **Scope:** create the local plugin directory tree + both manifests + README/LICENSE skeleton. NO git
  remote, NO push.
- **Files:** `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, empty `hooks/`, `bin/`,
  `skills/`, `commands/`, `templates/`, `README.md` (skeleton), `LICENSE`.
- **Binary AC:**
  1. `test -f .claude-plugin/plugin.json && test -f .claude-plugin/marketplace.json` → exit 0.
  2. `node -e "const m=require('./.claude-plugin/plugin.json'); if(!(m.name&&m.description&&m.version))process.exit(1)"`
     → exit 0 (manifest has the 3 required keys; `name` === `three-role-model`).
  3. `node -e "const mk=require('./.claude-plugin/marketplace.json'); if(!Array.isArray(mk.plugins)||!mk.plugins.find(p=>p.name==='three-role-model'))process.exit(1)"`
     → exit 0 (marketplace lists the plugin with a resolvable `source`).
  4. `claude plugin validate .` (if the CLI exposes it) exits 0; else AC 2+3 stand in.
- **Gated?** No (local file authoring only).

### Leg 2 — Port + re-path 10 hooks + hooks.json
- **Scope:** copy the 9 `.sh` hooks + `3role-ledger.mjs`; author `hooks/hooks.json` binding each to its
  event (per the verified ai-brain registrations: `enforce-plan`→PreToolUse `Edit|Write`;
  `inline-delegate-nudge`→PreToolUse `Edit|Write|MultiEdit|NotebookEdit` + Stop + PostToolUse `Agent|Task`;
  `plan-review-before-execute`→PreToolUse `Edit|Write|MultiEdit` + Stop + PostToolUse `Agent|Task`;
  `enforce-ship` + `enforce-review-or-lfah`→PreToolUse `Bash`; `three-role-instrumentation-gate`→PreToolUse
  `TaskUpdate`; `three-role-transition-gate`→PostToolUse `Agent|Task`; `three-role-subagent-ledger` +
  `subagent-bg-orphan-gate`→SubagentStop). Re-path per Blocker 1 + 4. Move `3role-ledger.mjs` to `bin/`.
  Port the 9 companion `*-smoke-test.sh` into `hooks/_smoke/` as oracles.
- **Files:** `hooks/*.sh` (9), `hooks/hooks.json`, `bin/3role-ledger.mjs`, `hooks/_smoke/*`.
- **Binary AC:**
  1. `grep -rEl '~/.claude/hooks|node hooks/3role-ledger|node skills/cairn' hooks/` → returns NOTHING
     (no ai-brain-relative or symlink paths survive in ported hooks).
  2. `node -e "JSON.parse(require('fs').readFileSync('hooks/hooks.json'))"` → exit 0; every `command`
     string contains `${CLAUDE_PLUGIN_ROOT}`.
  3. Each ported `hooks/_smoke/<name>-smoke-test.sh` exits 0 when run with `CLAUDE_PLUGIN_ROOT` set to the
     repo root (the re-pathed hooks still pass their own suites).
  4. A synthetic-payload smoke (pipe a minimal JSON event into each hook with `CLAUDE_PLUGIN_ROOT=$PWD`)
     produces no "file not found" / ai-brain-path error on stderr.
- **Gated?** No.

### Leg 3 — Port 7 skills + bundle cairn shim
- **Scope:** copy the 7 SKILL.md (+ each skill's `references/` it loads); re-path all `cairn-find` /
  `3role-ledger` invocations to `${CLAUDE_PLUGIN_ROOT}/bin/`; bundle `bin/cairn-find.mjs` + `bin/cairn-lib/`;
  strip ai-brain coupling — especially **remove the employer-privacy-token gate from `/ship`** (a public
  plugin must not carry the regulated token list) and make `/ship`'s repo-helper references degrade-skip.
- **Files:** `skills/*/SKILL.md` (7) + ported references, `bin/cairn-find.mjs`, `bin/cairn-lib/*.mjs`,
  `bin/cairn-find.test.mjs`.
- **Binary AC:**
  1. `node "$PWD/bin/cairn-find.mjs" "plugin"` exits 0 and prints ≥0 ranked lines (no crash, no missing-dep).
  2. `node bin/cairn-find.test.mjs` (ported test) → exit 0.
  3. `grep -rEl 'skills/cairn/bin|node hooks/|/Users/|coding_projects/ai-brain' skills/ bin/` → NOTHING.
  4. The employer-privacy regulated token does NOT appear anywhere under `skills/` or the repo (the privacy
     pre-commit grep, run by the reviewer, returns clean — public-artifact requirement).
  5. `/ship` SKILL.md's `cairn/bin/phase-b-checks.mjs` + oauth-helper references are each wrapped in an
     existence guard (grep shows "if … exists" / "if not found, skip" adjacency).
- **Gated?** No. (Privacy grep is a hard precondition of this leg's review, not an outward op.)

### Leg 4 — Extract `3-role-model.md` doctrine
- **Scope:** author the standalone doctrine file from `parent-claude.md` (the `## Planner / Executor
  Workflow` + `### Development model — 3 roles, orchestrated` + `### Role tooling` + inline criteria +
  skill-as-primitive mapping), self-contained, public-clean.
- **Files:** `3-role-model.md`.
- **Binary AC:**
  1. `test -f 3-role-model.md` → exit 0.
  2. `grep -qE '^## .*[Kk]nob A' 3-role-model.md && grep -qE '^## .*[Kk]nob B' 3-role-model.md` (both knob
     tables present) AND the file contains all 4 invariant statements (grep for "never self-review",
     "STATELESS", "search cairn", "INSTRUMENTED" or equivalents).
  3. `grep -nE '/Users/|coding_projects|~/.claude/agent-working-memory' 3-role-model.md`
     → NOTHING (no absolute paths, no card refs) AND a repo-wide employer-token grep is clean.
  4. The exact default-doctrine line (Leg 5) is present once.
- **Gated?** No.

### Leg 5 — Scaffolding command + default-doctrine line
- **Scope:** author `commands/scaffold.md` (the `/three-role-model:scaffold <kind> <name>` command) + the 4
  `templates/*.tmpl` it stamps out, each PRE-WIRED to the model; add the default-doctrine line to both
  `3-role-model.md` and `README.md`.
- **Files:** `commands/scaffold.md`, `templates/{skill.SKILL.md,command.md,hook.sh,agent.md}.tmpl`.
- **How scaffolding pre-wires (the D mechanism):** `/three-role-model:scaffold skill foo` copies the matching
  template into the right place (`skills/foo/SKILL.md`, `commands/foo.md`, `hooks/foo.sh` + a `hooks.json`
  entry stub, or `agents/foo.md`) with these pre-baked sections already filled:
  - a `## Execution model` heading whose body already declares a placement keyword (`delegate`) AND an
    evaluator keyword (`reviewer`) — so the generated artifact PASSES the ported `enforce-plan.sh`
    shape-declaration gate out of the box;
  - the role-ledger spawn snippet (the `3ROLE_TASK:<id> ROLE:<role>` tag + the
    `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append …` lines);
  - a one-line doctrine pointer: `See ${CLAUDE_PLUGIN_ROOT}/3-role-model.md — the 3-role model is the
    default for new primitives in this workspace.`
  - for the hook template, a ready `hooks.json` entry stub with a `${CLAUDE_PLUGIN_ROOT}` command.
- **The exact default-doctrine line** (verbatim, added to `3-role-model.md` + `README.md`):
  > **Default development model.** Every non-trivial skill, agent, hook, or command authored in a workspace
  > that installs this plugin runs through the 3-role model — planner → plan-review → executor →
  > execution-review, each a separate subagent, never self-review. New primitives are scaffolded pre-wired
  > via `/three-role-model:scaffold <skill|agent|hook|command> <name>`; the generated skeleton already
  > carries its `## Execution model` shape declaration, the role-ledger spawn snippet, and this doctrine
  > pointer. Hand-writing a primitive that skips the model is the exception, not the default.
- **Binary AC:**
  1. `test -f commands/scaffold.md` and all 4 `templates/*.tmpl` exist → exit 0.
  2. Pipe a generated skill template through the ported `hooks/enforce-plan.sh` as a NEW
     `.ai-workspace/plans/x.md`-shaped Write payload (the gate also fires on the `## Execution model`
     shape) → the gate does NOT block (exit 0): proves the template satisfies the placement+evaluator
     keyword contract.
  3. `grep -q 'Default development model' 3-role-model.md && grep -q 'Default development model' README.md`
     → exit 0 (doctrine line present in both).
  4. Each template contains `${CLAUDE_PLUGIN_ROOT}` and a `## Execution model` heading (grep).
- **Gated?** No.

### Leg 6 — Install-test + README (live prove-primary, Rule 18)
- **Scope:** the LIVE proof a stranger's flow works, from a local clone (no public repo yet). Document +
  run: `/plugin marketplace add <local-path>` → `/plugin install three-role-model@three-role-model` into a
  THROWAWAY config dir (`CLAUDE_CONFIG_DIR` sandbox), then verify hooks register, `${CLAUDE_PLUGIN_ROOT}`
  resolves at runtime, one hook FIRES live, one skill resolves namespaced, the ledger writes to the
  configured dir. Finalize README (install commands, the config env vars, the `${CLAUDE_PLUGIN_ROOT}`
  portability note, and the #841 anchor pointer).
- **Files:** `README.md` (final), a `_smoke/install-smoke.md` runbook + transcript.
- **Binary AC:**
  1. After install into the sandbox config dir, `claude` lists the plugin as installed AND its hooks appear
     registered (a documented `claude plugin list` / settings inspection shows them) → captured in the
     transcript.
  2. ONE hook fires live against a real synthetic event with `${CLAUDE_PLUGIN_ROOT}` resolved to the cache
     path (e.g. enforce-plan blocks a section-less plan Write) → observed in the transcript (this is the
     Rule-18 live tool-run, not a fixture parse).
  3. `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append …` writes a line under the resolved
     `THREE_ROLE_LEDGER_DIR` → `check` reads it back, exit 0.
  4. README contains the two install commands verbatim + the portability note + an #841 anchor line.
- **Gated?** No paid/outward step, BUT this is the mandatory live prove-primary precondition before the
  operator-gated repo-creation step (below). If the install smoke fails, do NOT proceed to publish.

## Gated steps flagged (NOT performed by any leg in this plan)

- **OUTWARD — create the public GitHub repo `ziyilam3999/three-role-model` + initial push.** Puts the user's
  identity on a public shelf. Requires an explicit operator "yes" in the transcript (per the
  outward-call-needs-per-step-authorization doctrine). NO leg here creates the repo or pushes. After Leg 6's
  install smoke is green AND the operator approves, a SEPARATE follow-up creates the repo + pushes.
- **Privacy precondition (hard gate, not outward):** before that push, the employer-privacy grep must be
  clean across the entire repo (Leg 3 AC 4 + Leg 4 AC 3 enforce it within the plugin tree; re-run repo-wide
  at push).
- No paid step exists anywhere in this plan (no render, no API spend, no model call).

## Risks / open questions

- **R1 — does `${CLAUDE_PLUGIN_ROOT}` resolve inside a SubagentStop hook shell?** `three-role-subagent-ledger.sh`
  and `subagent-bg-orphan-gate.sh` bind to SubagentStop and the ledger hook resolves the helper sibling-
  relative today. If the harness does NOT export `${CLAUDE_PLUGIN_ROOT}` for SubagentStop commands, the
  re-path breaks. MITIGATION baked into Blocker 1: keep a `$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs`
  fallback alongside the `${CLAUDE_PLUGIN_ROOT}` path. Leg 6 AC 2 must exercise a SubagentStop-bound hook
  live to settle this — do NOT trust the fixture smoke (per the live-tool-run-before-shipping doctrine).
- **R2 — bundled cairn-find returns near-empty for a stranger (no T3 KB).** Acceptable by design (it searches
  the user's own T1/WM tiers and exits 0), but the "search-before-plan" invariant becomes weaker for a fresh
  user. Documented as expected; `CAIRN_PERSIST_ROOT` lets power users restore full KB search. Not a blocker.
- **R3 — `/ship` is the heaviest, least-portable skill.** It encodes ai-brain release mechanics (version
  bump, CHANGELOG prepend, the cairn index-check gate, the employer-privacy gate, oauth sync). The faithful
  port keeps the SKILL.md guidance but degrades every ai-brain-specific helper to skip-if-absent and DROPS
  the employer-privacy gate (public-artifact requirement). Open question for plan-review: is a degraded
  `/ship` still "faithful enough" for v1, or should its repo-specific gates be clearly marked
  "ai-brain-only, no-op elsewhere" in the ported SKILL.md? Recommend the latter (mark + no-op, don't delete
  the guidance).
- **R4 — plugin hooks COMPOSE with the installer's settings.json hooks (both fire).** An ai-brain author who
  installs the plugin would double-fire every gate. Open question: ship as-is (strangers have no conflict;
  ai-brain stays on its symlink wiring) — recommended — or document a "don't install on a machine that
  already wires these via setup.sh" note. Decide in plan-review.
- **R5 — `claude plugin validate` surface unverified.** I could not confirm from source whether the CLI
  exposes a `plugin validate` subcommand; Leg 1 AC 4 is best-effort with AC 2+3 as the firm fallback.

## Deferred-follow-ups:

- **Create public repo `ziyilam3999/three-role-model` + initial push** — DEFERRED, OUTWARD + operator-gated.
  → file/execute only after Leg 6 install smoke is green AND explicit operator "yes" (not in this plan's legs).
- **#841 promo post anchored to the public artifact** — DEFERRED to its own task. → already tracked as #841;
  this plan only leaves the README #841-anchor pointer.
- **Full cairn port (place/promote/status/stones/drift), not just the search shim** — DEFERRED v1. → file a
  task only if a user needs in-plugin lesson-WRITING; v1 bundles search-only per Blocker 5.
- **`/ship` ai-brain-only gates (cairn index-check, release mechanics) marked no-op vs deleted** — decision
  DEFERRED to plan-review (Risk R3). → resolve in the plan-review beat, not a later task.
- **Double-firing on a machine that already wires these hooks via setup.sh** (Risk R4) — DEFERRED decision.
  → resolve in plan-review; file a README-note task only if "ship as-is" is rejected.

## Review

plan-review: **PASS** (Explore, stateless — `.ai-workspace/reviews/875-plan-review.md`, 2026-06-14). All 5
blockers verified against source; all AC binary + externally checkable; cairn bundle confirmed zero-npm-dep
(~24KB code); no blocking issues. Resolutions folded in:
- **R3 (`/ship` portability) — as planned, refined:** mark Stage 5.5 (cairn index-check) + Stage 7 (release
  mechanics) "ai-brain-only, no-op when helper absent" (keep guidance, existence-guard the helpers); **REMOVE
  Stage 5.6 (employer-privacy gate) entirely** (a public artifact must not carry the regulated token list —
  Leg 3 AC 4 enforces a clean repo-wide privacy grep); keep the oauth-sync already-guarded pattern.
- **R4 (hook double-fire) — ship as-is + README warning:** strangers have no conflict; an ai-brain author
  installs the plugin OR keeps setup.sh wiring, not both. Add the README note (verdict file lines 112-113).
- **Extra re-path (precision):** the Leg-2 re-path must ALSO catch two advisory `echo` strings printing
  `node hooks/3role-ledger.mjs` — `three-role-transition-gate.sh:85` and `three-role-instrumentation-gate.sh:122`
  → `node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"`. Leg-2 AC 1 grep already catches these once fixed.
- **Hard gate reaffirmed:** Leg 6 install-smoke is the mandatory live prove-primary; do NOT publish until green.

## cairn

cairn: HIT — `2026-06-14-3role-plugin-research-synthesis.md:48` — "A plugin ships in `~/.claude/plugins/cache/`;
hook commands must s[witch to] relative paths (relative `./` fails; plugin can't read `../` outside its dir)"
— directly grounds Blocker 1 (re-path to `${CLAUDE_PLUGIN_ROOT}`) and the bundle-don't-reference-sibling
decision for cairn (Blocker 5). Also HIT `session-state-20260614-875-plugin-epic.md:30` — "Distribution: npm
IS supported … `.claude-plugin/marketplace.json`" confirms the git-marketplace layout for fork A. (Queries
run via `node skills/cairn/bin/cairn-find.mjs`: "plugin", "portability", "CLAUDE_PLUGIN_ROOT", "ledger".)
