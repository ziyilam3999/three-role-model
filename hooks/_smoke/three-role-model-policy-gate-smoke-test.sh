#!/usr/bin/env bash
# Smoke for three-role-model-policy-gate.sh (#1448, effective-tier sensor #1494). Exit 0 = all cases pass.
# The hook is a PreToolUse(Agent|Task) BLOCK-ONCE nudge: on the POSITIVE condition (a tagged role spawn whose
# EFFECTIVE model tier != the role's cc-roles.env policy tier) it exits 2 the FIRST time per taskId+role
# signature, then exits 0 (block-once); everything else fail-opens exit 0 silent. Both-ends: each fixture FAILS
# on wrong behavior, PASSES on correct. No `set -e` (a non-block non-zero must never leak into a permission
# decision — #749).
#
# #1494 ADDS: (a) a SENSOR-UNIT section that calls `node hooks/3role-ledger.mjs resolve-effective-tier`
# directly and asserts its RESOLVED VALUE on stdout (not merely exit 0 — a smoke asserting only exit code on a
# CLI that always exits 0 is vacuous by construction); (b) a GATE section that feeds PreToolUse(Agent) payloads
# to the CURRENT hook AND, for the two REGRESSION-CATCH rows, to a snapshot of the PRE-FIX hook fetched from
# origin/master — proving the leak this ticket exists to close ACTUALLY existed on HEAD (RED-on-HEAD-first;
# a smoke whose red arm can pass via an unrelated fail-open path is vacuous — #1502's exact defect class).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/three-role-model-policy-gate.sh"
LED="$ROOT/bin/3role-ledger.mjs"

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d)"
# ── PRE-FIX hook: a PINNED, COMMITTED heredoc SNAPSHOT — never a moving `origin/master:` ref (#1494 follow-up) ──
# The two RED-on-HEAD-first control arms (AC-8, AC-11) prove the pre-#1494 leak (a badge-less spawn silently
# satisfied opus-seat policy) EXISTED and is now closed — they compare the CURRENT hook against the PRE-FIX
# hook. The first cut acquired the pre-fix hook with `git show origin/master:hooks/three-role-model-policy-gate.sh`,
# a reference that MOVES. That broke it TWO ways (both caught by the plugin's CI, 2026-07-09):
#   (1) RED NOW: the plugin CI uses a bare `actions/checkout@v4` (shallow, single-branch, no fetch-depth) —
#       `origin/master` does not exist in that checkout, so `git show` fails and the smoke correctly
#       fail-closes -> the whole smoke goes RED, and cannot go green as written.
#   (2) RED FOREVER AFTER MERGE: the instant #1494 merges, `origin/master:...gate.sh` IS the POST-fix hook, so
#       AC-8/AC-11 HEAD (which assert the pre-fix hook exits 0 SILENT) would run against a hook that exits 2 —
#       permanently inverting both HEAD arms on master and on every subsequent PR (same for the ai-brain copy).
# FIX: pin the pre-fix hook as a FIXED, COMMITTED artifact — the heredoc below. It does NOT resolve differently
# by WHEN or WHERE the smoke runs (no remote ref, no fetch depth, shallow-clone-safe, merge-stable). It is the
# byte-exact ai-brain pre-fix hook (its helper resolves via the flat `$(dirname …)/3role-ledger.mjs` sibling);
# the plugin port relabels ONLY that one helper line to the `${CLAUDE_PLUGIN_ROOT}/bin … else ../bin` block via
# the generator's transformHelperResolution (pipeSmokeModelPolicy now runs it) — the SAME relabel the live hook
# gets, so the ported snapshot is the faithful pre-fix PLUGIN hook. A NON-DECAY guard (AC-16, below) asserts the
# pinned snapshot is NOT byte-identical to the live hook, so a future careless "regenerate from live" cannot
# silently turn both HEAD arms into a fixed-vs-fixed tautology (green + vacuous + worthless).
#
# The snapshot MUST be materialized into `dirname "$HOOK"` (NOT `$DIR`): in ai-brain those coincide (hooks/),
# but the plugin port lives in hooks/_smoke/ while $HOOK stays ROOT-relative to hooks/ — the pre-fix hook's OWN
# sibling resolution (`$(dirname "${BASH_SOURCE[0]}")/3role-ledger.mjs`, or `…/../bin/3role-ledger.mjs` in the
# ported form) must find the real ledger, so the drop site is hooks/, not hooks/_smoke/ (else it fails
# `[ -f "$LEDGER_HELPER" ] || exit 0` and exits 0 for EVERY payload -> the HEAD arms PASS VACUOUSLY; AC-12 HEAD
# is the LOUD canary for exactly that — it only exits 2 when the pre-fix hook truly resolves the ledger).
HEAD_HOOK_DIR="$(dirname "$HOOK")"
HEAD_HOOK="$HEAD_HOOK_DIR/.smoke-1494-prefix-$$.sh"
trap 'rm -rf "$TMP" "$HEAD_HOOK"' EXIT

# PINNED pre-fix hook snapshot (byte-exact ai-brain pre-#1494 hook; the ONE helper line is relabeled to the
# plugin bin/ layout by the generator when this smoke is ported). Quoted heredoc -> written verbatim, no
# expansion. Do NOT hand-edit these lines to match the live hook — the AC-16 non-decay guard will fail.
cat > "$HEAD_HOOK" <<'PREFIX_HOOK_SNAPSHOT_EOF'
#!/usr/bin/env bash
# PreToolUse(Agent|Task) hook — THREE-ROLE MODEL-POLICY GATE (#1448). A LEADING-EDGE advisory sibling of
# three-role-attribution-gate.sh (same PreToolUse(Agent|Task) seam, same BLOCK-ONCE shape). It catches a
# per-role model MISCONFIG at SPAWN time — before a whole role run is wasted on the wrong tier — while the
# HARD, load-bearing enforcement stays at completion time (three-role-instrumentation-gate.sh reads the
# forgery-resistant transcript model). Defense-in-depth, not the primary block: a requested-model signal is
# weaker than the transcript, so this leg is advisory (block-once), not a true wall.
#
# POLICY: config/cc-roles.env maps each role -> a model TIER (Option A: Opus on planner + both review gates,
# Sonnet on the executor). `resolve-role-model` reads it fail-SAFE to opus. Today a role spawn carries
# model=(none) and INHERITS the session model (Opus) — correct for the opus seats, WRONG for the executor
# (should be Sonnet). So the violation condition is: the EFFECTIVE tier != the role's policy tier, where
#   effective = the requested tool_input.model if present, else "opus" (the documented session default).
# This fires ONLY when it matters (a non-opus seat left at the Opus default, or an explicit wrong tier) and
# stays SILENT on the majority opus seats whose absent-model default already satisfies policy — no nudge-noise.
#
# RESPONSE DECISION: BLOCK-ONCE (exit 2, VISIBLE to the model — a PreToolUse hook's stderr reaches the agent
# only on exit 2; the #769 lesson). First time a given taskId+role violation SIGNATURE is seen -> exit 2 (the
# orchestrator SEES it + re-launches passing model:<tier>), drop a per-signature marker, then fall through to
# exit 0 on the re-issue so a deliberate spawn is NEVER permanently wedged.
#
# EVERYTHING ELSE FAIL-OPENS (exit 0 silent): not a tagged role spawn (no 3ROLE_TASK + ROLE), policy satisfied,
# no resolvable policy (helper/config absent), parse error, no session. A bare Agent spawn with no model is the
# NORM and must never be false-blocked.
#
# BLOCK-ONCE keying: sha1(session + ":" + taskId + ":" + role) — per taskId+role (the plan's "block-once per
# taskId+role"). A genuinely different role OR task violation has a different signature and blocks again.
#
# Kill-switches: THREE_ROLE_INSTRUMENT_OFF=1 (uniform family) OR CC_ROLE_MODEL_GATE_OFF=1 (dedicated feature
# switch, SAME one the completion-time model leg honors) OR SHIP_PIPELINE=1 (ship-pipeline exempt). Inline
# bypass token `[model-policy-ok]` in the prompt -> exit 0 for a deliberate one-off.
#
# Env overrides (for the smoke): CC_ROLE_MODEL_POLICY_STATE_DIR (default ~/.claude/.three-role-model-policy-state);
# CC_ROLES_ENV points resolve-role-model at a fixture config. No `set -e` (a non-block non-zero must never leak
# into a permission decision — #749).
# Reference: parent-claude.md Invariant #6, hooks/three-role-attribution-gate.sh (the block-once sibling),
# hooks/3role-ledger.mjs (resolve-role-model), the plan .ai-workspace/plans/2026-07-03-1448-per-role-model-policy.md.

set -u

# Kill-switches (full exemption, no state mutation).
[ "${THREE_ROLE_INSTRUMENT_OFF:-}" = "1" ] && exit 0
[ "${CC_ROLE_MODEL_GATE_OFF:-}" = "1" ] && exit 0
[ "${SHIP_PIPELINE:-}" = "1" ] && exit 0

STATE_DIR="${CC_ROLE_MODEL_POLICY_STATE_DIR:-$HOME/.claude/.three-role-model-policy-state}"
TTL_DAYS="${CC_ROLE_MODEL_POLICY_TTL_DAYS:-14}"

INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Resolve the ledger helper (config logic lives there — this hook stays thin). Sibling flat file whether run
# from the repo or the ~/.claude/hooks/ symlink; the plugin sync rewrites this line to a ${CLAUDE_PLUGIN_ROOT}/bin block.
# Resolve the ledger helper: prefer ${CLAUDE_PLUGIN_ROOT}/bin; fall back to a repo-relative ../bin path
# (R1: ${CLAUDE_PLUGIN_ROOT} may be unset in some hook shells — the fallback keeps it portable).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" ]; then
  LEDGER_HELPER="${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs"
else
  LEDGER_HELPER="$(dirname "${BASH_SOURCE[0]}")/../bin/3role-ledger.mjs"
fi

# Parse role, session, taskId, the requested model (lowercased tier), the inline bypass token, and the
# block-once SIGNATURE in ONE node pass. Emits "<role|-> <session|-> <taskId|-> <model|-> <bypass 0|1> <sig>"
# or "" on a fatal parse error (-> fail-open). Reads the joined prompt+description+message field set (same
# bypass-form coverage as the attribution gate — #749).
read -r ROLE SESSION TASKID REQMODEL BYPASS SIG < <(
  HOOK_INPUT="$INPUT" node -e '
    const crypto=require("crypto");
    let d={}; try{ d=JSON.parse(process.env.HOOK_INPUT||"{}"); }catch(e){ process.exit(0); }
    const ti=d.tool_input||{};
    const prompt=[ti.prompt, ti.description, ti.message].map(x=> (x==null?"":String(x))).join("\n");
    const session=(d.session_id||"").toString().replace(/[^0-9A-Za-z._-]/g,"");
    const mTask=prompt.match(/3ROLE_TASK:\s*([0-9A-Za-z._-]+)/i);
    const mRole=prompt.match(/ROLE:\s*(planner|plan-review|execution-review|executor)/i);
    const role = mRole ? mRole[1].toLowerCase() : "-";
    const taskId = mTask ? mTask[1] : "-";
    const model = (ti.model==null?"":String(ti.model)).trim().toLowerCase().replace(/[^0-9a-z._-]/g,"") || "-";
    const bypass = /\[model-policy-ok\]/i.test(prompt) ? "1" : "0";
    const sig=crypto.createHash("sha1").update((session||"-")+":"+(taskId||"-")+":"+role).digest("hex");
    process.stdout.write([role, (session||"-"), taskId, model, bypass, sig].join(" "));
  ' 2>/dev/null
)

# Fatal parse error (node printed "") -> fail-open.
[ -n "$SIG" ] || exit 0
# Inline bypass -> exit 0 (deliberate one-off), even on a real violation.
[ "$BYPASS" = "1" ] && exit 0
# Not a tagged role spawn -> fail-open (the norm). Need BOTH the role AND a real task tag to attribute a policy.
[ "$ROLE" != "-" ] || exit 0
[ "$TASKID" != "-" ] || exit 0
# No usable session cannot be keyed reliably -> fail-open (the completion gate is the backstop).
[ -n "$SESSION" ] && [ "$SESSION" != "-" ] || exit 0

# Resolve the role's policy tier (+ effort) — fail-OPEN if the helper/config is unavailable (never block on
# infra). resolve-role-model fails SAFE to opus and always exits 0, so an empty EXPECTED means the helper
# itself is missing (not "policy is opus").
[ -f "$LEDGER_HELPER" ] || exit 0
read -r EXPECTED EFFORT < <(node "$LEDGER_HELPER" resolve-role-model --role "$ROLE" --with-effort 2>/dev/null)
[ -n "${EXPECTED:-}" ] || exit 0

# EFFECTIVE tier: the requested model if present, else the inherited session default (Opus today).
if [ "$REQMODEL" != "-" ] && [ -n "$REQMODEL" ]; then
  EFFECTIVE="$REQMODEL"; SRC="requested (model:${REQMODEL})"
else
  EFFECTIVE="opus"; SRC="inherited (no model: passed -> the session model, Opus)"
fi

# Policy satisfied -> silent allow. This is what keeps the opus seats quiet on an absent model.
[ "$EFFECTIVE" = "$EXPECTED" ] && exit 0

# --- per-signature block-once marker ---
mkdir -p "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -type f -mtime +"$TTL_DAYS" -delete 2>/dev/null   # bounded GC (mirrors the attribution gate).
MARKER="$STATE_DIR/$SIG.notified"
# Already nudged for THIS taskId+role violation -> let the spawn proceed (block-once, not wedged).
[ -f "$MARKER" ] && exit 0
: > "$MARKER" 2>/dev/null

# Fable cost-cliff note when either side of the comparison is fable.
FABLE_NOTE=""
if [ "$EXPECTED" = "fable" ] || [ "$REQMODEL" = "fable" ]; then
  FABLE_NOTE="  Fable note: ~2x Opus and its subsidised bar expires ~July 7-8 — after that a Fable seat bills out-of-pocket. Use it only for the hardest one-off plans."
fi

cat >&2 <<EOF
<system-reminder>
THREE-ROLE MODEL-POLICY GATE (three-role-model-policy-gate hook, #1448): role subagent ROLE:${ROLE} for
3ROLE_TASK:${TASKID} is being spawned on the WRONG model tier. cc-roles.env policy = ${EXPECTED}${EFFORT:+/${EFFORT}}, but
this spawn's effective tier is ${EFFECTIVE} [${SRC}]. Re-launch passing the policy tier to the Agent tool:
    model: ${EXPECTED}${EFFORT:+   (reasoning effort: ${EFFORT})}
(prepend nothing else — keep the 3ROLE_TASK:${TASKID} ROLE:${ROLE} tags). The HARD block is at completion time
(the instrumentation gate reads the actual transcript model); this leading-edge nudge just saves a wasted run.
${FABLE_NOTE:+${FABLE_NOTE}
}This is ADVISORY + block-once PER taskId+role: you will see this ONCE for this spawn. Re-launch with the
right model to proceed (you will NOT be blocked again for this same spawn). Escapes: inline bypass token
[model-policy-ok] in the prompt for a deliberate one-off, or kill-switch CC_ROLE_MODEL_GATE_OFF=1 (or
THREE_ROLE_INSTRUMENT_OFF=1 / SHIP_PIPELINE=1).
</system-reminder>
EOF
exit 2
PREFIX_HOOK_SNAPSHOT_EOF

HEAD_AVAILABLE=1
[ -s "$HEAD_HOOK" ] || { HEAD_AVAILABLE=0; bad "AC-16 setup: failed to materialize the pinned pre-fix hook snapshot at $HEAD_HOOK"; }

# ---- AC-16: NON-DECAY guard — the pinned pre-fix snapshot MUST differ from the live hook. If a future
#      regeneration ever made them byte-identical, the HEAD control arms (AC-8/AC-11) would degenerate into a
#      fixed-vs-fixed TAUTOLOGY (green, but proving nothing). `cmp -s` exits 0 when the files are identical —
#      so IDENTICAL is the FAILURE direction here. ----
if cmp -s "$HEAD_HOOK" "$HOOK"; then
  bad "AC-16: pinned pre-fix snapshot is BYTE-IDENTICAL to the live hook — the HEAD control arms are vacuous (the snapshot must be the PRE-fix hook, never regenerated from the live one)"
else
  ok "AC-16: pinned pre-fix snapshot differs from the live hook (non-decay guard holds)"
fi

# A SINGLE pinned state dir shared by ALL fixtures, so the marker dropped by one fixture is visible to a
# same-signature re-issue (block-once tests) and unrelated signatures never collide (distinct session ids
# per test case below).
STATE_DIR="$TMP/state"

# Fixture cc-roles.env (Option-A shape) — CC_ROLES_ENV points resolve-role-model at THIS file, so the smoke is
# independent of the repo/plugin config. executor=sonnet is the one non-opus seat.
CFG="$TMP/cc-roles.env"
cat > "$CFG" <<EOF
CC_ROLE_ORCHESTRATOR_MODEL=opus
CC_ROLE_PLANNER_MODEL=opus
CC_ROLE_PLAN_REVIEW_MODEL=opus
CC_ROLE_EXECUTOR_MODEL=sonnet
CC_ROLE_EXECUTOR_EFFORT=medium
CC_ROLE_EXECUTION_REVIEW_MODEL=opus
EOF
# A fable-executor config to exercise the cost-cliff note.
CFGF="$TMP/cc-roles-fable.env"
printf 'CC_ROLE_EXECUTOR_MODEL=fable\n' > "$CFGF"

# CC_ROLE_AGENTS_DIR fixture — a fixture agent-def dir the gate/sensor read (the REAL ~/.claude/agents is
# NEVER touched). Only cc-executor.md exists here (frontmatter model: sonnet) — AC-7/13.
AGENTS_FIX="$TMP/agents_fix"
mkdir -p "$AGENTS_FIX"
cat > "$AGENTS_FIX/cc-executor.md" <<'EOF'
---
name: cc-executor
model: sonnet
---
Executor role definition fixture (smoke-only; never installed).
EOF

# #1513 — SEPARATE per-AC agents dirs (plan-review non-blocking note 1): AC-RED/AC-RED-CLAUDE/AC-POS/AC-EMPTY/
# AC-ONCE/AC-KILL need cc-planner.md PRESENT, but the existing AC-9/M1/M4 (ROLE:planner, tier-satisfied) need
# it ABSENT to stay exit 0 — do NOT add cc-planner.md to the shared AGENTS_FIX above (that would flip AC-9/M1/M4).
AGENTS_FULL="$TMP/agents_full"
mkdir -p "$AGENTS_FULL"
cat > "$AGENTS_FULL/cc-planner.md" <<'EOF'
---
name: cc-planner
model: opus
---
Planner role definition fixture (smoke-only; never installed) — used ONLY by the #1513 effort-leg ACs.
EOF

# #1513 AC-NEG-DANGLING — a symlink whose target does NOT exist. `-f`/`-e` (never `-L`) must read this as
# ABSENT, so a half-installed env is treated as the sanctioned general-purpose fallback, never false-blocked.
AGENTS_DANGLING="$TMP/agents_dangling"
mkdir -p "$AGENTS_DANGLING"
ln -s "$AGENTS_DANGLING/cc-planner-target-does-not-exist.md" "$AGENTS_DANGLING/cc-planner.md"

# ── Transcript fixtures (JSONL, mktemp-relative — no literal home paths) ──────────────────────────────────
FABLE_TX="$TMP/fable.jsonl"
printf '%s\n' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}' \
  '{"type":"user","isSidechain":false,"message":{"content":"intermediate turn"}}' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5"}}' \
  > "$FABLE_TX"

OPUS_TX="$TMP/opus.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}' > "$OPUS_TX"

SIDECHAIN_TX="$TMP/sidechain.jsonl"
printf '%s\n' \
  '{"type":"assistant","isSidechain":false,"message":{"model":"claude-fable-5"}}' \
  '{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-4-8"}}' \
  > "$SIDECHAIN_TX"

# REALISTIC_OPUS_TX: opus assistant, then trailing non-assistant records, LAST ~0.8MB — proves the DEFAULT
# tail window (no env override) does not false-block a real opus spawn even behind a big trailing record.
REALISTIC_OPUS_TX="$TMP/realistic_opus.jsonl"
python3 - "$REALISTIC_OPUS_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-opus-4-8"}}) + "\n")
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": "small trailing turn"}}) + "\n")
    big = "x" * 819200   # ~0.8MB, exceeds a SMALL configured window but fits the 4MB default with margin.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# BIG_TAIL_TX: fable assistant, then a trailing record LARGER than a small configured initial window — forces
# the grow-with-cap path (AC-5).
BIG_TAIL_TX="$TMP/big_tail.jsonl"
python3 - "$BIG_TAIL_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-fable-5"}}) + "\n")
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": "small"}}) + "\n")
    big = "y" * 5000    # > the small 2048-byte initial window this AC uses below, forces >=2 growth doublings.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# OVERSIZE_TX: NO parseable last-assistant record reachable within a TINY cap (AC-6 — cap-exceeded fail-closed).
OVERSIZE_TX="$TMP/oversize.jsonl"
python3 - "$OVERSIZE_TX" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": False, "message": {"model": "claude-opus-4-8"}}) + "\n")
    big = "z" * 20000   # far past a tiny (e.g. 4096-byte) cap -> the assistant line at file-start is never reached.
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"content": big}}) + "\n")
PYEOF

# HUGE_TX: >=200MB, opus assistant as the LAST record (near-EOF) — proves the reverse-tail read is genuinely
# bounded at REAL scale (never a whole-file read) via a 1s timeout wrapper (AC-5 secondary bound).
HUGE_TX="$TMP/huge.jsonl"
{
  printf '{"type":"user","isSidechain":false,"message":{"content":"'
  dd if=/dev/zero bs=1m count=200 2>/dev/null | tr '\0' 'x'
  printf '"}}\n'
  printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-4-8"}}'
} > "$HUGE_TX"

EMPTY_TX="$TMP/does-not-exist.jsonl"   # never created -> unreadable/missing.

echo "-- fixtures built (HUGE_TX=$(wc -c < "$HUGE_TX" 2>/dev/null || echo '?') bytes) --"

# runh <hook-path> <payload-json> [env KEY=VAL ...] -> sets RC, CAP. Pins CC_ROLES_ENV=$CFG and
# CC_ROLE_AGENTS_DIR=$AGENTS_FIX by default (later env args win); pins the POST-FIX STATE_DIR.
runh() {
  local hook="$1" payload="$2"; shift 2
  CAP=$(printf '%s' "$payload" \
    | env CC_ROLES_ENV="$CFG" CC_ROLE_AGENTS_DIR="$AGENTS_FIX" "$@" CC_ROLE_MODEL_POLICY_STATE_DIR="$STATE_DIR" bash "$hook" 2>&1); RC=$?
}
run() { runh "$HOOK" "$@"; }   # legacy alias -> always the CURRENT (post-fix) hook.

# run_head <payload-json> [env KEY=VAL ...] -> the PRE-FIX hook snapshot, an ISOLATED state dir
# (STATE_DIR_HEAD, never $STATE_DIR). Sharing state with the post-fix runs would let a HEAD-side block-once
# marker (written whenever HEAD legitimately blocks, e.g. AC-12's consistency arm) shadow the SAME
# session:taskId:role signature's post-fix assertion — a same-signature HEAD write must never suppress the
# post-fix run for that identical payload.
STATE_DIR_HEAD="$TMP/state-head"
run_head() {
  local payload="$1"; shift
  CAP=$(printf '%s' "$payload" \
    | env CC_ROLES_ENV="$CFG" CC_ROLE_AGENTS_DIR="$AGENTS_FIX" "$@" CC_ROLE_MODEL_POLICY_STATE_DIR="$STATE_DIR_HEAD" bash "$HEAD_HOOK" 2>&1); RC=$?
}

echo "== SECTION 0: static syntax checks =="

# ---- AC-0: bash -n on every shell file this ticket touches (macOS /bin/bash 3.2.57 — no declare -A). ----
bash -n "$HOOK" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0a: bash -n three-role-model-policy-gate.sh -> syntax OK" || bad "AC-0a: bash -n three-role-model-policy-gate.sh FAILED"
bash -n "$DIR/three-role-model-policy-gate-smoke-test.sh" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0b: bash -n three-role-model-policy-gate-smoke-test.sh (self) -> syntax OK" || bad "AC-0b: bash -n (self) FAILED"
node --check "$LED" 2>&1
{ [ $? -eq 0 ]; } && ok "AC-0c: node --check 3role-ledger.mjs -> syntax OK" || bad "AC-0c: node --check 3role-ledger.mjs FAILED"

echo "== SECTION 1: sensor UNIT arms (resolve-effective-tier CLI, direct) — AC 1-7 =="

# ---- AC-1: explicit --model wins regardless of transcript. ----
OUT=$(node "$LED" resolve-effective-tier --model fable --transcript /dev/null 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable requested agentdef=none" ]; } \
  && ok "AC-1: explicit --model fable (any transcript) -> 'fable requested agentdef=none'" \
  || bad "AC-1 failed (rc=$RC out=$OUT)"

# ---- AC-2: session-read + last-assistant-wins (FABLE_TX has an earlier opus line). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$FABLE_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-2: empty --model + FABLE_TX -> 'fable session agentdef=none' (last-assistant wins)" \
  || bad "AC-2 failed (rc=$RC out=$OUT)"

# ---- AC-3: no transcript + no derivable session -> unknown (OR-disjunct a). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$TMP/nonexistent-ac3.jsonl" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "unknown unknown agentdef=none" ]; } \
  && ok "AC-3: no transcript, no session -> 'unknown unknown agentdef=none' (OR-disjunct a)" \
  || bad "AC-3 failed (rc=$RC out=$OUT)"

# ---- AC-4: sidechain filter — a subagent record can never leak in as the session model. ----
OUT=$(node "$LED" resolve-effective-tier --model "" --transcript "$SIDECHAIN_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-4: SIDECHAIN_TX -> 'fable session agentdef=none' (isSidechain:true opus is excluded)" \
  || bad "AC-4 failed (rc=$RC out=$OUT)"

# ---- AC-5: tail-past-a-giant-trailing-record (grow path) + a real-scale speed bound. ----
OUT=$(env CC_TIER_SENSOR_TAIL_BYTES=2048 CC_TIER_SENSOR_CAP_BYTES=65536 \
  node "$LED" resolve-effective-tier --model "" --transcript "$BIG_TAIL_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "fable session agentdef=none" ]; } \
  && ok "AC-5a: BIG_TAIL_TX + small TAIL_BYTES -> grows through the giant trailing record -> 'fable session'" \
  || bad "AC-5a failed (rc=$RC out=$OUT)"
T0=$(date +%s)
OUT2=$(timeout 1 env CC_TIER_SENSOR_TAIL_BYTES=2048 CC_TIER_SENSOR_CAP_BYTES=65536 \
  node "$LED" resolve-effective-tier --model "" --transcript "$HUGE_TX" 2>&1); RC2=$?
T1=$(date +%s)
{ [ "$RC2" = "0" ] && [ "$OUT2" = "opus session agentdef=none" ]; } \
  && ok "AC-5b: HUGE_TX (>=200MB) resolves 'opus session' inside a 1s timeout ($((T1-T0))s) — whole-file read genuinely avoided" \
  || bad "AC-5b failed (rc=$RC2 out=$OUT2 elapsed=$((T1-T0))s)"

# ---- AC-6: cap-exceeded fail-closed, bounded time (OR-disjunct c). ----
T0=$(date +%s)
OUT=$(timeout 1 env CC_TIER_SENSOR_TAIL_BYTES=512 CC_TIER_SENSOR_CAP_BYTES=4096 \
  node "$LED" resolve-effective-tier --model "" --transcript "$OVERSIZE_TX" 2>&1); RC=$?
T1=$(date +%s)
{ [ "$RC" = "0" ] && [ "$OUT" = "unknown unknown agentdef=none" ]; } \
  && ok "AC-6: OVERSIZE_TX + tiny CAP_BYTES -> 'unknown unknown' inside 1s ($((T1-T0))s) (OR-disjunct c)" \
  || bad "AC-6 failed (rc=$RC out=$OUT elapsed=$((T1-T0))s)"

# ---- AC-7: agent-def is PROVENANCE-ONLY — tier stays the SESSION tier (opus), never the frontmatter (sonnet). ----
OUT=$(node "$LED" resolve-effective-tier --model "" --subagent-type cc-executor --agents-dir "$AGENTS_FIX" --transcript "$OPUS_TX" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ "$OUT" = "opus session agentdef=sonnet" ]; } \
  && ok "AC-7: cc-executor frontmatter=sonnet + OPUS_TX -> tier stays 'opus session', agentdef=sonnet reported only" \
  || bad "AC-7 failed (rc=$RC out=$OUT)"

echo "== SECTION 2: GATE arms (PreToolUse(Agent) payloads through the hook) — AC 8-15 =="

# ---- AC-8: REGRESSION — the measured leak. planner, NO model, general-purpose, FABLE_TX.
#      HEAD (pre-fix): exits 0 silent (the bug). Post-fix: exits 2, names fable + the session source. ----
P8='{"session_id":"ac8","tool_input":{"prompt":"3ROLE_TASK:9101 ROLE:planner\nPlan it.","subagent_type":"general-purpose"},"transcript_path":"'"$FABLE_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P8"
  { [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
    && ok "AC-8 HEAD: planner+no-model+FABLE_TX on the PRE-FIX hook -> exit 0 silent (the measured leak, reproduced)" \
    || bad "AC-8 HEAD should silently pass (the bug) (rc=$RC out=$CAP)"
fi
run "$P8"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "fable" && echo "$CAP" | grep -qi "session"; } \
  && ok "AC-8 post-fix: same payload -> exit 2, names fable + the session-transcript source" \
  || bad "AC-8 post-fix should block and name fable+session (rc=$RC out=$CAP)"

# ---- AC-9: GREEN majority path — robust tail, no false block, DEFAULT tail bytes (no override). ----
P9='{"session_id":"ac9","tool_input":{"prompt":"3ROLE_TASK:9102 ROLE:planner\nPlan it.","subagent_type":"general-purpose"},"transcript_path":"'"$REALISTIC_OPUS_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P9"; rc9h=$RC
else
  rc9h=0
fi
run "$P9"; rc9p=$RC
{ [ "$rc9h" = "0" ] && [ "$rc9p" = "0" ]; } \
  && ok "AC-9: planner+no-model+REALISTIC_OPUS_TX (opus behind a ~0.8MB trailing record) -> exit 0 both HEAD and post-fix" \
  || bad "AC-9 should never false-block (rc_head=$rc9h rc_postfix=$rc9p)"

# ---- AC-10: GREEN explicit — an explicit model:sonnet under a Fable-session transcript is NOT false-blocked. ----
P10='{"session_id":"ac10","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9103 ROLE:executor\nGo."},"transcript_path":"'"$FABLE_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P10"; rc10h=$RC
else
  rc10h=0
fi
run "$P10"; rc10p=$RC
{ [ "$rc10h" = "0" ] && [ "$rc10p" = "0" ]; } \
  && ok "AC-10: executor+model:sonnet under a Fable-session transcript -> exit 0 both HEAD and post-fix (term-1 wins)" \
  || bad "AC-10 should never false-block an explicitly-badged cheap seat (rc_head=$rc10h rc_postfix=$rc10p)"

# ---- AC-11: FAIL-CLOSED opus-seat can't-determine. plan-review, NO model, EMPTY_TX (unreadable).
#      HEAD: exits 0 silent (the DANGEROUS direction — old hardcoded opus == opus policy). Post-fix: exits 2
#      via the named `unknown` branch; stderr asks for an explicit model: and does NOT silently claim opus
#      was assumed (no "inherited"/"the session model, Opus" language — the exact phrasing the bug used). ----
P11='{"session_id":"ac11","tool_input":{"prompt":"3ROLE_TASK:9104 ROLE:plan-review\nReview it."},"transcript_path":"'"$EMPTY_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P11"
  { [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
    && ok "AC-11 HEAD: plan-review+no-model+unreadable-tx on the PRE-FIX hook -> exit 0 silent (the dangerous direction)" \
    || bad "AC-11 HEAD should silently pass (rc=$RC out=$CAP)"
fi
run "$P11"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "INDETERMINATE" && echo "$CAP" | grep -q "model:" \
  && ! echo "$CAP" | grep -qi "inherited"; } \
  && ok "AC-11 post-fix: unknown branch -> exit 2, asks explicit model:, no silent-opus-assumption language" \
  || bad "AC-11 post-fix should fail-closed via the named unknown branch (rc=$RC out=$CAP)"

# ---- AC-12: FAIL-CLOSED cheap-seat can't-determine (consistency arm — HEAD already exits 2, for a
#      different reason: hardcoded opus != sonnet policy). Post-fix exits 2 via the NEW unknown branch. ----
P12='{"session_id":"ac12","tool_input":{"prompt":"3ROLE_TASK:9105 ROLE:executor\nImplement."},"transcript_path":"'"$EMPTY_TX"'"}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$P12"
  { [ "$RC" = "2" ]; } \
    && ok "AC-12 HEAD: executor+no-model+unreadable-tx on the PRE-FIX hook -> exit 2 (consistency: hardcoded opus != sonnet)" \
    || bad "AC-12 HEAD should already block (rc=$RC out=$CAP)"
fi
run "$P12"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "INDETERMINATE"; } \
  && ok "AC-12 post-fix: executor+no-model+unreadable-tx -> exit 2 via the named unknown branch" \
  || bad "AC-12 post-fix should fail-closed via the named unknown branch (rc=$RC out=$CAP)"

# ---- AC-13: agent-def does NOT rescue a badge-less cheap seat. executor, no model, subagent_type cc-executor
#      (frontmatter sonnet), OPUS_TX. Effective resolves to the SESSION tier (opus) != sonnet -> BLOCK. ----
P13='{"session_id":"ac13","tool_input":{"prompt":"3ROLE_TASK:9106 ROLE:executor\nImplement.","subagent_type":"cc-executor"},"transcript_path":"'"$OPUS_TX"'"}'
run "$P13"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "opus"; } \
  && ok "AC-13: cc-executor frontmatter=sonnet under an opus-session transcript -> exit 2 (frontmatter does not rescue)" \
  || bad "AC-13 should block on the session tier, not wave through on the frontmatter (rc=$RC out=$CAP)"

# ---- AC-14: escapes preserved (kill-switch, inline bypass, untagged) — each on a FRESH, otherwise-positive
#      signature (non-vacuity: proves the escape suppressed a REAL block, not an already-silent path). ----
P14a='{"session_id":"ac14a","tool_input":{"prompt":"3ROLE_TASK:9107 ROLE:planner\nPlan it."},"transcript_path":"'"$FABLE_TX"'"}'
runh "$HOOK" "$P14a" CC_ROLE_MODEL_GATE_OFF=1; rc14a=$RC
P14b='{"session_id":"ac14b","tool_input":{"prompt":"3ROLE_TASK:9108 ROLE:planner [model-policy-ok]\nPlan it."},"transcript_path":"'"$FABLE_TX"'"}'
run "$P14b"; rc14b=$RC
P14c='{"session_id":"ac14c","tool_input":{"prompt":"General research, no tags at all."},"transcript_path":"'"$FABLE_TX"'"}'
run "$P14c"; rc14c=$RC
{ [ "$rc14a" = "0" ] && [ "$rc14b" = "0" ] && [ "$rc14c" = "0" ]; } \
  && ok "AC-14: kill-switch / inline bypass / untagged spawn all -> exit 0 on an otherwise-positive FABLE_TX payload" \
  || bad "AC-14 escapes should suppress a real block (rc_a=$rc14a rc_b=$rc14b rc_c=$rc14c)"

# ---- AC-15: block-once — re-issuing the IDENTICAL AC-8 post-fix payload a second time -> exit 0
#      (the per-session:taskId:role marker was dropped on the first block). ----
run "$P8"
{ [ "$RC" = "0" ]; } \
  && ok "AC-15: AC-8 payload re-issued -> exit 0 (block-once marker dropped on first block, not wedged)" \
  || bad "AC-15 should fall through on re-issue (rc=$RC out=$CAP)"

echo "== SECTION 3: legacy explicit-model / escape-mechanics regression coverage (unaffected by #1494) =="

# ---- L1. executor + model:opus (violates sonnet policy), FRESH sig -> exit 2 + names role + expected tier. ----
PL1='{"session_id":"l1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9201 ROLE:executor\nImplement."}}'
run "$PL1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor" && echo "$CAP" | grep -q "sonnet"; } \
  && ok "L1: executor model:opus (fresh) -> exit 2, names role + sonnet policy" \
  || bad "L1 fresh violation should block visibly (rc=$RC out=$CAP)"

# ---- L2. SAME signature again (marker present) -> exit 0 (block-once, not wedged). ----
run "$PL1"
{ [ "$RC" = "0" ]; } && ok "L2: same signature again -> exit 0 (block-once, not wedged)" || bad "L2 second identical spawn should fall through (rc=$RC out=$CAP)"

# ---- L3. DIFFERENT signature (different taskId, same session) AFTER L1's marker exists -> exit 2 again. ----
PL3='{"session_id":"l1","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9202 ROLE:executor\nDifferent task, same violation."}}'
run "$PL3"
{ [ "$RC" = "2" ]; } && ok "L3: DIFFERENT taskId offense after first fire -> STILL exit 2 (blocks again)" || bad "L3 different signature must still block (rc=$RC out=$CAP)"

# ---- L4. executor + model:sonnet (matches policy) -> exit 0 silent. ----
PL4='{"session_id":"l4","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9203 ROLE:executor\nGo."}}'
run "$PL4"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L4: executor model:sonnet (match) -> exit 0 silent" || bad "L4 matching model should be silent allow (rc=$RC out=$CAP)"

# ---- L5. planner + model:sonnet -> explicit WRONG tier on an opus seat -> exit 2. ----
PL5='{"session_id":"l5","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:9204 ROLE:planner\nPlan it, wrong tier."}}'
run "$PL5"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "opus"; } && ok "L5: planner model:sonnet (explicit wrong on opus seat) -> exit 2" || bad "L5 explicit wrong tier should block (rc=$RC out=$CAP)"

# ---- L6. non-tagged spawn (no 3ROLE_TASK, no ROLE) -> exit 0 silent (the norm). ----
run '{"session_id":"l6","tool_input":{"prompt":"Do some general research. No tags."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L6: non-tagged spawn -> exit 0 silent" || bad "L6 untagged spawn should be silent allow (rc=$RC out=$CAP)"

# ---- L7. role-only, no task tag -> exit 0 silent. L7b. task-only, no role tag -> exit 0 silent. ----
run '{"session_id":"l7","tool_input":{"model":"opus","prompt":"ROLE:executor\nNo task tag here."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L7: role-only (no task tag) -> exit 0 silent" || bad "L7 role-only should be silent allow (rc=$RC out=$CAP)"
run '{"session_id":"l7b","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9205\nSome work, no role tag."}}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L7b: task-only (no role tag) -> exit 0 silent" || bad "L7b task-only should be silent allow (rc=$RC out=$CAP)"

# ---- L8. kill-switches on an OTHERWISE-POSITIVE explicit-model payload -> exit 0. ----
PL8a='{"session_id":"l8a","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9206 ROLE:executor\nviolation."}}'
run "$PL8a" CC_ROLE_MODEL_GATE_OFF=1; rcl8a=$RC
PL8b='{"session_id":"l8b","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9207 ROLE:executor\nviolation."}}'
run "$PL8b" THREE_ROLE_INSTRUMENT_OFF=1; rcl8b=$RC
PL8c='{"session_id":"l8c","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9208 ROLE:executor\nviolation."}}'
run "$PL8c" SHIP_PIPELINE=1; rcl8c=$RC
{ [ "$rcl8a" = "0" ] && [ "$rcl8b" = "0" ] && [ "$rcl8c" = "0" ]; } \
  && ok "L8: kill-switches on POSITIVE explicit-model payload -> exit 0" \
  || bad "L8 kill-switches should suppress a real block (rc_a=$rcl8a rc_b=$rcl8b rc_c=$rcl8c)"

# ---- L9. bypass-form coverage (#749): role tag in the description field + model in tool_input.model. ----
PL9='{"session_id":"l9","tool_input":{"model":"opus","description":"3ROLE_TASK:9209 ROLE:executor","prompt":"Implementation work, tags in description."}}'
run "$PL9"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:executor"; } \
  && ok "L9: tags in description field -> still detected -> exit 2" \
  || bad "L9 should read joined field set incl. description (rc=$RC out=$CAP)"

# ---- L10. malformed / empty payload -> exit 0 (fail-open). ----
run 'not json {{{'; rcl10a=$RC
run '{"session_id":"l10"}'; rcl10b=$RC
{ [ "$rcl10a" = "0" ] && [ "$rcl10b" = "0" ]; } && ok "L10: malformed / empty payload -> exit 0 (fail-open)" || bad "L10 malformed should fail-open exit 0 (rcl10a=$rcl10a rcl10b=$rcl10b)"

# ---- L11. NO-CONFIG fail-safe: CC_ROLES_ENV=/nonexistent -> policy resolves to opus for every role -> an
#      executor+model:opus spawn effective=opus == opus -> exit 0 (no false-block when config is absent). ----
PL11='{"session_id":"l11","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9210 ROLE:executor\nno config."}}'
run "$PL11" CC_ROLES_ENV=/nonexistent
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } && ok "L11: no-config executor+opus -> exit 0 (fail-safe opus, no false-block)" || bad "L11 no-config should fail-safe to opus (rc=$RC out=$CAP)"

# ---- L12. FABLE config: executor=fable, spawn model:opus -> exit 2 with the (corrected) Fable cost-cliff note. ----
PL12='{"session_id":"l12","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9211 ROLE:executor\nfable policy."}}'
run "$PL12" CC_ROLES_ENV="$CFGF"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "Fable" && echo "$CAP" | grep -q "July 12"; } \
  && ok "L12: fable-executor config + model:opus -> exit 2 + corrected Fable cost-cliff note (July 12)" \
  || bad "L12 fable seat mismatch should block with the corrected note (rc=$RC out=$CAP)"

echo "== SECTION 4: #1569 AC-6 -- fable-seat ALLOW arms (planner + execution-review), NOT covered above =="
# #1569 adopts fable, time-boxed, on TWO NEW seats: planner and execution-review (config/cc-roles.env PR-2).
# CFGF above only fixtures a fable EXECUTOR (L12's BLOCK arm) -- it never proves a fable spawn is actually
# ALLOWED to proceed. That is the genuine gap #1569 depends on: without it, (L12's BLOCK) could "pass" merely
# because the gate treats fable as always-invalid, which would also silently BLOCK the two new seats forever.
# Driving the real gate with a synthetic bash payload trips an UNRELATED hook (benchmark-persistence-check.sh
# false-fires on that command shape); its only escape is a forbidden override token. The gate-legal path is
# exactly this: arms INSIDE the shipped, CI-covered smoke, run via the smoke's own harness -- never a bare
# hand-rolled invocation. See the #1569 plan, AC-6 method note.
CFGF3="$TMP/cc-roles-fable-1569.env"
cat > "$CFGF3" <<EOF
CC_ROLE_PLANNER_MODEL=fable
CC_ROLE_EXECUTION_REVIEW_MODEL=fable
CC_ROLE_PLAN_REVIEW_MODEL=opus
EOF

# ---- M1 (AC-6a, ALLOW): planner=fable policy + spawn model:fable -> exit 0 (the new seat can spawn at all). ----
PM1='{"session_id":"m1","tool_input":{"model":"fable","prompt":"3ROLE_TASK:9301 ROLE:planner\nPlan it."}}'
run "$PM1" CC_ROLES_ENV="$CFGF3"
{ [ "$RC" = "0" ]; } \
  && ok "M1 (#1569 AC-6a): planner=fable policy + model:fable -> exit 0 (new seat ALLOWED)" \
  || bad "M1 fable planner seat should be allowed to spawn (rc=$RC out=$CAP)"

# ---- M2 (AC-6a, ALLOW): execution-review=fable policy + spawn model:fable -> exit 0. ----
PM2='{"session_id":"m2","tool_input":{"model":"fable","prompt":"3ROLE_TASK:9302 ROLE:execution-review\nReview it."}}'
run "$PM2" CC_ROLES_ENV="$CFGF3"
{ [ "$RC" = "0" ]; } \
  && ok "M2 (#1569 AC-6a): execution-review=fable policy + model:fable -> exit 0 (new seat ALLOWED)" \
  || bad "M2 fable execution-review seat should be allowed to spawn (rc=$RC out=$CAP)"

# ---- M3 (AC-6b, BLOCK, non-vacuity control): SAME fable-seat policy (planner=fable) but spawn model:opus ->
#      exit 2, naming the seat + instructing model:fable. Without this, M1 could "pass" merely because the
#      gate is inert for fable policies -- this proves the gate is still discriminating on a fable SEAT
#      (L12 already covers this shape on the EXECUTOR seat; this is the same control on a NEW #1569 seat). ----
PM3='{"session_id":"m3","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9303 ROLE:planner\nPlan it, wrong tier."}}'
run "$PM3" CC_ROLES_ENV="$CFGF3"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -q "ROLE:planner" && echo "$CAP" | grep -qi "fable"; } \
  && ok "M3 (#1569 AC-6b): planner=fable policy + model:opus -> exit 2, names role + fable (non-vacuous BLOCK control)" \
  || bad "M3 fable-seat wrong-tier spawn should still block (rc=$RC out=$CAP)"

# ---- M4 (AC-6c, UNCHANGED seat): plan-review stays opus in this SAME fixture -> model:opus -> exit 0 silent.
#      Proves the fable rollout on two seats does not disturb the untouched plan-review seat's policy. ----
PM4='{"session_id":"m4","tool_input":{"model":"opus","prompt":"3ROLE_TASK:9304 ROLE:plan-review\nReview it."}}'
run "$PM4" CC_ROLES_ENV="$CFGF3"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "M4 (#1569 AC-6c): plan-review=opus (unchanged) + model:opus -> exit 0 silent" \
  || bad "M4 unchanged plan-review seat should be silent allow (rc=$RC out=$CAP)"

echo "== SECTION 5: #1513 subagent_type/effort-inert advisory sub-leg =="
# The sub-leg lives ONLY on the tier-SATISFIED path (line ~179's silent-allow), so every payload below carries
# a model: that MATCHES the role's policy tier — the pre-existing tier-mismatch arms above are untouched.

# ---- AC-RED (the leak, must go from silent->fired): planner, subagent_type:general-purpose, model:opus,
#      cc-planner.md PRESENT (AGENTS_FULL). RED proof: the pinned pre-fix snapshot (same one AC-8/AC-11 use —
#      it has NO subagent_type-aware logic at all) exits 0 silent on this identical payload; the CURRENT hook
#      exits 2 naming the inert-effort condition + the fix. ----
PRED='{"session_id":"ac1513red","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
if [ "$HEAD_AVAILABLE" = "1" ]; then
  run_head "$PRED" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
  { [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
    && ok "AC-RED HEAD: planner+general-purpose+cc-planner.md-present on the PRE-#1513 hook -> exit 0 silent (the leak, reproduced)" \
    || bad "AC-RED HEAD should silently pass (rc=$RC out=$CAP)"
fi
runh "$HOOK" "$PRED" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "inert" && echo "$CAP" | grep -qi "effort" && echo "$CAP" | grep -q "subagent_type: cc-planner"; } \
  && ok "AC-RED post-fix: same payload -> exit 2, names EFFORT inertness + the fix (subagent_type: cc-planner)" \
  || bad "AC-RED post-fix should block and name the inert-effort condition (rc=$RC out=$CAP)"

# ---- AC-RED-CLAUDE (per-disjunct fixture): subagent_type:claude (not hardcoded to "general-purpose"). ----
PREDC='{"session_id":"ac1513redclaude","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"claude"}}'
runh "$HOOK" "$PREDC" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "inert" && echo "$CAP" | grep -q "subagent_type: cc-planner"; } \
  && ok "AC-RED-CLAUDE: subagent_type:claude (not general-purpose) + cc-planner.md present -> exit 2 (not hardcoded to one string)" \
  || bad "AC-RED-CLAUDE should also fire on subagent_type:claude (rc=$RC out=$CAP)"

# ---- AC-POS (positive control — right robot stays clean): subagent_type:cc-planner, cc-planner.md present -> exit 0, no marker. ----
PPOS='{"session_id":"ac1513pos","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"cc-planner"}}'
runh "$HOOK" "$PPOS" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-POS: subagent_type:cc-planner (the right robot) -> exit 0 clean, no inert-effort marker" \
  || bad "AC-POS should stay silent when the dedicated def IS used (rc=$RC out=$CAP)"

# ---- AC-NEG (sanctioned fallback — def absent must NOT fire): general-purpose, DEFAULT AGENTS_FIX (which
#      lacks cc-planner.md) -> exit 0, no marker. This is the case the fix must never false-block. ----
PNEG='{"session_id":"ac1513neg","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
run "$PNEG"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-NEG: cc-planner.md absent (sanctioned fallback) -> exit 0, never false-blocked" \
  || bad "AC-NEG should never fire when the dedicated def is genuinely absent (rc=$RC out=$CAP)"

# ---- AC-NEG-DANGLING (broken install reads as absent): cc-planner.md is a symlink to a missing target. ----
PDANG='{"session_id":"ac1513dangling","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PDANG" CC_ROLE_AGENTS_DIR="$AGENTS_DANGLING"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-NEG-DANGLING: dangling symlink at cc-planner.md -> reads as ABSENT -> exit 0, never false-blocked" \
  || bad "AC-NEG-DANGLING should treat a dangling def-symlink as absent (rc=$RC out=$CAP)"

# ---- AC-EXECUTOR-TIER (non-opus seat, effort still asserted independent of tier): executor, model:sonnet
#      (matches the sonnet policy), subagent_type:general-purpose, AGENTS_FIX (has cc-executor.md) -> exit 2. ----
PTIER='{"session_id":"ac1513tier","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:1513 ROLE:executor\nGo.","subagent_type":"general-purpose"}}'
run "$PTIER"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "inert" && echo "$CAP" | grep -q "subagent_type: cc-executor"; } \
  && ok "AC-EXECUTOR-TIER: tier-satisfied non-opus (sonnet) seat still fires the effort advisory" \
  || bad "AC-EXECUTOR-TIER should not be opus-only (rc=$RC out=$CAP)"

# ---- AC-RESEARCH (research never gated): ROLE:research resolves ROLE=- and fail-opens before the new logic
#      even runs (belt-and-suspenders — the ROLE regex never matches "research"). ----
PRESEARCH='{"session_id":"ac1513research","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:research\nLook it up.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PRESEARCH" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-RESEARCH: ROLE:research -> exit 0, never gated by the effort leg" \
  || bad "AC-RESEARCH should fail-open before the effort leg runs (rc=$RC out=$CAP)"

# ---- AC-INDEP (independent block-once — the marker-cannibalization trap, Design nuance C). SHARED session_id
#      across both issues (so SIG collides): (1) tier-MISMATCH for {taskId:1513indep, ROLE:executor}
#      (model:opus on the sonnet seat) -> fires the TIER advisory, writes $SIG.notified. (2) SAME
#      session/taskId/role, tier-SATISFIED (model:sonnet) but subagent_type wrong + cc-executor.md present ->
#      MUST still exit 2 via the effort advisory (NOT suppressed by the tier marker from step 1). ----
PINDEP1='{"session_id":"ac1513indep","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513indep ROLE:executor\nImplement."}}'
run "$PINDEP1"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "WRONG model tier"; } \
  && ok "AC-INDEP step 1: tier-mismatch fires the TIER advisory + writes its marker" \
  || bad "AC-INDEP step 1 should fire the tier advisory (rc=$RC out=$CAP)"
PINDEP2='{"session_id":"ac1513indep","tool_input":{"model":"sonnet","prompt":"3ROLE_TASK:1513indep ROLE:executor\nImplement.","subagent_type":"general-purpose"}}'
run "$PINDEP2"
{ [ "$RC" = "2" ] && echo "$CAP" | grep -qi "inert" && echo "$CAP" | grep -q "subagent_type: cc-executor"; } \
  && ok "AC-INDEP step 2: SAME session/taskId/role, tier now satisfied -> effort advisory STILL fires (independent marker, not cannibalized)" \
  || bad "AC-INDEP step 2 should fire the effort advisory despite the tier marker from step 1 (rc=$RC out=$CAP)"

# ---- AC-ONCE (block-once, self-clearing — proves advisory not wall): issue a FRESH effort-condition payload
#      twice against the persistent shared STATE_DIR -> first exit 2, second exit 0. ----
PONCE='{"session_id":"ac1513once","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513once ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PONCE" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"; rc_once1=$RC
runh "$HOOK" "$PONCE" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"; rc_once2=$RC
{ [ "$rc_once1" = "2" ] && [ "$rc_once2" = "0" ]; } \
  && ok "AC-ONCE: effort advisory fires once then falls through on re-issue (rc1=$rc_once1 rc2=$rc_once2)" \
  || bad "AC-ONCE should block-once and self-clear (rc1=$rc_once1 rc2=$rc_once2)"

# ---- AC-EMPTY (boundary — empty subagent_type fail-opens; Design nuance E): def present, subagent_type:"" -> exit 0. ----
PEMPTY='{"session_id":"ac1513empty","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":""}}'
runh "$HOOK" "$PEMPTY" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "AC-EMPTY: subagent_type:\"\" (malformed/edge payload) -> exit 0, fail-open" \
  || bad "AC-EMPTY should fail-open on an empty subagent_type (rc=$RC out=$CAP)"

# ---- AC-KILL (kill-switches honored) — each on a FRESH, otherwise-positive effort-condition payload. ----
PKILLA='{"session_id":"ac1513killa","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PKILLA" CC_ROLE_AGENTS_DIR="$AGENTS_FULL" CC_ROLE_MODEL_GATE_OFF=1; rc_killa=$RC
PKILLB='{"session_id":"ac1513killb","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PKILLB" CC_ROLE_AGENTS_DIR="$AGENTS_FULL" THREE_ROLE_INSTRUMENT_OFF=1; rc_killb=$RC
PKILLC='{"session_id":"ac1513killc","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PKILLC" CC_ROLE_AGENTS_DIR="$AGENTS_FULL" SHIP_PIPELINE=1; rc_killc=$RC
PKILLD='{"session_id":"ac1513killd","tool_input":{"model":"opus","prompt":"3ROLE_TASK:1513 ROLE:planner [model-policy-ok]\nPlan it.","subagent_type":"general-purpose"}}'
runh "$HOOK" "$PKILLD" CC_ROLE_AGENTS_DIR="$AGENTS_FULL"; rc_killd=$RC
{ [ "$rc_killa" = "0" ] && [ "$rc_killb" = "0" ] && [ "$rc_killc" = "0" ] && [ "$rc_killd" = "0" ]; } \
  && ok "AC-KILL: kill-switches (CC_ROLE_MODEL_GATE_OFF / THREE_ROLE_INSTRUMENT_OFF / SHIP_PIPELINE) + inline bypass all -> exit 0 on an otherwise-positive effort-condition payload" \
  || bad "AC-KILL escapes should suppress a real effort-leg block (rc_a=$rc_killa rc_b=$rc_killb rc_c=$rc_killc rc_d=$rc_killd)"

# ---- AC-REGRESSION / AC-NONDECAY are the pre-existing SECTION 0-4 arms above (unaffected by the new sub-leg —
#      AGENTS_FIX never contains cc-planner.md, so AC-9/M1/M4 stay silent; AC-16 already asserts non-decay).
#      No separate row needed here — this whole file's [ "$fail" = "0" ] tally IS AC-REGRESSION's mechanical
#      backstop, and it re-runs on every invocation.

[ "$fail" = "0" ] && { echo "ALL PASS"; exit 0; } || { echo "SMOKE FAILED"; exit 1; }
