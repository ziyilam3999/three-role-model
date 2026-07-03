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
# #1303: under ledger-first resolution every ledger-complete ALLOW case now resolves its 4a/4b docs from these
# shared ledger artifacts (not the empty convention dir), so they must carry a `cairn:` line — while keeping the
# `## ELI5`/`### Binary AC` (PLAN_RE) and `## Review`/verdict (VERDICT_RE) shapes the ledger leg needs.
printf '## ELI5\nplan\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$LART_PLAN"
printf '## Review\ncairn: "synth reviewer hit"\nverdict: PASS\n' > "$LART_REV"
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

# ── VEI #1430 — outcome_eval leg sweep support ──────────────────────────────────────────────────────
# The gate now runs a FINAL metadata-only leg on every TAGGED completion: metadata.outcome_eval must be a
# verdict in {achieved|partial|missed} AND metadata.outcome_evidence must be SPECIFIC (>=20 non-ws chars, off
# the NONSPECIFIC denylist). OEV is a shared VALID evidence string. The both-direction regression sweep injects
# the two keys into every shared TAGGED-ALLOW builder (runT/runV/runC) so the ENTIRE OLD corpus runs against the
# NEW arm in ONE edit (not twenty). BLOCK cases keep blocking on their earlier leg (perf/ledger/cairn/vacuous
# all run before the outcome leg), so the injected keys are harmless there. Synthetic-only; no real home paths.
OEV='post-ship live run: watchdog fired 3 stale-board alerts in a 5m window, 0 false-positives'

run() { CAP=$(printf '%s' "$1" | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
# helper: run a tagged completion citing the multi-mention perf card, for taskId $1 in session $2
# (VEI #1430: carries a valid outcome_eval verdict + specific evidence so the swept ALLOW cases clear the new leg)
runT() { run '{"session_id":"'"$2"'","tool_input":{"taskId":"'"$1"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-multi.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'; }

# ---- 1. UNTAGGED completion (no metadata.model_run) -> allow silent (IGNORED) ----
run '{"tool_name":"TaskUpdate","session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed"}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "untagged completion -> allow silent (IGNORED)" || bad "untagged should allow silent (rc=$RC out=$CAP)"

# ---- 1b. TRIVIAL completion: only evidence, no model_run -> allow silent (IGNORED) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"evidence":"trivial single-file fix"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "trivial completion (no model_run) -> allow silent (IGNORED)" || bad "trivial should allow silent (rc=$RC out=$CAP)"

# ---- 1c. non-completion (in_progress) with model_run -> allow silent ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"in_progress","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-good.md"}}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "in_progress tagged -> allow silent (only completions gated)" || bad "in_progress should allow silent (rc=$RC out=$CAP)"

# ---- 2. TAGGED completion, cited card HAS an entry for #847 -> ALLOW (VEI #1430: + valid outcome verdict/evidence) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r-847","model_perf_log":"'"$TMP"'/perf-good.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "tagged + card has entry for #847 -> ALLOW" || bad "good card should pass (rc=$RC out=$CAP)"

# ---- 2b. model_run is itself the path (no separate model_perf_log) + card has entry -> ALLOW (VEI #1430: + outcome verdict/evidence) ----
run '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"'"$TMP"'/perf-good.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'
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
CAP=$(printf '%s' '{"session_id":"'"$SID"'","tool_input":{"taskId":"847","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-good.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
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
# 3-role performance log — #1269 cairn-citation legs (+ #1303 ledger-first resolution)
## rounds for #12691 #12692 #12693 #12694 #12695 #12696 #12697 #12698 #12699 #12700 #12701 #12702
EOF

# runC <taskId> <session> [extra-env...] : tagged completion citing perf-1269.md (absolute), ledger store wired.
runC() {
  local t="$1" s="$2"; shift 2
  CAP=$(printf '%s' '{"session_id":"'"$s"'","tool_input":{"taskId":"'"$t"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1269.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
    | env THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" "$@" bash "$HOOK" 2>&1 >/dev/null); RC=$?
}
# mkplan <case-dir> <cairn?yes|no> : create <dir>/.ai-workspace/plans/p.md (with or without a cairn: line).
# #1303: the plan carries a PLAN_RE heading (## ELI5 / ### Binary AC) so it can ALSO serve as the planner's
# LEDGER artifact (re-pointed in the C-cases below) — under ledger-first the gate resolves 4a from that artifact.
mkplan() {
  mkdir -p "$1/.ai-workspace/plans"
  if [ "$2" = yes ]; then printf '## ELI5\nplan\ncairn: "a matched hit"\n### Binary AC\n- AC1\n\nbody\n' > "$1/.ai-workspace/plans/p.md"
  else printf '## ELI5\nplan\n### Binary AC\n- AC1\n\nbody, no citation here\n' > "$1/.ai-workspace/plans/p.md"; fi
}

# #1303: under ledger-first resolution the C-cases re-point their planner / plan-review LEDGER artifacts at the
# case's OWN docs (the cairn legs test DOC CONTENT, not the shared $LART_* fixtures). Re-appending a role
# overlay-updates its line (idempotent per role); pointing planner at a real cairn-less/cairn-bearing plan, or
# inline-skipping it, is what makes each case discriminate under ledger-first. agP/agR/agV subs already exist
# (ledger_complete created them), so re-pointed agentIds still resolve.

# ---- C1 (AC4a-positive). planner LEDGER artifact = plan w/ cairn: -> resolved ledger-first -> exit 0 ----
ledger_complete sC1 12691; D="$TMP/c1"; mkplan "$D" yes
appendL --session sC1 --task 12691 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12691 sC1 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4a-positive: ledger-resolved plan w/ cairn: -> ALLOW" || bad "AC4a-positive should allow (rc=$RC out=$CAP)"

# ---- C2 (AC4a-negative, override). planner LEDGER artifact = cairn-LESS plan -> BLOCK ----
ledger_complete sC2 12692; D="$TMP/c2"; mkplan "$D" no
appendL --session sC2 --task 12692 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12692 sC2 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC4a-negative(override): ledger-resolved cairn-less plan -> BLOCK" || bad "AC4a-negative should block (rc=$RC out=$CAP)"

# ---- C3 (AC4a-negative-NO-OVERRIDE, the convention-dir FALLBACK witness). planner INLINE-SKIP -> resolve-artifact
#      exits 1 -> 4a FALLS BACK to the CLAUDE_PROJECT_DIR convention dir holding a cairn-less plan -> BLOCK. ----
ledger_complete sC3 12693; D="$TMP/c3realproj"; mkplan "$D" no
appendL --session sC3 --task 12693 --role planner --skip-reason "planner was tightly coupled to live mid-edit session state, not briefable as a standalone plan"
runC 12693 sC3 CLAUDE_PROJECT_DIR="$D"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC4a-NO-OVERRIDE: planner skip -> convention-dir fallback cairn-less plan -> BLOCK" || bad "AC4a-NO-OVERRIDE should block via convention fallback (rc=$RC out=$CAP)"

# ---- C4 (AC4a-failopen, M1). planner INLINE-SKIP -> resolve-artifact exits 1 -> 4a falls back to an EMPTY
#      convention plans dir -> APLAN empty -> cairn legs skip -> ALLOW (genuine 4a-fail-open, not via resolution). ----
ledger_complete sC4 12694; D="$TMP/c4"; mkdir -p "$D/.ai-workspace/plans"
appendL --session sC4 --task 12694 --role planner --skip-reason "planner inseparable from live session state, ran inline against mid-edit positions not a briefable plan"
runC 12694 sC4 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ]; } && ok "AC4a-failopen: planner skip + empty convention dir -> ALLOW (4a fail-open)" || bad "AC4a-failopen should allow (rc=$RC out=$CAP)"

# ---- C5 (AC4b-positive, reviews artifact). planner->plan w/ cairn:, plan-review->reviews/<id>.md w/ cairn: -> exit 0 ----
ledger_complete sC5 12695; D="$TMP/c5"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\ncairn: "reviewer hit"\nverdict: PASS\n' > "$D/.ai-workspace/reviews/12695.md"
appendL --session sC5 --task 12695 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC5 --task 12695 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12695.md"
runC 12695 sC5 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-positive(ledger reviews artifact w/ cairn:) -> ALLOW" || bad "AC4b-positive(artifact) should allow (rc=$RC out=$CAP)"

# ---- C6 (AC4b-positive, in-plan ## Review). planner->plan, plan-review->SAME plan file (AREVIEW==APLAN -> awk route);
#      ## Review section carries its own cairn: -> exit 0 ----
ledger_complete sC6 12696; D="$TMP/c6"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS\ncairn: "reviewer hit"\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sC6 --task 12696 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC6 --task 12696 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12696 sC6 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-positive(in-plan ## Review w/ cairn:, awk route) -> ALLOW" || bad "AC4b-positive(in-plan) should allow (rc=$RC out=$CAP)"

# ---- C7 (AC4b-negative, reviews artifact). planner->plan w/ cairn:, plan-review->reviews/<id>.md WITHOUT cairn: -> BLOCK ----
ledger_complete sC7 12697; D="$TMP/c7"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\nverdict: PASS\nno citation\n' > "$D/.ai-workspace/reviews/12697.md"
appendL --session sC7 --task 12697 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC7 --task 12697 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12697.md"
runC 12697 sC7 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC4b-negative(ledger reviews artifact, no cairn:) -> BLOCK" || bad "AC4b-negative(artifact) should block (rc=$RC out=$CAP)"

# ---- C8 (AC4b-negative, in-plan ## Review). planner->plan, plan-review->SAME plan file (awk route); ## Review
#      section has NO cairn: (only the planner's top-of-file line) -> BLOCK (planner line must NOT satisfy 4b). ----
ledger_complete sC8 12698; D="$TMP/c8"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit only"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS\nno reviewer citation\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sC8 --task 12698 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC8 --task 12698 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12698 sC8 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC4b-negative(in-plan ## Review, planner cairn: only, awk route) -> BLOCK" || bad "AC4b-negative(in-plan) should block (rc=$RC out=$CAP)"

# ---- C9 (AC4b-failopen, the ONLY 4b-fail-open guard — M1). planner->plan w/ cairn:, plan-review INLINE-SKIP ->
#      resolve-artifact exits 1, NO reviews artifact, NO ## Review -> AREVIEW empty -> 4b GENUINELY fail-opens -> exit 0 ----
ledger_complete sC9 12699; D="$TMP/c9"; mkplan "$D" yes
appendL --session sC9 --task 12699 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC9 --task 12699 --role plan-review --skip-reason "plan-review was interleaved with a live in-session decision, not separable as a standalone review artifact"
runC 12699 sC9 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC4b-failopen: plan-review skip + no review discoverable -> ALLOW (4b fail-open)" || bad "AC4b-failopen should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1303 — LEDGER-FIRST resolution of the 4a/4b docs (fixes the #1266 wrong-dir + stale-newest false-block).
# The gate now resolves the planner/plan-review docs from the ledger artifact_path FIRST, convention dir as
# fallback. C10 = the docs/ regression; C11 = the stale-newest false-block; C12 = the convention fallback.
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# ---- C10 (AC2, docs/ regression). planner+plan-review LEDGER artifacts live under docs/ (NOT .ai-workspace/),
#      each WITH cairn:. THREE_ROLE_PLANS_DIR points at a DIFFERENT .ai-workspace/plans holding a cairn-LESS plan
#      (M2: cairn-less, NOT empty, so master would read the wrong plan -> BLOCK; ledger-first reads docs/ -> ALLOW). ----
ledger_complete sC10 12700; D="$TMP/c10"
mkdir -p "$D/docs/plans" "$D/docs/reviews" "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "docs plan hit"\n### Binary AC\n- AC1\n' > "$D/docs/plans/p.md"
printf '## Review\ncairn: "docs review hit"\nverdict: PASS\n' > "$D/docs/reviews/r.md"
printf '## ELI5\nstale convention plan\n### Binary AC\n- AC1\n\nno citation here\n' > "$D/.ai-workspace/plans/p.md"   # cairn-LESS decoy
appendL --session sC10 --task 12700 --role planner     --agent agP --artifact "$D/docs/plans/p.md"
appendL --session sC10 --task 12700 --role plan-review --agent agR --artifact "$D/docs/reviews/r.md"
runC 12700 sC10 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "C10 docs/ ledger artifacts (cairn-less convention decoy) -> ALLOW (#1266 wrong-dir fixed)" || bad "C10 should allow via ledger docs/ resolution (rc=$RC out=$CAP)"

# ---- C11 (AC3, stale-newest false-block). Convention .ai-workspace/plans holds a plan WITH cairn: (4a satisfied
#      regardless). Convention reviews/ holds ONLY a STALE newest 9999-execution-review.md WITHOUT cairn: (M3: no
#      reviews/<taskId>.md present, so master's newest-file fallback reads the stale file -> BLOCK). Ledger
#      plan-review -> a docs/ review WITH cairn: -> ledger-first reads that -> ALLOW. RED on master, GREEN after. ----
ledger_complete sC11 12701; D="$TMP/c11"
mkdir -p "$D/.ai-workspace/plans" "$D/.ai-workspace/reviews" "$D/docs/reviews"
printf '## ELI5\nplan\ncairn: "convention plan hit"\n### Binary AC\n- AC1\n' > "$D/.ai-workspace/plans/p.md"
printf '## Review\nverdict: PASS\nstale, no citation\n' > "$D/.ai-workspace/reviews/9999-execution-review.md"   # STALE newest, no <taskId>.md
printf '## Review\ncairn: "docs review hit"\nverdict: PASS\n' > "$D/docs/reviews/r.md"
appendL --session sC11 --task 12701 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sC11 --task 12701 --role plan-review --agent agR --artifact "$D/docs/reviews/r.md"
runC 12701 sC11 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "C11 stale-newest convention review NOT read (ledger review w/ cairn:) -> ALLOW (#1266 stale-newest fixed)" || bad "C11 should allow via ledger review resolution (rc=$RC out=$CAP)"

# ---- C12 (AC4, convention fallback). planner AND plan-review BOTH inline-skipped (ledger leg still passes —
#      both are inline-skippable) -> resolve-artifact exits 1 for each -> BOTH legs fall back to the convention
#      dir: .ai-workspace/plans plan WITH cairn: + reviews/<taskId>.md WITH cairn: -> ALLOW (no regression). ----
ledger_complete sC12 12702; D="$TMP/c12"
mkdir -p "$D/.ai-workspace/plans" "$D/.ai-workspace/reviews"
printf '## ELI5\nplan\ncairn: "convention plan hit"\n### Binary AC\n- AC1\n' > "$D/.ai-workspace/plans/p.md"
printf '## Review\ncairn: "convention review hit"\nverdict: PASS\n' > "$D/.ai-workspace/reviews/12702.md"
appendL --session sC12 --task 12702 --role planner     --skip-reason "planner ran inline against unsettled mid-edit state, no standalone briefable plan artifact"
appendL --session sC12 --task 12702 --role plan-review --skip-reason "plan-review interleaved with a live in-session paid-call decision, no standalone review artifact"
runC 12702 sC12 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "C12 ledger has no usable artifact -> both legs fall back to convention dir -> ALLOW" || bad "C12 should allow via convention fallback (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1276 — VACUOUS-ORACLE guard. The gate now opts the ledger `check` into --reject-vacuous-oracle: an
# execution-review oracle that EXISTS and carries a PASS token but contains ZERO real assertions
# (all-trivially-true / bare-verdict / echo-only) is BLOCKED. Five POSITIVE-BLOCK sub-forms (incl. the two
# adversarial false-negative boundaries) + four CLEAN-NEGATIVE ALLOW twins + fail-open + three bypasses.
# Each tagged completion cites perf-1276.md (perf leg passes) and a 3-real-role + oracle ledger, so the
# vacuous check decides the outcome. (#1303: under ledger-first resolution the ALLOW twins now resolve
# planner->$LART_PLAN / plan-review->$LART_REV from the LEDGER and DO reach the #1269 cairn legs — they pass
# because the shared $LART_* fixtures carry cairn: lines, no longer via fail-open-skip.) Synthetic-only
# values; no real home paths.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat > "$TMP/perf-1276.md" <<EOF
# 3-role performance log — #1276 vacuous-oracle guard
## rounds for #12760 #12761 #12762 #12763 #12764 #12765 #12766 #12767 #12768 #12769 #12770 #12771 #12772 #12773 #12774 #12775
EOF
# runV <taskId> <session> : tagged completion citing perf-1276.md (perf leg passes), ledger store wired.
# (VEI #1430: swept — carries a valid outcome_eval verdict + specific evidence so ALLOW twins clear the new leg)
runV() { run '{"session_id":"'"$2"'","tool_input":{"taskId":"'"$1"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1276.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'; }
# ledger_oracle <session> <task> <oracle-file> : 3 real roles + execution-review satisfied by an ORACLE
# file (so the vacuous classifier, not an agentId, decides). Models L9/L10.
ledger_oracle() {
  local s="$1" t="$2" orc="$3"
  mk_sub "$s" agP; mk_sub "$s" agR; mk_sub "$s" agE
  appendL --session "$s" --task "$t" --role planner          --agent agP --artifact "$LART_PLAN"
  appendL --session "$s" --task "$t" --role plan-review       --agent agR --artifact "$LART_REV"
  appendL --session "$s" --task "$t" --role executor          --agent agE --artifact "branch feat/x"
  appendL --session "$s" --task "$t" --role execution-review  --oracle "$orc"
}

# ── POSITIVE-BLOCK sub-forms (each a REAL exit-2 block whose stderr names the oracle vacuous) ──
# VAC-ALLTRUE — only true/:/exit 0/[ 1 = 1 ]/test 1 = 1 lines (+ a PASS token to reach the check).
printf 'true\n:\nexit 0\n[ 1 = 1 ]\ntest 1 = 1\nPASS\n' > "$TMP/vac-alltrue.txt"
ledger_oracle sV1 12760 "$TMP/vac-alltrue.txt"; runV 12760 sV1
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-ALLTRUE (all-trivially-true oracle) -> BLOCK" || bad "VAC-ALLTRUE should block (rc=$RC out=$CAP)"

# VAC-ZEROASSERT — a lone PASS token, nothing runnable at all.
printf 'PASS\n' > "$TMP/vac-zero.txt"
ledger_oracle sV2 12761 "$TMP/vac-zero.txt"; runV 12761 sV2
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-ZEROASSERT (bare verdict only) -> BLOCK" || bad "VAC-ZEROASSERT should block (rc=$RC out=$CAP)"

# VAC-ECHOONLY — echo-only; EMBEDS a real-command substring inside the echo literal (Finding 1b): a
# classifier that greps `grep -q` anywhere-on-line would FALSE-NEGATIVE; an executed-command classifier blocks.
printf 'echo "grep -q X build.log -- PASS"\necho PASS\n' > "$TMP/vac-echo.txt"
ledger_oracle sV3 12762 "$TMP/vac-echo.txt"; runV 12762 sV3
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-ECHOONLY (echo w/ embedded real-cmd substring) -> BLOCK" || bad "VAC-ECHOONLY should block (rc=$RC out=$CAP)"

# VAC-AMPTRIVIAL — `true && echo PASS` (Finding 1a): trivially-true LEFT operand short-circuits to echo;
# nothing is asserted. The &&-sparing must test the LEFT operand's realness, not bare `&&` presence.
printf 'true && echo PASS\n' > "$TMP/vac-amp.txt"
ledger_oracle sV4 12763 "$TMP/vac-amp.txt"; runV 12763 sV4
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-AMPTRIVIAL (true && echo PASS) -> BLOCK" || bad "VAC-AMPTRIVIAL should block (rc=$RC out=$CAP)"

# VAC-FAKEBRACKET — the only [[ … ]] is a constant comparison [[ 1 = 1 ]] (still vacuous).
printf '[[ 1 = 1 ]]\nPASS\n' > "$TMP/vac-fake.txt"
ledger_oracle sV5 12764 "$TMP/vac-fake.txt"; runV 12764 sV5
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-FAKEBRACKET ([[ 1 = 1 ]] constant) -> BLOCK" || bad "VAC-FAKEBRACKET should block (rc=$RC out=$CAP)"

# ── CLEAN-NEGATIVE ALLOW twins (each must ALLOW, exit 0 — catches over-matching AND false-block) ──
# VAC-REAL — a real assert command (grep -q with an operand).
printf 'grep -q "all green" build.log\nPASS\n' > "$TMP/vac-real.txt"
ledger_oracle sV6 12765 "$TMP/vac-real.txt"; runV 12765 sV6
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-REAL (real grep -q assert) -> ALLOW" || bad "VAC-REAL should allow (rc=$RC out=$CAP)"

# VAC-SUMMARY — a captured run-summary with digit-bearing counts (the no-regression twin of L9).
printf 'tests: 12 passed, 0 failed -- PASS\n' > "$TMP/vac-summary.txt"
ledger_oracle sV7 12766 "$TMP/vac-summary.txt"; runV 12766 sV7
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-SUMMARY (12 passed, 0 failed counts) -> ALLOW" || bad "VAC-SUMMARY should allow (rc=$RC out=$CAP)"

# VAC-OKBRACKET — a real double-bracket filesystem-test assert [[ -f build.log ]] (Finding 2: guards
# against FALSE-BLOCKing a genuine bash [[ oracle).
printf '[[ -f build.log ]]\nPASS\n' > "$TMP/vac-okbracket.txt"
ledger_oracle sV8 12767 "$TMP/vac-okbracket.txt"; runV 12767 sV8
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-OKBRACKET ([[ -f build.log ]] real fs-test) -> ALLOW" || bad "VAC-OKBRACKET should allow (rc=$RC out=$CAP)"

# VAC-SKIP — execution-review satisfied by a REAL reviewer agentId (no oracle) -> the vacuous check never
# fires -> ALLOW (orthogonal escape door is untouched).
ledger_complete sV9 12768; runV 12768 sV9
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-SKIP (real reviewer agentId, no oracle) -> ALLOW" || bad "VAC-SKIP should allow (rc=$RC out=$CAP)"

# ── fail-open on an unparseable (binary-ish, NUL-bearing) oracle that carries a PASS token -> ALLOW ──
# Proves the new check NEVER fail-CLOSES on a parse error.
printf 'PASS\n' > "$TMP/vac-binary.txt"; printf '\000\001\002 binoracle\n' >> "$TMP/vac-binary.txt"
ledger_oracle sV10 12769 "$TMP/vac-binary.txt"; runV 12769 sV10
{ [ "$RC" = "0" ]; } && ok "vacuous fail-open: unparseable (NUL-bearing) oracle -> ALLOW (never fail-closed)" || bad "binary oracle should fail-open allow (rc=$RC out=$CAP)"

# ── three bypass fixtures: a vacuous oracle that WOULD block is ALLOWED under each off-switch ──
# (master kill-switch / feature kill-switch / ship exemption). Same vacuous all-true oracle as VAC-ALLTRUE.
ledger_oracle sV11 12770 "$TMP/vac-alltrue.txt"
CAP=$(printf '%s' '{"session_id":"sV11","tool_input":{"taskId":"12770","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1276.md"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "vacuous + THREE_ROLE_INSTRUMENT_OFF=1 -> allow silent (master bypass)" || bad "master kill-switch should allow vacuous (rc=$RC out=$CAP)"

ledger_oracle sV12 12771 "$TMP/vac-alltrue.txt"
# VEI #1430: VACUOUS_ORACLE_OFF only skips the vacuous sub-check inside the ledger leg — it does NOT short-circuit
# at the top, so this tagged completion still reaches the outcome_eval leg and needs a valid verdict + evidence.
CAP=$(printf '%s' '{"session_id":"sV12","tool_input":{"taskId":"12771","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1276.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
  | VACUOUS_ORACLE_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "vacuous + VACUOUS_ORACLE_OFF=1 -> ALLOW (feature bypass reverts to exists+PASS)" || bad "feature kill-switch should allow vacuous (rc=$RC out=$CAP)"

ledger_oracle sV13 12772 "$TMP/vac-alltrue.txt"
CAP=$(printf '%s' '{"session_id":"sV13","tool_input":{"taskId":"12772","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1276.md"}}}' \
  | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "vacuous + SHIP_PIPELINE=1 -> allow silent (ship exemption)" || bad "SHIP_PIPELINE should allow vacuous (rc=$RC out=$CAP)"

# ── #1282 — R2 echo-trap: a count string INSIDE an echo/printf literal is printed TEXT, not captured ──
# output (mirrors the R1 echo-trap precedent at count-position). Echo-wrapped count -> vacuous -> BLOCK;
# the bare captured twins stay REAL -> ALLOW (no regression to legitimate captured-count evidence).

# VAC-ECHOCOUNT (#1282) — count string INSIDE an echo literal: printed text, not a captured run summary.
printf 'echo "12 passed, 0 failed -- PASS"\n' > "$TMP/vac-echocount.txt"
ledger_oracle sV14 12773 "$TMP/vac-echocount.txt"; runV 12773 sV14
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "vacuous"; } && ok "VAC-ECHOCOUNT (echo-wrapped count) -> BLOCK" || bad "VAC-ECHOCOUNT should block (rc=$RC out=$CAP)"

# VAC-CAPTUREDCOUNT (#1282) — a captured runner summary line (no echo/printf wrap) stays REAL -> ALLOW.
printf 'Ran 14 tests in 0.3s\n14 passed, 0 failed\n' > "$TMP/vac-captured.txt"
ledger_oracle sV15 12774 "$TMP/vac-captured.txt"; runV 12774 sV15
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-CAPTUREDCOUNT (captured runner counts) -> ALLOW" || bad "VAC-CAPTUREDCOUNT should allow (rc=$RC out=$CAP)"

# VAC-PASSFAIL (#1282) — bare `PASS=5 FAIL=0` captured count (one &&-segment, space-separated) stays REAL
# -> ALLOW. Locks the PASS=/FAIL= shape after the regexes moved into the per-`&&`-segment loop.
printf 'PASS=5 FAIL=0\n' > "$TMP/vac-passfail.txt"
ledger_oracle sV16 12775 "$TMP/vac-passfail.txt"; runV 12775 sV16
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "VAC-PASSFAIL (bare PASS=5 FAIL=0 captured) -> ALLOW" || bad "VAC-PASSFAIL should allow (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# VEI #1430 — outcome_eval leg (final, metadata-only). A TAGGED completion with a valid perf card AND a
# complete 4-role ledger AND cited cairn is now ALSO required to record an HONEST post-ship outcome verdict
# (metadata.outcome_eval in {achieved|partial|missed}) + SPECIFIC evidence (metadata.outcome_evidence,
# >=20 non-ws chars, off the NONSPECIFIC denylist). An honest missed/partial WITH evidence ALLOWS
# (anti-gaming: the gate never rewards a false 'achieved'). Kill-switch OUTCOME_EVAL_GATE_OFF=1 skips ONLY
# this leg; THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1 short-circuit the whole gate.
#
# F3 (E1 vacuous-witness class) — CRITICAL: O1-O5 are built from a DEDICATED outcome-free builder `runO`
# (raw `run` + `ledger_complete` + a taskId-citing perf card, NO outcome keys). They MUST NOT reuse the
# swept runT/runV/runC (those inject a valid verdict, so an O1 built from them would silently carry a verdict
# and never go RED). Both-ends non-vacuity is proven by the mutation run: `OUTCOME_EVAL_GATE_OFF=1 bash <this>`
# flips exactly O1/O3/O4/O5 from BLOCK to ALLOW (4 red witnesses). O3/O4/O5 assert stderr names `outcome_eval`
# so each BLOCK is bound to the outcome leg (not a different leg blocking vacuously).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat > "$TMP/perf-1430.md" <<EOF
# 3-role performance log — #1430 outcome_eval leg
## rounds for #14301 #14302 #14303 #14304 #14305 #14306 #14307 #14308 #14309 #14310
EOF
# runO <taskId> <session> [extra-metadata-json] : DEDICATED outcome-free tagged builder (raw run + perf-1430.md,
# NO outcome keys unless passed as $3). Distinct from runT/runV/runC precisely so O1/O3/O4/O5 can go RED.
runO() {
  local t="$1" s="$2" extra="${3:-}"
  local md='"model_run":"r","model_perf_log":"'"$TMP"'/perf-1430.md"'
  [ -n "$extra" ] && md="$md,$extra"
  run '{"session_id":"'"$s"'","tool_input":{"taskId":"'"$t"'","status":"completed","metadata":{'"$md"'}}}'
}

# ---- O1 (RED-on-bug, positive-BLOCK). complete ledger + perf card cites taskId, NO outcome_eval -> BLOCK ----
ledger_complete sO1 14301; runO 14301 sO1
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "outcome_eval"; } && ok "O1 tagged, complete ledger, NO outcome_eval -> BLOCK (red-on-bug witness)" || bad "O1 should block naming outcome_eval (rc=$RC out=$CAP)"

# ---- O2 (green-on-fix). same dedicated builder + achieved + specific evidence -> ALLOW ----
ledger_complete sO2 14302; runO 14302 sO2 '"outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "O2 achieved + specific evidence -> ALLOW" || bad "O2 should allow (rc=$RC out=$CAP)"

# ---- O3. invalid verdict value 'great' (not in {achieved|partial|missed}) -> BLOCK naming outcome_eval ----
ledger_complete sO3 14303; runO 14303 sO3 '"outcome_eval":"great","outcome_evidence":"'"$OEV"'"'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "outcome_eval"; } && ok "O3 invalid verdict 'great' -> BLOCK (outcome-leg bound)" || bad "O3 should block naming outcome_eval (rc=$RC out=$CAP)"

# ---- O4. valid verdict, outcome_evidence MISSING -> BLOCK naming outcome_eval ----
ledger_complete sO4 14304; runO 14304 sO4 '"outcome_eval":"achieved"'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "outcome_eval"; } && ok "O4 valid verdict, evidence missing -> BLOCK (outcome-leg bound)" || bad "O4 should block naming outcome_eval (rc=$RC out=$CAP)"

# ---- O5. valid verdict, outcome_evidence 'done' (NONSPECIFIC / <20 chars) -> BLOCK naming outcome_eval ----
ledger_complete sO5 14305; runO 14305 sO5 '"outcome_eval":"achieved","outcome_evidence":"done"'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "outcome_eval"; } && ok "O5 valid verdict, generic 'done' evidence -> BLOCK (outcome-leg bound)" || bad "O5 should block naming outcome_eval (rc=$RC out=$CAP)"

# ---- O6 (partial ALLOWs). partial + specific evidence -> ALLOW ----
ledger_complete sO6 14306; runO 14306 sO6 '"outcome_eval":"partial","outcome_evidence":"'"$OEV"'"'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "O6 partial + specific evidence -> ALLOW" || bad "O6 should allow (rc=$RC out=$CAP)"

# ---- O7 (missed ALLOWs, anti-gaming). missed + specific evidence -> ALLOW (honest miss recorded, not blocked) ----
ledger_complete sO7 14307; runO 14307 sO7 '"outcome_eval":"missed","outcome_evidence":"'"$OEV"'"'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "O7 missed + specific evidence -> ALLOW (anti-gaming: honest miss recorded)" || bad "O7 should allow (rc=$RC out=$CAP)"

# ---- O8 (feature bypass). the O1 would-block payload + OUTCOME_EVAL_GATE_OFF=1 -> ALLOW ----
ledger_complete sO8 14308
CAP=$(printf '%s' '{"session_id":"sO8","tool_input":{"taskId":"14308","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1430.md"}}}' \
  | OUTCOME_EVAL_GATE_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "O8 OUTCOME_EVAL_GATE_OFF=1 skips the outcome leg -> ALLOW (feature bypass)" || bad "O8 feature kill-switch should allow (rc=$RC out=$CAP)"

# ---- O9 (master bypass). O1 would-block payload + THREE_ROLE_INSTRUMENT_OFF=1 -> allow silent ----
ledger_complete sO9 14309
CAP=$(printf '%s' '{"session_id":"sO9","tool_input":{"taskId":"14309","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1430.md"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "O9 THREE_ROLE_INSTRUMENT_OFF=1 on outcome-less payload -> allow silent (master bypass)" || bad "O9 master kill-switch should allow silent (rc=$RC out=$CAP)"

# ---- O10 (master bypass). O1 would-block payload + SHIP_PIPELINE=1 -> allow silent ----
ledger_complete sO10 14310
CAP=$(printf '%s' '{"session_id":"sO10","tool_input":{"taskId":"14310","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1430.md"}}}' \
  | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "O10 SHIP_PIPELINE=1 on outcome-less payload -> allow silent (ship exemption)" || bad "O10 SHIP_PIPELINE should allow silent (rc=$RC out=$CAP)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
