#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-nocap-overlay.mjs — COMMITTED STATIC FIXTURE.
//
// Durable, hermetic RED-leg fixture for #3073 D3b (plan .ai-workspace/plans/2026-10-09-3073-zai-legs-checkpoint.md),
// same pattern as hooks/_fixtures/3role-ledger-pre3073-strikes-overlay.mjs (the D3 twin): a minimal, in-pocket,
// no-git-dependency port of the D3 rule WITHOUT the CONTINUE cap, so the RED leg always runs for real.
//
// Demonstrated defect: an unbounded CONTINUE classification. Every `reason=timeout` invocation whose nearest
// following companion `OR-DISPATCH-POSTMORTEM` row carries `progress=pushed` is a CONTINUE, however many have
// already happened since the last OR-SEAT-SMOKE reset — so a leg that pushes one trivial commit per dispatch loops
// on z.ai forever without ever accruing the 2 strikes that would route it to the Sonnet fallback (the nr-3073-
// continue-trivial-push surface before the F3 cap). On the receipts-exec-timeout-pushed-x4.md fixture this prints 0
// where the capped ledger prints 1.
//
// Do NOT hand-edit this file to re-introduce a cap, and do NOT regenerate it from current code — the targeted
// runner (hooks/3073-strikes-targeted-smoke.sh) and the #3073 block of 3role-ledger-smoke-test.sh assert this
// fixture's output DIFFERS from current code on identical inputs. If a future edit ever collapses the two to the
// same outcome, those guards go RED on purpose.
//
// Minimal subset: only the `zai-strikes --task T --role executor` verb (plain integer output), the D3 companion
// lookup, and the same reset/attempt window semantics — Rule 17 (mechanical, in-pocket, no git dependency).

import fs from 'node:fs';

const STRIKE_TAIL_BYTES = 262144;

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

const [, , cmd, ...rest] = process.argv;
const o = {};
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) {
    const k = rest[i].slice(2);
    const next = rest[i + 1];
    if (next === undefined || next.startsWith('--')) { o[k] = ''; } else { o[k] = next; i++; }
  }
}
if (cmd !== 'zai-strikes' || o.role !== 'executor' || !o.task) { console.error('usage: nocap-overlay zai-strikes --task T --role executor'); process.exit(2); }

const lines = readReceiptTail().split('\n');
let start = 0;
for (let i = lines.length - 1; i >= 0; i--) {
  if (!lines[i].startsWith('OR-SEAT-SMOKE ')) continue;
  const kv = receiptKv(lines[i]);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  start = i + 1;
  break;
}
let strikes = 0;
for (let i = start; i < lines.length; i++) {
  if (!lines[i].startsWith('OR-DISPATCH-FALLBACK ')) continue;
  const kv = receiptKv(lines[i]);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  if ('attempt' in kv && kv.attempt !== '1') continue;
  if (kv.reason !== 'timeout') { strikes++; continue; }
  let progress = null;
  for (let j = i + 1; j < lines.length; j++) {
    if (!lines[j].startsWith('OR-DISPATCH-POSTMORTEM ')) continue;
    const pkv = receiptKv(lines[j]);
    if (pkv.role !== 'executor' || pkv.task !== o.task) continue;
    if (pkv.drill === '1') continue;
    if (pkv.reason !== 'timeout') continue;
    if ((pkv.attempt || '1') !== (kv.attempt || '1')) continue;
    progress = pkv.progress || null;
    break;
  }
  if (progress === 'pushed') continue; // NO CAP: every pushed timeout is a CONTINUE, forever.
  strikes++;
}
console.log(String(strikes));
process.exit(0);
