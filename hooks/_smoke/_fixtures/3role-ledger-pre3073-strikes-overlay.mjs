#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre3073-strikes-overlay.mjs — COMMITTED STATIC FIXTURE.
//
// Durable, hermetic RED-leg fixture for #3073 D3 (plan .ai-workspace/plans/2026-10-09-3073-zai-legs-checkpoint.md),
// following the SAME pattern as hooks/_fixtures/3role-ledger-pre1580-overlay.mjs / -pre1947-ma2-overlay.mjs: a
// minimal, in-pocket, no-git-dependency port of a PAST buggy countExecutorStrikes, so the RED leg always runs for
// real (no pinned-SHA reachability requirement across a shallow CI checkout or the plugin repo's commit graph).
//
// MEASURED (not assumed) behavior at the #3073 leg-1 base 62044cba7c (`git show 62044cba7c:hooks/3role-ledger.mjs`,
// lines ~7461-7476): countExecutorStrikes scanned backward from the receipt tail and counted EVERY invocation-opening
// non-drill `OR-DISPATCH-FALLBACK role=executor task=T` row as a strike — the companion `OR-DISPATCH-POSTMORTEM`
// row's `progress=` field was never consulted, so a z.ai leg that timed out AFTER pushing its checkpoint branch was
// still charged a strike and the 2-strike rule routed the NEXT leg to the Sonnet fallback. That is the defect this
// fixture's behavior demonstrates the need for: on the receipts-exec-timeout-pushed.md fixture it prints 1 where the
// fixed ledger prints 0.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs rule, and do NOT regenerate it from current
// code — the targeted runner (hooks/3073-strikes-targeted-smoke.sh) and the #3073 block of
// 3role-ledger-smoke-test.sh assert this fixture's output DIFFERS from current code on identical inputs. If a future
// edit ever collapses the two to the same outcome, those guards go RED on purpose.
//
// Minimal subset: only the `zai-strikes --task T --role executor` verb (plain integer output), only the receipt-tail
// env var OPENROUTER_DISPATCH_RECEIPT_FILE, only the row kinds the strike window sees (FALLBACK / SEAT-SMOKE) —
// Rule 17 (mechanical, in-pocket, no git dependency) over faithfulness-by-bulk, same minimality call as the
// #1833/#1947 exemplars.

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
if (cmd !== 'zai-strikes' || o.role !== 'executor' || !o.task) { console.error('usage: pre3073-strikes-overlay zai-strikes --task T --role executor'); process.exit(2); }

const lines = readReceiptTail().split('\n');
let n = 0;
for (let i = lines.length - 1; i >= 0; i--) {
  const line = lines[i];
  const isFb = line.startsWith('OR-DISPATCH-FALLBACK ');
  const isSm = line.startsWith('OR-SEAT-SMOKE ');
  if (!isFb && !isSm) continue;
  const kv = receiptKv(line);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  if (isSm) break;
  if (!('attempt' in kv) || kv.attempt === '1') n++;
}
console.log(String(n));
process.exit(0);
