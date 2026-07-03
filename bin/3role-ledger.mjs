#!/usr/bin/env node
// bin/3role-ledger.mjs — role-LEDGER helper. Bundled in the plugin under bin/; hooks resolve it via
// "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" (with a repo-relative ../bin fallback).
//
// A tiny CLI that records WHICH 3-role roles actually ran for a task and verifies them against the
// forgery-resistant signal the harness already produces: one transcript file per real subagent spawn
// (`~/.claude/projects/*/<session>/subagents/agent-<agentId>.jsonl`). The orchestrator cannot create
// that file without actually spawning, so binding a per-task role ledger to those files turns "I claim
// the planner ran" into a checkable boolean — the leg #850 needed.
//
// FLAT file (NOT under hooks/lib/) because setup.sh only symlinks flat hook files (a subdir is skipped);
// the gate finds it as a sibling via `dirname "${BASH_SOURCE[0]}"` whether run from the repo or the
// ~/.claude/hooks/ symlink.
//
// Subcommands:
//   append --session S --task T --role R [--agent A] [--artifact P] [--skip-reason "..."] [--oracle P]
//                                        [--verdict V] [--self-authored]
//     Writes one JSONL line to <ledger-dir>/<S>/<T>.jsonl. Idempotent PER ROLE — re-appending the same
//     role UPDATES the line (drops the prior one), never duplicates. A role agent self-recording its OWN
//     line passes --artifact (and --verdict for review-roles) with NO --agent; the SubagentStop hook later
//     overlay-merges the harness-captured --agent (#855) and stamps --self-authored (#1100 item 3).
//   check --session S --task T [--require-provenance]
//     Exit 0 (+ "OK ...") iff all four required roles (planner, plan-review, executor, execution-review)
//     are present AND satisfied; otherwise exit 2 (+ "BLOCK: <reason>"). A role is satisfied by EITHER
//     (a) an agentId that resolves to a real subagent transcript AND a well-shaped artifact, OR (b) an
//     explicit, SPECIFIC inline-skip reason. execution-review is NEVER inline-skippable — it needs a real
//     reviewer agentId OR a test-oracle path that exists with a PASS/verdict token. A real-spawn role line
//     lacking the self_authored stamp is SURFACED as a "PROVENANCE:" flag (still exit 0); --require-provenance
//     promotes a missing stamp to a BLOCK.
//   resolve-agent --session S --task T --role R
//     Prints the agentId (basename of the `agent-<id>.jsonl` transcript) of the NEWEST-mtime subagent
//     transcript under <projects-root>/*/<S>/subagents/ whose content carries the literal spawn tag
//     `3ROLE_TASK:<T> ROLE:<R>` (#860). Exit 0 with the agentId on stdout when a match exists; prints
//     nothing + exits non-zero when no transcript carries the tag. Newest-mtime (not first-match) because a
//     tag can repeat across transcripts (an earlier probe/retry reusing a role tag), so the most recent
//     write is the real role spawn — a bare first-match/head -1 can grab a stale probe.
//   resolve-artifact --session S --task T --role R                  (#1303)
//     Prints the existence-checked ABSOLUTE artifact_path for ONE role of ONE task on stdout, then exit 0.
//     Reuses ledgerFile() + resolveArtifact() (the SAME parse cmdCheck/cmdInherit use — last line per role
//     wins). Exits NON-ZERO (printing nothing) on EVERY "no usable artifact" branch: no ledger file, no line
//     for the role, an absent/empty/whitespace artifact_path (e.g. an inline-skip line), or a dangling path
//     that does not resolve on disk. The instrumentation gate calls this to resolve the planner / plan-review
//     docs (cairn legs 4a/4b) LEDGER-FIRST — the non-zero exit is the "ledger has no usable artifact_path ->
//     fall back to the convention dir" contract (#1266 wrong-dir + stale-newest fix). A `verdict:` field on
//     the line is ignored; only artifact_path is read.
//   heartbeat --session S --task T                                 (#1350)
//     LEADING-EDGE lane liveness: bump the <task>.jsonl file MTIME to ~now so agent-kanban's swimlane
//     liveness counter (which stats <ledgerDir>/<session>/<task>.jsonl mtime via ledgerMtimeByTaskId →
//     updatedAt = max(mtimeMs, ledgerMtimeMs) → computeActiveIds secondary-window test) sees the lane as
//     LIVE the instant a role is SPAWNED — not only when a role COMPLETES (the trailing-edge append).
//     Writes NO JSONL line: if <task>.jsonl exists it is utimes-touched in place (content untouched); if
//     absent it is created as a ZERO-byte file. Because no line is written there is nothing for
//     overlayAppend to merge/drop/clobber, so a subsequent real append/check/resolve-artifact reads the
//     file byte-correctly — AC-4 (no overlay/close corruption) is true BY CONSTRUCTION. ALWAYS exits 0
//     (fail-open) — a heartbeat error must NEVER wedge the spawn it instruments.
//   resolve-role-model --role R [--with-effort]                    (#1448)
//     Prints the configured model TIER for role R (opus|sonnet|haiku|fable) from config/cc-roles.env — the
//     single command the orchestrator and both model hooks consume. Fail-SAFE: a missing/malformed config OR
//     an invalid per-role value => opus (never fail-open-to-cheap). --with-effort prints "<model> <effort>".
//     Lints the config on read (loud INVALID-MODEL / Fable stderr warnings). Always exits 0.
//   check --session S --task T --enforce-role-models               (#1448)
//     The --enforce-role-models flag (opt-in; only the instrumentation gate passes it) adds a per-role
//     MODEL-POLICY leg: for each role that resolves to a real transcript, compare its ACTUAL model
//     (message.model, forgery-resistant) to cc-roles.env's tier; a mismatch => exit 2. No config => skip
//     (fail-safe). Fable->Opus silent reroute is OK. Kill-switch CC_ROLE_MODEL_GATE_OFF=1.
//   inherit-plan-review --session S --task T --parent P            (#881)
//     Inherit the PARENT (P) planner + plan-review ledger lines onto the LEG (T) — but ONLY if the parent
//     genuinely has a real, TRANSCRIPT-BACKED planner AND plan-review (same checkRole `check` uses; an
//     inline-skipped parent entry is rejected because the session-bound carve-out does not transfer to a leg).
//     Verify-then-write, fail-closed: a missing / forged / inline-skipped parent review prints
//     "BLOCK: cannot inherit ..." to stderr, exits 3, and writes NOTHING. On success appends both parent
//     entries (verbatim agentId + artifact_path, plus `inherited_from: P`) through the overlay-merge path so a
//     later real per-leg review overwrites cleanly; prints "OK inherited ..." and exits 0.
//
// Env overrides (mirror DOGFOOD_GATE_STORE so a smoke can point at a fixture tree):
//   THREE_ROLE_LEDGER_DIR    (default ~/.claude/3role-ledger)
//   THREE_ROLE_PROJECTS_ROOT (default ~/.claude/projects)
//   CC_ROLES_ENV             (#1448) — explicit per-role-model config path. When SET it is AUTHORITATIVE +
//                            TERMINAL (never falls through to ~/.config / plugin / repo defaults), so a smoke
//                            sets CC_ROLES_ENV=/nonexistent to simulate "no config" (=> every role opus).
//   CC_ROLE_MODEL_GATE_OFF=1 (#1448) — skip the --enforce-role-models MODEL-POLICY leg (feature kill-switch).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const LEDGER_DIR = process.env.THREE_ROLE_LEDGER_DIR || path.join(HOME, '.claude', '3role-ledger');
const PROJECTS_ROOT = process.env.THREE_ROLE_PROJECTS_ROOT || path.join(HOME, '.claude', 'projects');

const REQUIRED_ROLES = ['planner', 'plan-review', 'executor', 'execution-review'];
// A plan is recognized by a MARKDOWN HEADING (2-4 `#`) naming an acceptance-criteria / ELI5 section.
// Anchored to a heading-line start (`^#{2,4}` + `m` flag) so prose that merely contains the word
// "acceptance" ("we await acceptance from QA") can NEVER match — only a real heading does. Accepts the
// natural variants planners actually write: `## ELI5`, `### Binary AC`, `## Binary acceptance criteria`,
// `### Acceptance criteria`, `## Acceptance`, `## AC`. The `ac\b` boundary keeps the second arm from
// half-matching the "Ac" of "Acceptance" — it falls through to the `acceptance` arm (#855).
const PLAN_RE = /^#{2,4}[ \t]*(eli5|(binary[ \t]+)?ac\b|(binary[ \t]+)?acceptance([ \t]+criteria)?\b)/im;
const VERDICT_RE = /(PASS|FAIL|APPROVE|verdict|##\s*Review)/i;
// Non-specific / placeholder skip reasons that are NOT acceptable (the carve-out is for genuinely
// inseparable-from-session-state work; "ran it inline myself" is not a valid skip — documented in the
// block message). Keep permissive: only empty/whitespace + a tiny denylist of obvious non-reasons.
const NONSPECIFIC_RE = /^(n\/?a|skip(ped)?|none|null|tbd|inline|-+|\.+)$/i;

function sanitize(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
function ledgerFile(session, task) {
  return path.join(LEDGER_DIR, sanitize(session), sanitize(task) + '.jsonl');
}
function fileExists(p) { try { return fs.statSync(p).isFile(); } catch (e) { return false; } }
function fileHas(p, re) { try { return re.test(fs.readFileSync(p, 'utf8')); } catch (e) { return false; } }

// ── #1448 per-role MODEL POLICY (config resolution + transcript-model read + lint) ─────────────────────
// The interactive 4-role chain staffs every seat with Opus by default (a spawn today carries model=(none), so
// each role inherits the session model). config/cc-roles.env maps each role -> a model TIER; this block reads
// it (fail-SAFE to opus), reads the FORGERY-RESISTANT actual model from the role's subagent transcript
// (message.model), and lints the config. MODEL is the only mechanically-enforced dimension (effort is not
// recorded in the transcript). See .ai-workspace/plans/2026-07-03-1448-per-role-model-policy.md.
const ROLE_MODELS = ['opus', 'sonnet', 'haiku', 'fable'];

// Ledger role -> config-key STEM (hyphen->underscore, upper): plan-review -> PLAN_REVIEW, execution-review ->
// EXECUTION_REVIEW, executor -> EXECUTOR. ORCHESTRATOR has a policy/lint entry but is NOT transcript-enforced.
function roleKeyStem(role) { return String(role == null ? '' : role).toUpperCase().replace(/-/g, '_'); }

// Resolve the cc-roles.env config file path. First hit wins across the chain, with ONE override rule:
//   CC_ROLES_ENV, when SET, is AUTHORITATIVE + TERMINAL — it selects EXACTLY that file and NEVER falls through
//   to the machine/plugin/repo defaults. So a smoke simulates "no config" with CC_ROLES_ENV=/nonexistent (or
//   /dev/null) and gets the fail-safe all-opus path without leaking the repo's own config/cc-roles.env
//   (AC-3 / green-gate: CC_ROLES_ENV=/dev/null => opus for every role).
//   Unset CC_ROLES_ENV: ~/.config/cc-roles.env -> ${CLAUDE_PLUGIN_ROOT}/config/cc-roles.env -> the
//   realpath-resolved repo config -> none => '' (=> every role opus).
// The fs.realpathSync step is LOAD-BEARING (defect-1b): setup.sh installs THIS helper as a SYMLINK at
// ~/.claude/hooks/3role-ledger.mjs -> the repo file. A naive import.meta.url join resolves ../config to
// ~/.claude/config (does NOT exist) -> silent all-opus on every real invocation while passing every
// worktree-run smoke. realpathSync walks THROUGH the symlink to the real repo file FIRST, so ../config lands
// in the repo. AC-4 exercises this via the installed symlink from a cwd outside the repo.
function resolveConfigPath() {
  if ('CC_ROLES_ENV' in process.env) {
    const p = process.env.CC_ROLES_ENV;
    return (p && fileExists(p)) ? p : '';
  }
  const cands = [path.join(HOME, '.config', 'cc-roles.env')];
  if (process.env.CLAUDE_PLUGIN_ROOT) cands.push(path.join(process.env.CLAUDE_PLUGIN_ROOT, 'config', 'cc-roles.env'));
  let selfDir;
  try { selfDir = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))); }
  catch (e) { selfDir = path.dirname(fileURLToPath(import.meta.url)); }
  cands.push(path.join(selfDir, '..', 'config', 'cc-roles.env'));
  for (const c of cands) { if (c && fileExists(c)) return c; }
  return '';
}

// Parse a shell-env KEY=VALUE file into a plain object (# comments + blanks dropped; optional surrounding
// quotes stripped). Never throws — an unreadable file returns {}.
function parseEnvFile(filePath) {
  const out = {};
  let raw;
  try { raw = fs.readFileSync(filePath, 'utf8'); } catch (e) { return out; }
  for (const line of raw.split('\n')) {
    const s = line.trim();
    if (!s || s.charAt(0) === '#') continue;
    const eq = s.indexOf('=');
    if (eq < 0) continue;
    const k = s.slice(0, eq).trim();
    let v = s.slice(eq + 1).trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1);
    if (k) out[k] = v;
  }
  return out;
}

// Load the config ONCE per command invocation. { found, cfg, configPath }. found=false => no config resolved.
function loadRoleConfig() {
  const configPath = resolveConfigPath();
  if (!configPath) return { found: false, cfg: {}, configPath: '' };
  return { found: true, cfg: parseEnvFile(configPath), configPath };
}

// Resolve a role's model TIER from an already-parsed cfg, fail-SAFE to opus (missing OR invalid => opus).
function roleModelFromCfg(cfg, role) {
  const raw = cfg['CC_ROLE_' + roleKeyStem(role) + '_MODEL'];
  return ROLE_MODELS.includes(raw) ? raw : 'opus';
}
function roleEffortFromCfg(cfg, role) {
  const v = cfg['CC_ROLE_' + roleKeyStem(role) + '_EFFORT'];
  return v == null ? '' : String(v);
}

// Config LINT (defect-3 + Fable guards) — emits stderr warnings; the pass/fail is unaffected (the gate's
// `expected` fails SAFE to opus, so a garbage value collapses to opus at the gate and CANNOT be caught there —
// VISIBILITY is entirely the lint's job). Fires on EVERY config read (every resolve-role-model + every enforce
// check + every spawn-hook call). Call ONCE per invocation (loud, not 5x). THREE warn classes:
//   1. INVALID-MODEL — a present *_MODEL whose value is not a known tier (typo / empty). The silent-overpay guard.
//   2. FABLE-ON-ORCHESTRATOR — the always-on seat pinned to fable (never-pin; refuse/warn).
//   3. FABLE-COST-CLIFF — any VALID *_MODEL=fable (post-July-7 subsidy-cliff cost warning).
function lintRoleConfig(cfg) {
  for (const k of Object.keys(cfg)) {
    const m = k.match(/^CC_ROLE_(.+)_MODEL$/);
    if (!m) continue;
    const val = cfg[k];
    if (!ROLE_MODELS.includes(val)) {
      process.stderr.write('INVALID-MODEL cc-roles.env: ' + k + '="' + val + '" is not a known tier ' +
        '(opus|sonnet|haiku|fable) — falling back to opus (you are paying OPUS rates while thinking you set "' +
        val + '").\n');
      continue;   // an invalid value is not also a fable warning.
    }
    if (val === 'fable') {
      if (m[1] === 'ORCHESTRATOR') {
        process.stderr.write('FABLE-ON-ORCHESTRATOR cc-roles.env: ' + k + '=fable — refusing to pin the ' +
          'always-on orchestrator seat to Fable (2x Opus, high-frequency; burns the subsidised bar fast). ' +
          'The orchestrator is documented opus-only.\n');
      }
      process.stderr.write('FABLE-COST-CLIFF cc-roles.env: ' + k + '=fable — Fable\'s subsidised usage bar ' +
        'expires ~July 7-8; after that a Fable-pinned seat bills out-of-pocket (~2x Opus). Use Fable only for ' +
        'the hardest one-off plans, never a standing seat.\n');
    }
  }
}

// claude model-id -> our tier. Unknown/absent => '' (can't-tell => the caller fails OPEN for that role).
function modelIdToTier(modelId) {
  const s = String(modelId == null ? '' : modelId).toLowerCase();
  if (/^claude-opus-/.test(s)) return 'opus';
  if (/^claude-sonnet-/.test(s)) return 'sonnet';
  if (/^claude-haiku-/.test(s)) return 'haiku';
  if (/^claude-fable-/.test(s)) return 'fable';
  return '';
}

// FORGERY-RESISTANT actual-model read: the LAST `type:"assistant"` line's message.model in the role's subagent
// transcript (the model that produced the closing tokens — the harness writes it, the orchestrator cannot forge
// it). Same glob as agentResolves(). Returns the model-id string or '' when no assistant model line exists
// (=> can't-tell => caller fails OPEN for that role — mirrors the gate's existing ERR->allow residual).
function transcriptModel(session, agentId) {
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  if (!aid) return '';
  const sess = sanitize(session);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return ''; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    let content;
    try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
    let last = '';
    for (const ln of content.split('\n')) {
      const s = ln.trim();
      if (!s) continue;
      let j; try { j = JSON.parse(s); } catch (e) { continue; }
      if (j && j.type === 'assistant' && j.message && typeof j.message.model === 'string' && j.message.model) {
        last = j.message.model;
      }
    }
    if (last) return last;
  }
  return '';
}

// Parse `--key value` flags. An empty next-arg ("") IS consumed (so `--skip-reason ""` records an
// explicit empty reason → caught as a non-specific skip). A flag with no following value → "".
function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) { o[key] = ''; }
      else { o[key] = next; i++; }
    }
  }
  return o;
}

// Phase 2 forgery-close: glob PROJECTS_ROOT/*/<session>/subagents/agent-<agentId>.jsonl ; ≥1 hit required.
function agentResolves(session, agentId) {
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  if (!aid) return false;
  const sess = sanitize(session);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return false; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    if (fileExists(f)) return true;
  }
  return false;
}

// #860: resolve the agentId of the NEWEST-mtime subagent transcript carrying the exact spawn tag
// `3ROLE_TASK:<task> ROLE:<role>`. Returns the agentId string or '' when no transcript carries the tag.
// Newest-mtime, not first-match: a tag can repeat across transcripts (an earlier probe/retry reusing a
// role tag), so the most recent write is the real role spawn.
function resolveAgent(session, task, role) {
  const sess = sanitize(session);
  const tag = '3ROLE_TASK:' + sanitize(task) + ' ROLE:' + sanitize(role);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return ''; }
  let best = null;       // { agentId, mtimeMs }
  for (const slug of slugs) {
    const dir = path.join(PROJECTS_ROOT, slug, sess, 'subagents');
    let files = [];
    try { files = fs.readdirSync(dir); } catch (e) { continue; }
    for (const fn of files) {
      const m = fn.match(/^agent-(.+)\.jsonl$/);
      if (!m) continue;
      const f = path.join(dir, fn);
      let st;
      try { st = fs.statSync(f); } catch (e) { continue; }
      if (!st.isFile()) continue;
      let content;
      try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
      if (!content.includes(tag)) continue;
      if (!best || st.mtimeMs > best.mtimeMs) best = { agentId: m[1], mtimeMs: st.mtimeMs };
    }
  }
  return best ? best.agentId : '';
}

// Mirror the gate's resolve_path: absolute / ~ / CLAUDE_PROJECT_DIR / cwd / $HOME.
function resolveArtifact(p) {
  if (!p) return '';
  const s = String(p);
  if (s.startsWith('/')) return fileExists(s) ? s : '';
  if (s.startsWith('~/')) { const q = path.join(HOME, s.slice(2)); return fileExists(q) ? q : ''; }
  const cands = [];
  if (process.env.CLAUDE_PROJECT_DIR) cands.push(path.join(process.env.CLAUDE_PROJECT_DIR, s));
  cands.push(path.join(process.cwd(), s));
  cands.push(path.join(HOME, s));
  cands.push(s);
  for (const c of cands) if (fileExists(c)) return c;
  return '';
}

function stripOraclePrefix(s) { return String(s == null ? '' : s).replace(/^oracle:/i, ''); }

// #1276 — vacuous-oracle classifier (RE-AUTHORED from the design intent of the upstream spec-driven
// harness's guardrails #9/#11 — see the Port-C "vacuous oracle" guard plan; no pattern was copied from
// any external source). An execution-review oracle that EXISTS and carries a PASS/verdict token but
// contains ZERO real assertions (all-trivially-true / bare-verdict / echo-only) proves nothing — "a PASS
// that asserts nothing is not a PASS." This classifier returns true ONLY when the oracle is POSITIVELY
// vacuous; ANY parse trouble / binary-ish content / unexpected shape returns false (FAIL-OPEN — never
// fail-closed: a malformed-but-present oracle is ALLOWED, not blocked).
//
// Operate over CONTENT lines (blank + `#`-comment lines dropped). A line is REAL-EVIDENCE when it either
// (R1) EXECUTES an assert command whose exit is the verdict, or (R2) carries a digit-bearing run-summary
// count. The R1 discriminator is that a REAL command is EXECUTED at a COMMAND POSITION (start of an
// `&&`-segment) — a command NAME quoted inside an echo/printf literal is printed TEXT, not run, so it does
// NOT count. The oracle is VACUOUS iff it has ZERO real-evidence content lines.

// R1 — does ONE `&&`-segment EXECUTE a real assert command (exit = verdict)?
function segmentIsRealAssert(seg) {
  const s = String(seg == null ? '' : seg).trim();
  if (!s) return false;
  // grep -q / -E / -F with an operand (the assert: search a file/stream, exit reflects a match).
  if (/^grep\b[^\n]*\s-[A-Za-z]*[qEF][A-Za-z]*\b[^\n]*\s\S/.test(s)) return true;
  // test / [ / [[ — REAL only with a $-var OR a filesystem-test flag (-e/-f/-d/-s/-r/-x) + operand; a
  // constant-vs-constant bracket ([ 1 = 1 ], [[ 1 = 1 ]], test 1 = 1) asserts nothing -> NOT real.
  if (/^(test\b|\[\[?)/.test(s)) {
    if (/\$[A-Za-z_{]/.test(s)) return true;
    if (/\s-[efdsrx]\s+\S/.test(s)) return true;
    return false;
  }
  // arithmetic (( ... )) test.
  if (/^\(\(.*\)\)/.test(s)) return true;
  // diff / cmp of two operands.
  if (/^(diff|cmp)\b\s+\S+\s+\S+/.test(s)) return true;
  // smoke / program / test-runner invocations executed for their exit code.
  if (/^bash\b[^\n]*smoke/i.test(s)) return true;
  if (/^\.\//.test(s)) return true;
  if (/^(pytest|jest|vitest)\b/.test(s)) return true;
  if (/^go\s+test\b/.test(s)) return true;
  if (/^npm\s+test\b/.test(s)) return true;
  if (/^node\b[^\n]*\.mjs\b/.test(s)) return true;
  return false;
}

// R2 — does ONE `&&`-segment carry a CAPTURED run-summary count (exit/output of a real run)? Mirrors R1's
// command-position echo-trap: a count sitting INSIDE an echo/printf literal is printed TEXT, not captured
// output, so a segment whose trimmed form STARTS with echo/printf is SKIPPED before the count regexes run.
// A bare captured line (no echo/printf prefix) is a single segment that keeps its count -> stays REAL.
function segmentIsCapturedCount(seg) {
  const s = String(seg == null ? '' : seg).trim();
  if (!s) return false;
  if (/^(echo|printf)\b/.test(s)) return false;   // printed literal, not captured output -> NOT real.
  if (/\b\d+\s+passed\b/i.test(s)) return true;
  if (/\b\d+\s+failed\b/i.test(s)) return true;
  if (/\bPASS=\d+\b[\s\S]*\bFAIL=\d+\b/i.test(s)) return true;
  if (/\bran\s+\d+\b/i.test(s)) return true;
  if (/\bOK\s*\(\d+/i.test(s)) return true;
  if (/\b\d+\s+(tests?|assertions?|checks?)\b/i.test(s)) return true;
  return false;
}

// Is ONE content line real-evidence (R1 OR R2 in any &&-segment)?
function lineIsRealEvidence(line) {
  const s = String(line == null ? '' : line);
  // Evaluate EACH &&-segment so a real command/count on EITHER side of `&&` counts (the LEFT-of-`&&`
  // realness is decided by the segment's command, NOT the bare presence of `&&`): `grep -q X f && echo
  // PASS` is real (left segment asserts), `true && echo PASS` is vacuous (both segments trivial). R2
  // counts are gated at COMMAND POSITION too (segmentIsCapturedCount skips echo/printf segments), so a
  // count quoted inside `echo "12 passed, 0 failed"` is printed TEXT, not captured output -> NOT real.
  const segs = s.split('&&');
  for (const seg of segs) {
    if (segmentIsRealAssert(seg)) return true;   // R1 — executed assert (exit = verdict).
    if (segmentIsCapturedCount(seg)) return true; // R2 — captured run-summary count.
  }
  return false;
}

// Returns true iff the oracle file is POSITIVELY vacuous. Fail-OPEN (false) on any error / kill-switch /
// binary-ish content.
function isVacuousOracle(filePath) {
  try {
    if (process.env.VACUOUS_ORACLE_OFF === '1') return false;   // belt-and-suspenders kill-switch.
    const raw = fs.readFileSync(filePath, 'utf8');
    // Binary-ish / unparseable bytes (NUL present) -> cannot classify a script -> FAIL-OPEN.
    if (raw.indexOf('\u0000') >= 0) return false;
    let hasContent = false;
    for (const ln of raw.split('\n')) {
      const line = ln.trim();
      if (!line) continue;
      if (line.charAt(0) === '#') continue;   // comment line — drop.
      hasContent = true;
      if (lineIsRealEvidence(line)) return false;   // >= 1 real-evidence line -> NOT vacuous.
    }
    // Zero real-evidence lines among >=1 content line -> vacuous. No content lines at all -> can't-tell ->
    // fail-open (not vacuous).
    return hasContent;
  } catch (e) {
    return false;   // FAIL-OPEN — never fail-closed on a classifier error.
  }
}

// #1199 Part B — normalize a PATH-SHAPED artifact value to a CWD-INDEPENDENT form AT WRITE TIME, so a
// later `check` from any other cwd resolves it. A NON-path value (PR URL, branch name, commit sha,
// "shipped") is stored VERBATIM — never mangled into a bogus absolute path.
//
// R3/R4 — the value-shape guard must NOT treat "any slash" as a path. Two common executor values contain a
// slash but are NOT files: a branch (`feat/1199-x`) and a PR URL (`https://github.com/...`). So:
//   - URL scheme (`http(s)://`, `git://`, `ssh://`, ...) → verbatim.
//   - already a portable home-tilde path (`~/...`) → verbatim (no username, resolves from any cwd).
//   - explicit path shape (`/`, `./`, `../`, `.claude/`, `.ai-workspace/`) → resolve to absolute.
//   - an ambiguous slashed token (`src/llm/generate.ts` vs `feat/x`) → treat as a path ONLY if it resolves
//     to a file that EXISTS on disk (a real executor SOURCE artifact does; a branch never does).
//   - no slash (`PR #123`, a sha, `shipped`) → verbatim.
//
// R6 privacy — the ledger append fires a PostToolUse sync (kanban-sync-on-ledger-append.sh) that publishes
// ledger state to the Vercel-hosted agent-kanban board. To keep a raw `/Users/<name>/...` home path off
// both the at-rest ledger AND that publish surface, when the resolved absolute path is under $HOME we store
// the HOME-RELATIVE TILDE form `~/<rest>` — it carries NO username and resolveArtifact()'s `~/` arm expands
// it from ANY cwd. A path genuinely OUTSIDE $HOME is stored absolute (no home to leak).
function normalizeArtifact(raw) {
  const v = String(raw == null ? '' : raw);
  if (v === '') return v;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) return v;   // URL scheme → not a filesystem path.
  if (v === '~' || v.startsWith('~/')) return v;        // already a portable home-tilde path.
  let abs = '';
  if (v.startsWith('/')) {
    abs = v;
  } else if (/^(\.\/|\.\.\/|\.claude\/|\.ai-workspace\/)/.test(v)) {
    abs = path.resolve(process.cwd(), v);               // explicit relative path shape → resolve.
  } else if (v.includes('/')) {
    const cand = path.resolve(process.cwd(), v);
    if (fileExists(cand)) abs = cand;                   // real source artifact (exists on disk).
    else return v;                                      // branch-shaped / non-file slashed token → verbatim.
  } else {
    return v;                                           // no slash → verbatim (PR #N, sha, "shipped").
  }
  abs = path.normalize(abs).replace(/\/+$/, '');
  const homePrefix = HOME.replace(/\/+$/, '') + path.sep;
  if (abs === HOME || abs.startsWith(homePrefix)) {     // R6: collapse $HOME prefix to `~` (no username).
    const rest = abs === HOME ? '' : abs.slice(homePrefix.length);
    return rest ? '~/' + rest : '~';
  }
  return abs;
}

// Returns {skip:false} when no skip was attempted; {skip:true, ok:true} for a valid reason;
// {skip:true, err:"..."} for an empty/non-specific reason.
function classifySkip(e) {
  if (!('skip_reason' in e)) return { skip: false };
  const t = String(e.skip_reason == null ? '' : e.skip_reason).trim();
  if (t === '') return { skip: true, err: 'skip reason is empty/whitespace' };
  if (NONSPECIFIC_RE.test(t)) return { skip: true, err: 'skip reason "' + t + '" is non-specific' };
  return { skip: true, ok: true };
}

// Returns null when the role is satisfied, else a problem string. `opts.rejectVacuousOracle` (#1276) — set
// ONLY by the instrumentation-gate's `check --reject-vacuous-oracle` — additionally REJECTS an
// execution-review oracle that exists + carries a PASS token but is vacuous (0 real assertions).
function checkRole(role, e, session, opts) {
  const sk = classifySkip(e);
  if (role === 'execution-review') {
    if (sk.skip) {
      return 'execution-review is NEVER inline-skippable (never grade your own homework) — it must resolve to a ' +
        'real reviewer agentId OR an oracle:<path> that exists with a PASS token; "ran it inline myself" is not allowed';
    }
    if (e.oracle) {
      const op = resolveArtifact(stripOraclePrefix(e.oracle));
      if (!op) return 'execution-review oracle path "' + e.oracle + '" does not exist';
      if (!fileHas(op, VERDICT_RE)) return 'execution-review oracle "' + op + '" lacks a PASS/verdict token';
      // #1276: a PASS that asserts nothing is not a PASS. When the gate opts in (and the feature kill-switch
      // is not set), reject a positively-vacuous oracle. The classifier fails OPEN, so this NEVER blocks on
      // a parse error — only on a file proven to carry zero real-evidence lines.
      if (opts && opts.rejectVacuousOracle && process.env.VACUOUS_ORACLE_OFF !== '1' && isVacuousOracle(op)) {
        return 'execution-review oracle "' + op + '" is vacuous — 0 real assertions (all-trivially-true / ' +
          'bare-verdict / echo-only); a PASS that asserts nothing is not a PASS. Add a REAL check (an assert ' +
          'command whose exit is the verdict, or a captured test-run summary with counts) OR name a real reviewer agentId';
      }
      return null;
    }
    if (!agentResolves(session, e.agentId)) {
      return 'execution-review agentId "' + (e.agentId || '') + '" does not resolve to a real subagent transcript (forged or no spawn)';
    }
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'execution-review artifact_path "' + (e.artifact_path || '') + '" not found';
    if (!fileHas(ap, VERDICT_RE)) return 'execution-review artifact "' + ap + '" lacks a verdict/PASS token';
    return null;
  }
  // planner / plan-review / executor — inline-skippable with a SPECIFIC reason.
  if (sk.skip) {
    if (sk.ok) return null;
    return role + ' ' + sk.err + ' — an inline-skip requires a SPECIFIC reason (the carve-out is for genuinely ' +
      'inseparable-from-session-state work; "ran the ' + role + ' inline myself" is NOT a valid skip)';
  }
  if (!agentResolves(session, e.agentId)) {
    return role + ' agentId "' + (e.agentId || '') + '" does not resolve to a real subagent transcript (' +
      PROJECTS_ROOT + '/*/' + sanitize(session) + '/subagents/agent-' + (e.agentId || '') + '.jsonl) — forged or no ' +
      'spawn happened; provide a real agentId OR an explicit inline-skip:<specific reason>';
  }
  if (role === 'planner') {
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'planner artifact_path "' + (e.artifact_path || '') + '" not found (the plan file)';
    if (!fileHas(ap, PLAN_RE)) return 'planner artifact "' + ap + '" lacks a plan marker — needs a heading like ' +
      '## ELI5, ### Binary AC, ## Binary acceptance criteria, ### Acceptance criteria, ## Acceptance, or ## AC';
    return null;
  }
  if (role === 'plan-review') {
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'plan-review artifact_path "' + (e.artifact_path || '') + '" not found';
    if (!fileHas(ap, VERDICT_RE)) return 'plan-review artifact "' + ap + '" lacks a verdict token (PASS/FAIL/APPROVE/verdict/## Review)';
    return null;
  }
  // executor — artifact_path is a string (PR URL / commit / branch); existence on disk not required.
  if (!e.artifact_path || String(e.artifact_path).trim() === '') {
    return 'executor artifact_path missing (PR URL / commit / branch string)';
  }
  return null;
}

// OVERLAY-MERGE core (#855), extracted so both `append` and `inherit-plan-review` write through the SAME
// path (semantics unchanged vs the prior inline cmdAppend body). Reads the ledger, drops any prior line for
// `role` (capturing it to MERGE onto), overlays ONLY the fields supplied in `fields` (own-key presence is the
// "provided" signal — an absent key PERSISTS the prior value; role / session_id / ts always refresh), applies
// the same mutual-exclusion guard, writes back. Recognized `fields` keys: agentId, artifact_path, skip_reason,
// oracle, inherited_from. Returns the ledger file path.
function overlayAppend(session, task, role, fields) {
  const file = ledgerFile(session, task);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); } catch (e) { /* new file */ }
  const kept = [];
  let prior = null;
  for (const ln of lines) {
    try { const j = JSON.parse(ln); if (j && j.role === role) { prior = j; continue; } kept.push(ln); }
    catch (e) { kept.push(ln); }
  }
  // Start from the prior line for this role and overlay ONLY the fields this call provides. Unprovided fields
  // PERSIST from the prior line; role / session_id / ts always refresh. This is what lets "agentId at spawn"
  // and "artifact_path at close" compose into ONE line, order-independent — neither writer clobbers the other.
  const entry = { ...(prior || {}), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agentId' in fields) entry.agentId = fields.agentId;
  if ('artifact_path' in fields) entry.artifact_path = fields.artifact_path;
  if ('skip_reason' in fields) entry.skip_reason = fields.skip_reason;
  if ('oracle' in fields) entry.oracle = fields.oracle;
  if ('inherited_from' in fields) entry.inherited_from = fields.inherited_from;
  // #1036: review roles (plan-review / execution-review / ship-review) may record a one-word VERDICT
  // (APPROVE / PASS / BLOCK / SHIP-WITH-FIXES / APPROVE-WITH-NOTES). Read-only downstream: the agent-kanban
  // board surfaces it as a colored pill. Overlay only when provided (back-compat: absent ⇒ no verdict).
  if ('verdict' in fields) entry.verdict = fields.verdict;
  // #1100 item 3: provenance stamp — overlay only when provided (back-compat: absent ⇒ unstamped).
  if ('self_authored' in fields) entry.self_authored = fields.self_authored;
  // Mutual-exclusion guard: a "ran/verified" signal (agentId for a real spawn, or oracle for a passing test)
  // and a "skip" signal are mutually exclusive by intent, and checkRole tests skip FIRST. So providing
  // agentId or oracle clears any inherited skip_reason (a stale skip can't mask a real spawn/oracle);
  // conversely providing skip_reason clears inherited agentId/artifact_path/oracle (dead weight a merge could
  // otherwise resurrect).
  if (('agentId' in fields) || ('oracle' in fields)) delete entry.skip_reason;
  if ('skip_reason' in fields) { delete entry.agentId; delete entry.artifact_path; delete entry.oracle; delete entry.verdict; delete entry.self_authored; }
  kept.push(JSON.stringify(entry));
  fs.writeFileSync(file, kept.join('\n') + '\n');
  return file;
}

function cmdAppend(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('append: --session, --task, --role are required'); process.exit(2); }
  if (!REQUIRED_ROLES.includes(role)) { console.error('append: --role must be one of ' + REQUIRED_ROLES.join(', ')); process.exit(2); }
  // Map the CLI flag names onto the canonical entry field names overlayAppend overlays.
  const fields = {};
  if ('agent' in o) fields.agentId = o.agent;
  if ('artifact' in o) fields.artifact_path = normalizeArtifact(o.artifact);   // #1199 Part B: cwd-independent + home-tilde.
  if ('skip-reason' in o) fields.skip_reason = o['skip-reason'];
  if ('oracle' in o) fields.oracle = o.oracle;
  if ('verdict' in o) fields.verdict = o.verdict;
  // #1100 item 3: provenance — a line authored BY the role's own agent (its SubagentStop scan saw the agent
  // self-append for this role) carries self_authored:true. Flag presence is the "provided" signal; a bare
  // `--self-authored` (no value) is true, `--self-authored false` is false.
  if ('self-authored' in o) fields.self_authored = (o['self-authored'] !== 'false');
  // #897: a build worktree is transient (quarantined at cleanup), so an artifact_path under
  // `.claude/worktrees/<slug>/` DANGLES the moment the worktree is removed — and the completion gate
  // (which checks the artifact file EXISTS) then BLOCKs. The committed artifact also lives at a stable
  // primary-clone path after merge+FF; cite THAT. Warn (stderr is visible to the orchestrator, unlike an
  // exit-0 hook nudge — #769) but do NOT block: the path may legitimately still exist this instant.
  if (fields.artifact_path && /\/\.claude\/worktrees\//.test(String(fields.artifact_path))) {
    console.error('WARN (3role-ledger #897): --artifact path is inside a build worktree (.claude/worktrees/) — ' +
      'it will DANGLE once the worktree is quarantined, and the completion gate will then BLOCK. Cite the ' +
      'stable primary-clone path the artifact lands at after merge+FF, OR complete the task before quarantine.');
  }
  const file = overlayAppend(session, task, role, fields);
  console.log('OK appended role=' + role + ' -> ' + file);
  process.exit(0);
}

// #881: inherit-plan-review --session S --task T --parent P
// A LEG sub-task (T) may inherit its PARENT's (P) planner + plan-review ledger lines — but ONLY if the parent
// genuinely has a real, TRANSCRIPT-BACKED planner AND plan-review (verify-then-write, fail-closed). A missing /
// forged / inline-skipped parent review BLOCKs (exit 3) and writes NOTHING — you cannot launder an absent or
// fabricated parent review onto a leg, and the session-bound inline-skip carve-out does NOT transfer to a leg.
function cmdInherit(o) {
  const session = o.session, task = o.task, parent = o.parent;
  if (!session || !task || !parent) { console.error('inherit-plan-review: --session, --task, --parent are required'); process.exit(2); }
  const block = (reason) => {
    console.error('BLOCK: cannot inherit — parent task ' + sanitize(parent) + ' has no verified plan-review (' + reason + ')');
    process.exit(3);
  };
  const pfile = ledgerFile(session, parent);
  let lines;
  try { lines = fs.readFileSync(pfile, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) { block('no parent ledger file: ' + pfile); }
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  const planner = byRole['planner'];
  const planReview = byRole['plan-review'];
  if (!planner) block('parent has no planner line');
  if (!planReview) block('parent has no plan-review line');
  // EXPLICIT inline-skip rejection (the #881 catch). checkRole returns null for a well-formed inline-skip, so
  // we must reject skip_reason here BEFORE trusting either entry — the carve-out is session-bound and does not
  // transfer to a leg (a leg inherits ONLY a transcript-backed parent planner + plan-review).
  for (const [r, ent] of [['planner', planner], ['plan-review', planReview]]) {
    if ('skip_reason' in ent) {
      block('parent ' + r + ' was inline-skipped — the carve-out does not apply to legs; provide a real ' +
        'transcript-backed ' + r + ' for the parent first');
    }
  }
  // Verify-or-fail-closed: run the SAME checkRole `check` uses on both parent entries.
  for (const [r, ent] of [['planner', planner], ['plan-review', planReview]]) {
    const prob = checkRole(r, ent, session);
    if (prob) block(prob);
  }
  // Success: append both parent entries into the LEG ledger verbatim (same agentId + artifact_path) + an
  // inherited_from marker, through the same overlay-merge path so a later real per-leg review overwrites clean.
  overlayAppend(session, task, 'planner', { agentId: planner.agentId, artifact_path: planner.artifact_path, inherited_from: sanitize(parent) });
  overlayAppend(session, task, 'plan-review', { agentId: planReview.agentId, artifact_path: planReview.artifact_path, inherited_from: sanitize(parent) });
  console.log('OK inherited plan-review from parent ' + sanitize(parent) + ' -> task ' + sanitize(task));
  process.exit(0);
}

function cmdCheck(o) {
  const session = o.session, task = o.task;
  if (!session || !task) { console.log('BLOCK: check requires --session and --task'); process.exit(2); }
  const file = ledgerFile(session, task);
  let lines;
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) {
    console.log('BLOCK: no role-ledger found for task ' + sanitize(task) + ' in this session (' + file +
      '). Append a ledger line per role: node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append --session <sid> --task <id> --role <role> ...');
    process.exit(2);
  }
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  // #1276: the vacuous-oracle rejection is OPT-IN via --reject-vacuous-oracle (only the instrumentation
  // gate passes it), so `check`'s other callers keep today's exists+PASS oracle acceptance.
  const checkOpts = { rejectVacuousOracle: ('reject-vacuous-oracle' in o) };
  const problems = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e) { problems.push('missing ' + role + ' ledger line'); continue; }
    const r = checkRole(role, e, session, checkOpts);
    if (r) problems.push(r);
  }
  // #1448 per-role MODEL-POLICY enforcement (opt-in via --enforce-role-models; only the instrumentation gate
  // passes it). Compare each REQUIRED role's ACTUAL transcript model to the tier cc-roles.env resolves for it.
  // Fail-SAFE: no config resolved => skip ENTIRELY (all-opus is the safe default we must not false-block).
  // Per role: inline-skip / missing / unresolvable-agentId / no message.model => fail-open (can't-tell). A
  // mismatch pushes a MODEL-POLICY: problem (=> exit 2). Fable->Opus silent reroute (expected fable, actual
  // opus) is OK-with-note. Also honors the feature kill-switch CC_ROLE_MODEL_GATE_OFF=1 internally (belt &
  // suspenders: the gate already strips the flag, but a direct `check --enforce-role-models` must skip too).
  if (('enforce-role-models' in o) && process.env.CC_ROLE_MODEL_GATE_OFF !== '1') {
    const { found, cfg } = loadRoleConfig();
    if (found) {
      lintRoleConfig(cfg);   // defect-3 visibility: fires on stderr on every enforce read (loud, once).
      for (const role of REQUIRED_ROLES) {
        const e = byRole[role];
        if (!e || ('skip_reason' in e)) continue;              // no transcript to read for a missing / inline-skip role
        if (!agentResolves(session, e.agentId)) continue;      // presence already reported above; can't-tell here
        const actualId = transcriptModel(session, e.agentId);
        const actual = modelIdToTier(actualId);
        if (!actual) continue;                                 // no message.model / unknown id => fail-open
        const expected = roleModelFromCfg(cfg, role);
        if (actual === expected) continue;                     // match => OK
        if (expected === 'fable' && actual === 'opus') continue; // Anthropic silent fable->opus reroute => OK-with-note
        problems.push('MODEL-POLICY: role ' + role + ' ran on ' + actual + ' (transcript model ' + actualId +
          ') but cc-roles.env resolves ' + role + ' -> ' + expected + '. Re-run the role on model:' + expected +
          ', or update CC_ROLE_' + roleKeyStem(role) + '_MODEL in cc-roles.env. Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.');
      }
    }
  }
  // #1100 item 3: provenance flags — a required role that ran as a REAL spawn (not an inline-skip) but whose
  // line lacks the self_authored stamp is provenance-unverified (an orchestrator-fabricated line has no
  // authoring agent turn). By DEFAULT this only SURFACES (never a silent brick — the honest residual: a
  // quiet-but-legit agent that forgot to self-append). Strict-block is opt-IN via --require-provenance.
  const provenanceFlags = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e || ('skip_reason' in e)) continue;        // missing handled above; skips don't have an authoring turn
    if (!e.self_authored) provenanceFlags.push(role);
  }
  const requireProv = ('require-provenance' in o);
  if (requireProv) {
    for (const role of provenanceFlags) problems.push(role + ' lacks a self_authored provenance stamp (--require-provenance)');
  }
  if (problems.length) { console.log('BLOCK: ' + problems.join('; ')); process.exit(2); }
  if (provenanceFlags.length) {
    console.log('PROVENANCE: ' + provenanceFlags.join(', ') +
      ' provenance-unverified (no self_authored stamp — orchestrator-fabricated or a quiet agent that did not self-append)');
  }
  console.log('OK: role-ledger complete for task ' + sanitize(task) +
    ' (planner, plan-review, executor, execution-review all resolved)');
  process.exit(0);
}

// #860: resolve-agent --session S --task T --role R -> newest-mtime tagged transcript's agentId on stdout.
function cmdResolveAgent(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('resolve-agent: --session, --task, --role are required'); process.exit(2); }
  const agentId = resolveAgent(session, task, role);
  if (!agentId) process.exit(1);   // no transcript carries the tag — print nothing, fail.
  console.log(agentId);
  process.exit(0);
}

// #1303: resolve-artifact --session S --task T --role R -> existence-checked absolute artifact_path on stdout.
// Reuses ledgerFile() + resolveArtifact() (the load-bearing helpers) and the SAME last-line-per-role parse
// cmdCheck/cmdInherit use. Exits non-zero on every "no usable artifact" branch so the gate falls back to the
// convention dir (the #1266 ledger-first fix). Only artifact_path is read — verdict/skip fields are ignored.
function cmdResolveArtifact(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('resolve-artifact: --session, --task, --role are required'); process.exit(2); }
  const file = ledgerFile(session, task);
  let lines;
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) { process.exit(1); }   // no ledger -> caller falls back to convention dir
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  const e = byRole[role];
  if (!e || !e.artifact_path || String(e.artifact_path).trim() === '') process.exit(1);
  const abs = resolveArtifact(e.artifact_path); // expands ~ / CLAUDE_PROJECT_DIR / cwd / $HOME, '' if not on disk
  if (!abs) process.exit(1);
  console.log(abs);
  process.exit(0);
}

// #1350: heartbeat --session S --task T -> bump <task>.jsonl mtime to ~now (touch-existing OR create-zero-byte).
// Writes NO JSONL line (AC-4 non-corruption by construction). ALWAYS exits 0 (fail-open) — a heartbeat error
// must never wedge the spawn it instruments, so the whole body is wrapped and every failure path returns 0.
function cmdHeartbeat(o) {
  try {
    const session = o.session, task = o.task;
    // Missing args -> nothing to touch; fail-open (do NOT exit 2 like the other subcommands).
    if (!session || !task) process.exit(0);
    const file = ledgerFile(session, task);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (!fileExists(file)) {
      // Create a ZERO-byte file. 'a' (append) NEVER truncates — so even on a race where a real append just
      // created a non-empty <task>.jsonl, this opens-and-closes without clobbering its content.
      fs.closeSync(fs.openSync(file, 'a'));
    }
    // Advance mtime to ~now (the entire board signal). Content is left untouched on every path.
    const now = new Date();
    fs.utimesSync(file, now, now);
  } catch (e) { /* fail-open: a heartbeat error never blocks the spawn */ }
  process.exit(0);
}

// #1448: resolve-role-model --role <role> [--with-effort]
// Prints the configured model TIER for a role (the single value the orchestrator + both model hooks consume),
// fail-SAFE to opus (missing/malformed config OR an invalid per-role value => opus). With --with-effort prints
// "<model> <effort>". Lints the config on read (defect-3 stderr visibility). Always exits 0 — a resolver error
// must never wedge a spawn; opus is the safe answer.
function cmdResolveRoleModel(o) {
  const role = o.role;
  if (!role) { console.error('resolve-role-model: --role is required (planner|plan-review|executor|execution-review|orchestrator)'); process.exit(2); }
  const { found, cfg } = loadRoleConfig();
  if (found) lintRoleConfig(cfg);
  const model = found ? roleModelFromCfg(cfg, role) : 'opus';
  const effort = found ? roleEffortFromCfg(cfg, role) : '';
  if ('with-effort' in o) console.log(model + (effort ? ' ' + effort : ''));
  else console.log(model);
  process.exit(0);
}

const [, , cmd, ...rest] = process.argv;
const opts = parseArgs(rest);
try {
  if (cmd === 'append') cmdAppend(opts);
  else if (cmd === 'check') cmdCheck(opts);
  else if (cmd === 'heartbeat') cmdHeartbeat(opts);
  else if (cmd === 'resolve-agent') cmdResolveAgent(opts);
  else if (cmd === 'resolve-artifact') cmdResolveArtifact(opts);
  else if (cmd === 'resolve-role-model') cmdResolveRoleModel(opts);
  else if (cmd === 'inherit-plan-review') cmdInherit(opts);
  else {
    console.log('usage: 3role-ledger.mjs <append|check|heartbeat|resolve-agent|resolve-artifact|resolve-role-model|inherit-plan-review> ' +
      '--session S --task T [--role R --agent A --artifact P --skip-reason "..." --oracle P] [--parent P (inherit-plan-review)] ' +
      '[--role R [--with-effort] (resolve-role-model)] [--enforce-role-models (check)]');
    process.exit(2);
  }
} catch (e) {
  console.log('BLOCK: ledger helper error: ' + (e && e.message ? e.message : e));
  process.exit(2);
}
