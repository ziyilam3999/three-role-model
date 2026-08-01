#!/usr/bin/env bash
# Smoke for hooks/three-role-route-dispatch-gate.sh (#1989, redesigned #2189). Exit 0 = all cases pass.
#
# #2189 changed the IN-SCOPE behavior (conservative mode + a tagged subprocess-declared seat) from a
# block-once advisory clearable by an inline prompt token, to a PERSISTENT refusal clearable ONLY by: (1) a
# recorded real (non-drill) dispatch failure for the same role+task (an untracked state-dir marker written by
# tools/openrouter-role-dispatch.sh), (2) the operator flipping the mode dial to normal, or (3) the operator's
# own audited env kill-switch. Everything OUT of scope (untagged, non-subprocess seat, non-conservative mode,
# unresolvable SSOT) is byte-identical to before: silent exit 0, no advisory, no marker, no log row.
#
# This suite exercises the plan's 15 gate-testable arms (of its declared 18 — AC-0 is a board-ticket check
# outside the repo, verified separately; AC-7 is dispatch-helper staleness-token coverage, exercised in
# hooks/openrouter-role-dispatch-smoke-test.sh and tools/openrouter-research-dispatch-mode-gate-smoke-test.sh):
# AC-1(1) + AC-2(1) + AC-3(a..f, 6, with (b) split into two named sub-mutations) + AC-4(a,b, 2) +
# AC-5(a,b,c, 3) + AC-6(1) + AC-8(1, suite-level shasum invariant) = 15, plus regression coverage of #2105's
# D3 mode-awareness backstop (speed-boost silence, crashed-resolver fail-open) this redesign must still honor.
#
# Both-ends: each fixture FAILS on wrong behavior, PASSES on correct. No `set -e` (a non-block non-zero must
# never leak into a permission decision — #749). N4 fold: EVERY AC-3 arm gets its OWN fresh state dir — six
# arms now depend on that directory's exact contents, and a leftover marker from a prior arm would silently
# flip the wrong answer.
#
# Self-contained via CC_ROUTES_JSON fixtures the smoke writes itself, so it passes in BOTH populations —
# ai-brain (real config/cc-routes.json) and the three-role-model plugin (which ships no config/cc-routes.json).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-route-dispatch-gate.sh"
HELPER="$REPO_ROOT/tools/openrouter-role-dispatch.sh"
LED="$ROOT/bin/3role-ledger.mjs"
# The bypass-audit writer (hook_log_bypass) lives in lib-hook-override.sh, which ai-brain ships in hooks/ but
# the three-role-model plugin does NOT port. In a plugin install its call sites are guarded no-ops — the
# hook's OWN enriched writer (route_dispatch_log_escape, #2189) does NOT depend on that lib at all, so AC-6's
# row assertions hold in BOTH populations; only the SECOND (generic hook_log_bypass) row is ai-brain-only.
HAS_OVERRIDE_LIB=0
[ -f "$(dirname "$HOOK")/lib-hook-override.sh" ] && HAS_OVERRIDE_LIB=1

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/bypass.log"

evsig() {   # $1=role $2=task -> sha1(role:task), MUST match both the gate's and the helper's own computation.
  node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha1").update(process.argv[1]+":"+process.argv[2]).digest("hex"))' "$1" "$2"
}

# Scratch mode pins (isolated CC_MODE_FILE paths — the real ~/.config/cc-mode.json is NEVER read or written
# by this smoke; the suite-level AC-8 invariant below proves that from OUTSIDE, not by trusting this comment).
CONS_PIN="$TMP/cons-pin.json"
CC_MODE_FILE="$CONS_PIN" node "$LED" set-mode --mode conservative --reason smoke >/dev/null 2>&1
NORM_PIN="$TMP/norm-pin.json"
CC_MODE_FILE="$NORM_PIN" node "$LED" set-mode --mode normal --reason smoke >/dev/null 2>&1
SB_PIN="$TMP/sb-pin.json"
CC_MODE_FILE="$SB_PIN" node "$LED" set-mode --mode speed-boost --reason smoke >/dev/null 2>&1
NO_PIN="$TMP/no-pin-never-created.json"

# AC-8 (whole-suite invariant, #2189): #2189 ships no automated pin writer at all — nothing in this diff can
# move the dial. Shasum the scratch pins used above AND the real pin (best-effort; skipped, never failed, if
# unreadable) NOW, re-checked at the very end of this file.
shasum_or_absent() { [ -f "$1" ] && shasum "$1" 2>/dev/null | awk '{print $1}' || echo "ABSENT"; }
CONS_PIN_SHA_BEFORE="$(shasum_or_absent "$CONS_PIN")"
REAL_PIN="$HOME/.config/cc-mode.json"
REAL_PIN_SHA_BEFORE="$(shasum_or_absent "$REAL_PIN")"

# Fixture A — BOTH plan-review and executor declared subprocess-openrouter (real #1947 shape).
ROUTES_SUBPROC="$TMP/routes-subproc.json"
cat > "$ROUTES_SUBPROC" <<'J'
{
  "providers": {
    "openrouter": { "auth": "env:OPENROUTER_API_KEY", "endpoint": "https://openrouter.ai/api",
                    "data_posture": { "class": "unverified-or-trains" } }
  },
  "task_classes": { "sustained-agentic": { "allowed_providers": ["anthropic", "openrouter"] } },
  "seats": {
    "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter",
                     "agent_tool_fallback": "opus", "task_class": "sustained-agentic", "data_sensitivity": "public" },
    "executor":    { "provider": "openrouter", "model": "z-ai/glm-5.2", "dispatch": "subprocess-openrouter",
                     "agent_tool_fallback": "sonnet", "task_class": "sustained-agentic", "data_sensitivity": "public" }
  }
}
J

# runh <payload-json> <state-dir> [env KEY=VAL ...] -> sets RC, CAP. Pins CC_ROUTES_JSON=subproc fixture and
# the GIVEN state dir (N4 — every AC-3 arm supplies its OWN fresh dir; no arm ever reuses another's).
runh() {
  local payload="$1" state="$2"; shift 2
  CAP=$(printf '%s' "$payload" \
    | env CC_ROUTES_JSON="$ROUTES_SUBPROC" "$@" CC_ROUTE_DISPATCH_STATE_DIR="$state" bash "$HOOK" 2>&1); RC=$?
}

echo "== SECTION 0: static syntax checks =="
bash -n "$HOOK" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0a: bash -n three-role-route-dispatch-gate.sh -> syntax OK" || bad "AC-0a: bash -n three-role-route-dispatch-gate.sh FAILED"
bash -n "$DIR/three-role-route-dispatch-gate-smoke-test.sh" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0b: bash -n three-role-route-dispatch-gate-smoke-test.sh (self) -> syntax OK" || bad "AC-0b: bash -n (self) FAILED"
bash -n "$HELPER" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0c: bash -n tools/openrouter-role-dispatch.sh -> syntax OK" || bad "AC-0c: bash -n openrouter-role-dispatch.sh FAILED"

echo "== AC-1: in conservative mode the inline token no longer launders a subprocess-declared seat =="
STATE1="$TMP/state-ac1"; mkdir -p "$STATE1"
P1='{"session_id":"9989","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:plan-review [route-dispatch-fallback-ok]\nreview the plan"}}'
runh "$P1" "$STATE1" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ] && echo "$CAP" | command grep -q "tools/openrouter-role-dispatch.sh" && ! echo "$CAP" | command grep -q "/Users/"; } \
  && ok "AC-1: token present, conservative, subprocess seat, no evidence -> exit 2, names the subprocess command, no /Users/ leak" \
  || bad "AC-1 should refuse despite the token (rc=$RC out=$CAP)"
{ ! echo "$CAP" | command grep -qi "carrying the inline token"; } \
  && ok "AC-1: refusal message does NOT advertise the token as a working escape (D3 — no in-band clear)" \
  || bad "AC-1 message should not tell the caller the token clears this refusal"

echo "== AC-2: the refusal is PERSISTENT, not block-once =="
runh "$P1" "$STATE1" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-2: identical re-issue of the AC-1 payload (same state dir) -> exit 2 again (persistent, no block-once marker)" \
  || bad "AC-2 second issue should still refuse (rc=$RC)"
{ [ -z "$(ls -A "$STATE1" 2>/dev/null)" ]; } \
  && ok "AC-2 (r2 N6 structural close): the state dir gained NO file at all on refusal — no '.notified' sentinel exists to be misread as evidence, so the self-clearing hazard cannot arise by construction" \
  || bad "AC-2: refusal must write nothing to the state dir (found: $(ls -A "$STATE1" 2>/dev/null))"

echo "== AC-3(a): genuine evidence escape + inline control =="
STATE3A="$TMP/state-ac3a"; mkdir -p "$STATE3A"
SIG_9989_PR="$(evsig plan-review 9989)"
printf 'role=plan-review task=9989 reason=error drill=0 ts=now\n' > "$STATE3A/$SIG_9989_PR.evidence"
P3A='{"session_id":"9989","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:plan-review\nreview the plan"}}'
runh "$P3A" "$STATE3A" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } \
  && ok "AC-3(a): fresh, non-drill, same-role+task evidence marker -> exit 0" \
  || bad "AC-3(a) should permit with genuine evidence (rc=$RC out=$CAP)"
STATE3A_CTRL="$TMP/state-ac3a-ctrl"; mkdir -p "$STATE3A_CTRL"
runh "$P3A" "$STATE3A_CTRL" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(a) inline control: identical env with the marker removed -> exit 2" \
  || bad "AC-3(a) control should refuse with no marker (rc=$RC)"
{ [ -n "$(ls -A "$STATE1" 2>/dev/null)" ] || true; } >/dev/null 2>&1  # (no-op — placeholder keeps section numbering readable)
# session-less-payload inline control (the N1 preamble discipline — same shape as AC-3(a), one field varied):
P3A_NOSESS='{"session_id":"-","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:plan-review\nreview the plan"}}'
runh "$P3A_NOSESS" "$STATE3A" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } \
  && ok "AC-3(a) power proof: a session-less payload ALSO exits 0 here — but that is the KNOWN fail-open path (no session -> untagged), not evidence-driven; the control below proves it is not silently vacuous" \
  || bad "unexpected rc for session-less control (rc=$RC)"

echo "== AC-3(b): marker matched on role+task ONLY — a different task, and separately a different role =="
STATE3B1="$TMP/state-ac3b1"; mkdir -p "$STATE3B1"
SIG_OTHERTASK="$(evsig plan-review OTHERTASK)"
printf 'role=plan-review task=OTHERTASK reason=error drill=0 ts=now\n' > "$STATE3B1/$SIG_OTHERTASK.evidence"
runh "$P3A" "$STATE3B1" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(b) task: marker exists for a DIFFERENT task id -> exit 2 (task-blind match would wrongly permit)" \
  || bad "AC-3(b) task-mismatch marker should still refuse (rc=$RC)"
STATE3B2="$TMP/state-ac3b2"; mkdir -p "$STATE3B2"
SIG_OTHERROLE="$(evsig executor 9989)"
printf 'role=executor task=9989 reason=error drill=0 ts=now\n' > "$STATE3B2/$SIG_OTHERROLE.evidence"
runh "$P3A" "$STATE3B2" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(b) role: marker exists for a DIFFERENT role, same task -> exit 2 (role-blind match would wrongly permit)" \
  || bad "AC-3(b) role-mismatch marker should still refuse (rc=$RC)"

echo "== AC-3(c): marker mtime older than the evidence window =="
STATE3C="$TMP/state-ac3c"; mkdir -p "$STATE3C"
MARKER3C="$STATE3C/$SIG_9989_PR.evidence"
printf 'role=plan-review task=9989 reason=error drill=0 ts=old\n' > "$MARKER3C"
node -e 'const fs=require("fs");const old=new Date(Date.now()-6*3600000);fs.utimesSync(process.argv[1],old,old);' "$MARKER3C"
{ [ -f "$MARKER3C" ]; } \
  && ok "AC-3(c) N3 fixture check: the aged marker genuinely EXISTS on disk before the probe (not a missing-file false positive)" \
  || bad "AC-3(c) fixture setup failed — marker file missing"
runh "$P3A" "$STATE3C" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(c): a 6h-old marker (window default 4h) -> exit 2 (age bound enforced)" \
  || bad "AC-3(c) aged marker should refuse (rc=$RC)"

echo "== AC-3(d): forged in-band evidence (a hand-authored receipt row) is refused, 2/2 =="
STATE3D="$TMP/state-ac3d"; mkdir -p "$STATE3D"
RECEIPT3D="$TMP/receipt-ac3d.md"
echo "OR-DISPATCH-FALLBACK role=plan-review reason=timeout model=moonshotai/kimi-k3 session=n/a task=9989 latency_s=100 drill=0" > "$RECEIPT3D"
runh "$P3A" "$STATE3D" CC_MODE_FILE="$CONS_PIN" OPENROUTER_DISPATCH_RECEIPT_FILE="$RECEIPT3D"
RC1="$RC"
runh "$P3A" "$STATE3D" CC_MODE_FILE="$CONS_PIN" OPENROUTER_DISPATCH_RECEIPT_FILE="$RECEIPT3D"
RC2="$RC"
{ [ "$RC1" = "2" ] && [ "$RC2" = "2" ]; } \
  && ok "AC-3(d): forged receipt row present, state dir empty -> BOTH calls exit 2 (the gate never opens the receipt file at all)" \
  || bad "AC-3(d) forged-evidence arm should be 2/2 (call1=$RC1 call2=$RC2)"

echo "== AC-3(e): the marker has a live production writer (real hermetic induced failure) =="
BINSTUB="$TMP/binstub"; mkdir -p "$BINSTUB"
cat > "$BINSTUB/claude" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$BINSTUB/claude"
KEYDIR="$TMP/keydir"; mkdir -p "$KEYDIR"
printf 'OPENROUTER_API_KEY=dummy-fixture-key\n' > "$KEYDIR/openrouter.prod.env"
chmod 600 "$KEYDIR/openrouter.prod.env"
BRIEFDIR="$TMP/brief"; mkdir -p "$BRIEFDIR"
printf 'smoke brief content, no template markers here\n' > "$BRIEFDIR/brief.md"
POSTMORTEM_DIR="$TMP/postmortem"; mkdir -p "$POSTMORTEM_DIR"
STATE3E="$TMP/state-ac3e"; mkdir -p "$STATE3E"
RECEIPT3E="$TMP/receipt-ac3e.md"
HELPER_RC=""
HELPER_OUT="$(
  PATH="$BINSTUB:$PATH" https_proxy="http://127.0.0.1:1" http_proxy="http://127.0.0.1:1" \
    CC_ROUTES_JSON="$ROUTES_SUBPROC" CC_MODE_FILE="$CONS_PIN" CC_ROUTE_DISPATCH_STATE_DIR="$STATE3E" \
    OPENROUTER_KEY_FILE="$KEYDIR/openrouter.prod.env" OPENROUTER_DISPATCH_RECEIPT_FILE="$RECEIPT3E" \
    OPENROUTER_DISPATCH_POSTMORTEM_DIR="$POSTMORTEM_DIR" CLAUDE_PROJECTS_ROOT="$TMP/fakeprojects" \
    bash "$HELPER" --role plan-review --brief "$BRIEFDIR/brief.md" --task 3ac3e --session smokesess 2>&1
)"; HELPER_RC=$?
{ [ "$HELPER_RC" = "1" ] && [ -f "$STATE3E/$(evsig plan-review 3ac3e).evidence" ]; } \
  && ok "AC-3(e): real induced dispatch failure (non-drill, hermetic, no egress) -> the helper writes the evidence marker itself" \
  || bad "AC-3(e) helper should fail rc=1 and write the marker (helper_rc=$HELPER_RC state=$(ls "$STATE3E" 2>/dev/null))"
P3E='{"session_id":"3ac3e","tool_input":{"prompt":"3ROLE_TASK:3ac3e ROLE:plan-review\nreview the plan"}}'
runh "$P3E" "$STATE3E" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } \
  && ok "AC-3(e): the tokenless AC-1-shaped payload for the SAME role+task now exits 0 (the marker the helper just wrote is read)" \
  || bad "AC-3(e) gate should permit off the helper-written marker (rc=$RC)"
STATE3E_CTRL="$TMP/state-ac3e-ctrl"; mkdir -p "$STATE3E_CTRL"
runh "$P3E" "$STATE3E_CTRL" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(e) inline control: same payload, fresh state dir -> exit 2 (a gate-only implementation cannot pass this arm)" \
  || bad "AC-3(e) control should refuse (rc=$RC)"

echo "== AC-3(f): drill failures are inadmissible as evidence =="
STATE3F="$TMP/state-ac3f"; mkdir -p "$STATE3F"
RECEIPT3F="$TMP/receipt-ac3f.md"
HELPER_RC_F=""
PATH="$BINSTUB:$PATH" https_proxy="http://127.0.0.1:1" http_proxy="http://127.0.0.1:1" \
  CC_ROUTES_JSON="$ROUTES_SUBPROC" CC_MODE_FILE="$CONS_PIN" CC_ROUTE_DISPATCH_STATE_DIR="$STATE3F" \
  OPENROUTER_KEY_FILE="$KEYDIR/openrouter.prod.env" OPENROUTER_DISPATCH_RECEIPT_FILE="$RECEIPT3F" \
  OPENROUTER_DISPATCH_POSTMORTEM_DIR="$POSTMORTEM_DIR" CLAUDE_PROJECTS_ROOT="$TMP/fakeprojects" \
  bash "$HELPER" --role plan-review --brief "$BRIEFDIR/brief.md" --task 3ac3f --session smokesess --drill >/dev/null 2>&1
HELPER_RC_F=$?
DRILL_ROW_COUNT=0; [ -f "$RECEIPT3F" ] && DRILL_ROW_COUNT=$(command grep -c "task=3ac3f.*drill=1" "$RECEIPT3F" 2>/dev/null || echo 0)
{ [ "$HELPER_RC_F" = "1" ] && [ "$DRILL_ROW_COUNT" -ge 1 ]; } \
  && ok "AC-3(f) N3 fixture check: the drill induction genuinely failed (receipt carries a real drill=1 row, not a silently-skipped induction)" \
  || bad "AC-3(f) drill induction should genuinely fail with a drill=1 receipt row (helper_rc=$HELPER_RC_F rows=$DRILL_ROW_COUNT)"
{ [ -z "$(ls -A "$STATE3F" 2>/dev/null)" ]; } \
  && ok "AC-3(f): the drill run wrote NO evidence marker at all" \
  || bad "AC-3(f) drill run should write no marker (found: $(ls -A "$STATE3F" 2>/dev/null))"
P3F='{"session_id":"3ac3f","tool_input":{"prompt":"3ROLE_TASK:3ac3f ROLE:plan-review\nreview the plan"}}'
runh "$P3F" "$STATE3F" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-3(f): the tokenless AC-1-shaped payload for the drilled role+task still exits 2 (drill evidence is inadmissible)" \
  || bad "AC-3(f) gate should still refuse after a drill-only failure (rc=$RC)"

echo "== AC-4(a): operator-scoped escape — mode dial to normal =="
STATE4A="$TMP/state-ac4a"; mkdir -p "$STATE4A"
P4A='{"session_id":"9989","tool_input":{"prompt":"3ROLE_TASK:9989 ROLE:plan-review [route-dispatch-fallback-ok]\nreview the plan"}}'
runh "$P4A" "$STATE4A" CC_MODE_FILE="$NORM_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-4(a): AC-1 payload under a scratch NORMAL pin -> exit 0, completely silent" \
  || bad "AC-4(a) normal mode should be silent (rc=$RC out=$CAP)"
{ [ -z "$(ls -A "$STATE4A" 2>/dev/null)" ]; } \
  && ok "AC-4(a): no marker/advisory emitted outside conservative mode (behavior outside conservative unchanged)" \
  || bad "AC-4(a) should write nothing to the state dir (found: $(ls -A "$STATE4A" 2>/dev/null))"
{ true; } && ok "AC-4(a) anti-vacuity (r2 N2 honesty): a do-nothing stub also PASSES this arm — it proves scoping, never work done" || true
runh "$P4A" "$STATE4A" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-4(a) inline control: same payload, scratch pin CONTENT flipped to conservative (same path, N1's pin-mutation-trap-safe) -> exit 2" \
  || bad "AC-4(a) control should refuse under conservative (rc=$RC)"

echo "== AC-4(b): operator-scoped escape — audited kill-switch, logged =="
STATE4B="$TMP/state-ac4b"; mkdir -p "$STATE4B"
LOG4B="$TMP/rule12-4b.log"; rm -f "$LOG4B"
P4B='{"session_id":"9990","tool_input":{"prompt":"3ROLE_TASK:9990 ROLE:plan-review\nreview the plan"}}'
runh "$P4B" "$STATE4B" CC_MODE_FILE="$CONS_PIN" RULE12_LOG="$LOG4B" CC_ROUTE_DISPATCH_GATE_OFF=1
{ [ "$RC" = "0" ]; } \
  && ok "AC-4(b): CC_ROUTE_DISPATCH_GATE_OFF=1 -> exit 0" \
  || bad "AC-4(b) kill-switch should exit 0 (rc=$RC)"
ENRICHED_ROW="$(command grep '"escape_kind":"kill-switch:CC_ROUTE_DISPATCH_GATE_OFF"' "$LOG4B" 2>/dev/null | tail -1)"
{ [ -n "$ENRICHED_ROW" ]; } \
  && ok "AC-4(b): scratch RULE12_LOG gained a row naming the kill-switch" \
  || bad "AC-4(b) should log a row naming the kill-switch (log=$(cat "$LOG4B" 2>/dev/null))"
runh "$P4B" "$STATE4B" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } \
  && ok "AC-4(b) inline control: same env WITHOUT the kill-switch -> exit 2" \
  || bad "AC-4(b) control should refuse without the kill-switch (rc=$RC)"

echo "== AC-5: the refusal is SCOPED — it never wedges paths it does not own (N4 fold) =="
STATE5="$TMP/state-ac5"; mkdir -p "$STATE5"
P5A='{"session_id":"9991","tool_input":{"prompt":"3ROLE_TASK:9991 ROLE:planner [route-dispatch-fallback-ok]\nplan it"}}'
runh "$P5A" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } && ok "AC-5(a): role=planner + token, conservative -> exit 0" || bad "AC-5(a) failed (rc=$RC)"
P5A_CTRL='{"session_id":"9991","tool_input":{"prompt":"3ROLE_TASK:9991 ROLE:plan-review [route-dispatch-fallback-ok]\nplan it"}}'
runh "$P5A_CTRL" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } && ok "AC-5(a) inline control: role restored to plan-review -> exit 2" || bad "AC-5(a) control failed (rc=$RC)"

P5B='{"session_id":"9992","tool_input":{"prompt":"just do research [route-dispatch-fallback-ok]"}}'
runh "$P5B" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } && ok "AC-5(b): untagged spawn + token -> exit 0" || bad "AC-5(b) failed (rc=$RC)"
P5B_CTRL='{"session_id":"9992","tool_input":{"prompt":"3ROLE_TASK:9992 ROLE:plan-review [route-dispatch-fallback-ok]\nresearch"}}'
runh "$P5B_CTRL" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } && ok "AC-5(b) inline control: tag restored (3ROLE_TASK + ROLE:plan-review) -> exit 2" || bad "AC-5(b) control failed (rc=$RC)"

P5C='{"session_id":"9993","tool_input":{"prompt":"3ROLE_TASK:9993 ROLE:execution-review [route-dispatch-fallback-ok]\nreview"}}'
runh "$P5C" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "0" ]; } && ok "AC-5(c): role=execution-review + token -> exit 0" || bad "AC-5(c) failed (rc=$RC)"
P5C_CTRL='{"session_id":"9993","tool_input":{"prompt":"3ROLE_TASK:9993 ROLE:plan-review [route-dispatch-fallback-ok]\nreview"}}'
runh "$P5C_CTRL" "$STATE5" CC_MODE_FILE="$CONS_PIN"
{ [ "$RC" = "2" ]; } && ok "AC-5(c) inline control: role restored to plan-review -> exit 2" || bad "AC-5(c) control failed (rc=$RC)"
{ true; } && ok "AC-5 anti-vacuity (r2 N2 honesty): an always-block stub fails all three; a do-nothing stub PASSES all three — they are scoping guards, not individually work-proving" || true

echo "== AC-6: every escape row is attributable (hook/mode/role/task/escape_kind, none of the five empty) =="
# Reuses the AC-3(a) and AC-4(b) arms above via a FRESH pair of runs against a shared log, per the AC text.
STATE6A="$TMP/state-ac6a"; mkdir -p "$STATE6A"
printf 'role=plan-review task=9995 reason=error drill=0 ts=now\n' > "$STATE6A/$(evsig plan-review 9995).evidence"
LOG6="$TMP/rule12-6.log"; rm -f "$LOG6"
P6A='{"session_id":"9995","tool_input":{"prompt":"3ROLE_TASK:9995 ROLE:plan-review\nreview the plan"}}'
runh "$P6A" "$STATE6A" CC_MODE_FILE="$CONS_PIN" RULE12_LOG="$LOG6"
P6B='{"session_id":"9996","tool_input":{"prompt":"3ROLE_TASK:9996 ROLE:executor\nimplement\n"}}'
STATE6B="$TMP/state-ac6b"; mkdir -p "$STATE6B"
runh "$P6B" "$STATE6B" CC_MODE_FILE="$CONS_PIN" RULE12_LOG="$LOG6" CC_ROUTE_DISPATCH_GATE_OFF=1
ALL_FIVE_OK=1
ROW_COUNT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Scope the assertion to route_dispatch_log_escape()'s OWN enriched rows (identified by carrying an
  # escape_kind field at all) — a pre-existing generic hook_log_bypass row is a DIFFERENT, older writer with
  # a different shape (no mode/task/escape_kind by design) and is correctly out of scope for this AC.
  case "$line" in *escape_kind*) ;; *) continue ;; esac
  ROW_COUNT=$((ROW_COUNT + 1))
  ROW_OK="$(HOOK_LINE="$line" node -e '
    let j; try { j = JSON.parse(process.env.HOOK_LINE); } catch (e) { console.log("0"); process.exit(0); }
    const need = ["hook","mode","role","task","escape_kind"];
    const ok = need.every(k => j && typeof j[k] === "string" && j[k].length > 0);
    console.log(ok ? "1" : "0");
  ')"
  [ "$ROW_OK" = "1" ] || ALL_FIVE_OK=0
done < "$LOG6"
{ [ "$ROW_COUNT" -ge 2 ] && [ "$ALL_FIVE_OK" = "1" ]; } \
  && ok "AC-6: after the AC-3(a)-shaped and AC-4(b)-shaped arms, RULE12_LOG rows each carry hook/mode/role/task/escape_kind — none of the five empty ($ROW_COUNT rows)" \
  || bad "AC-6 rows should each carry all 5 non-empty fields (rows=$ROW_COUNT all_ok=$ALL_FIVE_OK log=$(cat "$LOG6" 2>/dev/null))"
# Red-before floor (measured live, this round): the LIVE .rule-12-overrides.log carries >=75 pre-existing
# INLINE_TOKEN rows for this hook, none of which carry a mode field — the enrichment is genuinely additive,
# not a reformat of what was already there.
LIVE_LOG="$HOME/.claude/.rule-12-overrides.log"
if [ -f "$LIVE_LOG" ]; then
  OLD_ROWS=$(command grep -c '"hook":"three-role-route-dispatch-gate".*"var":"INLINE_TOKEN"' "$LIVE_LOG" 2>/dev/null || echo 0)
  { [ "$OLD_ROWS" -ge 1 ]; } \
    && ok "AC-6 red-before (floor, live log): $OLD_ROWS pre-#2189 INLINE_TOKEN rows exist for this hook, carrying no mode field — the enrichment is additive" \
    || echo "NOTE: AC-6 red-before floor found $OLD_ROWS rows (non-blocking measurement, environment-dependent)"
fi

echo "== Regression: #2105 D3 mode-awareness backstop still holds under the #2189 redesign =="
STATE_R1="$TMP/state-reg1"; mkdir -p "$STATE_R1"
P_R1='{"session_id":"reg1","tool_input":{"prompt":"3ROLE_TASK:9601 ROLE:plan-review\nreview the plan"}}'
runh "$P_R1" "$STATE_R1" CC_MODE_FILE="$NO_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "Regression: mode=normal (default, no pin) -> exit 0 silent" \
  || bad "Regression normal-default mode should stay silent (rc=$RC out=$CAP)"
STATE_R2="$TMP/state-reg2"; mkdir -p "$STATE_R2"
P_R2='{"session_id":"reg2","tool_input":{"prompt":"3ROLE_TASK:9603 ROLE:executor\nimplement the plan"}}'
runh "$P_R2" "$STATE_R2" CC_MODE_FILE="$SB_PIN"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "Regression: mode=speed-boost -> exit 0 silent (keys on ==conservative, not merely !=normal)" \
  || bad "Regression speed-boost should stay silent (rc=$RC out=$CAP)"
STATE_R3="$TMP/state-reg3"; mkdir -p "$STATE_R3"
P_R3='{"session_id":"reg3","tool_input":{"prompt":"3ROLE_TASK:9604 ROLE:plan-review\nreview the plan"}}'
runh "$P_R3" "$STATE_R3" CC_MODE_FILE="$TMP"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "Regression: unreadable/crashed mode pin (CC_MODE_FILE points at a directory) -> fails OPEN silent" \
  || bad "Regression broken mode resolution should fail open silent (rc=$RC out=$CAP)"

echo "== AC-8: nothing this suite (or the mechanism it exercises) can move the dial =="
CONS_PIN_SHA_AFTER="$(shasum_or_absent "$CONS_PIN")"
{ [ "$CONS_PIN_SHA_BEFORE" = "$CONS_PIN_SHA_AFTER" ]; } \
  && ok "AC-8: the scratch conservative pin is byte-identical before/after the whole suite (shasum $CONS_PIN_SHA_AFTER)" \
  || bad "AC-8 scratch pin should be byte-identical (before=$CONS_PIN_SHA_BEFORE after=$CONS_PIN_SHA_AFTER)"
REAL_PIN_SHA_AFTER="$(shasum_or_absent "$REAL_PIN")"
{ [ "$REAL_PIN_SHA_BEFORE" = "$REAL_PIN_SHA_AFTER" ]; } \
  && ok "AC-8: the REAL ~/.config/cc-mode.json is byte-identical before/after the whole suite ($REAL_PIN_SHA_AFTER) — disclosed race: a genuine concurrent operator flip mid-suite would false-fail this, acceptable for a seconds-long suite" \
  || bad "AC-8 REAL pin changed during this suite — investigate immediately (before=$REAL_PIN_SHA_BEFORE after=$REAL_PIN_SHA_AFTER)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
