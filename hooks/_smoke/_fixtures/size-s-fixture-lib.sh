#!/usr/bin/env bash
# hooks/_fixtures/size-s-fixture-lib.sh -- #3154 hermetic fixture builders for the size-S plan-review waiver.
# SOURCED by the smokes that test the waiver (it defines functions only, runs nothing). Plugin-synced like
# every other fixture the synced smokes read from their _fixtures directory.
#
# Shape (the real one, plan fold B1): every fixture is a throw-away git repo whose ONLY copy of the plan is a
# blob at refs/remotes/origin/<task>-fixture (written with plumbing, never checked out), so the working tree
# the helper runs from has NO .ai-workspace/plans/<plan>. A COPY of the helper lives inside the fixture repo's
# hooks/ so aiBrainToplevel() resolves to the fixture repo, never the real checkout.
# Ticket fixtures hold ONLY {"id","status","metadata":{"size"}} -- never a subject.
#
# The caller exports THREE_ROLE_LEDGER_DIR, THREE_ROLE_PROJECTS_ROOT, PROGRESS_TASKS_DIR and RULE12_LOG first.

# sz_plan_text <task> <variant>: S | M | L | nosize | twosize | unbound  (unbound = no Ticket line; pair it with
# a plan basename that does not carry the task id)
sz_plan_text() {
  case "$2" in
    S)        printf '# Plan\n\nsize: S\nTicket: #%s\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' "$1" ;;
    M)        printf '# Plan\n\nsize: M\nTicket: #%s\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' "$1" ;;
    L)        printf '# Plan\n\nsize: L\nTicket: #%s\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' "$1" ;;
    nosize)   printf '# Plan\n\nTicket: #%s\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' "$1" ;;
    twosize)  printf '# Plan\n\nsize: S\nsize: S\nTicket: #%s\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' "$1" ;;
    unbound)  printf '# Plan\n\nsize: S\n\n## ELI5\na plan\n### Binary AC\n- AC1\n' ;;
    *)        printf '# Plan\n## ELI5\nx\n### Binary AC\n- AC1\n' ;;
  esac
}

# sz_plan_name <task> : the default planner-row artifact_path (primary-relative)
sz_plan_name() { printf '.ai-workspace/plans/2026-10-16-%s-size-s-fixture.md' "$1"; }

# sz_mk_repo <repo-dir> <helper-src> <task> <variant|-> [plan-relative-path]
# variant "-" = no plan blob anywhere (the plan-unresolvable shape).
sz_mk_repo() {
  local repo="$1" helper="$2" task="$3" variant="$4" rel="${5:-}"
  [ -n "$rel" ] || rel="$(sz_plan_name "$task")"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "fixture-bot"
  git -C "$repo" config user.name fixture
  git -C "$repo" commit -q --allow-empty -m seed
  mkdir -p "$repo/hooks"
  cp "$helper" "$repo/hooks/3role-ledger.mjs"
  # plugin layout: a hook copy resolves its helper as ../bin/3role-ledger.mjs, so keep an identical copy there too
  mkdir -p "$repo/bin"; cp "$helper" "$repo/bin/3role-ledger.mjs"
  local seed; seed="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" update-ref refs/remotes/origin/master "$seed"
  if [ "$variant" != "-" ]; then
    local tmpf blob t_file t_plans t_ws c base
    tmpf="$(mktemp)"
    sz_plan_text "$task" "$variant" > "$tmpf"
    blob="$(git -C "$repo" hash-object -w "$tmpf")"
    rm -f "$tmpf"
    base="$(basename "$rel")"
    t_file="$(printf '100644 blob %s\t%s\n' "$blob" "$base" | git -C "$repo" mktree)"
    t_plans="$(printf '040000 tree %s\tplans\n' "$t_file" | git -C "$repo" mktree)"
    t_ws="$(printf '040000 tree %s\t.ai-workspace\n' "$t_plans" | git -C "$repo" mktree)"
    c="$(git -C "$repo" commit-tree "$t_ws" -p "$seed" -m "fixture plan")"
    git -C "$repo" update-ref "refs/remotes/origin/${task}-fixture" "$c"
  fi
}

# sz_ticket <session> <task> <size>: size "-" = no ticket file; otherwise metadata.size is written verbatim.
sz_ticket() {
  local dir="$PROGRESS_TASKS_DIR/$1"
  mkdir -p "$dir"
  if [ "$3" = "-" ]; then rm -f "$dir/$2.json"; return 0; fi
  printf '{"id":"%s","status":"pending","metadata":{"size":"%s"}}\n' "$2" "$3" > "$dir/$2.json"
}

# sz_sub <session> <agentId>: a resolvable subagent transcript under the fixture projects root
sz_sub() {
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents"
  printf '{"isSidechain":true,"agentId":"%s","sessionId":"%s","type":"user"}\n' "$2" "$1" > "$THREE_ROLE_PROJECTS_ROOT/proj/$1/subagents/agent-$2.jsonl"
}

# sz_planner <helper> <session> <task> [plan-relative-path]: the planner row (artifact is the plan path)
sz_planner() {
  local rel="${4:-}"; [ -n "$rel" ] || rel="$(sz_plan_name "$3")"
  sz_sub "$2" "szp$3"
  node "$1" append --session "$2" --task "$3" --role planner --agent "szp$3" --artifact "$rel" >/dev/null 2>&1
}

# sz_chain_tail <helper> <session> <task> <review-file>: executor + execution-review rows (plan-review is NEVER written here)
sz_chain_tail() {
  sz_sub "$2" "sze$3"; sz_sub "$2" "szr$3"
  node "$1" append --session "$2" --task "$3" --role executor --agent "sze$3" --artifact "PR #$3" >/dev/null 2>&1
  THREE_ROLE_LEDGER_EXECREVIEW_ARTIFACT_SHAPE_OFF=1 node "$1" append --session "$2" --task "$3" --role execution-review --agent "szr$3" --artifact "$4" --verdict PASS >/dev/null 2>&1
}

# sz_run <helper> <repo-cwd> <args...>: run the helper from <repo-cwd> (no plan on disk there); sets SZ_OUT and SZ_RC
sz_run() {
  local helper="$1" cwd="$2"; shift 2
  SZ_OUT="$(cd "$cwd" && THREE_ROLE_LEDGER_EXECREVIEW_ARTIFACT_SHAPE_OFF=1 node "$helper" "$@" 2>&1)"; SZ_RC=$?
}

# sz_review_row <helper> <session> <task> <review-file> [verdict]: a COMPLETED, spawn-record-bound plan-review row
# (default verdict PASS). Pass NEEDS-WORK for the negative-review shape.
sz_review_row() {
  local v="${5:-PASS}"
  mkdir -p "$THREE_ROLE_PROJECTS_ROOT/proj/$2/subagents"
  printf '{"type":"user","message":{"role":"user","content":"3ROLE_TASK:%s ROLE:plan-review -- do the work"}}\n' "$3" \
    > "$THREE_ROLE_PROJECTS_ROOT/proj/$2/subagents/agent-szv$3.jsonl"
  node "$1" append --session "$2" --task "$3" --role plan-review --agent "szv$3" --artifact "$4" --verdict "$v" --closed-at "2026-07-11T00:00:00.000Z" >/dev/null 2>&1
}
