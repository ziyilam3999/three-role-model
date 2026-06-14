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
//     Writes one JSONL line to <ledger-dir>/<S>/<T>.jsonl. Idempotent PER ROLE — re-appending the same
//     role UPDATES the line (drops the prior one), never duplicates.
//   check --session S --task T
//     Exit 0 (+ "OK ...") iff all four required roles (planner, plan-review, executor, execution-review)
//     are present AND satisfied; otherwise exit 2 (+ "BLOCK: <reason>"). A role is satisfied by EITHER
//     (a) an agentId that resolves to a real subagent transcript AND a well-shaped artifact, OR (b) an
//     explicit, SPECIFIC inline-skip reason. execution-review is NEVER inline-skippable — it needs a real
//     reviewer agentId OR a test-oracle path that exists with a PASS/verdict token.
//   resolve-agent --session S --task T --role R
//     Prints the agentId (basename of the `agent-<id>.jsonl` transcript) of the NEWEST-mtime subagent
//     transcript under <projects-root>/*/<S>/subagents/ whose content carries the literal spawn tag
//     `3ROLE_TASK:<T> ROLE:<R>` (#860). Exit 0 with the agentId on stdout when a match exists; prints
//     nothing + exits non-zero when no transcript carries the tag. Newest-mtime (not first-match) because a
//     tag can repeat across transcripts (an earlier probe/retry reusing a role tag), so the most recent
//     write is the real role spawn — a bare first-match/head -1 can grab a stale probe.
//
// Env overrides (mirror DOGFOOD_GATE_STORE so a smoke can point at a fixture tree):
//   THREE_ROLE_LEDGER_DIR    (default ~/.claude/3role-ledger)
//   THREE_ROLE_PROJECTS_ROOT (default ~/.claude/projects)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

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

// Returns {skip:false} when no skip was attempted; {skip:true, ok:true} for a valid reason;
// {skip:true, err:"..."} for an empty/non-specific reason.
function classifySkip(e) {
  if (!('skip_reason' in e)) return { skip: false };
  const t = String(e.skip_reason == null ? '' : e.skip_reason).trim();
  if (t === '') return { skip: true, err: 'skip reason is empty/whitespace' };
  if (NONSPECIFIC_RE.test(t)) return { skip: true, err: 'skip reason "' + t + '" is non-specific' };
  return { skip: true, ok: true };
}

// Returns null when the role is satisfied, else a problem string.
function checkRole(role, e, session) {
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

function cmdAppend(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('append: --session, --task, --role are required'); process.exit(2); }
  if (!REQUIRED_ROLES.includes(role)) { console.error('append: --role must be one of ' + REQUIRED_ROLES.join(', ')); process.exit(2); }
  const file = ledgerFile(session, task);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); } catch (e) { /* new file */ }
  // Idempotent per role: drop any prior line for this role (capturing it to MERGE onto); keep unparseable
  // lines untouched.
  const kept = [];
  let prior = null;
  for (const ln of lines) {
    try { const j = JSON.parse(ln); if (j && j.role === role) { prior = j; continue; } kept.push(ln); }
    catch (e) { kept.push(ln); }
  }
  // OVERLAY-MERGE (#855): start from the prior line for this role and overlay ONLY the fields this call
  // provides. Unprovided fields PERSIST from the prior line; role / session_id / ts always refresh. This is
  // what lets "agentId written at spawn" and "artifact_path added at close" compose into ONE line,
  // order-independent — neither writer clobbers the other's field.
  const entry = { ...(prior || {}), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agent' in o) entry.agentId = o.agent;
  if ('artifact' in o) entry.artifact_path = o.artifact;
  if ('skip-reason' in o) entry.skip_reason = o['skip-reason'];
  if ('oracle' in o) entry.oracle = o.oracle;
  // Mutual-exclusion guard: a "ran/verified" signal (--agent for a real spawn, or --oracle for a passing
  // test) and a "skip" signal are mutually exclusive by intent, and checkRole tests skip FIRST. So
  // providing --agent or --oracle clears any inherited skip_reason (a stale skip can't mask a real
  // spawn/oracle); conversely providing --skip-reason clears inherited agentId/artifact_path/oracle (those
  // fields would be dead weight a merge could otherwise resurrect).
  if (('agent' in o) || ('oracle' in o)) delete entry.skip_reason;
  if ('skip-reason' in o) { delete entry.agentId; delete entry.artifact_path; delete entry.oracle; }
  kept.push(JSON.stringify(entry));
  fs.writeFileSync(file, kept.join('\n') + '\n');
  console.log('OK appended role=' + role + ' -> ' + file);
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
  const problems = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e) { problems.push('missing ' + role + ' ledger line'); continue; }
    const r = checkRole(role, e, session);
    if (r) problems.push(r);
  }
  if (problems.length) { console.log('BLOCK: ' + problems.join('; ')); process.exit(2); }
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

const [, , cmd, ...rest] = process.argv;
const opts = parseArgs(rest);
try {
  if (cmd === 'append') cmdAppend(opts);
  else if (cmd === 'check') cmdCheck(opts);
  else if (cmd === 'resolve-agent') cmdResolveAgent(opts);
  else {
    console.log('usage: 3role-ledger.mjs <append|check|resolve-agent> --session S --task T [--role R --agent A --artifact P --skip-reason "..." --oracle P]');
    process.exit(2);
  }
} catch (e) {
  console.log('BLOCK: ledger helper error: ' + (e && e.message ? e.message : e));
  process.exit(2);
}
