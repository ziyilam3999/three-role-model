---
topic: workflow
id: post-compact-resume-sequencing-protocol
title: "Post-Compact Resume & Sequencing Protocol — ELI5 + 3-tier sequenced plan + ONE approve-gate before any task work"
created: 2026-05-31
pinned: true
tags: [workflow, post-compact, resume, sequencing, eli5, approve-gate, autonomous-pipeline, mechanical-gate]
---

## Packaging note (three-role-model plugin)

This doc ships with the **three-role-model** Claude Code plugin as the standalone
doctrine for **Autonomous Pipeline Mode**. A few things to know as an installer:

- **(a) What ships here.** This document is bundled at the plugin root. The
  surfacing hook is `hooks/post-compact-resume-sequencer.sh` (registered in
  `hooks/hooks.json` on `SessionStart` for the `compact` and `clear` matchers,
  plus a `UserPromptSubmit` resume-intent backstop). The hook resolves its own
  path via `${CLAUDE_PLUGIN_ROOT}`, so it runs from the install cache on any
  machine. The companion Stop hook `hooks/autonomous-approval-stop-check.sh`
  catches a turn that ends by asking permission for a step already in the
  approved plan.
- **(b) The hook only SURFACES this protocol.** It injects the reminder text;
  it never inspects or grades the plan. ELI5 quality and ordering correctness
  stay the agent's judgment (the Rule-17 instruction-vs-hook split).
- **(c) The `ScheduleWakeup` autonomous-loop "tick" is NOT part of this plugin.**
  A scheduled "wake up and continue the pipeline" loop is a **Claude Code runtime
  feature** — it is configured by the operator in their own runtime, and **cannot
  be packaged inside a plugin**. Autonomous Pipeline Mode as shipped here = the
  two advisory/gate hooks + this doctrine. Nothing in this plugin schedules,
  wakes, or auto-continues a session on a timer. Do not read this doc as a claim
  that the plugin runs a background loop.
- **(d) Memory-system references are informational only.** `[[wikilink]]`
  cross-refs, `feedback_*` lesson ids, and `*-template.md` pointers below refer
  to the author's private agent-memory system. They are kept for provenance and
  are NOT resolvable from inside the plugin — treat them as informational, not as
  files you are expected to have.

---

## Decision

**Every time the session resumes after a `/compact` AND the operator asks to RESUME / CONTINUE, the agent MUST run the 5-step protocol below — IN ORDER, BEFORE touching any task.** Don't jump into the first task; don't silently re-sequence in your head. The protocol is *surfaced* mechanically (a hook at the post-compact boundary / on resume-intent prompts), but its *execution* — ELI5 quality, correctness of the impact/dependency ordering — is judgment and is NOT mechanically verified.

### The protocol (5 steps, in order)

1. **ELI5 the plan + next steps** — plain language (CLAUDE.md ELI5 rule): 2–4 short sentences on what we were doing and where we left off, then the next steps in plain words. **First re-orient from source** by running the re-orientation steps already in `pre-compact-card-template.md` → "Post-compact resume protocol": read the latest `session-state-pre-compact-*` card's *Pickup pointer*, **then OPEN AND READ THE BIG PLAN it names** (the overarching plan doc itself — the pickup pointer is a finger, the big plan is where the full remaining scope actually lives; reading only the pointer is how whole arcs of open work get dropped), **and** the live `TaskList`. Do NOT narrate from memory; post-compact memory is exactly what was lost.
2. **RECONCILE the live TaskList against reality FIRST** (before sequencing). Walk the list: mark finished/obsolete tasks `completed`, and **delete the already-done ones** so the list reflects what is genuinely still open. A list carrying dozens of stale `completed` rows buries the real remaining work and corrupts the sequencing in step 3 — clean it before you sort it. (Keep future-dated reminders, e.g. 30-day quarantine sweeps, as pending.)
3. **Build a SEQUENCED task list, ordered by IMPACT and DEPENDENCIES, in THREE tiers** — drawn from the **UNION of (a) the BIG PLAN's not-yet-done steps AND (b) every still-OPEN task in the reconciled TaskList**, so no open task or plan step is dropped (sort the COMPLETE remaining inventory, not a top-3, and not just the pickup card's immediate arc):
   - **Tier 1 — QUICK + EASY first.** Small + self-contained (single file, <10 lines, a one-command check, a stale-state fix, a pending push/merge). Clear these first: momentum, and they *often unblock others as a side effect*.
   - **Tier 2 — then MOST-DEPENDED-UPON / BLOCKING.** The node the rest of the graph waits on (most outgoing `blockedBy` edges; the decision/contract/shared-file others build against). Doing these next unblocks the widest fan-out.
   - **Tier 3 — then LONG-RUNNING.** Benchmarks, overnight runs, multi-hour compute, large dispatches. Start these **last among foreground attention**, and usually **kick them off detached AFTER the quick wins** so their clock runs *while* you do Tier 1/2 — never block the quick wins waiting on them. (A long-running task that gates later analysis still starts as early as its inputs allow — in the background.)
4. **PRESENT the sequenced plan and STOP for review + approval.** Render the three tiers in ELI5 voice; wait for an affirmative signal scoped to *this* plan (yes / approve / proceed / "go"). Silence ≠ approval; adjacent chatter ≠ approval.
5. **ONLY AFTER approval, start working** — THEN create/update the TaskList in this sequenced order (Tier 1 → lowest IDs, per the create-in-priority-order rule) and execute.

### Ordering criteria (concrete)
- **Quick+easy (T1)** = small blast radius AND short wall time AND no upstream dependency (trivial-skip threshold, a pending `/ship`/merge/push, a config/stale-state fix, a read-only verify).
- **Most-depended-upon (T2)** = highest dependency in-degree across the rest (how many other tasks are `blockedBy` this, or share its file/interface/decision). The task that turns the most red lights green. Tie-break by impact.
- **Long-running (T3)** = wall time dominated by compute/waiting, not your attention. Launch detached (`nohup … &`, verify PPID=1 so it survives a later `/compact`), persist outputs to `.ai-workspace/` not `/tmp`, then poll.

### Reconciliation with Autonomous Pipeline Mode (the ONE gate)
Step 4's approve-gate is the **single initial post-compact sequencing gate — NOT a per-slice gate.** Once approved, proceed in Autonomous Pipeline Mode: chain slices end-to-end without per-task approval (the approved sequence + each plan's binary AC are the contract). Later pauses are only the ones APM already allows: a genuine context-cleaning `/compact`, a BLOCK verdict, a Rule-15 destructive-action visibility moment. **Gate once on the plan, then run.**

## Why
The agent already carries a pocket-card "post-compact resume protocol" (read latest pre-compact card → plan → `TaskList` → resume), but that restores *what* to do — it does NOT reliably make the agent (a) ELI5 in plain language, (b) re-sequence by impact+dependency into the 3 tiers, (c) gate on approval. This session (2026-05-31) the operator had to manually ask "eli5 the plan and next steps" post-compact — the surfacing wasn't automatic. Per Rule 17 / [[feedback_mechanical_gate_over_memory]], the *mechanically-verifiable* part (RELIABLY SURFACE this at the right moment) is a hook, not a longer instruction trusted to memory.

## Mechanical surfacing (hook) — `post-compact-resume-sequencer.sh`
- **SessionStart, `matcher:"compact"`** (the harness fires this ONLY at the post-compact boundary — confirmed honored in settings): writes a compact-specific sentinel `~/.claude/cairn/sessions/{sid}.compact` AND prints the protocol reminder to stdout (SessionStart stdout is injected into context).
- **UserPromptSubmit `--prompt-mode`** (backstop for the delayed-resume case — compact → chatter → reminder scrolls → "continue"): emits ONLY when BOTH (a) the `{sid}.compact` sentinel is fresh (`now - mtime < POST_COMPACT_RESUME_WINDOW_MIN`, default 30 — time since **COMPACT**, gated on the compact-specific sentinel so a plain startup/resume can't trip it) AND (b) the prompt matches resume-intent `/resume|continue|next steps|what.?s next|carry on|pick up|eli5 the plan/i`; then it consumes the sentinel (one-shot).
- The hook ONLY injects the reminder; it never inspects/grades the plan (judgment stays instruction-class — the exact instruction-vs-hook split Rule 17 demands).
- **Two distinct bypasses (don't conflate):** `POST_COMPACT_RESUME_SEQUENCER_OVERRIDE=1` suppresses the SURFACING entirely (operator/smoke use); an in-prompt pre-authorization ("resume and just run it") suppresses only the WAIT — you still SHOW the ELI5 + 3-tier plan (visibility), you just don't block on it.

## Integration (no duplication)
- **pre-compact-card-template.md → "Post-compact resume protocol"** = the re-orientation INPUT to step 1 (read card→plan→TaskList). This protocol EXTENDS it with the ELI5 + 3-tier re-sequence + approve-gate it lacks. Two ends of one seam — cross-linked both ways.
- **CLAUDE.md "Living Todo List"** governs HOW the sequence becomes tasks (headline-first, priority-order); this protocol decides the SEQUENCE. No overlap.
- **CLAUDE.md "Autonomous Pipeline Mode"** — reconciled above (this is the ONE initial gate).
- **Post-Slice Checkpoint Ritual** — sibling: that fires at every mid-pipeline slice-complete; this fires once at resume-after-compact. Both lead with ELI5.

## Update history
- **2026-06-01:** enhanced 4→5 steps (operator: "i want it to understand the big plan too … review the live task list, update … delete the completed one … include [the big plan + remaining open tasks] into the 3-tier list"). Step 1 now OPENS AND READS the big plan (not just the pickup pointer — the trigger was a resume that sequenced only the pickup card's immediate arc and dropped the open tasks living in the big plan + live TaskList). New step 2 RECONCILES the live TaskList (mark/delete done) before sorting. Step 3 builds the 3 tiers from the UNION of big-plan-remaining ∪ open-TaskList. Hook text + smoke (8/8) updated in lockstep.
- **2026-05-31:** issued. Operator wanted post-compact resume to AUTO ELI5 + re-sequence into 3 tiers + gate once, instead of being asked manually. Designed via workflow + adversarial critique (fixed: backstop recency must use a compact-specific sentinel, not the every-start `.start` file; dropped an unverified `source`-field read in favor of the confirmed `matcher:"compact"`; injected-text creates tasks AFTER approval).
