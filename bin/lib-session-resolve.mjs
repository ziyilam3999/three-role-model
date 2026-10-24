#!/usr/bin/env node
// hooks/lib-session-resolve.mjs -- #3520 area 1: the ONE session-id resolver (id + its aliases).
//
// WHY: a chat session is often an ALIAS of the session that holds the ticket JSON and the ledger rows
// (one conversation, two ids: the tasks-dir owner and the current chat id). Before #3520 nine files each
// carried a private alias walk (3role-ledger.mjs #3342/#3350, fastpath-verify ftcSessionAliases, the
// plan-review / transition / enforce-review gates, ...) and three readers had none at all:
// tools/ft-stamp-execution.mjs (#3511: rc=3 "no stampable ticket" whenever the dispatch --session was the
// alias), fastpath-verify's ticket-execution read, and the mistake-signal override-used detector (an
// override row written under the alias session never counted -> the health light was blind in exactly the
// session that runs). This file is the shared answer; callers import it (node) or go through
// hooks/lib-session-resolve.sh (bash), never a private copy.
//
// SOURCES of aliases for a session S (each bounded, each fails CLOSED to "no alias"):
//   1. the ledger dir:  <LEDGER>/.session-alias/<S>   (#1942: one alias session id per line; <= 4 KiB,
//      <= SESSION_ALIAS_MAX lines read)
//   2. the job state:   <JOBS>/<first 8 chars of S>/state.json  (<= 1 MiB; its sessionId / resumeSessionId
//      pair: when one of them is S, the other is an alias)
//   Every alias must be a token-safe session id that names a REAL ledger session dir (<LEDGER>/<id>/), the
//   #3342 rule -- a stray line can never point a reader at an arbitrary directory.
//   3. the tasks dir is the CONSUMER of the family, not a source: ticketJsonPath() walks [S, ...aliases] and
//      returns the first <tasks-root>/<sid>/<task>.json that is a regular file (S first, so a ticket under
//      the session's own dir answers byte-identically to the pre-alias readers).
//
// Roots: LEDGER = THREE_ROLE_LEDGER_DIR || ~/.claude/3role-ledger ; JOBS = CC_JOBS_DIR || ~/.claude/jobs.
// The tasks root is always the CALLER's (each reader keeps its own documented root order).
//
// CLI (for bash callers, see lib-session-resolve.sh; always exit 0 on valid args, 2 on bad usage):
//   node lib-session-resolve.mjs aliases --session S            -> alias ids, one per line
//   node lib-session-resolve.mjs family  --session S            -> S then its aliases, one per line
//   node lib-session-resolve.mjs ticket-session --session S --task T [--tasks-root R]
//                                                               -> the family member holding T's ticket, else S
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SESSION_ID_RE = /^[0-9A-Za-z][0-9A-Za-z._-]{0,127}$/;
export const SESSION_ALIAS_MAX = 8;
const ALIAS_FILE_MAX_BYTES = 4096;
const JOB_STATE_MAX_BYTES = 1024 * 1024;
const TOKEN_RE = /^[0-9A-Za-z._-]{1,128}$/;

export function sanitizeSession(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
export function ledgerDir() {
  return process.env.THREE_ROLE_LEDGER_DIR || path.join(os.homedir(), '.claude', '3role-ledger');
}
export function jobsDir() {
  return process.env.CC_JOBS_DIR || path.join(os.homedir(), '.claude', 'jobs');
}
function cleanId(v) {
  const a = String(v == null ? '' : v).trim();
  return (a && a === sanitizeSession(a) && SESSION_ID_RE.test(a) && !a.includes('..')) ? a : '';
}
export function isLedgerSessionDir(sid, ldir) {
  if (!SESSION_ID_RE.test(String(sid || ''))) return false;
  try { return fs.statSync(path.join(ldir || ledgerDir(), sid)).isDirectory(); } catch (e) { return false; }
}

// Source 1: the ledger alias file (the #3342 reader, unchanged semantics).
function ledgerAliasLines(s, ldir) {
  try {
    const f = path.join(ldir, '.session-alias', s);
    const st = fs.statSync(f);
    if (!st.isFile() || st.size <= 0 || st.size > ALIAS_FILE_MAX_BYTES) return [];   // INPUT-BOUND: fail closed
    return fs.readFileSync(f, 'utf8').split('\n').slice(0, SESSION_ALIAS_MAX);
  } catch (e) { return []; }
}
// Source 2: the job state's sessionId / resumeSessionId pair.
function jobStateAliases(s) {
  const short = s.slice(0, 8);
  if (!/^[0-9A-Za-z]{8}$/.test(short)) return [];
  try {
    const f = path.join(jobsDir(), short, 'state.json');
    const st = fs.statSync(f);
    if (!st.isFile() || st.size <= 0 || st.size > JOB_STATE_MAX_BYTES) return [];    // INPUT-BOUND: fail closed
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!j || typeof j !== 'object') return [];
    const a = cleanId(j.sessionId), b = cleanId(j.resumeSessionId);
    if (a === s && b && b !== s) return [b];
    if (b === s && a && a !== s) return [a];
  } catch (e) { /* unreadable / bad JSON -> no alias */ }
  return [];
}

// The alias ids of a session (never the session itself): <= SESSION_ALIAS_MAX, file order (ledger file first,
// then job state), each a clean token naming a real ledger session dir.
export function sessionAliases(session, opts = {}) {
  const s = sanitizeSession(session);
  if (!s || !SESSION_ID_RE.test(s)) return [];
  const ldir = opts.ledgerDir || ledgerDir();
  const out = [];
  const cands = ledgerAliasLines(s, ldir).concat(opts.noJobState ? [] : jobStateAliases(s));
  for (const raw of cands) {
    if (out.length >= SESSION_ALIAS_MAX) break;
    const a = String(raw).trim();
    if (!a || a === s || a !== sanitizeSession(a)) continue;   // not a clean session token -> ignored
    if (!isLedgerSessionDir(a, ldir)) continue;                // names no real ledger session -> ignored
    if (!out.includes(a)) out.push(a);
  }
  return out;
}
export function sessionFamily(session, opts = {}) {
  const s = sanitizeSession(session);
  if (!s || !SESSION_ID_RE.test(s)) return [];
  return [s].concat(sessionAliases(s, opts));
}
export function sessionsAliasLinked(a, b, opts = {}) {
  const sa = sanitizeSession(a), sb = sanitizeSession(b);
  if (!sa || !sb || sa === sb) return false;
  return sessionAliases(sa, opts).includes(sb) || sessionAliases(sb, opts).includes(sa);
}

// The ticket path a reader should open: <root>/<session>/<task>.json when it is a regular file, else the first
// alias session holding one, else the session's own path (the caller's stat then fails exactly as before).
export function ticketJsonPath(root, session, task, opts = {}) {
  const s = String(session == null ? '' : session), t = String(task == null ? '' : task);
  const own = path.join(root, s, t + '.json');
  if (!TOKEN_RE.test(s) || !TOKEN_RE.test(t) || s.includes('..') || t.includes('..')) return own;
  try { if (fs.statSync(own).isFile()) return own; } catch (e) { /* not under the session -> try aliases */ }
  for (const a of sessionAliases(s, opts)) {
    const cand = path.join(root, a, t + '.json');
    try { if (fs.statSync(cand).isFile()) return cand; } catch (e) { /* next alias */ }
  }
  return own;
}
// The family member whose tasks dir holds the ticket (the canonical orchestrator id for that ticket), else S.
export function ticketSession(root, session, task, opts = {}) {
  const s = String(session == null ? '' : session), t = String(task == null ? '' : task);
  const p = ticketJsonPath(root, s, t, opts);
  if (p === path.join(root, s, t + '.json')) return s;
  return path.basename(path.dirname(p));
}
export function defaultTasksRoot() {
  return process.env.PROGRESS_TASKS_DIR || path.join(os.homedir(), '.claude', 'tasks');
}

function cli(argv) {
  const cmd = argv[0];
  const o = {};
  for (let i = 1; i < argv.length; i += 2) o[String(argv[i]).replace(/^--/, '')] = argv[i + 1];
  if (typeof o.session !== 'string' || !o.session) { console.error('lib-session-resolve: --session <sid> is required'); return 2; }
  if (cmd === 'aliases') { const a = sessionAliases(o.session); if (a.length) console.log(a.join('\n')); return 0; }
  if (cmd === 'family') { const f = sessionFamily(o.session); if (f.length) console.log(f.join('\n')); return 0; }
  if (cmd === 'ticket-session') {
    if (typeof o.task !== 'string' || !o.task) { console.error('lib-session-resolve: --task <id> is required'); return 2; }
    const root = (typeof o['tasks-root'] === 'string' && o['tasks-root']) ? o['tasks-root'] : defaultTasksRoot();
    console.log(ticketSession(root, o.session, o.task));
    return 0;
  }
  console.error('usage: lib-session-resolve.mjs <aliases|family|ticket-session> --session <sid> [--task <id>] [--tasks-root <dir>]');
  return 2;
}

let isMain = false;
try { isMain = !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch (e) { isMain = false; }
if (isMain) process.exit(cli(process.argv.slice(2)));
