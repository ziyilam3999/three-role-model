#!/usr/bin/env bash
# Smoke for hooks/3role-ledger.mjs (#851). append / check verdicts / idempotency. Exit 0 = all pass.
# No `set -e` (a non-block non-zero from a checked command must NOT abort the suite — fail-open hygiene).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export THREE_ROLE_LEDGER_DIR="$TMP/ledger"
export THREE_ROLE_PROJECTS_ROOT="$TMP/projects"
SID="sess-ledger"; TASK="700"
LEDFILE="$THREE_ROLE_LEDGER_DIR/$SID/$TASK.jsonl"

# Create a real (resolvable) subagent transcript fixture under the fixture projects root.
mk_sub() { mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"; printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1" > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"; }
nlines() { [ -f "$LEDFILE" ] && grep -c . "$LEDFILE" || echo 0; }

# artifact fixtures
printf '## ELI5\na plan\n### Binary AC\n- AC1\n' > "$TMP/plan.md"
printf '## Review\nverdict: PASS\n' > "$TMP/rev.md"

# 1. append writes exactly one line
node "$LED" append --session "$SID" --task "$TASK" --role planner --agent p1 --artifact "$TMP/plan.md" >/dev/null
[ "$(nlines)" = "1" ] && ok "append writes 1 line" || bad "append should write 1 line (got $(nlines))"

# 2. a second role adds a second line
node "$LED" append --session "$SID" --task "$TASK" --role plan-review --agent r1 --artifact "$TMP/rev.md" >/dev/null
[ "$(nlines)" = "2" ] && ok "second role -> 2 lines" || bad "should be 2 lines (got $(nlines))"

# 3. idempotent: re-appending the identical role does NOT duplicate (still 2 lines)
node "$LED" append --session "$SID" --task "$TASK" --role planner --agent p1 --artifact "$TMP/plan.md" >/dev/null
[ "$(nlines)" = "2" ] && ok "re-append same role -> still 2 lines (idempotent)" || bad "idempotency broken (got $(nlines))"

# 4. re-append same role, new agent -> UPDATE in place (still 2 lines, agent changed to p2)
node "$LED" append --session "$SID" --task "$TASK" --role planner --agent p2 --artifact "$TMP/plan.md" >/dev/null
n=$(nlines); a=$(grep -c '"agentId":"p2"' "$LEDFILE")
{ [ "$n" = "2" ] && [ "$a" = "1" ]; } && ok "re-append same role new agent -> update in place" || bad "update-in-place broken (n=$n a=$a)"

# make the referenced agents resolvable
mk_sub "$SID" p2; mk_sub "$SID" r1; mk_sub "$SID" e1; mk_sub "$SID" er1

# 5. check on an INCOMPLETE ledger (no executor / execution-review) -> BLOCK (rc 2)
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "missing executor"; } && ok "incomplete ledger -> BLOCK" || bad "incomplete should block (rc=$RC out=$OUT)"

# 6. complete the ledger -> ALLOW (rc 0)
node "$LED" append --session "$SID" --task "$TASK" --role executor --agent e1 --artifact "PR #1" >/dev/null
node "$LED" append --session "$SID" --task "$TASK" --role execution-review --agent er1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "complete ledger -> ALLOW" || bad "complete should allow (rc=$RC out=$OUT)"

# 7. FORGED agentId (executor points at a transcript that does not exist) -> BLOCK (Phase-2 forgery-close)
node "$LED" append --session "$SID" --task "$TASK" --role executor --agent ghost-no-file --artifact "PR #1" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "does not resolve"; } && ok "forged agentId -> BLOCK" || bad "forged should block (rc=$RC out=$OUT)"
# restore a resolvable executor for the remaining checks
node "$LED" append --session "$SID" --task "$TASK" --role executor --agent e1 --artifact "PR #1" >/dev/null

# 8. execution-review inline-skip is NEVER allowed -> BLOCK
node "$LED" append --session "$SID" --task "$TASK" --role execution-review --skip-reason "no reviewer available right now" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "never"; } && ok "execution-review skip -> BLOCK" || bad "exec-review skip should block (rc=$RC out=$OUT)"

# 9. execution-review satisfied by an oracle that exists + has a PASS token -> ALLOW
printf 'tests: 12 passed, 0 failed — PASS\n' > "$TMP/oracle.txt"
node "$LED" append --session "$SID" --task "$TASK" --role execution-review --oracle "$TMP/oracle.txt" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "execution-review oracle(exists+PASS) -> ALLOW" || bad "oracle should allow (rc=$RC out=$OUT)"

# 10. planner inline-skip with a SPECIFIC reason -> ALLOW; empty reason -> BLOCK
node "$LED" append --session "$SID" --task "$TASK" --role planner --skip-reason "plan was tightly coupled to live mid-edit session state, not briefable" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "planner specific inline-skip -> ALLOW" || bad "planner skip should allow (rc=$RC out=$OUT)"
node "$LED" append --session "$SID" --task "$TASK" --role planner --skip-reason "" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "empty"; } && ok "planner empty skip reason -> BLOCK" || bad "empty skip should block (rc=$RC out=$OUT)"

# 11. check with no ledger file at all -> BLOCK
OUT=$(node "$LED" check --session "no-such-session" --task "999" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "no role-ledger"; } && ok "no ledger file -> BLOCK" || bad "no ledger should block (rc=$RC out=$OUT)"

# ---------------------------------------------------------------------------
# #855 — OVERLAY-MERGE (agent-at-spawn composes with artifact-at-close) + broadened PLAN_RE.
# ---------------------------------------------------------------------------
# resolvable agents used by the merge / PLAN_RE cases below
mk_sub "$SID" mp1; mk_sub "$SID" mr1; mk_sub "$SID" me1; mk_sub "$SID" mer1; mk_sub "$SID" pa_p
mfile() { echo "$THREE_ROLE_LEDGER_DIR/$SID/$1.jsonl"; }
# count ledger lines that contain BOTH substrings on the SAME line
both_on_line() { grep -E "$2" "$1" | grep -cE "$3"; }

# 12. MERGE-COMPOSE prove-primary (AC4): agent-ONLY at spawn, then artifact-ONLY at close ->
#     ONE planner line carrying BOTH agentId AND artifact_path; the agentId is NOT dropped; check resolves.
MT="855m"; MF="$(mfile "$MT")"
node "$LED" append --session "$SID" --task "$MT" --role planner --agent mp1 >/dev/null                  # spawn: agentId only
node "$LED" append --session "$SID" --task "$MT" --role planner --artifact "$TMP/plan.md" >/dev/null     # close: artifact only
pl=$(grep -c '"role":"planner"' "$MF"); both=$(both_on_line "$MF" '"agentId":"mp1"' '"artifact_path":')
{ [ "$pl" = "1" ] && [ "$both" = "1" ]; } && ok "merge: agent-then-artifact -> ONE line with BOTH fields (agentId not dropped)" || bad "merge-compose broken (planner-lines=$pl both=$both)"
# complete the other three roles and prove `check` RESOLVES (the composed planner line is accepted)
node "$LED" append --session "$SID" --task "$MT" --role plan-review --agent mr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$MT" --role executor --agent me1 --artifact "PR #2" >/dev/null
node "$LED" append --session "$SID" --task "$MT" --role execution-review --agent mer1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$MT" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "merge: composed ledger -> check RESOLVES (ALLOW)" || bad "composed ledger should resolve (rc=$RC out=$OUT)"

# 13. ORDER-INDEPENDENCE: artifact FIRST then agent -> still ONE line with BOTH fields.
MT2="855n"; MF2="$(mfile "$MT2")"
node "$LED" append --session "$SID" --task "$MT2" --role planner --artifact "$TMP/plan.md" >/dev/null    # artifact first
node "$LED" append --session "$SID" --task "$MT2" --role planner --agent mp1 >/dev/null                  # agent second
both2=$(both_on_line "$MF2" '"agentId":"mp1"' '"artifact_path":')
{ [ "$both2" = "1" ]; } && ok "merge: artifact-then-agent -> BOTH fields (order-independent)" || bad "order-independence broken (both=$both2)"

# 14. MUTUAL-EXCLUSION: --agent after a --skip-reason CLEARS the stale skip (skip can't mask a real spawn);
#     resulting verdict RESOLVES the role (not blocked by a leftover skip).
MT3="855x"; MF3="$(mfile "$MT3")"
node "$LED" append --session "$SID" --task "$MT3" --role planner --skip-reason "tightly coupled to live mid-edit session state" >/dev/null
node "$LED" append --session "$SID" --task "$MT3" --role planner --agent mp1 --artifact "$TMP/plan.md" >/dev/null
hasskip=$(grep -c '"skip_reason"' "$MF3"); hasagent=$(grep -c '"agentId":"mp1"' "$MF3")
node "$LED" append --session "$SID" --task "$MT3" --role plan-review --agent mr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$MT3" --role executor --agent me1 --artifact "PR #3" >/dev/null
node "$LED" append --session "$SID" --task "$MT3" --role execution-review --agent mer1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$MT3" 2>&1); RC=$?
{ [ "$hasskip" = "0" ] && [ "$hasagent" = "1" ] && [ "$RC" = "0" ]; } && ok "mutual-exclusion: --agent after a skip clears the stale skip -> RESOLVES" || bad "agent-after-skip should clear skip + resolve (skip=$hasskip agent=$hasagent rc=$RC out=$OUT)"

# 15. MUTUAL-EXCLUSION reverse: --skip-reason after an --agent CLEARS inherited agentId/artifact_path.
MT4="855y"; MF4="$(mfile "$MT4")"
node "$LED" append --session "$SID" --task "$MT4" --role planner --agent mp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$SID" --task "$MT4" --role planner --skip-reason "became inseparable from live session state" >/dev/null
gone=$(grep -cE '"agentId"|"artifact_path"' "$MF4"); keptskip=$(grep -c '"skip_reason"' "$MF4")
{ [ "$gone" = "0" ] && [ "$keptskip" = "1" ]; } && ok "mutual-exclusion: --skip after an agent clears inherited agentId/artifact" || bad "skip-after-agent should clear agent fields (agentFields=$gone skip=$keptskip)"

# 16. PLAN_RE broadened-accept (AC1): planner artifact whose ONLY heading is `## Binary acceptance criteria`
#     (no `## ELI5`) -> planner check ALLOWs.
printf '## Binary acceptance criteria\n- AC1\n- AC2\n' > "$TMP/plan-natural.md"
PT="855pa"
node "$LED" append --session "$SID" --task "$PT" --role planner --agent pa_p --artifact "$TMP/plan-natural.md" >/dev/null
node "$LED" append --session "$SID" --task "$PT" --role plan-review --agent r1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$PT" --role executor --agent e1 --artifact "PR #4" >/dev/null
node "$LED" append --session "$SID" --task "$PT" --role execution-review --agent er1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$PT" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "PLAN_RE: '## Binary acceptance criteria'-only plan -> ALLOW" || bad "natural AC heading should allow (rc=$RC out=$OUT)"

# 17. PLAN_RE not-too-loose (AC2): planner artifact with "acceptance" only in PROSE (no heading) -> BLOCK.
printf 'This plan still needs acceptance from QA before we proceed.\nNo headings here.\n' > "$TMP/prose-acceptance.md"
PT2="855pp"
node "$LED" append --session "$SID" --task "$PT2" --role planner --agent pa_p --artifact "$TMP/prose-acceptance.md" >/dev/null
node "$LED" append --session "$SID" --task "$PT2" --role plan-review --agent r1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$PT2" --role executor --agent e1 --artifact "PR #5" >/dev/null
node "$LED" append --session "$SID" --task "$PT2" --role execution-review --agent er1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$PT2" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "lacks a plan marker"; } && ok "PLAN_RE: prose-only 'acceptance' (no heading) -> BLOCK" || bad "prose acceptance should block (rc=$RC out=$OUT)"

# 18. Template alignment (AC3): the EXACT PLAN_RE from the module matches the literal AC heading in
#     plan-template.md (isolated from `## ELI5` so the AC arm itself is proven).
# PORT-NOTE: the plan-template lives in the issue-to-ship skill, ported in a LATER leg. Degrade-gracefully —
# SKIP this sub-case when the template is not present yet; it becomes a live check once the skill lands.
TPL="$ROOT/skills/issue-to-ship/references/plan-template.md"
if [ ! -f "$TPL" ]; then
  echo "SKIP: PLAN_RE-vs-plan-template alignment (template not bundled in this leg: $TPL)"
else
node -e '
  const fs=require("fs");
  const src=fs.readFileSync(process.argv[1],"utf8");
  const m=src.match(/const PLAN_RE\s*=\s*(\/.*\/[a-z]*);/);
  if(!m){console.error("could not extract PLAN_RE from module");process.exit(2);}
  const PLAN_RE=eval(m[1]);
  const tpl=fs.readFileSync(process.argv[2],"utf8");
  const acLine=tpl.split("\n").find(l=>/^#{2,4}[ \t]*Binary AC\b/i.test(l));
  if(!acLine){console.error("no `## Binary AC` heading in plan-template.md");process.exit(2);}
  process.exit(PLAN_RE.test(acLine)?0:1);
' "$LED" "$TPL"; RC=$?
{ [ "$RC" = "0" ]; } && ok "PLAN_RE matches the literal AC heading in plan-template.md (AC3)" || bad "template AC heading not matched by module PLAN_RE (rc=$RC)"
fi

# ---------------------------------------------------------------------------
# #860 — resolve-agent: newest-mtime tagged transcript wins; no-match -> empty + nonzero.
# ---------------------------------------------------------------------------
# Build a tagged subagent transcript carrying the literal spawn tag `3ROLE_TASK:<task> ROLE:<role>`.
mk_tagged() { # <session> <agentId> <task> <role>
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  printf '{"isSidechain":true,"agentId":"%s"}\n3ROLE_TASK:%s ROLE:%s\n' "$2" "$3" "$4" \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}

RSID="sess-resolve"; RTASK="TT"; RROLE="plan-review"
# 19. newest-mtime wins (AC1): write OLDER agentId first, then (sleep 1) a NEWER one with the SAME tag ->
#     resolve-agent returns the NEWER agentId on stdout, exit 0.
mk_tagged "$RSID" "ra-old" "$RTASK" "$RROLE"
sleep 1
mk_tagged "$RSID" "ra-new" "$RTASK" "$RROLE"
OUT=$(node "$LED" resolve-agent --session "$RSID" --task "$RTASK" --role "$RROLE" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "ra-new" ]; } && ok "resolve-agent: two tagged transcripts -> NEWER agentId wins (rc 0)" || bad "resolve-agent newest-mtime broken (rc=$RC out=$OUT, want ra-new)"

# 20. no-match (AC2): a role with ZERO matching tagged transcripts -> empty stdout + nonzero exit.
OUT=$(node "$LED" resolve-agent --session "$RSID" --task "$RTASK" --role "execution-review" 2>/dev/null); RC=$?
{ [ "$RC" != "0" ] && [ -z "$OUT" ]; } && ok "resolve-agent: no matching tag -> empty + nonzero" || bad "resolve-agent no-match should be empty+nonzero (rc=$RC out=$OUT)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
