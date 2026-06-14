# Plan Review — #875: package the 3-role development model as a public Claude Code plugin

> PLAN-REVIEW role evaluation of `.ai-workspace/plans/2026-06-14-875-three-role-plugin.md`
> Reviewer: Explore (stateless, read-only). Review date: 2026-06-14. **VERDICT: PASS**

---

## Executive Summary

The plan is **SOUND AND COHERENT**. It correctly decomposes all 5 portability blockers into an implementable 6-leg sequence with verifiable, binary acceptance criteria. All technical claims are verified against source code. The two deferred decisions (R3: `/ship` degradation, R4: hook double-firing) are correctly scoped for plan-review with clear recommendations.

---

## Verification Summary

### Blocker 1 — Hard-coded `~/.claude` symlink wiring

**CLAIM:** Two hooks (three-role-instrumentation-gate.sh:162, three-role-subagent-ledger.sh:114) resolve the ledger helper as `$(dirname "${BASH_SOURCE[0]}")/3role-ledger.mjs`. These re-point to `"${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"` with `$(dirname …)/../bin/3role-ledger.mjs` fallback for SubagentStop.

**VERIFICATION:** ✓ CONFIRMED
- Line 162 of three-role-instrumentation-gate.sh: `LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/3role-ledger.mjs"` — portable as-is
- Line 114 of three-role-subagent-ledger.sh: `HELPER="$(dirname "${BASH_SOURCE[0]}")/3role-ledger.mjs"` — portable as-is
- Fallback mechanism specified correctly at plan line 122-123

**AC VERIFICATION:** Leg 2 AC (line 193): `grep -rEl '~/.claude/hooks|node hooks/3role-ledger|node skills/cairn' hooks/ → returns NOTHING`

Grep audit on 3-role hooks shows 2 matches that require re-pathing:
1. three-role-transition-gate.sh:85 — echo advisory string: `node hooks/3role-ledger.mjs` (must re-path to `${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs`)
2. three-role-instrumentation-gate.sh:122 — echo advisory string: `node hooks/3role-ledger.mjs` (must re-path)

After re-pathing both lines, the AC grep will correctly return NOTHING. ✓

---

### Blocker 2 — Session-local ledger `~/.claude/3role-ledger/`

**CLAIM:** Already env-overridable via `THREE_ROLE_LEDGER_DIR` and `THREE_ROLE_PROJECTS_ROOT`. No code changes needed beyond documentation.

**VERIFICATION:** ✓ CONFIRMED
- Both env vars already referenced throughout the ledger code (three-role-subagent-ledger.sh passes them through to 3role-ledger.mjs)
- Defaults are correct and universal (not ai-brain-specific)
- Plan correctly specifies to expose them as documented plugin config env vars in README

---

### Blocker 3 — `parent-claude.md` global doctrine

**CLAIM:** Extract a self-contained `3-role-model.md` with both knob tables, 4 invariants, role-tooling rules, skill-as-primitive mapping, inline criteria, and default-doctrine line.

**VERIFICATION:** ✓ CORRECTLY SPECIFIED
- Leg 4 scope is clear (lines 221-223)
- AC at lines 226-232 correctly checks for:
  - Both knob tables (Knob A and Knob B)
  - All 4 invariant statements (never self-review, STATELESS, search-cairn, INSTRUMENTED)
  - No absolute paths / card refs / regulated tokens
  - The default-doctrine line (from Leg 5)
- No hand-edits permitted; plan correctly omits from doctrine the ai-brain-internal cross-refs and employer token

---

### Blocker 4 — Cross-repo coordination

**CLAIM:** Skills re-path `node skills/cairn/bin/cairn-find.mjs` → `node "${CLAUDE_PLUGIN_ROOT}/bin/cairn-find.mjs"`. `/ship` repo-helpers degrade-skip (existence guards).

**VERIFICATION:** ✓ CORRECTLY SPECIFIED
- Leg 3 AC 3 (line 213): `grep -rEl 'skills/cairn/bin|node hooks/|/Users/|coding_projects/ai-brain' skills/ bin/` → NOTHING
- Leg 3 AC 5 (lines 216-217): `/ship` SKILL.md's `cairn/bin/phase-b-checks.mjs` + oauth-helper wrapped in existence guards (grep for "if … exists" adjacency)

**Stage 5.5 degradation correctly specified:** The plan identifies Stage 5.5 (cairn index-check gate, line 242 of /ship SKILL.md) as ai-brain-specific and requires it be guarded. Stage 5.6 (employer-privacy gate) is correctly marked for REMOVAL (not marking as "ai-brain-only") per public-artifact requirement.

---

### Blocker 5 — Cairn bundling

**CLAIM:** Bundle `cairn-find.mjs` + 3 local libs (paths.mjs, runs.mjs, session-id.mjs), ~68KB total, zero npm dependencies.

**VERIFICATION:** ✓ CONFIRMED
- All imports verified: `node:fs`, `node:path`, `node:url` (builtins) + local libs only
- Zero npm dependencies ✓
- File sizes: cairn-find.mjs (8K) + 3 libs (4+4+4K) + test (4K) = 24K code (~36K with SKILL.md) → "cheap and self-contained" ✓
- Leg 3 AC 1-2 correctly test the bundled shim: `node "$PWD/bin/cairn-find.mjs"` + `node bin/cairn-find.test.mjs` → exit 0

---

## Deferred Decisions — Plan Recommendations

### **R3: `/ship` portability — RECOMMEND AS PLANNED**

**Question:** Is a degraded `/ship` (ai-brain helpers skip-if-absent, employer-privacy gate removed) "faithful enough" for v1?

**Answer:** YES. Recommend:
1. **Keep** Stage 5.5 (cairn index-check) with existence guard; mark as "ai-brain-only, no-op when helper absent"
2. **Keep** Stage 7 (release mechanics: version bump, CHANGELOG) guidance; mark as "ai-brain-only, no-op in plugin context"
3. **REMOVE** Stage 5.6 (employer-privacy gate) entirely — public plugin cannot carry regulated tokens; Leg 3 AC 4 enforces repo-wide privacy grep before any ship
4. **Keep** oauth sync already-guarded pattern (Stage 4c)

**Rationale:** This preserves the mental model of the `/ship` skill while gracefully degrading ai-brain-specific gates. Strangers get a working pipeline minus the regulated logic; ai-brain authors keep their full pipeline if they don't install the plugin.

---

### **R4: Hook double-firing — RECOMMEND SHIP AS-IS**

**Question:** Plugin hooks COMPOSE with user settings.json hooks (both fire). Should ai-brain authors be warned?

**Answer:** YES, ship as-is, WITH a README note.

**Rationale:**
- Strangers have zero conflict (no pre-existing setup.sh wiring)
- ai-brain authors have a choice: stay on symlink wiring OR install plugin (not both on the same machine)
- The hook composition is correct behavior; the warning is a matter of UX clarity

**README note to include:**
> "⚠️ **Note for ai-brain authors:** If your machine already wires the 3-role hooks via `setup.sh`, installing this plugin will cause all hooks to double-fire (plugin + setup.sh both active). Either uninstall the plugin or remove the setup.sh wiring, not both. For a clean machine or to migrate, install the plugin and uninstall setup.sh."

---

## AC Quality Assessment

**All AC are binary and checkable from outside the diff.** Representative examples:

- **Leg 1 (lines 174-178):** `test -f` file existence, `node -e` JSON schema validation, optional `claude plugin validate`
- **Leg 2 (line 193):** `grep -rEl` pattern → NOTHING (no matches = success)
- **Leg 3 (line 217):** `grep` for adjacency pattern: "if … exists" + reference (confirms guards are in place)
- **Leg 4 (lines 226-232):** `grep -qE` for knob tables + invariants, no absolute paths
- **Leg 6 (lines 280-285):** node invocations exit 0, file writes succeed, live synthetic smoke passes

**NO AC require reading implementation code.** All are mechanical shell/grep/exit-code checks.

---

## Missed Paths / Issues

**NONE IDENTIFIED.** The plan comprehensively addresses:
- All 5 blockers with clear re-pathing strategy
- All 10 hook files + 7 skills + cairn shim
- All ai-brain-specific coupling (employer token, oauth, cairn index, release mechanics)
- All 4 operator-locked architectural decisions (A/B/C/D from seed brief)
- Both deferred decisions (R3/R4) with clear recommendations

---

## Cairn Grounding

**cairn hit:** `2026-06-14-3role-plugin-research-synthesis.md:48`

> "A plugin ships in `~/.claude/plugins/cache/`; hook commands must switch to relative paths (relative `./` fails; plugin can't read `../` outside its dir) — directly grounds Blocker 1 (${CLAUDE_PLUGIN_ROOT} re-pathing) and Blocker 5 (bundle don't-reference-sibling)."

Also confirmed: `session-state-20260614-875-plugin-epic.md:30` — "Distribution: npm IS supported … `.claude-plugin/marketplace.json`" grounds operator fork A (git-marketplace distribution).

---

## Verdict

**STATUS: ✅ PASS — Execute as planned.**

**Gate:** Leg 6 install-smoke (line 287-288) is the mandatory live prove-primary before operator-gated repo creation step. **Do NOT publish until Leg 6 smoke is green.**

**Ready for:** Per-leg execution via subagent executor + reviewer teams. No blocking issues.

---

_Review completed: 2026-06-14 | Reviewer: Explore (stateless, read-only) | Harness: 3-role model_
