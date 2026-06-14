#!/bin/bash
# Hook: Enforce plan-first workflow
# Blocks Edit/Write on source files if no plan file exists in .ai-workspace/plans/
# Uses Node.js for JSON parsing (jq not available on Windows Git Bash)
#
# Execution-model gate (PR #v0.28.0 / D1):
#   On Write tool calls targeting a NEW (not-yet-on-disk) `.ai-workspace/plans/*.md`
#   file, require the plan content to contain a `^## Execution model$` heading whose
#   body (between the heading and the next `^## ` heading or EOF) holds at least one
#   non-whitespace character. Whitespace-only body BLOCKS. Existing plan files are
#   grandfathered (the existence check fires AFTER the path-match, before content
#   parsing). The stderr message names the missing/empty section AND cites CLAUDE.md's
#   task-sizing ladder so the planner has an actionable hint without re-opening the
#   global rulebook. The gate's contract is presence-of-section + non-emptiness only —
#   judging *quality* of rationale is planner discipline, not the hook's job (per
#   plan G2). Originated from a 2026-04-26 meta-failure where a planner forgot to
#   `/delegate` for non-trivial work despite the rule being in CLAUDE.md and memory.
#
# Shape-declaration sub-check (2026-06-12, #836 — supersedes the lfah-AND vehicle rule):
#   AFTER the presence + non-empty checks pass, the `## Execution model` body must
#   declare the work SHAPE — chosen by task nature, NOT a mandatory "always lfah + X".
#   The body (lowercased) must contain BOTH:
#     (a) >=1 EXECUTOR-PLACEMENT keyword: `lfah` | `delegate` | `parallel` | `inline`
#         (case-insensitive substring), AND
#     (b) >=1 EVALUATOR keyword: `review` (covers reviewer/reviewed) | `test-oracle` |
#         `test oracle` | `oracle` | `both`.
#   lfah is one PLACEMENT among four (the free dogfood path for red-test-buildable work)
#   — it is NO LONGER required; a delegate+reviewer body with no `lfah` token now PASSES.
#   Kill-switch: `EXECUTION_MODEL_SHAPE_OFF=1` (or legacy `EXECUTION_MODEL_VEHICLE_OFF=1`
#   for back-compat) skips ONLY this shape sub-check — the missing-section and
#   whitespace-only-body blocks STILL fire regardless of the switch (the switch must not
#   open a hole that lets a section-less plan through). Originated from a 2026-06-12
#   operator rejection of the lfah-AND rule (it implied "always use lfah + something",
#   false — lfah only fits red-test-buildable tasks).
set -e

INPUT=$(cat)

# Parse JSON fields using Node.js
FILE_PATH=$(echo "$INPUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const j=JSON.parse(d);console.log(j.tool_input?.file_path||'')}catch{console.log('')}})")
CWD=$(echo "$INPUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const j=JSON.parse(d);console.log(j.cwd||'')}catch{console.log('')}})")

# Allow if no file path (safety fallback)
[ -z "$FILE_PATH" ] && exit 0

# Plan-file branch (also covers the new Execution-model gate).
if echo "$FILE_PATH" | grep -qE '\.ai-workspace/plans/.*\.md$'; then
  # Existing plan files are grandfathered — only enforce on NEW saves.
  if [ -e "$FILE_PATH" ]; then
    exit 0
  fi
  # New plan-file save → run the Execution-model gate. The Node parser receives the
  # full hook input on stdin, extracts tool_input.content, scans for the heading,
  # accumulates body until the next `^## ` heading or EOF, and exits 2 (with stderr
  # diagnostic) on either missing-heading or whitespace-only body. Single-quoted
  # `-e` keeps bash out of the JS source. Stderr passes through as the user-facing
  # block message; we exit 2 to match the existing convention (line 28 below).
  set +e
  echo "$INPUT" | node -e '
    let d = "";
    process.stdin.on("data", c => d += c);
    process.stdin.on("end", () => {
      let content = "";
      try { content = (JSON.parse(d).tool_input || {}).content || ""; }
      catch { content = ""; }
      const lines = content.split(/\r?\n/);
      let headingIdx = -1;
      for (let i = 0; i < lines.length; i++) {
        if (/^##\s+[Ee]xecution\s+[Mm]odel\s*:?\s*$/.test(lines[i])) { headingIdx = i; break; }
      }
      if (headingIdx === -1) {
        process.stderr.write("BLOCKED: New plan file missing \"## Execution model\" section. Every new plan under .ai-workspace/plans/*.md must declare its execution model (inline / subagent / phased) with a non-empty rationale. See CLAUDE.md task-sizing ladder (3+ files / architectural decision / >10 LOC -> DELEGATE).\n");
        process.exit(2);
      }
      let body = "";
      for (let i = headingIdx + 1; i < lines.length; i++) {
        if (/^## /.test(lines[i])) break;
        body += lines[i] + "\n";
      }
      if (!/\S/.test(body)) {
        process.stderr.write("BLOCKED: \"## Execution model\" section is empty (whitespace-only body). Fill in inline / subagent / phased + rationale per CLAUDE.md task-sizing ladder (3+ files / architectural decision / >10 LOC -> DELEGATE).\n");
        process.exit(2);
      }
      // SHAPE-DECLARATION sub-check (#836): the body must declare the work shape —
      // an executor-PLACEMENT keyword AND an EVALUATOR keyword. lfah is one placement
      // among four (NOT mandatory). Kill-switch EXECUTION_MODEL_SHAPE_OFF=1 (or legacy
      // EXECUTION_MODEL_VEHICLE_OFF=1 for back-compat) skips ONLY this block; the
      // missing-section + whitespace-only-body blocks above already ran (presence is
      // enforced unconditionally, so the switch cannot open a section-less hole).
      if (process.env.EXECUTION_MODEL_SHAPE_OFF !== "1" &&
          process.env.EXECUTION_MODEL_VEHICLE_OFF !== "1") {
        const b = body.toLowerCase();
        const hasPlacement =
          b.includes("lfah") ||
          b.includes("delegate") ||
          b.includes("parallel") ||
          b.includes("inline");
        const hasEvaluator =
          b.includes("review") ||        // covers reviewer / reviewed / review
          b.includes("test-oracle") ||
          b.includes("test oracle") ||
          b.includes("oracle") ||
          b.includes("both");
        if (!hasPlacement || !hasEvaluator) {
          process.stderr.write(
            "BLOCKED: \"## Execution model\" must declare the work SHAPE — pick by task nature:\n" +
            "  (a) an EXECUTOR PLACEMENT keyword: lfah | delegate | parallel | inline, AND\n" +
            "  (b) an EVALUATOR keyword: reviewer | test-oracle | both.\n" +
            "Placements + when each fits:\n" +
            "  - lfah     = wrappable in a FAILING jest/test (the test IS the oracle); also the free dogfood path — NOT mandatory\n" +
            "  - delegate = briefable single coherent surface (DEFAULT)\n" +
            "  - parallel = split into DISJOINT write surfaces run side-by-side (auto-flow Stage 2)\n" +
            "  - inline   = NOT briefable: tightly-coupled to live state / interleaved with a paid/interactive step / exploratory\n" +
            "Evaluators:\n" +
            "  - test-oracle = a real passing test/jest/lfah exists (strongest)\n" +
            "  - reviewer    = stateless LLM review (judgment / tool-integration; do a live prove-primary too)\n" +
            "  - both        = high-stakes: real test AND an independent reviewer\n" +
            "Example body: \"delegate — briefable single surface; evaluator: reviewer (stateless code-review)\".\n" +
            "Kill-switch (last resort): EXECUTION_MODEL_SHAPE_OFF=1 (or legacy EXECUTION_MODEL_VEHICLE_OFF=1) skips ONLY this shape check.\n"
          );
          process.exit(2);
        }
      }
      process.exit(0);
    });
  '
  GATE_EC=$?
  set -e
  if [ "$GATE_EC" != "0" ]; then
    exit 2
  fi
  exit 0
fi

# Only block source code files
if echo "$FILE_PATH" | grep -qE '\.(ts|js|tsx|jsx|py|dart|java|go|rs|css|html|vue|svelte|sh)$'; then
  # Resolve the project's plans dir. Prefer CWD when provided; otherwise (the Edit/Write
  # tool intermittently sends an empty/missing cwd — verified 2026-05-20) walk up from
  # FILE_PATH to the nearest ancestor containing .ai-workspace/plans. Without this,
  # empty cwd made PLAN_DIR=/.ai-workspace/plans (which never exists) and spuriously
  # BLOCKED legitimately-planned edits.
  PLAN_DIR=""
  if [ -n "$CWD" ] && [ -d "$CWD/.ai-workspace/plans" ]; then
    PLAN_DIR="$CWD/.ai-workspace/plans"
  else
    # Walk up only for ABSOLUTE FILE_PATH (the Edit/Write tool always sends
    # absolute paths). Skipping relative paths avoids two defects: (a) an infinite
    # loop, since dirname fixpoints at "." for a relative path; (b) a false-allow
    # on an ambient ./.ai-workspace/plans in the hook's inherited cwd. A relative
    # path falls through to the BLOCK below (the safe default). The "$_d" != "$_prev"
    # guard is a belt-and-suspenders fixpoint stop even for absolute paths.
    case "$FILE_PATH" in
      /*)
        _d=$(dirname "$FILE_PATH")
        _prev=""
        while [ -n "$_d" ] && [ "$_d" != "/" ] && [ "$_d" != "$_prev" ]; do
          if [ -d "$_d/.ai-workspace/plans" ]; then
            PLAN_DIR="$_d/.ai-workspace/plans"
            break
          fi
          _prev="$_d"
          _d=$(dirname "$_d")
        done
        ;;
    esac
  fi
  if [ -n "$PLAN_DIR" ] && ls "$PLAN_DIR"/*.md 1>/dev/null 2>&1; then
    exit 0  # Plan exists, allow
  fi

  echo "BLOCKED: No plan file found in .ai-workspace/plans/. You MUST save a plan file before writing source code. Create the plan first, then implement." >&2
  exit 2
fi

# Default: allow (non-source files like .json, .md, .yaml, etc.)
exit 0
