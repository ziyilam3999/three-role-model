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
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
skip() { echo "SKIP: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SID="sess-847"
PROJ="$TMP/proj"; mkdir -p "$PROJ"

# #1458: hermetically insulate EVERY call below from the REAL repo config/cc-roles.env, which now carries live
# CC_TIER_*_VERSION pins. Before #1458 the ambient repo config bled through silently here (harmlessly — the
# TIER leg's can't-tell already failed OPEN on these fixtures' assistant-model-less transcripts, so no test
# ever noticed which config it was reading). The version sub-leg's fail-closed-on-can't-tell makes that
# bleed-through visible: a pin now configured for real turns the SAME can't-tell fixture into a BLOCK. Export
# a "no config resolves" default so every pre-existing call is unaffected; the MDL*/W* arms that WANT
# model-policy/version enforcement explicitly override CC_ROLES_ENV per call (env CC_ROLES_ENV=<fixture> ...).
export CC_ROLES_ENV="$TMP/no-such-cc-roles.env"

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
#      #1580 NOTE: do NOT use ledger_complete here — its planner row is a COMPLETED real artifact (agentId +
#      artifact_path), and under #1580's monotonic clear-list a bare skip over that is now correctly REFUSED
#      (it would erase real evidence — exactly the class this ticket closes). Build the other three roles
#      directly and inline-skip planner while it has NO prior row at all, so the skip lands cleanly and this
#      fixture exercises the convention-dir fallback, not the (now-hardened) clear-list guard.
mk_sub sC3 agR; mk_sub sC3 agE; mk_sub sC3 agV
appendL --session sC3 --task 12693 --role plan-review      --agent agR --artifact "$LART_REV"
appendL --session sC3 --task 12693 --role executor         --agent agE --artifact "branch feat/x"
appendL --session sC3 --task 12693 --role execution-review --agent agV --artifact "$LART_REV"
D="$TMP/c3realproj"; mkplan "$D" no
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
# #1518 — cairn: RECEIPT SHAPE-TOLERANCE (decoration-prefix, still line-anchored). Widens all THREE #1269
# check-sites (4a plan grep ~L449, 4b review-file grep ~L468, 4b in-plan awk ~L471) to recognize a receipt
# decorated with a leading markdown prefix (bullet -/*/+, blockquote >, backtick, bold **, w/ leading
# whitespace) written on its OWN line, while a mid-sentence prose mention must still BLOCK (anti-vacuity
# power test per #1533) -- independently at EACH separately-authored surface (S7/S10/S13). S1-S4/S8/S11 are
# the RED->GREEN decorated-ALLOW set (blocked under the pre-fix anchored-plain-only regex, allowed post-fix);
# S5-S7/S9-S10/S12-S13 are stable-block/allow guards whose verdict is IDENTICAL pre- and post-fix -- they
# prove the widening did not become vacuous (an unanchored `cairn:`-anywhere fix would wrongly ALLOW S7/S10/S13).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat >> "$TMP/perf-1269.md" <<EOF
## rounds for #12703 #12704 #12705 #12706 #12707 #12708 #12709 #12710 #12711 #12712 #12713 #12714 #12715 #12716 #12717 #12718 #12719
EOF

# ---- S1 (AC1, RED->GREEN). 4a plan's ONLY receipt is a decorated BULLET: '- cairn: "hit"' -> ALLOW post-fix ----
ledger_complete sS1 12703; D="$TMP/s1"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n- cairn: "hit"\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS1 --task 12703 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12703 sS1 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC1: decorated-4a bullet '- cairn:' -> ALLOW" || bad "AC1 decorated-4a bullet should allow post-fix (rc=$RC out=$CAP)"

# ---- S2 (AC1, RED->GREEN). 4a plan's ONLY receipt is decorated with an inline-code BACKTICK -> ALLOW post-fix ----
ledger_complete sS2 12704; D="$TMP/s2"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n`cairn: "hit"`\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS2 --task 12704 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12704 sS2 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC1: decorated-4a backtick '\`cairn:\`' -> ALLOW" || bad "AC1 decorated-4a backtick should allow post-fix (rc=$RC out=$CAP)"

# ---- S3 (AC1, RED->GREEN). 4a plan's ONLY receipt is decorated BOLD: '**cairn:** "hit"' -> ALLOW post-fix ----
ledger_complete sS3 12705; D="$TMP/s3"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n**cairn:** "hit"\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS3 --task 12705 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12705 sS3 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC1: decorated-4a bold '**cairn:**' -> ALLOW" || bad "AC1 decorated-4a bold should allow post-fix (rc=$RC out=$CAP)"

# ---- S4 (AC2, RED->GREEN). 4a plan's ONLY receipt is leading-whitespace + BLOCKQUOTE combo: '  > cairn: "hit"' ----
ledger_complete sS4 12706; D="$TMP/s4"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n  > cairn: "hit"\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS4 --task 12706 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12706 sS4 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC2: 4a whitespace+blockquote combo '  > cairn:' -> ALLOW" || bad "AC2 4a whitespace+blockquote combo should allow post-fix (rc=$RC out=$CAP)"

# ---- S5 (AC3, stable-allow, no regression). 4a plan's receipt is PLAIN 'cairn: "hit"' -> ALLOW pre- AND post-fix ----
ledger_complete sS5 12707; D="$TMP/s5"; mkplan "$D" yes
appendL --session sS5 --task 12707 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12707 sS5 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC3: plain-4a-still-passes (no regression) -> ALLOW" || bad "AC3 plain-4a-still-passes should allow (rc=$RC out=$CAP)"

# ---- S6 (AC4, stable-block, anti-vacuity). 4a plan has NO cairn: line at all -> BLOCK pre- AND post-fix ----
ledger_complete sS6 12708; D="$TMP/s6"; mkplan "$D" no
appendL --session sS6 --task 12708 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12708 sS6 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC4: absent-4a-still-blocks (no cairn: line) -> BLOCK" || bad "AC4 absent-4a-still-blocks should block (rc=$RC out=$CAP)"

# ---- S7 (AC5, stable-block, LINE-ANCHOR POWER TEST for the 4a grep regex, #1533). 4a plan's ONLY occurrence of
#      the token is MID-SENTENCE PROSE (not line-leading) -> BLOCK pre- AND post-fix. Proves the widening did NOT
#      become anywhere-in-line: an unanchored fix would wrongly ALLOW this. ----
ledger_complete sS7 12709; D="$TMP/s7"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\nAs noted the cairn: entry says X\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS7 --task 12709 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12709 sS7 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "AC5: mid-prose-4a-still-blocks (line-anchor power test) -> BLOCK" || bad "AC5 mid-prose-4a-still-blocks should block (rc=$RC out=$CAP)"

# ---- S8 (AC6a, RED->GREEN). 4a plan valid (plain cairn:); 4b SEPARATE reviews/<id>.md's ONLY receipt is a
#      decorated bullet -> ALLOW post-fix (blocked pre-fix). ----
ledger_complete sS8 12710; D="$TMP/s8"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\n- cairn: "reviewer hit"\nverdict: PASS\n' > "$D/.ai-workspace/reviews/12710.md"
appendL --session sS8 --task 12710 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS8 --task 12710 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12710.md"
runC 12710 sS8 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC6a: 4b-review-file-decorated '- cairn:' -> ALLOW" || bad "AC6a 4b-review-file-decorated should allow post-fix (rc=$RC out=$CAP)"

# ---- S9 (AC6b, stable-block). 4a plan valid; 4b SEPARATE review file has NO cairn: line -> BLOCK pre- AND post-fix ----
ledger_complete sS9 12711; D="$TMP/s9"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\nverdict: PASS\nno citation\n' > "$D/.ai-workspace/reviews/12711.md"
appendL --session sS9 --task 12711 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS9 --task 12711 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12711.md"
runC 12711 sS9 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC6b: 4b-review-file-absent-blocks (no cairn: line) -> BLOCK" || bad "AC6b 4b-review-file-absent-blocks should block (rc=$RC out=$CAP)"

# ---- S10 (AC6c [B2], stable-block, LINE-ANCHOR POWER TEST for the SEPARATELY-authored 4b review-file grep
#      regex, #1533). 4a plan valid; 4b SEPARATE review file's ONLY cairn: token is MID-PROSE -> BLOCK pre- AND
#      post-fix. AC5/S7 never routes through $AREVIEW -- without this the 4b-file surface has no power test. ----
ledger_complete sS10 12712; D="$TMP/s10"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\nDecision: PASS -- as noted the cairn: search returned hits\n' > "$D/.ai-workspace/reviews/12712.md"
appendL --session sS10 --task 12712 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS10 --task 12712 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12712.md"
runC 12712 sS10 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC6c[B2]: 4b-review-file-mid-prose-blocks (line-anchor power test) -> BLOCK" || bad "AC6c[B2] 4b-review-file-mid-prose-blocks should block (rc=$RC out=$CAP)"

# ---- S11 (AC7a, RED->GREEN). planner->plan w/ plain cairn:, plan-review->SAME plan file (AREVIEW==APLAN -> awk
#      route); ## Review section's ONLY receipt is a decorated bullet -> ALLOW post-fix (blocked pre-fix). ----
ledger_complete sS11 12713; D="$TMP/s11"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS\n- cairn: "reviewer hit"\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS11 --task 12713 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS11 --task 12713 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12713 sS11 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "AC7a: 4b-in-plan-awk-decorated '- cairn:' -> ALLOW" || bad "AC7a 4b-in-plan-awk-decorated should allow post-fix (rc=$RC out=$CAP)"

# ---- S12 (AC7b, stable-block, #1269 invariant). planner->plan w/ cairn:, awk route; ## Review section carries
#      NO reviewer receipt (only the planner's top-of-file line, which must NEVER satisfy 4b) -> BLOCK pre- AND
#      post-fix. Cannot prove the anchor survived (blocks regardless) -- S13 is the real anchor oracle. ----
ledger_complete sS12 12714; D="$TMP/s12"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit only"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS\nno reviewer citation\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS12 --task 12714 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS12 --task 12714 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12714 sS12 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC7b: 4b-in-plan-awk-section-absent-blocks (planner line only) -> BLOCK" || bad "AC7b 4b-in-plan-awk-section-absent-blocks should block (rc=$RC out=$CAP)"

# ---- S13 (AC7c [B1, PRIMARY], stable-block, LINE-ANCHOR POWER TEST for the grep-invisible awk regex, #1533).
#      planner->plan w/ cairn:, awk route; ## Review section's ONLY in-section cairn: token is MID-PROSE -> BLOCK
#      pre- AND post-fix. A widened-but-UNANCHORED awk pattern (e.g. r&&/[Cc]airn:/, ^ dropped) would wrongly
#      ALLOW this -- this is the ONLY case with power to catch that (S12 blocks regardless of the anchor). ----
ledger_complete sS13 12715; D="$TMP/s13"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS -- as noted the cairn: search returned hits\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS13 --task 12715 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS13 --task 12715 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12715 sS13 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "plan-reviewer must independently search memory"; } && ok "AC7c[B1]: 4b-in-plan-awk-mid-prose-blocks (anchor power test) -> BLOCK" || bad "AC7c[B1] 4b-in-plan-awk-mid-prose-blocks should block (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1607 — cairn: RECEIPT SHAPE-TOLERANCE (ALTERNATING decoration+whitespace, still line-anchored). Widens the
# #1518 single-decoration-run tolerance to an ALTERNATING run of decoration+whitespace (e.g. bullet, THEN a
# space, THEN bold: '- **cairn:**') across all three #1269 check-sites. LIVE EVIDENCE: #1590's own plan +
# plan-review artifacts both carried this exact shape and both false-blocked. S14-S16 are the RED->GREEN
# alternating-decoration-ALLOW set (blocked under the pre-fix single-run regex, allowed post-fix); S17 is a
# stable-block anti-vacuity power test (decoration THEN prose, not decoration then cairn:) proving the
# widening did not become an unanchored anywhere-in-line match.
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# ---- S14 (#1607 AC1/AC3, RED->GREEN). 4a plan's ONLY receipt is ALTERNATING decoration '- **cairn:**'
#      (bullet, space, THEN bold) -> BLOCKED under the pre-fix single-decoration-run regex (RED), ALLOW
#      post-fix (GREEN). This is the exact #1590 false-block shape. ----
ledger_complete sS14 12716; D="$TMP/s14"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n- **cairn:** "hit"\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS14 --task 12716 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12716 sS14 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "#1607 AC1/AC3: alternating-decoration-4a '- **cairn:**' -> ALLOW" || bad "#1607 AC1/AC3 alternating-decoration-4a '- **cairn:**' should allow post-fix (rc=$RC out=$CAP)"

# ---- S15 (#1607 AC1/AC4, RED->GREEN). 4a plan valid (plain cairn:); 4b SEPARATE reviews/<id>.md's ONLY
#      receipt is ALTERNATING decoration '- **cairn:**' -> ALLOW post-fix (blocked pre-fix). ----
ledger_complete sS15 12717; D="$TMP/s15"; mkplan "$D" yes
mkdir -p "$D/.ai-workspace/reviews"; printf '## Review\n- **cairn:** "reviewer hit"\nverdict: PASS\n' > "$D/.ai-workspace/reviews/12717.md"
appendL --session sS15 --task 12717 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS15 --task 12717 --role plan-review --agent agR --artifact "$D/.ai-workspace/reviews/12717.md"
runC 12717 sS15 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "#1607 AC1/AC4: alternating-decoration-4b-review-file '- **cairn:**' -> ALLOW" || bad "#1607 AC1/AC4 alternating-decoration-4b-review-file should allow post-fix (rc=$RC out=$CAP)"

# ---- S16 (#1607 AC1/AC5, RED->GREEN). planner->plan w/ plain cairn:, plan-review->SAME plan file
#      (AREVIEW==APLAN -> awk route); ## Review section's ONLY receipt is ALTERNATING decoration
#      '- **cairn:**' -> ALLOW post-fix (blocked pre-fix). ----
ledger_complete sS16 12718; D="$TMP/s16"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\ncairn: "planner hit"\n### Binary AC\n- AC1\n\n## Review\nDecision: PASS\n- **cairn:** "reviewer hit"\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS16 --task 12718 --role planner     --agent agP --artifact "$D/.ai-workspace/plans/p.md"
appendL --session sS16 --task 12718 --role plan-review --agent agR --artifact "$D/.ai-workspace/plans/p.md"
runC 12718 sS16 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "#1607 AC1/AC5: alternating-decoration-4b-in-plan-awk '- **cairn:**' -> ALLOW" || bad "#1607 AC1/AC5 alternating-decoration-4b-in-plan-awk should allow post-fix (rc=$RC out=$CAP)"

# ---- S17 (#1607 AC6, stable-block, ANTI-VACUITY power test). 4a plan's ONLY cairn: occurrence is DECORATION
#      THEN PROSE (a bullet lead-in, but 'cairn:' is NOT the decoration's immediate next content) -> BLOCK
#      pre- AND post-fix. Proves the alternating widening stayed line-anchored: the decoration group must be
#      immediately followed by 'cairn:', not just precede it somewhere on the line. ----
ledger_complete sS17 12719; D="$TMP/s17"; mkdir -p "$D/.ai-workspace/plans"
printf '## ELI5\nplan\n- some note cairn: X\n### Binary AC\n- AC1\n\nbody\n' > "$D/.ai-workspace/plans/p.md"
appendL --session sS17 --task 12719 --role planner --agent agP --artifact "$D/.ai-workspace/plans/p.md"
runC 12719 sS17 THREE_ROLE_PLANS_DIR="$D/.ai-workspace/plans"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "PLANNER searched memory"; } && ok "#1607 AC6: decoration-then-prose-4a-still-blocks (anti-vacuity power test) -> BLOCK" || bad "#1607 AC6 decoration-then-prose-4a-still-blocks should block (rc=$RC out=$CAP)"

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

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1448 — per-role MODEL-POLICY leg (completion-seam). The gate passes --enforce-role-models to the ledger
# `check` on the tagged path (unless CC_ROLE_MODEL_GATE_OFF=1). When a role's ACTUAL transcript model
# (message.model on its subagent transcript — forgery-resistant) contradicts cc-roles.env, the ledger emits
# a `MODEL-POLICY:` problem, `check` exits 2, and the gate routes to block_model. Every OTHER leg must pass
# (perf card, complete ledger, cairn, outcome) so the MODEL leg alone decides the outcome. Fixtures give ONLY
# the executor transcript a model line (mk_sub_model) — the other three use plain mk_sub (no model -> that
# role fail-opens on the model leg), so only the executor can mismatch. Synthetic-only; no real home paths.
# NOTE: the whole EXISTING corpus above uses plain mk_sub (no message.model) -> every role fail-opens on the
# model leg -> the added --enforce-role-models flag is inert there (proven by the corpus staying green).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat > "$TMP/perf-1448.md" <<EOF
# 3-role performance log — #1448 per-role model-policy leg
## rounds for #14481 #144811 #14482 #14483 #14484 #14485
EOF
# a transcript fixture carrying an assistant message.model line (the model leg reads it): mk_sub_model <s> <id> <model-id>
mk_sub_model() {
  mkdir -p "$PROJROOT/proj/$1/subagents"
  { printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[]}}\n' "$2" "$3"; } \
    > "$PROJROOT/proj/$1/subagents/agent-$2.jsonl"
}
# complete 4-role ledger where the EXECUTOR transcript carries model $3: ledger_execmodel <session> <task> <exec-model-id>
ledger_execmodel() {
  mk_sub "$1" agP; mk_sub "$1" agR; mk_sub_model "$1" agE "$3"; mk_sub "$1" agV
  appendL --session "$1" --task "$2" --role planner          --agent agP --artifact "$LART_PLAN"
  appendL --session "$1" --task "$2" --role plan-review       --agent agR --artifact "$LART_REV"
  appendL --session "$1" --task "$2" --role executor          --agent agE --artifact "branch feat/x"
  appendL --session "$1" --task "$2" --role execution-review  --agent agV --artifact "$LART_REV"
}
# runM <taskId> <session> [extra-env...] : tagged completion citing perf-1448.md + valid outcome, ledger store wired.
runM() {
  local t="$1" s="$2"; shift 2
  CAP=$(printf '%s' '{"session_id":"'"$s"'","tool_input":{"taskId":"'"$t"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1448.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
    | env THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$HOOK" 2>&1 >/dev/null); RC=$?
}
MODCFG="$TMP/cc-roles-mod.env"; printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_ROLE_EXECUTOR_EFFORT=medium\n' > "$MODCFG"

# ---- MDL1 (model BLOCK, #1624 RE-POINTED to a genuine DOWN-tier). executor transcript=haiku vs config=sonnet
#      -> a strict quality DOWN-tier (never allowed, #1624 does not relax this direction) -> MODEL-POLICY
#      mismatch -> block_model exit 2. (Pre-#1624 this fixture used opus-vs-sonnet, an UP-tier direction that
#      #1624 now allows-with-note at close -- see MDL1b below; re-pointing here keeps MDL1 a real down-tier RED
#      so the gate's blocking power against a genuine corner-cut is still proven, not silently vacated.)
ledger_execmodel sMDL1 14481 "claude-haiku-4-0"
runM 14481 sMDL1 CC_ROLES_ENV="$MODCFG"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "model-policy leg FAILED"; } && ok "MDL1 executor=haiku vs config=sonnet (down-tier) -> BLOCK (model-policy leg, #1624 re-pointed)" || bad "MDL1 down-tier wrong model should block via model leg (rc=$RC out=$CAP)"

# ---- MDL1b (model ALLOW-WITH-NOTE, #1624 NEW). executor transcript=opus vs config=sonnet, NO resume boundary
#      -> a strict quality UP-tier at close -> allowed-with-note (operator decision 2026-07-17: model cost is
#      enforced at booking/spawn, not at close). Proves the relaxation reaches through the instrumentation
#      gate's model-policy leg, not just the bare `3role-ledger.mjs check` call exercised directly elsewhere.
ledger_execmodel sMDL1b 144811 "claude-opus-4-8"
runM 144811 sMDL1b CC_ROLES_ENV="$MODCFG"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "model-policy OK"; } && ok "MDL1b executor=opus vs config=sonnet, no resume (#1624 up-tier) -> ALLOW (model-policy OK note)" || bad "MDL1b non-resume up-tier should allow via model leg (rc=$RC out=$CAP)"

# ---- MDL2 (model ALLOW). executor transcript=sonnet matches config=sonnet -> ledger OK + model-policy OK -> exit 0 ----
ledger_execmodel sMDL2 14482 "claude-sonnet-4-6"
runM 14482 sMDL2 CC_ROLES_ENV="$MODCFG"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "model-policy OK"; } && ok "MDL2 executor=sonnet matches config -> ALLOW (+ model-policy OK note)" || bad "MDL2 matching model should allow (rc=$RC out=$CAP)"

# ---- MDL3 (feature kill-switch, #1624 re-pointed to the DOWN-tier MDL1 fixture so the kill-switch is
#      genuinely load-bearing -- an up-tier fixture would ALLOW even without the switch post-#1624, which
#      would prove nothing). MDL1 (down-tier) red fixture + CC_ROLE_MODEL_GATE_OFF=1 -> model leg NOT
#      enforced -> exit 0 ----
ledger_execmodel sMDL3 14483 "claude-haiku-4-0"
runM 14483 sMDL3 CC_ROLES_ENV="$MODCFG" CC_ROLE_MODEL_GATE_OFF=1
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "MDL3 CC_ROLE_MODEL_GATE_OFF=1 over down-tier wrong-model -> ALLOW (feature kill-switch)" || bad "MDL3 kill-switch should allow (rc=$RC out=$CAP)"

# ---- MDL4 (no-config). executor transcript=opus but CC_ROLES_ENV=/nonexistent -> model enforcement SKIPPED -> exit 0 ----
ledger_execmodel sMDL4 14484 "claude-opus-4-8"
runM 14484 sMDL4 CC_ROLES_ENV=/nonexistent
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "MDL4 no-config -> model enforcement skipped -> ALLOW (no false-block)" || bad "MDL4 no-config should allow (rc=$RC out=$CAP)"

# ---- MDL5 (master kill-switch, #1624 re-pointed to the DOWN-tier MDL1 fixture -- same rationale as MDL3).
#      MDL1 (down-tier) red fixture + THREE_ROLE_INSTRUMENT_OFF=1 -> allow silent (short-circuits) ----
ledger_execmodel sMDL5 14485 "claude-haiku-4-0"
runM 14485 sMDL5 CC_ROLES_ENV="$MODCFG" THREE_ROLE_INSTRUMENT_OFF=1
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "MDL5 THREE_ROLE_INSTRUMENT_OFF=1 over down-tier wrong-model -> allow silent (master bypass)" || bad "MDL5 master kill-switch should allow silent (rc=$RC out=$CAP)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1458 — MODEL-VERSION completion-seam leg (assert-latest / fail-on-drift). Same shape as MDL1-MDL5 above
# but a DEDICATED pinned config (MVERCFG_* — NEVER MODCFG: MODCFG MUST stay pin-free, else the pre-existing
# sMDL2 "claude-sonnet-4-6" arm above would flip to exit 2 the moment it gained a CC_TIER_SONNET_VERSION pin).
# Every OTHER leg must pass (perf card, complete ledger, cairn, outcome) so the VERSION leg alone decides.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
cat > "$TMP/perf-1458.md" <<EOF
# 3-role performance log — #1458 model-VERSION drift leg
## rounds for #14581 #14582 #14583 #14584 #14585
EOF
# runW <taskId> <session> [extra-env...] : tagged completion citing perf-1458.md + valid outcome, ledger wired.
runW() {
  local t="$1" s="$2"; shift 2
  CAP=$(printf '%s' '{"session_id":"'"$s"'","tool_input":{"taskId":"'"$t"'","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1458.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
    | env THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$HOOK" 2>&1 >/dev/null); RC=$?
}
MVERCFG_RED="$TMP/mvercfg-red.env";     printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_TIER_SONNET_VERSION=claude-sonnet-6\n' > "$MVERCFG_RED"
MVERCFG_GREEN="$TMP/mvercfg-green.env"; printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_TIER_SONNET_VERSION=claude-sonnet-5\n' > "$MVERCFG_GREEN"
MVERCFG_NOPIN="$TMP/mvercfg-nopin.env"; printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\n' > "$MVERCFG_NOPIN"

# ---- W1 (RED, primary close-gate proof). executor transcript=claude-sonnet-5, pin=claude-sonnet-6 -> BLOCK
#      via block_version; stderr names the version leg + the observed/pinned ids. ----
ledger_execmodel sW1 14581 "claude-sonnet-5"
runW 14581 sW1 CC_ROLES_ENV="$MVERCFG_RED"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "model-VERSION leg FAILED" && echo "$CAP" | grep -q "claude-sonnet-5" && echo "$CAP" | grep -q "claude-sonnet-6"; } \
  && ok "W1 executor=claude-sonnet-5 vs pin=claude-sonnet-6 -> BLOCK (block_version, names observed+pinned)" || bad "W1 version drift should block via block_version (rc=$RC out=$CAP)"

# ---- W2 (GREEN). executor transcript matches the pin exactly -> ALLOW. ----
ledger_execmodel sW2 14582 "claude-sonnet-5"
runW 14582 sW2 CC_ROLES_ENV="$MVERCFG_GREEN"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "W2 executor matches pin exactly -> ALLOW" || bad "W2 matching pin should allow (rc=$RC out=$CAP)"

# ---- W3 (no-pin dormant). same drifted transcript, config has NO CC_TIER_SONNET_VERSION -> version leg
#      dormant, tier leg alone passes -> ALLOW. ----
ledger_execmodel sW3 14583 "claude-sonnet-6"
runW 14583 sW3 CC_ROLES_ENV="$MVERCFG_NOPIN"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "W3 no-pin dormant -> ALLOW" || bad "W3 no-pin should allow (rc=$RC out=$CAP)"

# ---- W4 (version-only kill-switch). W1's RED fixture + CC_ROLE_VERSION_GATE_OFF=1 -> ALLOW. ----
runW 14581 sW1 CC_ROLES_ENV="$MVERCFG_RED" CC_ROLE_VERSION_GATE_OFF=1
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } && ok "W4 CC_ROLE_VERSION_GATE_OFF=1 over RED drift -> ALLOW (version-only kill-switch)" || bad "W4 version kill-switch should allow (rc=$RC out=$CAP)"

# ---- W5 (whole-leg kill-switch). W1's RED fixture + CC_ROLE_MODEL_GATE_OFF=1 -> ALLOW. ----
runW 14581 sW1 CC_ROLES_ENV="$MVERCFG_RED" CC_ROLE_MODEL_GATE_OFF=1
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "ledger OK"; } && ok "W5 CC_ROLE_MODEL_GATE_OFF=1 over RED drift -> ALLOW (whole model+version leg off)" || bad "W5 model kill-switch should allow (rc=$RC out=$CAP)"


# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1509 — Leg A (tracked-ness) HARD block at the completion gate, SHIP_PIPELINE-PROOF (AC-1 real-seam RED,
# AC-7 hardening). Fixtures live inside a DEDICATED scratch git repo (mktemp -d + `git init`) so
# `git ls-files --error-unmatch` produces REAL tracked/untracked verdicts — every other artifact fixture in
# this file lives directly under $TMP (not a git repo), which is exactly why the entire pre-existing corpus
# above is unaffected by this addition (Leg A can't-tell -> fail-open there).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
GITROOT_H="$(mktemp -d)"
( cd "$GITROOT_H" && git init -q && git config user.email t@t.co && git config user.name t )
mkdir -p "$GITROOT_H/.ai-workspace/plans" "$GITROOT_H/.ai-workspace/reviews"
printf '## ELI5\nplan\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_H/.ai-workspace/plans/1509h-plan.md"
printf '## Review\ncairn: "synth reviewer hit"\nverdict: PASS\n' > "$GITROOT_H/.ai-workspace/reviews/1509h-rev.md"
cat > "$TMP/perf-1509.md" <<EOF
# 3-role performance log — #1509 Leg A smoke
## rounds for #1509h #1509h2
EOF

TAGSID="sess-1509h"
mk_sub "$TAGSID" hp1; mk_sub "$TAGSID" hr1; mk_sub "$TAGSID" he1; mk_sub "$TAGSID" hv1
appendL --session "$TAGSID" --task 1509h --role planner          --agent hp1 --artifact "$GITROOT_H/.ai-workspace/plans/1509h-plan.md"
appendL --session "$TAGSID" --task 1509h --role plan-review       --agent hr1 --artifact "$GITROOT_H/.ai-workspace/reviews/1509h-rev.md"
appendL --session "$TAGSID" --task 1509h --role executor          --agent he1 --artifact "PR #1509h"
appendL --session "$TAGSID" --task 1509h --role execution-review  --agent hv1 --artifact "$GITROOT_H/.ai-workspace/reviews/1509h-rev.md"

run1509h() { run '{"session_id":"'"$TAGSID"'","tool_input":{"taskId":"1509h","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1509.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'; }

# ---- H1 [proof] RED: the three disk-path artifacts EXIST on disk but are UNTRACKED (never `git add`-ed) ->
#      a REAL tagged completion citing them is BLOCKed by Leg A, at the SAME seam as the perf-card/ledger legs. ----
run1509h
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "tracked-ness leg FAILED" && echo "$CAP" | grep -q "TRACKED:"; } \
  && ok "[proof] 1509-H1 RED: untracked disk-path artifacts on a REAL tagged completion -> Leg A BLOCK" \
  || bad "1509-H1 RED failed (rc=$RC out=$CAP)"

# ---- H2 [proof] AC-7 SHIP_PIPELINE HARDENING: the IDENTICAL RED payload run WITH SHIP_PIPELINE=1 exported
#      -> STILL BLOCKED. This is the round-3 review's hardening requirement made binary: Leg A does NOT
#      honor the rest of the family's SHIP_PIPELINE exemption, proven against the SAME fixture as H1 (not a
#      weaker synthetic substitute). ----
CAP=$(printf '%s' '{"session_id":"'"$TAGSID"'","tool_input":{"taskId":"1509h","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1509.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
  | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "TRACKED:"; } \
  && ok "[proof] 1509-H2 AC-7: SHIP_PIPELINE=1 over the SAME untracked-artifact fixture -> STILL BLOCK (no route-around)" \
  || bad "1509-H2 AC-7 SHIP_PIPELINE hardening failed (rc=$RC out=$CAP)"

# ---- H3 [proof] GREEN: git add + commit the three artifacts -> the SAME tagged completion now ALLOWS (Leg A
#      satisfied; the perf-card/ledger/cairn/outcome legs downstream already held for this fixture). ----
( cd "$GITROOT_H" && git add .ai-workspace/plans/1509h-plan.md .ai-workspace/reviews/1509h-rev.md && git commit -q -m "fixture: track the 1509h artifacts" )
run1509h
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "[proof] 1509-H3 GREEN: same artifacts committed -> tagged completion ALLOWS" \
  || bad "1509-H3 GREEN failed (rc=$RC out=$CAP)"

# ---- H4 [control] the pre-existing MASTER kill-switch still disables Leg A too (THREE_ROLE_INSTRUMENT_OFF=1
#      over a FRESH untracked-artifact fixture — a second task so H3's commit cannot mask it). Leg A carries
#      no bypass flag of its OWN by design; this proves the one pre-existing escape still reaches it. ----
printf '## ELI5\nplan2\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_H/.ai-workspace/plans/1509h2-plan.md"
mk_sub "$TAGSID" hp2; mk_sub "$TAGSID" hr2; mk_sub "$TAGSID" he2; mk_sub "$TAGSID" hv2
appendL --session "$TAGSID" --task 1509h2 --role planner          --agent hp2 --artifact "$GITROOT_H/.ai-workspace/plans/1509h2-plan.md"
appendL --session "$TAGSID" --task 1509h2 --role plan-review       --agent hr2 --artifact "$GITROOT_H/.ai-workspace/reviews/1509h-rev.md"
appendL --session "$TAGSID" --task 1509h2 --role executor          --agent he2 --artifact "PR #1509h2"
appendL --session "$TAGSID" --task 1509h2 --role execution-review  --agent hv2 --artifact "$GITROOT_H/.ai-workspace/reviews/1509h-rev.md"
CAP=$(printf '%s' '{"session_id":"'"$TAGSID"'","tool_input":{"taskId":"1509h2","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1509.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "[control] 1509-H4: THREE_ROLE_INSTRUMENT_OFF=1 (whole-family master switch) over an untracked-Leg-A fixture -> allow silent" \
  || bad "1509-H4 master kill-switch failed (rc=$RC out=$CAP)"
rm -rf "$GITROOT_H" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1537 — artifact-PRIVACY leg (Binary AC1-AC12 of the plan). Sibling of the #1509 Leg-A block above: same
# scratch-git-repo pattern (isGitTracked must see REAL verdicts), extended with (a) three dirty-class plan
# fixtures, (b) a clean/dirty perf-log-card pair inside the SAME scratch repo (round-2 scope promotion), (c)
# an out-of-repo perf card under bare $TMP (never a git repo) for the fail-open boundary test, and (d) three
# isolated one-off git repos whose LOCAL user.email is a synthetic value, so the EMAIL class can be exercised
# and MUTATED without ever touching the real operator's email.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# PORTABILITY GUARD: this whole #1537 block is ai-brain-ONLY. Every BLOCK assertion below needs
# scripts/privacy-scan.sh (+ its denylist libs + hooks/lib-privacy-ere.sh + scripts/sync-three-role-plugin.mjs)
# to be present so the leg can actually scan. In the three-role-model PLUGIN those files are deliberately
# ABSENT and the gate's privacy leg ships DORMANT (presence-guarded) — so a dirty fixture would ALLOW, not
# BLOCK, and the assertions would false-fail. Guard the entire block on scanner presence: ai-brain CI runs it
# in full (scanner present -> real coverage, unchanged); plugin CI skips it cleanly (leg is dormant there by
# design). This is the same presence-guard the gate itself uses — its absence exactly defines the dormant
# context. AC4/AC5/AC6 invoke the scanner directly, so ai-brain coverage stays real, never vacuous.
if [ ! -f "$DIR/../scripts/privacy-scan.sh" ]; then
  skip "#1537 artifact-privacy leg (AC1-AC12): scripts/privacy-scan.sh absent (three-role-model plugin dormant context) -> ai-brain-only, skipped"
else
GITROOT_P="$(mktemp -d)"
( cd "$GITROOT_P" && git init -q && git config user.email t@t.co && git config user.name t )
mkdir -p "$GITROOT_P/.ai-workspace/plans" "$GITROOT_P/.ai-workspace/reviews" "$GITROOT_P/.ai-workspace/perf-logs"

SID_P="sess-1537p"
mk_sub "$SID_P" pp1; mk_sub "$SID_P" pr1; mk_sub "$SID_P" pe1; mk_sub "$SID_P" pv1

# clean plan/review (also satisfy the cairn-citation legs' shape: `## ELI5`+`cairn:`+`### Binary AC`, `## Review`+`cairn:`+`verdict:`).
printf '## ELI5\nplan\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_P/.ai-workspace/plans/1537p-plan-clean.md"
printf '## Review\ncairn: "synth reviewer hit"\nverdict: PASS\n' > "$GITROOT_P/.ai-workspace/reviews/1537p-rev-clean.md"
# one dirty fixture PER CLASS — otherwise identical to the clean plan, so ONLY the targeted class fires.
printf '## ELI5\nplan with a leak /Users/synthuser/secret\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
printf '## ELI5\nplan with a leak SYNTHBRANDTOKEN1537\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_P/.ai-workspace/plans/1537p-plan-brand.md"
printf '## ELI5\nplan with a leak synth-user-1537@example.test\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_P/.ai-workspace/plans/1537p-plan-email.md"
# perf-log cards, clean + dirty, INSIDE the scratch ai-brain-shaped repo (round-2 scope promotion).
printf '# perf log\n## rounds for #1537p1 #1537p2 #1537p3 #1537p4 #1537p6 #1537p8 #1537p9 #1537p10 #1537p11 #1537p12 #1537p13 #1537p14 #1537p15\n' > "$GITROOT_P/.ai-workspace/perf-logs/1537p-perf-clean.md"
printf '# perf log\n## rounds for #1537p5\nleak: /Users/synthuser/perf-leak\n' > "$GITROOT_P/.ai-workspace/perf-logs/1537p-perf-dirty.md"
( cd "$GITROOT_P" && git add -A && git commit -q -m "fixture: #1537 privacy-leg artifacts" )

# isolated one-off repos whose LOCAL user.email is a synthetic value (never the real operator's). Never a
# committed fixture — PRIVACY_SCAN_CWD points the spawned scanner's cwd here so `git config user.email`
# resolves it live at scan time, proving the needle is SOURCED from git config (AC6), not a hardcoded literal.
EMAILGIT_A="$(mktemp -d)"; ( cd "$EMAILGIT_A" && git init -q && git config user.email "synth-user-1537@example.test" )
EMAILGIT_B="$(mktemp -d)"; ( cd "$EMAILGIT_B" && git init -q && git config user.email "synth-other-1537@example.test" )
EMAILGIT_EMPTY="$(mktemp -d)"; ( cd "$EMAILGIT_EMPTY" && git init -q )   # no user.email configured at all -> empty needle -> SKIP

# ledger builder: role artifacts default to the CLEAN plan/review unless overridden. taskid [planPath] [reviewPath]
ledgerP() {
  local t="$1" plan="${2:-$GITROOT_P/.ai-workspace/plans/1537p-plan-clean.md}" rev="${3:-$GITROOT_P/.ai-workspace/reviews/1537p-rev-clean.md}"
  appendL --session "$SID_P" --task "$t" --role planner          --agent pp1 --artifact "$plan"
  appendL --session "$SID_P" --task "$t" --role plan-review       --agent pr1 --artifact "$rev"
  appendL --session "$SID_P" --task "$t" --role executor          --agent pe1 --artifact "PR #$t"
  appendL --session "$SID_P" --task "$t" --role execution-review  --agent pv1 --artifact "$rev"
}
privPayload() { printf '{"session_id":"%s","tool_input":{"taskId":"%s","status":"completed","metadata":{"model_run":"r","model_perf_log":"%s","outcome_eval":"achieved","outcome_evidence":"%s"}}}' "$SID_P" "$1" "$2" "$OEV"; }
runP() { local payload="$1"; shift; CAP=$(printf '%s' "$payload" | env THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$HOOK" 2>&1 >/dev/null); RC=$?; }
CLEANPERF="$GITROOT_P/.ai-workspace/perf-logs/1537p-perf-clean.md"

# ---- AC1a: dirty HOME-PATH plan artifact -> BLOCK, all three classes covered (this sub-case: home-path) ----
ledgerP 1537p1 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
runP "$(privPayload 1537p1 "$CLEANPERF")"
CAP_HP="$CAP"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "artifact-privacy leg FAILED" && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC1a: dirty home-path plan artifact -> BLOCK" || bad "AC1a home-path dirty should block (rc=$RC out=$CAP)"

# ---- AC1b: dirty BRAND plan artifact -> BLOCK (sanctioned PRIVACY_SCAN_TEST_PATTERN hook, no real brand token) ----
ledgerP 1537p2 "$GITROOT_P/.ai-workspace/plans/1537p-plan-brand.md"
runP "$(privPayload 1537p2 "$CLEANPERF")" PRIVACY_SCAN_TEST_PATTERN=SYNTHBRANDTOKEN1537
CAP_BRAND="$CAP"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC1b: dirty brand plan artifact -> BLOCK" || bad "AC1b brand dirty should block (rc=$RC out=$CAP)"

# ---- AC1c: dirty EMAIL plan artifact (isolated synthetic git env, config matches the fixture) -> BLOCK ----
ledgerP 1537p3 "$GITROOT_P/.ai-workspace/plans/1537p-plan-email.md"
runP "$(privPayload 1537p3 "$CLEANPERF")" PRIVACY_SCAN_CWD="$EMAILGIT_A"
CAP_EMAIL="$CAP"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC1c: dirty email plan artifact (isolated synthetic env) -> BLOCK" || bad "AC1c email dirty should block (rc=$RC out=$CAP)"

# ---- AC2: clean plan/review + clean perf card -> PASS (hook exit 0, ledger note present) ----
ledgerP 1537p4
runP "$(privPayload 1537p4 "$CLEANPERF")"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC2: clean plan/review artifacts -> PASS" || bad "AC2 clean should pass (rc=$RC out=$CAP)"

# ---- AC3a: dirty TRACKED perf-log card (clean plan/review) -> BLOCK ----
ledgerP 1537p5
runP "$(privPayload 1537p5 "$GITROOT_P/.ai-workspace/perf-logs/1537p-perf-dirty.md")"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:" && echo "$CAP" | grep -q "perf-log card"; } \
  && ok "AC3a: dirty tracked ai-brain perf-log card -> BLOCK" || bad "AC3a dirty perf card should block (rc=$RC out=$CAP)"

# ---- AC3b: clean TRACKED perf-log card -> the privacy leg does not fire (hook ALLOWs) ----
ledgerP 1537p6
runP "$(privPayload 1537p6 "$CLEANPERF")"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC3b: clean tracked ai-brain perf-log card -> ALLOW" || bad "AC3b clean perf card should allow (rc=$RC out=$CAP)"

# ---- AC3c: perf card path resolves OUTSIDE the ai-brain repo (bare $TMP is not a git repo) -> fail-OPEN
#      (not scanned, no block) EVEN THOUGH it carries a dirty synthetic home-path token -- the boundary rule
#      is keyed on git-tracked-INSIDE-ai-brain, never fail-open-on-everything (AC3a's IN-repo dirty card
#      still blocks above). ----
PERF_OUTSIDE="$TMP/1537p-perf-outside-dirty.md"
printf '# perf log (out of repo)\n## rounds for #1537p7\nleak: /Users/synthuser/outside-leak\n' > "$PERF_OUTSIDE"
ledgerP 1537p7
runP "$(privPayload 1537p7 "$PERF_OUTSIDE")"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC3c: out-of-repo dirty perf card -> fail-OPEN (not scanned, hook ALLOWs)" || bad "AC3c out-of-repo should fail-open (rc=$RC out=$CAP)"

# ---- AC4: positive control MUST fire for EACH class (direct scanner-level proof, independent of ledger plumbing) ----
SCANNER_BIN="$DIR/../scripts/privacy-scan.sh"
"$SCANNER_BIN" --working "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md" >/tmp/1537-ac4-hp.err 2>&1
{ [ "$?" = "1" ] && grep -q "home-path matches=1" /tmp/1537-ac4-hp.err; } \
  && ok "AC4a: home-path positive control fires (count=1)" || bad "AC4a home-path control did not fire"
PRIVACY_SCAN_TEST_PATTERN=SYNTHBRANDTOKEN1537 "$SCANNER_BIN" --working "$GITROOT_P/.ai-workspace/plans/1537p-plan-brand.md" >/tmp/1537-ac4-bt.err 2>&1
{ [ "$?" = "1" ] && grep -q "brand matches=1" /tmp/1537-ac4-bt.err; } \
  && ok "AC4b: brand positive control fires (count=1, sanctioned test pattern)" || bad "AC4b brand control did not fire"
( cd "$EMAILGIT_A" && "$SCANNER_BIN" --working "$GITROOT_P/.ai-workspace/plans/1537p-plan-email.md" >/tmp/1537-ac4-em.err 2>&1 )
{ [ "$?" = "1" ] && grep -q "email matches=1" /tmp/1537-ac4-em.err; } \
  && ok "AC4c: email positive control fires (count=1, isolated synthetic env)" || bad "AC4c email control did not fire"
rm -f /tmp/1537-ac4-hp.err /tmp/1537-ac4-bt.err /tmp/1537-ac4-em.err

# ---- AC5: home-path needle SOURCED from hooks/lib-privacy-ere.sh, proven by mutation (BLOCK -> ALLOW flip) ----
MUT="$TMP/1537-mutated-scanner"
mkdir -p "$MUT/scripts" "$MUT/hooks" "$MUT/lib"
cp "$DIR/../scripts/privacy-scan.sh" "$MUT/scripts/privacy-scan.sh"
cp "$DIR/../scripts/privacy-denylist-count.mjs" "$MUT/scripts/privacy-denylist-count.mjs"
cp "$DIR/../lib/privacy-denylist.mjs" "$MUT/lib/privacy-denylist.mjs"
printf 'PRIVACY_HOMEPATH_ERE="NEVERMATCHXYZ_IMPOSSIBLE_1537_PATTERN"\n' > "$MUT/hooks/lib-privacy-ere.sh"
chmod +x "$MUT/scripts/privacy-scan.sh"
ledgerP 1537p8 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
runP "$(privPayload 1537p8 "$CLEANPERF")" THREE_ROLE_PRIVACY_SCANNER="$MUT/scripts/privacy-scan.sh"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC5: home-path needle sourced from the lib (neutered-ERE mutation flips BLOCK->ALLOW)" \
  || bad "AC5 mutation should flip to ALLOW (rc=$RC out=$CAP)"

# ---- AC6: email needle SOURCED from \`git config user.email\`, proven by mutation (SAME dirty-email fixture,
#      config value Y != the fixture's X -> the email class does not fire -> ALLOW; task 1537p3 above already
#      proved config value X (matching) -> BLOCK, so the verdict TRACKS the config value). ----
ledgerP 1537p9 "$GITROOT_P/.ai-workspace/plans/1537p-plan-email.md"
runP "$(privPayload 1537p9 "$CLEANPERF")" PRIVACY_SCAN_CWD="$EMAILGIT_B"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC6: email needle sourced from git config (mismatched synthetic config -> ALLOW; matched config #1537p3 -> BLOCK)" \
  || bad "AC6 mismatched email config should allow (rc=$RC out=$CAP)"

# ---- AC7: the block report never quotes the matched secret bytes (captured from AC1a/AC1b/AC1c above) ----
{ ! printf '%s' "$CAP_HP" | grep -qF "synthuser/secret"; } \
  && ok "AC7a: home-path block report does not quote the matched bytes" || bad "AC7a leaked the home-path needle: $CAP_HP"
{ ! printf '%s' "$CAP_BRAND" | grep -qF "SYNTHBRANDTOKEN1537"; } \
  && ok "AC7b: brand block report does not quote the matched bytes" || bad "AC7b leaked the brand needle: $CAP_BRAND"
{ ! printf '%s' "$CAP_EMAIL" | grep -qF "synth-user-1537@example.test"; } \
  && ok "AC7c: email block report does not quote the matched bytes" || bad "AC7c leaked the email needle: $CAP_EMAIL"

# ---- AC8: SHIP_PIPELINE-proof — a dirty TRACKED artifact still BLOCKs under SHIP_PIPELINE=1 (no route-around) ----
ledgerP 1537p10 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
CAP=$(printf '%s' "$(privPayload 1537p10 "$CLEANPERF")" \
  | SHIP_PIPELINE=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC8: SHIP_PIPELINE=1 over a dirty tracked artifact -> STILL BLOCK (no route-around)" \
  || bad "AC8 SHIP_PIPELINE hardening failed (rc=$RC out=$CAP)"

# ---- AC9: exactly ONE new kill-switch, works both ways, + no other new *_OFF/*_OVERRIDE token ----
ledgerP 1537p11 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
runP "$(privPayload 1537p11 "$CLEANPERF")" THREE_ROLE_ARTIFACT_PRIVACY_OFF=1
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC9a: THREE_ROLE_ARTIFACT_PRIVACY_OFF=1 over a dirty artifact -> ALLOW (leg-only kill-switch)" \
  || bad "AC9a leg kill-switch failed (rc=$RC out=$CAP)"
CAP=$(printf '%s' "$(privPayload 1537p11 "$CLEANPERF")" \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC9b: THREE_ROLE_INSTRUMENT_OFF=1 (master) over the SAME dirty artifact -> allow silent" \
  || bad "AC9b master kill-switch failed (rc=$RC out=$CAP)"
NEWTOKENS="$(grep -ohE '[A-Z_]+_(OFF|OVERRIDE)' "$DIR/three-role-instrumentation-gate.sh" "$DIR/3role-ledger.mjs" "$DIR/../scripts/privacy-scan.sh" 2>/dev/null | sort -u)"
{ echo "$NEWTOKENS" | grep -qx "THREE_ROLE_ARTIFACT_PRIVACY_OFF" \
  && [ "$(echo "$NEWTOKENS" | grep -c 'ARTIFACT_PRIVACY')" = "1" ]; } \
  && ok "AC9c: grep proves THREE_ROLE_ARTIFACT_PRIVACY_OFF is the ONE new privacy kill-switch token" \
  || bad "AC9c unexpected privacy-related *_OFF/*_OVERRIDE token set: $NEWTOKENS"

# ---- AC10: dormant when the scanner is unavailable -> no error, does NOT block on the privacy leg (other legs decide) ----
ledgerP 1537p12 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
runP "$(privPayload 1537p12 "$CLEANPERF")" THREE_ROLE_PRIVACY_SCANNER=/nonexistent/1537-privacy-scan.sh
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK" && ! echo "$CAP" | grep -qi "privacy"; } \
  && ok "AC10: scanner unavailable -> DORMANT (no error, privacy leg does not block; other legs decide)" \
  || bad "AC10 dormant-scanner case failed (rc=$RC out=$CAP)"

# ---- AC11a: fail-CLOSED on can't-tell (scanner cannot produce a valid count -> BLOCK, never reports clean) ----
MUTBROKEN="$TMP/1537-mutated-scanner-broken"
mkdir -p "$MUTBROKEN/scripts"
cp "$DIR/../scripts/privacy-scan.sh" "$MUTBROKEN/scripts/privacy-scan.sh"
chmod +x "$MUTBROKEN/scripts/privacy-scan.sh"
# deliberately NO hooks/lib-privacy-ere.sh anywhere the script can resolve -> PRIVACY_HOMEPATH_ERE stays unset -> ABORT rc 2.
ledgerP 1537p13
runP "$(privPayload 1537p13 "$CLEANPERF")" THREE_ROLE_PRIVACY_SCANNER="$MUTBROKEN/scripts/privacy-scan.sh"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC11a: forced-abort can't-tell -> BLOCK (fail-closed, never reports clean)" \
  || bad "AC11a forced-abort should fail-closed to BLOCK (rc=$RC out=$CAP)"

# ---- AC11b: empty git-config user.email is SKIP-not-block (no false block from an empty needle); home-path
#      and brand STILL block on a dirty fixture when email is empty (monotonicity: the weak email-skip cannot
#      erase the strong classes). ----
ledgerP 1537p14 "$GITROOT_P/.ai-workspace/plans/1537p-plan-email.md"
runP "$(privPayload 1537p14 "$CLEANPERF")" PRIVACY_SCAN_CWD="$EMAILGIT_EMPTY"
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "AC11b-i: empty git-config email -> SKIP the email class (no false block)" \
  || bad "AC11b-i empty-email should skip, not block (rc=$RC out=$CAP)"
ledgerP 1537p15 "$GITROOT_P/.ai-workspace/plans/1537p-plan-homepath.md"
runP "$(privPayload 1537p15 "$CLEANPERF")" PRIVACY_SCAN_CWD="$EMAILGIT_EMPTY"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "PRIVACY:"; } \
  && ok "AC11b-ii: home-path STILL BLOCKs on a dirty fixture when email is empty (monotonicity holds)" \
  || bad "AC11b-ii home-path should still block with empty email (rc=$RC out=$CAP)"

# ---- AC12: this smoke (carrying the privacy-leg AC1-AC11 assertions above) is enumerated by the plugin-sync
#      SSOT, so it runs in CI. ----
SYNC_SCRIPT="$DIR/../scripts/sync-three-role-plugin.mjs"
if [ -f "$SYNC_SCRIPT" ]; then
  SYNC_COUNT="$(node "$SYNC_SCRIPT" --list 2>/dev/null | grep -c 'three-role-instrumentation-gate-smoke-test.sh')"
  { [ "${SYNC_COUNT:-0}" -ge 1 ]; } \
    && ok "AC12: this smoke is enumerated by scripts/sync-three-role-plugin.mjs --list (runs in CI)" \
    || bad "AC12 smoke not found in the plugin-sync SSOT list (count=$SYNC_COUNT)"
else
  bad "AC12 cannot verify — scripts/sync-three-role-plugin.mjs not found"
fi

rm -rf "$GITROOT_P" "$EMAILGIT_A" "$EMAILGIT_B" "$EMAILGIT_EMPTY" "$MUT" "$MUTBROKEN" "$PERF_OUTSIDE" 2>/dev/null
fi  # end #1537 artifact-privacy-leg portability guard (scanner-present -> ran; absent -> skipped)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1532 — executor artifact-KIND leg, wired onto the MAIN ledger `check` call site (this file's
# line ~447, unconditional — not the Leg-A/privacy branch above), so a REAL tagged completion actually
# fires it (AC-6 live-fire proof, plan-review non-blocking note 2). Same scratch-git-repo pattern as the
# #1509-H block (isGitTracked needs a real repo; every non-KIND fixture above lives under bare $TMP).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
GITROOT_K="$(mktemp -d)"
( cd "$GITROOT_K" && git init -q && git config user.email t@t.co && git config user.name t )
mkdir -p "$GITROOT_K/.ai-workspace/plans" "$GITROOT_K/.ai-workspace/reviews"
printf '## ELI5\nplan\ncairn: "synth hit"\n### Binary AC\n- AC1\n' > "$GITROOT_K/.ai-workspace/plans/1532k-plan.md"
printf '## Review\ncairn: "synth reviewer hit"\nverdict: PASS\n' > "$GITROOT_K/.ai-workspace/reviews/1532k-rev.md"
( cd "$GITROOT_K" && git add -A && git commit -q -m "fixture: #1532 KIND-leg artifacts" )
cat > "$TMP/perf-1532.md" <<EOF
# 3-role performance log — #1532 KIND-leg smoke
## rounds for #1532kred #1532kgreen
EOF

TAGSID_K="sess-1532k"
mk_sub "$TAGSID_K" kp1; mk_sub "$TAGSID_K" kr1; mk_sub "$TAGSID_K" ke1; mk_sub "$TAGSID_K" kv1
appendL --session "$TAGSID_K" --task 1532kred --role planner          --agent kp1 --artifact "$GITROOT_K/.ai-workspace/plans/1532k-plan.md"
appendL --session "$TAGSID_K" --task 1532kred --role plan-review       --agent kr1 --artifact "$GITROOT_K/.ai-workspace/reviews/1532k-rev.md"
# the #1494 shape: executor re-cites the PLANNER's own plan file instead of a ship reference.
appendL --session "$TAGSID_K" --task 1532kred --role executor          --agent ke1 --artifact "$GITROOT_K/.ai-workspace/plans/1532k-plan.md"
appendL --session "$TAGSID_K" --task 1532kred --role execution-review  --agent kv1 --artifact "$GITROOT_K/.ai-workspace/reviews/1532k-rev.md"

# ---- K1 [proof] RED, real seam: a REAL tagged completion whose executor row is the #1494 shape ->
#      BLOCKed by the KIND leg at the MAIN ledger check call site (line ~447), routed to block_kind. ----
run '{"session_id":"'"$TAGSID_K"'","tool_input":{"taskId":"1532kred","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1532.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "executor artifact-KIND leg FAILED" && echo "$CAP" | grep -q "KIND:"; } \
  && ok "[proof] 1532-K1 RED: real tagged completion, #1494-shaped executor row -> KIND leg BLOCK (block_kind, real seam)" \
  || bad "1532-K1 RED failed (rc=$RC out=$CAP)"

# ---- K2 [proof] GREEN: an otherwise-identical tagged completion whose executor row cites a real PR URL ->
#      ALLOWED (the KIND leg never touches a ship reference). ----
mk_sub "$TAGSID_K" ke2
appendL --session "$TAGSID_K" --task 1532kgreen --role planner          --agent kp1 --artifact "$GITROOT_K/.ai-workspace/plans/1532k-plan.md"
appendL --session "$TAGSID_K" --task 1532kgreen --role plan-review       --agent kr1 --artifact "$GITROOT_K/.ai-workspace/reviews/1532k-rev.md"
appendL --session "$TAGSID_K" --task 1532kgreen --role executor          --agent ke2 --artifact "https://github.com/owner/repo/pull/1532"
appendL --session "$TAGSID_K" --task 1532kgreen --role execution-review  --agent kv1 --artifact "$GITROOT_K/.ai-workspace/reviews/1532k-rev.md"
run '{"session_id":"'"$TAGSID_K"'","tool_input":{"taskId":"1532kgreen","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1532.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}'
{ [ "$RC" = "0" ] && echo "$CAP" | grep -qi "OK"; } \
  && ok "[proof] 1532-K2 GREEN: real tagged completion, PR-URL executor row -> ALLOWED (KIND leg never touches a ship reference)" \
  || bad "1532-K2 GREEN failed (rc=$RC out=$CAP)"

# ---- K3 [control] the pre-existing MASTER kill-switch still disables the KIND leg too
#      (THREE_ROLE_INSTRUMENT_OFF=1 over the SAME RED fixture as K1). This leg carries no bypass flag of
#      its OWN by design (mirrors Leg A) — proves the one pre-existing escape still reaches it. ----
CAP=$(printf '%s' '{"session_id":"'"$TAGSID_K"'","tool_input":{"taskId":"1532kred","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1532.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
  | THREE_ROLE_INSTRUMENT_OFF=1 THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1 >/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "[control] 1532-K3: THREE_ROLE_INSTRUMENT_OFF=1 (whole-family master switch) over the SAME RED KIND fixture -> allow silent" \
  || bad "1532-K3 master kill-switch failed (rc=$RC out=$CAP)"

# ---- K4 [proof] AC-6 LIVE-FIRE through the INSTALLED symlink (readlink -f resolved), not just the in-tree
#      script — proves the fix is live, not inert in-tree only. ----
INSTALLED_GATE_K="$HOME/.claude/hooks/three-role-instrumentation-gate.sh"
if [ -L "$INSTALLED_GATE_K" ] || [ -f "$INSTALLED_GATE_K" ]; then
  RESOLVED_GATE_K="$(readlink -f "$INSTALLED_GATE_K" 2>/dev/null)"
  RESOLVED_SELF_K="$(readlink -f "$HOOK" 2>/dev/null)"
  if [ -n "$RESOLVED_GATE_K" ] && [ "$RESOLVED_GATE_K" = "$RESOLVED_SELF_K" ]; then
    CAP=$(printf '%s' '{"session_id":"'"$TAGSID_K"'","tool_input":{"taskId":"1532kred","status":"completed","metadata":{"model_run":"r","model_perf_log":"'"$TMP"'/perf-1532.md","outcome_eval":"achieved","outcome_evidence":"'"$OEV"'"}}}' \
      | THREE_ROLE_LEDGER_DIR="$LEDGERDIR" THREE_ROLE_PROJECTS_ROOT="$PROJROOT" CLAUDE_PROJECT_DIR="$PROJ" bash "$INSTALLED_GATE_K" 2>&1 >/dev/null); RC=$?
    { [ "$RC" = "2" ] && echo "$CAP" | grep -q "executor artifact-KIND leg FAILED"; } \
      && ok "[proof] 1532-K4 AC-6: LIVE-FIRE through the INSTALLED symlink ($INSTALLED_GATE_K -> $RESOLVED_GATE_K) -> KIND leg BLOCK" \
      || bad "1532-K4 AC-6 live-fire failed (rc=$RC out=$CAP)"
  else
    skip "1532-K4 AC-6 live-fire: installed hook does not resolve to this repo's copy (resolved=$RESOLVED_GATE_K, self=$RESOLVED_SELF_K) — not this machine's canonical checkout"
  fi
else
  skip "1532-K4 AC-6 live-fire: $INSTALLED_GATE_K not present on this machine (setup.sh not run here)"
fi

rm -rf "$GITROOT_K" 2>/dev/null

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
