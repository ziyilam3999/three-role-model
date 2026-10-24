#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE ROUTE-DISPATCH GATE (#1989). A LEADING-EDGE advisory sibling of
# three-role-model-policy-gate.sh (same PreToolUse(Agent|Task) seam, same BLOCK-ONCE shape). It catches an
# Agent-tool spawn of a seat the routes SSOT (config/cc-routes.json) declares `dispatch: subprocess-openrouter`
# for (today: plan-review, executor) — a spawn that, because a provider endpoint binds once at `claude` launch
# (#1685/#1917), structurally cannot reach that seat's declared non-Anthropic model and silently lands on the
# `agent_tool_fallback` tier instead. Before #1989 this was invisible by design: the fallback "safely
# resolves", the model-policy gate sees expected==actual, and the ledger row is indistinguishable from a
# healthy run. This gate makes the bypass VISIBLE at spawn time (advisory block-once), and the trailing-edge
# ROUTE-BYPASS: advisory in `3role-ledger.mjs check` makes it visible at close-out too.
#
# POLICY: config/cc-routes.json `seats.<role>.dispatch == "subprocess-openrouter"` is the SSOT. The hook reads
# it FRESH through the ledger helper (`resolve-route --seat <role> --json`) — never a hand-rolled JSON parse,
# never a hardcoded role list, so a future seat flip is covered automatically. The ONLY path that reaches a
# subprocess-openrouter seat's declared model is the hermetic `claude -p` OS subprocess via
# tools/openrouter-role-dispatch.sh; an in-session Agent-tool call cannot redirect the provider.
#
# RESPONSE DECISION: BLOCK-ONCE (exit 2, VISIBLE to the model — a PreToolUse hook's stderr reaches the agent
# only on exit 2; the #769 lesson). First time a given session:task:role signature is seen -> exit 2 (the
# orchestrator SEES the nudge + either dispatches the subprocess or re-issues the spawn marked as a sanctioned
# fallback), drop a per-signature marker, then fall through to exit 0 on the re-issue so a deliberate spawn is
# NEVER permanently wedged. Advisory-with-override per repo convention (parent-claude.md), NOT a hard block.
#
# EVERYTHING ELSE FAIL-OPENS (exit 0 silent): not a tagged role spawn (no 3ROLE_TASK + ROLE), a seat NOT
# declared subprocess-openrouter (incl. planner/execution-review/research, and any SSOT-unresolvable case —
# `resolve-route --seat <unknown>` exits 2 with a non-JSON ROUTE-SEAT-NOT-FOUND line, so the fail-open keys on
# JSON-parse success, NEVER on empty output), no usable session, node/helper absent, any parse error. A bare
# Agent spawn is the NORM and must never be false-blocked.
#
# BLOCK-ONCE keying: sha1(session + ":" + taskId + ":" + role) — per session:task:role. A genuinely different
# role OR task has a different signature and blocks again. A routed seat whose OTHER role is also subprocess-
# declared has its OWN signature (no cannibalization — AC-4).
#
# Escapes: inline bypass token `[route-dispatch-fallback-ok]` in the prompt (deliberate sanctioned fallback,
# distinct from `[model-policy-ok]`); dedicated kill-switch `CC_ROUTE_DISPATCH_GATE_OFF=1`; family switch
# `THREE_ROLE_INSTRUMENT_OFF=1`; ship-pipeline exempt `SHIP_PIPELINE=1`.
#
# #1989 N1 — EVERY escape is audit-logged, INCLUDING the inline token. The cited precedent
# (`hooks/three-role-model-policy-gate.sh:126`) exits 0 on its inline token WITHOUT logging (only its env
# kill-switches log). Copying that precedent here would ship an UNLOGGED escape hatch by a ticket whose whole
# subject is silent bypasses — so this hook logs the inline-token escape too (pinned by AC-5's scratch-log
# assertion: >=2 rows naming this hook across the inline-token + CC_ROUTE_DISPATCH_GATE_OFF invocations).
# The family switches (THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE) are logged here as well -- the plan's
# Direction-2 prose says "every escape is audit-logged", and this hook implements that prose as written
# (the model-policy gate logs THREE_ROLE_INSTRUMENT_OFF but not SHIP_PIPELINE; this one logs both).
#
# No absolute `$HOME`/`/Users/` paths in the hook's stderr (N5): the helper is named repo-relatively
# (`tools/openrouter-role-dispatch.sh`) — hook stderr gets quoted into committed artifacts, and a literal
# home path carries the operator's macOS username (the exact leak the helper's own to_tilde() prevents).
#
# #2985 — z.ai routing policy (PROVIDER=zai seats only; every other provider keeps the behaviour above):
#   * executor: the spawn prompt must name exactly ONE plan (.ai-workspace/plans/<file>.md). The ledger helper
#     (resolve-route --plan) answers from the plan's flush-left `size: S|M|L` line and `data-class:` line:
#     L bound to this task -> an Agent-tool spawn at the seat's agent_tool_fallback tier is
#     the FIRST-CLASS route (exit 0, no marker, no bypass-audit row). S/M -> today's block-once. A missing /
#     duplicated / invalid label, zero or 2+ distinct plans, a nonexistent plan or a task mismatch -> exit 2,
#     REPEATED (no marker): it fails closed to no dispatch, never to a default model.
#   * #3060: an executor L public plan stays on the subprocess route (the resolver yields subprocess-zai, so the
#     S/M block-once path applies) until the task has 2 z.ai strikes, when the resolver yields agent-tool and the
#     Sonnet spawn is silent again. `ROLE:research` is a recognised tag: once the SSOT declares the research seat
#     subprocess-zai, EVERY Agent-tool research spawn takes the generic block-once path (no private exemption).
#   * plan-review: z.ai first EVERY round. The Opus fallback token is honoured only when the round has >= 2
#     recorded strikes (`zai-strikes`, receipts-derived) or the z.ai key file is absent. Below that the block
#     repeats. (#3078: a `data-class:` operator-private label is a recorded fact on every plan, never a reroute
#     -- a private plan-review brief takes the same path as a public one.)
# INPUT-BOUND (#2985): at most the first 1 MiB of the prompt is scanned, at most 3 distinct plan paths are
# examined, and each plan file is read through the resolver's 1 MiB cap -- per-spawn work is O(1 MiB).
#
# #3190 — RECEIPT-BASED NEEDLE ADMISSION (the #2888 deadlock fix). When the dispatcher refuses a brief with
# its positive-control needle lint (exit 9), it writes an OR-DISPATCH-REFUSED reason=NEEDLE-LINT receipt row
# (task + a 16-hex SHA-256 fingerprint of the brief's bytes). An executor spawn prompt may then carry exactly
# ONE flush-left `BRIEF: <path>` line (path resolved like PLAN:, against this hook's cwd); the gate transports
# it to `resolve-route --brief` and admits via the resolver ONLY (effective_dispatch=agent-tool = the existing
# silent first-class exit). This gate holds NO needle predicate and reads no path list: typing a BRIEF: line
# into a prompt admits nothing unless the dispatcher's lint actually flagged those exact bytes for that task.
# Two or more distinct BRIEF: paths -> BRIEF-AMBIGUOUS repeat-block; a brief that does not exist (or is over
# the resolver's 1 MiB cap) -> BRIEF-UNRESOLVABLE repeat-block. Both fail closed, no marker. Zero BRIEF: lines
# -> byte-identical to the pre-#3190 gate.
#
# #3344 — CROSS-REPO PLAN:/BRIEF:. A relative PLAN: or BRIEF: path that does not exist under this hook's cwd (the
# ai-brain primary) is resolved against the SPAWN TICKET'S OWN repo: the ticket's metadata.repo primary, the
# worktree(s) the prompt names (<projects>/<repo>/.claude/worktrees/<slug>, <= 3), and that repo's <task>-*
# worktrees. The gate only TRANSPORTS the session + worktree hints (--session/--worktrees); the bounded base set,
# and every size/bound check, live in the resolver (3role-ledger.mjs xrepoResolveRel). Not found anywhere ->
# the same SIZE-PLAN-UNRESOLVABLE / BRIEF-UNRESOLVABLE repeat-block as before (fail closed).
#
# Env overrides (for the smoke): CC_ROUTE_DISPATCH_STATE_DIR (default
# ~/.claude/.three-role-route-dispatch-state); CC_ROUTES_JSON points resolve-route at a fixture config (the
# same fixture mechanism 3role-ledger-smoke-test.sh already uses 15x). No `set -e` (a non-block non-zero must
# never leak into a permission decision — #749).
# PORT-NOTE: cites `parent-claude.md Invariant #6` (ai-brain doctrine); plugin ships doctrine as 3-role-model.md
#   (Leg 4). Comment only — safe forward-ref. The ledger helper now lives at bin/3role-ledger.mjs.
# Reference: parent-claude.md Invariant #6, hooks/three-role-model-policy-gate.sh (the block-once sibling),
# hooks/3role-ledger.mjs (resolve-route, seatDispatchIsSubprocess), the plan
# .ai-workspace/plans/2026-07-27-1989-agent-tool-route-bypass.md.

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

# Kill-switches (full exemption, no state mutation). EVERY escape audit-logged (N1) — including the inline
# token below. `${INPUT}` is already captured above so the audit row at minimum carries the real session id
# — NOT a claim every field is populated: this hook normally fires from the orchestrator's own
# PreToolUse(Agent|Task) dispatch, whose payload carries no agent_id, so cmdLogBypass's own attribution
# logic (3role-ledger.mjs) leaves agent/task empty and role falling to the orchestrator sentinel. Passing
# INPUT is still strictly better than losing the session id too, never a claim of full attribution.
if [ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "THREE_ROLE_INSTRUMENT_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
if [ "${CC_ROUTE_DISPATCH_GATE_OFF:-}" = "1" ]; then
  type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "CC_ROUTE_DISPATCH_GATE_OFF" "PERMIT" "${INPUT:-}"
  exit 0
fi
[ "${SHIP_PIPELINE:-}" = "1" ] && { type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "SHIP_PIPELINE" "PERMIT" "${INPUT:-}"; exit 0; }

STATE_DIR="${CC_ROUTE_DISPATCH_STATE_DIR:-$HOME/.claude/.three-role-route-dispatch-state}"
TTL_DAYS="${CC_ROUTE_DISPATCH_TTL_DAYS:-14}"

# Resolve the ledger helper (config logic lives there — this hook stays thin). Sibling flat file whether run
# from the repo or the ~/.claude/hooks/ symlink; the plugin sync rewrites this line to a ${CLAUDE_PLUGIN_ROOT}/bin block.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi

# Parse role, session, taskId, the inline bypass token, and the block-once SIGNATURE in ONE node pass.
# Emits "<role|-> <session|-> <taskId|-> <bypass 0|1> <sig>" or "" on a fatal parse error (-> fail-open).
# Reads the joined prompt+description+message field set (same bypass-form coverage as the model-policy gate).
ROLE=""; SESSION=""; TASKID=""; BYPASS=""; SIG=""; ROUNDV="-"
PHASH="-"
read -r ROLE SESSION TASKID BYPASS SIG ROUNDV PHASH < <(
  HOOK_INPUT="$INPUT" node -e '
    const crypto=require("crypto");
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor|research)/i);
    const role = mRole ? mRole[1].toLowerCase() : "-";
    const taskId = mTask ? mTask[1] : "-";
    const bypass = /\[route-dispatch-fallback-ok\]/i.test(prompt) ? "1" : "0";
    const sig=crypto.createHash("sha1").update((session||"-")+":"+(taskId||"-")+":"+role).digest("hex");
    const mRound=prompt.slice(0,1048576).match(/^ROUND: ([0-9]{1,6})[ \t]*$/m);
    const phash=crypto.createHash("sha1").update(prompt).digest("hex").slice(0,12);
    process.stdout.write([role, (session||"-"), taskId, bypass, sig, mRound ? mRound[1] : "-", phash].join(" ") + "\n");
  ' 2>/dev/null
)

# Fatal parse error (node printed nothing) -> fail-open.
[ -n "$SIG" ] || exit 0
# Inline bypass -> exit 0 (deliberate sanctioned fallback), LOGGED (N1 — never silent, unlike the cited precedent).
# #2985: a TAGGED plan-review spawn defers the token decision (strike rule below); every other spawn is unchanged.
# #3357: the 5th arg names the spawn target so override-used counts one permit per spawn (a retried spawn
# logs one row per attempt). Tagged -> "<task>:<role>"; untagged -> "u:<12-hex hash of the spawn text>" so
# DIFFERENT untagged spawns stay distinct while an identical retry still collapses (review F2).
_rd_spawn_key() {
  if [ "${TASKID:--}" != "-" ] && [ "${ROLE:--}" != "-" ]; then printf '%s:%s' "$TASKID" "$ROLE"; else printf 'u:%s' "${PHASH:--}"; fi
}
log_inline_token() { type hook_log_bypass >/dev/null 2>&1 && hook_log_bypass "three-role-route-dispatch-gate" "INLINE_TOKEN" "PERMIT" "${INPUT:-}" "$(_rd_spawn_key)"; }
# fail_open: the silent exit-0 of every "not in scope" case; a deferred plan-review token still gets its audit row.
fail_open() { [ "$BYPASS" = "1" ] && log_inline_token; exit 0; }
if [ "$BYPASS" = "1" ] && ! { [ "$ROLE" = "plan-review" ] && [ "$TASKID" != "-" ]; }; then
  log_inline_token
  exit 0
fi
# Not a tagged role spawn -> fail-open (the norm). Need BOTH the role AND a real task tag.
[ "$ROLE" != "-" ] || fail_open
[ "$TASKID" != "-" ] || fail_open
# No usable session cannot be keyed reliably -> fail-open (the trailing-edge ROUTE-BYPASS advisory is the backstop).
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || fail_open

# Resolve the routes SSOT — does this seat declare dispatch=subprocess-openrouter right now? Read FRESH
# through the helper (never hardcoded), so a future seat flip is covered automatically. Fail-open on ANY
# unresolvable SSOT: `resolve-route --seat <unknown>` exits 2 with a non-JSON ROUTE-SEAT-NOT-FOUND line on
# stdout (round-1 verified), so the fail-open keys on JSON-parse success + a real dispatch field, NEVER on
# empty output.
[ -f "$LEDGER_HELPER" ] || fail_open
ROUTE_JSON=$(node "$LEDGER_HELPER" resolve-route --seat "$ROLE" --json 2>/dev/null)
SEAT_MODEL=""; SEAT_DISPATCH=""; SEAT_FALLBACK=""
# #3520 -- SEAT_FALLBACK: the seat's agent_tool_fallback tier, read from the SAME fresh payload (used by
# the #3349 admission's fallback tier and the per-signature advisory's tier parenthetical below, so
# neither text stays a memorized copy of the SSOT).
read -r SEAT_MODEL SEAT_DISPATCH SEAT_FALLBACK < <(
  ROUTE_PAYLOAD="$ROUTE_JSON" node -e '
    let r=""; try{ r=JSON.parse(process.env.ROUTE_PAYLOAD||""); }catch(e){ process.exit(0); }
    const model = (r && typeof r.model === "string") ? r.model : "";
    const dispatch = (r && typeof r.dispatch === "string") ? r.dispatch : "";
    const fallback = (r && typeof r.agent_tool_fallback === "string") ? r.agent_tool_fallback : "";
    // model may contain a provider slash (e.g. moonshotai/kimi-k3, z-ai/glm-5.2); keep it, strip whitespace.
    process.stdout.write(model.replace(/\s/g,"") + " " + dispatch.replace(/[^0-9A-Za-z._-]/g,"") + " " + fallback.replace(/[^a-z]/g,"") + "\n");
  ' 2>/dev/null
)
# Any seat declared `subprocess-<provider>` is in scope (#2518 generalization of the #1989 openrouter-only
# proxy — the ledger's own prefix test, isSubprocessDispatch). Every other seat (planner/execution-review/
# research, or a seat whose row carries no dispatch field) and any SSOT-unresolvable case fail-opens silently.
case "$SEAT_DISPATCH" in
  subprocess-*) ;;
  *) fail_open ;;
esac
PROVIDER="${SEAT_DISPATCH#subprocess-}"

# --- #2105/#2518 D3 backstop: mode-awareness, keyed on THIS seat's OWN provider axis ------------------------
# Generalizes the #1989 "== conservative" proxy (which stood in for openrouter_dispatch=permitted, the only
# axis that existed then): the axis that matters is the resolved mode's <provider>_dispatch value for THIS
# seat's declared provider, never a hardcoded mode name. When that axis is "permitted" the subprocess route
# is live, so an Agent-tool spawn of this seat IS a real bypass — fire. When it is "forbidden" the dispatch
# helper would refuse the subprocess route too, so the Agent-tool fallback is the sanctioned primary and
# this gate stays COMPLETELY SILENT: no advisory, no marker write, no audit line (firing on every sanctioned
# spawn would train every routine spawn to carry the bypass token, deadening the gate for the case it exists
# to catch). Concretely: conservative + subprocess-openrouter still fires (openrouter_dispatch=permitted
# there, unchanged from pre-#2518 behavior); hybrid + subprocess-zai now ALSO fires (zai_dispatch=permitted
# in hybrid); hybrid + subprocess-openrouter and normal + subprocess-zai both stay silent (each axis is
# forbidden under that mode) — hybrid never re-opens the OpenRouter door. Fail-open on any mode-resolution
# failure or an unresolvable provider axis (a crashed resolver here is still advisory-only, unlike the lane
# doorman/dispatch helpers, so the existing fail-open-on-any-parse-error convention already covers it —
# AXIS_VAL stays empty, which is != "permitted", so this ALSO fails open silently; that is the correct
# direction for a hook whose whole job is "stay out of the way unless the subprocess route is actually live").
MODE_RESOLVE_OUT="$(node "$LEDGER_HELPER" resolve-mode 2>/dev/null)"
MODE_VAL="$(printf '%s\n' "$MODE_RESOLVE_OUT" | command grep -m1 '^mode=' | cut -d= -f2)"
AXIS_VAL="$(printf '%s\n' "$MODE_RESOLVE_OUT" | command grep -m1 "^${PROVIDER}_dispatch=" | cut -d= -f2)"
[ "$AXIS_VAL" = "permitted" ] || fail_open

# --- #3349: a CLOSED z.ai quota window admits the seat's FIRST-CLASS Claude fallback with ZERO strikes ---------
# #2785 refuses every z.ai role before spend while the window is CLOSED and writes zero strikes, so the 2-strike
# rule below could never be earned: the seat could neither run nor fall back until the reset. The window verdict
# comes from the ledger's zai-window-admit verb (the ONE window CLI, tools/zai-window.sh, same receipt + reset
# parsing as the dispatcher's pre-flight). admit=1 -> exit 0 for ANY z.ai seat (plan-review with or without the
# token, executor of any size, research, a pinned planner), no marker, no bypass row (a first-class route, like
# the #2985 L route), and the reason (window + reset + until) goes back to the orchestrator as PreToolUse
# additionalContext. admit=0 (OPEN, NEAR, an unanswerable or unparseable window) -> fall through to the
# unchanged rules below (fail closed). A reopened window answers OPEN, so z.ai-first resumes by itself.
if [ "$PROVIDER" = "zai" ]; then
  WIN_LINE="$(node "$LEDGER_HELPER" zai-window-admit --role "$ROLE" 2>/dev/null | head -1)"
  case "$WIN_LINE" in
    "admit=1 state=CLOSED reset="*" until="*)
      WIN_RESET="$(printf '%s' "$WIN_LINE" | sed -n 's/.* reset=\([0-9a-z]*\) until=.*/\1/p')"
      WIN_UNTIL="$(printf '%s' "$WIN_LINE" | sed -n 's/.* until=\([0-9]*\)$/\1/p')"
      # #3520 -- the fallback tier is the seat's OWN agent_tool_fallback, read FRESH from the same
      # resolve-route payload this gate already resolved (never the memorized plan-review/other-role
      # split). Byte-identical for every existing z.ai seat (plan-review opus; executor/research/
      # fast-track sonnet, verified at HEAD); an unresolvable tier fails to "unknown", never a guess.
      WIN_MODEL="${SEAT_FALLBACK:-unknown}"
      WIN_MSG="THREE-ROLE ROUTE-DISPATCH GATE (#3349): z.ai quota window CLOSED (reset=${WIN_RESET} until=${WIN_UNTIL}) -- ROLE:${ROLE} for 3ROLE_TASK:${TASKID} takes its first-class Claude fallback (model:${WIN_MODEL}) with 0 strikes; the 2-strike rule is skipped because every z.ai dispatch is refused before spend until the window reopens (tools/zai-window.sh status). z.ai-first resumes by itself when the window reopens."
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$WIN_MSG"
      exit 0 ;;
  esac
fi

# --- #3520: a SAFETY-area tagged Agent-tool ER spawn is the SANCTIONED PRIMARY, not a fallback -----------
# The dispatcher refuses the z.ai ER dispatch for carve-out areas BEFORE any spend (its ER-SAFETY-AREA
# exit 20), so the Opus Agent-tool ER spawn IS that review's primary route: silent exit 0, no marker, no
# advisory, no audit row -- the same first-class shape as the #2985 L-at-fallback and #3349 CLOSED-window
# admission routes above (firing on every sanctioned spawn would train every routine spawn to carry the
# bypass token, the deadening failure the mode-awareness comment above names). The carve-out list is read
# FRESH from the SSOT seat row this gate already resolved (its safety_areas field, spread by resolve-route
# --json; NEVER a hardcoded area list in this hook). A spawn binding NO resolvable flush-left `Area: <area-id>`
# line (an area id is 1-3 digits plus an optional lowercase-letter suffix, e.g. 4b) fails closed to the
# per-signature advisory below, never a guess. #3520 fix1: ids compare AS STRINGS (the SSOT list carries
# them as strings), and a missing, empty or unreadable safety_areas list fails CLOSED here too (every area
# treated as safety -> silence), never open (N1). #3520 fix2 (B1-r2): BOTH sides of the compare are
# normalised through the ONE shared helper area-id-normalize.cjs (resolved beside this hook; leading zeros
# stripped from the digit part, letter kept: "04" names area 4, "04b" names 4b), so a zero-padded spelling
# of a safety area can never miss the carve-out and dispatch to z.ai via the advisory; an all-zero id
# ("0", "00") is malformed and fails closed to the advisory (the dispatcher then refuses it at its bind).
# #3520 fix2 (N1-r2): the silence is keyed on PROVIDER=zai, verified EXHAUSTIVE 2026-10-24 -- no other
# non-Opus provider can serve the ER seat today (SSOT row zai; the overlay's execution-review refs that
# same row with the local slot kept off the ER; no openrouter ER row). Widen to "provider != anthropic"
# in the same PR as any future ER route change, never let the carve-out silently stop applying.
if [ "$ROLE" = "execution-review" ] && [ "$PROVIDER" = "zai" ]; then
  # ABSOLUTE (the dispatcher's SCRIPT_DIR idiom): a relative path here would make the node -e require()
  # below treat it as a bare module specifier and fail to load the helper whenever the hook is invoked
  # repo-relatively (measured: `bash hooks/three-role-route-dispatch-gate.sh` from the repo root) -- the
  # silence parse then crashes to the advisory instead of staying the sanctioned safety silence.
  AREA_ID_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/area-id-normalize.cjs"
  ER_GA_AREA="$(AREA_ID_HELPER="$AREA_ID_HELPER" HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=>(x==null?"":String(x))).join("\n").slice(0,1048576);
    const m=prompt.match(/^Area:[ \t]*([0-9]{1,3}[a-z]?)[ \t]*$/m);
    if (!m) process.exit(0);
    try { process.stdout.write(require(process.env.AREA_ID_HELPER).normaliseAreaId(m[1]) || ""); }
    catch (e) { process.exit(1); }   // helper unreadable: no id -> the advisory below (fail closed; the dispatcher refuses too)
  ' 2>/dev/null)"
  if [ -n "$ER_GA_AREA" ]; then
    ER_GA_MATCH="$(AREA_ID_HELPER="$AREA_ID_HELPER" ROUTE_PAYLOAD="$ROUTE_JSON" AREA_VAL="$ER_GA_AREA" node -e '
      const { normaliseAreaId } = require(process.env.AREA_ID_HELPER);
      let j; try { j=JSON.parse(process.env.ROUTE_PAYLOAD||""); } catch(e){ process.stdout.write("yes"); process.exit(0); }
      const raw=j.safety_areas;
      const areas=Array.isArray(raw)&&raw.length>0?raw:null;
      if (areas===null) { process.stdout.write("yes"); process.exit(0); }        // missing/empty list: every area safety (fix1 N1)
      const want=normaliseAreaId(process.env.AREA_VAL);
      if (want===null) { process.stdout.write("yes"); process.exit(0); }         // unnormalisable: fail closed to silence
      const norms=areas.map(normaliseAreaId);
      process.stdout.write(norms.some(n=>n===null)||norms.indexOf(want)>=0?"yes":"no");  // malformed entry: closed
    ' 2>/dev/null)"
    # #3520 fix2 (N2-r2): the ONLY non-silence is a DECIDED non-match ("no"). A missing/empty list, an
    # unparseable payload AND any matcher error (node crash, unreadable helper -> empty) all stay SILENT
    # (fail closed toward the Opus Agent-tool ER, the sanctioned route) -- the gate never fails open to
    # the z.ai advisory on an undecided carve-out.
    [ "$ER_GA_MATCH" != "no" ] && exit 0
  fi
fi

# --- #2985: z.ai seats are routed by the plan (executor) / the strike rule (plan-review) -----------------------
# emit_repeat_block TOKEN DETAIL: exit 2 on EVERY call (the predicate is deterministic and re-checkable, so no
# marker is written -- a marker would turn a fail-closed refusal into a one-time nudge). No home path in stderr.
emit_repeat_block() {
  cat >&2 <<EOF2
<system-reminder>
THREE-ROLE ROUTE-DISPATCH GATE (#2985): ROLE:${ROLE} for 3ROLE_TASK:${TASKID} -- ${1}: ${2}
This refusal REPEATS (no block-once marker): the z.ai routing policy is fail-closed. Remedy for an executor: name
exactly one plan (PLAN: .ai-workspace/plans/<file>.md) that carries one flush-left \`size: S|M|L\` line and is bound
to this task, then dispatch via tools/openrouter-role-dispatch.sh (S/M, and L below 2 z.ai strikes on the task; an L
plan at 2+ strikes is the first-class model:sonnet spawn; a \`data-class:\` label is recorded, never a reroute #3078).
#3190 receipt route: if tools/openrouter-role-dispatch.sh refused this seat's brief with its needle lint (#2888, exit 9),
the refusal's receipt row is itself the first-class remedy -- re-issue this Agent-tool spawn carrying PLAN: <that plan> AND
BRIEF: <the refused brief's path> (exactly one BRIEF: line); the gate admits the Sonnet spawn only for that exact task+brief.
Remedy for a
plan-review: dispatch tools/openrouter-role-dispatch.sh --role plan-review first; the Opus fallback token is
honoured only after 2 same-round strikes (3role-ledger.mjs zai-strikes --task ${TASKID} --role plan-review --round <n>).
</system-reminder>
EOF2
  exit 2
}
# prompt_plans: distinct plan paths cited in the prompt, one per line (max 3 -- 2+ is already ambiguous).
prompt_plans() {
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=>(x==null?"":String(x))).join("\n").slice(0,1048576);
    const re=new RegExp("[.\\w/-]*\\.ai-workspace/plans/[^\\s\"\x27`)]+\\.md","g");
    const seen=[]; let m;
    while((m=re.exec(prompt))!==null){ if(!seen.includes(m[0])){ seen.push(m[0]); if(seen.length>=3) break; } }
    process.stdout.write(seen.join("\n"));
  ' 2>/dev/null
}
# #3190 — prompt_briefs: distinct flush-left `BRIEF: <path>` paths cited in the prompt, one per line
# (max 3 -- 2+ is already ambiguous). Mirrors prompt_plans: same joined prompt+description+message field set,
# same 1 MiB scan cap, same repo-relative path transport (resolved by the resolver against this hook's cwd,
# exactly like PLAN:). The gate itself holds NO needle predicate and reads no path list -- it only transports
# the path to `resolve-route --brief`, where a needle-lint receipt row (if any) admits the first-class route.
prompt_briefs() {
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=>(x==null?"":String(x))).join("\n").slice(0,1048576);
    const seen=[]; let m; const re=/^BRIEF:[ \t]*([^\s"\x27`)]+)[ \t]*$/gm;
    while((m=re.exec(prompt))!==null){ if(!seen.includes(m[1])){ seen.push(m[1]); if(seen.length>=3) break; } }
    process.stdout.write(seen.join("\n"));
  ' 2>/dev/null
}
# #3344 — prompt_worktrees: distinct absolute .../.claude/worktrees/<slug> paths the prompt names (max 3), one per
# line. Transported to the resolver as cross-repo hints; the resolver accepts only <projects>/<repo>/.claude/
# worktrees/<slug> shapes (and the ticket's own repo when it names one). Never echoed into stderr (N5).
prompt_worktrees() {
  HOOK_INPUT="$INPUT" node -e '
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=>(x==null?"":String(x))).join("\n").slice(0,1048576);
    const re=/\/[^\s"\x27`)]*\/\.claude\/worktrees\/[0-9A-Za-z._-]+/g;
    const seen=[]; let m;
    while((m=re.exec(prompt))!==null){ if(!seen.includes(m[0])){ seen.push(m[0]); if(seen.length>=3) break; } }
    process.stdout.write(seen.join("\n"));
  ' 2>/dev/null
}
json_field() { ROUTE_PAYLOAD="$2" node -e 'try{const j=JSON.parse(process.env.ROUTE_PAYLOAD||"");const v=j[process.argv[1]];process.stdout.write(v===undefined?"":String(v));}catch(e){}' "$1" 2>/dev/null; }

if [ "$PROVIDER" = "zai" ] && [ "$ROLE" = "plan-review" ]; then
  # #3078 -- a `data-class: operator-private` label never admits the inline fallback token and never
  # silently permits a spawn: a private plan-review brief takes the SAME block-once path as a public one.
  STRIKES=0
  if [ "$ROUNDV" != "-" ]; then
    STRIKES=$(node "$LEDGER_HELPER" zai-strikes --task "$TASKID" --role plan-review --round "$ROUNDV" 2>/dev/null)
    case "$STRIKES" in ""|*[!0-9]*) STRIKES=0 ;; esac
  fi
  KEYF=""
  case "$PROVIDER" in
    *[!a-z0-9]*) ;;
    *) KEYVAR="$(printf '%s' "$PROVIDER" | tr 'a-z' 'A-Z')_KEY_FILE"; KEYF="$(eval "printf '%s' \"\${$KEYVAR:-}\"")" ;;
  esac
  [ -n "$KEYF" ] || KEYF="$HOME/.config/${PROVIDER}.prod.env"
  ADMIT=0
  [ "$STRIKES" -ge 2 ] && ADMIT=1
  [ -f "$KEYF" ] || ADMIT=1
  if [ "$BYPASS" = "1" ] && [ "$ADMIT" = "1" ]; then log_inline_token; exit 0; fi
  if [ "$BYPASS" = "1" ]; then
    emit_repeat_block "FALLBACK-NOT-ADMITTED" "the inline fallback token is honoured only after 2 same-round z.ai strikes (this round: ${STRIKES}) or a missing z.ai key file -- dispatch tools/openrouter-role-dispatch.sh --role plan-review (round ${ROUNDV}) first"
  fi
  emit_repeat_block "ZAI-FIRST" "plan-review is dispatched on z.ai every round (strikes this round: ${STRIKES}; a ROUND: <n> line in the prompt keys the count). Opus fallback after 2 strikes: re-issue with the inline token"
fi

if [ "$PROVIDER" = "zai" ] && [ "$ROLE" = "executor" ]; then
  PLANS_EX="$(prompt_plans)"
  NPL=0; [ -n "$PLANS_EX" ] && NPL=$(printf '%s
' "$PLANS_EX" | grep -c .)
  [ "$NPL" -ne 0 ] || emit_repeat_block "SIZE-PLAN-UNRESOLVABLE" "the spawn prompt names no .ai-workspace/plans/<file>.md path, so the plan is unresolvable (add a PLAN: line)"
  [ "$NPL" -eq 1 ] || emit_repeat_block "SIZE-PLAN-AMBIGUOUS" "the spawn prompt names ${NPL}+ distinct plan paths -- ambiguous; name exactly one"
  # #3190 — BRIEF: transport (see prompt_briefs above). Two or more DISTINCT paths -> ambiguous (repeat-block,
  # fail closed, no marker); zero -> today's behaviour exactly; one -> passed to resolve-route --brief, whose
  # needle-receipt admission (dispatcher #2888 refusal row for THIS task + the exact brief bytes) comes back
  # as effective_dispatch=agent-tool: the same silent first-class exit below, no token, no audit row.
  BRIEFS_EX="$(prompt_briefs)"
  NBR=0; [ -n "$BRIEFS_EX" ] && NBR=$(printf '%s
' "$BRIEFS_EX" | command grep -c .)
  [ "$NBR" -le 1 ] || emit_repeat_block "BRIEF-AMBIGUOUS" "the spawn prompt names ${NBR}+ distinct BRIEF: paths -- ambiguous; name exactly one (the refused brief the dispatcher's needle-lint receipt was written for)"
  # #3344: --session + --worktrees let the resolver look in the ticket's own repo when a relative path is absent here.
  WT_HINTS="$(prompt_worktrees)"
  if [ "$NBR" -eq 1 ]; then
    RJ=$(node "$LEDGER_HELPER" resolve-route --seat executor --plan "$PLANS_EX" --task "$TASKID" --brief "$BRIEFS_EX" --session "$SESSION" --worktrees "$WT_HINTS" --json 2>/dev/null); RJRC=$?
  else
    RJ=$(node "$LEDGER_HELPER" resolve-route --seat executor --plan "$PLANS_EX" --task "$TASKID" --session "$SESSION" --worktrees "$WT_HINTS" --json 2>/dev/null); RJRC=$?
  fi
  { [ "$RJRC" -eq 0 ] && [ -n "$RJ" ]; } || {
    # The resolver validated --brief BEFORE --plan (#3190): a nonexistent/oversized brief is BRIEF-UNRESOLVABLE,
    # never masked by the plan verdict. The brief path itself is never echoed into stderr (N5 home-path rule).
    printf '%s' "$RJ" | command grep -q 'BRIEF-UNRESOLVABLE' && emit_repeat_block "BRIEF-UNRESOLVABLE" "the BRIEF: line names no existing readable brief file at or under the resolver's 1 MiB input bound (fail closed; re-issue naming the exact brief the dispatcher refused)"
    emit_repeat_block "SIZE-PLAN-UNRESOLVABLE" "${PLANS_EX} is unresolvable (not an existing file under .ai-workspace/plans/ here, in the ticket's metadata.repo, or in a worktree the prompt names)"
  }
  SZ_SRC="$(json_field size_source "$RJ")"; DCLS="$(json_field data_class "$RJ")"; EFFD="$(json_field effective_dispatch "$RJ")"
  [ "$DCLS" != "invalid" ] || emit_repeat_block "DATA-CLASS-INVALID" "${PLANS_EX} carries a malformed data-class line (public|operator-private only)"
  case "$SZ_SRC" in
    plan) ;;
    task-mismatch) emit_repeat_block "SIZE-TASK-MISMATCH" "${PLANS_EX} is not bound to 3ROLE_TASK:${TASKID} (task-mismatch: its name lacks the task id and it has no flush-left Ticket: #${TASKID} line)" ;;
    missing) emit_repeat_block "SIZE-LABEL-MISSING" "${PLANS_EX} has no flush-left size: line (missing)" ;;
    ambiguous) emit_repeat_block "SIZE-LABEL-AMBIGUOUS" "${PLANS_EX} has more than one size: line (ambiguous)" ;;
    *) emit_repeat_block "SIZE-LABEL-INVALID" "${PLANS_EX} has a size: line that is not exactly S, M or L (invalid)" ;;
  esac
  # First-class route: L at the fallback tier -> Agent-tool spawn. Not a bypass: silent.
  [ "$EFFD" = "agent-tool" ] && exit 0
fi

# --- per-signature block-once marker ---
mkdir -p "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (mirrors the model-policy gate).
MARKER="$STATE_DIR/$SIG.notified"
# Already nudged for THIS session:task:role -> let the spawn proceed (block-once, not wedged — the
# orchestrator can never be wedged when the subprocess route is genuinely down).
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null

# #3520 — the advisory's fallback-tier parenthetical is rendered from FRESH resolve-route reads of every
# subprocess-dispatchable seat's agent_tool_fallback (never the memorized "model:opus (plan-review) /
# model:sonnet (executor, research)" split): seats are grouped opus-first in the fixed order below.
# Pre-flip this rendered BYTE-IDENTICAL to the old hardcoded text (plan-review opus; executor+research
# sonnet; execution-review resolved no dispatch/fallback so it dropped out). A seat whose resolve fails,
# carries no dispatch field or no fallback tier is OMITTED, never guessed; if the render itself fails the
# parenthetical names THIS seat's own fresh tier alone. Runs once per session:task:role (after the marker
# write), so the extra resolve calls never sit on the hot path of a routine spawn.
ADV_TIER_TXT="$(LEDGER_HELPER_ARG="$LEDGER_HELPER" node -e '
  const cp = require("child_process");
  const order = ["plan-review", "execution-review", "executor", "research"];
  const groups = { opus: [], sonnet: [] };
  for (const role of order) {
    let j = null;
    try {
      j = JSON.parse(cp.execFileSync("node", [process.env.LEDGER_HELPER_ARG, "resolve-route", "--seat", role, "--json"],
        { encoding: "utf8", timeout: 20000, stdio: ["ignore", "pipe", "ignore"] }));
    } catch (e) { continue; }
    const d = (j && typeof j.dispatch === "string") ? j.dispatch : "";
    const fb = (j && typeof j.agent_tool_fallback === "string") ? j.agent_tool_fallback : "";
    if (d.indexOf("subprocess-") === 0 && groups[fb]) groups[fb].push(role);
  }
  const parts = [];
  for (const tier of ["opus", "sonnet"]) if (groups[tier].length) parts.push("model:" + tier + " (" + groups[tier].join(", ") + ")");
  process.stdout.write(parts.join(" / "));
' 2>/dev/null)"
[ -n "$ADV_TIER_TXT" ] || ADV_TIER_TXT="model:${SEAT_FALLBACK:-unknown} (${ROLE})"

cat >&2 <<EOF
<system-reminder>
THREE-ROLE ROUTE-DISPATCH GATE (three-role-route-dispatch-gate hook, #1989/#2518): the seat ROLE:${ROLE} for
3ROLE_TASK:${TASKID} is declared dispatch=${SEAT_DISPATCH} (model ${SEAT_MODEL}, provider ${PROVIDER}) in the
routes SSOT (config/cc-routes.json), and mode=${MODE_VAL} resolves ${PROVIDER}_dispatch=permitted, so its
PRIMARY dispatch path is the subprocess helper, NOT an in-session Agent-tool spawn:
    bash tools/openrouter-role-dispatch.sh --role ${ROLE} --brief <brief-path> --task ${TASKID}
(A provider endpoint binds once at \`claude\` launch -- #1685/#1917 -- so an Agent-tool call cannot reach this
seat's declared non-Anthropic model; only the fresh-OS-process subprocess can, and \`agent_tool_fallback\`
made an accidental Agent-tool spawn silently gate-clean before this gate existed.) The Agent-tool spawn of
this seat is the FALLBACK path, sanctioned ONLY for: (a) a D3 bounded fallback after a failed/timed-out
subprocess dispatch (helper exit 124 or nonzero, <=1 subprocess retry first); (b) the seat's key file
absent / the route genuinely unavailable; or (c) explicit operator direction. #3190 FIRST-CLASS route (not a
fallback, no inline token): if tools/openrouter-role-dispatch.sh refused this task's brief with its needle lint
(#2888, exit 9), re-issue the spawn carrying PLAN: <the plan> AND BRIEF: <the refused brief's path> -- the
refusal's receipt row admits exactly that task+brief pair on the seat's agent_tool_fallback tier. If this spawn IS a sanctioned
fallback, re-issue it carrying the inline token [route-dispatch-fallback-ok] in the prompt (it is
audit-logged as a deliberate bypass, never silent) and pass ${ADV_TIER_TXT}
explicitly (each tier read fresh from that seat's SSOT agent_tool_fallback, #3520). This is ADVISORY + block-once PER session:task:role: you will see this ONCE for this spawn.
Escapes: inline bypass token [route-dispatch-fallback-ok] in the prompt for a deliberate one-off, or
kill-switch CC_ROUTE_DISPATCH_GATE_OFF=1 (or THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1).
</system-reminder>
EOF
exit 2
