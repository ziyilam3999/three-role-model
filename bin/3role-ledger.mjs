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
  const problems = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e) { problems.push('missing ' + role + ' ledger line'); continue; }
    const r = checkRole(role, e, session);
    if (r) problems.push(r);
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

const [, , cmd, ...rest] = process.argv;
const opts = parseArgs(rest);
try {
  if (cmd === 'append') cmdAppend(opts);
  else if (cmd === 'check') cmdCheck(opts);
  else if (cmd === 'resolve-agent') cmdResolveAgent(opts);
  else if (cmd === 'inherit-plan-review') cmdInherit(opts);
  else {
    console.log('usage: 3role-ledger.mjs <append|check|resolve-agent|inherit-plan-review> --session S --task T ' +
      '[--role R --agent A --artifact P --skip-reason "..." --oracle P] [--parent P (inherit-plan-review)]');
    process.exit(2);
  }
} catch (e) {
  console.log('BLOCK: ledger helper error: ' + (e && e.message ? e.message : e));
  process.exit(2);
}
