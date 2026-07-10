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

# R4. [control] NON-resume mismatch (no resume boundary at all, plain mk_sub_model) -> MUST stay hard-blocked
#     (AC-2's second guard: a resume boundary being ABSENT means the up-tier arm can never fire even though
#     the observed tier IS a strict up-tier over policy).
model_ledger msNORESUME 9304 "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msNORESUME --task 9304 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-POLICY" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[control] R4 non-resume mismatch (no boundary, same up-tier direction) -> STILL exit 2 BLOCK (AC-2, unchanged from M1)" \
  || bad "R4 non-resume mismatch must stay blocked (rc=$RC out=$OUT)"

# R5. [control] resume boundary present but PRE-resume model did NOT match policy either (a genuinely wrong
#     spawn that ALSO got resumed) -> MUST stay hard-blocked — the up-tier arm requires the pre-resume model
#     to have matched policy, proving the mismatch is resume-CAUSED, not a pre-existing wrong spawn.
model_ledger_resume msWRONGSPAWN 9305 "claude-haiku-4-0" "claude-opus-4-8"
OUT=$(CC_ROLES_ENV="$MCFG" node "$LED" check --session msWRONGSPAWN --task 9305 --enforce-role-models 2>&1); RC=$?
{ [ "$RC" = "2" ] && echo "$OUT" | grep -q "MODEL-POLICY" && ! echo "$OUT" | grep -q "RESUME-UPTIER"; } \
  && ok "[control] R5 resume boundary present but pre-resume ALSO mismatched policy -> STILL exit 2 BLOCK (AC-2)" \
  || bad "R5 pre-resume-mismatched-too case must stay blocked (rc=$RC out=$OUT)"

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

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
