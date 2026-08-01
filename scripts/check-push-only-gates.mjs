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

// The `on:` block, as a line range. Scoping matters in BOTH directions: a step that merely MENTIONS
// "pull_request" must not fake a trigger, and a real trigger must not be missed.
//
// This used to slice `lines[0..indexOf('jobs:')]`, which silently assumed `on:` always precedes
// `jobs:`. YAML mappings are UNORDERED and GitHub accepts them in any order, so a workflow that
// writes `jobs:` first left an empty head region -> no trigger found -> the ENTIRE file skipped
// while the job exited 0. That is the worst failure this file can have, and it was reachable by
// nothing more than key order (#2205 review round 2, blocker 3). Reproduced before the fix.
//
// Reading the actual block instead: from the top-level `on:` key to the next top-level key
// (column 0). Comments and blank lines inside the block are kept so the inline-list arm can still
// see a commented-out form, and the zero-indent anchor means a nested `on:` deep in a step cannot
// be mistaken for the trigger block.
function onBlock(lines) {
  const start = lines.findIndex((l) => /^["']?on["']?\s*:/.test(l));
  if (start === -1) return [];              // no `on:` at all -> no PR reachability
  const out = [lines[start]];
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.trim() === '' || /^\s*#/.test(l)) { out.push(l); continue; }
    if (/^\S/.test(l)) break;               // a new top-level key ends the block
    out.push(l);
  }
  return out;
}

// Does this workflow's `on:` block name pull_request? Handles the block form
//   on:
//     pull_request:
// and the inline list form `on: [push, pull_request]`.
function triggersOnPullRequest(lines) {
  const head = onBlock(lines);
  return head.some((l) => {
    const bare = l.replace(/#.*$/, '');
    return /^\s*pull_request(_target)?\s*:/.test(bare)              // block form
        || /^\s*-\s*pull_request(_target)?\s*$/.test(bare)          // block-SEQUENCE form
        || /^\s*["']?on["']?:\s*\[.*\bpull_request\b/.test(bare);   // inline list form
  });
}
// The two non-obvious spellings above are FALSE-NEGATIVE guards, and this is the highest-cost
// direction of error in this whole file: a missed trigger makes the checker skip the ENTIRE
// workflow ("skip -- does not trigger on pull_request"), so every push-only step in it goes
// unexamined while the job still exits 0.
//   * block-SEQUENCE `on:\n  - push\n  - pull_request` is valid YAML that GitHub accepts; the
//     block-form regex needs a trailing colon, so a bare `- pull_request` matched neither pattern.
//   * `"on":` -- YAML 1.1 folds bare `on` to boolean true, so writing it quoted is a real and
//     recommended style. It only ever mattered for the inline-list arm: the block-form arm keys off
//     the nested `pull_request:` line and never reads the parent key, so it was already immune.

// An `if:` that gates on the push event and never mentions pull_request. Both quote styles, and the
// `github.event_name != 'pull_request'` spelling, which is the same defect wearing a different hat.
function isPushOnlyCondition(value) {
  const v = value.trim();
  const positivePush = /github\.event_name\s*==\s*['"]push['"]/.test(v);
  const negativePr = /github\.event_name\s*!=\s*['"]pull_request['"]/.test(v);
  // A THIRD spelling of the same defect, and the one that reads least like it: on a push event
  // `github.event.pull_request` is null, so this is exactly "not a PR" wearing context-object
  // clothing instead of event_name clothing. The old `if (!/github\.event_name/) return false;`
  // early-exit made it structurally unreachable -- the condition never mentions event_name at all.
  //
  // `(?![\w.])` is LOAD-BEARING and replaces a `\b`, which was a live FALSE POSITIVE (#2205 review
  // round 2, blocker 2). `\b` is satisfied by the following `.`, so `!github.event.pull_request` also
  // matched inside `!github.event.pull_request.head.repo.fork` -- the standard fork guard -- and
  // inside `!github.event.pull_request.draft`. Both are PR-ONLY steps, the exact opposite of this
  // defect, and the only escape offered was a `# push-only-ok:` annotation, i.e. the lint demanded
  // the author write a false statement to get past it. A guard that can only be satisfied by lying
  // teaches people to disable it. The lookahead pins the match to the whole PR object, not a field
  // read off it. Reproduced before the fix.
  const nullPrContext = /github\.event\.pull_request(?![\w.])\s*==\s*null/.test(v)
    || /!\s*github\.event\.pull_request(?![\w.])/.test(v);
  // A FOURTH spelling, and per the round-2 review the commonest one in the wild: pinning the ref to
  // the default branch. On a pull_request event `github.ref` is `refs/pull/<n>/merge`, never
  // `refs/heads/<branch>`, so this is push-to-that-branch-only in effect even though it names
  // neither the event nor the PR object.
  const defaultBranchRef = /github\.ref\s*==\s*['"]refs\/heads\/[^'"]+['"]/.test(v);
  if (!positivePush && !negativePr && !nullPrContext && !defaultBranchRef) return false;
  // An `if:` that ALSO admits pull_request is not push-only — e.g.
  //   if: github.event_name == 'push' || github.event_name == 'pull_request'
  if ((positivePush || nullPrContext || defaultBranchRef)
      && /==\s*['"]pull_request['"]/.test(v)) return false;
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
  // Preamble start per step: the first line of the contiguous run of comments immediately above it.
  // Computed for ALL steps BEFORE any body, because a step's body must stop at the NEXT step's
  // preamble. Ending it at the next step's own start line (the original form) put those comment
  // lines inside BOTH steps -- and since annotationReason() scans [...preamble, ...body], step N's
  // `# push-only-ok:` comment silently exempted step N-1 as well. That is the #1590 monotonicity
  // shape: a justification written for one step erasing the gate on another. Reproduced before the
  // fix -- a step with NO annotation of its own passed because the next step had one.
  // BLANK LINES DO NOT BREAK THE ASSOCIATION. The first version walked up over CONTIGUOUS comment
  // lines only, so a single blank line between an annotation and the step it describes reopened the
  // exact leak this was written to close (#2205 review round 2, blocker 1):
  //
  //     - name: unannotated REAL GATE      <- gets the exemption it never earned
  //       if: github.event_name == 'push'
  //     # push-only-ok: publishes the release tag
  //                                        <- one blank line
  //     - name: publish                    <- gets flagged instead
  //
  // With the blank line present, the next step's walk-up stops immediately (its preamble is empty),
  // so its body starts at its own line -- which leaves the comment inside the PREVIOUS step's body,
  // and annotationReason() scans the body. The annotation and the flag land on opposite steps.
  // Reproduced live before this fix; the round-1 fixture differed by exactly one blank line and so
  // had no power over it.
  //
  // Walking up over blanks AND comments, and keeping the TOPMOST comment seen, associates the block
  // downward to the step it precedes. Over-claiming in this direction is the safe error: the worst
  // case is a trailing comment being read as the next step's preamble, which can only STRIP an
  // annotation from the step above (a loud false positive), never grant one it did not earn.
  const preStarts = starts.map(({ i }) => {
    let top = i;
    for (let j = i - 1; j >= 0; j--) {
      const t = lines[j].trim();
      if (t === '') continue;               // blank lines are transparent, not terminators
      if (t.startsWith('#')) { top = j; continue; }
      break;                                // real YAML content ends the preamble
    }
    return top;
  });
  return starts.map(({ i, indent }, k) => {
    // Body: to the next step's PREAMBLE, or to a line that dedents out of the steps list.
    // max(i+1, ...) keeps the body non-empty in the degenerate case.
    let end = k + 1 < starts.length ? Math.max(i + 1, preStarts[k + 1]) : lines.length;
    for (let j = i + 1; j < end; j++) {
      const l = lines[j];
      if (l.trim() === '') continue;
      const ind = l.length - l.trimStart().length;
      if (ind < indent) { end = j; break; }
    }
    const pre = preStarts[k];
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
// `scanned` counts files OPENED; `examined` counts files whose steps were actually inspected.
// They are reported separately because they answer different questions, and conflating them was a
// real gap (#2205 review round 2, blocker 3): `scanned++` runs BEFORE the not-PR-triggered `continue`
// below, so a file that was opened and immediately skipped still incremented it. A caller asserting
// only on `scanned` therefore proves the directory was READ, never that anything was CHECKED --
// and since a mis-detected trigger skips a whole file silently, that is precisely the state an
// oracle needs to be able to see. Reproduced: reordering `jobs:` above `on:` in a workflow carrying
// the verbatim #2205 defect kept `scanned 1` while examining nothing.
let examined = 0;
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
  examined++;

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
console.log(
  `scanned ${scanned} workflow file(s) (${examined} examined, ${scanned - examined} skipped as `
  + `not pull_request-triggered); ${pushOnlySeen} push-only step(s) found`
);

if (problems.length) {
  console.error('');
  for (const p of problems) console.error(`FAIL: ${p}`);
  console.error(`\n${problems.length} unannotated push-only step(s). See #2205.`);
  process.exit(1);
}
console.log('ok: no unannotated push-only steps');
