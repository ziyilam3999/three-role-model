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

# 4. re-append same role, DIFFERENT agent -> #1580 Fix B ROUND BOUNDARY (deliberate contract change, not a
#    regression — this exact "new agentId silently overwrites in place" was Bug B: a genuinely NEW spawn
#    destroyed round-1's evidence). A distinct incoming agentId over a prior row that already had one now
#    opens a NEW ROUND: round-1 (p1) is retained as HISTORY (its own line), and a fresh round-2 line for p2
#    is appended — 3 total lines (plan-review + planner-round-1 + planner-round-2), NOT 2.
node "$LED" append --session "$SID" --task "$TASK" --role planner --agent p2 --artifact "$TMP/plan.md" >/dev/null
n=$(nlines); pcount=$(grep -c '"role":"planner"' "$LEDFILE"); a=$(grep -c '"agentId":"p2"' "$LEDFILE"); a1=$(grep -c '"agentId":"p1"' "$LEDFILE")
{ [ "$n" = "3" ] && [ "$pcount" = "2" ] && [ "$a" = "1" ] && [ "$a1" = "1" ]; } \
  && ok "#1580 Fix B: re-append same role with a DISTINCT agent -> NEW ROUND (round-1 retained as history, round-2 appended, not overwritten in place)" \
  || bad "round-boundary broken (n=$n planner-lines=$pcount p2=$a p1-retained=$a1)"

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
#    #1580 NOTE: task $TASK's execution-review row is now a COMPLETED run (agentId+artifact_path, from test
#    6) — under #1580 Fix A that is terminal evidence, so a bare skip over it is REJECTED by the
#    terminal-evidence guard BEFORE checkRole's own "execution-review is never skippable" rule ever runs
#    (a stronger, earlier-firing protection, but it means this scenario no longer isolates checkRole's own
#    rule). Use a FRESH task with NO prior execution-review row (skip lands; Fix A only guards a REAL prior)
#    so checkRole's independent "never inline-skippable" rule is what actually fires and is proven here.
EN_TASK="700-execnever"
node "$LED" append --session "$SID" --task "$EN_TASK" --role planner --agent p2 --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$SID" --task "$EN_TASK" --role plan-review --agent r1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$EN_TASK" --role executor --agent e1 --artifact "PR #1" >/dev/null
node "$LED" append --session "$SID" --task "$EN_TASK" --role execution-review --skip-reason "no reviewer available right now" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$EN_TASK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "never"; } && ok "execution-review skip -> BLOCK" || bad "exec-review skip should block (rc=$RC out=$OUT)"

# 9. execution-review satisfied by an oracle that exists + has a PASS token -> ALLOW
printf 'tests: 12 passed, 0 failed — PASS\n' > "$TMP/oracle.txt"
node "$LED" append --session "$SID" --task "$TASK" --role execution-review --oracle "$TMP/oracle.txt" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$TASK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "execution-review oracle(exists+PASS) -> ALLOW" || bad "oracle should allow (rc=$RC out=$OUT)"

# 10. planner inline-skip with a SPECIFIC reason -> ALLOW; empty reason -> BLOCK
#     #1580 NOTE: task $TASK's planner row is now a COMPLETED run (agentId+artifact_path, from test 4's
#     round-2) — terminal under Fix A, so a bare skip over it is REJECTED before checkRole's specific/empty
#     reason distinction ever runs. Use a FRESH task with NO prior planner row (skip lands; the row stays
#     non-terminal — skip_reason alone carries no terminal field — so the SECOND skip in this same test can
#     still land too) so checkRole's own reason-validation logic is what is actually proven here.
PS_TASK="700-plannerskip"
node "$LED" append --session "$SID" --task "$PS_TASK" --role planner --skip-reason "plan was tightly coupled to live mid-edit session state, not briefable" >/dev/null
node "$LED" append --session "$SID" --task "$PS_TASK" --role plan-review --agent r1 --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$PS_TASK" --role executor --agent e1 --artifact "PR #1" >/dev/null
node "$LED" append --session "$SID" --task "$PS_TASK" --role execution-review --agent er1 --artifact "$TMP/rev.md" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$PS_TASK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "planner specific inline-skip -> ALLOW" || bad "planner skip should allow (rc=$RC out=$OUT)"
node "$LED" append --session "$SID" --task "$PS_TASK" --role planner --skip-reason "" >/dev/null
OUT=$(node "$LED" check --session "$SID" --task "$PS_TASK" 2>&1); RC=$?
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

# 15. MUTUAL-EXCLUSION reverse, HARDENED under #1580 Fix A (deliberate contract change, not a regression —
#     mirrors the #1036/AC-22-note-4 precedent below in this same file). Pre-#1580 a bare --skip-reason
#     after a real agent+artifact_path silently CLEARED the completed run — that is precisely the Bug-A
#     downgrade class (a weaker assertion erasing stronger evidence), just for a non-executor, non-verdict
#     role. #1580's terminal-evidence guard now REFUSES this (nonzero exit, agentId/artifact_path PRESERVED)
#     for every role uniformly, exactly like it already does for a completed verdict/executor row.
MT4="855y"; MF4="$(mfile "$MT4")"
node "$LED" append --session "$SID" --task "$MT4" --role planner --agent mp1 --artifact "$TMP/plan.md" >/dev/null
SKIP15_OUT=$(node "$LED" append --session "$SID" --task "$MT4" --role planner --skip-reason "became inseparable from live session state" 2>&1); SKIP15_RC=$?
survives=$(grep -cE '"agentId":"mp1"' "$MF4"); noskip=$(grep -c '"skip_reason"' "$MF4")
{ [ "$SKIP15_RC" != "0" ] && [ "$survives" = "1" ] && [ "$noskip" = "0" ]; } \
  && ok "#1580 Fix A: --skip-reason after a completed (agent+artifact) planner run is REFUSED, agentId/artifact_path PRESERVED" \
  || bad "skip-after-completed-run should be refused with fields preserved (rc=$SKIP15_RC survives=$survives noskip=$noskip out=$SKIP15_OUT)"

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
# #1575 Lane 1c / AC-22 note (3) — FIXTURE STRENGTHENED to the realistic SPAWN-RECORD shape: the tag now
# sits in the FIRST record (the spawn prompt), not a bare trailing raw-text line after a tagless metadata
# line. resolveAgent()'s predicate is re-scoped to test ONLY the first record (firstRecordText()) -- a
# fixture whose tag sits outside the first record no longer binds (that IS the D1 fix); this fixture is
# updated to the real shape rather than widening the predicate back to whole-file.
# ---------------------------------------------------------------------------
mk_tagged() { # <session> <agentId> <task> <role>
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4" \
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

# ---------------------------------------------------------------------------
# #897 — append warns (stderr) when --artifact is inside a build worktree (transient -> dangles after
#        quarantine), but stays SILENT for a stable path. Both-ends: warn on worktree path, NOT on a primary path.
# ---------------------------------------------------------------------------
# NOTE: use a non-$HOME absolute base (/tmp/...) so #1199 home-tilde normalization leaves it ABSOLUTE
# (the WARN regex needs the literal `/.claude/worktrees/` segment) AND so this file carries no `/Users/`.
WSID="sess-wtwarn"; WTASK="897w"
ERR=$(node "$LED" append --session "$WSID" --task "$WTASK" --role execution-review \
  --agent ew1 --artifact "/tmp/x/repo/.claude/worktrees/897-foo/.ai-workspace/reviews/r.md" 2>&1 >/dev/null)
echo "$ERR" | grep -q 'WARN (3role-ledger #897)' && ok "#897 worktree artifact path -> WARN on stderr" || bad "#897 should WARN on a .claude/worktrees/ artifact path (got: $ERR)"

ERR=$(node "$LED" append --session "$WSID" --task "$WTASK" --role execution-review \
  --agent ew1 --artifact "/tmp/x/repo/.ai-workspace/reviews/r.md" 2>&1 >/dev/null)
echo "$ERR" | grep -q 'WARN (3role-ledger #897)' && bad "#897 should NOT warn on a stable primary path (got: $ERR)" || ok "#897 stable primary artifact path -> no warn"

# ---------------------------------------------------------------------------
# #1036 — append --verdict persists a review verdict; skip_reason clears it; absent -> no field (back-compat).
# ---------------------------------------------------------------------------
VSID="sess-verdict"; VTASK="1036v"; VFILE="$THREE_ROLE_LEDGER_DIR/$VSID/$VTASK.jsonl"
node "$LED" append --session "$VSID" --task "$VTASK" --role execution-review --agent ev1 --artifact "$TMP/rev.md" --verdict "APPROVE-WITH-NOTES" >/dev/null
grep -q '"verdict":"APPROVE-WITH-NOTES"' "$VFILE" && ok "#1036 append --verdict persists the verdict" || bad "#1036 --verdict not persisted (got: $(tail -1 "$VFILE"))"
# #1575 AC-22 note (4) — HARDENED-CONTRACT FIXTURE UPDATE (deliberate, not a regression): this case used to
# assert the pre-fix clear-list mechanic (skip erases a completed verdict, exit 0). The 1a clause-1
# terminal-evidence guard now REVERSES that on EVERY required role, execution-review included (AC-4j proves
# the uniformity) -- the skip append onto this completed verdict now exits NONZERO and the verdict is
# PRESERVED (mirrors AC-4b's sub-checks (i)/(ii): assert BOTH the nonzero exit AND the retained verdict).
SKIP1036_OUT=$(node "$LED" append --session "$VSID" --task "$VTASK" --role execution-review --skip-reason "n/a" 2>&1); SKIP1036_RC=$?
{ [ "$SKIP1036_RC" != "0" ] && grep -q '"verdict"' "$VFILE"; } \
  && ok "#1036 skip append onto a completed execution-review verdict is REFUSED (nonzero exit, verdict PRESERVED -- AC-22 note 4)" \
  || bad "#1036 skip should be refused with the verdict preserved (rc=$SKIP1036_RC got: $(tail -1 "$VFILE") err=$SKIP1036_OUT)"
node "$LED" append --session "$VSID" --task "${VTASK}bc" --role planner --agent p9 --artifact "$TMP/plan.md" >/dev/null
grep -q '"verdict"' "$THREE_ROLE_LEDGER_DIR/$VSID/${VTASK}bc.jsonl" && bad "#1036 no --verdict should mean no verdict field" || ok "#1036 absent --verdict -> no verdict field (back-compat)"

# ---------------------------------------------------------------------------
# #1199 Part B — append normalizes a PATH-SHAPED artifact to a CWD-INDEPENDENT (+ home-tilde) form;
# a NON-path value (branch / URL / PR #N) is stored VERBATIM. resolveArtifact is UNCHANGED (back-compat).
# ---------------------------------------------------------------------------
NSID="sess-1199"

# 21. (R5) CROSS-CWD RED->GREEN: append a RELATIVE artifact from cwd X (where the file lives), then check
#     from cwd Y (where it does NOT). The file is isolated to X and CLAUDE_PROJECT_DIR is unset, so on the
#     OLD verbatim-store code the stored value is relative and `check` from Y can NOT resolve it (BLOCK) —
#     the RED. The fix stores an ABSOLUTE path at write time, so check from Y resolves it (GREEN).
CWDX="$(mktemp -d)"; CWDY="$(mktemp -d)"
mkdir -p "$CWDX/.ai-workspace/reviews"
printf '## Review\nverdict: PASS\n' > "$CWDX/.ai-workspace/reviews/rev.md"
mk_sub "$SID" xpl; mk_sub "$SID" xpr; mk_sub "$SID" xex; mk_sub "$SID" xer
# planner artifact authored + appended FROM cwd X (relative, explicit `.ai-workspace/` prefix)
printf '## ELI5\np\n### Binary AC\n- a\n' > "$CWDX/.ai-workspace/reviews/plan.md"
( cd "$CWDX" && env -u CLAUDE_PROJECT_DIR node "$LED" append --session "$SID" --task 1199x --role planner \
    --agent xpl --artifact ".ai-workspace/reviews/plan.md" >/dev/null )
NF="$THREE_ROLE_LEDGER_DIR/$SID/1199x.jsonl"
grep -q '"artifact_path":"/' "$NF" && ok "#1199 cross-cwd: relative artifact stored ABSOLUTE at write time" || bad "#1199 stored value should be absolute (got: $(grep planner "$NF"))"
# fill the other roles (all relative-from-X), then check from cwd Y
( cd "$CWDX" && env -u CLAUDE_PROJECT_DIR node "$LED" append --session "$SID" --task 1199x --role plan-review --agent xpr --artifact ".ai-workspace/reviews/rev.md" >/dev/null )
( cd "$CWDX" && env -u CLAUDE_PROJECT_DIR node "$LED" append --session "$SID" --task 1199x --role executor --agent xex --artifact "PR #99" >/dev/null )
( cd "$CWDX" && env -u CLAUDE_PROJECT_DIR node "$LED" append --session "$SID" --task 1199x --role execution-review --agent xer --artifact ".ai-workspace/reviews/rev.md" >/dev/null )
OUT=$( cd "$CWDY" && env -u CLAUDE_PROJECT_DIR node "$LED" check --session "$SID" --task 1199x 2>&1 ); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "#1199 cross-cwd: check from a DIFFERENT cwd resolves the stored absolute path (GREEN)" || bad "#1199 cross-cwd check from Y should resolve (rc=$RC out=$OUT)"

# 22. (back-compat) a PRE-FIX RELATIVE ledger entry (hand-written) still resolves from its origin cwd via
#     the UNCHANGED resolveArtifact fallback chain. Prove resolveArtifact was NOT touched.
mkdir -p "$THREE_ROLE_LEDGER_DIR/$SID"
BF="$THREE_ROLE_LEDGER_DIR/$SID/1199bc.jsonl"
printf '## ELI5\np\n### Binary AC\n- a\n' > "$CWDX/.ai-workspace/reviews/plan2.md"
mk_sub "$SID" bcp; mk_sub "$SID" bcr; mk_sub "$SID" bce; mk_sub "$SID" bcer
BF="$BF" node -e '
  const fs=require("fs");
  const L=[
    {role:"planner",agentId:"bcp",artifact_path:".ai-workspace/reviews/plan2.md"},
    {role:"plan-review",agentId:"bcr",artifact_path:".ai-workspace/reviews/rev.md"},
    {role:"executor",agentId:"bce",artifact_path:"PR #100"},
    {role:"execution-review",agentId:"bcer",artifact_path:".ai-workspace/reviews/rev.md"},
  ].map(o=>JSON.stringify(o)).join("\n")+"\n";
  fs.writeFileSync(process.env.BF, L);
'
OUT=$( cd "$CWDX" && env -u CLAUDE_PROJECT_DIR node "$LED" check --session "$SID" --task 1199bc 2>&1 ); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "#1199 back-compat: pre-fix RELATIVE entry still resolves from origin cwd" || bad "#1199 back-compat relative entry should resolve (rc=$RC out=$OUT)"

# 23. (R3/R4) SLASHED executor controls: a branch and a PR URL both contain '/' but are NOT files -> stored
#     VERBATIM, never mangled into an absolute/tilde path.
node "$LED" append --session "$NSID" --task brn --role executor --agent z1 --artifact "feat/1199-ledger-path-guard" >/dev/null
BRNF="$THREE_ROLE_LEDGER_DIR/$NSID/brn.jsonl"
grep -q '"artifact_path":"feat/1199-ledger-path-guard"' "$BRNF" && ok "#1199 slashed branch artifact -> stored VERBATIM (not mangled)" || bad "#1199 branch should be verbatim (got: $(cat "$BRNF"))"
node "$LED" append --session "$NSID" --task url --role executor --agent z2 --artifact "https://github.com/o/r/pull/123" >/dev/null
URLF="$THREE_ROLE_LEDGER_DIR/$NSID/url.jsonl"
grep -q '"artifact_path":"https://github.com/o/r/pull/123"' "$URLF" && ok "#1199 PR URL artifact -> stored VERBATIM (URL scheme not mangled)" || bad "#1199 URL should be verbatim (got: $(cat "$URLF"))"

# 24. (R3) a real relative SOURCE artifact (executor's src/x.ts that EXISTS on disk) DOES normalize to an
#     absolute path (so the completion gate finds it cross-cwd).
SRCX="$(mktemp -d)"; mkdir -p "$SRCX/src/llm"; printf 'export const x=1;\n' > "$SRCX/src/llm/generate.ts"
( cd "$SRCX" && node "$LED" append --session "$NSID" --task src --role executor --agent z3 --artifact "src/llm/generate.ts" >/dev/null )
SRCF="$THREE_ROLE_LEDGER_DIR/$NSID/src.jsonl"
grep -q '"artifact_path":"/' "$SRCF" && ok "#1199 real relative SOURCE artifact (exists on disk) -> normalized ABSOLUTE" || bad "#1199 existing src path should normalize absolute (got: $(cat "$SRCF"))"

# 25. (R6) a path UNDER \$HOME is stored as a HOME-RELATIVE TILDE path (~/...): no username, no /Users/, and
#     resolveArtifact's ~/ arm resolves it from any cwd.
HOMEDIR="$(node -e 'process.stdout.write(require("os").homedir())')"
HTMP="$(mktemp -d "$HOMEDIR/.3role-smoke-XXXXXX")"
mkdir -p "$HTMP/.ai-workspace/reviews"; printf '## Review\nverdict: PASS\n' > "$HTMP/.ai-workspace/reviews/h.md"
HABS="$HTMP/.ai-workspace/reviews/h.md"
mk_sub "$NSID" z4
node "$LED" append --session "$NSID" --task home --role execution-review --agent z4 --artifact "$HABS" >/dev/null
HOMEF="$THREE_ROLE_LEDGER_DIR/$NSID/home.jsonl"
{ grep -q '"artifact_path":"~/' "$HOMEF" && ! grep -q "$HOMEDIR" "$HOMEF"; } && ok "#1199 R6: \$HOME path stored as ~/... tilde form (no username/home leak)" || bad "#1199 R6 home path should store as ~/ (got: $(cat "$HOMEF"))"
# prove resolveArtifact expands the stored ~/ form (check from an unrelated cwd resolves it)
mk_sub "$NSID" hp; mk_sub "$NSID" hr; mk_sub "$NSID" he
printf '## ELI5\np\n### Binary AC\n- a\n' > "$HTMP/.ai-workspace/reviews/plan.md"
node "$LED" append --session "$NSID" --task home --role planner --agent hp --artifact "$HTMP/.ai-workspace/reviews/plan.md" >/dev/null
node "$LED" append --session "$NSID" --task home --role plan-review --agent hr --artifact "$HTMP/.ai-workspace/reviews/h.md" >/dev/null
node "$LED" append --session "$NSID" --task home --role executor --agent he --artifact "PR #5" >/dev/null
OUT=$( cd "$TMP" && node "$LED" check --session "$NSID" --task home 2>&1 ); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "#1199 R6: stored ~/ form resolves via resolveArtifact from an unrelated cwd" || bad "#1199 R6 tilde form should resolve (rc=$RC out=$OUT)"
rm -rf "$CWDX" "$CWDY" "$SRCX" "$HTMP" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1448 — per-role MODEL POLICY: resolve-role-model + check --enforce-role-models (both-ends, fail-safe).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# A transcript fixture carrying an assistant `message.model` line (the forgery-resistant signal the enforce
# leg reads). The plain mk_sub above writes only a type:"user" line (no model) -> those roles fail-OPEN on
# the model leg, so ONLY the executor (given a model here) can mismatch — isolating the both-ends arms.
mk_sub_model() {
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  { printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[]}}\n' "$2" "$3"; } \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}
# config fixtures (CC_ROLES_ENV points the resolver at these; SET+unresolvable => "no config" fail-safe).
MCFG="$TMP/mcfg.env";    printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_ROLE_EXECUTOR_EFFORT=medium\n' > "$MCFG"
MFAB="$TMP/mfab.env";    printf 'CC_ROLE_EXECUTOR_MODEL=fable\n' > "$MFAB"
MTYPO="$TMP/mtypo.env";  printf 'CC_ROLE_EXECUTOR_MODEL=sonet\n' > "$MTYPO"
MFABO="$TMP/mfabo.env";  printf 'CC_ROLE_ORCHESTRATOR_MODEL=fable\n' > "$MFABO"
# build a complete 4-role ledger with the executor transcript carrying model $3: model_ledger <session> <task> <exec-model-id>
model_ledger() {
  mk_sub "$1" mP; mk_sub "$1" mR; mk_sub_model "$1" mE "$3"; mk_sub "$1" mV
  node "$LED" append --session "$1" --task "$2" --role planner         --agent mP --artifact "$TMP/plan.md" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role plan-review      --agent mR --artifact "$TMP/rev.md" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role executor         --agent mE --artifact "PR #9" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role execution-review --agent mV --artifact "$TMP/rev.md" >/dev/null
}

# M1. GREEN (#1624, reverses the prior RED): executor transcript=opus, config=sonnet, NO resume boundary -> a
#     STRICT quality up-tier at CLOSE time is now allowed-with-note (operator decision 2026-07-17: model-cost
#     is enforced at booking/spawn time, not at close — by close the spend is already sunk). Asserts the NEW,
#     DISTINCT CLOSE-UPTIER token and that it does NOT reuse the resume branch's RESUME-UPTIER wording (F1 —
#     that would be a false "was resumed" statement for a role that was never resumed).
model_ledger msRED 9101 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msRED --task 9101 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && echo "$OUT" | grep -qE "NOTE:.*CLOSE-UPTIER" && echo "$OUT" | grep -qi "executor" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "M1 GREEN (#1624): non-resume up-tier (executor=opus vs config=sonnet) -> exit 0 CLOSE-UPTIER note, never RESUME-UPTIER (F1)" || bad "M1 non-resume up-tier should allow-with-note (rc=$RC out=$OUT)"

# M2. GREEN: executor transcript=sonnet, config=sonnet -> exit 0.
model_ledger msGREEN 9102 "claude-sonnet-4-6"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msGREEN --task 9102 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "M2 GREEN: executor=sonnet matches config -> exit 0" || bad "M2 matching model should allow (rc=$RC out=$OUT)"

# M3. NO-CONFIG: executor transcript=opus, CC_ROLES_ENV=/nonexistent -> enforcement SKIPPED -> exit 0 (no false-block).
model_ledger msNOCFG 9103 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV=/nonexistent node "$LED" check --session msNOCFG --task 9103 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "M3 no-config -> model enforcement skipped -> exit 0 (no false-block)" || bad "M3 no-config should allow (rc=$RC out=$OUT)"

# M4. FABLE->OPUS reroute: executor transcript=opus, config=fable -> OK-with-note -> exit 0.
model_ledger msFAB 9104 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MFAB" node "$LED" check --session msFAB --task 9104 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "M4 fable->opus silent reroute (expected fable, actual opus) -> exit 0 OK-with-note" || bad "M4 fable-reroute should allow (rc=$RC out=$OUT)"

# M5. KILL-SWITCH: RED fixture but CC_ROLE_MODEL_GATE_OFF=1 -> exit 0 (feature switch skips the leg).
model_ledger msKS 9105 "claude-opus-4-8"
OUT=$(CC_ROLE_MODEL_GATE_OFF=1 CC_ROLES_ENV="$MCFG" node "$LED" check --session msKS --task 9105 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "M5 CC_ROLE_MODEL_GATE_OFF=1 over RED fixture -> exit 0 (kill-switch)" || bad "M5 kill-switch should allow (rc=$RC out=$OUT)"

# M6. OPT-IN: RED fixture WITHOUT --enforce-role-models -> exit 0 (the flag is opt-in; plain check unaffected).
model_ledger msNOFLAG 9106 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msNOFLAG --task 9106 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "M6 no --enforce-role-models flag -> plain check ALLOWS (model leg is opt-in)" || bad "M6 plain check should allow (rc=$RC out=$OUT)"

# M7. INVALID-VALUE lint both-ends (defect-3).
OUT=$(CC_ROLES_ENV="$MTYPO" node "$LED" resolve-role-model --role executor 2>"$TMP/mlint.err")
{ [ "$OUT" = "opus" ] && [ "$(grep -Ec 'INVALID-MODEL' "$TMP/mlint.err")" -ge 1 ]; } \
  && ok "M7 RED: typo 'sonet' -> resolve prints opus + INVALID-MODEL on stderr" || bad "M7 typo should print opus + INVALID-MODEL (out=$OUT err=$(cat "$TMP/mlint.err"))"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" resolve-role-model --role executor 2>"$TMP/mlint2.err")
{ [ "$OUT" = "sonnet" ] && [ "$(grep -Ec 'INVALID-MODEL' "$TMP/mlint2.err")" -eq 0 ]; } \
  && ok "M7 GREEN: 'sonnet' -> resolve prints sonnet + NO INVALID-MODEL" || bad "M7 valid should print sonnet + no INVALID-MODEL (out=$OUT err=$(cat "$TMP/mlint2.err"))"

# M8. resolve-role-model fail-safe: missing config -> opus.
OUT=$(CC_ROLES_ENV=/nonexistent node "$LED" resolve-role-model --role executor)
[ "$OUT" = "opus" ] && ok "M8 resolve-role-model missing config -> opus (fail-safe)" || bad "M8 missing config should be opus (out=$OUT)"

# M9. Fable config lint: orchestrator=fable -> FABLE-ON-ORCHESTRATOR + FABLE-COST-CLIFF on stderr.
CC_ROLES_ENV="$MFABO" node "$LED" resolve-role-model --role orchestrator 2>"$TMP/mfab.err" >/dev/null
{ [ "$(grep -Ec 'FABLE-ON-ORCHESTRATOR' "$TMP/mfab.err")" -ge 1 ] && [ "$(grep -Ec 'FABLE-COST-CLIFF' "$TMP/mfab.err")" -ge 1 ]; } \
  && ok "M9 orchestrator=fable -> FABLE-ON-ORCHESTRATOR + FABLE-COST-CLIFF warnings" || bad "M9 fable-on-orchestrator warnings missing (err=$(cat "$TMP/mfab.err"))"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1512 — resume-induced quality UP-TIER allow-with-note (completion-time arm), on a DEDICATED fixture
# (mk_sub_resume, NEVER mk_sub_model) so a resume-boundary marker + a SECOND assistant model line are both
# present. AC-2's scope guard requires the DANGEROUS direction (down-tier) and any NON-resume mismatch to
# stay hard-blocked; AC-3 requires the allowance to be a machine-checkable NOTE, never silent.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# mk_sub_resume $session $agentId $preResumeModelId $postResumeModelId [$originKind]
# Writes: a plain user line, an assistant line at $preResumeModelId, a resume-boundary marker
# (type:"user", isMeta:true, origin.kind=$originKind — defaults to "coordinator", matching the real #1494
# shape; the fix's detector also accepts "peer", verified live in the AC-0 probe artifact), then an
# assistant line at $postResumeModelId. transcriptModel() reads the LAST assistant line (post-resume);
# resumeBoundaryModels() reads BOTH (pre-resume anchor + hasResume).
mk_sub_resume() {
  local origin_kind="${5:-coordinator}"
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  { printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[]}}\n' "$2" "$3";
    printf '{"type":"user","isMeta":true,"agentId":"%s","origin":{"kind":"%s"},"message":{"role":"user","content":"The coordinator sent a message while you were working: ...NEEDS-WORK..."}}\n' "$2" "$origin_kind";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[]}}\n' "$2" "$4"; } \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}
# build a complete 4-role ledger with the executor transcript carrying a resume boundary:
# model_ledger_resume <session> <task> <pre-model-id> <post-model-id> [origin-kind]
model_ledger_resume() {
  mk_sub "$1" mP; mk_sub "$1" mR; mk_sub_resume "$1" mE "$3" "$4" "${5:-coordinator}"; mk_sub "$1" mV
  node "$LED" append --session "$1" --task "$2" --role planner         --agent mP --artifact "$TMP/plan.md" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role plan-review      --agent mR --artifact "$TMP/rev.md" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role executor         --agent mE --artifact "PR #9" >/dev/null
  node "$LED" append --session "$1" --task "$2" --role execution-review --agent mV --artifact "$TMP/rev.md" >/dev/null
}

# R1. [proof] RED-then-GREEN: resume-induced UP-tier (executor pre-resume=sonnet matches policy, post-resume
#     =opus, real resume boundary present) -> check --enforce-role-models exits 0 WITH a machine-checkable
#     resume-reroute NOTE (AC-1 treatment shape + AC-3). This is the SYNTHETIC analogue of the real #1494
#     transcript already exercised directly against pre-fix/post-fix code (see the executor's PR description
#     for that live RED->GREEN run); here it proves the SAME shape is reachable from a hermetic fixture.
model_ledger_resume msUP 9301 "claude-sonnet-5" "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msUP --task 9301 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && echo "$OUT" | grep -qE "NOTE:.*RESUME-UPTIER" && echo "$OUT" | grep -qi "executor"; } \
  && ok "[proof] R1 resume-induced up-tier (sonnet->opus, real boundary) -> exit 0 + RESUME-UPTIER NOTE (AC-1/AC-3)" \
  || bad "R1 resume up-tier should allow-with-note (rc=$RC out=$OUT)"

# R2. [proof] Same fixture, origin.kind="peer" (the second real shape the AC-0 probe surfaced) -> same
#     allowance. Proves the detector matches the SHAPE (isMeta:true + non-empty origin.kind), not a
#     hardcoded "coordinator" literal.
model_ledger_resume msUPP 9302 "claude-sonnet-5" "claude-opus-4-8" "peer"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msUPP --task 9302 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qE "NOTE:.*RESUME-UPTIER"; } \
  && ok "[proof] R2 resume-induced up-tier via origin.kind=peer -> exit 0 + NOTE (detector matches shape, not a literal)" \
  || bad "R2 peer-origin resume up-tier should allow-with-note (rc=$RC out=$OUT)"

# R3. [control] resume-induced DOWN-tier (pre-resume=opus matches an opus policy, post-resume=sonnet, real
#     resume boundary present) -> MUST stay hard-blocked (AC-2's dangerous-direction guard). Uses a DEDICATED
#     opus-policy config so pre-resume genuinely matches policy.
MCFG_OPUS="$TMP/mcfg-opus.env"; printf 'CC_ROLE_EXECUTOR_MODEL=opus\n' > "$MCFG_OPUS"
model_ledger_resume msDOWN 9303 "claude-opus-4-8" "claude-sonnet-5"
OUT=$(CC_ROLES_ENV="$MCFG_OPUS" node "$LED" check --session msDOWN --task 9303 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-POLICY" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[control] R3 resume-induced DOWN-tier (opus->sonnet, real boundary) -> STILL exit 2 BLOCK (AC-2)" \
  || bad "R3 resume down-tier must stay blocked, not allowed (rc=$RC out=$OUT)"

# R4. [allow, #1624 reverses the prior RED-control] NON-resume mismatch (no resume boundary at all, plain
#     mk_sub_model) is still a STRICT quality up-tier over policy, so it is NOW allowed-with-note at close —
#     the up-tier decision no longer depends on a resume boundary existing at all. Asserts the CLOSE-UPTIER
#     token, never RESUME-UPTIER (F1 — no resume boundary exists in this fixture).
model_ledger msNORESUME 9304 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msNORESUME --task 9304 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qE "NOTE:.*CLOSE-UPTIER" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[allow, #1624] R4 non-resume up-tier (no boundary, same direction as M1) -> exit 0 CLOSE-UPTIER note" \
  || bad "R4 non-resume up-tier should allow-with-note (rc=$RC out=$OUT)"

# R5. [allow, #1624 reverses the prior RED-control] resume boundary present but PRE-resume model did NOT match
#     policy either (a genuinely wrong spawn that ALSO got resumed) -> the OBSERVED (post-resume) tier is still
#     a strict quality up-tier over policy, so it is allowed-with-note too (the up-tier decision no longer
#     depends on the pre-resume model). Uses the CLOSE-UPTIER token, NOT RESUME-UPTIER (F1) — this fixture
#     cannot honestly claim "resumed FROM a policy-matching model", so it must not borrow that wording.
model_ledger_resume msWRONGSPAWN 9305 "claude-haiku-4-0" "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msWRONGSPAWN --task 9305 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qE "NOTE:.*CLOSE-UPTIER" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[allow, #1624] R5 resume boundary present but pre-resume ALSO mismatched policy -> exit 0 CLOSE-UPTIER (not RESUME-UPTIER, F1)" \
  || bad "R5 pre-resume-mismatched-too case should allow-with-note via CLOSE-UPTIER (rc=$RC out=$OUT)"

# R8. [control, #1624 NEW] non-resume DOWN-tier (policy sonnet, actual haiku, no resume boundary) -> MUST STILL
#     hard-block. This is the corner-cut the relaxation must never touch: isResumeUpTier(sonnet,haiku)===false,
#     so this fixture never reaches either up-tier branch and falls straight through to MODEL-POLICY BLOCK,
#     proving the gate keeps power against a genuine quality regression even after #1624.
model_ledger msDOWNNORESUME 9307 "claude-haiku-4-0"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msDOWNNORESUME --task 9307 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-POLICY" && ! echo "$OUT" | grep -q "CLOSE-UPTIER" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[control, #1624] R8 non-resume DOWN-tier (haiku vs policy sonnet) -> STILL exit 2 BLOCK (down-tier never allowed)" \
  || bad "R8 non-resume down-tier must stay blocked (rc=$RC out=$OUT)"

# R6. [proof] FABLE sub-case (AC-3): resume-induced up-tier landing on fable -> NOTE carries the
#     FABLE-COST-CLIFF substring in addition to the RESUME-UPTIER token (never hides the cost).
model_ledger_resume msUPFAB 9306 "claude-sonnet-5" "claude-fable-1"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msUPFAB --task 9306 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qE "NOTE:.*RESUME-UPTIER" && echo "$OUT" | grep -q "FABLE-COST-CLIFF"; } \
  && ok "[proof] R6 resume-induced up-tier landing on fable -> NOTE carries FABLE-COST-CLIFF (AC-3)" \
  || bad "R6 fable sub-case must carry FABLE-COST-CLIFF in the NOTE (rc=$RC out=$OUT)"

# R7. KILL-SWITCH: RED up-tier fixture but CC_ROLE_MODEL_GATE_OFF=1 -> exit 0 (whole leg off, no NOTE needed
#     since the leg never ran).
OUT=$(CC_ROLE_MODEL_GATE_OFF=1 CC_ROLES_ENV="$MCFG" node "$LED" check --session msUP --task 9301 --enforce-role-models 2>&1); RC=$?
[ "$RC" = "0" ] && ok "R7 CC_ROLE_MODEL_GATE_OFF=1 over resume up-tier fixture -> exit 0 (kill-switch)" \
  || bad "R7 kill-switch should allow (rc=$RC out=$OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1458 — MODEL-VERSION sub-leg (assert-latest / fail-on-drift), on a DEDICATED fixture (MVER_*, NEVER MCFG).
# FIXTURE ISOLATION (the trap): MCFG (used by M1-M9 above) MUST STAY PIN-FREE — adding a CC_TIER_SONNET_VERSION
# pin to MCFG would flip the pre-existing pin-free msGREEN "claude-sonnet-4-6" arm (M2) to exit 2. So every
# version-drift arm below builds its OWN dedicated pinned config file — proving the tier leg (M1-M9, still
# pin-free) is version-agnostic (a version bump never breaks tier enforcement).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
MVER_RED="$TMP/mver-red.env";     printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_TIER_SONNET_VERSION=claude-sonnet-6\n' > "$MVER_RED"
MVER_GREEN="$TMP/mver-green.env"; printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\nCC_TIER_SONNET_VERSION=claude-sonnet-5\n' > "$MVER_GREEN"
MVER_NOPIN="$TMP/mver-nopin.env"; printf 'CC_ROLE_EXECUTOR_MODEL=sonnet\n' > "$MVER_NOPIN"

# V1. RED (AC-4): executor transcript=claude-sonnet-5, pin=claude-sonnet-6 -> exit 2, MODEL-VERSION names
#     role + observed (claude-sonnet-5) + pinned (claude-sonnet-6).
model_ledger msVRED 9201 "claude-sonnet-5"
OUT=$(CC_ROLES_ENV="$MVER_RED" node "$LED" check --session msVRED --task 9201 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-VERSION" && echo "$OUT" | grep -qi "executor" && echo "$OUT" | grep -q "claude-sonnet-5" && echo "$OUT" | grep -q "claude-sonnet-6"; } \
  && ok "V1 RED (AC-4): executor=claude-sonnet-5 vs pin=claude-sonnet-6 -> exit 2 MODEL-VERSION (names observed+pinned)" || bad "V1 version drift should block (rc=$RC out=$OUT)"

# V2. GREEN (AC-5): executor transcript matches the pin exactly -> exit 0.
model_ledger msVGREEN 9202 "claude-sonnet-5"
OUT=$(CC_ROLES_ENV="$MVER_GREEN" node "$LED" check --session msVGREEN --task 9202 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "V2 GREEN (AC-5): executor matches pin exactly -> exit 0" || bad "V2 matching pin should allow (rc=$RC out=$OUT)"

# V3. NO-PIN DORMANT (AC-6): same drifted transcript id, config carries NO CC_TIER_SONNET_VERSION -> version
#     leg dormant, tier leg alone still passes (sonnet==sonnet) -> exit 0.
model_ledger msVNOPIN 9203 "claude-sonnet-6"
OUT=$(CC_ROLES_ENV="$MVER_NOPIN" node "$LED" check --session msVNOPIN --task 9203 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "V3 no-pin dormant (AC-6): no CC_TIER_SONNET_VERSION -> version leg skipped -> exit 0" || bad "V3 no-pin should allow (rc=$RC out=$OUT)"

# V4. FAIL-CLOSED CAN'T-TELL WITH PIN (AC-7): a pin IS configured but the executor transcript carries NO
#     assistant message.model line (plain mk_sub, not mk_sub_model) -> exit 2, MODEL-VERSION can't-tell message.
mk_sub msVCT mCTp; mk_sub msVCT mCTr; mk_sub msVCT mCTe; mk_sub msVCT mCTv
node "$LED" append --session msVCT --task 9204 --role planner         --agent mCTp --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session msVCT --task 9204 --role plan-review      --agent mCTr --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session msVCT --task 9204 --role executor         --agent mCTe --artifact "PR #9204" >/dev/null
node "$LED" append --session msVCT --task 9204 --role execution-review --agent mCTv --artifact "$TMP/rev.md" >/dev/null
OUT=$(CC_ROLES_ENV="$MVER_GREEN" node "$LED" check --session msVCT --task 9204 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-VERSION" && echo "$OUT" | grep -qi "cannot be verified"; } \
  && ok "V4 fail-closed can't-tell WITH pin (AC-7): no message.model line + pin present -> exit 2" || bad "V4 can't-tell-with-pin should block (rc=$RC out=$OUT)"

# V5. VERSION-ONLY KILL-SWITCH (AC-8): CC_ROLE_VERSION_GATE_OFF=1 over the V1 RED fixture -> exit 0.
OUT=$(CC_ROLE_VERSION_GATE_OFF=1 CC_ROLES_ENV="$MVER_RED" node "$LED" check --session msVRED --task 9201 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "V5 CC_ROLE_VERSION_GATE_OFF=1 over RED drift -> exit 0 (version-only kill-switch)" || bad "V5 version kill-switch should allow (rc=$RC out=$OUT)"

# V6. WHOLE-LEG KILL-SWITCH (AC-8): CC_ROLE_MODEL_GATE_OFF=1 over the V1 RED fixture -> exit 0.
OUT=$(CC_ROLE_MODEL_GATE_OFF=1 CC_ROLES_ENV="$MVER_RED" node "$LED" check --session msVRED --task 9201 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "V6 CC_ROLE_MODEL_GATE_OFF=1 over RED drift -> exit 0 (whole model+version leg off)" || bad "V6 model kill-switch should allow (rc=$RC out=$OUT)"

# V7. INVALID-VERSION lint both-ends (AC-12).
MVER_TYPO="$TMP/mver-typo.env"; printf 'CC_TIER_SONNET_VERSION=sonnet5\n' > "$MVER_TYPO"
CC_ROLES_ENV="$MVER_TYPO" node "$LED" resolve-role-model --role executor 2>"$TMP/mverlint.err" >/dev/null
[ "$(grep -Ec 'INVALID-VERSION' "$TMP/mverlint.err")" -ge 1 ] \
  && ok "V7 RED: malformed pin 'sonnet5' -> INVALID-VERSION on stderr" || bad "V7 malformed pin should warn INVALID-VERSION (err=$(cat "$TMP/mverlint.err"))"
CC_ROLES_ENV="$MVER_GREEN" node "$LED" resolve-role-model --role executor 2>"$TMP/mverlint2.err" >/dev/null
[ "$(grep -Ec 'INVALID-VERSION' "$TMP/mverlint2.err")" -eq 0 ] \
  && ok "V7 GREEN: valid 'claude-sonnet-5' pin -> NO INVALID-VERSION" || bad "V7 valid pin should not warn (err=$(cat "$TMP/mverlint2.err"))"

# V8. Re-assert MCFG stays pin-free (AC-9 witness, this file): the pre-existing pin-free msGREEN
#     "claude-sonnet-4-6" arm (M2, config MCFG) is untouched by any MVER_* fixture above (distinct files).
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msGREEN --task 9102 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "V8 re-assert: MCFG stays pin-free -- msGREEN claude-sonnet-4-6 arm still exit 0" || bad "V8 MCFG pin-free re-assert failed (rc=$RC out=$OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1465 — model+effort CAPTURE at append time (AC1 four independent cases + AC2 back-compat).
# Reuses mk_sub (resolvable, NO message.model line) / mk_sub_model (resolvable, WITH a message.model
# line — both already defined above for the #1448 model-policy block). Every case passes --agent
# explicitly (deterministic; the self-append/resolveAgent timing path is proven separately, LIVE, by
# AC1-LIVE — not a synthetic fixture). #1466: the ambient process.env.CLAUDE_EFFORT auto-capture is
# REMOVED (it stamped the ORCHESTRATOR's session effort on every append, clobbering a role's real
# per-role effort — see hooks/three-role-effort-mechanism-smoke-test.sh AC-5 for the clobber-safety
# proof); effort is now written ONLY via the explicit --effort flag, so these cases pass/omit --effort
# directly instead of setting/unsetting the CLAUDE_EFFORT env var (which no longer has any effect on
# cmdAppend at all).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
MESID="sess-1465-model"

# CASE GREEN (both): message.model line present + explicit --effort xhigh -> line carries all three keys.
mk_sub_model "$MESID" me-green "claude-sonnet-5"
node "$LED" append --session "$MESID" --task 1465g --role executor --agent me-green --artifact "PR #1" --effort xhigh >/dev/null
GF="$THREE_ROLE_LEDGER_DIR/$MESID/1465g.jsonl"
{ grep -q '"effort":"xhigh"' "$GF" && grep -q '"modelVersion":"claude-sonnet-5"' "$GF" && grep -q '"modelTier":"sonnet"' "$GF"; } \
  && ok "#1465 AC1 GREEN: model auto-capture + explicit --effort -> line carries effort+modelVersion+modelTier" \
  || bad "#1465 AC1 GREEN failed (got: $(cat "$GF" 2>/dev/null))"

# CASE PARTIAL-A (effort only): resolvable agent, NO message.model line, explicit --effort xhigh -> line
# carries effort, NEITHER modelVersion NOR modelTier (proves effort does not ride on the model path).
mk_sub "$MESID" me-parta
node "$LED" append --session "$MESID" --task 1465pa --role executor --agent me-parta --artifact "PR #2" --effort xhigh >/dev/null
PAF="$THREE_ROLE_LEDGER_DIR/$MESID/1465pa.jsonl"
{ grep -q '"effort":"xhigh"' "$PAF" && ! grep -q '"modelVersion"' "$PAF" && ! grep -q '"modelTier"' "$PAF"; } \
  && ok "#1465 AC1 PARTIAL-A: explicit --effort, no model line -> effort present, model fields absent" \
  || bad "#1465 AC1 PARTIAL-A failed (got: $(cat "$PAF" 2>/dev/null))"

# CASE PARTIAL-B (model only): message.model line present, NO --effort flag passed -> modelVersion+modelTier
# present, NO effort key (proves the model auto-capture does not ride on any effort input).
mk_sub_model "$MESID" me-partb "claude-sonnet-5"
node "$LED" append --session "$MESID" --task 1465pb --role executor --agent me-partb --artifact "PR #3" >/dev/null
PBF="$THREE_ROLE_LEDGER_DIR/$MESID/1465pb.jsonl"
{ grep -q '"modelVersion":"claude-sonnet-5"' "$PBF" && grep -q '"modelTier":"sonnet"' "$PBF" && ! grep -q '"effort"' "$PBF"; } \
  && ok "#1465 AC1 PARTIAL-B: model-only (no --effort flag) -> model fields present, no effort key" \
  || bad "#1465 AC1 PARTIAL-B failed (got: $(cat "$PBF" 2>/dev/null))"

# CASE RED (neither, NON-VACUOUS): the SAME resolvable agent shape, NO message.model line, NO --effort flag
# -> line carries NONE of the three fields, but the agentId itself STILL resolves onto the line (proves the
# omission is because there is no model line / no effort flag, NOT a no-transcript/fail-open vacuous path).
mk_sub "$MESID" me-red
node "$LED" append --session "$MESID" --task 1465r --role executor --agent me-red --artifact "PR #4" >/dev/null
RF="$THREE_ROLE_LEDGER_DIR/$MESID/1465r.jsonl"
{ ! grep -q '"effort"' "$RF" && ! grep -q '"modelVersion"' "$RF" && ! grep -q '"modelTier"' "$RF" && grep -q '"agentId":"me-red"' "$RF"; } \
  && ok "#1465 AC1 RED: no model line + no --effort flag -> none of the three fields (agentId still resolves, non-vacuous)" \
  || bad "#1465 AC1 RED failed (got: $(cat "$RF" 2>/dev/null))"

# AC2 back-compat: a COMPLETE 4-role ledger built with NO model/effort resolvable (old shape) -> `check`
# still exits 0/OK, and an explicit assertion that none of the appended lines carry any of the 3 new keys.
mk_sub "$SID" old1465p; mk_sub "$SID" old1465r; mk_sub "$SID" old1465e; mk_sub "$SID" old1465v
OT="1465oldshape"
node "$LED" append --session "$SID" --task "$OT" --role planner         --agent old1465p --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$SID" --task "$OT" --role plan-review      --agent old1465r --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$SID" --task "$OT" --role executor         --agent old1465e --artifact "PR #1465old" >/dev/null
node "$LED" append --session "$SID" --task "$OT" --role execution-review --agent old1465v --artifact "$TMP/rev.md" >/dev/null
OLDF="$THREE_ROLE_LEDGER_DIR/$SID/$OT.jsonl"
OUT=$(node "$LED" check --session "$SID" --task "$OT" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && ! grep -qE '"modelVersion"|"modelTier"|"effort"' "$OLDF"; } \
  && ok "#1465 AC2: old-shape 4-role ledger (no model/effort resolvable) -> check still OK, no model/effort fields present" \
  || bad "#1465 AC2 back-compat failed (rc=$RC out=$OUT ledger=$(cat "$OLDF" 2>/dev/null))"


# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1481 — T1: `refresh-models --session S` IN-FLIGHT model backfill. The oracle is the NEW subcommand
# itself (RED pre-fix: `refresh-models` is unrecognized, prints usage, exits 2 -> the ledger line NEVER
# gains a model -> every assertion below fails). The already-green `append` auto-capture (#1465) is REUSED
# via the shared resolveModelFields() helper, not the oracle.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
SID_RF="sess-1481-refresh"; TASK_RF="1481r"
RFFILE="$THREE_ROLE_LEDGER_DIR/$SID_RF/$TASK_RF.jsonl"

# T1a setup: an in-progress EXECUTOR line, written while its transcript carries NO message.model line yet
# (mk_sub) -> lands model-less (agentId + artifact + effort captured; no modelVersion/modelTier).
mk_sub "$SID_RF" rf-e1
node "$LED" append --session "$SID_RF" --task "$TASK_RF" --role executor --agent rf-e1 --artifact "PR #1481" --effort xhigh >/dev/null
{ grep -q '"agentId":"rf-e1"' "$RFFILE" && ! grep -q '"modelVersion"' "$RFFILE"; } \
  && ok "#1481 T1a setup: in-progress executor line written model-less (agentId present, no modelVersion yet)" \
  || bad "#1481 T1a setup failed (got: $(cat "$RFFILE" 2>/dev/null))"

# T1b (RED/GREEN oracle): the SAME transcript is now UPDATED to carry message.model:"claude-sonnet-5" (the
# subagent produced its first assistant turn) -> run `refresh-models --session S` -> the executor line
# acquires modelTier/modelVersion, and effort/agentId/artifact_path are UNTOUCHED (no verdict field exists
# for an executor role, before or after -- also asserted, proving nothing spurious was added).
mk_sub_model "$SID_RF" rf-e1 "claude-sonnet-5"
OUT_RF=$(node "$LED" refresh-models --session "$SID_RF" 2>&1); RC_RF=$?
{ [ "$RC_RF" = "0" ] \
  && grep -q '"modelTier":"sonnet"' "$RFFILE" \
  && grep -q '"modelVersion":"claude-sonnet-5"' "$RFFILE" \
  && grep -q '"effort":"xhigh"' "$RFFILE" \
  && grep -q '"agentId":"rf-e1"' "$RFFILE" \
  && grep -q '"artifact_path":"PR #1481"' "$RFFILE" \
  && ! grep -q '"verdict"' "$RFFILE"; } \
  && ok "#1481 T1: refresh-models backfills modelTier=sonnet + modelVersion=claude-sonnet-5; effort/agentId/artifact_path UNTOUCHED (rc=$RC_RF)" \
  || bad "#1481 T1 FAILED -- refresh-models did not backfill as expected (rc=$RC_RF out=$OUT_RF ledger=$(cat "$RFFILE" 2>/dev/null))"

# T1c idempotency: re-running refresh-models a SECOND time reports changed=0 (nothing left to backfill) and
# the ledger line is byte-identical (absent->present only, never re-touches an already-present model).
BEFORE_RF="$(cat "$RFFILE")"
OUT_RF2=$(node "$LED" refresh-models --session "$SID_RF" 2>&1); RC_RF2=$?
AFTER_RF="$(cat "$RFFILE")"
{ [ "$RC_RF2" = "0" ] && echo "$OUT_RF2" | grep -q "changed=0" && [ "$BEFORE_RF" = "$AFTER_RF" ]; } \
  && ok "#1481 T1c: re-running refresh-models is idempotent (changed=0, ledger line unchanged)" \
  || bad "#1481 T1c idempotency failed (rc=$RC_RF2 out=$OUT_RF2 before=$BEFORE_RF after=$AFTER_RF)"

# T1d never-rewrite: a role that ALREADY carries a modelVersion (captured at append time because its
# transcript already had a message.model line) must NEVER be overwritten by refresh-models even if the
# transcript's LATEST assistant model later changes (e.g. a stale re-run) -- absent->present ONLY.
mk_sub_model "$SID_RF" rf-pr1 "claude-opus-4-8"
node "$LED" append --session "$SID_RF" --task "$TASK_RF" --role plan-review --agent rf-pr1 --artifact "$TMP/rev.md" >/dev/null
PRFILE_LINE_BEFORE="$(grep -o '"role":"plan-review"[^}]*' "$RFFILE")"
# transcript now (hypothetically) shows a DIFFERENT model -- append a second, later assistant line.
printf '{"type":"assistant","agentId":"rf-pr1","message":{"model":"claude-sonnet-5","role":"assistant","content":[]}}\n' >> "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RF/subagents/agent-rf-pr1.jsonl"
node "$LED" refresh-models --session "$SID_RF" >/dev/null 2>&1
PRFILE_LINE_AFTER="$(grep -o '"role":"plan-review"[^}]*' "$RFFILE")"
{ [ "$PRFILE_LINE_BEFORE" = "$PRFILE_LINE_AFTER" ] && grep -q '"modelVersion":"claude-opus-4-8"' "$RFFILE"; } \
  && ok "#1481 T1d: an ALREADY-present modelVersion is never rewritten (absent->present only)" \
  || bad "#1481 T1d never-rewrite failed (before=$PRFILE_LINE_BEFORE after=$PRFILE_LINE_AFTER)"

# T1e fail-open: a session with NO ledger dir at all -> exit 0, no throw.
OUT_RF5=$(node "$LED" refresh-models --session "sess-1481-no-such-session" 2>&1); RC_RF5=$?
[ "$RC_RF5" = "0" ] && ok "#1481 T1e: no ledger dir for session -> fail-open exit 0" || bad "#1481 T1e fail-open failed (rc=$RC_RF5 out=$OUT_RF5)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1495 — research seat ledger-visibility. cmdAppend's role guard now reads RECORDABLE_ROLES (= REQUIRED_ROLES
# + 'research'), while REQUIRED_ROLES itself and all four completion-loops (cmdCheck / --enforce-role-models /
# provenance / cmdRefreshModels) stay UNCHANGED — a research row is recorded but NEVER gates a close (G1).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
RSID="sess-1495-research"

# ---- [proof] L-APPEND-RESEARCH: append --role research now succeeds. RED on HEAD: `:722`-era guard
#      `REQUIRED_ROLES.includes('research')` is false -> exit 2, no line. GREEN post-fix: exit 0, one line.
mk_sub "$RSID" r-agent1
OUT=$(node "$LED" append --session "$RSID" --task 1495a --role research --agent r-agent1 2>&1); RC=$?
RFILE_A="$THREE_ROLE_LEDGER_DIR/$RSID/1495a.jsonl"
{ [ "$RC" = "0" ] && grep -q '"role":"research"' "$RFILE_A" 2>/dev/null; } \
  && ok "[proof] L-APPEND-RESEARCH: append --role research -> exit 0, one role:research line" \
  || bad "[proof] L-APPEND-RESEARCH failed (rc=$RC out=$OUT file=$(cat "$RFILE_A" 2>/dev/null))"

# ---- [control] L-APPEND-BOGUS: an unrecordable role is STILL rejected (superset is controlled, not "anything").
#      PASSES on HEAD (bogus already rejected) AND post-fix.
OUT=$(node "$LED" append --session "$RSID" --task 1495b --role bogus --agent r-agent2 2>&1); RC=$?
{ [ "$RC" = "2" ]; } && ok "[control] L-APPEND-BOGUS: an unrecordable role still exits 2" || bad "[control] L-APPEND-BOGUS should exit 2 (rc=$RC out=$OUT)"

# ---- [proof] L-PROVENANCE-RESEARCH (locks :899-class provenance loop — AC7): a FULL clean 4-role chain PLUS
#      one research row with NO self_authored stamp -> check --require-provenance still exits 0 (the provenance
#      loop iterates REQUIRED_ROLES only; a research row is never demanded to be self-authored).
#      Unbuildable on HEAD (append rejects --role research, exit 2) -> the fixture itself cannot be built.
mk_sub "$RSID" pr-p; mk_sub "$RSID" pr-r; mk_sub "$RSID" pr-e; mk_sub "$RSID" pr-v; mk_sub "$RSID" pr-rsch
node "$LED" append --session "$RSID" --task 1495c --role planner         --agent pr-p --artifact "$TMP/plan.md" --self-authored >/dev/null
node "$LED" append --session "$RSID" --task 1495c --role plan-review      --agent pr-r --artifact "$TMP/rev.md" --self-authored >/dev/null
node "$LED" append --session "$RSID" --task 1495c --role executor         --agent pr-e --artifact "PR #1495c" --self-authored >/dev/null
node "$LED" append --session "$RSID" --task 1495c --role execution-review --agent pr-v --artifact "$TMP/rev.md" --self-authored >/dev/null
node "$LED" append --session "$RSID" --task 1495c --role research         --agent pr-rsch >/dev/null 2>&1; RESRC_C=$?   # NO self-authored — the point of this AC; capture append's own exit code (on HEAD this is 2 -> fixture unbuildable, the true RED)
research_row_c=$(grep -c '"role":"research"' "$THREE_ROLE_LEDGER_DIR/$RSID/1495c.jsonl" 2>/dev/null)
OUT=$(CC_ROLES_ENV=/nonexistent node "$LED" check --session "$RSID" --task 1495c --require-provenance 2>&1); RC=$?
{ [ "$RESRC_C" = "0" ] && [ "$research_row_c" = "1" ] && [ "$RC" = "0" ]; } && ok "[proof] L-PROVENANCE-RESEARCH: 4-clean-role chain + unstamped research row -> require-provenance still exit 0" \
  || bad "[proof] L-PROVENANCE-RESEARCH failed (append_rc=$RESRC_C research_row=$research_row_c rc=$RC out=$OUT)"

# ---- [proof] L-CLOSE-NO-ARTIFACT (anti-vacuity control arm — #1502 lesson): 4 required-role lines complete
#      PLUS a research row with NO --artifact -> check --enforce-role-models still exits 0 (clean close). The
#      REAL close gate is reachable-GREEN with a research row present, not merely "a row exists somewhere".
#      Unbuildable on HEAD (append rejects the research line).
mk_sub "$RSID" na-p; mk_sub "$RSID" na-r; mk_sub "$RSID" na-e; mk_sub "$RSID" na-v; mk_sub "$RSID" na-rsch
node "$LED" append --session "$RSID" --task 1495d --role planner         --agent na-p --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495d --role plan-review      --agent na-r --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495d --role executor         --agent na-e --artifact "PR #1495d" >/dev/null
node "$LED" append --session "$RSID" --task 1495d --role execution-review --agent na-v --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495d --role research         --agent na-rsch >/dev/null 2>&1; RESRC_D=$?   # NO --artifact; capture the append's own exit code — on HEAD this is 2 (rejected), making the fixture unbuildable, the true RED
research_row_d=$(grep -c '"role":"research"' "$THREE_ROLE_LEDGER_DIR/$RSID/1495d.jsonl" 2>/dev/null)
OUT=$(CC_ROLES_ENV=/nonexistent node "$LED" check --session "$RSID" --task 1495d --enforce-role-models 2>&1); RC=$?
{ [ "$RESRC_D" = "0" ] && [ "$research_row_d" = "1" ] && [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } && ok "[proof] L-CLOSE-NO-ARTIFACT: 4 required clean + artifact-less research row -> check exits 0 (reachable GREEN close)" \
  || bad "[proof] L-CLOSE-NO-ARTIFACT failed (append_rc=$RESRC_D research_row=$research_row_d rc=$RC out=$OUT)"

# ---- [proof] L-CLOSE-FABLE-WARN: 4 required lines matching their policy tiers PLUS an up-tiered `fable`
#      research row (policy says sonnet) -> check --enforce-role-models still exits 0 and emits NO
#      MODEL-POLICY: block for research (the enforce loop iterates REQUIRED_ROLES only -> research tier is
#      NEVER compared -> an up-tiered fable research spawn cannot brick a close). Unbuildable on HEAD.
FWCFG="$TMP/fw-cfg.env"; printf 'CC_ROLE_PLANNER_MODEL=opus\nCC_ROLE_PLAN_REVIEW_MODEL=opus\nCC_ROLE_EXECUTOR_MODEL=sonnet\nCC_ROLE_EXECUTION_REVIEW_MODEL=opus\nCC_ROLE_RESEARCH_MODEL=sonnet\n' > "$FWCFG"
mk_sub_model "$RSID" fw-p "claude-opus-4-8"; mk_sub_model "$RSID" fw-r "claude-opus-4-8"
mk_sub_model "$RSID" fw-e "claude-sonnet-5"; mk_sub_model "$RSID" fw-v "claude-opus-4-8"
mk_sub_model "$RSID" fw-rsch "claude-fable-5"
node "$LED" append --session "$RSID" --task 1495e --role planner         --agent fw-p --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495e --role plan-review      --agent fw-r --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495e --role executor         --agent fw-e --artifact "PR #1495e" >/dev/null
node "$LED" append --session "$RSID" --task 1495e --role execution-review --agent fw-v --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495e --role research         --agent fw-rsch >/dev/null 2>&1; RESRC_E=$?   # capture append's own exit code — on HEAD this is 2 (rejected), making the fixture unbuildable, the true RED
research_row_e=$(grep -c '"role":"research"' "$THREE_ROLE_LEDGER_DIR/$RSID/1495e.jsonl" 2>/dev/null)
OUT=$(CC_ROLES_ENV="$FWCFG" node "$LED" check --session "$RSID" --task 1495e --enforce-role-models 2>&1); RC=$?
{ [ "$RESRC_E" = "0" ] && [ "$research_row_e" = "1" ] && [ "$RC" = "0" ] && ! echo "$OUT" | grep -qiE 'MODEL-POLICY:.*research'; } \
  && ok "[proof] L-CLOSE-FABLE-WARN: up-tiered fable research row -> exit 0, no MODEL-POLICY block for research (G1)" \
  || bad "[proof] L-CLOSE-FABLE-WARN failed (append_rc=$RESRC_E research_row=$research_row_e rc=$RC out=$OUT)"

# ---- [control] L-MISSING-REQUIRED-HARD-BLOCKS: a task missing one required role (execution-review) PLUS a
#      present research line -> check still exits 2 (HARD BLOCK). Proves research does not "substitute" for a
#      missing required role. PASSES on HEAD (already blocks) AND post-fix.
mk_sub "$RSID" mb-p; mk_sub "$RSID" mb-r; mk_sub "$RSID" mb-e; mk_sub "$RSID" mb-rsch
node "$LED" append --session "$RSID" --task 1495f --role planner    --agent mb-p --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495f --role plan-review --agent mb-r --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$RSID" --task 1495f --role executor   --agent mb-e --artifact "PR #1495f" >/dev/null
node "$LED" append --session "$RSID" --task 1495f --role research   --agent mb-rsch >/dev/null   # NO execution-review at all
OUT=$(node "$LED" check --session "$RSID" --task 1495f 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -qi "missing execution-review"; } \
  && ok "[control] L-MISSING-REQUIRED-HARD-BLOCKS: missing execution-review + present research -> still BLOCK" \
  || bad "[control] L-MISSING-REQUIRED-HARD-BLOCKS failed (rc=$RC out=$OUT)"


# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1509 — Leg A (tracked-ness, HARD block for planner/plan-review/execution-review) + the executor-
# disk-path SURFACED NOTE (never a block). Fixtures live inside a DEDICATED scratch git repo (mktemp -d +
# `git init`) so `git ls-files --error-unmatch` produces REAL tracked/untracked verdicts — $TMP itself is
# NOT a git repo (every OTHER artifact fixture in this file lives there and can-not-tell/fail-opens Leg A,
# which is exactly why those pre-existing ALLOW cases above are unaffected by this addition).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
GITROOT="$(mktemp -d)"
( cd "$GITROOT" && git init -q && git config user.email t@t.co && git config user.name t )
mkdir -p "$GITROOT/.ai-workspace/plans" "$GITROOT/.ai-workspace/reviews"

# Frozen-#1515-shaped fixture bodies (synthetic content, real headings so PLAN_RE/VERDICT_RE resolve) — the
# real #1515 ticket (6th recurrence of the #861 class) shipped a PR while its three disk-path role artifacts
# sat present-but-untracked on master; this reproduces that exact shape hermetically.
printf '## ELI5\nfrozen #1515-shaped plan copy\n### Binary AC\n- AC1\n' > "$GITROOT/.ai-workspace/plans/1515-plan.md"
printf '## Review\nverdict: PASS\n' > "$GITROOT/.ai-workspace/reviews/1515-planreview.md"
printf '## Review\nverdict: PASS\n' > "$GITROOT/.ai-workspace/reviews/1515-execreview.md"

TSID="sess-1509-tracked"
mk_sub "$TSID" tp1; mk_sub "$TSID" tr1; mk_sub "$TSID" te1; mk_sub "$TSID" tv1
node "$LED" append --session "$TSID" --task 1509red --role planner --agent tp1 --artifact "$GITROOT/.ai-workspace/plans/1515-plan.md" >/dev/null
node "$LED" append --session "$TSID" --task 1509red --role plan-review --agent tr1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID" --task 1509red --role executor --agent te1 --artifact "PR #1515" >/dev/null
node "$LED" append --session "$TSID" --task 1509red --role execution-review --agent tv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null

# 1509-AC1 RED: all three disk-path artifacts EXIST but are UNTRACKED (never `git add`-ed) -> the gated leg
# exits non-zero and NAMES the untracked roles.
OUT=$(node "$LED" check --session "$TSID" --task 1509red --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "TRACKED:" && echo "$OUT" | grep -qi "planner" && echo "$OUT" | grep -qi "plan-review" && echo "$OUT" | grep -qi "execution-review"; } \
  && ok "[proof] 1509-AC1 RED: frozen-#1515-shaped untracked fixture -> --enforce-tracked-artifacts exit 2, names untracked roles" \
  || bad "1509-AC1 RED failed (rc=$RC out=$OUT)"

# 1509-AC3 control: base `check` WITHOUT the flag, on the SAME untracked fixture -> still exit 0
# (existence-only, unchanged — the ~161 untracked historical artifacts and every non-gate caller must not break).
OUT=$(node "$LED" check --session "$TSID" --task 1509red 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[control] 1509-AC3: base check WITHOUT the flag on the SAME untracked fixture -> still exit 0 (no base regression)" \
  || bad "1509-AC3 base-check-unaffected failed (rc=$RC out=$OUT)"

# 1509-AC7 sanity: the SAME RED fixture with SHIP_PIPELINE=1 exported -> the ledger CLI's Leg A still exits 2
# (this flag is never consulted by the node helper at all — the SHIP_PIPELINE exemption logic lives entirely
# in the hook shell script; the substantive proof that the HOOK does not route around Leg A under
# SHIP_PIPELINE=1 is in hooks/three-role-instrumentation-gate-smoke-test.sh, cases 1509-H1/H2).
OUT=$(SHIP_PIPELINE=1 node "$LED" check --session "$TSID" --task 1509red --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "TRACKED:"; } \
  && ok "[proof] 1509-AC7 sanity: SHIP_PIPELINE=1 exported -> ledger CLI Leg A still exits 2 (env var not consulted here)" \
  || bad "1509-AC7 ledger-CLI sanity failed (rc=$RC out=$OUT)"

# 1509-AC1 GREEN: git add + commit the SAME three paths -> --enforce-tracked-artifacts now exits 0.
( cd "$GITROOT" && git add .ai-workspace/plans/1515-plan.md .ai-workspace/reviews/1515-planreview.md .ai-workspace/reviews/1515-execreview.md && git commit -q -m "fixture: freeze #1515 artifacts" )
OUT=$(node "$LED" check --session "$TSID" --task 1509red --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[proof] 1509-AC1 GREEN: same three paths committed -> --enforce-tracked-artifacts exit 0" \
  || bad "1509-AC1 GREEN failed (rc=$RC out=$OUT)"

# 1509-AC1 EXECUTOR ROLE-KEYED EXEMPTION: executor row carries a present-but-UNTRACKED disk path, the other
# three roles TRACKED -> the tracked-leg does NOT name executor and does not block on it (exit 0).
printf '## ELI5\nexecutor mis-cited plan copy\n### Binary AC\n- AC1\n' > "$GITROOT/.ai-workspace/plans/1509-exec-note.md"
TSID2="sess-1509-execexempt"
mk_sub "$TSID2" ep1; mk_sub "$TSID2" er1; mk_sub "$TSID2" ee1; mk_sub "$TSID2" ev1
node "$LED" append --session "$TSID2" --task 1509ex --role planner --agent ep1 --artifact "$GITROOT/.ai-workspace/plans/1515-plan.md" >/dev/null
node "$LED" append --session "$TSID2" --task 1509ex --role plan-review --agent er1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID2" --task 1509ex --role executor --agent ee1 --artifact "$GITROOT/.ai-workspace/plans/1509-exec-note.md" >/dev/null
node "$LED" append --session "$TSID2" --task 1509ex --role execution-review --agent ev1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID2" --task 1509ex --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "TRACKED:"; } \
  && ok "[proof] 1509-AC1 EXECUTOR-EXEMPT: executor's own untracked disk path is NOT named/blocked by Leg A (role-keyed exemption)" \
  || bad "1509-AC1 executor-exempt failed (rc=$RC out=$OUT)"
{ echo "$OUT" | grep -q "NOTE-EXECUTOR:" && echo "$OUT" | grep -qi "1509-exec-note.md"; } \
  && ok "[proof] 1509-AC2 SURFACE: executor's disk-path row is SURFACED as a NOTE-EXECUTOR (never a block)" \
  || bad "1509-AC2 executor NOTE not surfaced (out=$OUT)"

# 1509-AC2 GREEN (plan-review==planner collision, tracked): the real doctrine-sanctioned shape (44/246 real
# ledgers measured, e.g. #1477/#1481/#1466 — review roles self-write their `## Review` marker INTO the plan)
# -> --enforce-tracked-artifacts exits 0, NO spurious duplication/plan-review problem (the plan REJECTS any
# cross-role-duplication hard block as a measured-false invariant; this proves it is not walled).
COLLIDE="$GITROOT/.ai-workspace/plans/1509-collide-plan.md"
printf '## ELI5\ncollision plan\n### Binary AC\n- AC1\n## Review\nverdict: PASS\n' > "$COLLIDE"
( cd "$GITROOT" && git add .ai-workspace/plans/1509-collide-plan.md && git commit -q -m "fixture: collision plan (tracked)" )
TSID3="sess-1509-collide-pr"
mk_sub "$TSID3" cp1; mk_sub "$TSID3" ce1; mk_sub "$TSID3" cv1
node "$LED" append --session "$TSID3" --task 1509pr --role planner --agent cp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID3" --task 1509pr --role plan-review --agent cp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID3" --task 1509pr --role executor --agent ce1 --artifact "PR #1509" >/dev/null
node "$LED" append --session "$TSID3" --task 1509pr --role execution-review --agent cv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID3" --task 1509pr --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[proof] 1509-AC2 GREEN: plan-review==planner (doctrine-sanctioned collision, tracked) -> exit 0, NOT blocked" \
  || bad "1509-AC2 plan-review==planner should not block (rc=$RC out=$OUT)"

# 1509-AC2 GREEN (executor==planner collision, tracked): the #1494-shaped historical convention (62/246 real
# chains measured, e.g. #1494/#1420/#1414 — the executor self-cites the planner's plan file) -> exit 0, NOT
# blocked; the executor row is SURFACED as a NOTE-EXECUTOR (never silently dropped, never a hard block).
TSID4="sess-1509-collide-ex"
mk_sub "$TSID4" xp1; mk_sub "$TSID4" xr1; mk_sub "$TSID4" xv1
node "$LED" append --session "$TSID4" --task 1509ex2 --role planner --agent xp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID4" --task 1509ex2 --role plan-review --agent xr1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID4" --task 1509ex2 --role executor --agent xp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID4" --task 1509ex2 --role execution-review --agent xv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID4" --task 1509ex2 --enforce-tracked-artifacts 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && echo "$OUT" | grep -q "NOTE-EXECUTOR:" && echo "$OUT" | grep -qi "1509-collide-plan.md"; } \
  && ok "[proof] 1509-AC2 GREEN: executor==planner (#1494-shaped historical convention, tracked) -> exit 0, NOT blocked, NOTE-EXECUTOR surfaces the executor row" \
  || bad "1509-AC2 executor==planner should not block + must surface NOTE (rc=$RC out=$OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1544 — perf-log JURISDICTION-KEYED tracked-check, riding the SAME --enforce-tracked-artifacts flag (Leg
# A) via a NEW --perf-log argument. AC1(RED)/AC2(GREEN) need the perf-log's containing repo to equal the
# ai-brain toplevel; AC3a(POWER) needs it OUTSIDE that jurisdiction. Since aiBrainToplevel() derives from
# wherever the RUNNING hooks/3role-ledger.mjs file itself lives (git -C <that dir> rev-parse
# --show-toplevel), this smoke builds a fully HERMETIC "ai-brain" analog: a throwaway git repo carrying a
# COPY (not a symlink — a symlink would realpath straight back to THIS repo and defeat the isolation) of
# the real ledger script, so aiBrainToplevel() resolves to the throwaway repo. This keeps the whole #1544
# block hermetic (never touches this smoke's own real running repo), exactly like #1509/#1537 above.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AB_HERMETIC="$(mktemp -d)"
( cd "$AB_HERMETIC" && git init -q && git config user.email t@t.co && git config user.name t )
mkdir -p "$AB_HERMETIC/hooks" "$AB_HERMETIC/.ai-workspace/plans" "$AB_HERMETIC/.ai-workspace/reviews" "$AB_HERMETIC/.ai-workspace/perf-logs"
cp "$LED" "$AB_HERMETIC/hooks/3role-ledger.mjs"
LED_AB="$AB_HERMETIC/hooks/3role-ledger.mjs"
printf '## ELI5\nplan\n### Binary AC\n- AC1\n' > "$AB_HERMETIC/.ai-workspace/plans/1544-plan.md"
printf '## Review\nverdict: PASS\n' > "$AB_HERMETIC/.ai-workspace/reviews/1544-rev.md"
printf 'tests: 3 passed — PASS\n' > "$AB_HERMETIC/oracle.txt"
( cd "$AB_HERMETIC" && git add hooks .ai-workspace oracle.txt && git commit -q -m "fixture: #1544 hermetic ai-brain" )

TSID5="sess-1544-jur"
mk_sub "$TSID5" jp1; mk_sub "$TSID5" jr1; mk_sub "$TSID5" je1; mk_sub "$TSID5" jv1
node "$LED_AB" append --session "$TSID5" --task 1544j --role planner --agent jp1 --artifact "$AB_HERMETIC/.ai-workspace/plans/1544-plan.md" >/dev/null
node "$LED_AB" append --session "$TSID5" --task 1544j --role plan-review --agent jr1 --artifact "$AB_HERMETIC/.ai-workspace/reviews/1544-rev.md" >/dev/null
node "$LED_AB" append --session "$TSID5" --task 1544j --role executor --agent je1 --artifact "PR #1544j" >/dev/null
node "$LED_AB" append --session "$TSID5" --task 1544j --role execution-review --agent jv1 --oracle "$AB_HERMETIC/oracle.txt" >/dev/null

# 1544-AC1 RED: untracked perf-log EXISTS under the hermetic ai-brain's .ai-workspace/perf-logs/ -> exit 2,
# TRACKED: names it. (Proves --perf-log is now consumed by the TRACKED leg, not only the privacy leg.)
PERF1544="$AB_HERMETIC/.ai-workspace/perf-logs/untracked.md"
printf 'card\n' > "$PERF1544"
OUT=$(node "$LED_AB" check --session "$TSID5" --task 1544j --enforce-tracked-artifacts --perf-log "$PERF1544" 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "TRACKED:" && echo "$OUT" | grep -q "untracked.md"; } \
  && ok "[proof] 1544-AC1 RED: in-ai-brain untracked perf-log -> --enforce-tracked-artifacts exit 2, names the perf-log" \
  || bad "1544-AC1 RED failed (rc=$RC out=$OUT)"

# 1544-AC2 GREEN: git add + commit the SAME perf-log -> exit 0. Toggling ONLY the git-add flips AC1<->AC2.
( cd "$AB_HERMETIC" && git add .ai-workspace/perf-logs/untracked.md && git commit -q -m "fixture: track the 1544j perf-log" )
OUT=$(node "$LED_AB" check --session "$TSID5" --task 1544j --enforce-tracked-artifacts --perf-log "$PERF1544" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[proof] 1544-AC2 GREEN: same perf-log committed -> --enforce-tracked-artifacts exit 0" \
  || bad "1544-AC2 GREEN failed (rc=$RC out=$OUT)"

# 1544-AC3a POWER (the discriminating case): an untracked file inside a DIFFERENT real git repo (NOT
# ai-brain) -> exit 0, NOT blocked. A naive `isGitTracked===false -> block` impl WOULD block this case
# (isGitTracked alone is jurisdiction-blind); the ai-brain-toplevel jurisdiction key must fail-open here.
OTHER_REPO_1544="$(mktemp -d)"
( cd "$OTHER_REPO_1544" && git init -q && git config user.email t@t.co && git config user.name t )
PERF3A_1544="$OTHER_REPO_1544/perf.md"; printf 'card\n' > "$PERF3A_1544"
OUT=$(node "$LED_AB" check --session "$TSID5" --task 1544j --enforce-tracked-artifacts --perf-log "$PERF3A_1544" 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "TRACKED:"; } \
  && ok "[proof] 1544-AC3a POWER: untracked perf-log inside a DIFFERENT real (non-ai-brain) git repo -> exit 0 (ai-brain-toplevel jurisdiction key, not bare isGitTracked)" \
  || bad "1544-AC3a POWER failed (rc=$RC out=$OUT)"
rm -rf "$OTHER_REPO_1544"

# 1544-AC3b (not-a-repo residual): a perf-log path under bare $TMP (never a git repo, mirrors the real
# template home ~/.claude/agent-working-memory/... which is likewise not a git worktree) -> exit 0.
PERF3B_1544="$TMP/notarepo-perf-1544.md"; printf 'card\n' > "$PERF3B_1544"
OUT=$(node "$LED_AB" check --session "$TSID5" --task 1544j --enforce-tracked-artifacts --perf-log "$PERF3B_1544" 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "TRACKED:"; } \
  && ok "[proof] 1544-AC3b: non-repo perf-log path -> exit 0 (can't-tell, fail-open)" \
  || bad "1544-AC3b failed (rc=$RC out=$OUT)"

# 1544-AC3c (unresolvable): a --perf-log path that does not exist on disk at all -> exit 0 (nothing to check).
OUT=$(node "$LED_AB" check --session "$TSID5" --task 1544j --enforce-tracked-artifacts --perf-log "$TMP/does-not-exist-1544.md" 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "TRACKED:"; } \
  && ok "[proof] 1544-AC3c: unresolvable perf-log path -> exit 0" \
  || bad "1544-AC3c failed (rc=$RC out=$OUT)"

rm -rf "$AB_HERMETIC"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1532 — executor artifact-KIND leg (`check --enforce-artifact-role-kind`). Reuses the SAME GITROOT +
# $COLLIDE fixture the #1509 block above already built (still alive — the rm -rf below is now AFTER this
# block). AC labels below map to the plan's Binary AC-0..AC-5.
# ════════════════════════════════════════════════════════════════════════════════════════════════════

# AC-0 / AC-1 RED-both-ends (predicate a, the EXACT #1494 shape): reuse TSID4/1509ex2 built directly above —
# its executor row's artifact_path is LITERALLY the planner's own resolved path ($COLLIDE). Base `check`
# (no flag) exits 0 TODAY (the bug is genuinely live); the SAME fixture under --enforce-artifact-role-kind
# exits 2 with a KIND: problem naming the executor + the #1494 shape.
OUT=$(node "$LED" check --session "$TSID4" --task 1509ex2 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[proof] 1532-AC1 RED: #1494-shaped executor==planner fixture -> base check (no flag) still exit 0 (bug genuinely live)" \
  || bad "1532-AC1 RED failed (rc=$RC out=$OUT)"
OUT=$(node "$LED" check --session "$TSID4" --task 1509ex2 --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "KIND:" && echo "$OUT" | grep -qi "executor" && echo "$OUT" | grep -qi "1494"; } \
  && ok "[proof] 1532-AC0/AC1 GREEN: SAME #1494-shaped fixture -> --enforce-artifact-role-kind exit 2, KIND: names executor + the #1494 shape" \
  || bad "1532-AC0/AC1 GREEN failed (rc=$RC out=$OUT)"

# AC-1 predicate (b): executor cites a DIFFERENT plan-kind file (not literally the planner's own path, but
# still on a /.ai-workspace/plans/ segment) -> also KIND-blocked.
printf '## ELI5\na DIFFERENT plan-kind doc, not the planner row\n### Binary AC\n- AC1\n' > "$GITROOT/.ai-workspace/plans/1532-other-plan.md"
( cd "$GITROOT" && git add .ai-workspace/plans/1532-other-plan.md && git commit -q -m "fixture: 1532 predicate-b plan-kind doc" )
TSID5="sess-1532-predb"
mk_sub "$TSID5" bp1; mk_sub "$TSID5" br1; mk_sub "$TSID5" be1; mk_sub "$TSID5" bv1
node "$LED" append --session "$TSID5" --task 1532b --role planner --agent bp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID5" --task 1532b --role plan-review --agent br1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID5" --task 1532b --role executor --agent be1 --artifact "$GITROOT/.ai-workspace/plans/1532-other-plan.md" >/dev/null
node "$LED" append --session "$TSID5" --task 1532b --role execution-review --agent bv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID5" --task 1532b --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "KIND:" && echo "$OUT" | grep -qi "plans"; } \
  && ok "[proof] 1532-AC1 predicate-b: executor cites a DIFFERENT plans/-segment doc (not literally the planner's path) -> KIND BLOCK" \
  || bad "1532-AC1 predicate-b failed (rc=$RC out=$OUT)"

# AC-2 GREEN (hard constraint): executor cites a valid PR URL -> --enforce-artifact-role-kind exit 0, no
# KIND:/TRACKED: problem for the executor (the leg must NEVER existence-/git-check a real ship reference).
TSID6="sess-1532-prurl"
mk_sub "$TSID6" up1; mk_sub "$TSID6" ur1; mk_sub "$TSID6" ue1; mk_sub "$TSID6" uv1
node "$LED" append --session "$TSID6" --task 1532c --role planner --agent up1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID6" --task 1532c --role plan-review --agent ur1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID6" --task 1532c --role executor --agent ue1 --artifact "https://github.com/owner/repo/pull/1140" >/dev/null
node "$LED" append --session "$TSID6" --task 1532c --role execution-review --agent uv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID6" --task 1532c --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && ! echo "$OUT" | grep -q "KIND:"; } \
  && ok "[proof] 1532-AC2 GREEN: PR-URL executor -> exit 0, never KIND-checked (hard constraint)" \
  || bad "1532-AC2 PR-URL executor should never be KIND-blocked (rc=$RC out=$OUT)"

# AC-3 GREEN: executor cites a bare commit-sha-shaped / "PR #N" string -> exit 0, never KIND-checked.
TSID7="sess-1532-sha"
mk_sub "$TSID7" sp1; mk_sub "$TSID7" sr1; mk_sub "$TSID7" se1; mk_sub "$TSID7" sv1
node "$LED" append --session "$TSID7" --task 1532d --role planner --agent sp1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID7" --task 1532d --role plan-review --agent sr1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID7" --task 1532d --role executor --agent se1 --artifact "a1b2c3d4e5f6789012345678901234567890abcd" >/dev/null
node "$LED" append --session "$TSID7" --task 1532d --role execution-review --agent sv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID7" --task 1532d --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && ! echo "$OUT" | grep -q "KIND:"; } \
  && ok "[proof] 1532-AC3 GREEN: bare commit-sha executor -> exit 0, never KIND-checked" \
  || bad "1532-AC3 commit-sha executor should never be KIND-blocked (rc=$RC out=$OUT)"
OUT=$(node "$LED" check --session "$TSID3" --task 1509pr --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && ! echo "$OUT" | grep -q "KIND:"; } \
  && ok "[proof] 1532-AC3b GREEN: \"PR #1509\" string executor -> exit 0, never KIND-checked" \
  || bad "1532-AC3b PR-string executor should never be KIND-blocked (rc=$RC out=$OUT)"

# AC-4 GREEN (false-positive guard): a genuinely executor-authored NON-plan disk doc (SKILL.md-shaped, no
# PLAN_RE heading, off any /.ai-workspace/plans/ segment) -> exit 0, NOT blocked (guards against an over-broad
# "block any disk path" regression that would brick the ~42 historical executor-authored doc rows).
mkdir -p "$GITROOT/skills/foo"
printf 'A skill doc the executor genuinely wrote.\nNo plan heading here — just prose.\n' > "$GITROOT/skills/foo/SKILL.md"
( cd "$GITROOT" && git add skills/foo/SKILL.md && git commit -q -m "fixture: 1532-AC4 executor-authored non-plan doc" )
TSID8="sess-1532-ac4"
mk_sub "$TSID8" np1; mk_sub "$TSID8" nr1; mk_sub "$TSID8" ne1; mk_sub "$TSID8" nv1
node "$LED" append --session "$TSID8" --task 1532e --role planner --agent np1 --artifact "$COLLIDE" >/dev/null
node "$LED" append --session "$TSID8" --task 1532e --role plan-review --agent nr1 --artifact "$GITROOT/.ai-workspace/reviews/1515-planreview.md" >/dev/null
node "$LED" append --session "$TSID8" --task 1532e --role executor --agent ne1 --artifact "$GITROOT/skills/foo/SKILL.md" >/dev/null
node "$LED" append --session "$TSID8" --task 1532e --role execution-review --agent nv1 --artifact "$GITROOT/.ai-workspace/reviews/1515-execreview.md" >/dev/null
OUT=$(node "$LED" check --session "$TSID8" --task 1532e --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK" && ! echo "$OUT" | grep -q "KIND:"; } \
  && ok "[proof] 1532-AC4 GREEN: executor-authored non-plan SKILL.md (off plans/, no PLAN_RE heading) -> exit 0, NOT blocked" \
  || bad "1532-AC4 false-positive guard failed (rc=$RC out=$OUT)"

# AC-5(a): the KIND leg is executor-SCOPED — planner / plan-review / execution-review rows are untouched by
# it (already implicitly proven by every ALLOW case above still resolving to exit 0/OK under the flag).
# AC-5(b): the REJECTED "no two roles cite the same path" rule was deliberately NOT built — reuse TSID3/1509pr
# (the plan-review==planner collision fixture built in the #1509 block above) WITH the new flag on.
OUT=$(node "$LED" check --session "$TSID3" --task 1509pr --enforce-artifact-role-kind 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "[proof] 1532-AC5: plan-review==planner collision under --enforce-artifact-role-kind -> STILL exit 0 (the same-path rule was NOT built; the leg is executor-only)" \
  || bad "1532-AC5 same-path-rule-not-built proof failed (rc=$RC out=$OUT)"

rm -rf "$GITROOT" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1575 AC-4j (HERO) — per-role UNIFORMITY MATRIX for the 1a terminal-evidence guard. For EACH role R in
# REQUIRED_ROLES (planner / plan-review / executor / execution-review, `3role-ledger.mjs:185`), build a
# FRESH ledger fixture and run BOTH legs: (i) clause-1 (verdict-less ERASE via skip_reason) and (ii) clause-2
# (bare verdict-FLIP). Every cell is buildable via the plain helper (no raw writes -- cmdAppend accepts
# --verdict for any RECORDABLE role, the overlay has no role branch). This closes the whole class at once: a
# role-scoped (e.g. plan-review-only) implementation of either clause is mechanically rejected the instant
# ANY one role's cell exits 0 instead of NONZERO.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC4J_ROLES="planner plan-review executor execution-review"
for R in $AC4J_ROLES; do
  # -- clause-1 leg: seed a completed BLOCK for role R, then a verdict-LESS skip append.
  AJSID="sess-ac4j-c1-$R"; AJTASK="ac4j-c1"
  AJFILE="$THREE_ROLE_LEDGER_DIR/$AJSID/$AJTASK.jsonl"
  node "$LED" append --session "$AJSID" --task "$AJTASK" --role "$R" --agent "agR-$R" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK >/dev/null 2>&1
  seedCount=$(grep -Ec '"verdict":"BLOCK"' "$AJFILE" 2>/dev/null)
  SKIP_OUT=$(node "$LED" append --session "$AJSID" --task "$AJTASK" --role "$R" --skip-reason "a specific reason, twenty-plus characters long" 2>&1); SKIP_RC=$?
  afterCount=$(grep -Ec '"verdict":"BLOCK"' "$AJFILE" 2>/dev/null)
  ctrlCount=$(printf '%s\n' '{"role":"x","verdict":"BLOCK"}' | grep -Ec '"verdict":"BLOCK"')
  { [ "$seedCount" = "1" ] && [ "$SKIP_RC" != "0" ] && [ "$afterCount" = "1" ] && [ "$ctrlCount" = "1" ]; } \
    && ok "AC-4j clause-1 role=$R: verdict-less skip append onto a completed verdict is REFUSED, verdict preserved (positive control included)" \
    || bad "AC-4j clause-1 role=$R FAILED (seed=$seedCount skipRc=$SKIP_RC after=$afterCount ctrl=$ctrlCount out=$SKIP_OUT)"

  # -- clause-2 leg: same terminal fixture (fresh task id), then a bare verdict-flip (no --agent/--closed-at).
  AJTASK2="ac4j-c2"
  AJFILE2="$THREE_ROLE_LEDGER_DIR/$AJSID/$AJTASK2.jsonl"
  node "$LED" append --session "$AJSID" --task "$AJTASK2" --role "$R" --agent "agR2-$R" --closed-at "2026-07-11T00:00:00.000Z" --verdict BLOCK >/dev/null 2>&1
  FLIP_OUT=$(node "$LED" append --session "$AJSID" --task "$AJTASK2" --role "$R" --verdict PASS 2>&1); FLIP_RC=$?
  blockCount=$(grep -Ec '"verdict":"BLOCK"' "$AJFILE2" 2>/dev/null)
  passCount=$(grep -Ec '"verdict":"PASS"' "$AJFILE2" 2>/dev/null)
  { [ "$FLIP_RC" != "0" ] && [ "$blockCount" = "1" ] && [ "$passCount" = "0" ]; } \
    && ok "AC-4j clause-2 role=$R: bare verdict-flip is REFUSED, BLOCK survives, PASS never lands" \
    || bad "AC-4j clause-2 role=$R FAILED (flipRc=$FLIP_RC block=$blockCount pass=$passCount out=$FLIP_OUT)"
done

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1580 AC-2 — Bug A RESIDUAL closed: the clear-list is monotonic BY CONSTRUCTION (extends #1575's
# prior.verdict-only trigger to the full terminal-evidence class — see priorHasTerminalEvidence()). Dedicated
# EXECUTOR-COMPLETED-ROW case: executor rows NEVER carry a verdict, so #1575's guard was structurally BLIND
# to them (`3role-ledger.mjs` line ~1126 pre-fix: `if (prior && prior.verdict)`).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC2SID="sess-1580-ac2"
mk_sub "$AC2SID" ac2e1

# AC-2a (the RE-TARGETED RED, now GREEN): a completed executor row (agentId+artifact_path+closedAt+
# self_authored, NO verdict) -> a skip_reason append is REJECTED (nonzero exit) and the terminal fields
# SURVIVE untouched.
AC2F="$THREE_ROLE_LEDGER_DIR/$AC2SID/ac2a.jsonl"
node "$LED" append --session "$AC2SID" --task ac2a --role executor --agent ac2e1 --artifact "PR #1580" --closed-at "2026-07-16T00:00:00.000Z" --self-authored >/dev/null
AC2A_OUT=$(node "$LED" append --session "$AC2SID" --task ac2a --role executor --skip-reason "no longer needed, superseded" 2>&1); AC2A_RC=$?
{ [ "$AC2A_RC" != "0" ] && grep -q '"closedAt"' "$AC2F" && grep -q '"agentId":"ac2e1"' "$AC2F" && grep -q '"artifact_path"' "$AC2F"; } \
  && ok "#1580 AC-2a: skip over a COMPLETED EXECUTOR row (no verdict) is REJECTED — terminal fields survive (Bug A residual closed)" \
  || bad "#1580 AC-2a FAILED (rc=$AC2A_RC ledger=$(cat "$AC2F" 2>/dev/null) err=$AC2A_OUT)"

# AC-2b: skip over a BARE outcome-less spawn (agentId only, no terminal field) still SUCCEEDS — the
# legitimate clear/upgrade direction is preserved; this is not a blanket ban.
mk_sub "$AC2SID" ac2e2
AC2F2="$THREE_ROLE_LEDGER_DIR/$AC2SID/ac2b.jsonl"
node "$LED" append --session "$AC2SID" --task ac2b --role executor --agent ac2e2 >/dev/null
AC2B_OUT=$(node "$LED" append --session "$AC2SID" --task ac2b --role executor --skip-reason "spawn never produced a run, safe to clear" 2>&1); AC2B_RC=$?
{ [ "$AC2B_RC" = "0" ] && grep -q '"skip_reason"' "$AC2F2" && ! grep -q '"agentId"' "$AC2F2"; } \
  && ok "#1580 AC-2b: skip over a BARE outcome-less spawn (agentId only) still SUCCEEDS (upgrade direction preserved)" \
  || bad "#1580 AC-2b FAILED (rc=$AC2B_RC ledger=$(cat "$AC2F2" 2>/dev/null) err=$AC2B_OUT)"

# AC-2c (plan-review non-blocking note 1): spawn-time ASSIGNED provenance (modelVersion/modelTier/effort)
# alone is NOT terminal — a skip over a row carrying ONLY agentId + assigned model/effort (no artifact/
# closedAt/self_authored/oracle/verdict) still SUCCEEDS.
mk_sub "$AC2SID" ac2e3
AC2F3="$THREE_ROLE_LEDGER_DIR/$AC2SID/ac2c.jsonl"
node "$LED" append --session "$AC2SID" --task ac2c --role executor --agent ac2e3 --model-version "claude-sonnet-5" --model-tier sonnet --effort high >/dev/null
AC2C_OUT=$(node "$LED" append --session "$AC2SID" --task ac2c --role executor --skip-reason "assigned but never ran" 2>&1); AC2C_RC=$?
{ [ "$AC2C_RC" = "0" ] && grep -q '"skip_reason"' "$AC2F3" && ! grep -q '"modelVersion"' "$AC2F3" && ! grep -q '"effort"' "$AC2F3"; } \
  && ok "#1580 AC-2c: skip over ASSIGNED-only provenance (modelVersion/modelTier/effort, no other terminal field) still SUCCEEDS" \
  || bad "#1580 AC-2c FAILED (rc=$AC2C_RC ledger=$(cat "$AC2F3" 2>/dev/null) err=$AC2C_OUT)"

# AC-2d (no-duplicate-guard witness): #1575's own verdict-case skip-rejection is UNCHANGED by the widened
# trigger (same guard, extended predicate — already exercised end-to-end by the pre-existing AC-4j block
# above; this re-confirms in isolation that widening priorHasTerminalEvidence() didn't alter the verdict arm).
AC2VSID="sess-1580-ac2-verdict"
node "$LED" append --session "$AC2VSID" --task ac2v --role plan-review --agent ac2v1 --closed-at "2026-07-16T00:00:00.000Z" --verdict BLOCK >/dev/null 2>&1
AC2V_OUT=$(node "$LED" append --session "$AC2VSID" --task ac2v --role plan-review --skip-reason "n/a" 2>&1); AC2V_RC=$?
{ [ "$AC2V_RC" != "0" ] && grep -q '"verdict":"BLOCK"' "$THREE_ROLE_LEDGER_DIR/$AC2VSID/ac2v.jsonl"; } \
  && ok "#1580 AC-2d: #1575's verdict-case skip-rejection is UNCHANGED (same guard, extended trigger)" \
  || bad "#1580 AC-2d FAILED (rc=$AC2V_RC out=$AC2V_OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1580 AC-3 — Bug B closed: multi-round seat. Round-1 (agent RA1, verdict BLOCK, model M1) is superseded
# by a genuinely NEW round-2 (distinct, spawn-record-BOUND agent RA2, verdict PASS, model M2, a strictly-
# newer closedAt) satisfying BOTH #1575 clause 2's own attributed-supersede requirement AND #1580's
# round-boundary signal (the plan's documented "Bug B <-> clause 2 interop" — never weakened). Both rounds'
# observed models must remain RETRIEVABLE; the gate-state read must reflect only the LATEST round.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC3SID="sess-1580-ac3"; AC3TASK="ac3round"
AC3F="$THREE_ROLE_LEDGER_DIR/$AC3SID/$AC3TASK.jsonl"
mk_tagged "$AC3SID" "ac3-ra1" "$AC3TASK" "plan-review"
mk_tagged "$AC3SID" "ac3-ra2" "$AC3TASK" "plan-review"
# round-1: spawn, then close with verdict BLOCK + model M1 (two separate calls — the real spawn-hook /
# close-hook shape).
node "$LED" append --session "$AC3SID" --task "$AC3TASK" --role plan-review --agent ac3-ra1 --model-version "MODEL-ONE" >/dev/null
node "$LED" append --session "$AC3SID" --task "$AC3TASK" --role plan-review --agent ac3-ra1 --verdict BLOCK --closed-at "2026-07-16T00:00:00.000Z" --model-version "MODEL-ONE" >/dev/null
# round-2: a genuinely NEW spawn (distinct, tag-bound agent), then close with verdict PASS + model M2 + a
# strictly-newer closedAt.
node "$LED" append --session "$AC3SID" --task "$AC3TASK" --role plan-review --agent ac3-ra2 --model-version "MODEL-TWO" >/dev/null
AC3_OUT=$(node "$LED" append --session "$AC3SID" --task "$AC3TASK" --role plan-review --agent ac3-ra2 --verdict PASS --closed-at "2026-07-16T01:00:00.000Z" --model-version "MODEL-TWO" 2>&1); AC3_RC=$?
lines3=$(grep -c '"role":"plan-review"' "$AC3F")
{ [ "$AC3_RC" = "0" ] && [ "$lines3" = "2" ] && grep -q "MODEL-ONE" "$AC3F" && grep -q "MODEL-TWO" "$AC3F"; } \
  && ok "#1580 AC-3: round-1 (M1/BLOCK) retained as history, round-2 (M2/PASS) is its own line — BOTH models retrievable" \
  || bad "#1580 AC-3 retrievability FAILED (rc=$AC3_RC lines=$lines3 ledger=$(cat "$AC3F" 2>/dev/null) err=$AC3_OUT)"
# gate-state = LATEST round: the shared byRole[j.role]=j last-wins read (cmdCheck/cmdInherit's own contract)
# must see round-2's PASS, never round-1's stale BLOCK.
LASTVERDICT=$(node -e '
  const fs=require("fs");
  const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(l=>l.trim());
  const byRole={};
  for (const ln of lines){ try { const j=JSON.parse(ln); if(j&&j.role) byRole[j.role]=j; } catch(e){} }
  process.stdout.write(String((byRole["plan-review"]||{}).verdict||""));
' "$AC3F")
{ [ "$LASTVERDICT" = "PASS" ]; } \
  && ok "#1580 AC-3: gate-state read (byRole last-wins, cmdCheck's own contract) reflects the LATEST round (PASS), not round-1's stale BLOCK" \
  || bad "#1580 AC-3 gate-state FAILED (last-wins verdict=$LASTVERDICT)"
GATE_OUT=$(node "$LED" gate-plan-review --session "$AC3SID" --task "$AC3TASK" 2>&1); GATE_RC=$?
{ [ "$GATE_RC" = "0" ]; } \
  && ok "#1580 AC-3: gate-plan-review ALLOWS on the latest (round-2 PASS) row" \
  || bad "#1580 AC-3 gate-plan-review FAILED (rc=$GATE_RC out=$GATE_OUT)"

# AC-3b (Bug B <-> #1575 clause 2 interop, SINGLE combined call): round-2's spawn+close arrive as ONE
# command (--agent + --verdict + --closed-at together) directly over round-1's still-active BLOCK row —
# proving the round-boundary transition and clause 2's bound/distinct/newer-closedAt check compose
# correctly in the SAME write, not just across two separate calls.
AC3BSID="sess-1580-ac3b"; AC3BTASK="ac3bround"
AC3BF="$THREE_ROLE_LEDGER_DIR/$AC3BSID/$AC3BTASK.jsonl"
mk_tagged "$AC3BSID" "ac3b-ra1" "$AC3BTASK" "plan-review"
mk_tagged "$AC3BSID" "ac3b-ra2" "$AC3BTASK" "plan-review"
node "$LED" append --session "$AC3BSID" --task "$AC3BTASK" --role plan-review --agent ac3b-ra1 --verdict BLOCK --closed-at "2026-07-16T00:00:00.000Z" --model-version "MODEL-ONE" >/dev/null
AC3B_OUT=$(node "$LED" append --session "$AC3BSID" --task "$AC3BTASK" --role plan-review --agent ac3b-ra2 --verdict PASS --closed-at "2026-07-16T01:00:00.000Z" --model-version "MODEL-TWO" 2>&1); AC3B_RC=$?
lines3b=$(grep -c '"role":"plan-review"' "$AC3BF")
{ [ "$AC3B_RC" = "0" ] && [ "$lines3b" = "2" ] && grep -q '"verdict":"BLOCK"' "$AC3BF" && grep -q '"verdict":"PASS"' "$AC3BF"; } \
  && ok "#1580 AC-3b: single-call round-2 (agent+verdict+closed-at together) over an active BLOCK row -> clause-2 bound-check AND round-boundary compose correctly" \
  || bad "#1580 AC-3b FAILED (rc=$AC3B_RC lines=$lines3b ledger=$(cat "$AC3BF" 2>/dev/null) err=$AC3B_OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1580 AC-4 — compose regression (REQUIRED, #855 preserved): spawn-then-close AND close-then-spawn EACH
# yield exactly ONE merged row for the role, order-independent. Plan-review non-blocking note 2: close-
# then-spawn is the HARD direction for a "new distinct agentId opens a round" heuristic — a close arriving
# BEFORE its spawn must still MERGE into the same round, never open a spurious second round.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC4SID="sess-1580-ac4"

# AC-4a: spawn-then-close, single round -> ONE line, both fields.
mk_sub "$AC4SID" ac4e1
node "$LED" append --session "$AC4SID" --task ac4a --role executor --agent ac4e1 >/dev/null
node "$LED" append --session "$AC4SID" --task ac4a --role executor --artifact "PR #1580a" >/dev/null
AC4AF="$THREE_ROLE_LEDGER_DIR/$AC4SID/ac4a.jsonl"
n4a=$(grep -c '"role":"executor"' "$AC4AF"); both4a=$(both_on_line "$AC4AF" '"agentId":"ac4e1"' '"artifact_path":')
{ [ "$n4a" = "1" ] && [ "$both4a" = "1" ]; } && ok "#1580 AC-4a: spawn-then-close -> ONE merged row" || bad "#1580 AC-4a FAILED (lines=$n4a both=$both4a)"

# AC-4b (the HARD direction): close-then-spawn, single round -> STILL ONE line, both fields (the close's
# artifact-only row must not be mistaken by the later spawn for "a prior round" — prior.agentId is absent,
# so the round-boundary check never fires and the spawn correctly MERGES).
mk_sub "$AC4SID" ac4e2
node "$LED" append --session "$AC4SID" --task ac4b --role executor --artifact "PR #1580b" >/dev/null
node "$LED" append --session "$AC4SID" --task ac4b --role executor --agent ac4e2 >/dev/null
AC4BF="$THREE_ROLE_LEDGER_DIR/$AC4SID/ac4b.jsonl"
n4b=$(grep -c '"role":"executor"' "$AC4BF"); both4b=$(both_on_line "$AC4BF" '"agentId":"ac4e2"' '"artifact_path":')
{ [ "$n4b" = "1" ] && [ "$both4b" = "1" ]; } && ok "#1580 AC-4b (hard direction): close-then-spawn -> STILL ONE merged row (no spurious new round)" || bad "#1580 AC-4b FAILED (lines=$n4b both=$both4b)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #1590 — MONOTONICITY TRIPWIRE. THE RULE (census `.ai-workspace/reviews/1590-monotonicity-census.md`):
# a bare assertion (skip_reason) must NEVER erase attributable, checkable evidence (agentId+artifact_path,
# closedAt, oracle, verdict, self_authored). Both-ends-boolean, proven against TWO code snapshots:
#   RED  -- the PINNED pre-#1580 blob (`git show 0ba0e4233:hooks/3role-ledger.mjs`, the exact master SHA
#           the #1590 census probed live): overlayAppend's clear-list unconditionally erases those fields
#           on ANY skip_reason append, no guard existed for a verdict-less completed row.
#   GREEN -- current code: #1580's terminal-evidence guard REFUSES the same append (nonzero exit),
#           evidence fields PRESERVED.
# A third fixture (named literally `run-supersedes-skip`, AC6) proves the guard does NOT false-fire on
# the legitimate UPGRADE arm -- a real run clearing a stale skip is SUPERSESSION (legal per THE RULE) and
# must stay green on BOTH code snapshots. #1590 does not edit 3role-ledger.mjs (AC8 scope fence) -- this
# section only RUNS it (current + a `git show`-extracted read-only snapshot of the pinned pre-fix blob).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# The pinned pre-#1580 blob is looked up in THIS repo's own git history -- honest by construction: in the
# ai-brain canonical repo, 0ba0e4233 is a real reachable ancestor of master (the exact SHA the #1590 census
# probed live), so the RED-power proof below is authoritative there. In the three-role-model PLUGIN repo
# (a separate GitHub repo with its OWN commit graph -- this file is a byte-identical deterministic PORT, not
# a git-history fork), that SHA is legitimately unreachable, so the RED leg fails OPEN to an informational
# SKIP rather than a false FAIL -- mirrors this file's existing can't-tell fail-open style (e.g. isGitTracked
# returning null on a non-repo/128 exit). The GREEN leg and the run-supersedes-skip POST leg are
# repo-independent and always run for real in both repos.
REPO_ROOT="$(cd "$DIR/.." && pwd)"
MONO_PREFIX_SHA="0ba0e4233"
MONO_PREFIX_LED="$TMP/3role-ledger-prefix-$MONO_PREFIX_SHA.mjs"
MONO_PREFIX_AVAILABLE=0
if git -C "$REPO_ROOT" cat-file -e "$MONO_PREFIX_SHA:hooks/3role-ledger.mjs" >/dev/null 2>&1; then
  git -C "$REPO_ROOT" show "$MONO_PREFIX_SHA:hooks/3role-ledger.mjs" > "$MONO_PREFIX_LED" 2>/dev/null
  [ -s "$MONO_PREFIX_LED" ] && MONO_PREFIX_AVAILABLE=1
fi

# monotonicity-tripwire-red / monotonicity-tripwire-green: the erasure fixture.
if [ "$MONO_PREFIX_AVAILABLE" = "1" ]; then
  MONODIR_PRE="$TMP/mono-erasure-pre"
  ( export THREE_ROLE_LEDGER_DIR="$MONODIR_PRE"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-pre"
    node "$MONO_PREFIX_LED" append --session mono --task erasure-red --role executor \
      --agent monoAgentPre --artifact "tmp/mono.md" --closed-at "2026-07-15T10:00:00Z" >/dev/null 2>&1
    node "$MONO_PREFIX_LED" append --session mono --task erasure-red --role executor \
      --skip-reason "ran it inline myself" >/dev/null 2>&1
  )
  MONO_PRE_FILE="$MONODIR_PRE/mono/erasure-red.jsonl"
  mono_pre_survived=$(grep -c '"agentId":"monoAgentPre"' "$MONO_PRE_FILE" 2>/dev/null); mono_pre_survived="${mono_pre_survived:-0}"
  { [ "$mono_pre_survived" = "0" ]; } \
    && ok "#1590 monotonicity-tripwire-red (pinned pre-#1580 blob $MONO_PREFIX_SHA): a bare skip_reason ERASES a completed executor row's agentId/artifact_path/closedAt -- the live erasure this ticket targets, RED power proven on the pinned SHA today" \
    || bad "#1590 monotonicity-tripwire-red should show erasure on the pinned pre-#1580 blob (agentId survived=$mono_pre_survived, expected 0) -- pre-fix blob behavior drifted, re-verify the $MONO_PREFIX_SHA pin"
else
  ok "#1590 monotonicity-tripwire-red: SKIP -- pinned pre-#1580 blob ($MONO_PREFIX_SHA:hooks/3role-ledger.mjs) not reachable in this repo's git history (expected in the plugin-synced copy, a separate repo whose commit graph does not carry ai-brain's SHAs; the RED-power proof is authoritative in the ai-brain canonical repo)"
fi

MONODIR_POST="$TMP/mono-erasure-post"
( export THREE_ROLE_LEDGER_DIR="$MONODIR_POST"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-post"
  node "$LED" append --session mono --task erasure-green --role executor \
    --agent monoAgentPost --artifact "tmp/mono.md" --closed-at "2026-07-15T10:00:00Z" >/dev/null 2>&1
  node "$LED" append --session mono --task erasure-green --role executor \
    --skip-reason "ran it inline myself" >"$TMP/mono-post-skip.out" 2>&1
  echo $? > "$TMP/mono-post-skip.rc"
)
MONO_POST_FILE="$MONODIR_POST/mono/erasure-green.jsonl"
mono_post_rc=$(cat "$TMP/mono-post-skip.rc" 2>/dev/null || echo 1)
mono_post_survived=$(grep -c '"agentId":"monoAgentPost"' "$MONO_POST_FILE" 2>/dev/null); mono_post_survived="${mono_post_survived:-0}"
{ [ "$mono_post_rc" != "0" ] && [ "$mono_post_survived" = "1" ]; } \
  && ok "#1590 monotonicity-tripwire-green (current code): terminal-evidence guard REFUSES the same skip_reason append (rc=$mono_post_rc), agentId/artifact_path/closedAt PRESERVED" \
  || bad "#1590 monotonicity-tripwire-green should refuse the skip + preserve evidence on current code (rc=$mono_post_rc survived=$mono_post_survived out=$(cat "$TMP/mono-post-skip.out" 2>/dev/null))"

# run-supersedes-skip (AC6): the legitimate UPGRADE arm -- a real run clearing a stale skip -- must stay
# GREEN on BOTH the pinned pre-#1580 blob and current code (the guard must never false-fire on the correct
# sibling arm at overlayAppend, the mutual-exclusion clear at `if (agentId||oracle) delete skip_reason`).
# Vacuously true when the pre-fix blob isn't available in this repo's history (the plugin-repo case above)
# -- there is nothing dishonest here: the upgrade arm being "untested pre-fix" in the plugin repo is not a
# failure, it's the same repo-independence the RED leg already fails open on. When available (ai-brain), it
# is REQUIRED to actually pass -- default is only the escape hatch, never silently overridden when testable.
mono_upgrade_pre_ok=1
if [ "$MONO_PREFIX_AVAILABLE" = "1" ]; then
  mono_upgrade_pre_ok=0
  UPGDIR_PRE="$TMP/mono-run-supersedes-skip-pre"
  ( export THREE_ROLE_LEDGER_DIR="$UPGDIR_PRE"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-upg-pre"
    node "$MONO_PREFIX_LED" append --session mono --task run-supersedes-skip-pre --role planner \
      --skip-reason "not yet started" >/dev/null 2>&1
    node "$MONO_PREFIX_LED" append --session mono --task run-supersedes-skip-pre --role planner \
      --agent monoUpgPre --artifact "$TMP/plan.md" >/dev/null 2>&1
  )
  UPG_PRE_FILE="$UPGDIR_PRE/mono/run-supersedes-skip-pre.jsonl"
  upg_pre_agent=$(grep -c '"agentId":"monoUpgPre"' "$UPG_PRE_FILE" 2>/dev/null); upg_pre_agent="${upg_pre_agent:-0}"
  upg_pre_skip=$(grep -c '"skip_reason"' "$UPG_PRE_FILE" 2>/dev/null); upg_pre_skip="${upg_pre_skip:-0}"
  { [ "$upg_pre_agent" = "1" ] && [ "$upg_pre_skip" = "0" ]; } && mono_upgrade_pre_ok=1
fi
UPGDIR_POST="$TMP/mono-run-supersedes-skip-post"
( export THREE_ROLE_LEDGER_DIR="$UPGDIR_POST"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-upg-post"
  node "$LED" append --session mono --task run-supersedes-skip-post --role planner \
    --skip-reason "not yet started" >/dev/null 2>&1
  node "$LED" append --session mono --task run-supersedes-skip-post --role planner \
    --agent monoUpgPost --artifact "$TMP/plan.md" >/dev/null 2>&1
)
UPG_POST_FILE="$UPGDIR_POST/mono/run-supersedes-skip-post.jsonl"
upg_post_agent=$(grep -c '"agentId":"monoUpgPost"' "$UPG_POST_FILE" 2>/dev/null); upg_post_agent="${upg_post_agent:-0}"
upg_post_skip=$(grep -c '"skip_reason"' "$UPG_POST_FILE" 2>/dev/null); upg_post_skip="${upg_post_skip:-0}"
MONO_UPG_SCOPE="on BOTH the pinned pre-#1580 blob and current code"
[ "$MONO_PREFIX_AVAILABLE" = "1" ] || MONO_UPG_SCOPE="on current code (pre-#1580 blob leg N/A in this repo, see the RED-leg SKIP above)"
{ [ "$mono_upgrade_pre_ok" = "1" ] && [ "$upg_post_agent" = "1" ] && [ "$upg_post_skip" = "0" ]; } \
  && ok "#1590 run-supersedes-skip: the legitimate UPGRADE arm (a real run clearing a stale skip) stays GREEN $MONO_UPG_SCOPE -- the guard does not false-fire on SUPERSESSION" \
  || bad "#1590 run-supersedes-skip should pass $MONO_UPG_SCOPE (pre-ok=$mono_upgrade_pre_ok post-agent=$upg_post_agent post-skip=$upg_post_skip)"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
