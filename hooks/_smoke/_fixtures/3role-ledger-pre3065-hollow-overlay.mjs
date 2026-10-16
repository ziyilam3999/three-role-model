#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre3065-hollow-overlay.mjs — COMMITTED STATIC FIXTURE.
//
// Durable, hermetic RED-leg fixture for #3065 (plan .ai-workspace/plans/2026-10-15-3065-hollow-run-strike.md),
// following the SAME pattern as hooks/_fixtures/3role-ledger-pre3073-strikes-overlay.mjs /
// 3role-ledger-nocap-overlay.mjs: a minimal, in-pocket, no-git-dependency port of the PRE-#3065
// executorStrikeFacts, so the RED leg always runs for real (no pinned-SHA reachability requirement across a
// shallow CI checkout or the plugin repo's commit graph).
//
// MEASURED (not assumed) behavior at the #3065 base (hooks/3role-ledger.mjs executorStrikeFacts immediately
// before this ticket, #3073/#3093 merged): the reset window started after the LAST non-drill
// `OR-SEAT-SMOKE role=executor task=T` row WHATEVER its `artifact=` value, and the in-window scan classified
// only OR-DISPATCH-FALLBACK rows — an exit-0 executor close with no PR and nothing pushed wrote exactly such
// a SMOKE row, so the hollow close RESET the strike window (and a pushed-but-no-PR close counted nothing).
// That is the defect this fixture demonstrates the need for: on the receipts-exec-hollow-after-2.md fixture
// it prints 0 where the fixed ledger prints 3, and on receipts-exec-partial-x4.md it prints 0 where the
// fixed ledger prints 1.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs rule, and do NOT regenerate it from
// current code — the targeted runner (hooks/3065-hollow-strike-targeted-smoke.sh) and the #3065 block of
// 3role-ledger-smoke-test.sh assert this fixture's output DIFFERS from current code on identical inputs. If
// a future edit ever collapses the two to the same outcome, those guards go RED on purpose.
//
// Minimal subset: only the `zai-strikes --task T --role executor` verb (plain integer output), only the
// receipt-tail env var OPENROUTER_DISPATCH_RECEIPT_FILE, only the row kinds the strike window sees
// (FALLBACK / POSTMORTEM / SEAT-SMOKE / STRIKE-FORGIVE), and of the #3073/#3093 CONTINUE routes only the
// pushed-companion rule (the forgive line is out of this minimal subset, as the #3073 exemplar's header
// documents its own narrowing) — Rule 17 (mechanical, in-pocket, no git dependency) over
// faithfulness-by-bulk, same minimality call as the pre3073/nocap exemplars.

import fs from 'node:fs';

const STRIKE_TAIL_BYTES = 262144;
const CONTINUE_CAP = 3; // #3073 D3b — present at the pre-#3065 base too.

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

const evBasename = (v) => (v == null ? '' : String(v).split('/').pop());

// The pre-#3065 companion pairing (the #3073 ER-r1 F3 stop rule, verbatim shape).
function companionPostmortemEvidence(lines, i, task, kv) {
  let pm = null;
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
    pm = { progress: pkv.progress || null, evidence: pkv.evidence || null };
    break;
  }
  return pm;
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
if (cmd !== 'zai-strikes' || o.role !== 'executor' || !o.task) { console.error('usage: pre3065-hollow-overlay zai-strikes --task T --role executor'); process.exit(2); }

const lines = readReceiptTail().split('\n');
const forgiven = new Set();
for (const line of lines) {
  if (!line.startsWith('OR-STRIKE-FORGIVE ')) continue;
  const kv = receiptKv(line);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  if (kv.evidence) forgiven.add(evBasename(kv.evidence));
}
// PRE-#3065 RESET RULE (the defect): the window starts after the last non-drill executor SMOKE row
// whatever its artifact= value — a hollow close resets. SMOKE rows are NEVER classified in-window.
let start = 0;
for (let i = lines.length - 1; i >= 0; i--) {
  if (!lines[i].startsWith('OR-SEAT-SMOKE ')) continue;
  const kv = receiptKv(lines[i]);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  start = i + 1;
  break;
}
let n = 0, continues = 0;
for (let i = start; i < lines.length; i++) {
  if (!lines[i].startsWith('OR-DISPATCH-FALLBACK ')) continue;
  const kv = receiptKv(lines[i]);
  if (kv.role !== 'executor' || kv.task !== o.task) continue;
  if (kv.drill === '1') continue;
  if ('attempt' in kv && kv.attempt !== '1') continue;
  if (kv.reason === 'timeout') {
    const pm = companionPostmortemEvidence(lines, i, o.task, kv);
    const pushed = pm !== null && pm.progress === 'pushed';
    const forgivenHit = pm !== null && pm.evidence !== null && forgiven.has(evBasename(pm.evidence));
    if ((pushed || forgivenHit) && continues < CONTINUE_CAP) { continues++; continue; }
  }
  n++;
}
console.log(String(n));
process.exit(0);
