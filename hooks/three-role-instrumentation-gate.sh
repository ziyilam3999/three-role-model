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
# Why TaskUpdate, not `gh pr merge`: the merge-gates (enforce-review-or-lfah.sh) honor SHIP_PIPELINE=1 and are
# exempt during the real /ship path, so a perf-gate on that seam would never fire on a genuine 3-role ship. The
# headline TaskUpdate→completed is the "run is done" moment, outside SHIP_PIPELINE, and is exactly what the
# dogfood gates already use.
#
# Fail-open on any missing/unparseable state (no metadata.model_run / no card / unreadable) — mirrors the
# siblings. Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1, SHIP_PIPELINE=1.
# Reference: hooks/dogfood-artifact-gate.sh (resolve_path + parse mirrored), parent-claude.md Invariant #6,
# skills/issue-to-ship/references/3role-perf-log-template.md (the cited card's shape).

INPUT=$(cat)

# Kill-switches (consistent with sibling hooks).
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

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
read -r STATUS TASKID SESSION MODELRUN PERFPATH CODEWORK SKIPSTATE < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){}
    const ti=d.tool_input||{};
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
    const enc=(s)=> (s===""? "-" : encodeURIComponent(s));
    process.stdout.write([status||"-", taskId||"-", session||"-", enc(modelrun), enc(perf), codework, skipstate].join(" "));
  ' 2>/dev/null
)
# decode helper (paths/ids may contain spaces/encoded chars)
dec(){ [ "$1" = "-" ] && { printf ''; return; }; printf '%b' "${1//%/\\x}"; }
MODELRUN="$(dec "$MODELRUN")"; PERFPATH="$(dec "$PERFPATH")"

# Only completions matter; anything else (delete / in_progress / metadata edit / unparseable) -> allow.
[ "$STATUS" = "completed" ] || exit 0
[ -n "$TASKID" ] && [ "$TASKID" != "-" ] || exit 0

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
  ULEDGER_OUT="$(node "$UHELPER" check --session "$SESSION" --task "$TASKID" 2>&1)"; ULRC=$?
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
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi
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
  LEDGER_OUT="$(node "$LEDGER_HELPER" check --session "$SESSION" --task "$TASKID" 2>&1)"; LRC=$?
  if [ "$LRC" != "0" ]; then
    block_ledger "${LEDGER_OUT:-role-ledger check failed}"
  fi
  LEDGER_NOTE=" + ledger OK"
else
  LEDGER_NOTE=" + ledger SKIPPED (helper unavailable — fail-open)"
fi

# Allow + a brief confirming note (non-blocking).
echo "THREE-ROLE INSTRUMENTATION GATE: #${TASKID} OK — $VERDICT [$CARD]${LEDGER_NOTE}." >&2
exit 0
