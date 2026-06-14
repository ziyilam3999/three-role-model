#!/usr/bin/env bash
# Smoke for subagent-bg-orphan-gate.sh (#846). Asserts every AC-1..AC-8 case incl. bypass + fail-open forms
# (feedback_gate_smoke_must_cover_bypass_forms). NO `set -e` — a non-block non-zero must not fail-open into a
# spurious pass; we capture every exit code explicitly and tally. Exit 0 = N/N PASS.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"
HOOK="$ROOT/hooks/subagent-bg-orphan-gate.sh"

fail=0; pass=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Build a subagent transcript fixture under <root>/subagents/agent-<id>.jsonl from JSONL lines passed on stdin.
# mk_sub <id>  (reads JSONL lines from stdin) -> echoes the transcript path
mk_sub() {
  local aid="$1" d="$TMP/proj/sess/subagents"
  mkdir -p "$d"
  cat > "$d/agent-$aid.jsonl"
  printf '%s' "$d/agent-$aid.jsonl"
}
# Build a NON-subagent (main session) transcript.
mk_main() {
  local d="$TMP/proj/sessmain"
  mkdir -p "$d"
  cat > "$d/main.jsonl"
  printf '%s' "$d/main.jsonl"
}

# JSONL fragment builders (one JSON object per call, newline-terminated).
j_user()    { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"user",message:{role:"user",content:process.argv[1]}})+"\n")' "$1"; }
j_user_ns() { node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:process.argv[1]}})+"\n")' "$1"; }
# assistant Bash run_in_background tool_use (id=$1)
j_bg_launch() { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",id:process.argv[1],input:{command:"sleep 30",run_in_background:true}}]}})+"\n")' "$1"; }
# tool_result announcing the bg shell id (tool_use_id=$1, shellId=$2)
j_bg_result() { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:process.argv[1],content:"Command running in background with ID: "+process.argv[2]+". Output is being written to: /tmp/"+process.argv[2]+".output"}]}})+"\n")' "$1" "$2"; }
# BashOutput tool_use awaiting shell id $1
j_await() { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"BashOutput",id:"toolu_await",input:{bash_id:process.argv[1]}}]}})+"\n")' "$1"; }
# final assistant text message
j_say() { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"assistant",message:{role:"assistant",content:[{type:"text",text:process.argv[1]}]}})+"\n")' "$1"; }
# foreground (NON-bg) Bash tool_use
j_fg() { node -e 'process.stdout.write(JSON.stringify({isSidechain:true,type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",id:"toolu_fg",input:{command:"echo hi",run_in_background:false}}]}})+"\n")' ; }

# Run the hook with the REAL SubagentStop payload shape (#857): agent_transcript_path = the SUBAGENT transcript
# $1, transcript_path = a SEPARATE main-session file (so the gate must prefer agent_transcript_path). Optional
# extra payload kv via $2 (raw JSON snippet). mode ($3): "main" -> emit the MAIN-session shape instead (NO
# agent_transcript_path; transcript_path = $1 directly), used to assert the main-session no-op. Sets RC + CAP.
run() {
  local tpath="$1" extra="${2:-}" mode="${3:-sub}"
  local main="$TMP/proj/mainsess/main.jsonl"; mkdir -p "$(dirname "$main")"
  printf '{"type":"user","message":{"role":"user","content":"main-session work"}}\n' > "$main"
  local base payload
  if [ "$mode" = "main" ]; then
    base=$(printf '"transcript_path":"%s"' "$tpath")
  else
    base=$(printf '"transcript_path":"%s","agent_transcript_path":"%s","agent_id":"a-%s"' "$main" "$tpath" "$$")
  fi
  if [ -n "$extra" ]; then
    payload=$(printf '{%s,%s}' "$base" "$extra")
  else
    payload=$(printf '{%s}' "$base")
  fi
  CAP=$(printf '%s' "$payload" | bash "$HOOK" 2>&1); RC=$?
}

# ---- AC-1: orphan (bg launched, shell id never awaited) -> exit 2 + stderr names the gate ----
T=$( { j_user "do a heavy capture"; j_bg_launch toolu_a; j_bg_result toolu_a sh111; j_say "All done, returning."; } | mk_sub a1 )
run "$T"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "subagent-bg-orphan" && printf '%s' "$CAP" | grep -q "sh111"; } \
  && ok "AC-1 orphan bg -> exit 2 + names shell sh111" || bad "AC-1 expected exit2+sh111 (rc=$RC out=$CAP)"

# ---- AC-2: no bg job at all -> exit 0 ----
T=$( { j_user "just run a quick check"; j_fg; j_say "Done."; } | mk_sub a2 )
run "$T"
{ [ "$RC" = "0" ]; } && ok "AC-2 no bg job -> exit 0" || bad "AC-2 expected exit0 (rc=$RC out=$CAP)"

# ---- AC-3: bg launched THEN awaited (BashOutput on its shell id) -> exit 0 ----
T=$( { j_user "heavy step"; j_bg_launch toolu_b; j_bg_result toolu_b sh222; j_await sh222; j_say "Awaited and complete."; } | mk_sub a3 )
run "$T"
{ [ "$RC" = "0" ]; } && ok "AC-3 bg awaited (BashOutput) -> exit 0" || bad "AC-3 expected exit0 (rc=$RC out=$CAP)"

# ---- AC-4: bypass token in final message -> exit 0 (even though bg un-awaited) ----
T=$( { j_user "heavy step"; j_bg_launch toolu_c; j_bg_result toolu_c sh333; j_say "Launched render. (bg handed to orchestrator: sh333) — please await it."; } | mk_sub a4 )
run "$T"
{ [ "$RC" = "0" ]; } && ok "AC-4 bypass token -> exit 0" || bad "AC-4 expected exit0 (rc=$RC out=$CAP)"

# ---- AC-5: main-session shape (NO agent_transcript_path; transcript_path not /subagents/, no isSidechain) with
#           an un-awaited bg -> exit 0 (no false block) ----
T=$( { j_user_ns "main session work"; node -e 'process.stdout.write(JSON.stringify({type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",id:"toolu_m",input:{command:"sleep 30",run_in_background:true}}]}})+"\n")'; node -e 'process.stdout.write(JSON.stringify({type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_m",content:"Command running in background with ID: shMAIN. Output is being written to: /tmp/x"}]}})+"\n")'; } | mk_main )
run "$T" "" main
{ [ "$RC" = "0" ]; } && ok "AC-5 main-session bg -> exit 0 (no false block)" || bad "AC-5 expected exit0 (rc=$RC out=$CAP)"

# ---- AC-6: loop guard stop_hook_active:true on an orphan input -> exit 0 ----
T=$( { j_user "heavy"; j_bg_launch toolu_d; j_bg_result toolu_d sh444; j_say "ending"; } | mk_sub a6 )
run "$T" '"stop_hook_active":true'
{ [ "$RC" = "0" ]; } && ok "AC-6 stop_hook_active -> exit 0 (block once)" || bad "AC-6 expected exit0 (rc=$RC out=$CAP)"

# ---- AC-7a: empty stdin -> exit 0 ----
CAP=$(printf '' | bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ]; } && ok "AC-7a empty stdin -> exit 0" || bad "AC-7a expected exit0 (rc=$RC out=$CAP)"
# ---- AC-7b: malformed JSON -> exit 0 ----
CAP=$(printf 'not json {{{' | bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ]; } && ok "AC-7b malformed JSON -> exit 0" || bad "AC-7b expected exit0 (rc=$RC out=$CAP)"
# ---- AC-7c: missing transcript file -> exit 0 ----
run "$TMP/proj/sess/subagents/agent-DOESNOTEXIST.jsonl"
{ [ "$RC" = "0" ]; } && ok "AC-7c missing transcript -> exit 0" || bad "AC-7c expected exit0 (rc=$RC out=$CAP)"

# ---- AC-8: kill-switch SUBAGENT_BG_ORPHAN_OVERRIDE=1 on the AC-1 orphan input -> exit 0 + override log line ----
T=$( { j_user "heavy"; j_bg_launch toolu_e; j_bg_result toolu_e sh555; j_say "ending"; } | mk_sub a8 )
mkdir -p "$TMP/.claude"   # the hook logs to $HOME/.claude/.rule-12-overrides.log
CAP=$(printf '{"transcript_path":"%s/main.jsonl","agent_transcript_path":"%s","agent_id":"a8"}' "$TMP" "$T" | HOME="$TMP" SUBAGENT_BG_ORPHAN_OVERRIDE=1 bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "0" ] && [ -f "$TMP/.claude/.rule-12-overrides.log" ] && grep -q "SUBAGENT_BG_ORPHAN_OVERRIDE=1" "$TMP/.claude/.rule-12-overrides.log"; } \
  && ok "AC-8 kill-switch -> exit 0 + override logged" || bad "AC-8 expected exit0+log (rc=$RC out=$CAP log=$(cat "$TMP/.claude/.rule-12-overrides.log" 2>/dev/null))"

# ---- AC-9: isSidechain-only subagent detection (path NOT /subagents/ but entries isSidechain:true) orphan -> exit 2 ----
SD="$TMP/proj/sideways"; mkdir -p "$SD"
{ j_user "heavy"; j_bg_launch toolu_f; j_bg_result toolu_f sh666; j_say "ending"; } > "$SD/weird.jsonl"
run "$SD/weird.jsonl"
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "sh666"; } \
  && ok "AC-9 isSidechain-only detection -> exit 2" || bad "AC-9 expected exit2 (rc=$RC out=$CAP)"

# ---- AC-10: #857 REGRESSION. BOTH fields present (real shape): agent_transcript_path -> the ORPHAN subagent
#            transcript; transcript_path -> a SEPARATE main file with NO bg job. The gate MUST read
#            agent_transcript_path and BLOCK (exit 2, naming the orphan shell). This FAILS against the pre-#857
#            transcript_path-only code (which would read the clean main file -> no orphan -> exit 0) and PASSES
#            after the fix. ----
SUBO=$( { j_user "heavy capture"; j_bg_launch toolu_r; j_bg_result toolu_r shR10; j_say "All done."; } | mk_sub a10 )
MAINC="$TMP/proj/mainclean/main.jsonl"; mkdir -p "$(dirname "$MAINC")"
j_user_ns "just a main-session message, no bg job" > "$MAINC"
CAP=$(printf '{"transcript_path":"%s","agent_transcript_path":"%s","agent_id":"a10"}' "$MAINC" "$SUBO" | bash "$HOOK" 2>&1); RC=$?
{ [ "$RC" = "2" ] && printf '%s' "$CAP" | grep -q "shR10"; } \
  && ok "AC-10 real shape: reads agent_transcript_path orphan (shR10) not clean transcript_path -> exit 2" \
  || bad "AC-10 real-shape regression broken (rc=$RC out=$CAP)"

echo "----"
if [ "$fail" = "0" ]; then echo "$pass/$pass PASS"; exit 0; else echo "$pass passed, $fail FAILED"; exit 1; fi
