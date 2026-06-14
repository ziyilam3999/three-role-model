# The 3-Role Development Model

> **Placeholder — the full doctrine is extracted in build Leg 4.** This file will carry the standalone,
> self-contained doctrine: the two knob tables (executor placement / evaluator), the role invariants
> (never self-review, stateless reviewers, search-memory-first, instrumented), the role-tooling rules, the
> skill-as-role-primitive mapping, the not-briefable inline criteria, and the default-development-model line
> (Leg 5). It is extracted from a private doctrine source and scrubbed of any machine-specific paths,
> internal references, or regulated tokens before it ships.

## The shape (one-paragraph summary)

Every non-trivial task runs **planner → plan-review → executor → execution-review**, each a separate
subagent. The orchestrator coordinates only. Two knobs, picked by task nature: **executor placement**
(test-loop / one subagent / parallel / inline) and **evaluator** (a real passing test / an independent
stateless reviewer / both). The cardinal invariant: **never self-review** — the thing that grades the work
is never the thing that produced it.
