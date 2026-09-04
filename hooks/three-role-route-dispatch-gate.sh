#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE ROUTE-DISPATCH GATE (#1989, redesigned #2189). A LEADING-EDGE
# advisory sibling of three-role-model-policy-gate.sh (same PreToolUse(Agent|Task) seam). It catches an
# Agent-tool spawn of a seat the routes SSOT (config/cc-routes.json) declares `dispatch: subprocess-openrouter`
# for (today: plan-review, executor) — a spawn that, because a provider endpoint binds once at `claude` launch
# (#1685/#1917), structurally cannot reach that seat's declared non-Anthropic model and silently lands on the
# `agent_tool_fallback` tier instead.
#
# POLICY: config/cc-routes.json `seats.<role>.dispatch == "subprocess-openrouter"` is the SSOT. The hook reads
# it FRESH through the ledger helper (`resolve-route --seat <role> --json`) — never a hand-rolled JSON parse,
# never a hardcoded role list, so a future seat flip is covered automatically. The ONLY path that reaches a
# subprocess-openrouter seat's declared model is the hermetic `claude -p` OS subprocess via
# tools/openrouter-role-dispatch.sh; an in-session Agent-tool call cannot redirect the provider.
#
# #2189 — CONSERVATIVE MODE IS NOW A PERSISTENT, EVIDENCE-GATED REFUSAL (not a block-once advisory, and NOT
# clearable by the inline prompt token anymore). Before #2189: a tagged spawn of a subprocess-declared seat in
# conservative mode got a block-once advisory (exit 2 once, then silently exit 0 forever after — MEASURED, arm
# B2), and any spawn carrying the literal text `[route-dispatch-fallback-ok]` cleared it INSTANTLY regardless
# of mode or seat (MEASURED, arm A) — an agent-typeable magic word that laundered the gate with zero audit
# trail. #2189 closes both holes for the IN-SCOPE case (conservative mode + a subprocess-declared seat +
# a tagged role/task/session):
#   - The refusal is now PERSISTENT: an identical re-issue refuses again (no `.notified`/block-once marker for
#     this decision at all — the marker mechanism is gone, not merely un-consulted).
#   - The inline prompt token no longer clears it. It is ordinary prompt text now, parsed only for an
#     informational note in the refusal message. D3: "the gate closes INTENT, not forgery" — round 2 proved a
#     hand-typed or hand-authored-receipt-row signal is forgeable, so no signal an agent can TYPE into a
#     prompt or a TRACKED repo file opens this refusal anymore.
#   - Exactly THREE things clear it (D4): (1) a REAL failed subprocess dispatch for the SAME role+task,
#     recorded by tools/openrouter-role-dispatch.sh itself as an untracked, role+task-keyed marker under
#     CC_ROUTE_DISPATCH_STATE_DIR (this gate reads ONLY that marker — it NEVER opens the tracked receipt file,
#     .ai-workspace/status/1947-seat-mix-live-smoke.md, which round 2 proved is forgeable free text); (2) the
#     operator turning the mode dial to normal (an honest `set-mode`, not a prompt token); (3) the operator's
#     own audited env kill-switch (CC_ROUTE_DISPATCH_GATE_OFF / THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE — set
#     in the operator's OWN environment, never typed into a prompt).
# Everything OUTSIDE that in-scope case (untagged spawns, non-subprocess-declared seats, non-conservative
# modes, unresolvable SSOT/mode) is UNCHANGED: silent exit 0, no advisory, no marker, no log row — a routine
# spawn must never be false-blocked or false-nudged.
#
# Escapes are audit-logged (never silent): every evidence-escape and kill-switch-escape appends an ENRICHED
# row to $RULE12_LOG (default ~/.claude/.rule-12-overrides.log) naming the hook, the resolved MODE, the ROLE,
# the TASK id, and the escape kind — none of the five empty (#2189 AC-6; ticket scope item 4, and the real
# half of #2187's "zero audit trace" premise). The shared hooks/3role-ledger.mjs `log-bypass` path
# (hook_log_bypass, still called for the kill-switch escapes for cross-hook convention) CANNOT carry this
# hook's resolved MODE — its CLI has no --mode flag, and #2189 deliberately leaves hooks/3role-ledger.mjs
# UNTOUCHED (route (ii): the evidence lives in an untracked state-dir marker, never a ledger field) — so this
# hook writes its OWN enriched JSONL row directly to the SAME log file, additively, alongside whatever
# hook_log_bypass also wrote.
#
# BLOCK-ONCE (still used, elsewhere): the ONLY remaining state-dir writes this hook makes are none at all for
# the refusal decision itself — no `.notified` sentinel is written on refusal anymore (the #2189 redesign
# removes it outright, which structurally closes the r2 N6 hazard: a self-clearing sentinel cannot exist if
# the gate never writes one). The evidence markers this hook READS are written exclusively by
# tools/openrouter-role-dispatch.sh on its own real (non-drill) failure paths — this hook never writes them.
#
# Env overrides (for the smoke): CC_ROUTE_DISPATCH_STATE_DIR (default
# ~/.claude/.three-role-route-dispatch-state); CC_ROUTES_JSON points resolve-route at a fixture config;
# CC_ROUTE_DISPATCH_EVIDENCE_WINDOW_HOURS (default 4 — #2189 N5: short enough that a marker licenses "right
# after a failed dispatch", not "sometime this fortnight"; well under the state dir's own 14-day GC TTL).
# No `set -e` (a non-block non-zero must never leak into a permission decision — #749).
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/three-role-model-policy-gate.sh (the block-once sibling),
# hooks/3role-ledger.mjs (resolve-route, resolve-mode), tools/openrouter-role-dispatch.sh (the evidence-marker
# writer), the plans .ai-workspace/plans/2026-07-27-1989-agent-tool-route-bypass.md and
# .ai-workspace/plans/2026-08-01-2189-mode-to-model-class.md.

# #1543 — source the shared write-time bypass-audit writer (hook_log_bypass), if not already.
# This file is ALSO ported to the public three-role-model plugin (Population B), which does NOT ship
# lib-hook-override.sh — every call site below is `type`-guarded so a plugin install (no wrapper lib present)
# silently no-ops instead of erroring; ai-brain installs (lib present) log normally.
OVERRIDE_LIB="$(dirname "${BASH_SOURCE[0]}")/lib-hook-override.sh"
[ -f "$OVERRIDE_LIB" ] && . "$OVERRIDE_LIB"
set -u

INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

STATE_DIR="${CC_ROUTE_DISPATCH_STATE_DIR:-$HOME/.claude/.three-role-route-dispatch-state}"
TTL_DAYS="${CC_ROUTE_DISPATCH_TTL_DAYS:-14}"
EVIDENCE_WINDOW_HOURS="${CC_ROUTE_DISPATCH_EVIDENCE_WINDOW_HOURS:-4}"

# Resolve the ledger helper (config logic lives there — this hook stays thin). Sibling flat file whether run
# from the repo or the ~/.claude/hooks/ symlink; the plugin sync rewrites this line to a ${CLAUDE_PLUGIN_ROOT}/bin block.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi

# Parse role, session, taskId, and the (now informational-only) inline token, in ONE node pass.
# Emits "<role|-> <session|-> <taskId|-> <bypass 0|1>" or "" on a fatal parse error (-> fail-open).
ROLE=""; SESSION=""; TASKID=""; BYPASS=""
read -r ROLE SESSION TASKID BYPASS < <(
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    const role = mRole ? mRole[1].toLowerCase() : "-";
    const taskId = mTask ? mTask[1] : "-";
    const bypass = /\[route-dispatch-fallback-ok\]/i.test(prompt) ? "1" : "0";
    process.stdout.write([role, (session||"-"), taskId, bypass].join(" ") + "\n");
  ' 2>/dev/null
)

# Fatal parse error (node printed nothing) -> fail-open.
[ -n "$ROLE" ] || exit 0
# Not a tagged role spawn -> fail-open (the norm). Need BOTH the role AND a real task tag, REGARDLESS of the
# inline token (#2189 AC-5(b) / N4 fold — the token must never be consulted ahead of scope determination).
[ "$ROLE" != "-" ] || exit 0
[ "$TASKID" != "-" ] || exit 0
# No usable session cannot be keyed reliably -> fail-open.
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# Resolve the routes SSOT — does this seat declare dispatch=subprocess-openrouter right now? Read FRESH
# through the helper (never hardcoded), so a future seat flip is covered automatically. Fail-open on ANY
# unresolvable SSOT: `resolve-route --seat <unknown>` exits 2 with a non-JSON ROUTE-SEAT-NOT-FOUND line on
# stdout, so the fail-open keys on JSON-parse success + a real dispatch field, NEVER on empty output.
[ -f "$LEDGER_HELPER" ] || exit 0
ROUTE_JSON=$(node "$LEDGER_HELPER" resolve-route --seat "$ROLE" --json 2>/dev/null)
SEAT_MODEL=""; SEAT_DISPATCH=""
read -r SEAT_MODEL SEAT_DISPATCH < <(
  ROUTE_PAYLOAD="$ROUTE_JSON" node -e '
    let r=""; try{ r=JSON.parse(process.env.ROUTE_PAYLOAD||""); }catch(e){ process.exit(0); }
    const model = (r && typeof r.model === "string") ? r.model : "";
    const dispatch = (r && typeof r.dispatch === "string") ? r.dispatch : "";
    // model may contain a provider slash (e.g. moonshotai/kimi-k3, z-ai/glm-5.2); keep it, strip whitespace.
    process.stdout.write(model.replace(/\s/g,"") + " " + dispatch.replace(/[^0-9A-Za-z._-]/g,"") + "\n");
  ' 2>/dev/null
)
# Only seats declared subprocess-openrouter are in scope. Every other seat (planner/execution-review/research,
# or a seat whose row carries no dispatch field) and any SSOT-unresolvable case fail-opens silently, REGARDLESS
# of the inline token (#2189 AC-5(a)/(c) — token consideration never happens ahead of seat determination).
[ "$SEAT_DISPATCH" = "subprocess-openrouter" ] || exit 0

# --- #2105 D3 backstop: mode-awareness ---------------------------------------------------------------------
# In non-conservative mode the Agent-tool spawn of this seat IS the sanctioned primary (D3's own dispatch
# helpers refuse the subprocess-openrouter path themselves outside conservative mode) — so this gate stays
# COMPLETELY SILENT: no advisory, no marker write, no audit line, REGARDLESS of the inline token (#2189
# AC-4(a) — a normal-mode spawn must never be nudged, let alone refused, and the token must never be
# consulted ahead of the mode check). Fail-open on any mode-resolution failure (a crashed resolver here is
# still advisory-only, unlike the lane doorman/dispatch helpers — MODE_VAL stays empty, which is !=
# "conservative", so this ALSO fails open silently).
MODE_RESOLVE_OUT="$(node "$LEDGER_HELPER" resolve-mode 2>/dev/null)"
MODE_VAL="$(printf '%s\n' "$MODE_RESOLVE_OUT" | command grep -m1 '^mode=' | cut -d= -f2)"
[ "$MODE_VAL" = "conservative" ] || exit 0

# --- IN SCOPE from here: tagged role/task/session, seat declared subprocess-openrouter, mode=conservative ---

# #2189 AC-6 — enriched escape-audit writer. hooks/3role-ledger.mjs's shared log-bypass path (hook_log_bypass)
# cannot carry this hook's resolved MODE (its CLI has no --mode flag, and #2189 deliberately leaves that file
# untouched — D4/Approach). So this hook writes its OWN enriched JSONL row directly, appended to the SAME
# $RULE12_LOG file every other hook's bypass audit uses — additive, never a schema assumption elsewhere.
# $1 = escape_kind token (evidence | kill-switch:<VAR>). Best-effort; a logging failure never blocks the gate.
route_dispatch_log_escape() {
  local kind="$1" logf
  logf="${RULE12_LOG:-$HOME/.claude/.rule-12-overrides.log}"
  MODE_ESCAPE_VAL="$MODE_VAL" ROLE_ESCAPE_VAL="$ROLE" TASK_ESCAPE_VAL="$TASKID" KIND_ESCAPE_VAL="$kind" LOGF_VAL="$logf" node -e '
    const fs = require("fs"), path = require("path");
    try {
      const rec = {
        ts: new Date().toISOString(),
        hook: "three-role-route-dispatch-gate",
        mode: process.env.MODE_ESCAPE_VAL || "",
        role: process.env.ROLE_ESCAPE_VAL || "",
        task: process.env.TASK_ESCAPE_VAL || "",
        escape_kind: process.env.KIND_ESCAPE_VAL || "",
      };
      fs.mkdirSync(path.dirname(process.env.LOGF_VAL), { recursive: true });
      fs.appendFileSync(process.env.LOGF_VAL, JSON.stringify(rec) + "\n");
    } catch (e) { /* best-effort — never blocks the gate decision */ }
  ' 2>/dev/null
  return 0
}

# --- D4 escape (3): the operator's own audited env kill-switch. Checked FIRST among the in-scope escapes
#     (cheapest, and the most explicit operator signal). hook_log_bypass is ALSO called (cross-hook logging
#     convention — its task/role fields land empty in this PreToolUse(Agent) context, which is exactly why the
#     enriched writer above exists too), so both a generic AND an enriched row land. -------------------------
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  route_dispatch_log_escape "kill-switch:THREE_ROLE_INSTRUMENT_OFF"
  exit 0
fi
if [ "${CC_ROUTE_DISPATCH_GATE_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "CC_ROUTE_DISPATCH_GATE_OFF" "PERMIT" "${INPUT:-}"
  route_dispatch_log_escape "kill-switch:CC_ROUTE_DISPATCH_GATE_OFF"
  exit 0
fi
if [ "${SHIP_PIPELINE:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "SHIP_PIPELINE" "PERMIT" "${INPUT:-}"
  route_dispatch_log_escape "kill-switch:SHIP_PIPELINE"
  exit 0
fi

# --- D4 escape (1): a recorded REAL (non-drill) dispatch failure for this SAME role+task, evidenced by an
#     untracked marker under $STATE_DIR — never the tracked receipt file (round-2 B1: a receipt row is
#     forgeable free text in a file normal work already edits). Keyed by role+task (never session — a failed
#     dispatch and its fallback spawn need not share a session, D4's measured constraint), bounded in age by
#     mtime (CC_ROUTE_DISPATCH_EVIDENCE_WINDOW_HOURS, default 4h), namespaced `.evidence` — DISTINCT from any
#     legacy `.notified` sentinel (r2 N6 — this gate no longer writes `.notified` at all, which structurally
#     closes the self-clearing hazard: there is nothing here to misread as evidence). ------------------------
mkdir -p "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (unchanged convention).
EVSIG="$(
  ROLE_SIG_VAL="$ROLE" TASK_SIG_VAL="$TASKID" node -e '
    const crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha1").update(process.env.ROLE_SIG_VAL + ":" + process.env.TASK_SIG_VAL).digest("hex"));
  ' 2>/dev/null
)"
EVIDENCE_OK=0
if [ -n "$EVSIG" ]; then
  EVIDENCE_MARKER="$STATE_DIR/$EVSIG.evidence"
  if [ -f "$EVIDENCE_MARKER" ]; then
    AGE_OK="$(
      MARKER_PATH_VAL="$EVIDENCE_MARKER" WINDOW_HOURS_VAL="$EVIDENCE_WINDOW_HOURS" node -e '
        const fs = require("fs");
        try {
          const st = fs.statSync(process.env.MARKER_PATH_VAL);
          const ageH = (Date.now() - st.mtimeMs) / 3600000;
          process.stdout.write(ageH <= Number(process.env.WINDOW_HOURS_VAL) ? "1" : "0");
        } catch (e) { process.stdout.write("0"); }
      ' 2>/dev/null
    )"
    [ "$AGE_OK" = "1" ] && EVIDENCE_OK=1
  fi
fi
if [ "$EVIDENCE_OK" = "1" ]; then
  route_dispatch_log_escape "evidence"
  exit 0
fi

# --- No escape applies: PERSISTENT refusal. No marker is written here (nothing to write — the refusal is not
#     block-once anymore, so there is no "already told them" state to record). An identical re-issue of this
#     exact payload refuses again (#2189 AC-2). -------------------------------------------------------------
NOTE=""
if [ "$BYPASS" = "1" ]; then
  NOTE=" (note: this spawn carries [route-dispatch-fallback-ok] — that inline token no longer clears this refusal; #2189 removed the in-band clear entirely, see below)"
fi
cat >&2 <<EOF
<system-reminder>
THREE-ROLE ROUTE-DISPATCH GATE (three-role-route-dispatch-gate hook, #1989/#2189): the seat ROLE:${ROLE} for
3ROLE_TASK:${TASKID} is declared dispatch=subprocess-openrouter (model ${SEAT_MODEL}) in the routes SSOT
(config/cc-routes.json), and the operator's mode pin is CONSERVATIVE — so this Agent-tool spawn is REFUSED,
PERSISTENTLY${NOTE}. Run the sanctioned subprocess dispatch instead:
    bash tools/openrouter-role-dispatch.sh --role ${ROLE} --brief <brief-path> --task ${TASKID}
(A provider endpoint binds once at \`claude\` launch — #1685/#1917 — so an Agent-tool call structurally cannot
reach this seat's declared non-Anthropic model.) This refusal has NO in-band clear: no inline token, no prompt
content, and nothing typed into any tracked repo file opens it (#2189 D3 — "the gate closes INTENT, not
forgery"). Exactly three things clear it: (1) a REAL failed subprocess dispatch for this same role+task
already ran and recorded its own failure-evidence marker (an untracked, out-of-band signal this gate reads —
never the tracked receipt file); (2) the operator turns the dial to normal:
node hooks/3role-ledger.mjs set-mode --mode normal --reason "<why>"; or (3) the operator's own audited
kill-switch CC_ROUTE_DISPATCH_GATE_OFF=1 set in THEIR OWN environment (never a token typed into a prompt). If
(1) already happened for this exact role+task, re-issue this spawn now — it will proceed.
</system-reminder>
EOF
exit 2
