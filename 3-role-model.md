# The 3-Role Development Model

Every non-trivial change runs as four separate subagents in a line:

```
planner  ->  plan-review  ->  executor  ->  execution-review
 (what)      (vet the plan)    (the how)     (vet the result)
```

The **orchestrator** (your main session) only coordinates — it picks the knobs, spawns the
roles, threads the results between them, and ships. It does **not** do the substantive work
inline. The cardinal invariant behind the whole model: **never self-review** — the thing that
grades the work is never the thing that produced it. A planner doesn't bless its own plan, an
executor doesn't pass its own code, and the orchestrator doesn't quietly grade everything from
the driver's seat. Each beat is handed to a fresh, independent subagent so a real second pair of
eyes touches the work before it ships.

This file is the standalone, canonical explanation of the model. You can read it cold, with no
other context, and understand both the mechanics and the *why*.

---

## The two knobs

The model has exactly **two choices**, and **task nature picks both**. There is no separate
"delivery vehicle" to layer on top — just two knobs.

### Knob A — Executor placement (where the code gets written)

| Placement | Pick when the task is… |
|---|---|
| **test-loop** (local red -> green loop) | wrappable in a *failing* test that becomes the oracle — write the red test, make it green |
| **delegate** (one fresh subagent) | briefable as a single coherent surface — **this is the default** |
| **parallel** (N subagents) | splittable into *disjoint* write surfaces that can run side by side |
| **inline** (the orchestrator, in-session) | **not** briefable (see *When to go inline* below) |

### Knob B — Evaluator (how it's checked)

| Evaluator | Pick when… |
|---|---|
| **test-oracle** (a real passing test) | a binary acceptance criterion exists — strongest, use it whenever you can |
| **reviewer** (a stateless LLM review) | correctness is a judgment call, a tool integration, or otherwise not fully test-checkable (also do one live "prove the primary path" run) |
| **both** | high-stakes work — a real test *and* an independent reviewer |

**Task-nature picks the knobs, and that's a judgment call.** No hook can force the *right* shape;
a hook can only force you to *declare* one. The test-loop placement is simply knob A set to
test-loop — chosen **only** when a failing test naturally wraps the task. It is **never
mandatory** and never "test-loop plus another vehicle." A plain delegate task carries no
test-loop boilerplate at all.

---

## The invariants

These always hold for non-trivial work. (Trivial-skip = a single file **and** under ~10 changed
lines **and** no architectural decision — those can be fixed in place.)

1. **The planner is a subagent.** The only exception is a task so tightly coupled to live session
   state that no self-contained brief could carry it — the same carve-out as inline execution
   below.

2. **The plan is reviewed by a stateless reviewer before any code is written.**

3. **The executor's output is reviewed by a stateless, independent reviewer *or* a real test
   oracle before ship — never self-review.** Not the executor grading its own work, and not the
   orchestrator quietly grading it inline.

4. **Search memory first — all THREE systems.** Both the planner and the plan-reviewer consult
   every memory system before planning, and the plan/review cites what was found. The three
   systems, each with its own job:

   1. **cairn** (what went wrong before) — from inside a subagent shell, run the bundled,
      dependency-free search shim:

      ```
      node ${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs "<keyword>"
      ```

      Query with single, salient keywords (the matcher is substring-based). The shim **degrades
      gracefully**: if no memory store is present on the machine, every tier walk silently returns
      empty and you simply get *no hits* — it never errors out. Point it at a store by setting
      `CAIRN_PERSIST_ROOT` (it defaults to the repo it ships in).
   2. **working-memory active-decision cards** (what we decided) — the CLI above is keyword-gated,
      so open and Read the matched `~/.claude/agent-working-memory/tier-b/topics/<topic>/<id>.md`
      cards IN FULL.
   3. **the live project-index** (where the files are) — Read `<repo>/.ai-workspace/PROJECT-INDEX.md`
      (generate it via `/project-index` if absent). This is the LIVE per-repo map, distinct from any
      cached primer the cairn shim happens to walk.

   Either way, the plan/review MUST carry a one-line citation that quotes a matched result —
   `cairn: "<quoted matched hit>"` — *or* states plainly `cairn: no hits for <queries tried>`. That
   line is the cheapest honest signal that the search actually ran, and the instrumentation gate
   verifies it at completion.

5. **Every role subagent is spawned with the tools its job needs.** See *Role tooling* below.

6. **Every non-trivial run is instrumented — and the instrumentation is forgery-resistant.** The
   core mechanic is simple and mechanical:

   - **The orchestrator writes the role's identity at spawn.** As it spawns each role it prepends
     a tag to the brief — `3ROLE_TASK:<taskId> ROLE:<planner|plan-review|executor|execution-review>`
     — and immediately records that role's agent id in a per-task **role-ledger**:

     ```
     node ${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs append --session <sid> --task <taskId> --role <role> --agent <agentId>
     ```

     When the spawn surfaces the agent id directly, use it. When it doesn't (some read-only
     reviewer spawns don't), resolve it from the newest tagged transcript:

     ```
     node ${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs resolve-agent --session <sid> --task <taskId> --role <role>
     ```

     Use the *newest* match, not a first-match grep — a role tag can repeat across transcripts
     (an earlier probe or retry), and the newest write is the real spawn.

   - **The orchestrator writes the artifact at close.** When a role finishes, append only its
     output path; the append merges onto the spawn-time id, so neither write clobbers the other:

     ```
     node ${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs append --session <sid> --task <taskId> --role <role> --artifact <path>
     ```

   - **A backup capture corroborates it.** The bundled `three-role-subagent-ledger.sh` hook
     auto-captures a tagged spawn's agent id from its transcript. It's a safety net, **not** the
     primary path — always do the orchestrator-at-spawn write yourself, because you control it
     directly and it captures the artifact at close.

   - **A gate makes "we followed the process" provable.** The bundled
     `three-role-instrumentation-gate.sh` hook blocks a tagged headline completion unless the
     role-ledger carries all four roles, and each role is either a real agent id that **resolves
     to an actual subagent transcript file** (a forged id has no file -> blocked) with a
     well-shaped artifact, *or* an explicit, **specific** inline-skip reason. The planner,
     plan-review, and executor roles may inline-skip with a specific reason (empty, vague, or "I
     ran it myself" reasons are rejected — the carve-out is only for work genuinely inseparable
     from session state). **`execution-review` is never inline-skippable** — never grade your own
     homework. It needs a real reviewer agent id, or a test-oracle file that exists and carries a
     PASS token.

   The available ledger subcommands are `append`, `check`, and `resolve-agent`.

---

## The skills are the role-primitives

You don't reimplement the loop by hand. Each beat maps to a bundled skill, and you reuse them:

| Beat | Bundled skill(s) |
|---|---|
| **review-plan** | `per-task-review-loop` (its plan-chain mode: four reviewers in series) *or* `auto-flow` Stage 1 |
| **execute** | `delegate` (knob = delegate) / `auto-flow` Stage 2 (knob = parallel) / a test-loop role-chain (knob = test-loop) / inline + `per-task-review-loop` (knob = inline) |
| **review-execute** | `delegate review` *or* a fresh stateless reviewer subagent |
| **ship** | `ship` |
| **orchestrate end-to-end** | `issue-to-ship` |

Supporting skills round out the planning side: `coherent-plan` is the quick consistency sweep for
small plans, and `double-critique` is the heavier multi-round critique for large architectural
specs. All of these live in `skills/`.

---

## Role tooling

The subagent's *type* decides its toolset, and **a role spawned without a tool it needs fails
silently.** Match the type to the role:

- **Planner and executor write files** -> spawn a **full-tool** agent type (one with `*` tools).
  **Trap: do not use a read-only "Plan" agent type for the planner.** Despite the name it has no
  write or edit tools, so it *cannot* author a plan file.

- **Pure reviewers** (the plan-reviewer and the execution-reviewer) -> spawn a **read-only,
  Explore-style** type that still keeps Bash, Read, Grep, and Skill. That's enough to search
  memory (`node ${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs "<keyword>"`) and run the test oracle.
  The reviewer must never be the executor — that would be self-review.

- **Reviewer-artifact discipline.** A reviewer's shell often runs from the primary clone, not the
  worktree branch, so a bare relative output path lands untracked and never ships with the change.
  The orchestrator must hand the reviewer an **absolute worktree path** to write to, and after the
  reviewer returns, **verify the file actually landed there** (`test -f <abs-path>`) *before*
  committing. A missing file means the reviewer wrote to the wrong directory — relocate or re-run;
  don't commit a phantom artifact.

Rule of thumb: writers get the full-tool type, reviewers get the read-only type, and when in doubt
grant **more** tools, not fewer — a starved agent is the expensive failure.

---

## A role subagent must never background-and-end a job it owns

A subagent's turn is **one-shot**: it never receives the async completion notification for a
backgrounded job. So any heavy step a subagent backgrounds and then ends its turn on is
**orphaned**, leaving empty or partial output behind.

The rule:

- Run any heavy step you **own synchronously** — foreground, blocking — so its output exists
  before you return.
- If a step genuinely must run in the background, **hand the job id back to the orchestrator** in
  your return message (mark it clearly, e.g. "bg handed to orchestrator: `<id>`"). The
  orchestrator's turn is *not* one-shot and can await it.
- Never end your turn with an un-awaited background job you launched. "I'll wait for the
  completion notification" is a no-op for a subagent.

The bundled `subagent-bg-orphan-gate.sh` hook is the mechanical backstop for this.

---

## When to go inline

The default is **delegate** — a fresh subagent builds from a self-contained brief, which keeps the
main context lean. Reach for inline work (knob A = inline) **only when the task is not briefable**,
i.e. when at least one of these holds:

1. **Tightly coupled to live in-session context** — it depends on state a brief can't carry
   (mid-edit positions, evidence discovered between turns, a decision still being weighed).
2. **Interleaved with an in-session-only action** — it has to pause mid-flight for a paid call, an
   interactive prompt, or an operator-loop step only this session can perform.
3. **Exploratory / shape-unknown** — the plan is being discovered as you build; there's no stable
   brief because each step depends on what the last one finds.
4. **Handoff overhead exceeds the work** — writing and delivering the brief and reading the result
   would cost more than just making the small interlocked edit here.

If none of the four hold, the work **is** briefable — hand it to delegate. This list is the
judgment; the bundled `plan-review-before-execute.sh` hook is the mechanical backstop that stops
you from quietly building a delegate-sized batch inline on an un-reviewed plan.

---

## The default development model

> **Default development model.** Every non-trivial skill, agent, hook, or command authored in a workspace that installs this plugin runs through the 3-role model — planner → plan-review → executor → execution-review, each a separate subagent, never self-review. New primitives are scaffolded pre-wired via `/three-role-model:scaffold <skill|agent|hook|command> <name>`; the generated skeleton already carries its `## Execution model` shape declaration, the role-ledger spawn snippet, and this doctrine pointer. Hand-writing a primitive that skips the model is the exception, not the default.
