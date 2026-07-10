#!/usr/bin/env bash
# PreToolUse(TaskUpdate) hook — THREE-ROLE INSTRUMENTATION GATE (#847). Sibling of dogfood-artifact-gate.sh
# (#699) and dogfood-improvement-gate.sh (#722) — same PreToolUse(TaskUpdate→completed) seam, same parse +
# fail-open shape.
#
# PORT-NOTE: comments/advisory strings below cite `parent-claude.md Invariant #N` (ai-brain's doctrine file).
#   In the plugin the doctrine ships as 3-role-model.md (Leg 4). Functionally harmless (nothing READS the file);
#   a later leg may re-anchor the prose to 3-role-model.md once its headings are final.
# Doctrine #6 (parent-claude.md `### Development model — 3 roles, orchestrated`): every NON-trivial 3-role run
# is INSTRUMENTED — a per-round perf entry (role / agent_type / did-its-job / miss+root-cause / fix /
# prevention) is appended to the run's model-performance log, and at close each miss completes the
# root-cause → save-learning → fix → prevent loop. Today that instrumentation is Tier-3 voluntary prose
# (KB F2: behavioral-prose-without-consequences ~17% compliant). This gate moves the OBJECTIVE leg of it to a
# Tier-1/2 mechanical check (Rule 17 / KB P6 / P13): a tagged 3-role headline cannot be marked completed
# unless its cited perf-log card actually carries an entry for THIS run.
#
# Both-ends eval (the only reason this is a hook, not an instruction — feedback_run_both_ends_eval...):
#   * recurrence-condition = "a tagged 3-role run is being marked status=completed" — OBJECTIVE: the headline
#     completion carries metadata.model_run (the orchestrator's instrument step sets it at dispatch; value =
#     the perf-log card id/path). Untagged / trivial-skip completions never carry it -> never gated (fail-open
#     like the siblings — a gate never fires on absence).
#   * fix-landed = "the cited perf-log card exists AND contains an entry citing this taskId" — OBJECTIVE over
#     file content (grep the card for the taskId, or accept a clearly-marked run-summary that names it). Both
#     ends are booleans -> a real gate, not acknowledgment-theater. Always satisfiable: append the round/summary
#     entry to the card, then re-complete citing it.
#
# Residual JUDGMENT the gate does NOT check (and must not pretend to): whether the perf entries are honest /
# useful (root-cause quality). Same boundary the dogfood gates draw — they check artifact presence + shape,
# never build quality. That residue keeps doctrine #6 + the /issue-to-ship Stage-6 harvest instruction-class.
#
# cairn-citation legs (#1269): in ADDITION to the perf-card + role-ledger legs, a tagged completion must prove
# BOTH memory-consuming roles searched memory — 4a = the PLANNER's plan carries a `cairn:` line; 4b = the
# plan-REVIEWER's review carries its OWN `cairn:` line (a separate reviews/<id>.md, else a `cairn:` line AFTER
# the in-plan `## Review` header — the awk scan excludes the planner's top-of-file line). These are ARTIFACT
# checks, so the proof is session-INDEPENDENT (MED-2): the planning-time floor gate cannot distinguish the two
# roles under shared subagent session_ids, but the completion-time citations can. Both BLOCK when the artifact
# exists-but-uncited and fail-OPEN when no artifact is discoverable (same can't-tell residual as the perf-card).
#
# Why TaskUpdate, not `gh pr merge`: the merge-gates (enforce-review-or-lfah.sh) honor SHIP_PIPELINE=1 and are
# exempt during the real /ship path, so a perf-gate on that seam would never fire on a genuine 3-role ship. The
# headline TaskUpdate→completed is the "run is done" moment, outside SHIP_PIPELINE, and is exactly what the
# dogfood gates already use.
#
# Fail-open on any missing/unparseable state (no metadata.model_run / no card / unreadable) — mirrors the
# siblings. Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1, SHIP_PIPELINE=1 — EXCEPT #1509's Leg A (tracked-ness),
# which deliberately does NOT honor SHIP_PIPELINE=1 (see the dedicated block below) and carries no bypass flag
# of its own; only THREE_ROLE_INSTRUMENT_OFF=1 (the whole-family master switch) silences it.
# Reference: hooks/dogfood-artifact-gate.sh (resolve_path + parse mirrored), parent-claude.md Invariant #6,
# skills/issue-to-ship/references/3role-perf-log-template.md (the cited card's shape).

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib
# present) silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
INPUT=$(cat)

# Master kill-switch only (consistent with sibling hooks) — disables the WHOLE instrumentation gate family,
# Leg A (#1509) included. SHIP_PIPELINE is deliberately NOT checked here any more: #1509 Leg A (tracked-ness)
# must fire regardless of SHIP_PIPELINE (see the dedicated block below), so the payload must be PARSED before
# any SHIP_PIPELINE short-circuit exists — the family's SHIP_PIPELINE exemption is now applied AFTER Leg A,
# once TASKID/SESSION/MODELRUN are known (moved down from its old position right after this line).
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-instrumentation-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi

# Parse the update payload (node = the dep already required by sibling hooks).
#   STATUS    — tool_input.status
#   TASKID    — sanitized tool_input.taskId
#   SESSION   — sanitized session_id
#   MODELRUN  — tool_input.metadata.model_run on THIS update (the discriminator: perf-log card id/path). "" if absent.
#   PERFPATH  — an explicit perf-log path cited on THIS update: metadata.model_perf_log wins; else, if model_run
#               itself looks like a path (contains "/" or ends .md), use it. "" if none.
#   CODEWORK  — "1" if the completion shows OBJECTIVE code-work evidence (PR / merge / commit-sha / "shipped" /
#               "released vX.Y.Z") in metadata.evidence (+ other metadata string values), else "0" (#1098).
#   SKIPSTATE — "valid" | "invalid" | "none": classification of metadata.three_role_skip. "valid" = a SPECIFIC
#               reason (≥20 chars, not on the non-specific denylist incl. "done"); "invalid" = present but empty /
#               generic; "none" = not supplied (#1098 + plan-review improvement #1).
#   PCWD      — d.cwd on THIS update (the PreToolUse payload carries it), used to derive the plans dir for
#               the #1269 cairn-citation legs. "" if absent (the leg then falls back to CLAUDE_PROJECT_DIR/$PWD).
#   OUTCOME   — md.outcome_eval normalized to lowercase (VEI #1430): the post-ship verdict. "" if absent.
#   OEVSTATE  — "valid" | "invalid" | "none": classification of md.outcome_evidence, reusing the SAME
#               NONSPECIFIC denylist + >=20-char test as SKIPSTATE (VEI #1430).
read -r STATUS TASKID SESSION MODELRUN PERFPATH CODEWORK SKIPSTATE PCWD OUTCOME OEVSTATE < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const ti=d.tool_input||{};
    const cwd=(d.cwd!=null ? String(d.cwd) : "").trim();
    const status=(ti.status||"").toString().replace(/\s+/g," ").trim();
    const taskId=(ti.taskId||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const md=(ti.metadata && typeof ti.metadata==="object") ? ti.metadata : {};
    const modelrun=(md.model_run!=null ? String(md.model_run) : "").trim();
    // cited perf-log path: explicit metadata.model_perf_log wins; else model_run if it itself looks like a path.
    let perf=(md.model_perf_log!=null ? String(md.model_perf_log) : "").trim();
    if(!perf && modelrun && (modelrun.indexOf("/")>=0 || /\.md$/i.test(modelrun))) perf=modelrun;
    // ── #1098 untagged-path classification ──────────────────────────────────────────────────────
    // OBJECTIVE code-work signal over metadata.evidence + every other metadata string value (skip excluded).
    // commit-sha arm uses a lookahead requiring ≥1 hex LETTER so a plain decimal id (e.g. "1098000") is NOT
    // mistaken for a sha; PR / merge / shipped / released-vX.Y.Z are explicit tokens.
    const evParts=[];
    if(md.evidence!=null) evParts.push(String(md.evidence));
    for(const k of Object.keys(md)){ if(k==="three_role_skip"||k==="evidence") continue; const v=md[k]; if(typeof v==="string") evParts.push(v); }
    const evText=evParts.join(" ");
    // #1100 item 5: the released? arm requires the REAL shape — lowercase released/release + whitespace +
    // 'v' + semver (\breleased?\b\s+v\d+\.\d+\.\d+). A hyphenated quarantine dir name like "release-0.70.0"
    // (no 'v', '-' not whitespace) no longer over-fires CODEWORK; a real "released v0.70.0" still does.
    const CODEWORK_RE=/(\bPR\s*#?\d+|\bpull[ _-]?request\b|\bmerged?\b|\b(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b|\bshipped\b|\breleased?\b\s+v\d+\.\d+\.\d+)/i;
    const codework = CODEWORK_RE.test(evText) ? "1" : "0";
    // three_role_skip strength: reuse the ledger NONSPECIFIC denylist semantics AND a ≥20-char minimum, so
    // the plan example "done" (and "n/a"/"skip"/empty) is rejected (plan-review improvement #1).
    const NONSPECIFIC=/^(n\/?a|skip(ped)?|none|null|tbd|inline|done|-+|\.+)$/i;
    let skipstate="none";
    if("three_role_skip" in md){
      const skipRaw=(md.three_role_skip!=null ? String(md.three_role_skip) : "").trim();
      skipstate=(skipRaw==="" || NONSPECIFIC.test(skipRaw) || skipRaw.length<20) ? "invalid" : "valid";
    }
    // outcome_eval leg (VEI #1430): normalize the verdict to lowercase; classify the evidence with the SAME
    // NONSPECIFIC denylist + >=20-char minimum used for three_role_skip (reused, not a second copy of the rule).
    const outcome=(md.outcome_eval!=null ? String(md.outcome_eval) : "").trim().toLowerCase();
    let oevstate="none";
    if("outcome_evidence" in md){
      const oevRaw=(md.outcome_evidence!=null ? String(md.outcome_evidence) : "").trim();
      oevstate=(oevRaw==="" || NONSPECIFIC.test(oevRaw) || oevRaw.length<20) ? "invalid" : "valid";
    }
    const enc=(s)=> (s===""? "-" : encodeURIComponent(s));
    process.stdout.write([status||"-", taskId||"-", session||"-", enc(modelrun), enc(perf), codework, skipstate, enc(cwd), enc(outcome), oevstate].join(" "));
  ' 2>/dev/null
)
# decode helper (paths/ids may contain spaces/encoded chars)
dec(){ [ "$1" = "-" ] && { printf ''; return; }; printf '%b' "${1//%/\\x}"; }
MODELRUN="$(dec "$MODELRUN")"; PERFPATH="$(dec "$PERFPATH")"; PCWD="$(dec "$PCWD")"; OUTCOME="$(dec "$OUTCOME")"

# Only completions matter; anything else (delete / in_progress / metadata edit / unparseable) -> allow.
[ "$STATUS" = "completed" ] || exit 0
[ -n "$TASKID" ] && [ "$TASKID" != "-" ] || exit 0

# ── #1509 Leg A (tracked-ness) — SHIP_PIPELINE-PROOF, runs BEFORE the family's SHIP_PIPELINE exemption ────
# Round-3 review hardening requirement: the rest of this gate family exempts itself under SHIP_PIPELINE=1 (see
# below). If Leg A inherited that exemption unchanged, performing a tagged close INSIDE the ship pipeline would
# skip the tracked-ness check entirely — making SHIP_PIPELINE=1 a de-facto bypass of the exact #861/#1509 leak
# this plan closes. So Leg A is evaluated HERE, before the family's SHIP_PIPELINE short-circuit, and does NOT
# honor SHIP_PIPELINE at all. Scoped like every other ledger leg below: only a TAGGED completion (MODELRUN
# non-empty) with a resolvable SESSION is in scope — an untagged completion is handled by the separate
# untagged-path branch further down (unaffected by this leg). Fail-OPEN when the ledger helper is unavailable
# (mirrors the file's existing HELPER-absence discipline) or when the ledger check reports anything OTHER than
# a "TRACKED:"-prefixed problem (a missing-role / forged-agentId problem here is the EXISTING ledger leg's to
# report below, with its richer per-role message — Leg A only owns the tracked-ness verdict). No grace/bypass
# flag on this leg by design (parent-claude.md #1509: a `*_OFF` here would reopen the leak) — the only escapes
# are (a) git add + commit the cited artifact, or (b) the pre-existing master THREE_ROLE_INSTRUMENT_OFF=1 above
# (which disables the whole family, not a Leg-A-specific bypass).
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
if [ -n "$MODELRUN" ] && [ -n "$SESSION" ] && [ "$SESSION" != "-" ]; then
  if [ -f "$LEDGER_HELPER" ]; then
    TRACKED_OUT="$(node "$LEDGER_HELPER" check --session "$SESSION" --task "$TASKID" --enforce-tracked-artifacts 2>&1)"; TRC=$?
    case "$TRACKED_OUT" in
      *TRACKED:*)
        {
          echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
          echo "  tracked-ness leg FAILED (Leg A, #1509 — SHIP_PIPELINE does NOT exempt this leg): $TRACKED_OUT"
          echo "  A tagged 3-role completion's planner / plan-review / execution-review artifacts must be GIT-TRACKED, not"
          echo "  merely present on disk (the #861 class, 6 recurrences — a reviewer's Bash cwd is the PRIMARY clone, not"
          echo "  the PR worktree, so a bare relative artifact path lands untracked and never ships with the PR)."
          echo "  executor is exempt from this leg BY ROLE (its legitimate artifact is a PR URL / sha / branch string)."
          echo "  Fix: git add + commit the cited artifact (from a Rule-12 worktree), then re-complete. This leg has NO"
          echo "  grace/bypass flag by design — not even SHIP_PIPELINE=1 skips it (adding one would reopen the leak)."
          echo "  Master kill-switch (disables the WHOLE instrumentation gate, not just this leg): THREE_ROLE_INSTRUMENT_OFF=1."
        } >&2
        exit 2
        ;;
      *) : ;;   # not this leg's problem (missing role / forged agentId / etc.) -> the ledger leg below reports it.
    esac
  fi
fi

# Kill-switch for the REST of the family (perf-card, role-presence, model-policy, cairn, outcome-eval legs) —
# Leg A above deliberately does NOT honor this (see its own comment block).
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

# #1276 vacuous-oracle guard: opt the ledger `check` calls into rejecting an execution-review oracle that
# exists + carries a PASS token but is VACUOUS (0 real assertions — all-trivially-true / bare-verdict /
# echo-only). The classifier lives in the synced helper (the only place the oracle path is resolved+read);
# this hook just passes the opt-in flag, gated by the feature kill-switch. The master kill-switch /
# SHIP_PIPELINE already short-circuited above. Empty -> no flag (today's exists+PASS acceptance).
VAC_FLAG="--reject-vacuous-oracle"
[ "${VACUOUS_ORACLE_OFF:-}" = "1" ] && VAC_FLAG=""

# #1448 per-role MODEL-POLICY leg: opt the tagged-path ledger `check` into enforcing each role's ACTUAL
# transcript model (message.model — forgery-resistant) against cc-roles.env. This is a LOAD-BEARING true block
# (exit 2 denies the completion), not an advisory: the seam can deny and the signal cannot be forged. The model
# logic lives in the synced helper (check --enforce-role-models); this hook just passes the opt-in flag, gated
# by the feature kill-switch CC_ROLE_MODEL_GATE_OFF=1 (the helper honors it internally too). No config resolved
# => the helper skips enforcement entirely (fail-safe — all-Opus is the safe default we must not false-block).
# Master THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE already short-circuited above. Empty -> no flag.
# #1458 piggybacks on this SAME flag: when a role's tier matches AND a concrete CC_TIER_<TIER>_VERSION (or
# CC_ROLE_<ROLE>_MODEL_VERSION override) pin is configured, the helper ALSO asserts the transcript model
# equals the pin (assert-latest / fail-on-drift) and emits a `MODEL-VERSION:` problem on mismatch — routed
# below to block_version, distinct from block_model. A dedicated CC_ROLE_VERSION_GATE_OFF=1 disables ONLY that
# version sub-leg (CC_ROLE_MODEL_GATE_OFF=1 above still disables the whole model+version leg). No pin
# configured for a tier/role => the version sub-leg is DORMANT for it (no behavior change, no false-block).
MODEL_FLAG="--enforce-role-models"
[ "${CC_ROLE_MODEL_GATE_OFF:-}" = "1" ] && MODEL_FLAG=""

# DISCRIMINATOR (objective): a TAGGED 3-role run carries metadata.model_run -> the tagged perf-card + ledger
# legs below. UNTAGGED completions (no model_run) are NO LONGER blanket-allowed (#1098 — that opt-in seam is
# exactly how inline-orchestrator code-work slipped both gates): they are routed through the untagged
# fail-CLOSED branch below (defined after the helpers it calls). Only a TRIVIAL untagged completion (no
# objective code-work evidence) still fails open there.

# Resolve a cited path: absolute as-is; else relative to CLAUDE_PROJECT_DIR, then cwd, then $HOME (perf-log
# cards usually live under ~/.claude/agent-working-memory/...). Echoes "" if not found.
resolve_path(){
  local p="$1"
  case "$p" in
    /*) [ -f "$p" ] && printf '%s' "$p" ;;
    \~/*) [ -f "$HOME/${p#\~/}" ] && printf '%s' "$HOME/${p#\~/}" ;;
    *)  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/$p" ]; then printf '%s' "$CLAUDE_PROJECT_DIR/$p"
        elif [ -f "$PWD/$p" ]; then printf '%s' "$PWD/$p"
        elif [ -f "$HOME/$p" ]; then printf '%s' "$HOME/$p"
        elif [ -f "$p" ]; then printf '%s' "$p"; fi ;;
  esac
}

block(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
    echo "  $1"
    echo "  Every NON-trivial 3-role run is INSTRUMENTED (parent-claude.md Invariant #6): the run's model-performance"
    echo "  log must carry an entry for THIS run — a per-round perf entry (role / agent_type / did-its-job / miss+root-cause"
    echo "  / fix / prevention) and/or a run-close SUMMARY that names this taskId. Template:"
    echo "    skills/issue-to-ship/references/3role-perf-log-template.md"
    echo "  Append the entry to the cited card, then re-complete citing it:"
    echo "    TaskUpdate(taskId=${TASKID}, status=completed, metadata={\"model_run\":\"<perf-log card id>\",\"model_perf_log\":\"/abs/path/to/<card>.md\"})"
    echo "  (The card must mention this taskId — '#${TASKID}' or 'task ${TASKID}' — in a round entry or the SUMMARY.)"
    echo "  Kill-switch (not a real 3-role run / retiring a task): THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# Phase 1+2 (#851) block message: the role-LEDGER leg failed (the roles did not provably RUN).
block_ledger(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
    echo "  role-ledger leg FAILED: $1"
    echo "  A tagged 3-role completion must prove the four roles actually RAN (parent-claude.md Invariant #6, #851) —"
    echo "  not just that a perf entry was written. Required roles: planner, plan-review, executor, execution-review."
    echo "  Each role is satisfied by EITHER (a) an agentId that resolves to a real"
    echo "    ~/.claude/projects/*/<session>/subagents/agent-<id>.jsonl transcript (a FORGED agentId has no file -> BLOCK)"
    echo "    plus a well-shaped artifact_path, OR (b) an explicit, SPECIFIC inline-skip:<reason>."
    echo "  execution-review is NEVER inline-skippable (never grade your own homework): give a real reviewer agentId"
    echo "    OR an oracle:<path> (a test-oracle output file that exists with a PASS token). 'ran it inline myself' is NOT valid."
    echo "  Append the missing ledger line(s) (cite the agentId the Agent tool returned for each spawn), then re-complete:"
    echo "    node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" append --session ${SESSION} --task ${TASKID} --role <planner|plan-review|executor|execution-review> --agent <agentId> --artifact <path>"
    echo "    (inline-skip a non-review role: ... --role planner --skip-reason \"<specific reason it was inseparable from live session state>\")"
    echo "  Kill-switch (not a real 3-role run / retiring a task): THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# #1448 per-role MODEL-POLICY leg block message: a role's ACTUAL transcript model contradicts cc-roles.env.
# Load-bearing (forgery-resistant transcript read); the specific per-role expected-vs-actual is carried in $1
# (the ledger `check` output, which names role + expected + actual). Satisfiable two ways: re-run the role on
# the policy tier, OR update cc-roles.env if the policy itself is wrong.
block_model(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
    echo "  model-policy leg FAILED: $1"
    echo "  A tagged 3-role completion must run each role on the model TIER cc-roles.env assigns it (#1448, Option A:"
    echo "  Opus on planner + both review gates, Sonnet on the executor). The check reads the FORGERY-RESISTANT"
    echo "  transcript model (message.model on the role's subagent transcript) — not a claimable field."
    echo "  Fix ONE of: (a) re-run the offending role on the policy tier (pass model:<tier> to the Agent tool), or"
    echo "  (b) if the policy itself is wrong, update the role's CC_ROLE_*_MODEL in config/cc-roles.env."
    echo "  Resolve a role's policy: node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" resolve-role-model --role <role>."
    echo "  Feature kill-switch (skip only this leg): CC_ROLE_MODEL_GATE_OFF=1. Master: THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# #1458 per-role MODEL-VERSION leg block message: a role's ACTUAL transcript model contradicts the concrete
# version cc-roles.env PINS for its tier (assert-latest / fail-on-drift). Distinct from block_model: a version
# drift is a DELIBERATE-update signal (the platform likely moved the tier's latest, or the role ran on an
# unexpected version) — it is NOT fixed by simply re-running the role on the same tier. $1 carries the ledger
# `check` output (names role + the observed id + the pinned id).
block_version(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
    echo "  model-VERSION leg FAILED (assert-latest / fail-on-drift, #1458): $1"
    echo "  A tagged 3-role completion's role transcripts must match the EXACT version cc-roles.env pins for the"
    echo "  role's tier — a mismatch means either the platform silently bumped the tier's latest, or the role ran"
    echo "  on an unexpected version. A version drift is NOT fixed by re-running the role on the same tier."
    echo "  Fix ONE of: (a) if the observed version is the new blessed latest, update the tier's *_VERSION pin in"
    echo "  config/cc-roles.env (then re-run the plugin sync), or (b) investigate why the role ran an unexpected version."
    echo "  Feature kill-switches (skip only the version sub-leg): CC_ROLE_VERSION_GATE_OFF=1, or CC_ROLE_MODEL_GATE_OFF=1"
    echo "  (skips the whole model+version leg). Master: THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# outcome_eval leg (VEI #1430) block message: the post-ship OUTCOME verdict is missing/unknown, or its evidence
# is non-specific. Metadata-only (no card read) => genuinely fail-CLOSED. An honest `missed`/`partial` verdict
# WITH specific evidence is ACCEPTED (it ALLOWS the close) — this block fires ONLY on a missing/unknown verdict
# or absent/generic evidence, never to punish an honest miss (that would only incentivize a false `achieved`).
block_outcome(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} (a tagged 3-role run) completed."
    echo "  outcome_eval leg FAILED: $1"
    echo "  A tagged 3-role completion must record an HONEST post-ship OUTCOME verdict + specific live-evidence"
    echo "  (parent-claude.md Invariant #6, VEI #1430): metadata.outcome_eval in {achieved|partial|missed} AND"
    echo "  metadata.outcome_evidence = a SPECIFIC live-run/production observation (>=20 non-ws chars, not"
    echo "  'done'/'n/a'/generic). A missing or unknown verdict is can't-tell => fail-closed (blocked here)."
    echo "  An honest 'missed'/'partial' WITH evidence is ACCEPTED (it ALLOWS — Phase 3 files the iteration"
    echo "  ticket); the gate never rewards a false 'achieved'. Record the verdict, then re-complete:"
    echo "    TaskUpdate(taskId=${TASKID}, status=completed, metadata={\"model_run\":\"<card>\",\"model_perf_log\":\"/abs/<card>.md\",\"outcome_eval\":\"achieved|partial|missed\",\"outcome_evidence\":\"<specific live evidence>\"})"
    echo "  Durable record: add the \`## OUTCOME\` row to the perf-log card (skills/issue-to-ship/references/3role-perf-log-template.md)."
    echo "  Feature kill-switch (skip only this leg): OUTCOME_EVAL_GATE_OFF=1. Master: THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# ── UNTAGGED path (#1098): opt-IN → opt-OUT, fail-CLOSED ─────────────────────────────────────────────
# Block message for an untagged completion that shows objective code-work evidence but cannot prove the
# 3-role process ran (no resolvable ledger) and offers no valid skip. Names BOTH escapes (Rule-17 both-ends).
block_untagged(){
  {
    echo "THREE-ROLE INSTRUMENTATION GATE (three-role-instrumentation-gate): cannot mark task #${TASKID} completed."
    echo "  This completion shows OBJECTIVE code-work evidence (a PR / merge / commit-sha / 'shipped' / 'released vX.Y.Z'),"
    echo "  but the 3-role process is UNPROVEN: $1"
    echo "  A code-work completion (#1098: untagged is no longer a free pass) must satisfy ONE of:"
    echo "    (a) a resolvable 4-role role-ledger for this run (planner, plan-review, executor, execution-review):"
    echo "          node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" check --session ${SESSION} --task ${TASKID}"
    echo "        append lines with: node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" append --session ${SESSION} --task ${TASKID} --role <role> --agent <agentId> --artifact <path>"
    echo "    (b) an explicit, SPECIFIC metadata.three_role_skip reason (≥20 chars, not 'done'/'n/a'/generic) saying"
    echo "        why the 3-role process was genuinely inapplicable to this completion."
    echo "  Kill-switch (not a real 3-role run / retiring a task): THREE_ROLE_INSTRUMENT_OFF=1."
  } >&2
  exit 2
}

# The untagged branch ALWAYS exits (allow 0 or block 2); past it, MODELRUN is guaranteed non-empty -> tagged legs.
if [ -z "$MODELRUN" ]; then
  # No objective code-work signal -> trivial / doc / restore completion -> allow silent (the fail-OPEN residual).
  [ "$CODEWORK" = "1" ] || exit 0
  # Code-work evidence present. ESCAPE 1: a valid, SPECIFIC metadata.three_role_skip reason.
  [ "$SKIPSTATE" = "valid" ] && exit 0
  # ESCAPE 2: a resolvable 4-role ledger. FAIL-CLOSED on anything unresolvable — never wave through on can't-tell.
  if [ -z "$SESSION" ] || [ "$SESSION" = "-" ]; then
    block_untagged "no session_id on the completion — the role-ledger cannot be resolved (fail-closed)."
  fi
  # Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
  # (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
    UHELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
  else
    UHELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
  fi
  if [ ! -f "$UHELPER" ]; then
    block_untagged "the role-ledger helper (3role-ledger.mjs) is unavailable — cannot verify the 3-role process (fail-closed)."
  fi
  ULEDGER_OUT="$(node "$UHELPER" check --session "$SESSION" --task "$TASKID" $VAC_FLAG 2>&1)"; ULRC=$?
  if [ "$ULRC" != "0" ]; then
    block_untagged "${ULEDGER_OUT:-role-ledger check failed}"
  fi
  echo "THREE-ROLE INSTRUMENTATION GATE: #${TASKID} OK — untagged code-work completion backed by a resolvable 4-role ledger." >&2
  exit 0
fi

# fix-landed leg (objective): the cited perf-log card must EXIST and carry an entry citing this taskId.
[ -n "$PERFPATH" ] || block "No perf-log card path was cited (metadata.model_perf_log, or a path-shaped metadata.model_run)."
CARD="$(resolve_path "$PERFPATH")"
[ -n "$CARD" ] || block "Cited perf-log card '$PERFPATH' not found (resolved against project dir + cwd + \$HOME)."

VERDICT=$(
  CARD_PATH="$CARD" TASKID_ENV="$TASKID" node -e '
    const fs=require("fs");
    let t=""; try{ t=fs.readFileSync(process.env.CARD_PATH,"utf8"); }catch(e){ process.stdout.write("ERR could not read the cited perf-log card"); process.exit(0); }
    const id=(process.env.TASKID_ENV||"").trim();
    if(!id){ process.stdout.write("ERR empty taskId"); process.exit(0); }
    // Match the taskId as a whole token in the card: "#847", "task 847", "847" bounded by non-word chars.
    // Use explicit boundaries (BSD/macOS grep does not honor \b portably; node regex does).
    const esc=id.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    const re=new RegExp("(^|[^0-9A-Za-z_])#?(?:task\\s+)?"+esc+"([^0-9A-Za-z_]|$)","im");
    if(re.test(t)){ process.stdout.write("OK perf-log card carries an entry citing #"+id); }
    else { process.stdout.write("ERR the cited perf-log card has NO entry citing this run (#"+id+")"); }
  ' 2>/dev/null
)
case "$VERDICT" in
  OK*) : ;;  # passes the gate
  *)   block "${VERDICT:-ERR could not validate the perf-log card}." ;;
esac

# ── Phase 1+2 (#851): role-LEDGER leg ──────────────────────────────────────────────────────────────
# In ADDITION to the perf-card leg above, a tagged 3-role completion must carry a per-task role ledger
# proving the four roles actually RAN: each role EITHER (a) an agentId that resolves to a real
# ~/.claude/projects/*/<session>/subagents/agent-<id>.jsonl transcript (a forged agentId has no file ->
# BLOCK) + a well-shaped artifact, OR (b) an explicit, SPECIFIC inline-skip reason. execution-review is
# NEVER inline-skippable (Invariant #3, never-self-review) — it needs a real reviewer agentId or a
# test-oracle:<path> that exists. The flat sibling helper encapsulates the check; same kill-switches above.
# Fail-OPEN (allow, note it) only when the helper or the session id is unavailable — never silently brick
# a tagged completion if the helper symlink is missing; the perf-card leg already passed by this point.
# ($LEDGER_HELPER is resolved once, near the top of the script — reused here so #1509's Leg A block and this
# leg share ONE resolution site, which also keeps the plugin-sync HELPER_RE transform correct: it only
# relabels a bare `LEDGER_HELPER=/HELPER=/UHELPER=` assignment, so introducing a differently-named variable
# here would silently port un-relabeled and resolve to the wrong path inside the plugin.)
# SESSION-absence FAILS CLOSED: a legit tagged 3-role run ALWAYS carries a session_id, so a tagged completion
# with no usable session cannot have its ledger verified. Without this block the whole ledger leg would be
# skipped and the gate would collapse to the forgeable perf-card check (the #970-review bypass). Blocking on a
# missing session on a tagged run has zero false-block cost.
if [ -z "$SESSION" ] || [ "$SESSION" = "-" ]; then
  block_ledger "model_run-tagged completion but no session_id — cannot verify the role ledger; this is required (a legit 3-role run always carries a session_id)."
fi
# HELPER-absence stays fail-OPEN (allow, note it) — never silently brick a tagged completion if the symlink is
# missing; the perf-card leg already passed by this point.
if [ -f "$LEDGER_HELPER" ]; then
  # #1448: $MODEL_FLAG adds the per-role MODEL-POLICY enforcement (empty when CC_ROLE_MODEL_GATE_OFF=1).
  LEDGER_OUT="$(node "$LEDGER_HELPER" check --session "$SESSION" --task "$TASKID" $VAC_FLAG $MODEL_FLAG 2>&1)"; LRC=$?
  if [ "$LRC" != "0" ]; then
    # Route to a MODEL-specific block message when the failure is a model-policy mismatch (the ledger prefixes
    # those problems with `MODEL-POLICY:`); otherwise the role-presence/ledger message.
    case "$LEDGER_OUT" in
      *MODEL-VERSION:*) block_version "$LEDGER_OUT" ;;
      *MODEL-POLICY:*)  block_model "$LEDGER_OUT" ;;
      *)                block_ledger "${LEDGER_OUT:-role-ledger check failed}" ;;
    esac
  fi
  LEDGER_NOTE=" + ledger OK${MODEL_FLAG:+ + model-policy OK}"
else
  LEDGER_NOTE=" + ledger SKIPPED (helper unavailable — fail-open)"
fi

# ── cairn-citation legs (#1269) ─────────────────────────────────────────────────────────────────────
# A tagged completion must prove BOTH memory-consuming roles searched memory: 4a = the PLANNER's plan must
# carry a `cairn:` receipt line; 4b = the plan-REVIEWER's review must carry its OWN `cairn:` line. Both are
# ARTIFACT checks, so the guarantee is session-INDEPENDENT — the planning-time floor gate
# (cairn-search-before-planning.sh) cannot, under shared subagent session_ids, distinguish the two roles;
# these completion-time artifact citations do (MED-2 resolution). Fail-OPEN when the artifact is not
# discoverable (can't-tell, mirrors the perf-card ERR->allow residual); BLOCK when the artifact EXISTS but
# carries no `cairn:` line. Placed AFTER the perf-card + ledger legs already hold (LOW-2: the receipt rides
# on top of the heavier instrumentation). Plans-dir from a DEFINED chain (HIGH-1, never the round-1 empty
# $CWD): THREE_ROLE_PLANS_DIR (test override) -> $PCWD (parser-emitted cwd) -> $CLAUDE_PROJECT_DIR -> $PWD.
PLANS_DIR="${THREE_ROLE_PLANS_DIR:-${PCWD:-${CLAUDE_PROJECT_DIR:-$PWD}}/.ai-workspace/plans}"
REVIEWS_DIR="${PLANS_DIR%/plans}/reviews"

# 4a doc — resolve the PLANNER's plan from the 3-role LEDGER's artifact_path for THIS task (#1303 —
# authoritative, task-scoped). This closes the #1266 failure modes: a lane that files its plan under docs/
# (not .ai-workspace/) is no longer invisible, and a NEWER stranger file in the convention dir is no longer
# grabbed by ls -t. Fall back to the convention dir + newest-file ONLY when the ledger has no usable
# artifact_path (helper absent, no planner line, no/empty artifact_path, or a dangling path) — nothing regresses.
APLAN=""
if [ -f "$LEDGER_HELPER" ] && [ -n "$SESSION" ] && [ "$SESSION" != "-" ]; then
  APLAN="$(node "$LEDGER_HELPER" resolve-artifact --session "$SESSION" --task "$TASKID" --role planner 2>/dev/null)"
fi
{ [ -n "$APLAN" ] && [ -f "$APLAN" ]; } || APLAN="$(ls -t "$PLANS_DIR"/*.md 2>/dev/null | head -1)"

if [ -n "$APLAN" ] && [ -f "$APLAN" ]; then
  # 4a — the planner's plan must carry a `cairn:` line. (PRESENCE check UNCHANGED.)
  grep -Eiq '^[[:space:]]*cairn:' "$APLAN" 2>/dev/null \
    || block "the active plan ($APLAN) carries no \`cairn:\` citation line — prove the PLANNER searched memory (cairn/AWM/project-index). Add a \`cairn: \"<hit>\"\` or \`cairn: no hits for <q>\` line, then re-complete. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1."

  # 4b doc — resolve the plan-REVIEWER's review from the LEDGER's plan-review artifact_path for THIS task
  # (#1303), then fall back to the convention reviews dir (reviews/<taskId>.md, else the newest reviews/*.md).
  AREVIEW=""
  if [ -f "$LEDGER_HELPER" ] && [ -n "$SESSION" ] && [ "$SESSION" != "-" ]; then
    AREVIEW="$(node "$LEDGER_HELPER" resolve-artifact --session "$SESSION" --task "$TASKID" --role plan-review 2>/dev/null)"
  fi
  if [ -z "$AREVIEW" ] || [ ! -f "$AREVIEW" ]; then
    if [ -f "$REVIEWS_DIR/$TASKID.md" ]; then AREVIEW="$REVIEWS_DIR/$TASKID.md"
    else AREVIEW="$(ls -t "$REVIEWS_DIR"/*.md 2>/dev/null | head -1)"; fi
  fi
  # A review doc that is a SEPARATE file from the plan -> its own `cairn:` line. When the ledger points the
  # plan-review artifact AT THE PLAN FILE itself (in-plan `## Review`), AREVIEW == APLAN: route to the awk
  # `## Review` scan (which EXCLUDES the planner's top-of-file cairn: line) so the planner's line can NEVER
  # satisfy 4b (the #1269 invariant — and STRICTER for the in-plan case, never looser).
  # Fail-OPEN only when NEITHER form exists (can't-tell); BLOCK when a review IS present but uncited.
  if [ -n "$AREVIEW" ] && [ -f "$AREVIEW" ] && [ "$AREVIEW" != "$APLAN" ]; then
    grep -Eiq '^[[:space:]]*cairn:' "$AREVIEW" 2>/dev/null \
      || block "the plan-review ($AREVIEW) carries no \`cairn:\` citation line — the plan-reviewer must independently search memory and cite it. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1."
  elif grep -Eq '^## Review' "$APLAN" 2>/dev/null; then
    awk '/^## Review/{r=1} r&&/^[[:space:]]*[Cc]airn:/{found=1} END{exit !found}' "$APLAN" 2>/dev/null \
      || block "the plan-review (## Review section in $APLAN) carries no \`cairn:\` citation line — the plan-reviewer must independently search memory and cite it. Kill-switch: THREE_ROLE_INSTRUMENT_OFF=1."
  fi
fi

# ── outcome_eval leg (VEI #1430) ─────────────────────────────────────────────────────────────────────
# Placed AFTER the cairn block's `fi` (TOP-LEVEL, NOT nested inside `if [ -n "$APLAN" ]`) so it fires on the
# SOLE tagged ALLOW exit below — a tagged completion with no discoverable plan (APLAN empty) still reaches it,
# so every tagged completion is gated (nesting it would create an APLAN-empty bypass). A tagged 3-role
# completion must record an HONEST post-ship OUTCOME verdict + specific live-evidence in its metadata
# (parent-claude.md Invariant #6, VEI): metadata-only (no card read) => genuinely fail-CLOSED. Both checks must
# hold, else block_outcome (exit 2). An honest `missed`/`partial` verdict WITH evidence ALLOWS — Phase 3 turns
# it into the next iteration ticket; blocking an honest miss would only reward a false `achieved`. Feature
# kill-switch OUTCOME_EVAL_GATE_OFF=1 skips ONLY this leg (mirrors VACUOUS_ORACLE_OFF); the master
# THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE switches already short-circuited at the top.
if [ "${OUTCOME_EVAL_GATE_OFF:-}" != "1" ]; then
  # (2a) the verdict must be one of the three honest values — absent / any other string => can't-tell => BLOCK.
  case "$OUTCOME" in
    achieved|partial|missed) : ;;
    *) block_outcome "no valid metadata.outcome_eval verdict (got '${OUTCOME:-<absent>}'; must be one of achieved|partial|missed)." ;;
  esac
  # (2b) the evidence must be SPECIFIC (present, >=20 non-ws chars, not on the NONSPECIFIC denylist).
  [ "$OEVSTATE" = "valid" ] \
    || block_outcome "metadata.outcome_evidence is ${OEVSTATE:-absent} — needs specific live-run/production evidence (>=20 chars, not 'done'/'n/a'/generic)."
fi

# Allow + a brief confirming note (non-blocking).
echo "THREE-ROLE INSTRUMENTATION GATE: #${TASKID} OK — $VERDICT [$CARD]${LEDGER_NOTE}." >&2
exit 0
