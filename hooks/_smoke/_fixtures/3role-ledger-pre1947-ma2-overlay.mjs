#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre1947-ma2-overlay.mjs — COMMITTED STATIC FIXTURE.
//
// Durable, hermetic RED-leg fixture for #1947's round-2 execution-review finding "M-A-2" (fix-round 2),
// following the SAME pattern as hooks/_fixtures/3role-ledger-pre1580-overlay.mjs (#1833 Bundle 1A): a
// minimal, in-pocket, no-git-dependency port of a PAST buggy `overlayAppend`, so the RED leg always runs
// for real (no pinned-SHA reachability requirement across a shallow CI checkout or the three-role-model
// plugin repo's independent commit graph).
//
// MEASURED (not assumed) behavior at pinned SHA aa924ff51 (`git show aa924ff51:hooks/3role-ledger.mjs`,
// the round-2 M-A fix commit, immediate parent of this fix-round's commit): overlayAppend's
// agentId/oracle clear-list tested only `('agentId' in fields) || ('oracle' in fields)` — mere KEY
// PRESENCE — then unconditionally deleted `dispatch`/`transcript_path`/`nonce`, with NO check that the
// incoming agentId/oracle actually RESOLVES to real evidence. A non-resolving (bogus/forged) `--agent`
// append therefore erased a completed, nonce-verified subprocess-openrouter dispatch's provenance just the
// same as a genuinely-resolving one — turning a genuinely-completed role into a false BLOCK the instant
// `check` re-evaluated the row and found the subprocess marker gone (falls through to the ordinary
// agentId-resolution arm, which correctly fails on the bogus agentId). This is execution-review round-2's
// "M-A-2" finding. Fix-round 2 (current hooks/3role-ledger.mjs) gates that same clear on
// `agentResolves(session, fields.agentId)` (or, for execution-review only, a genuinely-resolving oracle) —
// THAT gate is what this fixture's absence of any resolution check demonstrates the need for.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs gate, and do NOT regenerate it from
// current code — the non-decay guard in 3role-ledger-smoke-test.sh asserts this fixture's behavior DIFFERS
// from current code (erasure-that-false-BLOCKs vs preservation-that-passes) on identical inputs. If a
// future edit ever collapses the two to the same outcome, that guard goes RED on purpose.
//
// Minimal subset: only the `append` verb, only the fields #1947's Reproduction A sequence exercises
// (agent, artifact, verdict, dispatch, transcript, nonce, oracle). No round-boundary / terminal-evidence-
// guard porting — Reproduction A's exact sequence never triggers either (the step-3 `--agent` append
// carries no skip_reason/inherited_from/verdict of its own, so #1575/#1580's guard clauses are inert for
// this scenario; and the prior row has no agentId, so #1580 Fix B's round-boundary never fires) — Rule 17
// (mechanical, in-pocket, no git dependency) over faithfulness-by-bulk, same minimality call the #1833
// exemplar and its own #1494 predecessor made.

import fs from 'node:fs';
import path from 'node:path';

const LEDGER_DIR = process.env.THREE_ROLE_LEDGER_DIR || path.join(process.env.HOME || '/tmp', '.claude', '3role-ledger');

function sanitize(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
function ledgerFile(session, task) { return path.join(LEDGER_DIR, sanitize(session), sanitize(task) + '.jsonl'); }

// PRE-#1947-fix-round-2 overlayAppend, byte-behavior-verified against the pinned SHA aa924ff51: the
// agentId/oracle clear-list unconditionally deletes dispatch/transcript_path/nonce on mere KEY PRESENCE —
// no `agentResolves` check, no oracle-resolution check.
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
  const entry = { ...(prior || {}), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agentId' in fields) entry.agentId = fields.agentId;
  if ('artifact_path' in fields) entry.artifact_path = fields.artifact_path;
  if ('oracle' in fields) entry.oracle = fields.oracle;
  if ('verdict' in fields) entry.verdict = fields.verdict;
  if ('dispatch' in fields) entry.dispatch = fields.dispatch;
  if ('transcript_path' in fields) entry.transcript_path = fields.transcript_path;
  if ('nonce' in fields) entry.nonce = fields.nonce;
  // THE BUG (pinned SHA aa924ff51): mere key PRESENCE, never resolution, gates the clear.
  if (('agentId' in fields) || ('oracle' in fields)) {
    delete entry.skip_reason;
    delete entry.dispatch; delete entry.transcript_path; delete entry.nonce;
  }
  kept.push(JSON.stringify(entry));
  fs.writeFileSync(file, kept.join('\n') + '\n');
  return file;
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) { o[key] = true; }
      else { o[key] = next; i++; }
    }
  }
  return o;
}

function cmdAppend(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('append: --session, --task, --role are required'); process.exit(2); }
  const fields = {};
  if ('agent' in o) fields.agentId = o.agent;
  if ('artifact' in o) fields.artifact_path = o.artifact;
  if ('oracle' in o) fields.oracle = o.oracle;
  if ('verdict' in o) fields.verdict = o.verdict;
  if ('dispatch' in o) fields.dispatch = o.dispatch;
  if ('transcript' in o) fields.transcript_path = o.transcript;
  if ('nonce' in o) fields.nonce = o.nonce;
  overlayAppend(session, task, role, fields);
}

const [, , verb, ...rest] = process.argv;
const opts = parseArgs(rest);
if (verb === 'append') cmdAppend(opts);
else { console.error('unsupported verb: ' + String(verb) + ' — this fixture only implements `append` (the #1947 M-A-2 Reproduction A subset)'); process.exit(2); }
