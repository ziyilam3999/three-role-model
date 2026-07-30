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

# ---- #2075 AC-23(b) baseline fixture (committed, no git dependency, no network) -----------------
# AC-23(b) below diffs the NEW binary's check() output against the OLD (pre-#2075) binary's output
# on an identical fixture -- proving #2075 is byte-identical on a legacy ledger except for its one
# new PROVENANCE-LEGACY note. Same class of problem, same fix pattern, as the established
# hooks/_fixtures/3role-ledger-pre1580-overlay.mjs / -pre1947-ma2-overlay.mjs (#1833 Bundle 1A / #1947
# M-A-2): the original cut acquired the pre-fix binary via `git show origin/master:...` piped into an
# artifact (the #1833-class shape-i defect) -- MEASURED to fail two ways (#2094): (1) CI runs a
# shallow (depth=1) checkout, so neither `origin/master` nor an on-demand SHA fetch resolves there
# without a live network call; (2) this file is also byte-ported into the separate `three-role-model`
# plugin repo (scripts/sync-three-role-plugin.mjs), whose git history does not contain ai-brain SHAs
# at all, so even a network fetch permanently fails there. Unlike the two sibling fixtures above
# (deliberately a MINIMAL subset -- Rule 17, mechanical-over-bulk, since each targets one narrow
# vulnerable function), AC-23(b)'s claim is GLOBAL byte-identical equivalence across check()'s entire
# legacy-ledger output surface, which can only be honestly tested against the real, complete pre-fix
# implementation (a hand-trimmed subset would silently re-introduce "a re-derived assumption" -- the
# exact risk the original test author's own comment called out). So this fixture is a full, untouched,
# byte-exact `git show 9757d10e1995af123b6a99bb535604a320bb77c0:hooks/3role-ledger.mjs` port (master's
# tip immediately before the #2075 feature commit landed) -- see the fixture file's own header for
# provenance + the do-not-hand-edit / non-decay-guard notes the sibling fixtures also carry.
AC23B_FIXTURE="$DIR/_fixtures/3role-ledger-pre2075-snapshot.mjs"
OLD_LED="$AC23B_FIXTURE"


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
# #2028 — worktreeDangleHint's regex must fire on a WORKTREE PATH REGARDLESS OF A LEADING SLASH: both an
# absolute-embedded `/.claude/worktrees/...` and a bare project-relative `.claude/worktrees/...` (no
# leading slash) must trigger the HINT when `check` can't resolve the artifact on disk. Pre-fix, the
# regex required the literal `/.claude/worktrees/` segment and silently missed the bare-relative case.
# ---------------------------------------------------------------------------
DHSID="sess-dangle-hint"; DHTASK="2028dh"
mk_sub "$DHSID" dhp
node "$LED" append --session "$DHSID" --task "$DHTASK" --role planner --agent dhp \
  --artifact ".claude/worktrees/2028-fake-slug/.ai-workspace/plans/does-not-exist.md" >/dev/null
OUT=$(node "$LED" check --session "$DHSID" --task "$DHTASK" 2>&1)
echo "$OUT" | grep -q 'HINT: this path points inside a git worktree subtree' \
  && ok "#2028 worktreeDangleHint fires on a BARE project-relative .claude/worktrees/ path (no leading slash)" \
  || bad "#2028 dangle hint should fire on a bare-relative worktree path (got: $OUT)"

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

# 21b. (#1868) WRONG-CWD append: the SAME relative `.ai-workspace/`-prefixed artifact, appended from cwd Y
#     where the file does NOT exist (a role's Bash cwd landed in the wrong repo). On the pre-#1868 code this
#     silently resolved to an ABSOLUTE path under Y anyway (no existence check on this branch) -- a
#     plausible-looking but WRONG-REPO path that a later `check` can never find. The fix falls back to
#     storing the value VERBATIM, deferring resolution to check-time (which may run from the right cwd).
mk_sub "$SID" ypl
( cd "$CWDY" && env -u CLAUDE_PROJECT_DIR node "$LED" append --session "$SID" --task 1199y --role planner \
    --agent ypl --artifact ".ai-workspace/reviews/plan.md" >/dev/null )
YF="$THREE_ROLE_LEDGER_DIR/$SID/1199y.jsonl"
grep -q '"artifact_path":".ai-workspace/reviews/plan.md"' "$YF" \
  && ok "#1868 wrong-cwd append: non-existent-under-cwd artifact stored VERBATIM (not mangled into a wrong-repo absolute path)" \
  || bad "#1868 wrong-cwd append should store verbatim, not a bogus absolute path (got: $(cat "$YF"))"

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

# M9. Fable config lint: orchestrator=fable -> FABLE-ON-ORCHESTRATOR + FABLE-CAP-BUDGET on stderr.
CC_ROLES_ENV="$MFABO" node "$LED" resolve-role-model --role orchestrator 2>"$TMP/mfab.err" >/dev/null
{ [ "$(grep -Ec 'FABLE-ON-ORCHESTRATOR' "$TMP/mfab.err")" -ge 1 ] && [ "$(grep -Ec 'FABLE-CAP-BUDGET' "$TMP/mfab.err")" -ge 1 ]; } \
  && ok "M9 orchestrator=fable -> FABLE-ON-ORCHESTRATOR + FABLE-CAP-BUDGET warnings" || bad "M9 fable-on-orchestrator warnings missing (err=$(cat "$TMP/mfab.err"))"

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
#     FABLE-CAP-BUDGET substring in addition to the RESUME-UPTIER token (never hides the cost).
model_ledger_resume msUPFAB 9306 "claude-sonnet-5" "claude-fable-1"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msUPFAB --task 9306 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qE "NOTE:.*RESUME-UPTIER" && echo "$OUT" | grep -q "FABLE-CAP-BUDGET"; } \
  && ok "[proof] R6 resume-induced up-tier landing on fable -> NOTE carries FABLE-CAP-BUDGET (AC-3)" \
  || bad "R6 fable sub-case must carry FABLE-CAP-BUDGET in the NOTE (rc=$RC out=$OUT)"

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
# #1229 — `reconcile-spawns --session S` MISSING-ROW backfill. AC-0 through AC-6 per
# .ai-workspace/plans/2026-07-23-1229-kanban-board-visibility.md. A tagged transcript carrying the spawn-record
# tag in its FIRST record is the oracle (mk_tagged, defined above); resolve-agent's newest-mtime resolver and
# resolveModelFields() are REUSED (never re-implemented).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
mk_tagged_model() { # <session> <agentId> <task> <role> <modelId>
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  { printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[]}}\n' "$2" "$5"; } \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}
# A tagged transcript that ALSO shows the agent self-appending its own line for --role R (the exact predicate
# three-role-subagent-ledger.sh scans for) -- used by the AC-1b self_authored arm.
mk_tagged_selfauthored() { # <session> <agentId> <task> <role> <modelId>
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  { printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4";
    printf '{"type":"assistant","agentId":"%s","message":{"model":"%s","role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"node hooks/3role-ledger.mjs append --session %s --task %s --role %s --artifact \\"x\\""}}]}}\n' \
      "$2" "$5" "$1" "$3" "$4"; } \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}

# ---- AC-1a: row ABSENT -> row CREATED with {role, agentId, modelVersion, modelTier}. ----
SID_RC="sess-1229-rc"; TASK_RCa="1229a"
RCFILE_A="$THREE_ROLE_LEDGER_DIR/$SID_RC/$TASK_RCa.jsonl"
mk_tagged_model "$SID_RC" rc-e1 "$TASK_RCa" executor "claude-sonnet-5"
OUT_RC1=$(node "$LED" reconcile-spawns --session "$SID_RC" 2>&1); RC_RC1=$?
{ [ "$RC_RC1" = "0" ] && echo "$OUT_RC1" | grep -q "changed=1" \
  && grep -q '"agentId":"rc-e1"' "$RCFILE_A" && grep -q '"modelVersion":"claude-sonnet-5"' "$RCFILE_A" && grep -q '"modelTier":"sonnet"' "$RCFILE_A"; } \
  && ok "#1229 AC-1a: absent row -> CREATED with agentId+modelVersion+modelTier (rc=$RC_RC1)" \
  || bad "#1229 AC-1a failed (rc=$RC_RC1 out=$OUT_RC1 ledger=$(cat "$RCFILE_A" 2>/dev/null))"

# ---- AC-0 (delete-the-input-oracle, live-proof power): removing the fixture transcript + re-running on a
#      FRESH (session,task) with no ledger yet produces NO backfill (no ledger file created at all). ----
SID_RC0="sess-1229-ac0"; TASK_RC0="1229ac0"
mk_tagged_model "$SID_RC0" rc0-e1 "$TASK_RC0" executor "claude-sonnet-5"
rm -f "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC0/subagents/agent-rc0-e1.jsonl"
OUT_RC0=$(node "$LED" reconcile-spawns --session "$SID_RC0" 2>&1); RC_RC0=$?
RC0FILE="$THREE_ROLE_LEDGER_DIR/$SID_RC0/$TASK_RC0.jsonl"
{ [ "$RC_RC0" = "0" ] && [ ! -f "$RC0FILE" ]; } \
  && ok "#1229 AC-0: removing the input transcript before the FIRST run -> NO backfill (power proof: the sweep's power comes from the transcript)" \
  || bad "#1229 AC-0 failed (rc=$RC_RC0 out=$OUT_RC0 ledger-exists=$([ -f "$RC0FILE" ] && echo yes || echo no))"

# ---- AC-2 (idempotent): re-running on the AC-1a ledger reports changed=0 and leaves the file byte-identical.
#      Bump the transcript's mtime (simulating fresh tool activity) so the watermark short-circuit does NOT
#      mask a real no-op scan -- this exercises the "scanned>0, changed=0" path, not just the watermark path.
touch "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC/subagents/agent-rc-e1.jsonl"
BEFORE_RC2="$(cat "$RCFILE_A")"
OUT_RC2=$(node "$LED" reconcile-spawns --session "$SID_RC" 2>&1); RC_RC2=$?
AFTER_RC2="$(cat "$RCFILE_A")"
{ [ "$RC_RC2" = "0" ] && echo "$OUT_RC2" | grep -q "changed=0" && [ "$BEFORE_RC2" = "$AFTER_RC2" ]; } \
  && ok "#1229 AC-2: re-running reconcile-spawns is idempotent (changed=0, ledger byte-identical)" \
  || bad "#1229 AC-2 idempotency failed (rc=$RC_RC2 out=$OUT_RC2 before=$BEFORE_RC2 after=$AFTER_RC2)"

# ---- AC-2b (watermark short-circuit): a SECOND immediate re-run with NO transcript mtime advance also
#      reports success + fail-open with the ledger untouched (the cheap-guard path).
BEFORE_RC2B="$(cat "$RCFILE_A")"
OUT_RC2B=$(node "$LED" reconcile-spawns --session "$SID_RC" 2>&1); RC_RC2B=$?
AFTER_RC2B="$(cat "$RCFILE_A")"
{ [ "$RC_RC2B" = "0" ] && [ "$BEFORE_RC2B" = "$AFTER_RC2B" ]; } \
  && ok "#1229 AC-2b: watermark short-circuit run -> exit 0, ledger untouched" \
  || bad "#1229 AC-2b watermark short-circuit failed (rc=$RC_RC2B out=$OUT_RC2B)"

# ---- AC-1b: row present with {role, artifact_path} but NO agentId (the self-append-only shape) ->
#      agentId+model backfilled, artifact_path UNCHANGED; self_authored:true appears IFF the transcript shows
#      the agent's own `append --role <role>` call.
SID_RC1B="sess-1229-rc1b"; TASK_RC1B="1229b"
RC1BFILE="$THREE_ROLE_LEDGER_DIR/$SID_RC1B/$TASK_RC1B.jsonl"
mk_tagged_selfauthored "$SID_RC1B" rc1b-e1 "$TASK_RC1B" executor "claude-sonnet-5"
node "$LED" append --session "$SID_RC1B" --task "$TASK_RC1B" --role executor --artifact "PR #1229b" >/dev/null
OUT_RC1B=$(node "$LED" reconcile-spawns --session "$SID_RC1B" 2>&1); RC_RC1B=$?
{ [ "$RC_RC1B" = "0" ] \
  && grep -q '"agentId":"rc1b-e1"' "$RC1BFILE" \
  && grep -q '"artifact_path":"PR #1229b"' "$RC1BFILE" \
  && grep -q '"self_authored":true' "$RC1BFILE"; } \
  && ok "#1229 AC-1b: self-append-only row -> agentId+model+self_authored backfilled, artifact_path UNCHANGED (rc=$RC_RC1B)" \
  || bad "#1229 AC-1b failed (rc=$RC_RC1B out=$OUT_RC1B ledger=$(cat "$RC1BFILE" 2>/dev/null))"

# ---- AC-1c (no false self_authored): the SAME shape but WITHOUT the self-append Bash call in the transcript
#      -> agentId+model backfilled, self_authored NEVER appears.
SID_RC1C="sess-1229-rc1c"; TASK_RC1C="1229c"
RC1CFILE="$THREE_ROLE_LEDGER_DIR/$SID_RC1C/$TASK_RC1C.jsonl"
mk_tagged_model "$SID_RC1C" rc1c-e1 "$TASK_RC1C" executor "claude-sonnet-5"
node "$LED" append --session "$SID_RC1C" --task "$TASK_RC1C" --role executor --artifact "PR #1229c" >/dev/null
node "$LED" reconcile-spawns --session "$SID_RC1C" >/dev/null 2>&1
{ grep -q '"agentId":"rc1c-e1"' "$RC1CFILE" && ! grep -q '"self_authored"' "$RC1CFILE"; } \
  && ok "#1229 AC-1c: no self-append call in transcript -> self_authored NEVER stamped (no blind stamp)" \
  || bad "#1229 AC-1c failed (ledger=$(cat "$RC1CFILE" 2>/dev/null))"

# ---- AC-3a: a row already carrying a DIFFERENT real agentId is left byte-UNCHANGED even when a newer tagged
#      transcript for the same (task,role) shows up (the #1580 round-boundary trap; simulates a stray retry). ----
SID_RC3="sess-1229-rc3"; TASK_RC3="1229d"
RC3FILE="$THREE_ROLE_LEDGER_DIR/$SID_RC3/$TASK_RC3.jsonl"
mk_sub "$SID_RC3" rc3-real1
node "$LED" append --session "$SID_RC3" --task "$TASK_RC3" --role planner --agent rc3-real1 --artifact "$TMP/plan.md" >/dev/null
BEFORE_RC3="$(cat "$RC3FILE")"
mk_tagged "$SID_RC3" rc3-stray1 "$TASK_RC3" planner
OUT_RC3=$(node "$LED" reconcile-spawns --session "$SID_RC3" 2>&1); RC_RC3=$?
AFTER_RC3="$(cat "$RC3FILE")"
{ [ "$RC_RC3" = "0" ] && [ "$BEFORE_RC3" = "$AFTER_RC3" ]; } \
  && ok "#1229 AC-3a: a row with a DIFFERENT real agentId is left byte-unchanged (never disturbs a genuine row)" \
  || bad "#1229 AC-3a failed (rc=$RC_RC3 out=$OUT_RC3 before=$BEFORE_RC3 after=$AFTER_RC3)"

# ---- AC-3b: an inline-skip row (skip_reason, no transcript match otherwise) is NEVER touched even when a
#      tagged transcript for that same (task,role) shows up. ----
SID_RC3B="sess-1229-rc3b"; TASK_RC3B="1229e"
RC3BFILE="$THREE_ROLE_LEDGER_DIR/$SID_RC3B/$TASK_RC3B.jsonl"
node "$LED" append --session "$SID_RC3B" --task "$TASK_RC3B" --role planner --skip-reason "not briefable this round" >/dev/null
BEFORE_RC3B="$(cat "$RC3BFILE")"
mk_tagged "$SID_RC3B" rc3b-e1 "$TASK_RC3B" planner
node "$LED" reconcile-spawns --session "$SID_RC3B" >/dev/null 2>&1
AFTER_RC3B="$(cat "$RC3BFILE")"
[ "$BEFORE_RC3B" = "$AFTER_RC3B" ] && ok "#1229 AC-3b: an inline-skip row is NEVER touched even when a transcript later appears" || bad "#1229 AC-3b failed (before=$BEFORE_RC3B after=$AFTER_RC3B)"

# ---- AC-3c: a transcript with NO 3ROLE_TASK tag produces NO row. (The session's ledger DIR may still be
#      created as a side effect of the watermark bookkeeping -- that is not a "row"; assert no *.jsonl task
#      file exists, which is the actual AC-3 property: no board-visible row.) ----
SID_RC3C="sess-1229-rc3c"
mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC3C/subagents"
printf '{"type":"user","message":{"role":"user","content":"just an ordinary message, no tag here"}}\n' \
  > "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC3C/subagents/agent-rc3c-e1.jsonl"
node "$LED" reconcile-spawns --session "$SID_RC3C" >/dev/null 2>&1
rc3c_rows=$(find "$THREE_ROLE_LEDGER_DIR/$SID_RC3C" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$rc3c_rows" = "0" ] && ok "#1229 AC-3c: an untagged transcript produces NO row" || bad "#1229 AC-3c: an untagged transcript should create NO row (found $rc3c_rows)"

# ---- (D) role-enum discipline (plan-review fold-in): a malformed `ROLE:foobar` tag is REJECTED, never filed
#      as a garbage-role row. Validated against the SAME RECORDABLE_ROLES enum cmdAppend's role guard uses.
#      (Same dir-vs-row caveat as AC-3c above -- assert no *.jsonl task file, not "no dir".) ----
SID_RCBAD="sess-1229-rcbad"
mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RCBAD/subagents"
printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:1229z ROLE:foobar -- do the work"}}\n' \
  > "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RCBAD/subagents/agent-rcbad-e1.jsonl"
node "$LED" reconcile-spawns --session "$SID_RCBAD" >/dev/null 2>&1
rcbad_rows=$(find "$THREE_ROLE_LEDGER_DIR/$SID_RCBAD" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
[ "$rcbad_rows" = "0" ] && ok "#1229 (D): malformed ROLE:foobar tag REJECTED (RECORDABLE_ROLES enum validation) -- no row filed" || bad "#1229 (D): a malformed ROLE:foobar tag should never file a row (found $rcbad_rows)"

# ---- AC-4a (fail-open): a nonexistent session -> exit 0, no throw. ----
OUT_RC4A=$(node "$LED" reconcile-spawns --session "sess-1229-no-such-session" 2>&1); RC_RC4A=$?
[ "$RC_RC4A" = "0" ] && ok "#1229 AC-4a: nonexistent session -> fail-open exit 0" || bad "#1229 AC-4a failed (rc=$RC_RC4A out=$OUT_RC4A)"

# ---- AC-4b (fail-open): an unreadable/absent projects root -> exit 0, no throw. ----
OUT_RC4B=$(THREE_ROLE_PROJECTS_ROOT="$TMP/does-not-exist-root-1229" node "$LED" reconcile-spawns --session "$SID_RC" 2>&1); RC_RC4B=$?
[ "$RC_RC4B" = "0" ] && ok "#1229 AC-4b: unreadable projects root -> fail-open exit 0" || bad "#1229 AC-4b failed (rc=$RC_RC4B out=$OUT_RC4B)"

# ---- AC-4c (fail-open): a malformed (non-JSON) transcript never crashes the scan. ----
SID_RC4C="sess-1229-rc4c"
mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC4C/subagents"
printf 'not valid json {{{\n' > "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC4C/subagents/agent-rc4c-e1.jsonl"
OUT_RC4C=$(node "$LED" reconcile-spawns --session "$SID_RC4C" 2>&1); RC_RC4C=$?
[ "$RC_RC4C" = "0" ] && ok "#1229 AC-4c: malformed transcript -> fail-open exit 0, no crash" || bad "#1229 AC-4c failed (rc=$RC_RC4C out=$OUT_RC4C)"

# ---- AC-5 (resync only on change): a run that backfills >=1 row fires kanban-resync.sh exactly once; a
#      no-change run fires it zero times. fireResyncBackground() spawns a DETACHED child with stdio 'ignore'
#      (never inherits this process's stdout), and resolves the script via THIS FILE's own realpath -- so the
#      hermetic proof copies 3role-ledger.mjs (like the #1544 AB_HERMETIC pattern above) into a throwaway dir
#      alongside a STUB kanban-resync.sh that appends "would-sync" to a MARKER FILE (a real side effect,
#      unaffected by stdio:'ignore') instead of echoing to a swallowed stdout.
AC5_DIR="$(mktemp -d)"; mkdir -p "$AC5_DIR/hooks"
cp "$LED" "$AC5_DIR/hooks/3role-ledger.mjs"
cat > "$AC5_DIR/hooks/kanban-resync.sh" <<'RESYNCSTUB'
#!/usr/bin/env bash
echo "would-sync" >> "$RESYNC_MARKER_1229"
exit 0
RESYNCSTUB
chmod +x "$AC5_DIR/hooks/kanban-resync.sh"
LED_AC5="$AC5_DIR/hooks/3role-ledger.mjs"
export RESYNC_MARKER_1229="$AC5_DIR/resync.log"; : > "$RESYNC_MARKER_1229"

SID_RC5="sess-1229-rc5"; TASK_RC5="1229f"
mk_tagged_model "$SID_RC5" rc5-e1 "$TASK_RC5" executor "claude-sonnet-5"
node "$LED_AC5" reconcile-spawns --session "$SID_RC5" >/dev/null 2>&1
sleep 0.3
n5a=$(grep -c . "$RESYNC_MARKER_1229" 2>/dev/null); [ -n "$n5a" ] || n5a=0
[ "$n5a" = "1" ] && ok "#1229 AC-5: a backfilling run fires kanban-resync exactly once" || bad "#1229 AC-5 backfill-fires-once failed (n=$n5a)"

: > "$RESYNC_MARKER_1229"
touch "$THREE_ROLE_PROJECTS_ROOT/proj/$SID_RC5/subagents/agent-rc5-e1.jsonl"
node "$LED_AC5" reconcile-spawns --session "$SID_RC5" >/dev/null 2>&1
sleep 0.3
n5b=$(grep -c . "$RESYNC_MARKER_1229" 2>/dev/null); [ -n "$n5b" ] || n5b=0
[ "$n5b" = "0" ] && ok "#1229 AC-5: a no-change run fires kanban-resync zero times" || bad "#1229 AC-5 no-change-fires-zero failed (n=$n5b)"

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
#   RED  -- a COMMITTED STATIC FIXTURE (#1833 Bundle 1A, hooks/_fixtures/3role-ledger-pre1580-overlay.mjs):
#           a minimal, in-pocket port of the pre-#1580 overlayAppend, byte-behavior-verified against the
#           pinned SHA 0ba0e4233 — its terminal-evidence guard is keyed ONLY on prior.verdict, so a
#           completed EXECUTOR row (agentId+artifact_path+closedAt, no verdict) is erased by a bare
#           skip_reason append. NO git dependency: does not call `git show`/`cat-file`, does not require any
#           ancestor SHA to be reachable — always runs for real (full clone, shallow CI, and the
#           three-role-model plugin repo's own independent commit graph, alike). #1833's whole point: the
#           OLD acquisition (a `cat-file -e <pinned-SHA>:<path>` existence guard around a `show
#           <pinned-SHA>:<path>` extraction, pinned SHA = the ai-brain master ancestor the #1590 census
#           probed live) fail-opened to a vacuous informational SKIP the instant that ancestor was
#           unreachable — this fixture removes that failure mode entirely by carrying the pre-fix behavior
#           in its own pocket instead of fetching it.
#   GREEN -- current code: #1580's terminal-evidence guard (priorHasTerminalEvidence: verdict OR closedAt OR
#           self_authored OR oracle OR a completed agentId+artifact_path pair) REFUSES the same append
#           (nonzero exit), evidence fields PRESERVED.
# A third fixture (named literally `run-supersedes-skip`, AC6) proves the guard does NOT false-fire on
# the legitimate UPGRADE arm -- a real run clearing a stale skip is SUPERSESSION (legal per THE RULE) and
# must stay green on BOTH the pre-fix fixture and current code. #1590 does not edit 3role-ledger.mjs (AC8
# scope fence) -- this section only RUNS it (current code + the committed pre-fix fixture, never a git ref).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
MONO_FIXTURE="$DIR/_fixtures/3role-ledger-pre1580-overlay.mjs"

# monotonicity-tripwire-red / monotonicity-tripwire-green: the erasure fixture.
if [ -s "$MONO_FIXTURE" ]; then
  MONODIR_PRE="$TMP/mono-erasure-pre"
  ( export THREE_ROLE_LEDGER_DIR="$MONODIR_PRE"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-pre"
    node "$MONO_FIXTURE" append --session mono --task erasure-red --role executor \
      --agent monoAgentPre --artifact "tmp/mono.md" --closed-at "2026-07-15T10:00:00Z" >/dev/null 2>&1
    node "$MONO_FIXTURE" append --session mono --task erasure-red --role executor \
      --skip-reason "ran it inline myself" >/dev/null 2>&1
  )
  MONO_PRE_FILE="$MONODIR_PRE/mono/erasure-red.jsonl"
  mono_pre_survived=$(grep -c '"agentId":"monoAgentPre"' "$MONO_PRE_FILE" 2>/dev/null); mono_pre_survived="${mono_pre_survived:-0}"
  { [ "$mono_pre_survived" = "0" ]; } \
    && ok "#1590 monotonicity-tripwire-red (committed pre-#1580 fixture, no git dependency): a bare reason-only append ERASES a completed executor row's agentId/artifact_path/closedAt -- the live erasure this ticket targets, RED power proven hermetically today" \
    || bad "#1590 monotonicity-tripwire-red should show erasure on the pre-#1580 fixture (agentId survived=$mono_pre_survived, expected 0) -- fixture behavior drifted, re-verify hooks/_fixtures/3role-ledger-pre1580-overlay.mjs against pinned SHA 0ba0e4233"
else
  bad "#1590 monotonicity-tripwire-red: FIXTURE MISSING at $MONO_FIXTURE -- this fixture is committed and must always be present (it replaced the old git-object acquisition; its absence means the RED leg cannot prove pre-#1580 erasure at all)"
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
  && ok "#1590 monotonicity-tripwire-green (current code): terminal-evidence guard REFUSES the same reason-only append (rc=$mono_post_rc), agentId/artifact_path/closedAt PRESERVED" \
  || bad "#1590 monotonicity-tripwire-green should refuse the skip + preserve evidence on current code (rc=$mono_post_rc survived=$mono_post_survived out=$(cat "$TMP/mono-post-skip.out" 2>/dev/null))"

# AC3 -- NON-DECAY GUARD (#1833). The pre-#1580 fixture MUST behave DIFFERENTLY from current code (erasure
# vs preserve) on the identical completed-executor-row + skip-reason inputs. If a future edit ever
# regenerated the fixture from live code (accidentally adopting the priorHasTerminalEvidence guard), the
# RED and GREEN arms would collapse to the SAME outcome -- a fixed-vs-fixed tautology, green but proving
# nothing. This assertion is the tripwire for that decay.
{ [ "$mono_pre_survived" != "$mono_post_survived" ]; } \
  && ok "#1833 AC3 non-decay guard: pre-#1580 fixture erasure (agentId survived=$mono_pre_survived) differs from current-code preservation (agentId survived=$mono_post_survived) -- the RED/GREEN split still has power, has not decayed into a tautology" \
  || bad "#1833 AC3 non-decay guard: the pre-#1580 fixture and current code produced the SAME survival outcome (both=$mono_pre_survived) -- the fixture has decayed into a fixed-vs-fixed tautology; do NOT regenerate hooks/_fixtures/3role-ledger-pre1580-overlay.mjs from live code"

# run-supersedes-skip (AC6): the legitimate UPGRADE arm -- a real run clearing a stale skip -- must stay
# GREEN on BOTH the pre-#1580 fixture and current code (the guard must never false-fire on the correct
# sibling arm at overlayAppend, the mutual-exclusion clear at `if (agentId||oracle) delete skip_reason`).
# The fixture is committed and always in-pocket (no reachability escape hatch any more) -- REQUIRED to pass.
UPGDIR_PRE="$TMP/mono-run-supersedes-skip-pre"
( export THREE_ROLE_LEDGER_DIR="$UPGDIR_PRE"; export THREE_ROLE_PROJECTS_ROOT="$TMP/mono-projects-upg-pre"
  node "$MONO_FIXTURE" append --session mono --task run-supersedes-skip-pre --role planner \
    --skip-reason "not yet started" >/dev/null 2>&1
  node "$MONO_FIXTURE" append --session mono --task run-supersedes-skip-pre --role planner \
    --agent monoUpgPre --artifact "$TMP/plan.md" >/dev/null 2>&1
)
UPG_PRE_FILE="$UPGDIR_PRE/mono/run-supersedes-skip-pre.jsonl"
upg_pre_agent=$(grep -c '"agentId":"monoUpgPre"' "$UPG_PRE_FILE" 2>/dev/null); upg_pre_agent="${upg_pre_agent:-0}"
upg_pre_skip=$(grep -c '"skip_reason"' "$UPG_PRE_FILE" 2>/dev/null); upg_pre_skip="${upg_pre_skip:-0}"
mono_upgrade_pre_ok=0
{ [ "$upg_pre_agent" = "1" ] && [ "$upg_pre_skip" = "0" ]; } && mono_upgrade_pre_ok=1

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
{ [ "$mono_upgrade_pre_ok" = "1" ] && [ "$upg_post_agent" = "1" ] && [ "$upg_post_skip" = "0" ]; } \
  && ok "#1590 run-supersedes-skip: the legitimate UPGRADE arm (a real run clearing a stale skip) stays GREEN on BOTH the pre-#1580 fixture and current code -- the guard does not false-fire on SUPERSESSION" \
  || bad "#1590 run-supersedes-skip should pass on both the pre-#1580 fixture and current code (pre-ok=$mono_upgrade_pre_ok post-agent=$upg_post_agent post-skip=$upg_post_skip)"


# ── #1947 AC-11 — the subprocess-openrouter third provenance arm is SSOT-gated and dispatch-bound, not
#    row-asserted. Fixture ledger + fixture transcript, isolated CC_ROUTES_JSON + THREE_ROLE_LEDGER_DIR. ────
OR_FIX="$TMP/or-fixtures"
mkdir -p "$OR_FIX/ledger" "$OR_FIX/transcripts" "$OR_FIX/artifacts"
cat > "$OR_FIX/routes.json" <<'ORJSON'
{
  "seats": {
    "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter", "agent_tool_fallback": "opus" },
    "execution-review": { "provider": "anthropic", "model": "claude-opus-5" }
  }
}
ORJSON
mk_or_transcript() {   # $1=path $2=nonce $3=served-model $4=lead-with-ai-title(0|1)
  node -e '
    const fs = require("fs");
    const [ , outPath, nonce, model, leadTitle ] = process.argv;
    const lines = [];
    if (leadTitle === "1") lines.push(JSON.stringify({ type: "ai-title", aiTitle: "smoke fixture title", sessionId: "or-fixture" }));
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "or-fixture", content: "3ROLE_TASK:t ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview this plan" }));
    lines.push(JSON.stringify({ type: "assistant", message: { model, content: [ { type: "text", text: "ok" } ] } }));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3" "$4"
}

# (a) forged-marker control: role=execution-review carries dispatch=subprocess-openrouter, but the SSOT seat
#     for execution-review has NO dispatch field -> the marker must be IGNORED (fall through to the ordinary
#     arm), not accepted -> BLOCK naming execution-review.
( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
  node "$LED" append --session orFixA --task t --role planner --skip-reason "fixture: not under test in AC-11(a)" >/dev/null
  node "$LED" append --session orFixA --task t --role executor --skip-reason "fixture: not under test in AC-11(a)" >/dev/null
  node "$LED" append --session orFixA --task t --role plan-review --skip-reason "fixture: not under test in AC-11(a)" >/dev/null
  echo "anything" > "$OR_FIX/transcripts/anything.jsonl"
  node "$LED" append --session orFixA --task t --role execution-review --dispatch subprocess-openrouter \
    --transcript "$OR_FIX/transcripts/anything.jsonl" --nonce "OR-NONCE-forged" >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session orFixA --task t 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | grep -qi "execution-review"; } \
  && ok "#1947 AC-11(a) forged-marker control: dispatch=subprocess-openrouter on execution-review (SSOT seat has no dispatch field) -> BLOCK naming execution-review, marker ignored" \
  || bad "#1947 AC-11(a) forged-marker control should BLOCK naming execution-review (rc=$RC out=$OUT)"

# (b) replayed-transcript control: role=plan-review, SSOT-declared subprocess seat, but the named transcript's
#     FIRST record carries a DIFFERENT nonce than this dispatch's own -> BLOCK (M2).
( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
  node "$LED" append --session orFixB --task t --role planner --skip-reason "fixture: not under test in AC-11(b)" >/dev/null
  node "$LED" append --session orFixB --task t --role executor --skip-reason "fixture: not under test in AC-11(b)" >/dev/null
  printf 'Decision: PASS\n' > "$OR_FIX/artifacts/er-b.md"
  node "$LED" append --session orFixB --task t --role execution-review --oracle "$OR_FIX/artifacts/er-b.md" >/dev/null
  mk_or_transcript "$OR_FIX/transcripts/fixB.jsonl" "OR-NONCE-different-run" "moonshotai/kimi-k3" 0
  printf '## Review\nDecision: PASS\nDISPATCH-NONCE:OR-NONCE-THIS-RUN\n' > "$OR_FIX/artifacts/plan-b.md"
  node "$LED" append --session orFixB --task t --role plan-review --dispatch subprocess-openrouter \
    --transcript "$OR_FIX/transcripts/fixB.jsonl" --nonce "OR-NONCE-THIS-RUN" \
    --artifact "$OR_FIX/artifacts/plan-b.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session orFixB --task t 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | grep -qi "plan-review" && echo "$OUT" | grep -qi "M2"; } \
  && ok "#1947 AC-11(b) replayed-transcript control: named transcript's first record nonce != this dispatch's nonce -> BLOCK (M2)" \
  || bad "#1947 AC-11(b) replayed-transcript control should BLOCK on M2 (rc=$RC out=$OUT)"

# (c) well-formed happy path: SSOT-declared seat, first-record tag+nonce present, message.model == SSOT slug,
#     nonce present in the artifact, verdict token present -> the WHOLE task's check exits 0.
( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
  node "$LED" append --session orFixC --task t --role planner --skip-reason "fixture: not under test in AC-11(c)" >/dev/null
  node "$LED" append --session orFixC --task t --role executor --skip-reason "fixture: not under test in AC-11(c)" >/dev/null
  printf 'Decision: PASS\n' > "$OR_FIX/artifacts/er-c.md"
  node "$LED" append --session orFixC --task t --role execution-review --oracle "$OR_FIX/artifacts/er-c.md" >/dev/null
  mk_or_transcript "$OR_FIX/transcripts/fixC.jsonl" "OR-NONCE-THIS-RUN-C" "moonshotai/kimi-k3" 0
  printf '## Review\nDecision: PASS\nDISPATCH-NONCE:OR-NONCE-THIS-RUN-C\n' > "$OR_FIX/artifacts/plan-c.md"
  node "$LED" append --session orFixC --task t --role plan-review --dispatch subprocess-openrouter \
    --transcript "$OR_FIX/transcripts/fixC.jsonl" --nonce "OR-NONCE-THIS-RUN-C" \
    --artifact "$OR_FIX/artifacts/plan-c.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session orFixC --task t 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "#1947 AC-11(c) well-formed plan-review row (SSOT-declared, first-record tag+nonce, served model matches, nonce in artifact) -> check exits 0" \
  || bad "#1947 AC-11(c) well-formed row should exit 0 (rc=$RC out=$OUT)"
# M-B (execution-review round-2 FAIL): the SAME well-formed pass must LABEL the row distinctly in check's own
# output, on the success path -- D2 promised "check output labels these rows distinctly"; previously the
# string appeared only in comments/BLOCK-reason text, never announced on a genuine pass.
{ [ "$RC" = "0" ] && echo "$OUT" | grep -q "role=plan-review dispatch=subprocess-openrouter"; } \
  && ok "#1947 M-B AC-11(c): check's OWN stdout labels the passing subprocess row 'role=plan-review dispatch=subprocess-openrouter' (D2's disclosure promise, not just an exit code)" \
  || bad "#1947 M-B AC-11(c) should print the dispatch=subprocess-openrouter label on the success path (rc=$RC out=$OUT)"

# (d) regression control: a leading {"type":"ai-title",...} bookkeeping record before the real enqueue record
#     must NOT defeat the tag+nonce binding (measured live on #1947 AC-6, session bd8c0aec-...) -> still 0.
( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
  node "$LED" append --session orFixD --task t --role planner --skip-reason "fixture: not under test in AC-11 regression(d)" >/dev/null
  node "$LED" append --session orFixD --task t --role executor --skip-reason "fixture: not under test in AC-11 regression(d)" >/dev/null
  printf 'Decision: PASS\n' > "$OR_FIX/artifacts/er-d.md"
  node "$LED" append --session orFixD --task t --role execution-review --oracle "$OR_FIX/artifacts/er-d.md" >/dev/null
  mk_or_transcript "$OR_FIX/transcripts/fixD.jsonl" "OR-NONCE-THIS-RUN-D" "moonshotai/kimi-k3" 1
  printf '## Review\nDecision: PASS\nDISPATCH-NONCE:OR-NONCE-THIS-RUN-D\n' > "$OR_FIX/artifacts/plan-d.md"
  node "$LED" append --session orFixD --task t --role plan-review --dispatch subprocess-openrouter \
    --transcript "$OR_FIX/transcripts/fixD.jsonl" --nonce "OR-NONCE-THIS-RUN-D" \
    --artifact "$OR_FIX/artifacts/plan-d.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session orFixD --task t 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "#1947 AC-11 regression(d): a leading ai-title bookkeeping record before the real enqueue record does not defeat the M2 tag+nonce binding -> still exits 0" \
  || bad "#1947 AC-11 regression(d) should still exit 0 with a leading ai-title record (rc=$RC out=$OUT)"

# (e) M-A monotonicity control (execution-review round-2 FAIL): a STALE, self-declared
#     dispatch=subprocess-openrouter marker must NEVER outrank a harness-signed, RESOLVING agentId on the SAME
#     row -- reproduces D3's bounded-fallback shape end-to-end: a subprocess plan-review dispatch stamps
#     dispatch/transcript_path/nonce; that Kimi review gets REJECTED (D3's third fallback trigger, "a failed
#     gate check of the plan's AC"); the bounded Anthropic Opus fallback then self-appends a REAL agentId + its
#     OWN artifact + verdict=PASS onto the SAME row. Before the fix, checkSubprocessProvenance kept
#     re-evaluating the SUPERSEDED subprocess evidence (the fallback's artifact never contains the earlier
#     dispatch's nonce) and false-BLOCKed a genuinely-completed plan-review.
( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
  node "$LED" append --session orFixE --task t --role planner --skip-reason "fixture: not under test in AC-11(e)" >/dev/null
  node "$LED" append --session orFixE --task t --role executor --skip-reason "fixture: not under test in AC-11(e)" >/dev/null
  printf 'Decision: PASS\n' > "$OR_FIX/artifacts/er-e.md"
  node "$LED" append --session orFixE --task t --role execution-review --oracle "$OR_FIX/artifacts/er-e.md" >/dev/null
  # Step 1: the subprocess dispatch's OWN spawn-time stamp (a real, validly-bound transcript; nonce N-PR-ORIG).
  mk_or_transcript "$OR_FIX/transcripts/fixE.jsonl" "N-PR-ORIG" "moonshotai/kimi-k3" 0
  node "$LED" append --session orFixE --task t --role plan-review --dispatch subprocess-openrouter \
    --transcript "$OR_FIX/transcripts/fixE.jsonl" --nonce "N-PR-ORIG" >/dev/null
  # Step 2: that dispatch was REJECTED -- the bounded Anthropic Opus FALLBACK self-appends a REAL, resolving
  #    agentId + its own artifact + verdict=PASS onto the SAME row (mirrors mk_sub's real-transcript pattern).
  mk_sub orFixE fallback-agent-e
  printf '## Review\nDecision: PASS\n' > "$OR_FIX/artifacts/plan-e-fallback.md"
  node "$LED" append --session orFixE --task t --role plan-review --agent fallback-agent-e \
    --artifact "$OR_FIX/artifacts/plan-e-fallback.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session orFixE --task t 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -qi "OK"; } \
  && ok "#1947 M-A AC-11(e): a harness-signed, RESOLVING agentId + real artifact + verdict on the SAME row always OUTRANKS a stale subprocess dispatch/transcript/nonce stamp (D3's bounded-fallback shape) -> check exits 0, never a false BLOCK from superseded residue" \
  || bad "#1947 M-A AC-11(e) should exit 0 -- a stale subprocess marker must never outrank a resolving agentId (rc=$RC out=$OUT)"

# (f) M-A-2 Reproduction A (execution-review round-2 FAIL, fix-round 2): the round-2 M-A fix (aa924ff51)
#     introduced a NEW anti-monotonic arm in overlayAppend's own agentId/oracle clear-list -- it cleared
#     dispatch/transcript_path/nonce on mere KEY PRESENCE, never checking the incoming agentId/oracle
#     actually RESOLVES. A NON-resolving (bogus) --agent append therefore erased a completed, nonce-verified
#     subprocess dispatch's evidence just the same as a genuinely-resolving one -- turning a genuinely-
#     completed role into a false BLOCK. Both-ends proof, same #1833/#1590 pattern as the monotonicity
#     tripwire above: RED = the committed pre-fix-round-2 fixture (no git dependency) writes the SAME buggy
#     unconditional-clear row; GREEN = current code (this file) gates the clear on agentResolves. Both rows
#     are then read by the SAME real `check` (current, unmodified checkRole/checkSubprocessProvenance) --
#     the only experimental variable is which engine produced the plan-review row's second append.
MA2_FIXTURE="$DIR/_fixtures/3role-ledger-pre1947-ma2-overlay.mjs"
ma2_setup_common_roles() {   # $1=session
  node "$LED" append --session "$1" --task t --role planner --skip-reason "fixture: not under test in M-A-2 repro" >/dev/null
  node "$LED" append --session "$1" --task t --role executor --skip-reason "fixture: not under test in M-A-2 repro" >/dev/null
  printf 'Decision: PASS\n' > "$OR_FIX/artifacts/er-ma2-$1.md"
  node "$LED" append --session "$1" --task t --role execution-review --oracle "$OR_FIX/artifacts/er-ma2-$1.md" >/dev/null
}

if [ -s "$MA2_FIXTURE" ]; then
  # RED: aa924ff51's buggy engine writes the plan-review row's bogus-agent append -> dispatch fields ERASED
  # on mere presence, even though "bogusagent999" resolves to nothing.
  MA2_RED_SID="orMA2Red"
  ( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
    ma2_setup_common_roles "$MA2_RED_SID"
    mk_or_transcript "$OR_FIX/transcripts/ma2-red.jsonl" "N-E2-red" "moonshotai/kimi-k3" 0
    printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-E2-red\n' > "$OR_FIX/artifacts/plan-ma2-red.md"
    node "$LED" append --session "$MA2_RED_SID" --task t --role plan-review --dispatch subprocess-openrouter \
      --transcript "$OR_FIX/transcripts/ma2-red.jsonl" --nonce "N-E2-red" \
      --artifact "$OR_FIX/artifacts/plan-ma2-red.md" --verdict PASS >/dev/null
    node "$MA2_FIXTURE" append --session "$MA2_RED_SID" --task t --role plan-review --agent bogusagent999 >/dev/null
  )
  RED_OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session "$MA2_RED_SID" --task t 2>&1); RED_RC=$?
  { [ "$RED_RC" = "2" ] && echo "$RED_OUT" | grep -qi 'plan-review agentId "bogusagent999" does not resolve'; } \
    && ok "#1947 M-A-2 Reproduction A RED (committed pre-fix-round-2 fixture, no git dependency): a NON-resolving agentId append unconditionally erases a completed subprocess dispatch's evidence -- reproduces the round-2 review's exact false BLOCK (rc=2)" \
    || bad "#1947 M-A-2 Reproduction A RED should reproduce the false BLOCK rc=2 (rc=$RED_RC out=$RED_OUT) -- re-verify hooks/_fixtures/3role-ledger-pre1947-ma2-overlay.mjs against pinned SHA aa924ff51"

  # GREEN: current code (this file) -- the SAME non-resolving agentId must NOT erase the completed
  # subprocess dispatch's evidence, so check re-validates the ORIGINAL nonce-bound provenance and passes.
  MA2_GREEN_SID="orMA2Green"
  ( export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"
    ma2_setup_common_roles "$MA2_GREEN_SID"
    mk_or_transcript "$OR_FIX/transcripts/ma2-green.jsonl" "N-E2-green" "moonshotai/kimi-k3" 0
    printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-E2-green\n' > "$OR_FIX/artifacts/plan-ma2-green.md"
    node "$LED" append --session "$MA2_GREEN_SID" --task t --role plan-review --dispatch subprocess-openrouter \
      --transcript "$OR_FIX/transcripts/ma2-green.jsonl" --nonce "N-E2-green" \
      --artifact "$OR_FIX/artifacts/plan-ma2-green.md" --verdict PASS >/dev/null
    node "$LED" append --session "$MA2_GREEN_SID" --task t --role plan-review --agent bogusagent999 >/dev/null
  )
  GREEN_OUT=$(export THREE_ROLE_LEDGER_DIR="$OR_FIX/ledger"; export CC_ROUTES_JSON="$OR_FIX/routes.json"; node "$LED" check --session "$MA2_GREEN_SID" --task t 2>&1); GREEN_RC=$?
  { [ "$GREEN_RC" = "0" ] && echo "$GREEN_OUT" | grep -qi "OK"; } \
    && ok "#1947 M-A-2 Reproduction A GREEN (current code, fix-round 2): a NON-resolving agentId append does NOT erase a completed subprocess dispatch's evidence -- check re-validates the ORIGINAL nonce-bound provenance and exits 0, no false BLOCK" \
    || bad "#1947 M-A-2 Reproduction A GREEN should exit 0 -- a non-resolving agentId must never erase verified subprocess provenance (rc=$GREEN_RC out=$GREEN_OUT)"

  # Non-decay guard (mirrors #1833 AC3): RED and GREEN must produce DIFFERENT rc's on the identical
  # sequence, else this pair has collapsed into a fixed-vs-fixed tautology that would pass regardless of
  # whether the fix is actually present.
  { [ "$RED_RC" != "$GREEN_RC" ]; } \
    && ok "#1947 M-A-2 non-decay guard: RED (rc=$RED_RC) differs from GREEN (rc=$GREEN_RC) -- the split still has power, has not decayed into a tautology" \
    || bad "#1947 M-A-2 non-decay guard: RED and GREEN produced the SAME rc ($RED_RC) -- the pair has decayed into a tautology; do NOT regenerate hooks/_fixtures/3role-ledger-pre1947-ma2-overlay.mjs from live code"
else
  bad "#1947 M-A-2 Reproduction A: FIXTURE MISSING at $MA2_FIXTURE -- this fixture is committed and must always be present (it carries aa924ff51's pre-fix-round-2 unconditional clear-list behavior; its absence means the RED leg cannot prove the false BLOCK at all)"
fi

# ── #1989 AC-7/AC-8 — ROUTE-BYPASS trailing-edge detector (Direction 3). Self-contained CC_ROUTES_JSON +
#    THREE_ROLE_LEDGER_DIR fixtures, sibling of the #1947 AC-11 block above. Reuses mk_sub (resolvable agent
#    transcript) + mk_or_transcript's shape (a dedicated helper below writes the tag for THIS task). The
#    detector reads seatDispatchIsSubprocess() (loadRoutesConfig, NOT resolveRoute), so a minimal routes
#    fixture with only the `seats` block suffices (no providers/task_classes needed for THIS leg). ────────
RB_FIX="$TMP/rb-fixtures"
mkdir -p "$RB_FIX/ledger" "$RB_FIX/transcripts" "$RB_FIX/artifacts"
# Fixture declaring plan-review subprocess-openrouter (executor left UNdeclared here so AC-7 fires for
# plan-review only; AC-8(a)'s no-subprocess-seat control uses a SEPARATE fixture below).
cat > "$RB_FIX/routes-pr.json" <<'RBJSON'
{ "seats": { "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter", "agent_tool_fallback": "opus" } } }
RBJSON
# Fixture with NO subprocess-declared seat (AC-8(a) control — plan-review here has no dispatch field).
cat > "$RB_FIX/routes-none.json" <<'RBJSON'
{ "seats": { "plan-review": { "provider": "anthropic", "model": "claude-opus-5" } } }
RBJSON
# mk_rb_or_transcript $path $nonce — a validly-bound subprocess transcript whose FIRST record carries the
# spawn tag (3ROLE_TASK:rb ROLE:plan-review) + this dispatch's nonce, and an assistant line serving the
# SSOT-declared model (the two signals checkSubprocessProvenance binds on).
mk_rb_or_transcript() {
  node -e '
    const fs = require("fs");
    const [ , outPath, nonce ] = process.argv;
    const lines = [];
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "rb-fixture", content: "3ROLE_TASK:rb ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview" }));
    lines.push(JSON.stringify({ type: "assistant", message: { model: "moonshotai/kimi-k3", content: [ { type: "text", text: "ok" } ] } }));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2"
}
# rb_common $session — satisfy planner/executor/execution-review via the ordinary agentId/oracle arm so the
# WHOLE task's `check` reaches the roles-satisfied path where ROUTE-BYPASS prints (plan-review is added per-case).
rb_common() {  # $1=session
  mk_sub "$1" rb-P; mk_sub "$1" rb-E; mk_sub "$1" rb-V
  node "$LED" append --session "$1" --task rb --role planner --agent rb-P --artifact "$TMP/plan.md" >/dev/null
  node "$LED" append --session "$1" --task rb --role executor --agent rb-E --artifact "PR #rb" >/dev/null
  printf 'Decision: PASS\n' > "$RB_FIX/artifacts/er-$1.md"
  node "$LED" append --session "$1" --task rb --role execution-review --oracle "$RB_FIX/artifacts/er-$1.md" >/dev/null
}
RB_LED() { echo "$RB_FIX/ledger/$1/rb.jsonl"; }

# ---- AC-7: a fixture ledger whose four roles all satisfy `check` via ordinary arms, under a CC_ROUTES_JSON
#      declaring plan-review subprocess-dispatched -> `check` exits 0 AND stdout carries a `^ROUTE-BYPASS:` line
#      naming plan-review, whose text contains 'no surviving subprocess dispatch stamp', does NOT contain
#      'never attempted', and contains NO '/Users/' substring (N5). ----
( export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"
  rb_common rb7; mk_sub rb7 rb-PR
  printf '## Review\nverdict: PASS\n' > "$RB_FIX/artifacts/plan-rb7.md"
  node "$LED" append --session rb7 --task rb --role plan-review --agent rb-PR --artifact "$RB_FIX/artifacts/plan-rb7.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"; node "$LED" check --session rb7 --task rb 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -q "^ROUTE-BYPASS:" && echo "$OUT" | grep -q "plan-review" \
  && echo "$OUT" | grep -q "no surviving subprocess dispatch stamp" && ! echo "$OUT" | grep -q "never attempted" \
  && ! echo "$OUT" | grep -q "/Users/"; } \
  && ok "#1989 AC-7: routed plan-review closed via the agentId arm -> exit 0 + ROUTE-BYPASS with honest wording, no 'never attempted', no /Users/ leak" \
  || bad "#1989 AC-7 failed (rc=$RC out=$OUT)"

# ---- AC-8(a): the SAME rows under a fixture with NO subprocess-declared seat -> exit 0 and stdout carries NO
#      ROUTE-BYPASS token (seatDispatchIsSubprocess returns !ok -> the advisory is dormant). ----
( export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-none.json"
  rb_common rb8a; mk_sub rb8a rb-PRa
  printf '## Review\nverdict: PASS\n' > "$RB_FIX/artifacts/plan-rb8a.md"
  node "$LED" append --session rb8a --task rb --role plan-review --agent rb-PRa --artifact "$RB_FIX/artifacts/plan-rb8a.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-none.json"; node "$LED" check --session rb8a --task rb 2>&1); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "ROUTE-BYPASS"; } \
  && ok "#1989 AC-8(a): no subprocess-declared seat -> exit 0, NO ROUTE-BYPASS token (dormant)" \
  || bad "#1989 AC-8(a) should exit 0 with no ROUTE-BYPASS (rc=$RC out=$OUT)"

# ---- AC-8(b): a plan-review row with VERIFIED subprocess provenance (fixture-only by construction per N2 --
#      live subprocess rows are keyed by the SUBPROCESS's own session id, so no production single-session
#      `check` can observe this shape) -> exit 0, DISPATCH: labels it as today, NO ROUTE-BYPASS for plan-review
#      (a surviving dispatch stamp suppresses the advisory). ----
( export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"
  rb_common rb8b
  mk_rb_or_transcript "$RB_FIX/transcripts/fix8b.jsonl" "OR-NONCE-RB8B"
  printf '## Review\nDecision: PASS\nDISPATCH-NONCE:OR-NONCE-RB8B\n' > "$RB_FIX/artifacts/plan-rb8b.md"
  node "$LED" append --session rb8b --task rb --role plan-review --dispatch subprocess-openrouter \
    --transcript "$RB_FIX/transcripts/fix8b.jsonl" --nonce "OR-NONCE-RB8B" \
    --artifact "$RB_FIX/artifacts/plan-rb8b.md" --verdict PASS >/dev/null
)
OUT=$(export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"; node "$LED" check --session rb8b --task rb 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -q "role=plan-review dispatch=subprocess-openrouter" && ! echo "$OUT" | grep -q "ROUTE-BYPASS"; } \
  && ok "#1989 AC-8(b): verified subprocess plan-review row -> exit 0, DISPATCH: labels it, NO ROUTE-BYPASS (surviving stamp suppresses)" \
  || bad "#1989 AC-8(b) should exit 0 + DISPATCH label + no ROUTE-BYPASS (rc=$RC out=$OUT)"

# ---- AC-8(c): the genuine-D3-fallback shape (round-2 B2 requirement). Append a plan-review row carrying
#      dispatch/transcript/nonce (NO agentId), then SUPERSEDE it with a resolving --agent + --artifact + --verdict
#      append. overlayAppend's clear-list (gated on agentResolves) ERASES dispatch/transcript_path/nonce on the
#      resolving append; the prior no-agentId row is NOT retained as history (isNewRound requires prior.agentId).
#      So the file holds 1 surviving line, `grep -Ec '"dispatch"'` = 0 (positive control `grep -Ec
#      '"role":"plan-review"'` = 1) -> `check` exits 0 AND the ROUTE-BYPASS: line for plan-review FIRES with the
#      AC-7 honest wording (it names the receipt file as disambiguator; no 'never attempted' claim). This pins the
#      designed round-2 semantics: a fallback-closed routed seat is VISIBLE, and the advisory never lies about
#      the cause. ----
( export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"
  rb_common rb8c
  # Step 1: the subprocess dispatch's OWN spawn-time stamp (a real, validly-bound transcript; no agentId).
  mk_rb_or_transcript "$RB_FIX/transcripts/fix8c.jsonl" "N-PR-ORIG-8C"
  node "$LED" append --session rb8c --task rb --role plan-review --dispatch subprocess-openrouter \
    --transcript "$RB_FIX/transcripts/fix8c.jsonl" --nonce "N-PR-ORIG-8C" >/dev/null
  # Step 2: that dispatch was REJECTED -- the bounded Anthropic fallback self-appends a REAL, resolving agentId +
  #    its own artifact + verdict=PASS onto the SAME row (the clear-list erases the stamp on this resolving append).
  mk_sub rb8c fallback-agent-8c
  printf '## Review\nDecision: PASS\n' > "$RB_FIX/artifacts/plan-rb8c-fallback.md"
  node "$LED" append --session rb8c --task rb --role plan-review --agent fallback-agent-8c \
    --artifact "$RB_FIX/artifacts/plan-rb8c-fallback.md" --verdict PASS >/dev/null
)
RB8C_FILE="$(RB_LED rb8c)"
disp_count=$(grep -Ec '"dispatch"' "$RB8C_FILE" 2>/dev/null); disp_count="${disp_count:-0}"
pr_count=$(grep -Ec '"role":"plan-review"' "$RB8C_FILE" 2>/dev/null); pr_count="${pr_count:-0}"
OUT=$(export THREE_ROLE_LEDGER_DIR="$RB_FIX/ledger"; export CC_ROUTES_JSON="$RB_FIX/routes-pr.json"; node "$LED" check --session rb8c --task rb 2>&1); RC=$?
{ [ "$disp_count" = "0" ] && [ "$pr_count" = "1" ] && [ "$RC" = "0" ] \
  && echo "$OUT" | grep -q "^ROUTE-BYPASS:" && echo "$OUT" | grep -q "plan-review" \
  && echo "$OUT" | grep -q "no surviving subprocess dispatch stamp" && ! echo "$OUT" | grep -q "never attempted" \
  && echo "$OUT" | grep -q "1947-seat-mix-live-smoke"; } \
  && ok "#1989 AC-8(c): superseded-fallback shape (stamp then resolving --agent/--artifact/--verdict) -> 1 surviving line, grep '\"dispatch\"'=0 (positive control role=plan-review=1), exit 0 + ROUTE-BYPASS FIRES with honest wording naming the receipt file" \
  || bad "#1989 AC-8(c) failed (dispatch-count=$disp_count pr-count=$pr_count rc=$RC out=$OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #2051 — the transition gate's evaluatePlanReviewGate now recognizes a genuine subprocess-openrouter
# (Kimi K3) plan-review PASS via a THIRD sanctioned arm that CALLS checkSubprocessProvenance (never
# re-implements it), placed FIRST after the universal verdict screen (mirroring checkRole's consult-order).
# These node-level arms exercise `gate-plan-review` DIRECTLY. Sibling end-to-end arms live in
# hooks/three-role-transition-gate-smoke-test.sh (AC-7). Isolated CC_ROUTES_JSON + THREE_ROLE_LEDGER_DIR +
# THREE_ROLE_PROJECTS_ROOT fixtures, reusing the #1947 AC-11 fixture vocabulary.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
G_FIX="$TMP/gate-fixtures"
mkdir -p "$G_FIX/ledger" "$G_FIX/transcripts" "$G_FIX/artifacts" "$G_FIX/projects"
# Fixture routes: plan-review = subprocess-openrouter kimi-k3 (the #1947 SSOT shape the gate was blind to).
cat > "$G_FIX/routes.json" <<'GJSON'
{ "seats": { "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter", "agent_tool_fallback": "opus" } } }
GJSON
# A SECOND routes fixture for AC-4 (SSOT silent — plan-review is an ordinary anthropic seat, no dispatch).
cat > "$G_FIX/routes-none.json" <<'GJSON'
{ "seats": { "plan-review": { "provider": "anthropic", "model": "claude-opus-5" } } }
GJSON
# mk_g_or_transcript $path $task $nonce $servedModel — a validly-bound subprocess transcript whose FIRST
# record (queue-operation/enqueue) carries `3ROLE_TASK:<task> ROLE:plan-review` AND this dispatch's nonce,
# and an assistant line serving the SSOT-declared model. The two signals checkSubprocessProvenance binds on.
mk_g_or_transcript() {
  node -e '
    const fs = require("fs");
    const [ , outPath, task, nonce, model ] = process.argv;
    const lines = [];
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "g-fixture", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview this plan" }));
    lines.push(JSON.stringify({ type: "assistant", message: { model, content: [ { type: "text", text: "ok" } ] } }));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3" "$4"
}
# mk_g_bound $session $agentId $task $role — a resolvable AND spawn-record-bound Agent-tool subagent
# transcript (first record message.content carries the tag), under the fixture PROJECTS_ROOT. Used by
# AC-10(c) (a genuinely RESOLVING, spawn-bound agentId that must win via arm 1, not be shadowed by arm 3).
mk_g_bound() {
  mkdir -p "$G_FIX/projects/proj/$1/subagents"
  printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4" \
    > "$G_FIX/projects/proj/$1/subagents/agent-$2.jsonl"
}
# Run gate-plan-review under the G fixture env. $1=session $2=task; sets GR_OUT / GR_RC.
g_gate() { GR_OUT=$(THREE_ROLE_LEDGER_DIR="$G_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$G_FIX/projects" CC_ROUTES_JSON="$G_FIX/routes.json" node "$LED" gate-plan-review --session "$1" --task "$2" 2>&1 >/dev/null); GR_RC=$?; }
# g_append $session $task <append-args...> — write a plan-review row under the G fixture env.
g_append() { local S="$1" T="$2"; shift 2; THREE_ROLE_LEDGER_DIR="$G_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$G_FIX/projects" CC_ROUTES_JSON="$G_FIX/routes.json" node "$LED" append --session "$S" --task "$T" --role plan-review "$@" >/dev/null 2>&1; }
GT="gt1"   # the task id used across these arms

# ---- AC-1 (green — recognition). Hermetic AC-1 fixture: verdict PASS + dispatch + transcript + nonce +
#      artifact, NO agentId, NO closedAt. The arm-3 call to checkSubprocessProvenance returns '' -> ALLOW. ----
GS1="s-ac1-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac1.jsonl" "$GT" "N-AC1-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC1-2051\n' > "$G_FIX/artifacts/p-ac1.md"
g_append "$GS1" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac1.jsonl" \
  --nonce "N-AC1-2051" --artifact "$G_FIX/artifacts/p-ac1.md" --verdict PASS
g_gate "$GS1" "$GT"
{ [ "$GR_RC" = "0" ]; } && ok "#2051 AC-1: a real subprocess-openrouter plan-review PASS (nonce-verified, SSOT-declared) -> gate-plan-review exits 0 (the fix)" \
  || bad "#2051 AC-1 should ALLOW a genuine subprocess PASS (rc=$GR_RC out=$GR_OUT)"

# ---- AC-2 (red — nonce/binding forgeries). Each single mutation of the AC-1 fixture exits 2 with
#      BLOCK:subprocess-unverified. ----
# (a) transcript first record carries a DIFFERENT nonce than the row's own.
GS2A="s-ac2a-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac2a.jsonl" "$GT" "WRONG-NONCE-2A" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC2A-2051\n' > "$G_FIX/artifacts/p-ac2a.md"
g_append "$GS2A" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac2a.jsonl" \
  --nonce "N-AC2A-2051" --artifact "$G_FIX/artifacts/p-ac2a.md" --verdict PASS
g_gate "$GS2A" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:subprocess-unverified"; } \
  && ok "#2051 AC-2(a): transcript first-record nonce != row nonce -> BLOCK:subprocess-unverified (M2)" \
  || bad "#2051 AC-2(a) should block subprocess-unverified (rc=$GR_RC out=$GR_OUT)"

# (b) served model != SSOT seat model.
GS2B="s-ac2b-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac2b.jsonl" "$GT" "N-AC2B-2051" "wrong/model-b"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC2B-2051\n' > "$G_FIX/artifacts/p-ac2b.md"
g_append "$GS2B" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac2b.jsonl" \
  --nonce "N-AC2B-2051" --artifact "$G_FIX/artifacts/p-ac2b.md" --verdict PASS
g_gate "$GS2B" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:subprocess-unverified"; } \
  && ok "#2051 AC-2(b): served model != SSOT seat model -> BLOCK:subprocess-unverified" \
  || bad "#2051 AC-2(b) should block subprocess-unverified (rc=$GR_RC out=$GR_OUT)"

# (c) artifact does not contain the nonce.
GS2C="s-ac2c-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac2c.jsonl" "$GT" "N-AC2C-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\n' > "$G_FIX/artifacts/p-ac2c.md"   # NO nonce in the artifact
g_append "$GS2C" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac2c.jsonl" \
  --nonce "N-AC2C-2051" --artifact "$G_FIX/artifacts/p-ac2c.md" --verdict PASS
g_gate "$GS2C" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:subprocess-unverified"; } \
  && ok "#2051 AC-2(c): artifact lacks this dispatch's nonce -> BLOCK:subprocess-unverified (M2 binds artifact)" \
  || bad "#2051 AC-2(c) should block subprocess-unverified (rc=$GR_RC out=$GR_OUT)"

# ---- AC-3 (red — missing transcript). transcript_path points at a non-existent file. ----
GS3="s-ac3-2051"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC3-2051\n' > "$G_FIX/artifacts/p-ac3.md"
g_append "$GS3" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/does-not-exist.jsonl" \
  --nonce "N-AC3-2051" --artifact "$G_FIX/artifacts/p-ac3.md" --verdict PASS
g_gate "$GS3" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:subprocess-unverified"; } \
  && ok "#2051 AC-3: missing transcript -> BLOCK:subprocess-unverified" \
  || bad "#2051 AC-3 should block subprocess-unverified (rc=$GR_RC out=$GR_OUT)"

# ---- AC-4 (red — forged marker, SSOT silent). AC-1 fixture unchanged EXCEPT CC_ROUTES_JSON declares
#      plan-review an ordinary anthropic seat (no dispatch). checkSubprocessProvenance returns null (M1:
#      SSOT silent -> marker ignored) -> fall through -> arms 1/2 (no closedAt/agentId) -> BLOCK:not-finished. ----
GS4="s-ac4-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac4.jsonl" "$GT" "N-AC4-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC4-2051\n' > "$G_FIX/artifacts/p-ac4.md"
THREE_ROLE_LEDGER_DIR="$G_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$G_FIX/projects" CC_ROUTES_JSON="$G_FIX/routes.json" \
  node "$LED" append --session "$GS4" --task "$GT" --role plan-review \
  --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac4.jsonl" \
  --nonce "N-AC4-2051" --artifact "$G_FIX/artifacts/p-ac4.md" --verdict PASS >/dev/null 2>&1
# Run the gate under the SSOT-SILENT routes (routes-none.json) — the row still carries the marker, the SSOT
# does not declare the seat subprocess-dispatched, so the marker is ignored.
GR_OUT=$(THREE_ROLE_LEDGER_DIR="$G_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$G_FIX/projects" CC_ROUTES_JSON="$G_FIX/routes-none.json" node "$LED" gate-plan-review --session "$GS4" --task "$GT" 2>&1 >/dev/null); GR_RC=$?
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:not-finished"; } \
  && ok "#2051 AC-4: bare dispatch marker with SSOT silent -> BLOCK:not-finished (marker admitted nothing; fall-through preserved — the poisoned hand-append lesson is mechanically rejected)" \
  || bad "#2051 AC-4 should block not-finished (rc=$GR_RC out=$GR_OUT)"

# ---- AC-5 (red — verdict screen still first). AC-1 fixture with verdict FAIL -> the universal verdict
#      screen fires before arm 3 -> BLOCK:negative-verdict (never reaches the subprocess arm). ----
GS5="s-ac5-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac5.jsonl" "$GT" "N-AC5-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: FAIL\nDISPATCH-NONCE:N-AC5-2051\n' > "$G_FIX/artifacts/p-ac5.md"
g_append "$GS5" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac5.jsonl" \
  --nonce "N-AC5-2051" --artifact "$G_FIX/artifacts/p-ac5.md" --verdict FAIL
g_gate "$GS5" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:negative-verdict"; } \
  && ok "#2051 AC-5: verdict FAIL on a subprocess row -> BLOCK:negative-verdict (verdict screen ahead of arm 3)" \
  || bad "#2051 AC-5 should block negative-verdict (rc=$GR_RC out=$GR_OUT)"

# ---- AC-10(a) (placement discriminator — ALLOW side). The dual-signal row overlayAppend can really
#      produce: AC-1's fixture row ADDITIONALLY carrying closedAt + a NON-resolving agentId (no transcript
#      for it exists), alongside valid dispatch/transcript/nonce. arm-3-first: tie-break at :1264 does NOT
#      fire (agentId non-resolving) -> subprocess evidence verified -> '' -> ALLOW. A wrong arm-3-last
#      implementation exits 2 BLOCK:no-bound-reviewer-spawn here, so this arm mechanically pins the placement. ----
GS10A="s-ac10a-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac10a.jsonl" "$GT" "N-AC10A-2051" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC10A-2051\n' > "$G_FIX/artifacts/p-ac10a.md"
# Two ordinary appends compose the dual-signal row: first the closedAt+agentId, then the dispatch fields.
# (A NON-resolving agentId: no transcript for "ghost-ac10a" exists under the fixture projects root.)
g_append "$GS10A" "$GT" --agent "ghost-ac10a" --artifact "$G_FIX/artifacts/p-ac10a.md" --verdict PASS --closed-at "2026-07-28T00:00:00.000Z"
g_append "$GS10A" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac10a.jsonl" \
  --nonce "N-AC10A-2051" --artifact "$G_FIX/artifacts/p-ac10a.md" --verdict PASS
g_gate "$GS10A" "$GT"
{ [ "$GR_RC" = "0" ]; } \
  && ok "#2051 AC-10(a): dual-signal row (closedAt + NON-resolving agentId + valid subprocess evidence) -> ALLOW (noise agentId does not erase valid nonce evidence; arm-3-first)" \
  || bad "#2051 AC-10(a) should ALLOW (rc=$GR_RC out=$GR_OUT)"

# ---- AC-10(b) (placement discriminator — BLOCK side). Same dual-signal shape with the AC-2(a) forged-nonce
#      mutation: the subprocess arm blocks BLOCK:subprocess-unverified, specifically NOT no-bound-reviewer-
#      spawn — proving the dual-signal shape never fail-opens AND the block is issued by arm 3 (a wrong
#      arm-3-last implementation emits no-bound-reviewer-spawn here). ----
GS10B="s-ac10b-2051"
mk_g_or_transcript "$G_FIX/transcripts/f-ac10b.jsonl" "$GT" "WRONG-NONCE-10B" "moonshotai/kimi-k3"   # forged nonce in transcript
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC10B-2051\n' > "$G_FIX/artifacts/p-ac10b.md"
g_append "$GS10B" "$GT" --agent "ghost-ac10b" --artifact "$G_FIX/artifacts/p-ac10b.md" --verdict PASS --closed-at "2026-07-28T00:00:00.000Z"
g_append "$GS10B" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac10b.jsonl" \
  --nonce "N-AC10B-2051" --artifact "$G_FIX/artifacts/p-ac10b.md" --verdict PASS
g_gate "$GS10B" "$GT"
{ [ "$GR_RC" = "2" ] && echo "$GR_OUT" | grep -q "BLOCK:subprocess-unverified" && ! echo "$GR_OUT" | grep -q "no-bound-reviewer-spawn"; } \
  && ok "#2051 AC-10(b): dual-signal + forged nonce -> BLOCK:subprocess-unverified (NOT no-bound-reviewer-spawn; block issued by arm 3, dual-signal never fail-opens)" \
  || bad "#2051 AC-10(b) should block subprocess-unverified and NOT no-bound-reviewer-spawn (rc=$GR_RC out=$GR_OUT)"

# ---- AC-10(c) (round-2 N6 — the stronger-claim-wins positive control). AC-1's fixture PLUS closedAt PLUS
#      an agentId that RESOLVES AND is spawn-record-bound to 3ROLE_TASK:<T> ROLE:plan-review (a genuine,
#      spawn-bound agentId) PLUS a DELIBERATELY forged transcript nonce on the dispatch fields -> exit 0.
#      checkSubprocessProvenance's tie-break at :1264 returns null for the resolving agentId (the stronger
#      claim) BEFORE any subprocess verification runs, so arm 3 falls through and arm 1 wins. A MIRRORED
#      arm-3-first (C2 violation) would block subprocess-unverified here — this arm catches that regression. ----
GS10C="s-ac10c-2051"
# A genuinely resolving + spawn-bound agentId transcript under the fixture projects root.
mk_g_bound "$GS10C" "real-ac10c" "$GT" "plan-review"
mk_g_or_transcript "$G_FIX/transcripts/f-ac10c.jsonl" "$GT" "WRONG-NONCE-10C" "moonshotai/kimi-k3"   # forged nonce in transcript
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC10C-2051\n' > "$G_FIX/artifacts/p-ac10c.md"
# Compose: first the resolving+bound agentId + closedAt + verdict, then the (forged) dispatch fields.
g_append "$GS10C" "$GT" --agent "real-ac10c" --artifact "$G_FIX/artifacts/p-ac10c.md" --verdict PASS --closed-at "2026-07-28T00:00:00.000Z"
g_append "$GS10C" "$GT" --dispatch subprocess-openrouter --transcript "$G_FIX/transcripts/f-ac10c.jsonl" \
  --nonce "N-AC10C-2051" --artifact "$G_FIX/artifacts/p-ac10c.md" --verdict PASS
g_gate "$GS10C" "$GT"
{ [ "$GR_RC" = "0" ]; } \
  && ok "#2051 AC-10(c): resolving + spawn-bound agentId PLUS a forged dispatch nonce -> exit 0 (arm 1 wins via the :1264 tie-break; arm 3 must NOT shadow a resolving agentId — catches a mirrored checkSubprocessProvenance regression)" \
  || bad "#2051 AC-10(c) should ALLOW — a resolving+bound agentId must win, not be shadowed by a forged-nonce subprocess arm (rc=$GR_RC out=$GR_OUT)"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# #2075 Phase 1 — provider-agnostic ledger provenance primitive (provenance-kind, strength lattice,
# stored run_kind/run_id/run_source, E3 containment). Isolated CC_ROUTES_JSON + THREE_ROLE_LEDGER_DIR +
# THREE_ROLE_PROJECTS_ROOT fixture root, reusing the #1947/#2051 fixture vocabulary (mk_*_tagged /
# mk_*_or_transcript). Covers AC-1, AC-2, AC-3, AC-9, AC-10, AC-11, AC-23(a/b/c), AC-24 — the plan's own
# Phase 1 scope (`.ai-workspace/plans/2026-07-29-2075-ledger-provenance-redesign.md`). AC-23(d)/(e) and
# every AC-4..AC-8c/AC-12..AC-27 sit in Phase 2/3 (the `run_id` round-identity extension + the clause-2
# write-protocol / route-change-clause rewrite) and are NOT built here — see this task's PR body.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P1_FIX="$TMP/p1-fixtures"
mkdir -p "$P1_FIX/ledger" "$P1_FIX/projects" "$P1_FIX/transcripts" "$P1_FIX/artifacts"
cat > "$P1_FIX/routes.json" <<'P1JSON'
{ "seats": { "plan-review": { "provider": "openrouter", "model": "moonshotai/kimi-k3", "dispatch": "subprocess-openrouter", "agent_tool_fallback": "opus" } } }
P1JSON
cat > "$P1_FIX/routes-ollama.json" <<'P1JSON'
{ "seats": { "plan-review": { "provider": "ollama", "model": "gemma4:26b-nvfp4-cfgA", "dispatch": "subprocess-ollama", "agent_tool_fallback": "opus" } } }
P1JSON

# mk_p1_tagged $session $agentId $task $role — a resolving AND spawn-record-bound Agent-tool subagent
# transcript (first record message.content carries the tag), first record only (no model line yet).
mk_p1_tagged() {
  mkdir -p "$P1_FIX/projects/proj/$1/subagents"
  printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4" \
    > "$P1_FIX/projects/proj/$1/subagents/agent-$2.jsonl"
}
# mk_p1_tagged_model $session $agentId $task $role $model — same, PLUS a trailing assistant message.model line.
mk_p1_tagged_model() {
  mkdir -p "$P1_FIX/projects/proj/$1/subagents"
  { printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:%s -- do the work"}}\n' "$3" "$4";
    printf '{"type":"assistant","message":{"model":"%s","role":"assistant","content":[]}}\n' "$5"; } \
    > "$P1_FIX/projects/proj/$1/subagents/agent-$2.jsonl"
}
# p1_append_model_line $session $agentId $model — append a trailing assistant message.model line to an
# EXISTING tagged transcript (simulates the transcript "completing" after an initial spawn-time stamp).
p1_append_model_line() {
  printf '{"type":"assistant","message":{"model":"%s","role":"assistant","content":[]}}\n' "$3" \
    >> "$P1_FIX/projects/proj/$1/subagents/agent-$2.jsonl"
}
# mk_p1_or_transcript $path $task $nonce $model — a validly-bound subprocess transcript (queue-operation/
# enqueue first record carrying the tag + nonce, plus a served-model assistant line).
mk_p1_or_transcript() {
  node -e '
    const fs = require("fs");
    const [ , outPath, task, nonce, model ] = process.argv;
    const lines = [];
    lines.push(JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "p1-fixture", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview this plan" }));
    lines.push(JSON.stringify({ type: "assistant", message: { model, content: [ { type: "text", text: "ok" } ] } }));
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3" "$4"
}
# mk_p1_or_transcript_nomodel $path $task $nonce — the SAME bound first record, but NO assistant line at
# all (AC-11: an execution record with no readable message.model).
mk_p1_or_transcript_nomodel() {
  node -e '
    const fs = require("fs");
    const [ , outPath, task, nonce ] = process.argv;
    const lines = [ JSON.stringify({ type: "queue-operation", operation: "enqueue", timestamp: "2026-01-01T00:00:00.000Z",
      sessionId: "p1-fixture", content: "3ROLE_TASK:" + task + " ROLE:plan-review\nDISPATCH-NONCE:" + nonce + "\n\nreview this plan" }) ];
    fs.writeFileSync(outPath, lines.join("\n") + "\n");
  ' "$1" "$2" "$3"
}
# p1_append $routesFile $session $task $role <extra append args...> — fire-and-forget write.
p1_append() {
  local RF="$1" S="$2" T="$3" R="$4"; shift 4
  THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$RF" \
    node "$LED" append --session "$S" --task "$T" --role "$R" "$@" >/dev/null 2>&1
}
# p1_append_capture $routesFile $session $task $role <extra append args...> — sets PAOUT/PARC.
p1_append_capture() {
  local RF="$1" S="$2" T="$3" R="$4"; shift 4
  PAOUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$RF" \
    node "$LED" append --session "$S" --task "$T" --role "$R" "$@" 2>&1); PARC=$?
}
# p1_kind $routesFile $session $task $role — sets PKOUT/PKRC.
p1_kind() {
  PKOUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$1" \
    node "$LED" provenance-kind --session "$2" --task "$3" --role "$4" 2>&1); PKRC=$?
}
# p1_check $routesFile $session $task — sets PCOUT/PCRC.
p1_check() {
  PCOUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$1" \
    node "$LED" check --session "$2" --task "$3" 2>&1); PCRC=$?
}
# p1_reconcile $routesFile $session — sets RCOUT/RCRC.
p1_reconcile() {
  RCOUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$1" \
    node "$LED" reconcile-spawns --session "$2" 2>&1); RCRC=$?
}
# p1_refresh $routesFile $session — sets RFOUT/RFRC.
p1_refresh() {
  RFOUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$1" \
    node "$LED" refresh-models --session "$2" 2>&1); RFRC=$?
}
# p1_row_get $session $task $role $field — prints the RAW stored value of $field on the last matching row
# (empty string if absent/no row). Byte-level assertions, never through provenance-kind's own formula.
p1_row_get() {
  local FILE="$P1_FIX/ledger/$1/$2.jsonl"
  node -e '
    const fs = require("fs");
    const [ , file, role, field ] = process.argv;
    let lines = []; try { lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.trim()); } catch (e) {}
    let row = null;
    for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role === role) row = j; } catch (e) {} }
    process.stdout.write(row && row[field] != null ? String(row[field]) : "");
  ' "$FILE" "$3" "$4"
}

# ---- AC-1 (provenance-kind reporting formula: min(stored run_kind, verified kind)) -------------------------
# Arm 1: Agent-tool row, resolving + tag-bound agentId, stamped run_kind:witnessed -> E1.
mk_p1_tagged "p1-ac1a" "ag-ac1a" "t1" "plan-review"
p1_append "$P1_FIX/routes.json" "p1-ac1a" "t1" "plan-review" --agent "ag-ac1a" --run-kind witnessed
p1_kind "$P1_FIX/routes.json" "p1-ac1a" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E1" ]; } \
  && ok "#2075 AC-1 arm1: resolving+tag-bound agentId, stamped witnessed -> provenance-kind prints E1" \
  || bad "#2075 AC-1 arm1 expected E1 (rc=$PKRC out=$PKOUT)"

# Arm 2: nonce-bound subprocess row, fully verified (transcript+artifact+model), stamped run_kind:bound -> E2.
mk_p1_or_transcript "$P1_FIX/transcripts/ac1b.jsonl" "t1" "N-AC1B" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC1B\n' > "$P1_FIX/artifacts/ac1b.md"
p1_append "$P1_FIX/routes.json" "p1-ac1b" "t1" "plan-review" --dispatch subprocess-openrouter \
  --transcript "$P1_FIX/transcripts/ac1b.jsonl" --nonce "N-AC1B" --artifact "$P1_FIX/artifacts/ac1b.md" \
  --verdict PASS --run-kind bound
p1_kind "$P1_FIX/routes.json" "p1-ac1b" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E2" ]; } \
  && ok "#2075 AC-1 arm2: fully-verified nonce-bound subprocess row, stamped bound -> provenance-kind prints E2" \
  || bad "#2075 AC-1 arm2 expected E2 (rc=$PKRC out=$PKOUT)"

# Arm 3: reconcile-spawns backfills a bare row from a real tagged sibling -> stamps run_kind:inferred, so
# provenance-kind reports E3 even though the agentId genuinely resolves and is tag-bound.
mk_p1_tagged "p1-ac1c" "ag-ac1c" "t1" "executor"
p1_reconcile "$P1_FIX/routes.json" "p1-ac1c"
p1_kind "$P1_FIX/routes.json" "p1-ac1c" "t1" "executor"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E3" ]; } \
  && ok "#2075 AC-1 arm3: reconcile-spawns-backfilled row (run_kind:inferred) -> provenance-kind prints E3 despite a genuinely resolving agentId" \
  || bad "#2075 AC-1 arm3 expected E3 (rc=$PKRC out=$PKOUT)"
AC1C_RK=$(p1_row_get "p1-ac1c" "t1" "executor" "run_kind")
[ "$AC1C_RK" = "inferred" ] \
  && ok "#2075 AC-1 arm3: reconcile-spawns stamped run_kind=inferred on the raw row" \
  || bad "#2075 AC-1 arm3 expected raw run_kind=inferred (got '$AC1C_RK')"

# Arm 4: a bare spawn placeholder (no evidence, no run_kind at all) -> none, no legacy suffix.
p1_append "$P1_FIX/routes.json" "p1-ac1d" "t1" "plan-review"
p1_kind "$P1_FIX/routes.json" "p1-ac1d" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "none" ]; } \
  && ok "#2075 AC-1 arm4: bare spawn placeholder -> provenance-kind prints none (no legacy suffix)" \
  || bad "#2075 AC-1 arm4 expected none (rc=$PKRC out=$PKOUT)"

# ---- AC-2 (comparison-site count guard — necessary, not sufficient; AC-3 carries the real weight) ----------
AC2_COUNT=$(awk '{ if ($0 ~ /^[[:space:]]*\/\//) { print "" } else { print } }' "$LED" \
  | grep -oiE "\.dispatch[[:space:]]*[!=]==[[:space:]]*['\"]subprocess[-_]?openrouter['\"]" | wc -l | tr -d ' ')
[ "$AC2_COUNT" -le 2 ] \
  && ok "#2075 AC-2: comparison-operator-scoped, comment-stripped subprocess-openrouter count = $AC2_COUNT (target <= 2)" \
  || bad "#2075 AC-2 expected <= 2 direct comparisons, got $AC2_COUNT"

# ---- AC-3 (provider-agnosticism proof) — the SAME AC-1 arm-2 and AC-9 arm-1 shapes, ZERO further code
#      edits, with a fixture subprocess-ollama seat substituted throughout (fixture SSOT seat AND row
#      dispatch value both flip). Only AC-9 is a Phase-1-built AC, so that is the arm this proof re-runs. ----
mk_p1_or_transcript "$P1_FIX/transcripts/ac3a.jsonl" "t1" "N-AC3A" "gemma4:26b-nvfp4-cfgA"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC3A\n' > "$P1_FIX/artifacts/ac3a.md"
p1_append "$P1_FIX/routes-ollama.json" "p1-ac3a" "t1" "plan-review" --dispatch subprocess-ollama \
  --transcript "$P1_FIX/transcripts/ac3a.jsonl" --nonce "N-AC3A" --artifact "$P1_FIX/artifacts/ac3a.md" \
  --verdict PASS --run-kind bound
p1_kind "$P1_FIX/routes-ollama.json" "p1-ac3a" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E2" ]; } \
  && ok "#2075 AC-3(i): AC-1 arm2's shape re-run with a subprocess-ollama SSOT seat + row dispatch, ZERO code edits -> still prints E2" \
  || bad "#2075 AC-3(i) expected E2 under subprocess-ollama (rc=$PKRC out=$PKOUT)"

mk_p1_or_transcript "$P1_FIX/transcripts/ac3b.jsonl" "t1" "N-AC3B" "gemma4:26b-nvfp4-cfgA"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC3B\n' > "$P1_FIX/artifacts/ac3b.md"
p1_append "$P1_FIX/routes-ollama.json" "p1-ac3b" "t1" "plan-review" --dispatch subprocess-ollama \
  --transcript "$P1_FIX/transcripts/ac3b.jsonl" --nonce "N-AC3B" --artifact "$P1_FIX/artifacts/ac3b.md" \
  --verdict PASS --run-kind bound
D3B_BEFORE=$(p1_row_get "p1-ac3b" "t1" "plan-review" "dispatch")
mk_p1_tagged_model "p1-ac3b" "sib-ac3b" "t1" "plan-review" "claude-opus-5"
p1_reconcile "$P1_FIX/routes-ollama.json" "p1-ac3b"
D3B_AFTER=$(p1_row_get "p1-ac3b" "t1" "plan-review" "dispatch")
MV3B_AFTER=$(p1_row_get "p1-ac3b" "t1" "plan-review" "modelVersion")
{ [ "$D3B_AFTER" = "$D3B_BEFORE" ] && [ "$MV3B_AFTER" != "claude-opus-5" ]; } \
  && ok "#2075 AC-3(ii): AC-9 arm1's E3-corruption regression re-run under subprocess-ollama, ZERO code edits -> dispatch survives, model never the Anthropic sibling's" \
  || bad "#2075 AC-3(ii) regression under subprocess-ollama (dispatch before=$D3B_BEFORE after=$D3B_AFTER model=$MV3B_AFTER)"

# ---- AC-9 (the ~30s timer / E3-containment guard, arm1 + the demotion-interposed arm2) ---------------------
# Arm 1: a verified E2 plan-review row PLUS a same-session/same-task Agent-tool SIBLING transcript. After
#        reconcile-spawns, the E2 row's dispatch/transcript_path/nonce/run_kind survive; modelVersion is
#        never backfilled from the sibling.
mk_p1_or_transcript "$P1_FIX/transcripts/ac9a.jsonl" "t1" "N-AC9A" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC9A\n' > "$P1_FIX/artifacts/ac9a.md"
p1_append "$P1_FIX/routes.json" "p1-ac9a" "t1" "plan-review" --dispatch subprocess-openrouter \
  --transcript "$P1_FIX/transcripts/ac9a.jsonl" --nonce "N-AC9A" --artifact "$P1_FIX/artifacts/ac9a.md" \
  --verdict PASS --run-kind bound
D9A_BEFORE=$(p1_row_get "p1-ac9a" "t1" "plan-review" "dispatch")
T9A_BEFORE=$(p1_row_get "p1-ac9a" "t1" "plan-review" "transcript_path")
N9A_BEFORE=$(p1_row_get "p1-ac9a" "t1" "plan-review" "nonce")
mk_p1_tagged_model "p1-ac9a" "sib-ac9a" "t1" "plan-review" "claude-opus-5"
p1_reconcile "$P1_FIX/routes.json" "p1-ac9a"
D9A_AFTER=$(p1_row_get "p1-ac9a" "t1" "plan-review" "dispatch")
T9A_AFTER=$(p1_row_get "p1-ac9a" "t1" "plan-review" "transcript_path")
N9A_AFTER=$(p1_row_get "p1-ac9a" "t1" "plan-review" "nonce")
RK9A_AFTER=$(p1_row_get "p1-ac9a" "t1" "plan-review" "run_kind")
MV9A_AFTER=$(p1_row_get "p1-ac9a" "t1" "plan-review" "modelVersion")
{ [ "$D9A_AFTER" = "$D9A_BEFORE" ] && [ "$T9A_AFTER" = "$T9A_BEFORE" ] && [ "$N9A_AFTER" = "$N9A_BEFORE" ] \
  && [ "$RK9A_AFTER" = "bound" ] && [ "$MV9A_AFTER" != "claude-opus-5" ]; } \
  && ok "#2075 AC-9 arm1: reconcile-spawns with an Agent-tool sibling present -> E2 row's dispatch/transcript_path/nonce/run_kind survive intact, modelVersion never the sibling's" \
  || bad "#2075 AC-9 arm1 regression (dispatch=$D9A_AFTER transcript=$T9A_AFTER nonce=$N9A_AFTER run_kind=$RK9A_AFTER modelVersion=$MV9A_AFTER)"

# Arm 2 (demotion-interposed): a bare --run-kind inferred append lands BEFORE reconcile-spawns runs.
#   (i) immediately after the demotion, run_kind is still 'bound' (write-once clamp).
#   (ii) reconcile-spawns then STILL cannot erase the row's E2 evidence (guard reads verified kind).
mk_p1_or_transcript "$P1_FIX/transcripts/ac9b.jsonl" "t1" "N-AC9B" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC9B\n' > "$P1_FIX/artifacts/ac9b.md"
p1_append "$P1_FIX/routes.json" "p1-ac9b" "t1" "plan-review" --dispatch subprocess-openrouter \
  --transcript "$P1_FIX/transcripts/ac9b.jsonl" --nonce "N-AC9B" --artifact "$P1_FIX/artifacts/ac9b.md" \
  --verdict PASS --run-kind bound
D9B_BEFORE=$(p1_row_get "p1-ac9b" "t1" "plan-review" "dispatch")
T9B_BEFORE=$(p1_row_get "p1-ac9b" "t1" "plan-review" "transcript_path")
N9B_BEFORE=$(p1_row_get "p1-ac9b" "t1" "plan-review" "nonce")
p1_append "$P1_FIX/routes.json" "p1-ac9b" "t1" "plan-review" --run-kind inferred
RK9B_MID=$(p1_row_get "p1-ac9b" "t1" "plan-review" "run_kind")
[ "$RK9B_MID" = "bound" ] \
  && ok "#2075 AC-9 arm2(i): a bare --run-kind inferred append against an already-bound row is a no-op on the stored field (write-once clamp)" \
  || bad "#2075 AC-9 arm2(i) expected run_kind to stay 'bound' after the demotion append, got '$RK9B_MID'"
mk_p1_tagged_model "p1-ac9b" "sib-ac9b" "t1" "plan-review" "claude-opus-5"
p1_reconcile "$P1_FIX/routes.json" "p1-ac9b"
D9B_AFTER=$(p1_row_get "p1-ac9b" "t1" "plan-review" "dispatch")
T9B_AFTER=$(p1_row_get "p1-ac9b" "t1" "plan-review" "transcript_path")
N9B_AFTER=$(p1_row_get "p1-ac9b" "t1" "plan-review" "nonce")
RK9B_AFTER=$(p1_row_get "p1-ac9b" "t1" "plan-review" "run_kind")
{ [ "$D9B_AFTER" = "$D9B_BEFORE" ] && [ "$T9B_AFTER" = "$T9B_BEFORE" ] && [ "$N9B_AFTER" = "$N9B_BEFORE" ] && [ "$RK9B_AFTER" = "bound" ]; } \
  && ok "#2075 AC-9 arm2(ii): after an interposed demotion append, reconcile-spawns STILL cannot erase the row's E2 evidence (guard reads verified kind, not the stored label)" \
  || bad "#2075 AC-9 arm2(ii) regression (dispatch=$D9B_AFTER transcript=$T9B_AFTER nonce=$N9B_AFTER run_kind=$RK9B_AFTER)"

# ---- AC-10 (E3 may still fill a blank row — regression guard) ----------------------------------------------
# (a) via reconcile-spawns: a genuinely tagged+modeled Anthropic transcript with NO ledger row yet.
mk_p1_tagged_model "p1-ac10a" "ag-ac10a" "t1" "executor" "claude-sonnet-5"
p1_reconcile "$P1_FIX/routes.json" "p1-ac10a"
AID10A=$(p1_row_get "p1-ac10a" "t1" "executor" "agentId")
MV10A=$(p1_row_get "p1-ac10a" "t1" "executor" "modelVersion")
RK10A=$(p1_row_get "p1-ac10a" "t1" "executor" "run_kind")
{ [ "$AID10A" = "ag-ac10a" ] && [ "$MV10A" = "claude-sonnet-5" ] && [ "$RK10A" = "inferred" ]; } \
  && ok "#2075 AC-10(a): an ordinary Anthropic row is still filled by reconcile-spawns, stamped run_kind:inferred (regression guard)" \
  || bad "#2075 AC-10(a) regression (agentId=$AID10A modelVersion=$MV10A run_kind=$RK10A)"

# (b) via refresh-models: agentId present, modelVersion genuinely unresolvable at append time (the transcript
#     "completes" only AFTER the row already exists).
mk_p1_tagged "p1-ac10b" "ag-ac10b" "t1" "executor"
p1_append "$P1_FIX/routes.json" "p1-ac10b" "t1" "executor" --agent "ag-ac10b" --artifact "PR #1"
MV10B_BEFORE=$(p1_row_get "p1-ac10b" "t1" "executor" "modelVersion")
p1_append_model_line "p1-ac10b" "ag-ac10b" "claude-opus-5"
p1_refresh "$P1_FIX/routes.json" "p1-ac10b"
MV10B_AFTER=$(p1_row_get "p1-ac10b" "t1" "executor" "modelVersion")
RK10B_AFTER=$(p1_row_get "p1-ac10b" "t1" "executor" "run_kind")
{ [ -z "$MV10B_BEFORE" ] && [ "$MV10B_AFTER" = "claude-opus-5" ] && [ "$RK10B_AFTER" = "inferred" ]; } \
  && ok "#2075 AC-10(b): an ordinary Anthropic row is still filled by refresh-models, stamped run_kind:inferred (regression guard)" \
  || bad "#2075 AC-10(b) regression (before=$MV10B_BEFORE after=$MV10B_AFTER run_kind=$RK10B_AFTER)"

# ---- AC-11 (protection-vs-admissibility split for an unreadable served model) -------------------------------
mk_p1_or_transcript_nomodel "$P1_FIX/transcripts/ac11.jsonl" "t1" "N-AC11"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC11\n' > "$P1_FIX/artifacts/ac11.md"
p1_append "$P1_FIX/routes.json" "p1-ac11" "t1" "plan-review" --dispatch subprocess-openrouter \
  --transcript "$P1_FIX/transcripts/ac11.jsonl" --nonce "N-AC11" --artifact "$P1_FIX/artifacts/ac11.md" \
  --verdict PASS --run-kind bound
D11_BEFORE=$(p1_row_get "p1-ac11" "t1" "plan-review" "dispatch")
T11_BEFORE=$(p1_row_get "p1-ac11" "t1" "plan-review" "transcript_path")
N11_BEFORE=$(p1_row_get "p1-ac11" "t1" "plan-review" "nonce")
MV11_BEFORE=$(p1_row_get "p1-ac11" "t1" "plan-review" "modelVersion")
[ -z "$MV11_BEFORE" ] \
  && ok "#2075 AC-11 setup: the E2 row genuinely starts with no modelVersion (unreadable served model)" \
  || bad "#2075 AC-11 setup should start with no modelVersion, got '$MV11_BEFORE'"

# (a) protection (write side): reconcile-spawns (with a real Agent-tool sibling present) and refresh-models
#     must NOT fill modelVersion from a guess, and must NOT clear dispatch/transcript_path/nonce.
mk_p1_tagged_model "p1-ac11" "sib-ac11" "t1" "plan-review" "claude-opus-5"
p1_reconcile "$P1_FIX/routes.json" "p1-ac11"
p1_refresh "$P1_FIX/routes.json" "p1-ac11"
D11_AFTER=$(p1_row_get "p1-ac11" "t1" "plan-review" "dispatch")
T11_AFTER=$(p1_row_get "p1-ac11" "t1" "plan-review" "transcript_path")
N11_AFTER=$(p1_row_get "p1-ac11" "t1" "plan-review" "nonce")
MV11_AFTER=$(p1_row_get "p1-ac11" "t1" "plan-review" "modelVersion")
{ [ "$D11_AFTER" = "$D11_BEFORE" ] && [ "$T11_AFTER" = "$T11_BEFORE" ] && [ "$N11_AFTER" = "$N11_BEFORE" ] && [ -z "$MV11_AFTER" ]; } \
  && ok "#2075 AC-11(a) protection: modelVersion stays absent, dispatch/transcript_path/nonce survive intact (honest-blank beats confidently-wrong)" \
  || bad "#2075 AC-11(a) regression (dispatch=$D11_AFTER transcript=$T11_AFTER nonce=$N11_AFTER modelVersion=$MV11_AFTER)"

# (b) admissibility (read side) still FAILS CLOSED: check exits 2, naming plan-review + the unreadable model.
p1_append "$P1_FIX/routes.json" "p1-ac11" "t1" "planner" --skip-reason "fixture: not under test in AC-11"
p1_append "$P1_FIX/routes.json" "p1-ac11" "t1" "executor" --skip-reason "fixture: not under test in AC-11"
printf 'Decision: PASS\n' > "$P1_FIX/artifacts/ac11-er.md"
p1_append "$P1_FIX/routes.json" "p1-ac11" "t1" "execution-review" --oracle "$P1_FIX/artifacts/ac11-er.md"
p1_check "$P1_FIX/routes.json" "p1-ac11" "t1"
{ [ "$PCRC" = "2" ] && echo "$PCOUT" | grep -qi "plan-review" && echo "$PCOUT" | grep -qi "served model"; } \
  && ok "#2075 AC-11(b) admissibility: check still FAILS CLOSED (exit 2) naming plan-review's unreadable served model" \
  || bad "#2075 AC-11(b) should BLOCK naming plan-review's served model (rc=$PCRC out=$PCOUT)"

# ---- AC-23 (legacy-row migration, arms a/b/c — buildable this phase). A "legacy" row is simply one
#      appended WITHOUT --run-kind (no key at all) — functionally identical to a row the pre-#2075 binary
#      would have written; there is no separate parsing path to reproduce. Arms (d)/(e) require clause 2's
#      Phase-3 route-change-clause (R-C) rewrite, which does not exist in this binary — NOT built here,
#      see the PR body. ----------------------------------------------------------------------------------
# (a) resolving+tag-bound legacy row -> "E1 legacy"; bare placeholder -> "none" (no suffix).
mk_p1_tagged "p1-ac23a" "ag-ac23a" "t1" "plan-review"
p1_append "$P1_FIX/routes.json" "p1-ac23a" "t1" "plan-review" --agent "ag-ac23a"
p1_kind "$P1_FIX/routes.json" "p1-ac23a" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E1 legacy" ]; } \
  && ok "#2075 AC-23(a): a legacy (no run_kind) resolving+tag-bound row -> provenance-kind prints 'E1 legacy'" \
  || bad "#2075 AC-23(a) expected 'E1 legacy' (rc=$PKRC out=$PKOUT)"
p1_append "$P1_FIX/routes.json" "p1-ac23a2" "t1" "plan-review"
p1_kind "$P1_FIX/routes.json" "p1-ac23a2" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "none" ]; } \
  && ok "#2075 AC-23(a): a legacy bare placeholder -> provenance-kind prints plain 'none' (no legacy suffix)" \
  || bad "#2075 AC-23(a) bare-placeholder expected 'none' (rc=$PKRC out=$PKOUT)"

# (b) check() on an all-legacy 4-role ledger prints output BYTE-IDENTICAL to the pre-#2075 binary's output
#     on the SAME fixture, except for the new PROVENANCE-LEGACY: note. Diff against a real origin/master
#     snapshot (git show), not a re-derived assumption.
mk_p1_tagged "p1-ac23b" "ac23b-p" "t1" "planner"
mk_p1_tagged "p1-ac23b" "ac23b-r" "t1" "plan-review"
mk_p1_tagged "p1-ac23b" "ac23b-e" "t1" "executor"
mk_p1_tagged "p1-ac23b" "ac23b-v" "t1" "execution-review"
printf '## ELI5\na plan\n### Binary AC\n- AC1\n' > "$P1_FIX/artifacts/ac23b-plan.md"
printf '## Review\nverdict: PASS\n' > "$P1_FIX/artifacts/ac23b-rev.md"
p1_append "$P1_FIX/routes.json" "p1-ac23b" "t1" "planner" --agent "ac23b-p" --artifact "$P1_FIX/artifacts/ac23b-plan.md"
p1_append "$P1_FIX/routes.json" "p1-ac23b" "t1" "plan-review" --agent "ac23b-r" --artifact "$P1_FIX/artifacts/ac23b-rev.md" --verdict PASS
p1_append "$P1_FIX/routes.json" "p1-ac23b" "t1" "executor" --agent "ac23b-e" --artifact "PR #99"
p1_append "$P1_FIX/routes.json" "p1-ac23b" "t1" "execution-review" --agent "ac23b-v" --artifact "$P1_FIX/artifacts/ac23b-rev.md"
p1_check "$P1_FIX/routes.json" "p1-ac23b" "t1"
NEW_OUT="$PCOUT"; NEW_RC="$PCRC"
# OLD_LED == AC23B_FIXTURE, the committed pinned pre-#2075 snapshot (test-setup block above; no git
# ref, no network -- same FIXTURE-MISSING-fails-closed convention as this file's sibling pinned-
# baseline ACs, hooks/_fixtures/3role-ledger-pre1580-overlay.mjs / -pre1947-ma2-overlay.mjs).
if [ -s "$AC23B_FIXTURE" ]; then
  OLD_OUT=$(THREE_ROLE_LEDGER_DIR="$P1_FIX/ledger" THREE_ROLE_PROJECTS_ROOT="$P1_FIX/projects" CC_ROUTES_JSON="$P1_FIX/routes.json" \
    node "$OLD_LED" check --session "p1-ac23b" --task "t1" 2>&1); OLD_RC=$?
  NEW_OUT_STRIPPED=$(echo "$NEW_OUT" | grep -v '^PROVENANCE-LEGACY:')
  # Non-decay guard (same convention as this file's other pinned-baseline ACs, e.g. #1833 AC3 / #1947
  # M-A-2): the pinned snapshot must NOT be byte-identical to the live ledger, else a future careless
  # "regenerate the snapshot from HEAD" collapses this into a fixed-vs-fixed tautology with zero power.
  cmp -s "$OLD_LED" "$LED" && bad "#2075 AC-23(b) non-decay guard: pinned pre-#2075 snapshot is byte-identical to the LIVE ledger -- the comparison has decayed into a tautology (re-pin hooks/_fixtures/3role-ledger-pre2075-snapshot.mjs from the real pre-#2075 commit)"
  { [ "$NEW_RC" = "0" ] && [ "$NEW_RC" = "$OLD_RC" ] && [ "$NEW_OUT_STRIPPED" = "$OLD_OUT" ] \
    && echo "$NEW_OUT" | grep -q '^PROVENANCE-LEGACY: planner, plan-review, executor, execution-review'; } \
    && ok "#2075 AC-23(b): check() on an all-legacy ledger is byte-identical to the pre-#2075 (pinned snapshot) binary's output, except the new PROVENANCE-LEGACY: note naming all four roles" \
    || bad "#2075 AC-23(b) regression (new_rc=$NEW_RC old_rc=$OLD_RC new=[$NEW_OUT] old=[$OLD_OUT])"
else
  bad "#2075 AC-23(b): FIXTURE MISSING at $AC23B_FIXTURE -- this fixture is committed and must always be present (it replaced a git-object acquisition; its absence means this AC cannot prove the byte-identical-except-PROVENANCE-LEGACY claim at all)"
fi

# (c) legacy row protection is UNCHANGED: a verdict-less skip/inherit write against a legacy TERMINAL row
#     (verdict present) still exits 2 (clause 1, untouched by #2075).
mk_p1_tagged "p1-ac23c" "ag-ac23c" "t1" "plan-review"
printf '## Review\nverdict: PASS\n' > "$P1_FIX/artifacts/ac23c.md"
p1_append "$P1_FIX/routes.json" "p1-ac23c" "t1" "plan-review" --agent "ag-ac23c" --artifact "$P1_FIX/artifacts/ac23c.md" --verdict PASS
p1_append_capture "$P1_FIX/routes.json" "p1-ac23c" "t1" "plan-review" --skip-reason "trying to erase"
VD23C_AFTER=$(p1_row_get "p1-ac23c" "t1" "plan-review" "verdict")
{ [ "$PARC" = "2" ] && [ "$VD23C_AFTER" = "PASS" ]; } \
  && ok "#2075 AC-23(c): a legacy TERMINAL row is still erasure-protected (clause 1 unchanged) -- verdict-less skip append exits 2, verdict survives" \
  || bad "#2075 AC-23(c) regression (rc=$PARC verdict_after=$VD23C_AFTER)"

# ---- AC-24 (demotion-only, PROMOTION direction — the anti-forgery power test for AC-1) ---------------------
# Arm A: stored run_kind:witnessed but a NON-resolving agentId -> provenance-kind prints none (not E1), and
#        a supersession attempt CITING that same non-resolving agentId still exits 2 -- proven against
#        EXISTING (unmodified by #2075) clause-2 anti-forgery code (agentBoundToTag on the incoming write),
#        never the Phase-3 R-C rewrite.
printf '## Review\nverdict: FAIL\n' > "$P1_FIX/artifacts/ac24a.md"
p1_append "$P1_FIX/routes.json" "p1-ac24a" "t1" "plan-review" --agent "ghost-ac24a" --run-kind witnessed \
  --artifact "$P1_FIX/artifacts/ac24a.md" --verdict FAIL --closed-at "2026-01-01T00:00:00.000Z"
p1_kind "$P1_FIX/routes.json" "p1-ac24a" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "none" ]; } \
  && ok "#2075 AC-24 arm A(i): stored run_kind:witnessed but a NON-resolving agentId -> provenance-kind prints none, not E1 (the stored label can only ever LOWER a row's kind)" \
  || bad "#2075 AC-24 arm A(i) expected none (rc=$PKRC out=$PKOUT)"
p1_append_capture "$P1_FIX/routes.json" "p1-ac24a" "t1" "plan-review" --agent "ghost-ac24a" --verdict PASS --closed-at "2026-01-02T00:00:00.000Z"
[ "$PARC" = "2" ] \
  && ok "#2075 AC-24 arm A(ii): a verdict-flip attempt citing that same NON-resolving agentId still exits 2 (today's existing anti-forgery, unbroken by #2075)" \
  || bad "#2075 AC-24 arm A(ii) expected exit 2 (rc=$PARC out=$PAOUT)"

# Arm B: stored run_kind:inferred alongside a FULLY VERIFYING nonce triple -> provenance-kind prints E3, not
#        E2 -- the stored label can never PROMOTE a row above its true verified strength.
mk_p1_or_transcript "$P1_FIX/transcripts/ac24b.jsonl" "t1" "N-AC24B" "moonshotai/kimi-k3"
printf '## Review\nDecision: PASS\nDISPATCH-NONCE:N-AC24B\n' > "$P1_FIX/artifacts/ac24b.md"
p1_append "$P1_FIX/routes.json" "p1-ac24b" "t1" "plan-review" --dispatch subprocess-openrouter \
  --transcript "$P1_FIX/transcripts/ac24b.jsonl" --nonce "N-AC24B" --artifact "$P1_FIX/artifacts/ac24b.md" \
  --verdict PASS --run-kind inferred
p1_kind "$P1_FIX/routes.json" "p1-ac24b" "t1" "plan-review"
{ [ "$PKRC" = "0" ] && [ "$PKOUT" = "E3" ]; } \
  && ok "#2075 AC-24 arm B: stored run_kind:inferred alongside a fully-verifying nonce triple -> provenance-kind prints E3, not E2 (the label can never raise a row's kind)" \
  || bad "#2075 AC-24 arm B expected E3 (rc=$PKRC out=$PKOUT)"
# ---------------------------------------------------------------------------
# #1936 -- read-side history lanes: Lane B (outcome monotonicity) + Lane A (round-aware freshness).
# `check` gains two additional, strictly-additive lanes over the role's FULL row history (never just the
# byRole-selected last-parse-wins row): Lane B walks a review role's verdict-bearing rows and refuses to let
# a bare/unattributed later row silently bury a recorded NEGATIVE verdict (NEGATIVE-VERDICT: problem); Lane A
# fires STALE-REVIEW: only when the ledger shows a genuinely NEW subject round left unreviewed. Fixture rows
# are built THROUGH the real CLI mirroring the sanctioned three-write lifecycle (spawn-shaped agent append,
# mid-turn self-append, stop-shaped closed-at append), EXCEPT AC-14 (marked below) which appends raw JSONL
# rows DIRECTLY to the fixture file to simulate hand-written / pre-existing states -- exactly the
# already-on-disk population the read lane defends. Dedicated session id (sess-1936) so agent ids never
# collide with any earlier section's fixtures.
# ---------------------------------------------------------------------------
S1936="sess-1936"
raw_append_1936() { # <ledger-file> <json-line> -- append a RAW JSONL row directly, bypassing the CLI (the
                     #    sanctioned AC-14 "hand-written state" exception).
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >> "$1"
}
# Minimal GREEN baseline for the THREE roles NOT under test in a given AC-14/AC-15 case: planner + executor
# + the "other" review role (single round each, bound + resolvable + closedAt well before anything the
# target review role's own history will carry). <target> in {execution-review, plan-review}.
mk_baseline3_1936() { # <task> <target-review-role>
  local t="$1" target="$2"
  local other="execution-review"; [ "$target" = "execution-review" ] && other="plan-review"
  mk_sub "$S1936" "${t}-p1"; mk_sub "$S1936" "${t}-e1"; mk_sub "$S1936" "${t}-o1"
  node "$LED" append --session "$S1936" --task "$t" --role planner --agent "${t}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
  node "$LED" append --session "$S1936" --task "$t" --role executor --agent "${t}-e1" --artifact "PR #$t" --closed-at "2026-01-01T00:05:00Z" >/dev/null
  node "$LED" append --session "$S1936" --task "$t" --role "$other" --agent "${t}-o1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T00:10:00Z" >/dev/null
}
# Complete GREEN 4-role fixture, all single-round, controllable per-role closedAt (used by AC-3/4/5/6/7/8/9).
mk_green4_1936() { # <task> <planner_closedAt> <planreview_closedAt> <executor_closedAt> <execreview_closedAt>
  local t="$1" pc="$2" prc="$3" ec="$4" erc="$5"
  mk_sub "$S1936" "${t}-p1"; mk_sub "$S1936" "${t}-pr1"; mk_sub "$S1936" "${t}-e1"; mk_sub "$S1936" "${t}-er1"
  node "$LED" append --session "$S1936" --task "$t" --role planner --agent "${t}-p1" --artifact "$TMP/plan.md" --closed-at "$pc" >/dev/null
  node "$LED" append --session "$S1936" --task "$t" --role plan-review --agent "${t}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "$prc" >/dev/null
  node "$LED" append --session "$S1936" --task "$t" --role executor --agent "${t}-e1" --artifact "PR #$t" --closed-at "$ec" >/dev/null
  node "$LED" append --session "$S1936" --task "$t" --role execution-review --agent "${t}-er1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "$erc" >/dev/null
}

# ---- AC-3: fresh execution-review FAIL is a handoff, not completion (single round, no Lane-A signal). ----
T3="1936ac3"
mk_sub "$S1936" "${T3}-p1"; mk_sub "$S1936" "${T3}-pr1"; mk_sub "$S1936" "${T3}-e1"; mk_sub "$S1936" "${T3}-er1"
node "$LED" append --session "$S1936" --task "$T3" --role planner --agent "${T3}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T3" --role plan-review --agent "${T3}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T3" --role executor --agent "${T3}-e1" --artifact "PR #$T3" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T3" --role execution-review --agent "${T3}-er1" --artifact "$TMP/rev.md" --verdict FAIL --closed-at "2026-01-01T03:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T3" 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
  && ok "1936 AC-3: fresh execution-review FAIL (no staleness signal at all) -> NEGATIVE-VERDICT, not a completion (kills a freshness-only fix)" \
  || bad "1936 AC-3 failed (rc=$RC out=$OUT)"

# ---- AC-4: stale review of a superseded executor round (Lane A, executor pair). ----
T4="1936ac4"
mk_sub "$S1936" "${T4}-p1"; mk_sub "$S1936" "${T4}-pr1"; mk_sub "$S1936" "${T4}-e1"; mk_sub "$S1936" "${T4}-er1"; mk_sub "$S1936" "${T4}-e2"
node "$LED" append --session "$S1936" --task "$T4" --role planner --agent "${T4}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T4" --role plan-review --agent "${T4}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T00:30:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T4" --role executor --agent "${T4}-e1" --artifact "PR #${T4}-r1" --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T4" --role execution-review --agent "${T4}-er1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T4" --role executor --agent "${T4}-e2" --artifact "PR #${T4}-r2" --closed-at "2026-01-01T03:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T4" 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "STALE-REVIEW" && echo "$OUT" | command grep -q "execution-review"; } \
  && ok "1936 AC-4: stale review of a SUPERSEDED executor round -> STALE-REVIEW + execution-review (kills a verdict-only fix)" \
  || bad "1936 AC-4 failed (rc=$RC out=$OUT)"

# ---- AC-5: GREEN disjunct -- a fresh execution-review round (the sanctioned remedy) is NOT false-blocked. ----
mk_sub "$S1936" "${T4}-er2"
node "$LED" append --session "$S1936" --task "$T4" --role execution-review --agent "${T4}-er2" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T04:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T4" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-5: fresh execution-review round (distinct agent, PASS, newer closedAt) -> ALLOW (sanctioned remedy not false-blocked, #1179 class)" \
  || bad "1936 AC-5 failed (rc=$RC out=$OUT)"

# ---- AC-6: planner pair, (a) STALE-REVIEW fires (b) fresh review clears it (c) resume-re-close twin ALLOWS. ----
T6="1936ac6"
mk_sub "$S1936" "${T6}-p1"; mk_sub "$S1936" "${T6}-pr1"; mk_sub "$S1936" "${T6}-e1"; mk_sub "$S1936" "${T6}-er1"
node "$LED" append --session "$S1936" --task "$T6" --role planner --agent "${T6}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6" --role plan-review --agent "${T6}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6" --role executor --agent "${T6}-e1" --artifact "PR #$T6" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6" --role execution-review --agent "${T6}-er1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T03:00:00Z" >/dev/null
mk_sub "$S1936" "${T6}-p2"
node "$LED" append --session "$S1936" --task "$T6" --role planner --agent "${T6}-p2" --artifact "$TMP/plan.md" --closed-at "2026-01-01T04:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T6" 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "STALE-REVIEW" && echo "$OUT" | command grep -q "plan-review"; } \
  && ok "1936 AC-6(a): new planner round unreviewed -> STALE-REVIEW + plan-review" \
  || bad "1936 AC-6(a) failed (rc=$RC out=$OUT)"

mk_sub "$S1936" "${T6}-pr2"
node "$LED" append --session "$S1936" --task "$T6" --role plan-review --agent "${T6}-pr2" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T05:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T6" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-6(b): fresh plan-review round covering the new planner round -> ALLOW" \
  || bad "1936 AC-6(b) failed (rc=$RC out=$OUT)"

T6C="1936ac6c"
mk_sub "$S1936" "${T6C}-p1"; mk_sub "$S1936" "${T6C}-pr1"; mk_sub "$S1936" "${T6C}-e1"; mk_sub "$S1936" "${T6C}-er1"
node "$LED" append --session "$S1936" --task "$T6C" --role planner --agent "${T6C}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6C" --role plan-review --agent "${T6C}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6C" --role executor --agent "${T6C}-e1" --artifact "PR #$T6C" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6C" --role execution-review --agent "${T6C}-er1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T03:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T6C" --role planner --agent "${T6C}-p1" --closed-at "2026-01-01T06:00:00Z" >/dev/null
pcount6c=$(command grep -c '"role":"planner"' "$THREE_ROLE_LEDGER_DIR/$S1936/$T6C.jsonl")
OUT=$(node "$LED" check --session "$S1936" --task "$T6C" 2>&1); RC=$?
{ [ "$pcount6c" = "1" ] && [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-6(c): resume-re-close twin (SAME planner agent, only a newer closed-at, single row, closedAt > review's) -> ALLOW (kills the #1760/#1719 false-block class)" \
  || bad "1936 AC-6(c) failed (planner-rows=$pcount6c rc=$RC out=$OUT)"

# ---- AC-7: can't-tell fails OPEN (legacy / oracle / verdict-absent shapes keep working). ----
T7A="1936ac7a"
mk_sub "$S1936" "${T7A}-p1"; mk_sub "$S1936" "${T7A}-pr1"; mk_sub "$S1936" "${T7A}-e1"; mk_sub "$S1936" "${T7A}-er1"
node "$LED" append --session "$S1936" --task "$T7A" --role planner --agent "${T7A}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7A" --role plan-review --agent "${T7A}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7A" --role executor --agent "${T7A}-e1" --artifact "PR #$T7A" >/dev/null
node "$LED" append --session "$S1936" --task "$T7A" --role execution-review --agent "${T7A}-er1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T02:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T7A" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-7(a): executor row with NO closedAt -> can't-tell fails OPEN, still ALLOW" \
  || bad "1936 AC-7(a) failed (rc=$RC out=$OUT)"

T7B="1936ac7b"
mk_sub "$S1936" "${T7B}-p1"; mk_sub "$S1936" "${T7B}-pr1"; mk_sub "$S1936" "${T7B}-e1"
printf 'tests: 3 passed -- PASS\n' > "$TMP/oracle-1936.txt"
node "$LED" append --session "$S1936" --task "$T7B" --role planner --agent "${T7B}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7B" --role plan-review --agent "${T7B}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7B" --role execution-review --oracle "$TMP/oracle-1936.txt" >/dev/null
node "$LED" append --session "$S1936" --task "$T7B" --role executor --agent "${T7B}-e1" --artifact "PR #$T7B" --closed-at "2026-01-01T02:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T7B" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-7(b): oracle-shaped execution-review (no verdict field anywhere, no agentId) with a later-closed executor -> ALLOW" \
  || bad "1936 AC-7(b) failed (rc=$RC out=$OUT)"

T7C="1936ac7c"
mk_sub "$S1936" "${T7C}-p1"; mk_sub "$S1936" "${T7C}-pr1"; mk_sub "$S1936" "${T7C}-e1"; mk_sub "$S1936" "${T7C}-er1"
node "$LED" append --session "$S1936" --task "$T7C" --role planner --agent "${T7C}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7C" --role plan-review --agent "${T7C}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7C" --role executor --agent "${T7C}-e1" --artifact "PR #$T7C" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T7C" --role execution-review --agent "${T7C}-er1" --artifact "$TMP/rev.md" --closed-at "2026-01-01T05:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T7C" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-7(c) Lane-B twin: execution-review bound+artifact+FRESHEST closedAt but NO verdict anywhere in its history -> Lane B stays silent, ALLOW" \
  || bad "1936 AC-7(c) failed (rc=$RC out=$OUT)"

# ---- AC-8: artifact-only re-points for ALL FOUR roles, executor LAST -- still ALLOW. ----
T8="1936ac8"
mk_green4_1936 "$T8" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" "2026-01-01T02:00:00Z" "2026-01-01T03:00:00Z"
node "$LED" append --session "$S1936" --task "$T8" --role planner --artifact "$TMP/plan.md" >/dev/null
node "$LED" append --session "$S1936" --task "$T8" --role plan-review --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$S1936" --task "$T8" --role execution-review --artifact "$TMP/rev.md" >/dev/null
node "$LED" append --session "$S1936" --task "$T8" --role executor --artifact "PR #${T8}-repointed" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T8" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-8: artifact-only re-points (all 4 roles, executor LAST) -> STILL ALLOW (ts-refresh/block-relocation-fragile implementations would false-block here)" \
  || bad "1936 AC-8 failed (rc=$RC out=$OUT)"

# ---- AC-9: allowlist pinned at BOTH edges. Single-round fixtures (the target verdict IS the role's only
# ---- round) -- deliberately avoids a same-role verdict-CHANGE across rounds, which is the pre-existing,
# ---- untouched write-side clause-2 guard's OWN jurisdiction (it requires a spawn-tag-BOUND --agent, not
# ---- merely a resolvable one -- irrelevant to what Lane B is being proven here). ----
T9A="1936ac9a"
mk_sub "$S1936" "${T9A}-p1"; mk_sub "$S1936" "${T9A}-pr1"; mk_sub "$S1936" "${T9A}-e1"; mk_sub "$S1936" "${T9A}-er1"
node "$LED" append --session "$S1936" --task "$T9A" --role planner --agent "${T9A}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9A" --role plan-review --agent "${T9A}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9A" --role executor --agent "${T9A}-e1" --artifact "PR #$T9A" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9A" --role execution-review --agent "${T9A}-er1" --artifact "$TMP/rev.md" --verdict PASS-WITH-FIXES --closed-at "2026-01-01T03:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T9A" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
  && ok "1936 AC-9(a): fresh execution-review PASS-WITH-FIXES -> ALLOW (check-lane allowlist, separate from :844)" \
  || bad "1936 AC-9(a) failed (rc=$RC out=$OUT)"

T9B="1936ac9b"
mk_sub "$S1936" "${T9B}-p1"; mk_sub "$S1936" "${T9B}-pr1"; mk_sub "$S1936" "${T9B}-e1"; mk_sub "$S1936" "${T9B}-er1"
node "$LED" append --session "$S1936" --task "$T9B" --role planner --agent "${T9B}-p1" --artifact "$TMP/plan.md" --closed-at "2026-01-01T00:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9B" --role plan-review --agent "${T9B}-pr1" --artifact "$TMP/rev.md" --verdict PASS --closed-at "2026-01-01T01:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9B" --role executor --agent "${T9B}-e1" --artifact "PR #$T9B" --closed-at "2026-01-01T02:00:00Z" >/dev/null
node "$LED" append --session "$S1936" --task "$T9B" --role execution-review --agent "${T9B}-er1" --artifact "$TMP/rev.md" --verdict NEEDS-WORK --closed-at "2026-01-01T03:00:00Z" >/dev/null
OUT=$(node "$LED" check --session "$S1936" --task "$T9B" 2>&1); RC=$?
{ [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
  && ok "1936 AC-9(b): fresh execution-review NEEDS-WORK -> NEGATIVE-VERDICT (not in the check-lane allowlist)" \
  || bad "1936 AC-9(b) failed (rc=$RC out=$OUT)"

# ---- AC-14: supersession precondition pinned at BOTH edges (RAW JSONL, hand-written-state population), ----
# ---- both review roles. ----
for RROLE_14 in execution-review plan-review; do
  T14A="1936ac14a-${RROLE_14}"
  mk_baseline3_1936 "$T14A" "$RROLE_14"
  F14A="$THREE_ROLE_LEDGER_DIR/$S1936/${T14A}.jsonl"
  mk_sub "$S1936" "ac14-${RROLE_14}-A1"
  raw_append_1936 "$F14A" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-A1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T10:00:00Z\"}"
  raw_append_1936 "$F14A" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-A1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\",\"closedAt\":\"2026-01-01T11:00:00Z\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T14A" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-14(a) $RROLE_14: SAME agentId + newer closedAt -> STILL NEGATIVE-VERDICT (not a genuinely new reviewer)" \
    || bad "1936 AC-14(a) $RROLE_14 failed (rc=$RC out=$OUT)"

  T14B="1936ac14b-${RROLE_14}"
  mk_baseline3_1936 "$T14B" "$RROLE_14"
  F14B="$THREE_ROLE_LEDGER_DIR/$S1936/${T14B}.jsonl"
  mk_sub "$S1936" "ac14-${RROLE_14}-B1"; mk_sub "$S1936" "ac14-${RROLE_14}-B2"
  raw_append_1936 "$F14B" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-B1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T10:00:00Z\"}"
  raw_append_1936 "$F14B" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-B2\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T14B" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-14(b) $RROLE_14: distinct agentId, closedAt ABSENT -> STILL NEGATIVE-VERDICT" \
    || bad "1936 AC-14(b)-absent $RROLE_14 failed (rc=$RC out=$OUT)"

  T14B2="1936ac14b2-${RROLE_14}"
  mk_baseline3_1936 "$T14B2" "$RROLE_14"
  F14B2="$THREE_ROLE_LEDGER_DIR/$S1936/${T14B2}.jsonl"
  raw_append_1936 "$F14B2" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-B1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T10:00:00Z\"}"
  raw_append_1936 "$F14B2" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-B2\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\",\"closedAt\":\"2026-01-01T09:00:00Z\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T14B2" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-14(b) $RROLE_14: distinct agentId, closedAt OLDER (<= T1) -> STILL NEGATIVE-VERDICT" \
    || bad "1936 AC-14(b)-older $RROLE_14 failed (rc=$RC out=$OUT)"

  T14C1="1936ac14c1-${RROLE_14}"
  mk_baseline3_1936 "$T14C1" "$RROLE_14"
  F14C1="$THREE_ROLE_LEDGER_DIR/$S1936/${T14C1}.jsonl"
  mk_sub "$S1936" "ac14-${RROLE_14}-C1"; mk_sub "$S1936" "ac14-${RROLE_14}-C2"
  raw_append_1936 "$F14C1" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-C1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T10:00:20Z\"}"
  raw_append_1936 "$F14C1" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-C2\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\",\"closedAt\":\"2026-01-01T10:00:20.500Z\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T14C1" 2>&1); RC=$?
  { [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
    && ok "1936 AC-14(c) $RROLE_14 accept-leg: sub-second closedAt numerically NEWER (lexicographically SMALLER) -> ALLOW (epoch, never string, comparison)" \
    || bad "1936 AC-14(c)-accept $RROLE_14 failed (rc=$RC out=$OUT)"

  T14C2="1936ac14c2-${RROLE_14}"
  mk_baseline3_1936 "$T14C2" "$RROLE_14"
  F14C2="$THREE_ROLE_LEDGER_DIR/$S1936/${T14C2}.jsonl"
  raw_append_1936 "$F14C2" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-C1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T10:00:20.500Z\"}"
  raw_append_1936 "$F14C2" "{\"role\":\"${RROLE_14}\",\"session_id\":\"$S1936\",\"agentId\":\"ac14-${RROLE_14}-C2\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\",\"closedAt\":\"2026-01-01T10:00:20Z\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T14C2" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-14(c) $RROLE_14 refuse-leg: sub-second closedAt numerically OLDER (lexicographically LARGER) -> STILL NEGATIVE-VERDICT" \
    || bad "1936 AC-14(c)-refuse $RROLE_14 failed (rc=$RC out=$OUT)"
done

# ---- AC-15: the sanctioned self-append flow passes against a shielded state (B5's regression proof), ----
# ---- both review roles -- built through the real CLI, mirroring the live three-write lifecycle exactly. ----
for RROLE_15 in execution-review plan-review; do
  T15="1936ac15-${RROLE_15}"
  mk_baseline3_1936 "$T15" "$RROLE_15"
  mk_sub "$S1936" "ac15-${RROLE_15}-A1"; mk_sub "$S1936" "ac15-${RROLE_15}-A2"
  # (1) full FAIL review round, three-write lifecycle: spawn -> mid-turn self-append -> stop-shaped closed-at.
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --agent "ac15-${RROLE_15}-A1" >/dev/null
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --artifact "$TMP/rev.md" --verdict FAIL >/dev/null
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --agent "ac15-${RROLE_15}-A1" --closed-at "2026-01-01T10:00:00Z" >/dev/null
  # (2) round-2 spawn-shaped append (A2, distinct) -- the interposed bare row, the DEFAULT shield state.
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --agent "ac15-${RROLE_15}-A2" >/dev/null

  # (a) the doctrine command, verbatim shape -- NO --agent, NO --closed-at -- must exit 0 (write path
  #     completely unchanged; this is the exact command round-3's write-side re-key was measured to refuse).
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --artifact "$TMP/rev.md" --verdict PASS >"$TMP/1936-ac15-a-${RROLE_15}.out" 2>&1; DRC=$?
  { [ "$DRC" = "0" ]; } \
    && ok "1936 AC-15(a) $RROLE_15: doctrine self-append (no --agent, no --closed-at) over a shielded FAIL -> exits 0 (write path never touched)" \
    || bad "1936 AC-15(a) $RROLE_15 failed (rc=$DRC out=$(cat "$TMP/1936-ac15-a-${RROLE_15}.out"))"

  # (b) check AT THIS transient point (PASS self-appended, punch-out NOT yet stamped) -- must STILL block
  #     negative. THIS is the leg the fresh execution-review found still RED pre-fix; it must be GREEN now.
  OUT=$(node "$LED" check --session "$S1936" --task "$T15" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-15(b) $RROLE_15: transient window (PASS self-appended, no closedAt yet) -> STILL NEGATIVE-VERDICT (fails SAFE toward the negative) -- the fix's discriminating leg" \
    || bad "1936 AC-15(b) $RROLE_15 FAILED -- this is the documented pre-fix RED that must flip to GREEN (rc=$RC out=$OUT)"

  # (c) stop-shaped append (A2, closed-at T2 > T1) -- the SubagentStop punch-out -- check now ALLOWS.
  node "$LED" append --session "$S1936" --task "$T15" --role "$RROLE_15" --agent "ac15-${RROLE_15}-A2" --closed-at "2026-01-01T11:00:00Z" >/dev/null
  OUT=$(node "$LED" check --session "$S1936" --task "$T15" 2>&1); RC=$?
  { [ "$RC" = "0" ] && echo "$OUT" | command grep -qi "OK"; } \
    && ok "1936 AC-15(c) $RROLE_15: full sanctioned lifecycle complete (distinct agent + affirmative verdict + strictly-newer closedAt) -> ALLOW" \
    || bad "1936 AC-15(c) $RROLE_15 failed (rc=$RC out=$OUT)"
done

# ---- AC-2: committed synthetic twin of AC-1 (the REAL #1821 hero case), BOTH review roles. Field-for-field ----
# ---- replica: full FAIL review round, then a bare distinct-agent round-2 append (the #1821 shield shape). ----
for RROLE_2 in execution-review plan-review; do
  T2="1936ac2-${RROLE_2}"
  mk_baseline3_1936 "$T2" "$RROLE_2"
  mk_sub "$S1936" "ac2-${RROLE_2}-RA1"; mk_sub "$S1936" "ac2-${RROLE_2}-RA2"
  node "$LED" append --session "$S1936" --task "$T2" --role "$RROLE_2" --agent "ac2-${RROLE_2}-RA1" --artifact "$TMP/rev.md" --verdict FAIL --closed-at "2026-01-01T00:15:00Z" >/dev/null
  node "$LED" append --session "$S1936" --task "$T2" --role "$RROLE_2" --agent "ac2-${RROLE_2}-RA2" >/dev/null   # bare round-2 spawn -- the #1821 shield row

  # (leg 1) bare state -> check blocks with NEGATIVE-VERDICT + the role name.
  OUT=$(node "$LED" check --session "$S1936" --task "$T2" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT" && echo "$OUT" | command grep -q "$RROLE_2"; } \
    && ok "1936 AC-2($RROLE_2) leg1: bare #1821-shape shield row -> NEGATIVE-VERDICT + role name" \
    || bad "1936 AC-2($RROLE_2) leg1 failed (rc=$RC out=$OUT)"

  # (leg 2) artifact-only re-point onto the bare shield row -> STILL blocks.
  node "$LED" append --session "$S1936" --task "$T2" --role "$RROLE_2" --artifact "$TMP/rev.md" >/dev/null
  OUT=$(node "$LED" check --session "$S1936" --task "$T2" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-2($RROLE_2) leg2: artifact-only re-point laundering -> STILL blocks" \
    || bad "1936 AC-2($RROLE_2) leg2 failed (rc=$RC out=$OUT)"

  # (leg iv-a) BOTH attribution-free appends LAND (exit 0 each -- write path unchanged, the scope pin) and
  #            check STILL blocks afterwards (the B4 verdict-overlay laundering, killed at the READ side).
  node "$LED" append --session "$S1936" --task "$T2" --role "$RROLE_2" --artifact "$TMP/rev.md" >"$TMP/1936-ac2-iva1-${RROLE_2}.out" 2>&1; R1=$?
  node "$LED" append --session "$S1936" --task "$T2" --role "$RROLE_2" --verdict PASS >"$TMP/1936-ac2-iva2-${RROLE_2}.out" 2>&1; R2=$?
  OUT=$(node "$LED" check --session "$S1936" --task "$T2" 2>&1); RC=$?
  { [ "$R1" = "0" ] && [ "$R2" = "0" ] && [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-2($RROLE_2) leg(iv-a): both attribution-free appends land (exit0/exit0, write path unchanged) yet check STILL blocks" \
    || bad "1936 AC-2($RROLE_2) leg(iv-a) failed (r1=$R1 r2=$R2 rc=$RC out=$OUT)"

  # (leg iv-b) raw-JSONL hand-written twin, on a FRESH task: FAIL round complete, then a DIRECTLY-appended
  #            laundered row (verdict PASS, a DISTINCT agentId, NO closedAt -- the exact merged shape the
  #            CLI produces in leg iv-a) -- still blocks.
  T2B="1936ac2b-${RROLE_2}"
  mk_baseline3_1936 "$T2B" "$RROLE_2"
  F2B="$THREE_ROLE_LEDGER_DIR/$S1936/${T2B}.jsonl"
  mk_sub "$S1936" "ac2b-${RROLE_2}-RA1"; mk_sub "$S1936" "ac2b-${RROLE_2}-RA2"
  raw_append_1936 "$F2B" "{\"role\":\"${RROLE_2}\",\"session_id\":\"$S1936\",\"agentId\":\"ac2b-${RROLE_2}-RA1\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"FAIL\",\"closedAt\":\"2026-01-01T00:15:00Z\"}"
  raw_append_1936 "$F2B" "{\"role\":\"${RROLE_2}\",\"session_id\":\"$S1936\",\"agentId\":\"ac2b-${RROLE_2}-RA2\",\"artifact_path\":\"$TMP/rev.md\",\"verdict\":\"PASS\"}"
  OUT=$(node "$LED" check --session "$S1936" --task "$T2B" 2>&1); RC=$?
  { [ "$RC" != "0" ] && echo "$OUT" | command grep -qi "NEGATIVE-VERDICT"; } \
    && ok "1936 AC-2($RROLE_2) leg(iv-b): directly-written laundered row (distinct agentId, NO closedAt) -> STILL blocks (kills a distinct-agentId-only read rule)" \
    || bad "1936 AC-2($RROLE_2) leg(iv-b) failed (rc=$RC out=$OUT)"
done

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
