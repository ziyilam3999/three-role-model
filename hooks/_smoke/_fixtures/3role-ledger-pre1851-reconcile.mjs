#!/usr/bin/env node
// hooks/_fixtures/3role-ledger-pre1851-reconcile.mjs — COMMITTED STATIC FIXTURE (#1851).
//
// Durable, hermetic stand-in for the PRE-#1851 `reconcile-spawns` implementation (the O(G x corpus) defect
// #1851 fixes), so the red-arm legs of hooks/3role-ledger-smoke-test.sh's AC1/AC2 checks never depend on a
// git-object lookup that could be unreachable in a shallow CI checkout (mirrors the existing
// hooks/_fixtures/3role-ledger-pre1580-overlay.mjs precedent — same rationale, same no-git-dependency goal).
//
// MEASURED (not assumed) pre-#1851 behavior, extracted verbatim from `git show HEAD:hooks/3role-ledger.mjs`
// at the commit this fixture was authored against (origin/master @ f368f09ec, 2026-07-28 — the commit this
// PR branched from; verified byte-identical to the cited plan baseline `fbe7687b0` for every function below
// via `git diff fbe7687b0 f368f09ec -- hooks/3role-ledger.mjs`, which touches unrelated code only): the group
// loop in `cmdReconcileSpawns` called `resolveAgent(sess, task, role)` ONCE PER (task, role) GROUP, and
// `resolveAgent` re-`readdir`s + full-`readFileSync`s EVERY subagent transcript for the session on EACH call
// — one full corpus pass per group, i.e. O(G x corpus). `firstRecordText` took the whole-file string handed
// to it (already fully read) and split it on '\n' to find the first non-empty line — no bounded read exists
// in this era. `modelVersion` resolution (`resolveModelFields`) ran UNCONDITIONALLY every sweep (no
// `!prior.modelVersion` gate). The coarse watermark (a per-session mtime high-water mark) advanced
// UNCONDITIONALLY after every sweep, including one where a row failed. No per-file checkpoint of any kind
// existed. This fixture reproduces exactly that shape so the smoke's red arms can demonstrate the defect
// (and the ABSENCE of the new incremental capability) without needing `git show <old-sha>` to succeed.
//
// Do NOT hand-edit this file to match the live hooks/3role-ledger.mjs, and do NOT regenerate it from current
// code — the AC1/AC2 red arms in 3role-ledger-smoke-test.sh assert this fixture's behavior DIFFERS from
// current code (O(G x corpus) cost, no firstRecordsRead/firstRecordsCached counters at all). If a future
// edit ever collapses the two to identical outcomes, those guards go RED on purpose.
//
// Minimal subset: only the `reconcile-spawns` verb and its real dependency chain (sanitize, ledgerFile,
// firstRecordText, resolveAgent, resolveModelFields/transcriptModel/modelIdToTier, transcriptSelfAuthored,
// overlayAppend simplified to a same-round merge — these fixtures never pre-populate a terminal-evidence row,
// so #1575/#1580's guard machinery is irrelevant noise for this comparison — and a no-op fireResyncBackground
// stub). Deliberately NOT a full byte-for-byte port of the 3,300+-line file — Rule 17 (mechanical, in-pocket,
// no git dependency) over faithfulness-by-bulk, the same call the pre-#1580 fixture's own header makes.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();
const LEDGER_DIR = process.env.THREE_ROLE_LEDGER_DIR || path.join(HOME, '.claude', '3role-ledger');
const PROJECTS_ROOT = process.env.THREE_ROLE_PROJECTS_ROOT || path.join(HOME, '.claude', 'projects');
const REQUIRED_ROLES = ['planner', 'plan-review', 'executor', 'execution-review'];
const RECORDABLE_ROLES = [...REQUIRED_ROLES, 'research'];

function sanitize(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
function ledgerFile(session, task) { return path.join(LEDGER_DIR, sanitize(session), sanitize(task) + '.jsonl'); }
function fileExists(p) { try { return fs.statSync(p).isFile(); } catch (e) { return false; } }

// Pre-#1851 firstRecordText: takes the ALREADY-FULLY-READ whole-file string and splits on '\n' to find the
// first non-empty line. No bounded read of any kind exists at this era.
function firstRecordText(content) {
  const firstLine = String(content == null ? '' : content).split('\n').find((l) => l.trim());
  if (!firstLine) return '';
  let rec;
  try { rec = JSON.parse(firstLine); } catch (e) { return ''; }
  const msg = (rec && rec.message) || {};
  let text = '';
  if (typeof msg.content === 'string') text = msg.content;
  else if (Array.isArray(msg.content)) {
    for (const c of msg.content) { if (c && c.type === 'text' && typeof c.text === 'string') text += c.text; }
  }
  return text;
}

// Pre-#1851 resolveAgent: re-readdirs + full-readFileSync's EVERY transcript on EVERY call. This is the O(G
// x corpus) defect's engine — cmdReconcileSpawns below calls this ONCE PER GROUP.
function resolveAgent(session, task, role) {
  const sess = sanitize(session);
  const tag = '3ROLE_TASK:' + sanitize(task) + ' ROLE:' + sanitize(role);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return ''; }
  let best = null;
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
      if (!firstRecordText(content).includes(tag)) continue;
      if (!best || st.mtimeMs > best.mtimeMs) best = { agentId: m[1], mtimeMs: st.mtimeMs };
    }
  }
  return best ? best.agentId : '';
}

function modelIdToTier(modelId) {
  const s = String(modelId == null ? '' : modelId).toLowerCase();
  if (/^claude-opus-/.test(s)) return 'opus';
  if (/^claude-sonnet-/.test(s)) return 'sonnet';
  if (/^claude-haiku-/.test(s)) return 'haiku';
  if (/^claude-fable-/.test(s)) return 'fable';
  return '';
}

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

function resolveModelFields(session, task, role, explicitAgent) {
  try {
    const agentIdForModel = explicitAgent || resolveAgent(session, task, role);
    if (!agentIdForModel) return {};
    const modelId = transcriptModel(session, agentIdForModel);
    if (!modelId) return {};
    const fields = { modelVersion: modelId };
    const tier = modelIdToTier(modelId);
    if (tier) fields.modelTier = tier;
    return fields;
  } catch (e) { return {}; }
}

function transcriptSelfAuthored(file, role) {
  let content;
  try { content = fs.readFileSync(file, 'utf8'); } catch (e) { return false; }
  const roleRe = new RegExp('--role\\s+' + role);
  for (const ln of content.split('\n')) {
    if (!ln.trim()) continue;
    let j;
    try { j = JSON.parse(ln); } catch (e) { continue; }
    const isAsst = j && (j.type === 'assistant' || (j.message && j.message.role === 'assistant'));
    if (!isAsst) continue;
    const c = j.message && j.message.content;
    if (!Array.isArray(c)) continue;
    for (const blk of c) {
      if (!blk || blk.type !== 'tool_use') continue;
      if (String(blk.name || '').toLowerCase() !== 'bash') continue;
      const cmd = String((blk.input && blk.input.command) || '');
      if (/3role-ledger\.mjs[\s\S]*?\bappend\b/.test(cmd) && roleRe.test(cmd)) return true;
    }
  }
  return false;
}

// Simplified overlayAppend: a same-round merge onto the last same-role line (no #1575/#1580 terminal-evidence
// guard machinery — irrelevant here since these fixtures start from empty ledgers). Sufficient to reproduce
// the OUTPUT ROWS cmdReconcileSpawns below would write, which is all AC3's equivalence check needs.
function overlayAppend(session, task, role, fields) {
  const file = ledgerFile(session, task);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); } catch (e) { /* new file */ }
  const kept = [];
  let prior = null;
  for (const ln of lines) {
    try {
      const j = JSON.parse(ln);
      if (j && j.role === role) { prior = j; continue; }
      kept.push(ln);
    } catch (e) { kept.push(ln); }
  }
  const entry = { ...(prior || {}), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agentId' in fields) entry.agentId = fields.agentId;
  if ('artifact_path' in fields) entry.artifact_path = fields.artifact_path;
  if ('modelVersion' in fields) entry.modelVersion = fields.modelVersion;
  if ('modelTier' in fields) entry.modelTier = fields.modelTier;
  if ('self_authored' in fields) entry.self_authored = fields.self_authored;
  kept.push(JSON.stringify(entry));
  fs.writeFileSync(file, kept.join('\n') + '\n');
}

function fireResyncBackground() { /* no-op stub for the fixture -- resync side effects are out of scope here */ }

// ── #1229 pre-#1851 cmdReconcileSpawns, verbatim shape (O(G x corpus)) ──────────────────────────────────
function cmdReconcileSpawns(o) {
  try {
    const session = o.session;
    if (!session) { console.log('OK reconcile-spawns: no --session given (fail-open, nothing to do)'); process.exit(0); }
    const sess = sanitize(session);

    let slugs = [];
    try { slugs = fs.readdirSync(PROJECTS_ROOT); }
    catch (e) { console.log('OK reconcile-spawns: no projects root'); process.exit(0); }

    let newestMtime = 0;
    const transcripts = [];
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
        transcripts.push({ agentId: m[1], file: f, mtimeMs: st.mtimeMs });
        if (st.mtimeMs > newestMtime) newestMtime = st.mtimeMs;
      }
    }
    if (transcripts.length === 0) { console.log('OK reconcile-spawns: no subagent transcripts for session ' + sess); process.exit(0); }

    const watermarkFile = path.join(LEDGER_DIR, sess, '.reconcile-watermark');
    let lastWatermark = 0;
    try { lastWatermark = Number(fs.readFileSync(watermarkFile, 'utf8').trim()) || 0; } catch (e) { lastWatermark = 0; }
    if (newestMtime > 0 && newestMtime <= lastWatermark) {
      console.log('OK reconcile-spawns: session=' + sess + ' no new transcript activity since last sweep (watermark)');
      process.exit(0);
    }

    const groups = new Set();
    for (const t of transcripts) {
      let content;
      try { content = fs.readFileSync(t.file, 'utf8'); } catch (e) { continue; }
      const text = firstRecordText(content);
      if (!text) continue;
      const m = text.match(/3ROLE_TASK:(\S+) ROLE:(\S+)/);
      if (!m) continue;
      const task = sanitize(m[1]);
      const role = m[2];
      if (!task || !RECORDABLE_ROLES.includes(role)) continue;
      groups.add(task + ' ' + role);
    }

    let scanned = 0;
    let changed = 0;
    for (const key of groups) {
      const [task, role] = key.split(' ');
      scanned++;
      const agentId = resolveAgent(sess, task, role);
      if (!agentId) continue;

      const file = ledgerFile(sess, task);
      let lines = [];
      try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); } catch (e) { /* no ledger yet */ }
      let prior = null;
      for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role === role) prior = j; } catch (e) { /* skip */ } }

      if (prior && ('skip_reason' in prior)) continue;
      if (prior && prior.agentId && prior.agentId !== agentId) continue;

      const fields = {};
      let hasChange = false;
      if (!prior || !prior.agentId) { fields.agentId = agentId; hasChange = true; }

      const modelFields = resolveModelFields(sess, task, role, agentId);
      if (modelFields.modelVersion && (!prior || !prior.modelVersion)) { fields.modelVersion = modelFields.modelVersion; hasChange = true; }
      if (modelFields.modelTier && (!prior || !prior.modelTier)) { fields.modelTier = modelFields.modelTier; hasChange = true; }

      if (!prior || !prior.self_authored) {
        const tr = transcripts.find((t) => t.agentId === agentId);
        if (tr && transcriptSelfAuthored(tr.file, role)) { fields.self_authored = true; hasChange = true; }
      }

      if (!hasChange) continue;
      try { overlayAppend(sess, task, role, fields); changed++; }
      catch (e) { console.error('WARN reconcile-spawns: row ' + task + '/' + role + ' failed: ' + (e && e.message ? e.message : e)); }
    }

    try { fs.mkdirSync(path.dirname(watermarkFile), { recursive: true }); fs.writeFileSync(watermarkFile, String(newestMtime)); } catch (e) { /* best-effort */ }
    if (changed > 0) fireResyncBackground();
    console.log('OK reconcile-spawns: session=' + sess + ' scanned=' + scanned + ' changed=' + changed);
    process.exit(0);
  } catch (e) {
    console.log('OK reconcile-spawns: error (fail-open): ' + (e && e.message ? e.message : e));
    process.exit(0);
  }
}

// ── minimal CLI ──────────────────────────────────────────────────────────────────────────────────────────
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

const argv = process.argv.slice(2);
const cmd = argv[0];
const opts = parseArgs(argv.slice(1));
if (cmd === 'reconcile-spawns') cmdReconcileSpawns(opts);
else { console.log('usage: 3role-ledger-pre1851-reconcile.mjs reconcile-spawns --session S'); process.exit(1); }
