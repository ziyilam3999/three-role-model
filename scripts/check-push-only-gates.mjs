#!/usr/bin/env node
// scripts/check-push-only-gates.mjs — the PREVENTION half of #2205.
//
// WHAT #2205 WAS. `.github/workflows/ci.yml` carried a commit-message check scoped
// `if: github.event_name == 'push'`. The workflow triggers on BOTH push and pull_request, so that
// `if:` meant the check ran ONLY on the post-merge push — after the thing it purported to gate had
// already become irreversible. MEASURED: 17 of the last 20 origin/master first-parent commits failed
// it and it blocked exactly zero of them. A check that can only run after the irreversible step is a
// REPORTER, not a gate. Fixing the one step does nothing to stop the next one, so this lint exists.
//
// WHAT THIS FLAGS (fully mechanical, no judgment):
//   a step whose `if:` restricts it to the push event, inside a workflow that ALSO triggers on
//   pull_request. That combination is the exact shape of #2205 — the workflow is reachable pre-merge,
//   and the step deliberately opts out of that reachability.
//
// WHAT IT DELIBERATELY DOES NOT DECIDE. Whether a given push-only step is a GATE (bad) or a genuine
// post-merge action (fine: deploy, publish, tag, release, cache-warm, changelog) is irreducible
// judgment — no lint can read intent. So the escape is an ANNOTATION, not a heuristic: put
//
//     # push-only-ok: <reason, >= 20 chars>
//
// in the step's own body or in the comment lines immediately above it. That converts a silent
// structural defect into a one-line stated intent a reviewer can disagree with. This is the honest
// Rule-17 split: the TRIGGER is mechanical, the VERDICT stays human.
//
// WHY LINE-BASED, NOT A YAML PARSE. The plugin is zero-dependency by construction (see
// scripts/ci-validate.mjs), so there is no js-yaml. A line scan is also strictly better for this job:
// it can see the COMMENTS, which a YAML parse discards — and the comments carry the annotation.
//
// Exit 0 = clean. Exit 1 = at least one unannotated push-only step. Missing/empty workflow dir = clean
// (matches ci-validate.mjs's "empty globs PASS" bootstrap posture).

import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.env.PUSH_ONLY_GATE_ROOT
  || join(dirname(fileURLToPath(import.meta.url)), '..');
const WF_DIR = join(ROOT, '.github', 'workflows');

const MIN_REASON = 20;
const ANNOTATION = /#\s*push-only-ok:\s*(.+)$/;

function workflowFiles() {
  let names;
  try { names = readdirSync(WF_DIR); } catch { return []; } // no workflows yet -> clean
  return names.filter((n) => n.endsWith('.yml') || n.endsWith('.yaml')).sort();
}

// Does this workflow's `on:` block name pull_request? Handles the block form
//   on:
//     pull_request:
// and the inline list form `on: [push, pull_request]`.
// Scoped to the region before `jobs:` so a step that merely MENTIONS the string cannot fake it.
function triggersOnPullRequest(lines) {
  const jobsAt = lines.findIndex((l) => /^jobs:\s*$/.test(l));
  const head = jobsAt === -1 ? lines : lines.slice(0, jobsAt);
  return head.some((l) => {
    const bare = l.replace(/#.*$/, '');
    return /^\s*pull_request(_target)?\s*:/.test(bare)   // block form
        || /^on:\s*\[.*\bpull_request\b/.test(bare);      // inline list form
  });
}

// An `if:` that gates on the push event and never mentions pull_request. Both quote styles, and the
// `github.event_name != 'pull_request'` spelling, which is the same defect wearing a different hat.
function isPushOnlyCondition(value) {
  const v = value.trim();
  if (!/github\.event_name/.test(v)) return false;
  const positivePush = /github\.event_name\s*==\s*['"]push['"]/.test(v);
  const negativePr = /github\.event_name\s*!=\s*['"]pull_request['"]/.test(v);
  if (!positivePush && !negativePr) return false;
  // An `if:` that ALSO admits pull_request is not push-only — e.g.
  //   if: github.event_name == 'push' || github.event_name == 'pull_request'
  if (positivePush && /==\s*['"]pull_request['"]/.test(v)) return false;
  return true;
}

// Split a workflow into steps. A step starts at a `- name:`/`- uses:`/`- run:` list item and runs
// until the next list item at the SAME indent (or a dedent). Leading comment lines directly above the
// item belong to the step — that is where an annotation most naturally goes.
function stepsOf(lines) {
  const starts = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)-\s+(name|uses|run|id):/);
    if (m) starts.push({ i, indent: m[1].length });
  }
  return starts.map(({ i, indent }, k) => {
    // Body: to the next step start, or to a line that dedents out of the steps list.
    let end = k + 1 < starts.length ? starts[k + 1].i : lines.length;
    for (let j = i + 1; j < end; j++) {
      const l = lines[j];
      if (l.trim() === '') continue;
      const ind = l.length - l.trimStart().length;
      if (ind < indent) { end = j; break; }
    }
    // Preamble: contiguous comment lines immediately above.
    let pre = i;
    while (pre - 1 >= 0 && /^\s*#/.test(lines[pre - 1])) pre--;
    const nameLine = lines.slice(i, end).find((l) => /-?\s*name:/.test(l));
    return {
      startLine: i + 1,
      name: nameLine ? nameLine.replace(/^.*name:\s*/, '').trim() : '(unnamed step)',
      body: lines.slice(i, end),
      preamble: lines.slice(pre, i),
    };
  });
}

function annotationReason(step) {
  for (const l of [...step.preamble, ...step.body]) {
    const m = l.match(ANNOTATION);
    if (m) return m[1].trim();
  }
  return null;
}

const problems = [];
const notes = [];
let scanned = 0;
let pushOnlySeen = 0;

for (const file of workflowFiles()) {
  const abs = join(WF_DIR, file);
  const rel = relative(ROOT, abs);
  const lines = readFileSync(abs, 'utf8').split('\n');
  scanned++;

  if (!triggersOnPullRequest(lines)) {
    // A push-only WORKFLOW is out of scope by construction: it has no pre-merge reachability to
    // opt out of, so its steps cannot be committing this defect.
    notes.push(`skip ${rel} — workflow does not trigger on pull_request`);
    continue;
  }

  for (const step of stepsOf(lines)) {
    const ifLine = step.body.find((l) => /^\s*if:\s*/.test(l));
    if (!ifLine) continue;
    const cond = ifLine.replace(/^\s*if:\s*/, '');
    if (!isPushOnlyCondition(cond)) continue;
    pushOnlySeen++;

    const reason = annotationReason(step);
    if (reason === null) {
      problems.push(
        `${rel}:${step.startLine} — step "${step.name}" is scoped to the push event `
        + `(if: ${cond.trim()}) inside a workflow that ALSO runs on pull_request.\n`
        + `      If this step gates a merge, it CANNOT — it runs only after the merge lands (#2205).\n`
        + `      If it is a genuine post-merge action, say so:  # push-only-ok: <reason>`
      );
    } else if (reason.length < MIN_REASON) {
      problems.push(
        `${rel}:${step.startLine} — step "${step.name}" carries a push-only-ok annotation that is `
        + `too short to be a reason (${reason.length} chars, need >= ${MIN_REASON}): "${reason}"`
      );
    } else {
      notes.push(`allow ${rel}:${step.startLine} "${step.name}" — push-only-ok: ${reason}`);
    }
  }
}

for (const n of notes) console.log(n);
console.log(`scanned ${scanned} workflow file(s); ${pushOnlySeen} push-only step(s) found`);

if (problems.length) {
  console.error('');
  for (const p of problems) console.error(`FAIL: ${p}`);
  console.error(`\n${problems.length} unannotated push-only step(s). See #2205.`);
  process.exit(1);
}
console.log('ok: no unannotated push-only steps');
