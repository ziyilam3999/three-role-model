#!/usr/bin/env bash
# Hermetic red/green oracle for #2496 — the in-session, merge-head-gated SIBLING-TOKEN resolution arm in
# `hooks/3role-ledger.mjs check`. Exit 0 = all pass. No `set -e` (a non-block non-zero from a checked
# command must NOT abort the suite — fail-open hygiene, same discipline as hooks/3role-ledger-smoke-test.sh).
#
# What this covers (AC labels map 1:1 to the #2496 plan's Binary AC):
#   AC-1 shape — a bare-token stub (planner-only ledger) + a genuinely complete, merge-head-bound sibling
#     ledger: BLOCK when the merge head predates the review commit (RED), OK when the merge head is the
#     commit that ADDS the review (GREEN) — naming the sibling on stdout.
#   AC-2 — RED power: no candidate sibling at all; a sibling that exists but is INCOMPLETE; and the
#     token-boundary probe (a shorter numeric task must never resolve a longer sibling sharing its digit
#     prefix — paired with a power control proving the SAME sibling DOES resolve its true, longer task).
#   AC-3 — RED power: a complete sibling whose execution-review evidence resolves ONLY via the
#     origin/master fallback (absent at the merge head itself) — merge-head binding is preserved.
#   AC-6 — RED-first power: two twins on ONE fixture repo. (a) INHERITED — the review file is already on
#     origin/master and the merge head only inherits it via tree ancestry (no commit of its own adds it) —
#     must stay BLOCK, with a `git cat-file -e` assertion pinning that the artifact IS a blob at the merge
#     head (so a resolver regressed to tree-membership binding would visibly flip this fixture to exit 0).
#     (b) ADDED — the merge head's OWN commit adds the review file, absent at origin/master — flips to OK.
#
# Every fixture is hermetic: mktemp -d throwaway git repos + a COPIED 3role-ledger.mjs inside each repo's
# own hooks/ dir (the established hooks/3role-ledger-smoke-test.sh #2088-AC5(b)/AC11(a) pattern) so
# aiBrainToplevel() resolves to the FIXTURE repo, never the real ai-brain checkout — no network, no push,
# plumbing-only git ops (update-ref / cat-file / show), consistent with the resolver's own plugin-safety
# contract (pure fs + local git plumbing reads).
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
SID="sess-2496-sib"

mk_sub() { mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"; printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1" > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"; }

printf '## ELI5\na plan\n### Binary AC\n- AC1\n' > "$TMP/plan.md"
printf '## Review\nverdict: PASS\n' > "$TMP/rev.md"

# Fresh copied-helper fixture repo: git init + a hooks/3role-ledger.mjs copy so aiBrainToplevel() (used by
# the ref-scoped arm's candidate-2 fallback) resolves to THIS repo, never the real ai-brain checkout.
mk_fixture_repo() {
  local repo="$1"
  ( cd "$repo" && git init -q && git config user.email t@t.co && git config user.name t && git commit -q --allow-empty -m seed )
  mkdir -p "$repo/hooks"
  cp "$LED" "$repo/hooks/3role-ledger.mjs"
}

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-1 shape — RED (merge head predates the review commit) -> GREEN (merge head IS the review-adding commit)
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC1REPO="$(mktemp -d)"
mk_fixture_repo "$AC1REPO"
LED1="$AC1REPO/hooks/3role-ledger.mjs"
AC1_UNRELATED=$(git -C "$AC1REPO" rev-parse HEAD)
git -C "$AC1REPO" update-ref refs/remotes/origin/master "$AC1_UNRELATED"
mkdir -p "$AC1REPO/.ai-workspace/reviews"
printf '## Review\nDecision: PASS\n' > "$AC1REPO/.ai-workspace/reviews/2496-ac1-execreview.md"
( cd "$AC1REPO" && git add .ai-workspace/reviews/2496-ac1-execreview.md && git commit -q -m "fixture: AC-1 slice adds its own review" )
AC1_ADDED=$(git -C "$AC1REPO" rev-parse HEAD)
rm -f "$AC1REPO/.ai-workspace/reviews/2496-ac1-execreview.md"   # keep the working copy clean of the disk arm (N1 hazard)

T_AC1="2496ac1"
mk_sub "$SID" ac1p1
node "$LED1" append --session "$SID" --task "$T_AC1" --role planner --agent ac1p1 --artifact "$TMP/plan.md" >/dev/null
SIBT_AC1="${T_AC1}-scanner-build"
mk_sub "$SID" ac1sp1; mk_sub "$SID" ac1sr1; mk_sub "$SID" ac1se1
node "$LED1" append --session "$SID" --task "$SIBT_AC1" --role planner --agent ac1sp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED1" append --session "$SID" --task "$SIBT_AC1" --role plan-review --agent ac1sr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED1" append --session "$SID" --task "$SIBT_AC1" --role executor --agent ac1sp1 --artifact "PR #2496ac1" >/dev/null
node "$LED1" append --session "$SID" --task "$SIBT_AC1" --role execution-review --agent ac1se1 --artifact ".ai-workspace/reviews/2496-ac1-execreview.md" --verdict PASS >/dev/null

OUT=$(cd "$AC1REPO" && node "$LED1" check --session "$SID" --task "$T_AC1" --merge-head "$AC1_UNRELATED" 2>&1); RC=$?
{ [ "$RC" = "2" ]; } \
  && ok "AC-1 shape RED: bare-token stub + qualifying sibling, but merge-head PREDATES the review commit -> stays BLOCK" \
  || bad "AC-1 shape RED FAILED (rc=$RC out=$OUT)"

OUT=$(cd "$AC1REPO" && node "$LED1" check --session "$SID" --task "$T_AC1" --merge-head "$AC1_ADDED" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -q "SIBLING-RESOLVE" && echo "$OUT" | command grep -qF "$SIBT_AC1"; } \
  && ok "AC-1 shape GREEN: same ledger, merge-head IS the commit that ADDS the review -> resolves via sibling, names it on stdout" \
  || bad "AC-1 shape GREEN FAILED (rc=$RC out=$OUT)"
rm -rf "$AC1REPO"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-2 — RED power: no sibling at all; sibling present but incomplete; token-boundary discipline
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC2REPO="$(mktemp -d)"
mk_fixture_repo "$AC2REPO"
LED2="$AC2REPO/hooks/3role-ledger.mjs"
AC2_SEED=$(git -C "$AC2REPO" rev-parse HEAD)
git -C "$AC2REPO" update-ref refs/remotes/origin/master "$AC2_SEED"

# (a) no candidate sibling at all.
T_AC2A="2496ac2a"
mk_sub "$SID" ac2ap1
node "$LED2" append --session "$SID" --task "$T_AC2A" --role planner --agent ac2ap1 --artifact "$TMP/plan.md" >/dev/null
OUT=$(cd "$AC2REPO" && node "$LED2" check --session "$SID" --task "$T_AC2A" --merge-head "$AC2_SEED" 2>&1); RC=$?
{ [ "$RC" = "2" ]; } \
  && ok "AC-2(a) RED power: no candidate sibling exists at all -> stays BLOCK" \
  || bad "AC-2(a) FAILED (rc=$RC out=$OUT)"

# (b) sibling exists but is INCOMPLETE (no execution-review row at all).
T_AC2B="2496ac2b"
mk_sub "$SID" ac2bp1
node "$LED2" append --session "$SID" --task "$T_AC2B" --role planner --agent ac2bp1 --artifact "$TMP/plan.md" >/dev/null
SIBT_AC2B="${T_AC2B}-scanner-build"
mk_sub "$SID" ac2bsp1; mk_sub "$SID" ac2bsr1
node "$LED2" append --session "$SID" --task "$SIBT_AC2B" --role planner --agent ac2bsp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED2" append --session "$SID" --task "$SIBT_AC2B" --role plan-review --agent ac2bsr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED2" append --session "$SID" --task "$SIBT_AC2B" --role executor --agent ac2bsp1 --artifact "PR #2496ac2b" >/dev/null
OUT=$(cd "$AC2REPO" && node "$LED2" check --session "$SID" --task "$T_AC2B" --merge-head "$AC2_SEED" 2>&1); RC=$?
{ [ "$RC" = "2" ]; } \
  && ok "AC-2(b) RED power: sibling exists but is INCOMPLETE (no execution-review row) -> stays BLOCK" \
  || bad "AC-2(b) FAILED (rc=$RC out=$OUT)"

# (c) token-boundary discipline: a genuinely qualifying sibling under the LONGER token "1660-…" must never
# resolve the SHORTER, digit-prefix-sharing bare token "166" -- paired with a power control proving the
# SAME sibling DOES resolve its own true, longer bare token "1660" (the oracle can say YES).
mkdir -p "$AC2REPO/.ai-workspace/reviews"
printf '## Review\nDecision: PASS\n' > "$AC2REPO/.ai-workspace/reviews/2496-ac2c-execreview.md"
( cd "$AC2REPO" && git add .ai-workspace/reviews/2496-ac2c-execreview.md && git commit -q -m "fixture: AC-2c token-boundary probe" )
AC2C_HEAD=$(git -C "$AC2REPO" rev-parse HEAD)
SIBT_AC2C="1660-scanner-build"
mk_sub "$SID" ac2csp1; mk_sub "$SID" ac2csr1; mk_sub "$SID" ac2cse1
node "$LED2" append --session "$SID" --task "$SIBT_AC2C" --role planner --agent ac2csp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED2" append --session "$SID" --task "$SIBT_AC2C" --role plan-review --agent ac2csr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED2" append --session "$SID" --task "$SIBT_AC2C" --role executor --agent ac2csp1 --artifact "PR #2496ac2c" >/dev/null
node "$LED2" append --session "$SID" --task "$SIBT_AC2C" --role execution-review --agent ac2cse1 --artifact ".ai-workspace/reviews/2496-ac2c-execreview.md" --verdict PASS >/dev/null

T_AC2C="166"
mk_sub "$SID" ac2cp1
node "$LED2" append --session "$SID" --task "$T_AC2C" --role planner --agent ac2cp1 --artifact "$TMP/plan.md" >/dev/null

OUT_POWER=$(cd "$AC2REPO" && node "$LED2" check --session "$SID" --task "1660" --merge-head "$AC2C_HEAD" 2>&1); RC_POWER=$?
OUT_SHORT=$(cd "$AC2REPO" && node "$LED2" check --session "$SID" --task "$T_AC2C" --merge-head "$AC2C_HEAD" 2>&1); RC_SHORT=$?
{ [ "$RC_POWER" = "0" ] && [ "$RC_SHORT" = "2" ]; } \
  && ok "AC-2(c) token-boundary: a qualifying sibling under '1660-…' resolves its true task '1660' (rc=0, power control) but NEVER the shorter digit-prefix-sharing task '166' (rc=2)" \
  || bad "AC-2(c) FAILED (rc_power=$RC_POWER out_power=$OUT_POWER rc_short=$RC_SHORT out_short=$OUT_SHORT)"
rm -rf "$AC2REPO"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-3 — RED power: sibling's execution-review evidence resolves ONLY via origin/master (absent at the
# merge head itself) -- merge-head binding is preserved (orthogonal to AC-6's inherited-in-tree case).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC3REPO="$(mktemp -d)"
mk_fixture_repo "$AC3REPO"
LED3="$AC3REPO/hooks/3role-ledger.mjs"
AC3_MERGEHEAD=$(git -C "$AC3REPO" rev-parse HEAD)   # deliberately WITHOUT the review file
mkdir -p "$AC3REPO/.ai-workspace/reviews"
printf '## Review\nDecision: PASS\n' > "$AC3REPO/.ai-workspace/reviews/2496-ac3-execreview.md"
( cd "$AC3REPO" && git add .ai-workspace/reviews/2496-ac3-execreview.md && git commit -q -m "fixture: AC-3 review lands on master, never on the merge head" )
AC3_MASTER=$(git -C "$AC3REPO" rev-parse HEAD)
git -C "$AC3REPO" update-ref refs/remotes/origin/master "$AC3_MASTER"
rm -f "$AC3REPO/.ai-workspace/reviews/2496-ac3-execreview.md"

T_AC3="2496ac3"
mk_sub "$SID" ac3p1
node "$LED3" append --session "$SID" --task "$T_AC3" --role planner --agent ac3p1 --artifact "$TMP/plan.md" >/dev/null
SIBT_AC3="${T_AC3}-scanner-build"
mk_sub "$SID" ac3sp1; mk_sub "$SID" ac3sr1; mk_sub "$SID" ac3se1
node "$LED3" append --session "$SID" --task "$SIBT_AC3" --role planner --agent ac3sp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED3" append --session "$SID" --task "$SIBT_AC3" --role plan-review --agent ac3sr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED3" append --session "$SID" --task "$SIBT_AC3" --role executor --agent ac3sp1 --artifact "PR #2496ac3" >/dev/null
node "$LED3" append --session "$SID" --task "$SIBT_AC3" --role execution-review --agent ac3se1 --artifact ".ai-workspace/reviews/2496-ac3-execreview.md" --verdict PASS >/dev/null

# Assert the fixture's own discriminating power first: the artifact is genuinely absent from the merge
# head's tree (so ADDED-BY-PR's "present at merge-head" conjunct genuinely has something to reject).
if git -C "$AC3REPO" cat-file -e "$AC3_MERGEHEAD:.ai-workspace/reviews/2496-ac3-execreview.md" 2>/dev/null; then
  bad "AC-3 fixture setup broken: the review blob is unexpectedly present at the merge head"
else
  ok "AC-3 fixture pin: the review blob is genuinely ABSENT at the merge head (present only on origin/master)"
fi

OUT=$(cd "$AC3REPO" && node "$LED3" check --session "$SID" --task "$T_AC3" --merge-head "$AC3_MERGEHEAD" 2>&1); RC=$?
{ [ "$RC" = "2" ]; } \
  && ok "AC-3 RED power: complete sibling whose execution-review evidence resolves ONLY via origin/master (absent at the merge head itself) -> stays BLOCK (merge-head binding preserved)" \
  || bad "AC-3 FAILED (rc=$RC out=$OUT)"
rm -rf "$AC3REPO"

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# AC-6 — RED-first power, two twins on ONE fixture repo: (a) INHERITED (must stay BLOCK, tree-membership
# power pinned by a `git cat-file -e` assertion), (b) ADDED (flips to OK).
# ════════════════════════════════════════════════════════════════════════════════════════════════════
AC6REPO="$(mktemp -d)"
mk_fixture_repo "$AC6REPO"
LED6="$AC6REPO/hooks/3role-ledger.mjs"
AC6_DEFAULT_BRANCH=$(git -C "$AC6REPO" branch --show-current)

# Master already carries reviewA.md (the shipped-sibling steady state the round-1 finding exploited).
mkdir -p "$AC6REPO/.ai-workspace/reviews"
printf '## Review\nDecision: PASS\n' > "$AC6REPO/.ai-workspace/reviews/2496-ac6-reviewA.md"
( cd "$AC6REPO" && git add .ai-workspace/reviews/2496-ac6-reviewA.md && git commit -q -m "fixture: AC-6 reviewA ships to master" )
AC6_MASTER=$(git -C "$AC6REPO" rev-parse HEAD)
git -C "$AC6REPO" update-ref refs/remotes/origin/master "$AC6_MASTER"

# Twin (a) INHERITED: branch off master, add an UNRELATED file -- reviewA.md is in this tree by ancestry
# only, never touched by this commit.
git -C "$AC6REPO" checkout -q -b ac6-twin-inherited
mkdir -p "$AC6REPO/.ai-workspace/status"
printf 'unrelated marker\n' > "$AC6REPO/.ai-workspace/status/2496-ac6-marker.md"
( cd "$AC6REPO" && git add .ai-workspace/status/2496-ac6-marker.md && git commit -q -m "fixture: AC-6 twin(a) unrelated commit off master" )
AC6_INHERITED_HEAD=$(git -C "$AC6REPO" rev-parse HEAD)

# Twin (b) ADDED: back to master, branch off it, add reviewB.md -- absent at master, added by THIS commit.
git -C "$AC6REPO" checkout -q "$AC6_DEFAULT_BRANCH"
git -C "$AC6REPO" checkout -q -b ac6-twin-added
printf '## Review\nDecision: PASS\n' > "$AC6REPO/.ai-workspace/reviews/2496-ac6-reviewB.md"
( cd "$AC6REPO" && git add .ai-workspace/reviews/2496-ac6-reviewB.md && git commit -q -m "fixture: AC-6 twin(b) adds its own review" )
AC6_ADDED_HEAD=$(git -C "$AC6REPO" rev-parse HEAD)
git -C "$AC6REPO" checkout -q "$AC6_DEFAULT_BRANCH"
rm -f "$AC6REPO/.ai-workspace/reviews/2496-ac6-reviewA.md" "$AC6REPO/.ai-workspace/reviews/2496-ac6-reviewB.md" "$AC6REPO/.ai-workspace/status/2496-ac6-marker.md"

# Twin (a) ledger: bare-token stub + a complete sibling citing reviewA.md.
T_AC6A="2496ac6a"
mk_sub "$SID" ac6ap1
node "$LED6" append --session "$SID" --task "$T_AC6A" --role planner --agent ac6ap1 --artifact "$TMP/plan.md" >/dev/null
SIBT_AC6A="${T_AC6A}-scanner-build"
mk_sub "$SID" ac6asp1; mk_sub "$SID" ac6asr1; mk_sub "$SID" ac6ase1
node "$LED6" append --session "$SID" --task "$SIBT_AC6A" --role planner --agent ac6asp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6A" --role plan-review --agent ac6asr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6A" --role executor --agent ac6asp1 --artifact "PR #2496ac6a" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6A" --role execution-review --agent ac6ase1 --artifact ".ai-workspace/reviews/2496-ac6-reviewA.md" --verdict PASS >/dev/null

# Pin the fixture's discriminating power: the artifact IS a blob at the merge head (inherited from master)
# -- a resolver regressed to bare tree-membership binding would find this and wrongly exit 0 here.
if git -C "$AC6REPO" cat-file -e "$AC6_INHERITED_HEAD:.ai-workspace/reviews/2496-ac6-reviewA.md" 2>/dev/null; then
  ok "AC-6(a) fixture pin: reviewA.md IS a blob at the INHERITED merge head (tree-membership alone would wrongly allow this)"
else
  bad "AC-6(a) fixture setup broken: reviewA.md is unexpectedly absent from the inherited merge head's tree"
fi

OUT=$(cd "$AC6REPO" && node "$LED6" check --session "$SID" --task "$T_AC6A" --merge-head "$AC6_INHERITED_HEAD" 2>&1); RC=$?
{ [ "$RC" = "2" ]; } \
  && ok "AC-6(a) RED-first power: reviewA.md is INHERITED-in-tree only (already on origin/master) -> stays BLOCK despite tree membership" \
  || bad "AC-6(a) FAILED (rc=$RC out=$OUT)"

# Twin (b) ledger: bare-token stub + a complete sibling citing reviewB.md.
T_AC6B="2496ac6b"
mk_sub "$SID" ac6bp1
node "$LED6" append --session "$SID" --task "$T_AC6B" --role planner --agent ac6bp1 --artifact "$TMP/plan.md" >/dev/null
SIBT_AC6B="${T_AC6B}-scanner-build"
mk_sub "$SID" ac6bsp1; mk_sub "$SID" ac6bsr1; mk_sub "$SID" ac6bse1
node "$LED6" append --session "$SID" --task "$SIBT_AC6B" --role planner --agent ac6bsp1 --artifact "$TMP/plan.md" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6B" --role plan-review --agent ac6bsr1 --artifact "$TMP/rev.md" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6B" --role executor --agent ac6bsp1 --artifact "PR #2496ac6b" >/dev/null
node "$LED6" append --session "$SID" --task "$SIBT_AC6B" --role execution-review --agent ac6bse1 --artifact ".ai-workspace/reviews/2496-ac6-reviewB.md" --verdict PASS >/dev/null

OUT=$(cd "$AC6REPO" && node "$LED6" check --session "$SID" --task "$T_AC6B" --merge-head "$AC6_ADDED_HEAD" 2>&1); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | command grep -q "SIBLING-RESOLVE"; } \
  && ok "AC-6(b) falsification (RED-first flip): reviewB.md is ADDED by this merge head, absent at origin/master -> exits 0" \
  || bad "AC-6(b) FAILED (rc=$RC out=$OUT)"
rm -rf "$AC6REPO"

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
