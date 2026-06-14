#!/usr/bin/env node
// CI validation for the three-role-model plugin.
// Pure node: builtins only, zero npm dependencies (matches the plugin itself).
// Checks (all must pass):
//   1. .claude-plugin/plugin.json parses and has the 3 required keys (name/description/version).
//   2. .claude-plugin/marketplace.json parses and lists a plugin named "three-role-model".
//   3. Every bin/**/*.mjs passes `node --check` (syntax).
//   4. Every bin/**/*.test.mjs runs to a clean exit (the bundled oracles).
// Defensive: empty globs PASS (the tree fills in across the build legs, not at bootstrap).

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const fail = (msg) => { console.error(`FAIL: ${msg}`); process.exitCode = 1; };
const ok = (msg) => console.log(`ok: ${msg}`);

function readJson(rel) {
  const p = join(ROOT, rel);
  return JSON.parse(readFileSync(p, 'utf8'));
}

function walk(dir, pred, out = []) {
  let entries;
  try { entries = readdirSync(dir); } catch { return out; } // missing dir -> empty
  for (const name of entries) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, pred, out);
    else if (pred(name)) out.push(full);
  }
  return out;
}

// 1. plugin.json
try {
  const m = readJson('.claude-plugin/plugin.json');
  for (const k of ['name', 'description', 'version']) {
    if (!m[k]) fail(`plugin.json missing required key "${k}"`);
  }
  if (m.name !== 'three-role-model') fail(`plugin.json name is "${m.name}", expected "three-role-model"`);
  if (process.exitCode !== 1) ok(`plugin.json valid (v${m.version})`);
} catch (e) { fail(`plugin.json: ${e.message}`); }

// 2. marketplace.json
try {
  const mk = readJson('.claude-plugin/marketplace.json');
  if (!Array.isArray(mk.plugins) || !mk.plugins.find((p) => p.name === 'three-role-model')) {
    fail('marketplace.json does not list a plugin named "three-role-model"');
  } else ok('marketplace.json lists three-role-model');
} catch (e) { fail(`marketplace.json: ${e.message}`); }

// 3. node --check every bin/**/*.mjs
const mjs = walk(join(ROOT, 'bin'), (n) => n.endsWith('.mjs') && !n.endsWith('.test.mjs'));
for (const f of mjs) {
  try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); }
  catch (e) { fail(`node --check ${f}: ${e.stderr?.toString() || e.message}`); }
}
ok(`node --check: ${mjs.length} bin script(s)`);

// 4. run every bin/**/*.test.mjs
const tests = walk(join(ROOT, 'bin'), (n) => n.endsWith('.test.mjs'));
for (const f of tests) {
  try { execFileSync(process.execPath, [f], { stdio: 'pipe' }); ok(`test passed: ${f}`); }
  catch (e) { fail(`test failed ${f}: ${e.stdout?.toString() || ''}${e.stderr?.toString() || e.message}`); }
}
if (!tests.length) ok('no bundled tests yet (bootstrap)');

if (process.exitCode === 1) { console.error('\nci-validate: FAILED'); }
else { console.log('\nci-validate: PASS'); }
