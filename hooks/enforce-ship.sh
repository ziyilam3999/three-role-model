#!/bin/bash
# Hook: Enforce /ship before merging PRs
# Blocks `gh pr merge` unless /ship has verified the PR (marker file exists).
# Fast path: non-merge commands exit immediately without spawning node.
# Carve-out: PRs whose baseRefName is not master/main are exempt — supports the
# integration-branch delivery model where sub-PRs land into a long-lived feature
# branch and only the final integration→master merge needs the marker (#514).
set -e

INPUT=$(cat)

# Fast path: check if this is a gh pr merge command using bash string matching
# Avoid spawning node for the 99% of Bash calls that aren't merges.
#
# Grep is a PRE-FILTER — the authoritative gate is the bounded `gh pr merge`
# regex run after the node parse extracts the real command (#461). The fast-path must be
# strictly broader than a real merge (no false-negatives, which would skip the
# security check) and is allowed to false-positive (extra node spawn, same
# correct final verdict). The earlier `"command".*gh pr merge` regex added
# false positives when `gh pr merge` appeared in a `body` field on the same
# JSON line — benign, but same hazard class as #356/#357 (#392). The simpler
# `gh pr merge` pattern cannot false-negative because every real merge
# contains the sequence in its command.
if ! echo "$INPUT" | grep -qE 'gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge'; then
  exit 0
fi

# Parse the command, cwd, and any leading 'cd <target> &&' prefix(es) from JSON using Node.js.
# The targetCwd field lets the marker lookup locate the repo being shipped when the user's
# session cwd differs from the target (e.g. shipping ai-brain from an agent-working-memory
# wrapper session). Falls back to empty string when the command has no cd prefix.
#
# Output shape: three lines (one field per line) — command, cwd, targetCwd. Newline-separated
# rather than tab-separated because a tab can legally appear inside `cmd` (e.g. a --body flag
# holding tab-indented content) and would corrupt a tab-parsed read. Any newline inside cmd is
# stripped so the three-line invariant holds for the bash reader downstream (#356).
#
# For chained `cd A && cd B && ...` prefixes, we loop-strip each segment and join them: a
# relative later segment joins onto the running base with `/`; an absolute later segment
# (starts with `/` or matches a Windows/MSYS drive prefix) replaces the base. Path-join is
# hand-rolled — AC-8 keeps this hook dependency-free (no module imports) (#357).
PARSED=$(echo "$INPUT" | node -e "
let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(d);
    const cmd = j.tool_input?.command || '';
    const cwd = j.cwd || '';
    const cdRe = /^\s*cd\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s&;]+))\s*&&\s*/;
    let rest = cmd;
    let targetCwd = '';
    while (true) {
      const m = rest.match(cdRe);
      if (!m) break;
      let seg = m[1] || m[2] || m[3] || '';
      if (!seg) break;
      // Tilde-expansion: bash does NOT tilde-expand inside the double-quoted
      // 'cd \"\${TARGET_CWD:-\$CWD}\"' that runs the marker lookup later, so
      // the captured segment must already be absolute. Resolve a leading
      // '~' or '~/...' to process.env.HOME here, before the isAbs check —
      // the resolved path begins with '/' (POSIX) or a drive letter (after
      // MSYS conversion of \$HOME) and the existing isAbs regex then treats
      // it as absolute, so chained-cd composition keeps working unchanged.
      // Without this fix, 'cd ~/foo && gh pr merge ...' captured TARGET_CWD
      // as the literal '~/foo', the later cd failed silently, BASE_REF was
      // empty and the integration-branch carve-out was bypassed, blocking
      // legitimate merges (#586).
      if (seg === '~') {
        seg = process.env.HOME || seg;
      } else if (seg.startsWith('~/')) {
        seg = (process.env.HOME || '~') + '/' + seg.slice(2);
      }
      const isAbs = /^\//.test(seg) || /^[A-Za-z]:[\\\\\/]/.test(seg);
      if (!targetCwd || isAbs) {
        targetCwd = seg;
      } else {
        targetCwd = targetCwd.replace(/\/+$/, '') + '/' + seg;
      }
      rest = rest.slice(m[0].length);
    }
    // Normalize . and .. segments so 'cd /a && cd .. && …' yields '/' instead
    // of '/a/..'. Hand-rolled to stay dependency-free — AC-8 bans imports
    // (both require syntax and ESM), which rules out path.posix.resolve.
    // Preserves leading '/' or drive prefix (C:/); collapses '.' entirely;
    // pops on '..'; pops nothing past root (matches path.posix.resolve
    // semantics) (#390).
    // A bare-relative cd prefix ('cd ..' or 'cd .' alone) normalizes to an
    // empty targetCwd here — the downstream CWD fallback handles the marker
    // lookup correctly in that case (#462).
    // Windows UNC paths ('\\\\server\\share') are NOT preserved — the drive
    // regex above recognizes 'C:/' but not the leading double-backslash, so
    // UNC shape is lost if it ever appears. Tracked; not observed in Claude
    // Code tool_input in practice (#463).
    if (targetCwd) {
      let lead = '';
      const drive = targetCwd.match(/^([A-Za-z]:)[\\\\\/](.*)$/);
      if (drive) { lead = drive[1] + '/'; targetCwd = drive[2]; }
      else if (targetCwd.startsWith('/')) { lead = '/'; targetCwd = targetCwd.slice(1); }
      const out = [];
      for (const s of targetCwd.split(/[/\\\\]/)) {
        if (!s || s === '.') continue;
        if (s === '..') { if (out.length) out.pop(); continue; }
        out.push(s);
      }
      targetCwd = lead + out.join('/');
    }
    const cmdSafe = cmd.replace(/\r?\n/g, ' ');
    console.log(cmdSafe);
    console.log(cwd);
    console.log(targetCwd);
  } catch { console.log(''); console.log(''); console.log(''); }
})")

# Read three fields, one per line. Newline separation keeps inner tabs in COMMAND intact (#356).
# The `|| true` on each read tolerates an empty trailing field: command substitution strips
# trailing newlines from $PARSED, so a final empty field (no cd prefix, empty targetCwd)
# leaves the third `read` at EOF with a zero-length buffer; read returns 1 and under `set -e`
# the hook would abort. The short-read still assigns an empty string to the variable, which
# is the intended semantic, so we swallow the non-zero.
COMMAND=""; CWD=""; TARGET_CWD=""
{ IFS= read -r COMMAND || true; IFS= read -r CWD || true; IFS= read -r TARGET_CWD || true; } <<< "$PARSED"

# Confirm this is actually a gh pr merge invocation (not just a grep false positive from
# PR body text or commit messages containing the string). Accept two shapes:
#   1. bare: `gh pr merge …` at the start of the command
#   2. wrapper: `cd <path> && gh pr merge …` (or any `&&`-prefixed invocation)
if ! echo "$COMMAND" | grep -qE '(^|&&[[:space:]]*)[[:space:]]*gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge'; then
  exit 0
fi

# Extract PR number from command (e.g., "gh pr merge 123 --squash")
PR_NUMBER=$(echo "$COMMAND" | grep -oE 'gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge[[:space:]][[:space:]]*[0-9]+' | grep -oE '[0-9]+')

# If no PR number in command, resolve from current branch (gh pr merge --squash uses branch PR)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(cd "$CWD" && gh pr view --json number -q .number 2>/dev/null)
fi

# If still no PR number, block -- can't verify without one
if [ -z "$PR_NUMBER" ]; then
  echo "BLOCKED: Could not determine PR number. Include the PR number in the merge command or ensure a PR exists for the current branch." >&2
  exit 2
fi

# Integration-branch carve-out: PRs whose base is not master/main are exempt from
# the marker requirement. Supports the integration-branch delivery model where
# multiple sub-PRs merge into a long-lived feature branch and a single final
# /ship cuts the release from that branch to master (master-bound merges still
# require the marker — only the inner sub-branch → integration-branch step
# is exempted). Graceful degradation: if `gh pr view` fails (network, auth,
# PR not found) the empty BASE_REF falls through to the existing marker check,
# preserving today's fail-closed behavior on the dangerous path (#514).
# `|| true` swallows the substitution's exit code so `set -e` (top of file) does
# not propagate when `gh` fails (auth/network/PR-not-found OR cwd-isn't-a-repo).
# Without it, BASE_REF="" would still be assigned correctly but the failed
# substitution would exit the hook with code 1 — silently breaking ALL pre-existing
# AC paths that hit a non-gh-resolvable cwd. Caught by the new acceptance test
# AC-4 (gh-fails graceful-degradation) and the hardening regression suite.
BASE_REF=$(cd "${TARGET_CWD:-$CWD}" && gh pr view "$PR_NUMBER" --json baseRefName -q .baseRefName 2>/dev/null || true)
if [ -n "$BASE_REF" ] && [ "$BASE_REF" != "master" ] && [ "$BASE_REF" != "main" ]; then
  exit 0
fi

# Check for verification marker at the target repo first (the repo being shipped),
# then fall back to the session cwd for non-wrapper workflows and hand-duplicated markers.
# Either hit is enough — the marker only needs to exist once per shipped PR.
if [ -n "$TARGET_CWD" ] && [ -f "$TARGET_CWD/.ai-workspace/ship-verified-$PR_NUMBER" ]; then
  exit 0
fi
if [ -f "$CWD/.ai-workspace/ship-verified-$PR_NUMBER" ]; then
  exit 0
fi

echo "BLOCKED: Run /ship first. Self-review must pass before merging PR #$PR_NUMBER." >&2
echo "The enforce-ship hook requires /ship to verify the PR before allowing gh pr merge." >&2

# Name the manual-merge escape explicitly (#767). /ship writes the marker for you, but the
# autonomous-pipeline path merges manually AFTER a passing stateless review and needs its OWN
# distinct marker `.ai-workspace/ship-verified-<PR>` (the sibling enforce-review-or-lfah gate's
# tmp/ship-review-<PR>.md does NOT satisfy enforce-ship). Without this line the only recovery
# hint was the #683 block below, which fires solely when the merge ALSO chained a marker write —
# a plain `gh pr merge <PR>` got no marker guidance at all. Print the one-command recovery always.
echo "" >&2
echo "If /ship passed already, re-run the merge — it writes the marker for you." >&2
echo "For a manual post-review merge, write the PASS marker first (as its own command, repo-qualified" >&2
echo "path so a wrapper-session cwd still lands it in the shipped repo), then merge:" >&2
echo "  echo \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > <repo>/.ai-workspace/ship-verified-$PR_NUMBER" >&2
echo "  gh pr merge $PR_NUMBER --squash" >&2

# Heal a recurring footgun (#683): a marker WRITE chained with the merge in ONE command
# (e.g. `echo ... > <repo>/.ai-workspace/ship-verified-<PR> && gh pr merge <PR>`) is blocked ATOMICALLY here
# at PreToolUse, so the write to the LEFT of && never runs -> the marker stays absent and this block fires.
# Detect that shape and say so, so the fix (write the marker as a SEPARATE command first) is obvious.
if printf '%s' "$COMMAND" | grep -qE '>[[:space:]]*[^|&;]*ship-verified'; then
  echo "" >&2
  echo "NOTE: this command ALSO tried to WRITE the ship-verified marker. enforce-ship is a PreToolUse hook," >&2
  echo "so it blocked the WHOLE command atomically -> the marker write (left of &&) never ran. Write the" >&2
  echo "marker as a SEPARATE command FIRST (absolute repo path), THEN re-run the merge:" >&2
  echo "  echo verified > <repo>/.ai-workspace/ship-verified-$PR_NUMBER" >&2
  echo "  gh pr merge $PR_NUMBER --squash" >&2
fi
exit 2
