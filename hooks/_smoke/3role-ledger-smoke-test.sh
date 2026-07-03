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
node "$LED" append --session "$VSID" --task "$VTASK" --role execution-review --skip-reason "n/a" >/dev/null
grep -q '"verdict"' "$VFILE" && bad "#1036 skip should clear verdict (got: $(tail -1 "$VFILE"))" || ok "#1036 skip_reason clears the verdict"
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

# M1. RED: executor transcript=opus, config=sonnet -> check --enforce-role-models exits 2, names role+expected+actual.
model_ledger msRED 9101 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msRED --task 9101 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-POLICY" && echo "$OUT" | grep -qi "executor" && echo "$OUT" | grep -qi "sonnet" && echo "$OUT" | grep -qi "opus"; } \
  && ok "M1 RED: executor=opus vs config=sonnet -> exit 2 (names role+expected+actual)" || bad "M1 wrong model should block (rc=$RC out=$OUT)"

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

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
