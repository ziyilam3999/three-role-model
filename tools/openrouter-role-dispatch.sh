#!/usr/bin/env bash
# tools/openrouter-role-dispatch.sh — #1947 S2. The COMMITTED dispatch helper that puts a 3-role seat
# (plan-review, executor) on a non-Anthropic OpenRouter model via a hermetic `claude -p` subprocess, because
# the Agent tool's `model` param only selects Anthropic tiers and provider routing binds once at process
# launch [MEASURED, #1685/#1917] — an in-process Agent spawn structurally cannot do this.
#
# Why a committed helper and not a hand-typed env block: the #1696 failure class IS a half-applied env
# family, and the #1544-class lesson is to fix the GENERATOR (one script that always emits the complete,
# measured recipe) rather than detect bad hand-typed copies later. See the #1947 plan, D1.
#
# Usage:
#   tools/openrouter-role-dispatch.sh --role <plan-review|executor> --brief <path> --task <id>
#       --session <orchestrator-session-id> [--cwd <dir>] [--timeout <secs>] [--drill]
#       [--allowed-tools "<space-separated tool list>"] [--dry-run]
#
# --dry-run prints the env var NAMES this dispatch would set for the child process (never values;
# ANTHROPIC_API_KEY is marked EMPTY-STRING, the one var whose value is intentionally always empty) and makes
# NO network call. --dry-run does not require --brief/--task/--session.
#
# Real (non-dry-run) invocation: resolves the seat's slug from the router SSOT, fails closed if the
# OpenRouter key file is absent, runs `claude -p` hermetically with the full measured env family scoped to
# the CHILD PROCESS ONLY (never exported into this script's own shell, never into the caller's shell), reads
# the served model + transcript path back from the subprocess's own JSON output, THIS HELPER self-appends
# the `dispatch=subprocess-openrouter` + transcript + nonce ledger fields (the "spawn-side" stamp — #1947 D2)
# while the DISPATCHED ROLE's own brief instructs it to self-append its `--artifact` (and, for plan-review,
# `--verdict`) using the SAME --session/--task/--role — the two composed via the ledger's own overlay-merge,
# exactly like an Agent-tool role's spawn-time-agentId + close-time-artifact split. It then polls the
# OpenRouter usage endpoint (never the CLI's own fabricated cost field — measured ~1,255x off in #1684) for
# the real spend delta, and appends a flush-left receipt line to the live-smoke status file.
#
# Exit codes: 0 = the subprocess completed (regardless of the subprocess's OWN verdict, which lives in its
# artifact, never in this script's exit code); 124 = TIMEOUT/STALL (a DISTINCT code from ordinary failure,
# per D1); any other nonzero = an ordinary dispatch failure (key missing, seat unresolved, etc).
#
# Timeout budget (#2046 D1): the wall-clock default is PER-ROLE and derived from this repo's own measured
# receipt history — executor 3600s, plan-review 2700s, anything else 1800s. `--timeout` beats
# $OPENROUTER_DISPATCH_TIMEOUT_S beats the per-role default. See the derivation comment at the resolution site.
#
# Failure post-mortem (#2046 D2): EVERY non-success exit (124 timeout, rc!=0 error, malformed JSON) now
# preserves the subprocess's stdout/stderr instead of deleting them, resolves the subprocess's own
# incrementally-written transcript from $DISPATCH_CWD, and appends a second, machine-parseable
# `OR-DISPATCH-POSTMORTEM` receipt line carrying counters + a fixed-vocabulary `verdict_hint`
# (no-transcript | zero-tool-calls | research-only | partial-work | unmeasured). The pre-existing
# `OR-DISPATCH-FALLBACK` line is emitted UNCHANGED alongside it — the post-mortem is purely additive, so any
# existing parser of that grammar keeps working.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LEDGER="$REPO_ROOT/bin/3role-ledger.mjs"
RECEIPT_FILE="${OPENROUTER_DISPATCH_RECEIPT_FILE:-$REPO_ROOT/.ai-workspace/status/1947-seat-mix-live-smoke.md}"
KEY_FILE="${OPENROUTER_KEY_FILE:-$HOME/.config/openrouter.prod.env}"
LEDGER_DIR="${THREE_ROLE_LEDGER_DIR:-$HOME/.claude/3role-ledger}"
PROJECTS_ROOT="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
# #2046 D2 — where a FAILED dispatch's preserved stdout/stderr land. Under `.ai-workspace/_*` so Rule 16's
# gitignore covers it (throw-away scratch, mv-not-rm safe); overridable so the hermetic smoke never writes
# into the real repo (same override-seam discipline as OPENROUTER_DISPATCH_RECEIPT_FILE, #2005 D1/D3).
POSTMORTEM_DIR="${OPENROUTER_DISPATCH_POSTMORTEM_DIR:-$REPO_ROOT/.ai-workspace/_or-dispatch-postmortem}"

ROLE=""
BRIEF=""
TASK=""
SESSION=""
CWD=""
TIMEOUT_S=""          # resolved AFTER arg parsing — the default is now PER-ROLE (#2046 D1, see below)
DRILL=0
DRY_RUN=0
ALLOWED_TOOLS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --brief) BRIEF="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --timeout) TIMEOUT_S="$2"; shift 2 ;;
    --drill) DRILL=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    --allowed-tools) ALLOWED_TOOLS="$2"; shift 2 ;;
    *) echo "openrouter-role-dispatch: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$ROLE" ]; then
  echo "openrouter-role-dispatch: --role is required (plan-review|executor)" >&2
  exit 2
fi

# ── #2153 AC-2 — fail-closed refusal of an unreplaced required-replacement marker in the brief,
# HOISTED above the KEY_FILE pre-flight (below) and therefore above the --dry-run early-exit too
# (design B1, plan round 2). WHY here and not lower: a three-arm probe measured that in a no-
# credentials shell the KEY_FILE guard fires FIRST and makes any check placed below it structurally
# UNREACHABLE — so a marker refusal that must fire before this helper spends any provider/network
# call has to sit above BOTH existing fail-closed guards. Ordering weakens neither: every brief that
# clears this check still hits the key-file guard right after. NO-OP when $BRIEF is empty/absent —
# every existing --dry-run-with-no-brief and no-`--brief` real-dispatch path stays byte-for-byte
# unchanged (this is what keeps the pre-existing `:406`/`:549-552`-class dry-run arms green).
#
# Marker grammar: a live required-replacement marker is "[" immediately followed by 2+ uppercase
# letters, up to its matching "]" (may span multiple physical lines -- two of this repo's own
# template markers do). This shape deliberately does NOT match an ordinary markdown link
# (`[text](url)`, lowercase-led) or a reference-style bracket (`[1]`, digit-led). Quoting
# convention (documented in the templates): wrap the bracket syntax in backticks to REFER to it in
# prose without triggering a live-marker refusal -- inline-code spans are stripped before matching,
# so a backtick-quoted example of the marker syntax never counts as a live, unreplaced one.
if [ -n "$BRIEF" ] && [ -f "$BRIEF" ]; then
  MARKER_HIT="$(BRIEF_PATH="$BRIEF" node -e '
    const fs = require("fs");
    const path = process.env.BRIEF_PATH;
    let text;
    try { text = fs.readFileSync(path, "utf8"); } catch (e) { process.exit(0); }
    const stripped = text.replace(/`[^`]*`/g, "");
    const MARKER_RE = /\[[A-Z]{2,}[\s\S]*?\]/;
    process.stdout.write(MARKER_RE.test(stripped) ? "1" : "0");
  ' 2>/dev/null)"
  if [ "$MARKER_HIT" = "1" ]; then
    echo "openrouter-role-dispatch: UNREPLACED-MARKER detected in brief '$BRIEF' -- a required-replacement placeholder (a bracketed, ALL-CAPS-led span) is still live in the rendered brief. Fill in every bracketed marker with real, task-specific text before dispatch. Refusing before any provider/network spend (fail-closed, #2153)." >&2
    exit 4
  fi
fi

# ── #2046 D1 — PER-ROLE wall-clock default, MEASURED not guessed ────────────────────────────────────────────
# Precedence (highest first): --timeout <n>  >  $OPENROUTER_DISPATCH_TIMEOUT_S  >  the per-role default below.
#
# WHY these numbers. The flat 1800s default was never derived from an observation; #2046's live incident
# proved it under-sized. Measured from this repo's OWN receipt file (.ai-workspace/status/1947-seat-mix-live-
# smoke.md), every real dispatch through this helper to date:
#   role=executor    (z-ai/glm-5.2)      successes: 53, 782, 1252, 1501s   -> max success = 83% OF THE 1800s CAP
#                                        killed at the cap: task 1851 (1800s), task 1989 (1801s)
#   role=plan-review (moonshotai/kimi-k3) successes: 114 .. 1452s          -> max success = 81% of the cap
#                                        killed at the cap: task 1681 (1800s)
# A cap whose right tail of SUCCESSES sits at ~83% of the cap is a cap that truncates the distribution, not
# one that catches hangs. #2046's own transcript is the decisive case: the executor was killed 17 SECONDS
# after it finished designing and flipped its first implementation task to in_progress, having spent 181,186
# characters in extended-thinking blocks (one single block = 8m10s = 27% of the whole budget). It was not
# hung; it was correctly working and simply had not reached the writing phase yet.
# Executor gets 2x the observed max success (1501s -> 3600s) because it must both READ+DESIGN *and* WRITE;
# plan-review gets ~1.9x its observed max (1452s -> 2700s) because it only ever reads and writes one verdict.
# These are BUDGETS, not allocations — a dispatch that finishes in 300s still costs 300s (a ceiling is not
# an allocation). Re-derive from the receipt file whenever the seat models change; do not fold a new model in
# on vibes.
if [ -z "$TIMEOUT_S" ]; then
  TIMEOUT_S="${OPENROUTER_DISPATCH_TIMEOUT_S:-}"
fi
if [ -z "$TIMEOUT_S" ]; then
  case "$ROLE" in
    executor)    TIMEOUT_S=3600 ;;
    plan-review) TIMEOUT_S=2700 ;;
    *)           TIMEOUT_S=1800 ;;
  esac
fi

# ── Resolve the seat's slug from the router SSOT (never hand-typed) ────────────────────────────────────────
SEAT_JSON="$(node "$LEDGER" resolve-route --seat "$ROLE" --json 2>&1)"
RESOLVE_RC=$?
if [ "$RESOLVE_RC" -ne 0 ]; then
  echo "openrouter-role-dispatch: resolve-route --seat $ROLE failed (rc=$RESOLVE_RC): $SEAT_JSON" >&2
  exit 2
fi
SLUG="$(printf '%s' "$SEAT_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(j.model||"")}catch(e){}})')"
DISPATCH_KIND="$(printf '%s' "$SEAT_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(j.dispatch||"")}catch(e){}})')"
if [ -z "$SLUG" ]; then
  echo "openrouter-role-dispatch: seat '$ROLE' resolved no model slug from the SSOT" >&2
  exit 2
fi
if [ "$DISPATCH_KIND" != "subprocess-openrouter" ]; then
  echo "openrouter-role-dispatch: seat '$ROLE' is not SSOT-declared dispatch=subprocess-openrouter (got '$DISPATCH_KIND') — refusing to dispatch a role this helper is not the sanctioned path for" >&2
  exit 2
fi
FALLBACK_TIER="$(printf '%s' "$SEAT_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(j.agent_tool_fallback||"")}catch(e){}})')"

# ── #2105 D3 — MODE GATE, before ANY child process, ANY network, ANY key read (AC 8(e)/(f)/(g)) ────────────
# The mode axis is enforced HERE, at the top of this dispatch helper — never delegated to the Agent-tool
# route-dispatch gate alone, and NEVER consulting OpenRouter key balance (the existing credit-floor checks
# stay unchanged, AFTER this gate, and apply only in conservative mode where dispatch is even reachable).
MODE_OUT="$(node "$LEDGER" resolve-mode 2>&1)"
MODE_RC=$?
if [ "$MODE_RC" -ne 0 ]; then
  # resolve-mode's own in-code fallback path always exits 0 -- a nonzero exit means a genuine crash. Fail
  # CLOSED here (unlike the lane doorman's fail-OPEN): a crashed resolver must never be treated as silent
  # permission to reach a non-Anthropic provider.
  echo "openrouter-role-dispatch: MODE-REFUSAL resolve-mode crashed (rc=$MODE_RC): $MODE_OUT — refusing to dispatch (fail-closed on an unresolvable mode)" >&2
  exit 5
fi
MODE_VAL="$(printf '%s\n' "$MODE_OUT" | command grep -m1 '^mode=' | cut -d= -f2)"
SRC_VAL="$(printf '%s\n' "$MODE_OUT" | command grep -m1 '^source=' | cut -d= -f2)"
DISPATCH_PERM="$(printf '%s\n' "$MODE_OUT" | command grep -m1 '^openrouter_dispatch=' | cut -d= -f2)"
SET_AT_VAL="$(printf '%s\n' "$MODE_OUT" | command grep -m1 '^set_at=' | cut -d= -f2-)"
REASON_VAL="$(printf '%s\n' "$MODE_OUT" | command grep -m1 '^reason=' | cut -d= -f2-)"
# AC 20(b) — the mode-verdict provenance suffix: source= always; set_at=/reason= ONLY when source=pin (the
# paired absence arm — a source=default refusal carries NEITHER field, never an empty placeholder).
MODE_VERDICT_SUFFIX="source=$SRC_VAL"
if [ "$SRC_VAL" = "pin" ]; then
  MODE_VERDICT_SUFFIX="$MODE_VERDICT_SUFFIX set_at=$SET_AT_VAL"
  [ -n "$REASON_VAL" ] && MODE_VERDICT_SUFFIX="$MODE_VERDICT_SUFFIX reason=$REASON_VAL"
fi
# AC 20(b) — the mode-verdict output, printed UNCONDITIONALLY (refusal, dry-run, AND pass-through) so a
# conservative-mode dispatch ships its own authorization evidence in its own artifact, and a normal-mode
# refusal is grep-able for the SAME distinct grammar. Uses a bare "MODE " prefix distinct from the receipt
# file's own unrelated `source=openrouter-usage` (cost-data-source) key — never conflated.
echo "openrouter-role-dispatch: MODE mode=$MODE_VAL $MODE_VERDICT_SUFFIX" >&2

# ── #2189 AC-7 — pin-age tell: WARN (never refuse) when the resolved mode pin is older than the SAME
#    staleness threshold #1939 uses for READING staleness (config/lane-modes.json staleness.maxAgeHours=24),
#    deliberately borrowed here for PIN age (the config governs reading staleness; this is a documented
#    borrow, not a claim the two are the same concept — ticket scope item 2, translated per the plan's
#    Approach point 4). Applies to ANY pin regardless of provenance: #2189 ships no automated pin writer, so
#    there is no provenance axis to scope by — every pin is operator-written, and only its AGE matters. A pin
#    with no set_at (source=default, i.e. no pin at all) has no age to judge -> silent, no token. Prints
#    UNCONDITIONALLY alongside the MODE line above (refusal, dry-run, and pass-through alike) so the tell
#    survives every code path a caller might only capture 2>&1 from. Never refuses — staleness converted into
#    a refusal would turn a stale pin into a 3-role-chain outage, the direction D1 already rejects.
LANE_MODES_JSON="${CC_LANE_MODES_JSON:-$REPO_ROOT/config/lane-modes.json}"
if [ "$SRC_VAL" = "pin" ] && [ -n "$SET_AT_VAL" ]; then
  PIN_STALE_OUT="$(
    LANE_MODES_JSON_VAL="$LANE_MODES_JSON" SET_AT_ENV_VAL="$SET_AT_VAL" node -e '
      const fs = require("fs");
      let maxH = 24;   // in-code fallback if the config is unreadable/unparseable — never crash the dispatch.
      try {
        const cfg = JSON.parse(fs.readFileSync(process.env.LANE_MODES_JSON_VAL, "utf8"));
        if (cfg && cfg.staleness && typeof cfg.staleness.maxAgeHours === "number") maxH = cfg.staleness.maxAgeHours;
      } catch (e) { /* fall back to the in-code default above */ }
      const setMs = Date.parse(process.env.SET_AT_ENV_VAL || "");
      if (Number.isNaN(setMs)) { process.exit(0); }
      const ageH = (Date.now() - setMs) / 3600000;
      if (ageH > maxH) { process.stdout.write("age_h=" + ageH.toFixed(1) + " max_h=" + maxH); }
    ' 2>/dev/null
  )"
  if [ -n "$PIN_STALE_OUT" ]; then
    echo "openrouter-role-dispatch: PIN-STALE mode=$MODE_VAL $PIN_STALE_OUT set_at=$SET_AT_VAL — the operator's mode pin is older than the staleness threshold borrowed from config/lane-modes.json staleness.maxAgeHours; the pin still governs (warn only, never refused) but consider re-confirming it is still intended." >&2
  fi
fi

if [ "$DRY_RUN" -ne 1 ] && [ "$DISPATCH_PERM" != "permitted" ]; then
  # Refuse BEFORE the key-file pre-flight, BEFORE any usage_total()/credits network call, BEFORE any
  # subprocess. Receipt file is byte-unchanged; no postmortem dir entry (AC 8(a)).
  echo "openrouter-role-dispatch: MODE-REFUSAL mode=$MODE_VAL $MODE_VERDICT_SUFFIX role=$ROLE — OpenRouter dispatch is not permitted outside conservative mode (operator directive: Anthropic-only by default). Sanctioned path in this mode: an Agent-tool spawn of this seat on its agent_tool_fallback tier (model:${FALLBACK_TIER:-unknown}), carrying the inline token [route-dispatch-fallback-ok]. To permit OpenRouter dispatch: node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" set-mode --mode conservative --reason \"<why>\"." >&2
  exit 5
fi

# ── Per-role default --allowedTools grant (overridable via --allowed-tools) ─────────────────────────────────
if [ -z "$ALLOWED_TOOLS" ]; then
  case "$ROLE" in
    plan-review) ALLOWED_TOOLS="Read Grep Glob Bash Write Edit" ;;
    executor)    ALLOWED_TOOLS="Read Grep Glob Bash Write Edit" ;;
    *)           ALLOWED_TOOLS="Read Grep Glob Bash" ;;
  esac
fi

# ── Fail-closed pre-flight: the key file must exist (never read into any output, referenced by path only) ──
if [ ! -f "$KEY_FILE" ]; then
  echo "openrouter-role-dispatch: OPENROUTER key file '$KEY_FILE' does not exist — refusing to dispatch (fail-closed pre-flight, #1737 Step 5a)" >&2
  exit 3
fi
KEY_MODE="$(stat -f '%Lp' "$KEY_FILE" 2>/dev/null || stat -c '%a' "$KEY_FILE" 2>/dev/null || echo '')"
if [ -n "$KEY_MODE" ] && [ "$KEY_MODE" != "600" ]; then
  echo "openrouter-role-dispatch: WARN key file '$KEY_FILE' mode is $KEY_MODE, not 600 (not blocking; tighten it: chmod 600 '$KEY_FILE')" >&2
fi

# ── Privacy (#1947 AC-9, hoisted #2005 D2): the receipt file is a TRACKED, PUBLIC artifact, but a real
#    absolute path under $HOME (e.g. `find`'s own output, or a worktree cwd) always contains the operator's
#    literal macOS username — a genuine PII leak the moment it lands in any output surface (measured:
#    privacy-scan.sh's PRIVACY_HOMEPATH_ERE correctly flags `/Users/<name>` with no carve-out for a real
#    username). Collapse any $HOME-rooted path to portable `~/`-form before it is ever printed or written.
#    Hoisted ABOVE the --dry-run block (was defined later, l.173 pre-#2005) so the new dry-run receipt-path
#    diagnostic below can call it — the function is pure (`$1` + `$HOME` only) with no dependencies, so this
#    relocation changes no behavior for its existing callers further down this file. Mirrors
#    normalizeArtifact()'s R6 rule in hooks/3role-ledger.mjs, so the two stay consistent. Internal use (the
#    ledger append call, ledger_field() lookups) keeps the real absolute path; only OUTPUT surfaces collapse.
to_tilde() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    "$HOME") printf '~' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── --dry-run: print the env var NAMES only (never values), no network call. Also reports the RESOLVED
#    receipt path (#2005 D2) — privacy-collapsed via to_tilde() above — so "default unchanged when unset" and
#    "override honored when set" are both checkable hermetically, with no network, key, or receipt write. ───
if [ "$DRY_RUN" -eq 1 ]; then
  for v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
           ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
    echo "ENV $v"
  done
  echo "ENV ANTHROPIC_API_KEY=EMPTY-STRING"
  echo "RECEIPT_FILE=$(to_tilde "$RECEIPT_FILE")"
  # AC 8 — --dry-run makes NO network call and is NEVER refused by the mode gate, but must still print the
  # resolved mode verdict (computed above, before this block, so a dry-run also exercises the resolver).
  echo "MODE mode=$MODE_VAL $MODE_VERDICT_SUFFIX"
  echo "# role=$ROLE slug=$SLUG allowedTools=$ALLOWED_TOOLS timeout=${TIMEOUT_S}s (dry-run — no network call)"
  exit 0
fi

if [ -z "$BRIEF" ] || [ ! -f "$BRIEF" ]; then
  echo "openrouter-role-dispatch: --brief <path> must name an existing file (the prompt is delivered from disk, never inline shell text)" >&2
  exit 2
fi
if [ -z "$TASK" ]; then
  echo "openrouter-role-dispatch: --task <id> is required" >&2
  exit 2
fi
# ── #2001 D3 — fail-closed: --session is REQUIRED for a real (non-dry-run) dispatch ─────────────────────────
# `hooks/3role-ledger.mjs`'s `ledgerFile(session, task)` maps exactly one (session, task) pair to exactly one
# file; `check --session <orchestrator-sid> --task <id>` can only ever see rows filed under THAT session. A
# dispatch that never learns the orchestrator's session key writes a row nobody can check — the exact silent
# scattering #2001 fixes (measured live on #1995: a real 4-role task mixing Agent-tool and subprocess
# dispatches scattered its rows across N session files). SESSION_SANITIZED mirrors the ledger's OWN
# `sanitize()` (`[0-9A-Za-z._-]` only) so a value that SANITIZES to empty (e.g. `--session "///"`) is refused
# just like an absent one — otherwise it would silently mis-file the row at `<LEDGER_DIR>/<task>.jsonl` with
# no session directory component, a failure `check` can never find either.
SESSION_SANITIZED="$(printf '%s' "$SESSION" | tr -dc 'A-Za-z0-9._-')"
if [ -z "$SESSION" ] || [ -z "$SESSION_SANITIZED" ]; then
  echo "openrouter-role-dispatch: --session <orchestrator-sid> is required for a real dispatch and must contain at least one [0-9A-Za-z._-] character (fail-closed, #2001 D3) — --dry-run does not require it" >&2
  exit 2
fi
# NOTE (#2001): a `claude -p` one-shot cannot learn its OWN session id until AFTER it exits (the id is only
# reported in the final JSON envelope) — but every ledger write THIS dispatch produces (the spawn-side stamp
# below, and the self-append instruction prepended into the brief) is keyed by the ORCHESTRATOR's own
# `--session` value above, never by the subprocess's own minted id. The subprocess's own session id
# ($SUBPROC_SESSION, read back from the JSON envelope after the process exits) stays useful for exactly one
# thing: resolving its OWN transcript file on disk (the transcript is genuinely named by that id) — see the
# `find` + WARN diagnostic below.

# ── Mint a per-dispatch nonce (#1947 M2) and render it + the spawn tag into the brief's FIRST line ─────────
NONCE="OR-NONCE-$(node -e 'process.stdout.write(require("crypto").randomBytes(8).toString("hex"))')"
RUN_BRIEF="$(mktemp -t openrouter-role-dispatch-brief.XXXXXX)"
{
  echo "3ROLE_TASK:$TASK ROLE:$ROLE"
  echo "DISPATCH-NONCE:$NONCE"
  echo ""
  echo "(Self-append instructions: when you write your own ledger row at close, run this via YOUR Bash tool — this is the ORCHESTRATOR's session (not a value you look up yourself; use it exactly as shown), the same key every other role's row is filed under: node \"\${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs\" append --session \"$SESSION\" --task $TASK --role $ROLE --artifact <your-artifact-path>$([ "$ROLE" = "plan-review" ] && echo ' --verdict PASS-or-FAIL') — do NOT pass --dispatch/--transcript/--nonce yourself, the dispatch helper stamps those separately after you exit.)"
  echo ""
  cat "$BRIEF"
} > "$RUN_BRIEF"

DISPATCH_CWD="${CWD:-$REPO_ROOT}"

# ── Provider-side usage BEFORE (the only honest cost oracle — never the CLI's own cost field, fabricated
#    ~1,255x against this gateway [MEASURED, #1684]) ────────────────────────────────────────────────────────
usage_total() {
  ( set -a; . "$KEY_FILE"; set +a
    curl -sS -H "Authorization: Bearer $OPENROUTER_API_KEY" https://openrouter.ai/api/v1/credits 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).data.total_usage)}catch(e){console.log("")}})'
  )
}
USAGE_BEFORE="$(usage_total)"

# ── Run hermetically. The env family is scoped to THIS command only (child process) — never exported into
#    this script's own shell (no `export` above this line touches any ANTHROPIC_* var), never into the
#    caller's shell (a bash script cannot mutate its caller's environment). ────────────────────────────────
OUT_FILE="$(mktemp -t openrouter-role-dispatch-out.XXXXXX)"
START_TS=$(date +%s)
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || echo '')"
if [ -z "$TIMEOUT_BIN" ]; then
  echo "openrouter-role-dispatch: no 'timeout' or 'gtimeout' binary found — cannot bound wall-clock, refusing to run unbounded" >&2
  rm -f "$RUN_BRIEF"
  exit 3
fi

( set -a; . "$KEY_FILE"; set +a
  export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
  export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
  export ANTHROPIC_API_KEY=""
  export ANTHROPIC_MODEL="$SLUG"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$SLUG"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$SLUG"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SLUG"
  export ANTHROPIC_DEFAULT_FABLE_MODEL="$SLUG"
  cd "$DISPATCH_CWD" && \
  "$TIMEOUT_BIN" "${TIMEOUT_S}s" claude -p "$(cat "$RUN_BRIEF")" \
    --output-format json \
    --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --allowedTools $ALLOWED_TOOLS \
    > "$OUT_FILE" 2>"$OUT_FILE.stderr"
)
CLAUDE_RC=$?
END_TS=$(date +%s)
LATENCY_S=$((END_TS - START_TS))
rm -f "$RUN_BRIEF"

mkdir -p "$(dirname "$RECEIPT_FILE")"
DRILL_FIELD=0
[ "$DRILL" -eq 1 ] && DRILL_FIELD=1

# ── #2189 D4 — evidence-marker writer: on each REAL (non-drill) failure path below, record an untracked,
#    role+task-keyed marker under CC_ROUTE_DISPATCH_STATE_DIR — the ONLY signal
#    hooks/three-role-route-dispatch-gate.sh's conservative-mode persistent refusal reads to permit a
#    sanctioned Agent-tool fallback for THIS exact role+task. Never the tracked receipt file (round-2 B1: a
#    receipt row is forgeable free text in a file normal work already edits) — this marker lives outside
#    every repo, untracked, in the SAME directory the gate already uses for its own state (default
#    ~/.claude/.three-role-route-dispatch-state), under a DISTINCT `.evidence` namespace from any legacy
#    `.notified` sentinel (r2 N6). Filename convention MUST match the gate's own EVSIG computation exactly:
#    sha1(role + ":" + task) — never session (D4's measured constraint: a failed dispatch and its fallback
#    spawn need not share a session). Drill runs (AC-3(f)) NEVER write this marker — a rehearsal proves
#    nothing about whether the REAL dispatch for this task can run, and admitting drill failures as evidence
#    would let an agent manufacture admissible evidence at will by running a deliberately-failing drill (D4's
#    own decision, "drill rows are EXCLUDED — decided explicitly").
write_evidence_marker() {   # $1 = reason token (timeout|error|malformed-json), informational content only
  [ "$DRILL_FIELD" -eq 1 ] && return 0
  local state_dir sig marker
  state_dir="${CC_ROUTE_DISPATCH_STATE_DIR:-$HOME/.claude/.three-role-route-dispatch-state}"
  mkdir -p "$state_dir" 2>/dev/null
  sig="$(ROLE_SIG_VAL="$ROLE" TASK_SIG_VAL="$TASK" node -e '
    const crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha1").update(process.env.ROLE_SIG_VAL + ":" + process.env.TASK_SIG_VAL).digest("hex"));
  ' 2>/dev/null)"
  [ -n "$sig" ] || return 0
  marker="$state_dir/$sig.evidence"
  printf 'role=%s task=%s reason=%s drill=%s ts=%s\n' "$ROLE" "$TASK" "$1" "$DRILL_FIELD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker" 2>/dev/null
  return 0
}

# ── #2046 D2 — FAILURE-PATH POST-MORTEM ────────────────────────────────────────────────────────────────────
# The bug this exists to kill is NOT the timeout itself — it is that a timed-out (or errored) dispatch used to
# `rm -f` the subprocess's stdout+stderr and log a single row reading `session=n/a` with no cwd, no transcript
# pointer and no counters. That row cannot distinguish ANY of the four things an operator actually needs to
# tell apart:
#     the subprocess never started        (provider/auth/network)   -> verdict_hint=no-transcript
#     it started but never acted          (refusal / stuck loading) -> verdict_hint=zero-tool-calls
#     it worked but never reached writing (budget exhausted)        -> verdict_hint=research-only
#     it DID write real work we must salvage before re-dispatching  -> verdict_hint=partial-work
# #2046 sat as an un-diagnosed symptom restatement for two days precisely because the answer (research-only:
# 45 tool calls, 0 writes, still active 17s before the kill) required hand archaeology across ~/.claude/
# projects that this function now does automatically, in one line, at the moment of failure.
#
# It also serves #1983's sibling arm: that ticket is the `rc != 0` case where REAL work (a merged-quality PR)
# was reported as total failure. `verdict_hint=partial-work` + a preserved stderr is exactly the evidence that
# case needs, so the post-mortem is wired into BOTH non-success branches, never just the timeout one.
#
# PRIVACY: this appends to a TRACKED, PUBLIC receipt file. Every emitted path goes through to_tilde() (a real
# $HOME-rooted absolute path leaks the operator username — scripts/privacy-scan.sh flags it, no carve-out),
# and NO free text from the subprocess is ever embedded — only integer counters, a fixed-vocabulary
# verdict_hint, and pointers to preserved files. Model output can say anything; it never lands in the artifact.
dispatch_postmortem() {   # $1 = reason token (timeout|error|malformed-json)
  local reason pm_out evidence_dir bash_n
  reason="$1"

  # Preserve, never delete: the subprocess's own stdout + stderr, under a gitignored scratch dir.
  evidence_dir="$POSTMORTEM_DIR/${TASK}-${ROLE}-${END_TS}"
  mkdir -p "$evidence_dir" 2>/dev/null
  cp "$OUT_FILE" "$evidence_dir/stdout.txt" 2>/dev/null || : > "$evidence_dir/stdout.txt"
  cp "$OUT_FILE.stderr" "$evidence_dir/stderr.txt" 2>/dev/null || : > "$evidence_dir/stderr.txt"

  # Resolve the subprocess's OWN transcript from DISPATCH_CWD and count what it actually DID. The `claude`
  # CLI names its per-project transcript dir by slugifying the absolute cwd ([/._] -> "-"), and writes the
  # transcript INCREMENTALLY — so it survives a SIGTERM even though the JSON envelope on stdout never
  # arrives. That is why this is recoverable at all, and why deleting the temp files was never the loss:
  # the loss was never RECORDING where to look.
  pm_out="$(node -e '
    const fs = require("fs");
    const projectsRoot = process.argv[1], cwd = process.argv[2];
    const startMs = Number(process.argv[3]) * 1000, endMs = Number(process.argv[4]) * 1000;
    const modelSlug = process.argv[5];
    const out = { transcript: "", records: 0, tool_calls: 0, reads: 0, bash: 0, writes: 0,
                  think_chars: 0, idle_s: -1, last_model: "" };
    const dirSlug = cwd.replace(/[\/._]/g, "-");
    // #2046 B1: a `claude -p` one-shot always mints a FRESH transcript, so a candidate must have
    // been CREATED during this dispatch, not merely TOUCHED. The orchestrator live session
    // keeps appending to its (hours-old) transcript while this dispatch runs — that file has a NEW
    // mtime but an OLD birthtime, and under the sanctioned no-`--cwd` invocation (both
    // hooks/three-role-route-dispatch-gate.sh and agents/cc-executor.md OMIT --cwd) both files land
    // in the SAME project-slug dir. A birthtime filter (not mtime) is what tells them apart. Guard
    // for btime-less Linux FSes (stat reports birthtimeMs=0 when the FS does not track creation
    // time): fall back to the original mtime check there, so this never excludes EVERY file and
    // break the suite on CI — the model-match discriminator below still closes B1 on a btime-less FS.
    let candidates = [];
    try {
      const dir = projectsRoot + "/" + dirSlug;
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".jsonl")) continue;
        const p = dir + "/" + f;
        let st; try { st = fs.statSync(p); } catch (e) { continue; }
        if (st.birthtimeMs > 0) { if (!(st.birthtimeMs >= startMs - 2000)) continue; }   // born during this dispatch
        else                    { if (st.mtimeMs + 2000 < startMs) continue; }           // btime-less FS fallback
        candidates.push({ p, mtimeMs: st.mtimeMs });
      }
    } catch (e) { /* dir absent => no-transcript, an honest verdict, never a crash */ }
    // Among survivors, prefer the candidate whose records carry message.model === modelSlug (this
    // dispatch launched the subprocess with ANTHROPIC_MODEL=$SLUG, so the discriminator is sitting
    // right here). A foreign-session transcript — even one created in the same window by a
    // concurrent dispatch under the same project-slug dir — carries a DIFFERENT model and must NEVER
    // be reported as the counters of this dispatch. If no survivor matches, fail CLOSED to `unmeasured`
    // rather than attribute foreign-session writes/verdict to this dispatch (#2046 B1).
    let best = null, bestM = -1;
    for (const c of candidates) {
      let txt = ""; try { txt = fs.readFileSync(c.p, "utf8"); } catch (e) { continue; }
      let modelMatches = false;
      for (const ln of txt.split("\n")) {
        if (!ln.trim()) continue;
        let j; try { j = JSON.parse(ln); } catch (e) { continue; }
        if (j.message && j.message.model === modelSlug) { modelMatches = true; break; }
      }
      if (!modelMatches) continue;
      if (c.mtimeMs > bestM) { bestM = c.mtimeMs; best = { p: c.p, txt }; }
    }
    if (best) {
      out.transcript = best.p;
      let txt = best.txt;
      let lastTs = 0;
      for (const ln of txt.split("\n")) {
        if (!ln.trim()) continue;
        let j; try { j = JSON.parse(ln); } catch (e) { continue; }
        out.records++;
        if (j.timestamp) { const t = Date.parse(j.timestamp); if (t > lastTs) lastTs = t; }
        const m = j.message;
        if (m && m.model) out.last_model = m.model;
        if (m && Array.isArray(m.content)) {
          for (const c of m.content) {
            if (c.type === "tool_use") {
              out.tool_calls++;
              if (/^(Write|Edit|MultiEdit|NotebookEdit)$/.test(c.name)) out.writes++;
              else if (c.name === "Read") out.reads++;
              else if (c.name === "Bash") out.bash++;
            } else if (c.type === "thinking" && typeof c.thinking === "string") {
              out.think_chars += c.thinking.length;
            }
          }
        }
      }
      if (lastTs > 0) out.idle_s = Math.max(0, Math.round((endMs - lastTs) / 1000));
    }
    // FIXED VOCABULARY -- the whole point is that a future reader classifies by token, not by prose.
    // If a transcript was resolved, classify by its counters. If candidates existed but NONE matched
    // the dispatched model (foreign-session attribution risk, #2046 B1), fail CLOSED to `unmeasured`
    // — never report foreign-session writes/verdict as belonging to this dispatch. No candidates at all =>
    // no-transcript (the subprocess never started).
    out.verdict_hint = !out.transcript ? (candidates.length ? "unmeasured" : "no-transcript")
                     : out.tool_calls === 0 ? "zero-tool-calls"
                     : out.writes === 0 ? "research-only"
                     : "partial-work";
    for (const k of Object.keys(out)) console.log("PM_" + k.toUpperCase() + "=" + out[k]);
  ' "$PROJECTS_ROOT" "$DISPATCH_CWD" "$START_TS" "$END_TS" "$SLUG" 2>/dev/null)"

  pm_get() { printf '%s\n' "$pm_out" | command grep -m1 "^PM_$1=" | sed "s/^PM_$1=//"; }

  local pm_transcript pm_verdict
  pm_transcript="$(pm_get TRANSCRIPT)"
  pm_verdict="$(pm_get VERDICT_HINT)"
  [ -n "$pm_verdict" ] || pm_verdict="unmeasured"   # fail-CLOSED: "could not tell" is never "fine"

  echo "OR-DISPATCH-POSTMORTEM role=$ROLE reason=$reason model=$SLUG session=$SESSION task=$TASK latency_s=$LATENCY_S timeout_s=$TIMEOUT_S cwd=$(to_tilde "$DISPATCH_CWD") transcript=$(to_tilde "${pm_transcript:-n/a}") evidence=$(to_tilde "$evidence_dir") records=$(pm_get RECORDS) tool_calls=$(pm_get TOOL_CALLS) reads=$(pm_get READS) bash_calls=$(pm_get BASH) writes=$(pm_get WRITES) think_chars=$(pm_get THINK_CHARS) idle_s=$(pm_get IDLE_S) served_model=$(pm_get LAST_MODEL) verdict_hint=$pm_verdict drill=$DRILL_FIELD" >> "$RECEIPT_FILE"

  echo "openrouter-role-dispatch: POST-MORTEM verdict_hint=$pm_verdict (writes=$(pm_get WRITES) tool_calls=$(pm_get TOOL_CALLS) idle_s=$(pm_get IDLE_S)) transcript=$(to_tilde "${pm_transcript:-n/a}") evidence=$(to_tilde "$evidence_dir")" >&2
  case "$pm_verdict" in
    partial-work)   echo "openrouter-role-dispatch: HINT the subprocess WROTE files before it died — inspect $(to_tilde "$DISPATCH_CWD") (git status) and any PR it may have opened BEFORE re-dispatching; a blind retry duplicates paid work (#1983's class)." >&2 ;;
    research-only)
      # #2046 B2: `writes` only counts Write|Edit|MultiEdit|NotebookEdit tool calls. A role that
      # committed via `git commit`, opened a PR via `gh pr create`, or wrote through a Bash heredoc
      # scores writes=0 and lands here — whose default HINT would then recommend the blind retry the
      # partial-work branch exists to prevent. HINT-text-only change: when bash_calls > 0, append the
      # caveat so the operator checks git/gh state before re-dispatching. The verdict_hint token
      # vocabulary is UNTOUCHED (existing smoke assertions on verdict_hint= stay green).
      bash_n="$(pm_get BASH)"
      if [ -n "$bash_n" ] && [ "$bash_n" -gt 0 ] 2>/dev/null; then
        echo "openrouter-role-dispatch: HINT the subprocess was working but never reached its writing phase — this is a BUDGET shortfall, not a hang (idle_s near 0 confirms it was still active at the kill). Re-dispatch with a larger --timeout, or narrow the brief; do not treat it as a model failure (#2046's class). ...but bash_calls=$bash_n — side effects (git commit / gh pr create / heredoc writes) are NOT counted in writes; check git status and gh pr list in the cwd before re-dispatching." >&2
      else
        echo "openrouter-role-dispatch: HINT the subprocess was working but never reached its writing phase — this is a BUDGET shortfall, not a hang (idle_s near 0 confirms it was still active at the kill). Re-dispatch with a larger --timeout, or narrow the brief; do not treat it as a model failure (#2046's class)." >&2
      fi
      ;;
    zero-tool-calls) echo "openrouter-role-dispatch: HINT the subprocess started but made ZERO tool calls — suspect a refusal, a permission/allowedTools gap, or a context-load stall. Read $(to_tilde "$evidence_dir")/stderr.txt first." >&2 ;;
    no-transcript)  echo "openrouter-role-dispatch: HINT no transcript was produced under $(to_tilde "$PROJECTS_ROOT") for cwd $(to_tilde "$DISPATCH_CWD") — the subprocess most likely never started (provider/auth/network). Read $(to_tilde "$evidence_dir")/stderr.txt first." >&2 ;;
  esac
}

# ── Distinct exit code for timeout/stall vs ordinary failure (GNU `timeout` convention: 124 = killed) ──────
if [ "$CLAUDE_RC" -eq 124 ]; then
  echo "OR-DISPATCH-FALLBACK role=$ROLE reason=timeout model=$SLUG session=n/a task=$TASK latency_s=$LATENCY_S drill=$DRILL_FIELD" >> "$RECEIPT_FILE"
  write_evidence_marker timeout
  dispatch_postmortem timeout
  echo "openrouter-role-dispatch: TIMEOUT after ${TIMEOUT_S}s (role=$ROLE model=$SLUG) — fallback receipt + post-mortem written" >&2
  rm -f "$OUT_FILE" "$OUT_FILE.stderr"
  exit 124
fi

STDOUT_CONTENT="$(cat "$OUT_FILE" 2>/dev/null)"

if [ "$CLAUDE_RC" -ne 0 ] || [ -z "$STDOUT_CONTENT" ]; then
  echo "OR-DISPATCH-FALLBACK role=$ROLE reason=error model=$SLUG session=n/a task=$TASK latency_s=$LATENCY_S drill=$DRILL_FIELD" >> "$RECEIPT_FILE"
  write_evidence_marker error
  dispatch_postmortem error
  echo "openrouter-role-dispatch: dispatch FAILED (rc=$CLAUDE_RC, role=$ROLE, model=$SLUG); stderr follows" >&2
  cat "$OUT_FILE.stderr" >&2 2>/dev/null
  rm -f "$OUT_FILE" "$OUT_FILE.stderr"
  exit 1
fi

# ── Parse the subprocess's OWN JSON output as DATA, never instructions (stdout can carry injected-looking
#    appended text — cairn T1 2026-07-25). NEVER gate on the `result` field: Kimi K3's trailing thinking-only
#    turn leaves it EMPTY on success [MEASURED, #1684 round 3]. ────────────────────────────────────────────
SUBPROC_SESSION="$(printf '%s' "$STDOUT_CONTENT" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(j.session_id||"")}catch(e){}})')"
CACHE_READ="$(printf '%s' "$STDOUT_CONTENT" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);const v=j.usage&&j.usage.cache_read_input_tokens;process.stdout.write((v===undefined||v===null)?"":String(v))}catch(e){}})')"
CACHE_CREATE="$(printf '%s' "$STDOUT_CONTENT" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);const v=j.usage&&j.usage.cache_creation_input_tokens;process.stdout.write((v===undefined||v===null)?"":String(v))}catch(e){}})')"

if [ -z "$SUBPROC_SESSION" ]; then
  echo "OR-DISPATCH-FALLBACK role=$ROLE reason=error model=$SLUG session=n/a task=$TASK latency_s=$LATENCY_S drill=$DRILL_FIELD" >> "$RECEIPT_FILE"
  write_evidence_marker malformed-json
  dispatch_postmortem malformed-json
  echo "openrouter-role-dispatch: subprocess produced no session_id (malformed JSON output) — treated as an ordinary failure" >&2
  rm -f "$OUT_FILE" "$OUT_FILE.stderr"
  exit 1
fi

TRANSCRIPT="$(find "$HOME/.claude/projects" -maxdepth 2 -name "${SUBPROC_SESSION}.jsonl" -print -quit 2>/dev/null)"
TRANSCRIPT="${TRANSCRIPT:-}"

# ── This helper's OWN spawn-side ledger stamp (#1947 D2/M1/M2, re-keyed #2001 D1/D2): dispatch marker +
#    transcript + nonce, keyed by the ORCHESTRATOR's --session value (required + validated above) — the SAME
#    key the role's OWN self-append (prepended into the brief above) and every other role's row in this task
#    are filed under, which is what makes `check --session <orchestrator-sid> --task <id>` able to see all
#    four roles from one file. Composes via overlay-merge with the role's OWN self-append of --artifact (and
#    --verdict for plan-review), in whichever order the two writes land — overlayAppend only overlays keys a
#    given call explicitly provides. The subprocess's own $SUBPROC_SESSION is used ONLY to name the
#    --transcript path above (its own transcript is genuinely named by that id) — it is never a ledger key. ─
if [ -n "$TRANSCRIPT" ]; then
  node "$LEDGER" append --session "$SESSION" --task "$TASK" --role "$ROLE" \
    --dispatch subprocess-openrouter --transcript "$TRANSCRIPT" --nonce "$NONCE" >&2
else
  echo "openrouter-role-dispatch: WARN could not resolve a transcript file for session $SUBPROC_SESSION under $HOME/.claude/projects — the dispatch/transcript/nonce ledger stamp was NOT written; check will correctly refuse this row" >&2
fi

# ── Read back whatever the role's OWN self-append recorded for --artifact/--verdict (may not exist yet if
#    the subprocess did not follow its brief — that is an honest failure this reports, never papers over).
#    Reads the ORCHESTRATOR-session file (#2001 D2) — the same file the spawn-side stamp above just wrote
#    into and the same file the role's own self-append was instructed to target. ─────────────────────────
ledger_field() {   # $1=field name
  local field sess task f
  field="$1"
  sess="$(printf '%s' "$SESSION" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(s.replace(/[^0-9A-Za-z._-]/g,"")))')"
  task="$(printf '%s' "$TASK" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(s.replace(/[^0-9A-Za-z._-]/g,"")))')"
  f="$LEDGER_DIR/$sess/$task.jsonl"
  [ -f "$f" ] || { echo ""; return 0; }
  node -e '
    const fs = require("fs");
    const role = process.argv[1], field = process.argv[2], file = process.argv[3];
    let val = "";
    for (const ln of fs.readFileSync(file, "utf8").split("\n")) {
      if (!ln.trim()) continue;
      try { const j = JSON.parse(ln); if (j && j.role === role && field in j) val = j[field]; } catch (e) { /* skip */ }
    }
    process.stdout.write(val == null ? "" : String(val));
  ' "$ROLE" "$field" "$f"
}
ARTIFACT_VAL="$(ledger_field artifact_path)"
VERDICT_VAL="$(ledger_field verdict)"
[ -z "$ARTIFACT_VAL" ] && ARTIFACT_VAL="MISSING-no-self-append"
[ -z "$VERDICT_VAL" ] && VERDICT_VAL="MISSING"

# ── Provider-side usage AFTER, polled to settlement (the provider usage counter lags ~20-30s; poll to 120s
#    before concluding a cost didn't register — a fast "no change" read is not evidence). ──────────────────
settle_cost() {
  local before="$1" last="" cur i
  for i in $(seq 1 12); do
    cur="$(usage_total)"
    if [ -n "$cur" ] && [ "$cur" != "$before" ]; then
      if [ "$cur" = "$last" ]; then echo "$cur"; return 0; fi
      last="$cur"
    fi
    sleep 10
  done
  echo "$before"   # unsettled after 120s -- report zero delta rather than an unstable number.
}
USAGE_AFTER="$(settle_cost "$USAGE_BEFORE")"
COST_USD="$(node -e 'const b=+process.argv[1]||0,a=+process.argv[2]||0;console.log((a-b).toFixed(9))' "$USAGE_BEFORE" "$USAGE_AFTER")"

# ── Cache evidence (AC-8, D4/V3) — report the REAL fields from this dispatch's own usage object, or the
#    honest `status=unmeasured` literal. Never fabricate a number. ─────────────────────────────────────────
if [ -n "$CACHE_READ" ] && [ -n "$CACHE_CREATE" ]; then
  echo "CACHE-EVIDENCE model=$SLUG cache_hit_tokens=$CACHE_READ cache_miss_tokens=$CACHE_CREATE" >> "$RECEIPT_FILE"
else
  echo "CACHE-EVIDENCE model=$SLUG status=unmeasured" >> "$RECEIPT_FILE"
fi

# executor's artifact_path IS the PR URL its own self-append records; AC-6 additionally names it via its
# own `pr=` field (redundant with `artifact=` by value, but a distinct required grammar token).
PR_FIELD=""
if [ "$ROLE" = "executor" ]; then
  PR_FIELD=" pr=$ARTIFACT_VAL"
fi
RECEIPT_TRANSCRIPT="$(to_tilde "${TRANSCRIPT:-n/a}")"
RECEIPT_ARTIFACT="$(to_tilde "$ARTIFACT_VAL")"
echo "OR-SEAT-SMOKE role=$ROLE model=$SLUG session=$SESSION task=$TASK transcript=$RECEIPT_TRANSCRIPT artifact=$RECEIPT_ARTIFACT verdict=$VERDICT_VAL cost_usd=$COST_USD latency_s=$LATENCY_S source=openrouter-usage gates=standard${PR_FIELD} nonce=$NONCE" >> "$RECEIPT_FILE"

echo "openrouter-role-dispatch: OK role=$ROLE model=$SLUG session=$SESSION transcript=${TRANSCRIPT:-n/a} artifact=$ARTIFACT_VAL cost_usd=$COST_USD latency_s=${LATENCY_S}s nonce=$NONCE"
rm -f "$OUT_FILE" "$OUT_FILE.stderr"
exit 0
