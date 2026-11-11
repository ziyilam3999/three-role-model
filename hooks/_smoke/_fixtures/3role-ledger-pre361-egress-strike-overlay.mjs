#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre361-egress-strike-overlay.mjs — COMMITTED STATIC FIXTURE.
//
// Durable, hermetic RED-leg fixture for #361 (plan .ai-workspace/plans/2026-11-08-361-plan.md), following
// the SAME pattern as hooks/_fixtures/3role-ledger-pre3073-strikes-overlay.mjs / -pre3065-hollow-overlay.mjs:
// a minimal, in-pocket, no-git-dependency port of the PAST (pre-#361) countExecutorStrikes, so the RED leg
// always runs for real (no pinned-SHA reachability requirement across a shallow CI checkout).
//
// MEASURED (not assumed) behavior at the #361 base rev beb312c19e (the executorStrikeFacts loop as it stood
// BEFORE the #361 skip clause): every invocation-opening, non-drill `OR-DISPATCH-FALLBACK role=executor
// task=T` row with `kv.reason !== 'timeout'` struck — including `reason=privacy-block`, the token the rc=7
// mid-run egress short-circuit stamps (tools/openrouter-role-dispatch.sh classify_postmortem privacy-block →
// PM_REASON → the FALLBACK row) — so two privacy blocks routed the task off z.ai at the 2-strike rule. That
// is the defect this fixture demonstrates the need for: on the receipts-exec-egress-x2.md fixture it prints
// 2 where the fixed ledger prints 0.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs rule, and do NOT regenerate it from
// current code — hooks/361-egress-block-strike-smoke.sh asserts this fixture's output DIFFERS from current
// code on identical inputs. If a future edit ever collapses the two to the same outcome, that guard goes
// RED on purpose.
//
// Minimal subset (Rule 17, same minimality call as the pre3073 exemplar): only the `zai-strikes --task T
// --role executor` verb (plain integer output), only the receipt-tail env var OPENROUTER_DISPATCH_RECEIPT_FILE,
// and of the base counter only the FALLBACK-row classification — the window-start boundary, the
// role/task/drill/attempt filters, the reason!=='timeout' strike (NO #361 privacy-block skip: the whole
// point), the #3073 timeout pairing with the ER-r1 F3 stop rule and the shared CONTINUE_CAP. The #3065
// OR-SEAT-SMOKE hollow/partial classification is OUT of the subset (no SMOKE rows in the #361 fixtures);
// the base and the fixed ledger agree on every input this overlay can be pointed at except a
// `reason=privacy-block` row, which is exactly the one-class divergence a mutant must have.

import fs from 'node:fs';

const STRIKE_TAIL_BYTES = 262144;
const CONTINUE_CAP = 3;

function readReceiptTail() {
  const file = process.env.OPENROUTER_DISPATCH_RECEIPT_FILE;
  if (!file) return '';
  try {
    const fd = fs.openSync(file, 'r');
    try {
      const size = fs.fstatSync(fd).size;
      const len = Math.min(size, STRIKE_TAIL_BYTES);
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, size - len);
      return buf.toString('utf8');
    } finally { fs.closeSync(fd); }
  } catch (e) { return ''; }
}

function receiptKv(line) {
  const kv = {};
  for (const tok of line.split(/\s+/)) { const eq = tok.indexOf('='); if (eq > 0 && !(tok.slice(0, eq) in kv)) kv[tok.slice(0, eq)] = tok.slice(eq + 1); }
  return kv;
}

const execMissingSide = (kv) => !kv.artifact || kv.artifact.startsWith('MISSING');

function windowStart(lines, task) {
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].startsWith('OR-SEAT-SMOKE ')) continue;
    const kv = receiptKv(lines[i]);
    if (kv.role !== 'executor' || kv.task !== task) continue;
    if (kv.drill === '1') continue;
    if (execMissingSide(kv)) continue;
    return i + 1;
  }
  return 0;
}

// #3073 ER-r1 F3 stop rule, mirrored from the base companionPostmortemEvidence: the pairing scan stops at
// the NEXT invocation-opening executor FALLBACK for the task (a lost POSTMORTEM must fail closed).
function companionPushed(lines, i, task, kv) {
  for (let j = i + 1; j < lines.length; j++) {
    if (lines[j].startsWith('OR-DISPATCH-FALLBACK ')) {
      const fkv = receiptKv(lines[j]);
      if (fkv.role === 'executor' && fkv.task === task && fkv.drill !== '1'
        && (!('attempt' in fkv) || fkv.attempt === '1')) break;
      continue;
    }
    if (!lines[j].startsWith('OR-DISPATCH-POSTMORTEM ')) continue;
    const pkv = receiptKv(lines[j]);
    if (pkv.role !== 'executor' || pkv.task !== task) continue;
    if (pkv.drill === '1') continue;
    if (pkv.reason !== 'timeout') continue;
    if ((pkv.attempt || '1') !== (kv.attempt || '1')) continue;
    return pkv.progress === 'pushed';
  }
  return false;
}

const [, , cmd, ...rest] = process.argv;
const o = {};
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) {
    const k = rest[i].slice(2);
    const next = rest[i + 1];
    if (next === undefined || next.startsWith('--')) { o[k] = ''; } else { o[k] = next; i++; }
  }
}
if (cmd !== 'zai-strikes' || o.role !== 'executor' || !o.task) { console.error('usage: pre361-egress-strike-overlay zai-strikes --task T --role executor'); process.exit(2); }

const lines = readReceiptTail().split('\n');
let n = 0, continues = 0;
for (let i = windowStart(lines, o.task); i < lines.length; i++) {
  if (!lines[i].startsWith('OR-DISPATCH-FALLBACK ')) continue;
  const kv = receiptKv(lines[i]);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  if ('attempt' in kv && kv.attempt !== '1') continue;
  // PRE-#361 behavior: `reason=privacy-block` falls in here and STRIKES — no skip clause exists yet.
  if (kv.reason !== 'timeout') { n++; continue; }
  if (companionPushed(lines, i, o.task, kv) && continues < CONTINUE_CAP) { continues++; continue; }
  n++;
}
console.log(String(n));
process.exit(0);
