#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre1580-overlay.mjs — COMMITTED STATIC FIXTURE (#1833 Bundle 1A).
//
// Durable, hermetic stand-in for a git-object-dependent acquisition this fixture REPLACES. The RED leg in
// hooks/3role-ledger-smoke-test.sh used to `git cat-file -e 0ba0e4233:hooks/3role-ledger.mjs` + `git show`
// that SHA into a temp file — pinned to an IMMUTABLE SHA (so it never rots into fixed-vs-fixed), but
// fail-opening to a vacuous informational SKIP the moment that ancestor is unreachable (a shallow CI
// checkout, or the three-role-model PLUGIN repo, whose own commit graph does not carry ai-brain SHAs at
// all). This file carries the SAME pre-#1580 vulnerable behavior IN-POCKET instead: no git dependency, no
// reachability requirement, always runs for real.
//
// MEASURED (not assumed) pre-#1580 behavior at pinned SHA 0ba0e4233 (`git show
// 0ba0e4233:hooks/3role-ledger.mjs`, verified 2026-07-24 against origin/master @ e44d09f52): overlayAppend's
// terminal-evidence guard was keyed ONLY on `prior.verdict` (the #1575 predicate). A COMPLETED EXECUTOR row
// carries agentId + artifact_path + closedAt and NO verdict (only review roles ever carry a verdict) — so
// that guard was BLIND to it, and the unconditional clear-list under `if ('skip_reason' in fields)` erased
// agentId/artifact_path/verdict/closedAt on ANY bare `--skip-reason` append, no exception for a completed
// row. #1580 Fix A (current hooks/3role-ledger.mjs, function `priorHasTerminalEvidence`) generalized the
// guard to: verdict OR closedAt OR self_authored OR oracle OR a completed agentId+artifact_path pair — THAT
// broadened predicate is what this fixture's absence of any completed-row guard demonstrates the need for.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs guard, and do NOT regenerate it from
// current code — the AC3 non-decay guard in 3role-ledger-smoke-test.sh asserts this fixture's behavior
// DIFFERS from current code (erasure vs preserve) on the identical inputs. If a future edit ever collapses
// the two to identical outcomes, that guard goes RED on purpose.
//
// Minimal subset: only the `append` verb, only the fields the smoke's monotonicity-tripwire + AC6
// run-supersedes-skip fixtures need (agent, artifact, closed-at, skip-reason, verdict). Deliberately NOT a
// full byte-for-byte port of the historical 2960-line file — Rule 17 (mechanical, in-pocket, no git
// dependency) over faithfulness-by-bulk; the #1494 exemplar this mirrors made the same minimality call.

import fs from 'node:fs';
import path from 'node:path';

const LEDGER_DIR = process.env.THREE_ROLE_LEDGER_DIR || path.join(process.env.HOME || '/tmp', '.claude', '3role-ledger');

function sanitize(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
function ledgerFile(session, task) { return path.join(LEDGER_DIR, sanitize(session), sanitize(task) + '.jsonl'); }

class GuardRejection extends Error {}

// PRE-#1580 overlayAppend, byte-behavior-verified against the pinned SHA 0ba0e4233: the terminal-evidence
// guard is keyed ONLY on `prior.verdict` — blind to a completed executor row (agentId+artifact_path+
// closedAt, no verdict).
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
  // Pre-#1580: guarded ONLY on prior.verdict (the #1575 shape) — a completed executor row has no verdict,
  // so this branch never fires for it, and the clear-list below runs unconditionally.
  if (prior && prior.verdict) {
    if ((('skip_reason' in fields) || ('inherited_from' in fields)) && !('verdict' in fields)) {
      throw new GuardRejection(
        'terminal-evidence guard (pre-#1580, verdict-only): role ' + role + ' already carries a completed ' +
        'verdict "' + prior.verdict + '" — a verdict-LESS write (skip / inherit) cannot erase it.'
      );
    }
  }
  const entry = { ...(prior || {}), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agentId' in fields) entry.agentId = fields.agentId;
  if ('artifact_path' in fields) entry.artifact_path = fields.artifact_path;
  if ('skip_reason' in fields) entry.skip_reason = fields.skip_reason;
  if ('closedAt' in fields) entry.closedAt = fields.closedAt;
  if ('verdict' in fields) entry.verdict = fields.verdict;
  // Same mutual-exclusion clear-list shape as the live code's overlayAppend, restricted to the fields this
  // minimal fixture tracks — agentId/oracle clears a stale skip_reason; skip_reason clears the completed-run
  // evidence (agentId/artifact_path/verdict/closedAt), UNCONDITIONALLY — this is the pre-#1580 bug.
  if ('agentId' in fields) delete entry.skip_reason;
  if ('skip_reason' in fields) {
    delete entry.agentId; delete entry.artifact_path; delete entry.verdict; delete entry.closedAt;
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
  if ('skip-reason' in o) fields.skip_reason = o['skip-reason'];
  if ('closed-at' in o) fields.closedAt = o['closed-at'];
  if ('verdict' in o) fields.verdict = o.verdict;
  try {
    overlayAppend(session, task, role, fields);
  } catch (e) {
    if (e instanceof GuardRejection) { console.error('BLOCK: ' + e.message); process.exit(2); }
    throw e;
  }
}

const [, , verb, ...rest] = process.argv;
const opts = parseArgs(rest);
if (verb === 'append') cmdAppend(opts);
else { console.error('unsupported verb: ' + String(verb) + ' — this fixture only implements `append` (the pre-#1580 monotonicity-tripwire subset)'); process.exit(2); }
