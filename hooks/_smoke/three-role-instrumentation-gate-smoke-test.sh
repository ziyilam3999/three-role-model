#!/usr/bin/env bash
# Smoke test for three-role-instrumentation-gate.sh (#847). Exit 0 = all cases pass.
# The gate blocks (exit 2) a completing TaskUpdate that carries metadata.model_run (a tagged 3-role run)
# unless the cited perf-log card carries an entry citing THIS taskId. Untagged / trivial completions and
# missing/unparseable state fail-open (allow). Covers the bypass forms (untagged, kill-switch, missing file).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-instrumentation-gate.sh"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SID="sess-847"
PROJ="$TMP/proj"; mkdir -p "$PROJ"

# ---- perf-log card fixtures ----
# A card WITH an entry citing task #847 (a per-round entry naming the run).
cat > "$TMP/perf-good.md" <<EOF
# 3-role performance log — run for #847

## Round 1 — #847 self-instrumentation, via the model
### Round 1a — PLANNER (general-purpose, full tools)
- did its job?: yes
- miss + root cause: (none)
- prevention: (none)

## SUMMARY
Model wins: planner + reviewer both strong. Defects filed: none.
EOF
# A card that exists but does NOT mention #847 at all (instrumentation not actually done for this run).
cat > "$TMP/perf-other.md" <<EOF
# 3-role performance log — run for #824

## Round 1 — #824 demo post
- did its job?: yes
EOF
# A card that mentions 847 only as a SUBSTRING of a larger number (#18472) — must NOT count (token boundary).
cat > "$TMP/perf-substr.md" <<EOF
# 3-role performance log — run for #18472
## Round 1 — #18472 unrelated
- did its job?: yes
EOF

# ── Phase 1+2 (#851) role-LEDGER fixtures ───────────────────────────────────────────────────────────
# The extended gate runs a SECOND leg (node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" check) after the perf-card leg passes.
# Point both the ledger store and the subagent-transcript projects root at fixture trees, and dogfood the
# helper's own `append` to build ledgers. Every ALLOW case needs a complete, resolvable ledger.
LED="$ROOT/bin/3role-ledger.mjs"
LEDGERDIR="$TMP/ledger"; PROJROOT="$TMP/projects"
appendL() { THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" node "$LED" append "$@" >/dev/null 2>&1; }
# create a real (resolvable) subagent transcript fixture: mk_sub <session> <agentId>
mk_sub() { mkdir -p "$PROJROOT/proj/$1/subagents"; printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1" > "$PROJROOT/proj/$1/subagents/agent-$2.jsonl"; }
# artifact fixtures for ledger roles
LART_PLAN="$TMP/lplan.md"; LART_REV="$TMP/lrev.md"
printf '## ELI5\nplan\n### Binary AC\n- AC1\n' > "$LART_PLAN"
printf '## Review\nverdict: PASS\n' > "$LART_REV"
# build a complete, valid ledger for (session,task) with all four roles resolvable: ledger_complete <session> <task>
ledger_complete() {
  local s="$1" t="$2"
  mk_sub "$s" agP; mk_sub "$s" agR; mk_sub "$s" agE; mk_sub "$s" agV
  appendL --session "$s" --task "$t" --role planner          --agent agP --artifact "$LART_PLAN"
  appendL --session "$s" --task "$t" --role plan-review       --agent agR --artifact "$LART_REV"
  appendL --session "$s" --task "$t" --role executor          --agent agE --artifact "branch feat/x"
  appendL --session "$s" --task "$t" --role execution-review  --agent agV --artifact "$LART_REV"
}
# a perf-log card mentioning every NEW Phase-1/2 task id (so the perf-card leg passes and we reach the ledger leg)
cat > "$TMP/perf-multi.md" <<EOF
# 3-role performance log — Phase 1+2 ledger cases
## rounds for #8511 #8512 #8513 #8514 #8515 #8516 #8517 #8518 #8519 #8520 #8599
EOF
# the existing ALLOW cases (2, 2b) use session sess-847 / task 847 — give them a complete ledger so they still ALLOW
ledger_complete "$SID" 847

run() { CAP=$(printf '%s' "$1" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# helper: run a tagged completion citing the multi-mention perf card, for taskId $1 in session $2
runT() { run '{"session_id":"'"$2"'","tool_input":{"taskId":"'"$1"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-multi.md"}}}'; }

# ---- 1. UNTAGGED completion (no metadata.model_run) -> allow silent (IGNORED) ----
run '{"tool_name":"TaskUpdate","session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed"}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "untagged completion -> allow silent (IGNORED)" || bad "untagged should allow silent (rc=$RC out=$CAP)"

# ---- 1b. TRIVIAL completion: only evidence, no model_run -> allow silent (IGNORED) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"evidence":"trivial single-file fix"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "trivial completion (no model_run) -> allow silent (IGNORED)" || bad "trivial should allow silent (rc=$RC out=$CAP)"

# ---- 1c. non-completion (in_progress) with model_run -> allow silent ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"in_progress","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-good.md"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "in_progress tagged -> allow silent (only completions gated)" || bad "in_progress should allow silent (rc=$RC out=$CAP)"

# ---- 2. TAGGED completion, cited card HAS an entry for #847 -> ALLOW ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-good.md"}}}'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "tagged + card has entry for #847 -> ALLOW" || bad "good card should pass (rc=$RC out=$CAP)"

# ---- 2b. model_run is itself the path (no separate model_perf_log) + card has entry -> ALLOW ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"'"$TMP"'/perf-good.md"}}}'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "model_run-as-path + card has entry -> ALLOW" || bad "path-shaped model_run should resolve (rc=$RC out=$CAP)"

# ---- 3. TAGGED completion, cited card LACKS an entry for #847 -> BLOCK ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-other.md"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "NO entry citing this run"; } && ok "tagged + card lacks entry -> BLOCK" || bad "missing entry should block (rc=$RC out=$CAP)"

# ---- 3b. token-boundary: card mentions 18472 (847 as substring) -> BLOCK (not a real cite) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-substr.md"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "NO entry citing this run"; } && ok "substring 18472 does NOT satisfy #847 -> BLOCK" || bad "substring must not count (rc=$RC out=$CAP)"

# ---- 4. TAGGED completion, NO perf-log path cited -> BLOCK ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "No perf-log card path"; } && ok "tagged + no path cited -> BLOCK" || bad "no path should block (rc=$RC out=$CAP)"

# ---- 5. TAGGED completion, cited card file missing -> BLOCK (fix-landed leg) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/nope.md"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not found"; } && ok "cited card missing -> BLOCK" || bad "missing card should block (rc=$RC out=$CAP)"

# ---- 6. kill-switches ----
CAP=$(printf '%s' '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "THREE_ROLE_INSTRUMENT_OFF=1 -> allow silent" || bad "OFF kill-switch should allow (rc=$RC out=$CAP)"

CAP=$(printf '%s' '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847"}}}' \
  | SHIP_PIPELINE=1 bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "SHIP_PIPELINE=1 -> allow silent" || bad "SHIP_PIPELINE kill-switch should allow (rc=$RC out=$CAP)"

# ---- 7. malformed hook input -> allow silent (fail-open) ----
run 'not json at all {{{'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "malformed input -> allow silent (fail-open)" || bad "malformed input should fail-open (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Phase 1+2 (#851) — role-LEDGER leg cases. Each tagged completion cites perf-multi.md (perf-card leg
# passes), so the RESULT is decided by the ledger leg. Each case uses its own session to isolate.
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# ---- L1. complete ledger (4 roles, artifacts valid, agentIds resolve) -> ALLOW ----
ledger_complete s8511 8511
runT 8511 s8511
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "complete ledger -> ALLOW" || bad "complete ledger should allow (rc=$RC out=$CAP)"

# ---- L2. missing execution-review ledger line -> BLOCK ----
mk_sub s8512 agP; mk_sub s8512 agR; mk_sub s8512 agE
appendL --session s8512 --task 8512 --role planner     --agent agP --artifact "$LART_PLAN"
appendL --session s8512 --task 8512 --role plan-review  --agent agR --artifact "$LART_REV"
appendL --session s8512 --task 8512 --role executor     --agent agE --artifact "branch feat/x"
runT 8512 s8512
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "missing execution-review"; } && ok "missing execution-review -> BLOCK" || bad "missing exec-review should block (rc=$RC out=$CAP)"

# ---- L3. planner inline-skip with a SPECIFIC reason + other 3 valid -> ALLOW ----
mk_sub s8513 agR; mk_sub s8513 agE; mk_sub s8513 agV
appendL --session s8513 --task 8513 --role planner          --skip-reason "plan was tightly coupled to live mid-edit session state, not briefable"
appendL --session s8513 --task 8513 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8513 --task 8513 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8513 --task 8513 --role execution-review  --agent agV --artifact "$LART_REV"
runT 8513 s8513
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "planner inline-skip(reason) -> ALLOW" || bad "planner skip should allow (rc=$RC out=$CAP)"

# ---- L4. execution-review inline-skip -> BLOCK (never skippable) ----
mk_sub s8514 agP; mk_sub s8514 agR; mk_sub s8514 agE
appendL --session s8514 --task 8514 --role planner          --agent agP --artifact "$LART_PLAN"
appendL --session s8514 --task 8514 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8514 --task 8514 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8514 --task 8514 --role execution-review  --skip-reason "no reviewer available"
runT 8514 s8514
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "never"; } && ok "execution-review inline-skip -> BLOCK" || bad "exec-review skip should block (rc=$RC out=$CAP)"

# ---- L5. planner artifact_path cited but does NOT exist -> BLOCK ----
mk_sub s8515 agP; mk_sub s8515 agR; mk_sub s8515 agE; mk_sub s8515 agV
appendL --session s8515 --task 8515 --role planner          --agent agP --artifact "$TMP/does-not-exist.md"
appendL --session s8515 --task 8515 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8515 --task 8515 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8515 --task 8515 --role execution-review  --agent agV --artifact "$LART_REV"
runT 8515 s8515
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "not found"; } && ok "missing plan artifact -> BLOCK" || bad "missing plan artifact should block (rc=$RC out=$CAP)"

# ---- L6. FORGED planner agentId (no subagent transcript) -> BLOCK (Phase-2 forgery-close; names the id) ----
mk_sub s8516 agR; mk_sub s8516 agE; mk_sub s8516 agV   # NOTE: no agent file for 'forged9999'
appendL --session s8516 --task 8516 --role planner          --agent forged9999 --artifact "$LART_PLAN"
appendL --session s8516 --task 8516 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8516 --task 8516 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8516 --task 8516 --role execution-review  --agent agV --artifact "$LART_REV"
runT 8516 s8516
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "forged9999"; } && ok "forged agentId -> BLOCK (names unresolved id)" || bad "forged agentId should block (rc=$RC out=$CAP)"

# ---- L7. REAL planner agentId resolves to a fixture transcript -> ALLOW (prove-primary, REAL) ----
mk_sub s8517 realplanner; mk_sub s8517 agR; mk_sub s8517 agE; mk_sub s8517 agV
appendL --session s8517 --task 8517 --role planner          --agent realplanner --artifact "$LART_PLAN"
appendL --session s8517 --task 8517 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8517 --task 8517 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8517 --task 8517 --role execution-review  --agent agV --artifact "$LART_REV"
runT 8517 s8517
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "real resolvable agentId -> ALLOW" || bad "real agentId should allow (rc=$RC out=$CAP)"

# ---- L8. empty skip reason on planner -> BLOCK ----
mk_sub s8518 agR; mk_sub s8518 agE; mk_sub s8518 agV
appendL --session s8518 --task 8518 --role planner          --skip-reason ""
appendL --session s8518 --task 8518 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8518 --task 8518 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8518 --task 8518 --role execution-review  --agent agV --artifact "$LART_REV"
runT 8518 s8518
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "empty"; } && ok "empty skip reason -> BLOCK" || bad "empty skip reason should block (rc=$RC out=$CAP)"

# ---- L9. execution-review satisfied by an oracle that exists + PASS token -> ALLOW (AC2.3) ----
printf 'tests: 12 passed, 0 failed — PASS\n' > "$TMP/oracle-pass.txt"
mk_sub s8519 agP; mk_sub s8519 agR; mk_sub s8519 agE
appendL --session s8519 --task 8519 --role planner          --agent agP --artifact "$LART_PLAN"
appendL --session s8519 --task 8519 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8519 --task 8519 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8519 --task 8519 --role execution-review  --oracle "$TMP/oracle-pass.txt"
runT 8519 s8519
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "exec-review oracle(exists+PASS) -> ALLOW" || bad "oracle should allow (rc=$RC out=$CAP)"

# ---- L10. execution-review oracle path missing -> BLOCK ----
mk_sub s8520 agP; mk_sub s8520 agR; mk_sub s8520 agE
appendL --session s8520 --task 8520 --role planner          --agent agP --artifact "$LART_PLAN"
appendL --session s8520 --task 8520 --role plan-review       --agent agR --artifact "$LART_REV"
appendL --session s8520 --task 8520 --role executor          --agent agE --artifact "branch feat/x"
appendL --session s8520 --task 8520 --role execution-review  --oracle "$TMP/no-such-oracle.txt"
runT 8520 s8520
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "oracle"; } && ok "exec-review oracle missing -> BLOCK" || bad "missing oracle should block (rc=$RC out=$CAP)"

# ---- L11. tagged completion + valid perf card but NO ledger file at all -> BLOCK (bypass form, #749) ----
runT 8599 s8599
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "no role-ledger"; } && ok "tagged + no ledger file -> BLOCK" || bad "no ledger should block (rc=$RC out=$CAP)"

# ---- L12. untagged completion is still allow-silent even with the ledger leg present (fail-open) ----
run '{"session_id":"s8599","tool_input":{"taskId":"8599","status":"completed"}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "untagged completion -> allow silent (ledger leg never reached)" || bad "untagged should allow silent (rc=$RC out=$CAP)"

# ---- L13. tagged + valid perf card (mentions #8511) but NO session_id in payload -> BLOCK (#970 bypass close) ----
# Missing-session must FAIL CLOSED on a tagged run: without it the ledger leg is skipped and the gate collapses
# to the forgeable perf-card check. #8511 has a complete ledger under session s8511, so ONLY the absent session
# (not the ledger content) decides the outcome here.
run '{"tool_input":{"taskId":"8511","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-multi.md"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "no session_id"; } && ok "tagged + no session_id -> BLOCK (missing-session fail-closed)" || bad "missing session should block (rc=$RC out=$CAP)"

# ---- L14. SAME bypass payload but kill-switch THREE_ROLE_INSTRUMENT_OFF=1 -> ALLOW (kill-switch still bypasses) ----
CAP=$(printf '%s' '{"tool_input":{"taskId":"8511","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-multi.md"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "missing-session bypass + OFF kill-switch -> allow silent" || bad "OFF kill-switch should allow missing-session payload (rc=$RC out=$CAP)"

# ---- L15. helper-absent (fail-open) + tagged + session present -> ALLOW (documents the defensive fail-open) ----
# Point the helper-dir resolution at a hook COPY whose sibling 3role-ledger.mjs does NOT exist, so the helper
# leg is skipped (fail-open) while session IS present. Proves HELPER-absence (unlike SESSION-absence) allows.
NOHELPDIR="$TMP/nohelper"; mkdir -p "$NOHELPDIR"; cp "$HOOK" "$NOHELPDIR/gate.sh"
CAP=$(printf '%s' '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-good.md"}}}' \
  | CLAUDE_PLUGIN_ROOT= THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$NOHELPDIR/gate.sh" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger SKIPPED"; } && ok "helper-absent + session present -> ALLOW (fail-open documented)" || bad "helper-absent should fail-open allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1098 — UNTAGGED-path fail-CLOSED cases. The opt-in seam (no metadata.model_run) used to allow EVERY
# untagged completion silently. Now an untagged completion that shows OBJECTIVE code-work evidence
# (PR / merge / commit-sha / "shipped" / "released vX.Y.Z") must carry EITHER a resolvable 4-role ledger
# OR a valid metadata.three_role_skip; else BLOCK. Trivial (no-evidence) untagged completions still fail OPEN.
# Each runU pipes an UNtagged (no model_run) completed payload. CODE-work evidence below cites a PR + sha.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
EV='shipped PR #1098, merged commit a1b2c3d'   # objective code-work signal (PR + merge + commit-sha)
# runU <taskId> <session> [extra-metadata-json]  — untagged completion with code-work evidence
runU() {
  local extra="${3:-}"; local md='"evidence":"'"$EV"'"'
  [ -n "$extra" ] && md="$md,$extra"
  run '{"session_id":"'"$2"'","tool_input":{"taskId":"'"$1"'","status":"completed","metadata":{'"$md"'}}}'
}

# ---- U1. code-work evidence + NO ledger + NO skip -> BLOCK (the #1098 bypass closed) ----
runU 9001 s9001
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "no role-ledger\|UNPROVEN"; } && ok "U1 untagged code-work + no ledger + no skip -> BLOCK" || bad "U1 should block (rc=$RC out=$CAP)"

# ---- U2. code-work evidence + COMPLETE 4-role ledger -> ALLOW ----
ledger_complete s9002 9002
runU 9002 s9002
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "resolvable 4-role ledger"; } && ok "U2 untagged code-work + complete ledger -> ALLOW" || bad "U2 should allow (rc=$RC out=$CAP)"

# ---- U2b (plan-review #2). code-work evidence + ledger MISSING one role (execution-review) -> BLOCK ----
mk_sub s9002b agP; mk_sub s9002b agR; mk_sub s9002b agE
appendL --session s9002b --task 9002 --role planner     --agent agP --artifact "$LART_PLAN"
appendL --session s9002b --task 9002 --role plan-review  --agent agR --artifact "$LART_REV"
appendL --session s9002b --task 9002 --role executor     --agent agE --artifact "branch feat/x"
runU 9002 s9002b
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "missing execution-review"; } && ok "U2b untagged code-work + incomplete ledger -> BLOCK" || bad "U2b should block (rc=$RC out=$CAP)"

# ---- U3. code-work evidence + valid SPECIFIC three_role_skip -> ALLOW ----
runU 9003 s9003 '"three_role_skip":"hotfix tightly coupled to live mid-edit session state, not briefable as a 3-role run"'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "U3 untagged code-work + valid specific skip -> ALLOW silent" || bad "U3 should allow (rc=$RC out=$CAP)"

# ---- U3b. code-work evidence + empty/generic skip ("done"/"n/a") -> BLOCK (skip-strength, plan-review #1) ----
runU 9003 s9003b '"three_role_skip":"done"'
{ [ "$RC" = "2" ]; } && ok "U3b untagged code-work + generic skip 'done' -> BLOCK" || bad "U3b 'done' should block (rc=$RC out=$CAP)"
runU 9003 s9003c '"three_role_skip":"n/a"'
{ [ "$RC" = "2" ]; } && ok "U3b untagged code-work + generic skip 'n/a' -> BLOCK" || bad "U3b 'n/a' should block (rc=$RC out=$CAP)"
runU 9003 s9003d '"three_role_skip":""'
{ [ "$RC" = "2" ]; } && ok "U3b untagged code-work + empty skip -> BLOCK" || bad "U3b empty should block (rc=$RC out=$CAP)"

# ---- U4 (plan-review #3). vague/unmapped evidence ("updated the thing") -> ALLOW (acknowledged fail-OPEN residual) ----
run '{"session_id":"s9004","tool_input":{"taskId":"9004","status":"completed","metadata":{"evidence":"updated the thing"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "U4 vague evidence (no code-work signal) -> ALLOW (documented fail-OPEN residual)" || bad "U4 vague should allow (rc=$RC out=$CAP)"

# ---- U5. kill-switches on the U1 (would-block) untagged code-work payload -> ALLOW silent ----
CAP=$(printf '%s' '{"session_id":"s9005","tool_input":{"taskId":"9005","status":"completed","metadata":{"evidence":"'"$EV"'"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "U5 THREE_ROLE_INSTRUMENT_OFF=1 on untagged code-work -> allow silent" || bad "U5 OFF should allow (rc=$RC out=$CAP)"
CAP=$(printf '%s' '{"session_id":"s9005","tool_input":{"taskId":"9005","status":"completed","metadata":{"evidence":"'"$EV"'"}}}' \
  | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "U5 SHIP_PIPELINE=1 on untagged code-work -> allow silent" || bad "U5 SHIP_PIPELINE should allow (rc=$RC out=$CAP)"

# ---- U6. code-work evidence + MISSING session_id -> BLOCK (fail-CLOSED on can't-tell) ----
run '{"tool_input":{"taskId":"9006","status":"completed","metadata":{"evidence":"'"$EV"'"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "no session_id"; } && ok "U6 untagged code-work + no session_id -> BLOCK (fail-closed)" || bad "U6 should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1100 item 5 (AC2) — CODEWORK_RE over-fire, BOTH-ENDS. The `released?` arm now requires the REAL shape
# (released/release + whitespace + 'v' + semver). A hyphenated quarantine dir name "release-0.70.0" (no 'v',
# '-' not whitespace, no other code-work token) must NOT fire CODEWORK -> untagged fail-OPEN allow; a real
# "released v0.70.0" MUST fire CODEWORK -> routed to the code-work branch -> BLOCK (no ledger backs it).
# RED on master: master's arm `\breleased?\b[\s\S]{0,12}v?\d+\.\d+\.\d+` matches "release-0.70.0" -> CODEWORK=1
# -> R1 would BLOCK instead of allow-silent. GREEN after the tighten.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ---- R1. evidence "release-0.70.0" ALONE -> CODEWORK=0 -> allow silent (NO over-fire) ----
run '{"session_id":"sR1","tool_input":{"taskId":"R1","status":"completed","metadata":{"evidence":"cut from worktree release-0.70.0, no PR yet"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "AC2: 'release-0.70.0' alone -> CODEWORK=0 -> allow silent (no over-fire)" || bad "AC2 'release-0.70.0' should NOT fire codework (rc=$RC out=$CAP)"

# ---- R2. evidence "released v0.70.0" -> CODEWORK=1 -> routed to code-work branch -> BLOCK (no ledger) ----
run '{"session_id":"sR2","tool_input":{"taskId":"R2","status":"completed","metadata":{"evidence":"released v0.70.0"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "UNPROVEN\|no role-ledger"; } && ok "AC2: 'released v0.70.0' -> CODEWORK=1 -> routed to code-work branch (BLOCK, no ledger)" || bad "AC2 'released v0.70.0' should fire codework (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1269 — cairn-citation legs (4a planner + 4b reviewer). Each tagged completion cites perf-1269.md (perf
# leg passes) AND has a complete 4-role ledger (ledger leg passes), so the RESULT is decided by the cairn
# legs. The active plan is resolved from THREE_ROLE_PLANS_DIR (override) or CLAUDE_PROJECT_DIR (the real
# default-path, exercised by AC4a-negative-NO-OVERRIDE).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat > "$TMP/perf-1269.md" <<EOF
# 3-role performance log — #1269 cairn-citation legs
## rounds for #12691 #12692 #12693 #12694 #12695 #12696 #12697 #12698 #12699
EOF

# runC <taskId> <session> [extra-env...] : tagged completion citing perf-1269.md (absolute), ledger store wired.
runC() {
  local t="$1" s="$2"; shift 2
  CAP=$(printf '%s' '{"session_id":"'"$s"'","tool_input":{"taskId":"'"$t"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1269.md"}}}' \
    | env THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" "$@" bash "$HOOK" 2>&1 >/dev/null); RC=$?
}
# mkplan <case-dir> <cairn?yes|no> : create <dir>/.ai-workspace/plans/p.md (with or without a cairn: line).
mkplan() {
  mkdir -p "$1/.ai-workspace/plans"
  if [ "$2" = yes ]; then printf '# Plan\ncairn: "a matched hit"\n\nbody\n' > "$1/.ai-workspace/plans/p.md"
  else printf '# Plan\n\nbody, no citation here\n' > "$1/.ai-workspace/plans/p.md"; fi
}

# ---- C1 (AC4a-positive). plan carries cairn: -> exit 0 ----
ledger_complete sC1 12691; D="$TMP/c1"; mkplan "$D" yes
runC 12691 sC1 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4a-positive: plan w/ cairn: -> ALLOW" || bad "AC4a-positive should allow (rc=$RC out=$CAP)"

# ---- C2 (AC4a-negative, override). plan lacks cairn:, THREE_ROLE_PLANS_DIR set -> BLOCK ----
ledger_complete sC2 12692; D="$TMP/c2"; mkplan "$D" no
runC 12692 sC2 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC4a-negative(override): cairn-less plan -> BLOCK" || bad "AC4a-negative should block (rc=$RC out=$CAP)"

# ---- C3 (AC4a-negative-NO-OVERRIDE, the load-bearing one). THREE_ROLE_PLANS_DIR UNSET, real cwd via
#      CLAUDE_PROJECT_DIR holding a cairn-less plan -> BLOCK (proves the production default-path blocks). ----
ledger_complete sC3 12693; D="$TMP/c3realproj"; mkplan "$D" no
runC 12693 sC3 CLAUDE_PROJECT_DIR="$D"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC4a-negative-NO-OVERRIDE: default-path cairn-less plan -> BLOCK" || bad "AC4a-NO-OVERRIDE should block via default wiring (rc=$RC out=$CAP)"

# ---- C4 (AC4a-failopen). plans dir exists but NO plan file -> fail-open exit 0 ----
ledger_complete sC4 12694; D="$TMP/c4"; mkdir -p "$D/.ai-workspace/plans"
runC 12694 sC4 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ]; } && ok "AC4a-failopen: no plan file -> ALLOW (can't-tell residual)" || bad "AC4a-failopen should allow (rc=$RC out=$CAP)"

# ---- C5 (AC4b-positive, reviews artifact). plan w/ cairn: + reviews/<id>.md w/ cairn: -> exit 0 ----
ledger_complete sC5 12695; D="$TMP/c5"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\ncairn: "reviewer hit"\nverdict: PASS\n' > "$D/.ai-workspace/reviews/12695.md"
runC 12695 sC5 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-positive(reviews artifact w/ cairn:) -> ALLOW" || bad "AC4b-positive(artifact) should allow (rc=$RC out=$CAP)"

# ---- C6 (AC4b-positive, in-plan ## Review). plan w/ top cairn: + ## Review section w/ its own cairn: -> exit 0 ----
ledger_complete sC6 12696; D="$TMP/c6"; mkdir -p "$D/.ai-workspace/plans"
printf '# Plan\ncairn: "planner hit"\n\nbody\n\n## Review\nDecision: PASS\ncairn: "reviewer hit"\n' > "$D/.ai-workspace/plans/p.md"
runC 12696 sC6 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-positive(in-plan ## Review w/ cairn:) -> ALLOW" || bad "AC4b-positive(in-plan) should allow (rc=$RC out=$CAP)"

# ---- C7 (AC4b-negative, reviews artifact). plan w/ cairn: + reviews/<id>.md WITHOUT cairn: -> BLOCK ----
ledger_complete sC7 12697; D="$TMP/c7"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\nverdict: PASS\nno citation\n' > "$D/.ai-workspace/reviews/12697.md"
runC 12697 sC7 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC4b-negative(reviews artifact, no cairn:) -> BLOCK" || bad "AC4b-negative(artifact) should block (rc=$RC out=$CAP)"

# ---- C8 (AC4b-negative, in-plan ## Review). plan w/ top cairn: + ## Review section WITHOUT cairn: -> BLOCK
#      (the planner's top-of-file cairn: must NOT satisfy 4b — the awk scan only counts a cairn: after ## Review).
ledger_complete sC8 12698; D="$TMP/c8"; mkdir -p "$D/.ai-workspace/plans"
printf '# Plan\ncairn: "planner hit only"\n\nbody\n\n## Review\nDecision: PASS\nno reviewer citation\n' > "$D/.ai-workspace/plans/p.md"
runC 12698 sC8 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC4b-negative(in-plan ## Review, planner cairn: only) -> BLOCK" || bad "AC4b-negative(in-plan) should block (rc=$RC out=$CAP)"

# ---- C9 (AC4b-failopen). plan w/ cairn:, NO reviews artifact AND no ## Review section -> exit 0 ----
ledger_complete sC9 12699; D="$TMP/c9"; mkplan "$D" yes
runC 12699 sC9 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-failopen: no review present -> ALLOW (can't-tell residual)" || bad "AC4b-failopen should allow (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
