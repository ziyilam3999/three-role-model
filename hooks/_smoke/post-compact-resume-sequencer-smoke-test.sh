#!/usr/bin/env bash
# Smoke for post-compact-resume-sequencer.sh (SessionStart:compact|clear + UserPromptSubmit backstop).
# Portability + both-ends fire smoke (AC12): emit cases (primary; prompt+resume) AND no-emit cases (empty
# stdin, non-resume prompt with sentinel intact, override). Uses POST_COMPACT_SESS_DIR=$(mktemp -d) so the
# real $HOME is NEVER touched. NO `set -e` — every exit code is captured + tallied. Exit 0 = N/N PASS.
# Invoked with CLAUDE_PLUGIN_ROOT set (CI provides it).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/post-compact-resume-sequencer.sh"

SESS_DIR="$(mktemp -d)"; trap 'rm -rf "$SESS_DIR"' EXIT
export POST_COMPACT_SESS_DIR="$SESS_DIR"

fail=0; pass=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# run <mode-arg> <json-payload> -> sets RC + CAP (stdout only; stderr discarded). mode-arg "" = primary.
run() {
  CAP=$(printf '%s' "$2" | bash "$HOOK" $1 2>/dev/null); RC=$?
}

# --- AC12.1: --prompt-mode, empty stdin, no sentinel -> exit 0, no output ---
run "--prompt-mode" ""
{ [ "$RC" = "0" ] && [ -z "$CAP" ]; } \
  && ok "prompt-mode empty stdin, no sentinel -> exit 0 silent" || bad "expected exit0/silent (rc=$RC out=$CAP)"

# --- AC12.2: primary mode {"session_id":"smoke-1"} -> exit 0, stdout has protocol, sentinel planted ---
run "" '{"session_id":"smoke-1"}'
{ [ "$RC" = "0" ] && printf '%s' "$CAP" | grep -q "post-compact resume protocol" && [ -f "$SESS_DIR/smoke-1.compact" ]; } \
  && ok "primary -> exit 0 + emits + plants smoke-1.compact" || bad "primary expected emit+plant (rc=$RC out=$CAP sent=$(ls "$SESS_DIR"))"

# --- AC12.3: --prompt-mode resume intent, fresh sentinel -> emit once, then sentinel consumed ---
date +%s > "$SESS_DIR/smoke-1.compact"   # fresh plant
run "--prompt-mode" '{"session_id":"smoke-1","prompt":"resume"}'
{ [ "$RC" = "0" ] && printf '%s' "$CAP" | grep -q "post-compact resume protocol" && [ ! -f "$SESS_DIR/smoke-1.compact" ]; } \
  && ok "prompt-mode resume fresh -> emit once + sentinel consumed" || bad "expected emit+consume (rc=$RC out=$CAP sent_exists=$([ -f "$SESS_DIR/smoke-1.compact" ] && echo yes || echo no))"

# --- AC12.4: --prompt-mode non-resume prompt, fresh sentinel -> NO emit, sentinel left intact ---
date +%s > "$SESS_DIR/smoke-1.compact"   # fresh plant
run "--prompt-mode" '{"session_id":"smoke-1","prompt":"unrelated chatter"}'
{ [ "$RC" = "0" ] && [ -z "$CAP" ] && [ -f "$SESS_DIR/smoke-1.compact" ]; } \
  && ok "prompt-mode non-resume -> no emit + sentinel intact" || bad "expected no-emit+intact (rc=$RC out=$CAP sent_exists=$([ -f "$SESS_DIR/smoke-1.compact" ] && echo yes || echo no))"

# --- AC12.5: override -> exit 0, no emit (even in primary mode with a session_id) ---
CAP=$(printf '%s' '{"session_id":"smoke-2"}' | POST_COMPACT_RESUME_SEQUENCER_OVERRIDE=1 bash "$HOOK" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && [ -z "$CAP" ] && [ ! -f "$SESS_DIR/smoke-2.compact" ]; } \
  && ok "override -> exit 0, no emit, no plant" || bad "override expected exit0/silent (rc=$RC out=$CAP)"

echo "----"
if [ "$fail" = "0" ]; then echo "$pass/$pass PASS"; exit 0; else echo "$pass passed, $fail FAILED"; exit 1; fi
