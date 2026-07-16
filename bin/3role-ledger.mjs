#!/usr/bin/env node
// bin/3role-ledger.mjs — role-LEDGER helper. Bundled in the plugin under bin/; hooks resolve it via
// "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" (with a repo-relative ../bin fallback).
//
// A tiny CLI that records WHICH 3-role roles actually ran for a task and verifies them against the
// forgery-resistant signal the harness already produces: one transcript file per real subagent spawn
// (`~/.claude/projects/*/<session>/subagents/agent-<agentId>.jsonl`). The orchestrator cannot create
// that file without actually spawning, so binding a per-task role ledger to those files turns "I claim
// the planner ran" into a checkable boolean — the leg #850 needed.
//
// FLAT file (NOT under hooks/lib/) because setup.sh only symlinks flat hook files (a subdir is skipped);
// the gate finds it as a sibling via `dirname "${BASH_SOURCE[0]}"` whether run from the repo or the
// ~/.claude/hooks/ symlink.
//
// Subcommands:
//   append --session S --task T --role R [--agent A] [--artifact P] [--skip-reason "..."] [--oracle P]
//                                        [--verdict V] [--self-authored]
//                                        [--effort E] [--model-version V] [--model-tier T]      (#1466)
//                                        [--closed-at ISO]                                       (#1516)
//     --closed-at is an EXPLICIT overlay flag, written ONLY by three-role-subagent-ledger.sh (the sole
//     writer that fires exclusively at SubagentStop/close) — never inferred, never defaulted. It is the
//     research seat's punch-out signal for the agent-kanban board: a research row WITHOUT it is in-flight,
//     WITH it is done. Optional + additive on every role (check/checkRole never reference it).
//     Writes one JSONL line to <ledger-dir>/<S>/<T>.jsonl. Idempotent PER ROLE — re-appending the same
//     role UPDATES the line (drops the prior one), never duplicates. A role agent self-recording its OWN
//     line passes --artifact (and --verdict for review-roles) with NO --agent; the SubagentStop hook later
//     overlay-merges the harness-captured --agent (#855) and stamps --self-authored (#1100 item 3).
//     #1465 — EVERY append also best-effort resolves + overlays two OPTIONAL model-provenance fields:
//     modelVersion (transcriptModel() over the resolved agentId — --agent when given, else
//     resolveAgent(session, task, role)) and modelTier (modelIdToTier(modelVersion)). Fail-open + back-compat:
//     absent inputs simply omit the fields; check/checkRole never reference them. Centralizing this in
//     cmdAppend means the SubagentStop hook's EXISTING stop-time `append --agent`
//     (three-role-subagent-ledger.sh) automatically re-resolves the model against the by-then-COMPLETE
//     transcript with zero hook edit — the free backfill for a self-append that ran too early to see
//     `message.model`. This transcript auto-capture is OBSERVED and always wins when a message.model line
//     exists yet (i.e. it overwrites an --model-version/--model-tier passed on the SAME call, in the rare case
//     both are present) — normally the two never co-occur (see below).
//     #1466 — `--effort`/`--model-version`/`--model-tier` are EXPLICIT overlay flags, the ONLY way any of the
//     three provenance fields get written now (the #1465 ambient `process.env.CLAUDE_EFFORT` auto-capture is
//     REMOVED — it stamped the ORCHESTRATOR's session effort on every append, including a close-out with no
//     effort opinion of its own, clobbering a role's real per-role effort the instant the orchestrator's own
//     effort differed). Two callers use them: the spawn-time hook (three-role-spawn-ledger.sh) passes all
//     three as the role's ASSIGNED {tier, version, effort} (resolved from config/cc-roles.env, known up front);
//     the close-time hook (three-role-subagent-ledger.sh) passes ONLY --effort as the OBSERVED
//     `effort.level` from its SubagentStop payload (modelVersion/modelTier at close stay on the transcript
//     auto-capture path above, unchanged). Every OTHER append (self-record, close-out --artifact) passes NONE
//     of the three, so overlayAppend's per-key "provided" discipline (#855) PRESERVES whatever a role's real
//     line already carries — an orchestrator's --artifact-only close-out can never clobber a role's effort.
//   check --session S --task T [--require-provenance]
//     Exit 0 (+ "OK ...") iff all four required roles (planner, plan-review, executor, execution-review)
//     are present AND satisfied; otherwise exit 2 (+ "BLOCK: <reason>"). A role is satisfied by EITHER
//     (a) an agentId that resolves to a real subagent transcript AND a well-shaped artifact, OR (b) an
//     explicit, SPECIFIC inline-skip reason. execution-review is NEVER inline-skippable — it needs a real
//     reviewer agentId OR a test-oracle path that exists with a PASS/verdict token. A real-spawn role line
//     lacking the self_authored stamp is SURFACED as a "PROVENANCE:" flag (still exit 0); --require-provenance
//     promotes a missing stamp to a BLOCK.
//   check --session S --task T --enforce-tracked-artifacts                                    (#1509)
//     Leg A — TRACKED, not merely present. Opt-in (base `check` stays existence-only — ~29% of the real
//     .ai-workspace/plans+reviews backlog is present-but-untracked today, so making this the DEFAULT would
//     brick most closes; only the completion-time instrumentation gate passes this flag). For the THREE
//     disk-path roles (planner, plan-review, execution-review) whose base check already resolved a real
//     on-disk artifact (or oracle) path: HARD-BLOCKs (a "TRACKED:" problem, => exit 2) when that path exists
//     on disk but is NOT git-tracked (`git ls-files --error-unmatch` over the file's own containing repo —
//     exit 0/staged = tracked, exit 1 = untracked => BLOCK, any other exit e.g. 128/no-repo => can't-tell =>
//     fail-open, never a false block on an environment hiccup). executor is EXEMPT from Leg A, keyed on
//     ROLE (its legitimate artifact is a PR URL / sha / branch, never existence/tracked-checked) — but when
//     the executor row resolves to an EXISTING disk path anyway (the #1494 shape: a PR-ref-shaped role citing
//     a plan file), that is SURFACED as a "NOTE-EXECUTOR:" line (never a block — a 62/246-task measured-false
//     invariant means artifact_path alone cannot distinguish #1494's mis-citation from 62 shipped conventions;
//     kind/authorship discrimination is #1532). No grace/bypass flag on this leg by design (a `*_OFF` here
//     would reopen the #1509 leak); the ONLY escapes are (a) `git add`+commit the cited artifact, or (b) the
//     pre-existing master THREE_ROLE_INSTRUMENT_OFF=1 that already disables the whole gate family.
//   resolve-agent --session S --task T --role R
//     Prints the agentId (basename of the `agent-<id>.jsonl` transcript) of the NEWEST-mtime subagent
//     transcript under <projects-root>/*/<S>/subagents/ whose content carries the literal spawn tag
//     `3ROLE_TASK:<T> ROLE:<R>` (#860). Exit 0 with the agentId on stdout when a match exists; prints
//     nothing + exits non-zero when no transcript carries the tag. Newest-mtime (not first-match) because a
//     tag can repeat across transcripts (an earlier probe/retry reusing a role tag), so the most recent
//     write is the real role spawn — a bare first-match/head -1 can grab a stale probe.
//   resolve-artifact --session S --task T --role R                  (#1303)
//     Prints the existence-checked ABSOLUTE artifact_path for ONE role of ONE task on stdout, then exit 0.
//     Reuses ledgerFile() + resolveArtifact() (the SAME parse cmdCheck/cmdInherit use — last line per role
//     wins). Exits NON-ZERO (printing nothing) on EVERY "no usable artifact" branch: no ledger file, no line
//     for the role, an absent/empty/whitespace artifact_path (e.g. an inline-skip line), or a dangling path
//     that does not resolve on disk. The instrumentation gate calls this to resolve the planner / plan-review
//     docs (cairn legs 4a/4b) LEDGER-FIRST — the non-zero exit is the "ledger has no usable artifact_path ->
//     fall back to the convention dir" contract (#1266 wrong-dir + stale-newest fix). A `verdict:` field on
//     the line is ignored; only artifact_path is read.
//   heartbeat --session S --task T                                 (#1350)
//     LEADING-EDGE lane liveness: bump the <task>.jsonl file MTIME to ~now so agent-kanban's swimlane
//     liveness counter (which stats <ledgerDir>/<session>/<task>.jsonl mtime via ledgerMtimeByTaskId →
//     updatedAt = max(mtimeMs, ledgerMtimeMs) → computeActiveIds secondary-window test) sees the lane as
//     LIVE the instant a role is SPAWNED — not only when a role COMPLETES (the trailing-edge append).
//     Writes NO JSONL line: if <task>.jsonl exists it is utimes-touched in place (content untouched); if
//     absent it is created as a ZERO-byte file. Because no line is written there is nothing for
//     overlayAppend to merge/drop/clobber, so a subsequent real append/check/resolve-artifact reads the
//     file byte-correctly — AC-4 (no overlay/close corruption) is true BY CONSTRUCTION. ALWAYS exits 0
//     (fail-open) — a heartbeat error must NEVER wedge the spawn it instruments.
//   refresh-models --session S                                     (#1481)
//     IN-FLIGHT model backfill: the missing TRIGGER the #1481 root-cause identified (cmdAppend's model
//     capture already exists and is green today; there was simply no event that RE-INVOKED it between a
//     background role spawn and SubagentStop). Walks every task ledger under <LEDGER_DIR>/<S>/*.jsonl and,
//     for each REQUIRED-role line that (a) is not inline-skipped, (b) LACKS a modelVersion yet, and (c)
//     resolves an agentId (its own --agent, else resolveAgent(session, task, role) by tag), re-resolves the
//     model via the SAME resolveModelFields() helper cmdAppend uses (reuse, not a re-implementation) and
//     overlay-appends ONLY {modelVersion[, modelTier]} — agentId/artifact_path/effort/verdict/self_authored
//     are left untouched (overlayAppend's per-key "provided" discipline, #855). Idempotent, absent->present
//     ONLY: a role that already carries a modelVersion is never re-touched. Fires kanban-resync.sh
//     (backgrounded, fail-open) exactly ONCE per invocation, and ONLY when >=1 role actually flipped
//     absent->present (no-change scans never resync — bounds the extra board-upload cost). ALWAYS exits 0
//     (fail-open) — a refresh error must never wedge its caller (a backgrounded hook trigger).
//   resolve-role-model --role R [--with-effort] [--with-version]    (#1448, --with-version #1466)
//     Prints the configured model TIER for role R (opus|sonnet|haiku|fable) from config/cc-roles.env — the
//     single command the orchestrator and both model hooks consume. Fail-SAFE: a missing/malformed config OR
//     an invalid per-role value => opus (never fail-open-to-cheap). --with-effort ALONE prints "<model>
//     <effort>" (or bare "<model>" if no effort is configured — UNCHANGED #1448 shape, back-compat). --with-
//     version ALONE prints "<model> <version>" (the role's ASSIGNED concrete pin — roleVersionFromCfg's
//     CC_TIER_<TIER>_VERSION, falling back to the tier alias itself when no pin is configured, so this token
//     is NEVER empty). BOTH together print "<model> <effort-or-'-'> <version>" (a `-` sentinel fills a
//     genuinely-unset effort so a plain `read -r A B C` always gets exactly 3 well-formed tokens — the
//     spawn-time badge stamp is the caller). Lints the config on read (loud INVALID-MODEL / Fable stderr
//     warnings). Always exits 0.
//   check --session S --task T --enforce-role-models               (#1448 + #1458)
//     The --enforce-role-models flag (opt-in; only the instrumentation gate passes it) adds a per-role
//     MODEL-POLICY leg: for each role that resolves to a real transcript, compare its ACTUAL model
//     (message.model, forgery-resistant) to cc-roles.env's tier; a mismatch => exit 2. No config => skip
//     (fail-safe). Fable->Opus silent reroute is OK. Kill-switch CC_ROLE_MODEL_GATE_OFF=1.
//     #1458 MODEL-VERSION sub-leg (assert-latest / fail-on-drift): when a role's tier matches AND a concrete
//     version pin is configured for that tier/role (CC_TIER_<TIER>_VERSION or the CC_ROLE_<ROLE>_MODEL_VERSION
//     override), the ACTUAL transcript model id is compared to the pin — a mismatch pushes a `MODEL-VERSION:`
//     problem (=> exit 2). No pin configured => the version sub-leg is DORMANT for that role (tier leg alone
//     still enforces). Fail-CLOSED on can't-tell (unreadable/unparseable transcript model) ONLY when a pin is
//     present. Dedicated kill-switch CC_ROLE_VERSION_GATE_OFF=1 (skips ONLY the version sub-leg;
//     CC_ROLE_MODEL_GATE_OFF=1 still disables the whole model+version leg). Completion-time ONLY — the
//     leading-edge spawn gate sees a tier ALIAS, never a concrete version, so it cannot check this.
//   resolve-effective-tier --model M --subagent-type T --transcript P [--session S] [--agents-dir D]
//                          [--projects-root R]                      (#1494)
//     The EFFECTIVE-TIER SENSOR: resolves the tier a spawn will ACTUALLY run on, by reading the current
//     session's OWN transcript tail — never by assuming a hardcoded default. Fixes the leading-edge gate's
//     bug (a badge-less spawn's effective tier was hardcoded to "opus", so under a Fable session it silently
//     satisfied the opus seats' policy check while all four roles actually ran Fable). Precedence: (1) an
//     explicit --model wins outright; (2) else the last `isSidechain:false` assistant message.model in
//     --transcript (a bounded, grow-with-cap reverse-tail read via lastAssistantModelFromFile — never reads
//     the whole transcript file); (3) else tier='unknown'. Agent-def frontmatter (--subagent-type +
//     --agents-dir) is reported as provenance (`agentdefTier`) but NEVER decides `tier` (UNVERIFIED whether
//     it overrides session inheritance). Prints "<tier> <source> agentdef=<tier|none>" on stdout, ALWAYS
//     exits 0 (like resolve-role-model — a resolver error must never wedge the caller; it fails CLOSED to
//     tier=unknown internally, which is the CALLER's cue to block). `tier ∈ {opus,sonnet,haiku,fable,unknown}`;
//     the caller (three-role-model-policy-gate.sh) treats `unknown` as a named BLOCK arm — it does NOT
//     default to opus (the fail-safe direction the #1448 leading-edge gate got backwards for Fable sessions).
//     Exported (`resolveEffectiveTier`, `lastAssistantModelFromFile`) for #1497's Key-1 role-eligibility
//     check to consume directly instead of re-parsing spawn payloads.
//   inherit-plan-review --session S --task T --parent P            (#881)
//     Inherit the PARENT (P) planner + plan-review ledger lines onto the LEG (T) — but ONLY if the parent
//     genuinely has a real, TRANSCRIPT-BACKED planner AND plan-review (same checkRole `check` uses; an
//     inline-skipped parent entry is rejected because the session-bound carve-out does not transfer to a leg).
//     Verify-then-write, fail-closed: a missing / forged / inline-skipped parent review prints
//     "BLOCK: cannot inherit ..." to stderr, exits 3, and writes NOTHING. On success appends both parent
//     entries (verbatim agentId + artifact_path, plus `inherited_from: P`) through the overlay-merge path so a
//     later real per-leg review overwrites cleanly; prints "OK inherited ..." and exits 0.
//     #1575 — THREE additional fail-closed preconditions (verify-then-write, before EITHER overlayAppend
//     write): (1) the parent's PLANNER artifact must NAME the leg task id (parent-leg relation); (2) the
//     parent's plan-review verdict must be AFFIRMATIVE (PASS|APPROVE|APPROVE-WITH-NOTES); (3) the LEG's own
//     plan-review row must NOT already carry a verdict (leg terminality — a hand-me-down never papers over a
//     completed per-leg review). The successful plan-review write now ALSO carries the parent's verdict (the
//     gate's universal screen reads it).
//   gate-plan-review --session S --task T                            (#1575)
//     The TRANSITION GATE's entire plan-review-ADMISSION decision (hooks/three-role-transition-gate.sh shells
//     out to this instead of re-implementing the contract). Evaluates the LAST PARSEABLE plan-review line in
//     the task's ledger (last-match, not first-match — #1580-safe); fail-closed on any UNPARSEABLE line
//     trailing it (junk-line class); runs a universal verdict ALLOWLIST screen (PASS|APPROVE|
//     APPROVE-WITH-NOTES, never a denylist) FIRST, on every arm; then two sanctioned arms — (1) completed-
//     review: affirmative verdict + closedAt + an agentId SPAWN-RECORD-bound (agentBoundToTag(), never
//     resolveAgent()/newest-mtime) to `3ROLE_TASK:<task> ROLE:plan-review`; (2) inherited-review: the same
//     binding test keyed on the row's own `inherited_from`. There is NO skip arm (operator decision — a
//     deliberate skip never satisfies this gate). Exit 0 (ALLOW, silent) or exit 2 (BLOCK, stderr
//     "BLOCK:<class>|<ledger-file-and-line>" naming one of seven classes: not-finished / no-verdict /
//     negative-verdict / no-bound-reviewer-spawn / inherited-row-unbound-to-parent / deliberate-skip-closed /
//     junk-line).
//
// Env overrides (mirror DOGFOOD_GATE_STORE so a smoke can point at a fixture tree):
//   THREE_ROLE_LEDGER_DIR    (default ~/.claude/3role-ledger)
//   THREE_ROLE_PROJECTS_ROOT (default ~/.claude/projects)
//   CC_ROLES_ENV             (#1448) — explicit per-role-model config path. When SET it is AUTHORITATIVE +
//                            TERMINAL (never falls through to ~/.config / plugin / repo defaults), so a smoke
//                            sets CC_ROLES_ENV=/nonexistent to simulate "no config" (=> every role opus).
//   CC_ROLE_MODEL_GATE_OFF=1 (#1448) — skip the --enforce-role-models MODEL-POLICY leg (feature kill-switch).
//   CC_ROLE_VERSION_GATE_OFF=1 (#1458) — skip ONLY the version-pin (assert-latest) sub-leg of
//                            --enforce-role-models; CC_ROLE_MODEL_GATE_OFF=1 still disables the whole leg.
//   CC_TIER_SENSOR_TAIL_BYTES (#1494) — lastAssistantModelFromFile()'s initial reverse-tail read window
//                            (default 4MB — big enough to fit a single ~0.8MB transcript record with margin).
//   CC_TIER_SENSOR_CAP_BYTES (#1494) — the grow-with-cap ceiling (default 64MB); exceeding it without a
//                            parseable last-assistant record resolves tier='unknown' (fail-closed).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const HOME = os.homedir();
const LEDGER_DIR = process.env.THREE_ROLE_LEDGER_DIR || path.join(HOME, '.claude', '3role-ledger');
const PROJECTS_ROOT = process.env.THREE_ROLE_PROJECTS_ROOT || path.join(HOME, '.claude', 'projects');

const REQUIRED_ROLES = ['planner', 'plan-review', 'executor', 'execution-review'];
// #1495 — RECORDABLE_ROLES is a STRICT SUPERSET used ONLY by cmdAppend's role guard, so the ad-hoc
// research/search seat can be ledger-visible (recorded) without ever becoming a required/gating role.
// Every completion-time loop (cmdCheck, --enforce-role-models, provenance, cmdRefreshModels) MUST keep
// iterating REQUIRED_ROLES, never this superset — that is what keeps a research row non-gating (G1).
const RECORDABLE_ROLES = [...REQUIRED_ROLES, 'research'];
// A plan is recognized by a MARKDOWN HEADING (2-4 `#`) naming an acceptance-criteria / ELI5 section.
// Anchored to a heading-line start (`^#{2,4}` + `m` flag) so prose that merely contains the word
// "acceptance" ("we await acceptance from QA") can NEVER match — only a real heading does. Accepts the
// natural variants planners actually write: `## ELI5`, `### Binary AC`, `## Binary acceptance criteria`,
// `### Acceptance criteria`, `## Acceptance`, `## AC`. The `ac\b` boundary keeps the second arm from
// half-matching the "Ac" of "Acceptance" — it falls through to the `acceptance` arm (#855).
const PLAN_RE = /^#{2,4}[ \t]*(eli5|(binary[ \t]+)?ac\b|(binary[ \t]+)?acceptance([ \t]+criteria)?\b)/im;
const VERDICT_RE = /(PASS|FAIL|APPROVE|verdict|##\s*Review)/i;
// Non-specific / placeholder skip reasons that are NOT acceptable (the carve-out is for genuinely
// inseparable-from-session-state work; "ran it inline myself" is not a valid skip — documented in the
// block message). Keep permissive: only empty/whitespace + a tiny denylist of obvious non-reasons.
const NONSPECIFIC_RE = /^(n\/?a|skip(ped)?|none|null|tbd|inline|-+|\.+)$/i;

function sanitize(s) { return String(s == null ? '' : s).replace(/[^0-9A-Za-z._-]/g, ''); }
function ledgerFile(session, task) {
  return path.join(LEDGER_DIR, sanitize(session), sanitize(task) + '.jsonl');
}
function fileExists(p) { try { return fs.statSync(p).isFile(); } catch (e) { return false; } }
function fileHas(p, re) { try { return re.test(fs.readFileSync(p, 'utf8')); } catch (e) { return false; } }

// ── #1448 per-role MODEL POLICY (config resolution + transcript-model read + lint) ─────────────────────
// The interactive 4-role chain staffs every seat with Opus by default (a spawn today carries model=(none), so
// each role inherits the session model). config/cc-roles.env maps each role -> a model TIER; this block reads
// it (fail-SAFE to opus), reads the FORGERY-RESISTANT actual model from the role's subagent transcript
// (message.model), and lints the config. MODEL is the only mechanically-enforced dimension (effort is not
// recorded in the transcript). See .ai-workspace/plans/2026-07-03-1448-per-role-model-policy.md.
const ROLE_MODELS = ['opus', 'sonnet', 'haiku', 'fable'];

// Ledger role -> config-key STEM (hyphen->underscore, upper): plan-review -> PLAN_REVIEW, execution-review ->
// EXECUTION_REVIEW, executor -> EXECUTOR. ORCHESTRATOR has a policy/lint entry but is NOT transcript-enforced.
function roleKeyStem(role) { return String(role == null ? '' : role).toUpperCase().replace(/-/g, '_'); }

// Resolve the cc-roles.env config file path. First hit wins across the chain, with ONE override rule:
//   CC_ROLES_ENV, when SET, is AUTHORITATIVE + TERMINAL — it selects EXACTLY that file and NEVER falls through
//   to the machine/plugin/repo defaults. So a smoke simulates "no config" with CC_ROLES_ENV=/nonexistent (or
//   /dev/null) and gets the fail-safe all-opus path without leaking the repo's own config/cc-roles.env
//   (AC-3 / green-gate: CC_ROLES_ENV=/dev/null => opus for every role).
//   Unset CC_ROLES_ENV: ~/.config/cc-roles.env -> ${CLAUDE_PLUGIN_ROOT}/config/cc-roles.env -> the
//   realpath-resolved repo config -> none => '' (=> every role opus).
// The fs.realpathSync step is LOAD-BEARING (defect-1b): setup.sh installs THIS helper as a SYMLINK at
// ~/.claude/hooks/3role-ledger.mjs -> the repo file. A naive import.meta.url join resolves ../config to
// ~/.claude/config (does NOT exist) -> silent all-opus on every real invocation while passing every
// worktree-run smoke. realpathSync walks THROUGH the symlink to the real repo file FIRST, so ../config lands
// in the repo. AC-4 exercises this via the installed symlink from a cwd outside the repo.
function resolveConfigPath() {
  if ('CC_ROLES_ENV' in process.env) {
    const p = process.env.CC_ROLES_ENV;
    return (p && fileExists(p)) ? p : '';
  }
  const cands = [path.join(HOME, '.config', 'cc-roles.env')];
  if (process.env.CLAUDE_PLUGIN_ROOT) cands.push(path.join(process.env.CLAUDE_PLUGIN_ROOT, 'config', 'cc-roles.env'));
  let selfDir;
  try { selfDir = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))); }
  catch (e) { selfDir = path.dirname(fileURLToPath(import.meta.url)); }
  cands.push(path.join(selfDir, '..', 'config', 'cc-roles.env'));
  for (const c of cands) { if (c && fileExists(c)) return c; }
  return '';
}

// Parse a shell-env KEY=VALUE file into a plain object (# comments + blanks dropped; optional surrounding
// quotes stripped). Never throws — an unreadable file returns {}.
function parseEnvFile(filePath) {
  const out = {};
  let raw;
  try { raw = fs.readFileSync(filePath, 'utf8'); } catch (e) { return out; }
  for (const line of raw.split('\n')) {
    const s = line.trim();
    if (!s || s.charAt(0) === '#') continue;
    const eq = s.indexOf('=');
    if (eq < 0) continue;
    const k = s.slice(0, eq).trim();
    let v = s.slice(eq + 1).trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1);
    if (k) out[k] = v;
  }
  return out;
}

// Load the config ONCE per command invocation. { found, cfg, configPath }. found=false => no config resolved.
function loadRoleConfig() {
  const configPath = resolveConfigPath();
  if (!configPath) return { found: false, cfg: {}, configPath: '' };
  return { found: true, cfg: parseEnvFile(configPath), configPath };
}

// Resolve a role's model TIER from an already-parsed cfg, fail-SAFE to opus (missing OR invalid => opus).
function roleModelFromCfg(cfg, role) {
  const raw = cfg['CC_ROLE_' + roleKeyStem(role) + '_MODEL'];
  return ROLE_MODELS.includes(raw) ? raw : 'opus';
}
function roleEffortFromCfg(cfg, role) {
  const v = cfg['CC_ROLE_' + roleKeyStem(role) + '_EFFORT'];
  return v == null ? '' : String(v);
}

// #1458 — Resolve a role's VERSION PIN from an already-parsed cfg: a per-ROLE override
// (CC_ROLE_<ROLE>_MODEL_VERSION) wins when present; else the per-TIER pin (CC_TIER_<TIER>_VERSION) for the
// role's expected tier; else '' (NO PIN => the version sub-leg is DORMANT for that role — the tier leg alone
// still enforces). This is an ASSERTION knob (validate against a concrete claude-* id), never a SELECTION
// knob — the spawn alias cannot choose an old version, so there is nothing to "select" here.
function roleVersionFromCfg(cfg, role, expectedTier) {
  const roleOverride = cfg['CC_ROLE_' + roleKeyStem(role) + '_MODEL_VERSION'];
  if (roleOverride) return roleOverride;
  const tierPin = cfg['CC_TIER_' + String(expectedTier || '').toUpperCase() + '_VERSION'];
  return tierPin || '';
}

// Config LINT (defect-3 + Fable guards) — emits stderr warnings; the pass/fail is unaffected (the gate's
// `expected` fails SAFE to opus, so a garbage value collapses to opus at the gate and CANNOT be caught there —
// VISIBILITY is entirely the lint's job). Fires on EVERY config read (every resolve-role-model + every enforce
// check + every spawn-hook call). Call ONCE per invocation (loud, not 5x). THREE warn classes:
//   1. INVALID-MODEL — a present *_MODEL whose value is not a known tier (typo / empty). The silent-overpay guard.
//   2. FABLE-ON-ORCHESTRATOR — the always-on seat pinned to fable (never-pin; refuse/warn).
//   3. FABLE-COST-CLIFF — any VALID *_MODEL=fable (post-July-7 subsidy-cliff cost warning).
function lintRoleConfig(cfg) {
  for (const k of Object.keys(cfg)) {
    const m = k.match(/^CC_ROLE_(.+)_MODEL$/);
    if (!m) continue;
    const val = cfg[k];
    if (!ROLE_MODELS.includes(val)) {
      process.stderr.write('INVALID-MODEL cc-roles.env: ' + k + '="' + val + '" is not a known tier ' +
        '(opus|sonnet|haiku|fable) — falling back to opus (you are paying OPUS rates while thinking you set "' +
        val + '").\n');
      continue;   // an invalid value is not also a fable warning.
    }
    if (val === 'fable') {
      if (m[1] === 'ORCHESTRATOR') {
        process.stderr.write('FABLE-ON-ORCHESTRATOR cc-roles.env: ' + k + '=fable — refusing to pin the ' +
          'always-on orchestrator seat to Fable (2x Opus, high-frequency; burns the subsidised bar fast). ' +
          'The orchestrator is documented opus-only.\n');
      }
      process.stderr.write('FABLE-COST-CLIFF cc-roles.env: ' + k + '=fable — Fable\'s subsidised usage bar ' +
        'expires ~July 7-8; after that a Fable-pinned seat bills out-of-pocket (~2x Opus). Use Fable only for ' +
        'the hardest one-off plans, never a standing seat.\n');
    }
  }
  // #1458 INVALID-VERSION — a present CC_TIER_*_VERSION or CC_ROLE_*_MODEL_VERSION pin whose non-empty value
  // does not look like a concrete claude-* model id. Visibility-only (mirrors INVALID-MODEL's doctrine): the
  // version leg will treat the malformed value as a literal pin and will very likely FAIL every run against it.
  for (const k of Object.keys(cfg)) {
    const isVersionKey = /^CC_TIER_[A-Z]+_VERSION$/.test(k) || /^CC_ROLE_.+_MODEL_VERSION$/.test(k);
    if (!isVersionKey) continue;
    const val = cfg[k];
    if (val && !/^claude-/.test(val)) {
      process.stderr.write('INVALID-VERSION cc-roles.env: ' + k + '="' + val + '" does not look like a concrete ' +
        'claude-* model id — the version leg will treat it as a literal pin and likely FAIL every run.\n');
    }
  }
}

// claude model-id -> our tier. Unknown/absent => '' (can't-tell => the caller fails OPEN for that role).
function modelIdToTier(modelId) {
  const s = String(modelId == null ? '' : modelId).toLowerCase();
  if (/^claude-opus-/.test(s)) return 'opus';
  if (/^claude-sonnet-/.test(s)) return 'sonnet';
  if (/^claude-haiku-/.test(s)) return 'haiku';
  if (/^claude-fable-/.test(s)) return 'fable';
  return '';
}

// FORGERY-RESISTANT actual-model read: the LAST `type:"assistant"` line's message.model in the role's subagent
// transcript (the model that produced the closing tokens — the harness writes it, the orchestrator cannot forge
// it). Same glob as agentResolves(). Returns the model-id string or '' when no assistant model line exists
// (=> can't-tell => caller fails OPEN for that role — mirrors the gate's existing ERR->allow residual).
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

// ── #1512 RESUME-BOUNDARY DETECTOR ───────────────────────────────────────────────────────────────────────
// A SendMessage resume discards a role's spawn-time model pin (measured: `.ai-workspace/research/
// 2026-07-10-1512-resume-hook-edge-probe.md`) — the resumed subagent silently re-inherits the SESSION model,
// which can land on a MORE capable tier than the role's policy (e.g. an Opus-orchestrator resuming a sonnet
// executor). The completion-time gate needs to tell that apart from a genuinely-wrong spawn. The harness marks
// a resume delivery with an UNFORGEABLE shape in the role's OWN transcript: a `type:"user"` record with
// `isMeta:true` and `origin.kind==="coordinator"` (verified on-disk against the real #1494 executor transcript,
// record 540: "The coordinator sent a message while you were working: ..."). The orchestrator cannot fabricate
// this record — it is authored by the harness at delivery time, the same trust boundary transcriptModel()
// already relies on for `message.model`.
//
// Returns { hasResume, preResumeModel, lastModel }:
//   hasResume       — true iff >=1 resume-delivery record exists anywhere in the transcript.
//   preResumeModel  — the LAST assistant `message.model` seen strictly BEFORE the FIRST resume boundary (the
//                     "what the role was actually running as before ANY rework tap" reading — multi-resume
//                     sequences anchor here, per the plan's "compare final-observed against the spawn/
//                     pre-first-resume model that matched policy" rule, not the model before the LAST resume).
//   lastModel       — the same value transcriptModel() would return for this agentId (computed in the same
//                     pass to avoid a second file read); '' if no assistant message.model line exists.
// Fails open to { hasResume:false, preResumeModel:'', lastModel:'' } on any missing/unreadable file — mirrors
// transcriptModel()'s can't-tell contract.
function resumeBoundaryModels(session, agentId) {
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  const empty = { hasResume: false, preResumeModel: '', lastModel: '' };
  if (!aid) return empty;
  const sess = sanitize(session);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return empty; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    let content;
    try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
    let firstResumeSeen = false;
    let preResumeModel = '';
    let lastModel = '';
    let sawAnyLine = false;
    for (const ln of content.split('\n')) {
      const s = ln.trim();
      if (!s) continue;
      let j; try { j = JSON.parse(s); } catch (e) { continue; }
      if (!j) continue;
      sawAnyLine = true;
      // #1512 AC-0 live probe (2026-07-10): a resume delivery's `origin.kind` varies by WHO issued the
      // SendMessage — 'coordinator' for a top-level-orchestrator resume (the real #1494 shape, verified
      // on-disk), 'peer' for an agent-to-agent resume (verified live this run, probe agent a4bd765511486c4ba
      // record 7). Both are the SAME harness-authored resume-delivery shape (type:"user", isMeta:true, a
      // non-empty origin.kind) — match on the SHAPE, not a single hardcoded kind, so a peer-issued resume is
      // not silently invisible to this detector.
      if (!firstResumeSeen && j.type === 'user' && j.isMeta === true && j.origin && typeof j.origin.kind === 'string' && j.origin.kind) {
        firstResumeSeen = true;
      }
      if (j.type === 'assistant' && j.message && typeof j.message.model === 'string' && j.message.model) {
        lastModel = j.message.model;
        if (!firstResumeSeen) preResumeModel = j.message.model;
      }
    }
    if (sawAnyLine) return { hasResume: firstResumeSeen, preResumeModel, lastModel };
  }
  return empty;
}

// #1512 CAPABILITY ordering (used ONLY to decide a STRICT quality up-tier for the resume-reroute arm below).
// `fable` is deliberately EXCLUDED from this map (plan-review N4: fable is high-quality but NOT cost-monotonic
// — ~2x Opus — so it must never be folded into a numeric rank other tiers get compared against). A resumed
// role landing on `fable` is instead handled as an unconditional up-tier in isResumeUpTier() below, kept
// syntactically SEPARATE from this ordering rather than assigned a rank inside it.
const CAPABILITY_RANK = { haiku: 1, sonnet: 2, opus: 3 };

// True iff `actual` is a STRICTLY more capable tier than `expected` — i.e. safe to allow-with-note when it
// arises from a resume (never used to permit a non-resume mismatch; the caller only invokes this inside the
// resume-boundary branch). `actual === 'fable'` is always true (see CAPABILITY_RANK comment above); otherwise
// both tiers must be known ranks and actual's rank must exceed expected's.
function isResumeUpTier(expected, actual) {
  if (actual === 'fable') return true;
  const er = CAPABILITY_RANK[expected];
  const ar = CAPABILITY_RANK[actual];
  return !!er && !!ar && ar > er;
}

// ── #1494 EFFECTIVE-TIER SENSOR ──────────────────────────────────────────────────────────────────────────
// The leading-edge model-policy gate (three-role-model-policy-gate.sh) used to HARDCODE the effective tier of
// a badge-less spawn to "opus" (the documented session default). Under an Opus session that's usually right;
// under a Fable session it's WRONG — a badge-less spawn actually inherits Fable, and the hardcoded guess let
// all four roles run Fable across 19 tasks in total silence (the gate computed effective=opus==expected=opus
// and stayed quiet). ADD, do NOT refactor transcriptModel() (finding H) — that function is load-bearing for
// the completion-time gate (transcriptModel() reads a role's OWN subagent transcript by agentId; this sensor
// reads the MAIN SESSION transcript directly by path, a different shape of the same "read the transcript, do
// not assume" idea) and stays byte-unchanged (AC-19).
const TIER_SENSOR_DEFAULT_TAIL_BYTES = 4 * 1024 * 1024;    // >= a single ~0.8MB record with margin (measured).
const TIER_SENSOR_DEFAULT_CAP_BYTES = 64 * 1024 * 1024;    // bounded — NEVER readFileSync the whole (281MB+) file.

// Bounded REVERSE-TAIL read of the last `type:"assistant"` record in a growing JSONL transcript, filtered to
// the MAIN session (isSidechain===false, so a subagent/sidechain record can never leak in as "the session
// model" — finding C). Reads only the last `tailBytes` from EOF; if no matching record is found in that
// window (trailing junk, or a record straddling the window edge), DOUBLES the window and retries, up to
// `capBytes`. Exceeding the cap without a parseable last-assistant record returns null (caller fails CLOSED).
// tailBytes/capBytes are configurable via opts OR env (CC_TIER_SENSOR_TAIL_BYTES / CC_TIER_SENSOR_CAP_BYTES,
// Rule 16) so a smoke can force the grow-path and cap-path with SMALL fixtures instead of 200MB files.
function lastAssistantModelFromFile(filePath, opts) {
  opts = opts || {};
  const envTail = Number(process.env.CC_TIER_SENSOR_TAIL_BYTES);
  const envCap = Number(process.env.CC_TIER_SENSOR_CAP_BYTES);
  const tailBytes = Number(opts.tailBytes) > 0 ? Number(opts.tailBytes)
    : (envTail > 0 ? envTail : TIER_SENSOR_DEFAULT_TAIL_BYTES);
  const capBytes = Number(opts.capBytes) > 0 ? Number(opts.capBytes)
    : (envCap > 0 ? envCap : TIER_SENSOR_DEFAULT_CAP_BYTES);
  const mainSessionOnly = opts.mainSessionOnly !== false;   // default true.

  let fd;
  let size;
  try {
    fd = fs.openSync(filePath, 'r');
    size = fs.fstatSync(fd).size;
  } catch (e) { return null; }   // missing / unreadable -> can't-tell.

  try {
    let window = Math.max(1, Math.min(tailBytes, capBytes));
    for (;;) {
      const start = Math.max(0, size - window);
      const length = size - start;
      if (length > 0) {
        const buf = Buffer.alloc(length);
        let bytesRead = 0;
        try { bytesRead = fs.readSync(fd, buf, 0, length, start); } catch (e) { bytesRead = 0; }
        let text = buf.toString('utf8', 0, bytesRead);
        // Drop the leading partial record (everything before the first \n), UNLESS this window covers byte 0
        // (in which case there IS no leading partial record — the window starts at the true file start).
        if (start > 0) {
          const nl = text.indexOf('\n');
          text = nl >= 0 ? text.slice(nl + 1) : '';
        }
        const lines = text.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
          const s = lines[i].trim();
          if (!s) continue;
          let j; try { j = JSON.parse(s); } catch (e) { continue; }
          if (!j || j.type !== 'assistant') continue;
          if (mainSessionOnly && j.isSidechain !== false) continue;   // require an EXPLICIT isSidechain:false.
          const model = (j.message && typeof j.message.model === 'string') ? j.message.model : '';
          if (model) return model;
        }
      }
      if (start === 0) break;          // covered the whole file — nothing found, give up.
      if (window >= capBytes) break;    // already at the cap — give up (fail-closed, never read past it).
      window = Math.min(window * 2, capBytes);
    }
  } finally {
    try { fs.closeSync(fd); } catch (e) { /* no-op */ }
  }
  return null;
}

// A `--model` value may be a bare TIER ALIAS (the normal spawn convention — "opus"/"sonnet"/"fable"/"haiku")
// or, defensively, a concrete claude-* id. Returns '' when neither form resolves (caller treats as unknown).
function modelIdOrAliasToTier(v) {
  const s = String(v == null ? '' : v).trim().toLowerCase();
  if (!s) return '';
  if (ROLE_MODELS.includes(s)) return s;
  return modelIdToTier(s);
}

// resolveEffectiveTier — the reusable "who is this really?" reader (#1494; #1497 Key-1 consumes this, does
// NOT re-derive it). TOTAL function: never throws, always returns a well-shaped { tier, source, agentdefTier }.
//
// Tier-deciding precedence (ONLY these three terms decide `tier`):
//   1. `model` non-empty -> tier = modelIdOrAliasToTier(model), source='requested'. Explicit badge wins,
//      regardless of transcript. An unresolvable explicit value (never seen in practice) fails CLOSED to
//      'unknown' rather than silently falling through to term 2 — an explicit-but-garbled badge must never
//      resolve to a guess.
//   2. else read the session transcript tail — `transcriptPath` (the PreToolUse(Agent) payload's own
//      `transcript_path`, used DIRECTLY — this is proven always-present, so this is the live path in
//      practice), else (ONLY when transcriptPath is absent) a defensive, dead-code-in-practice fallback:
//      build the MAIN-session path shape `<projectsRoot>/*/<session>.jsonl` (session as the FILENAME — this
//      is a NEW path shape, NOT the subagent-shape glob `.../<session>/subagents/agent-<id>.jsonl` that
//      transcriptModel()/agentResolves() use). Last `isSidechain:false` assistant `message.model` ->
//      modelIdToTier(...); non-empty -> that tier, source='session'.
//   3. else -> tier='unknown', source='unknown'.
//
// Agent-def frontmatter (`subagentType` + `agentsDir`) is PROVENANCE-ONLY: reported as `agentdefTier` but
// NEVER enters the precedence above and NEVER changes `tier` (whether frontmatter overrides session
// inheritance is UNVERIFIED — see the plan's `## Unverified assumptions`). `tier=unknown` ALWAYS means the
// caller must fail closed — never coerce it to a concrete tier (never resolve an opus seat's can't-tell to
// "opus"; that is exactly the leak this sensor exists to close).
function resolveEffectiveTier(o) {
  o = o || {};
  const out = { tier: 'unknown', source: 'unknown', agentdefTier: null };
  try {
    const modelRaw = (o.model == null ? '' : String(o.model)).trim();
    if (modelRaw) {
      const t = modelIdOrAliasToTier(modelRaw);
      out.tier = t || 'unknown';
      out.source = 'requested';
    } else {
      let txPath = (o.transcriptPath == null ? '' : String(o.transcriptPath)).trim();
      if (!txPath) {
        // Defensive fallback (finding K/L — dead-code-in-practice: transcript_path is byte-proven always
        // present on the payload). Build the MAIN-session path shape directly; do NOT reuse the subagent glob.
        const session = sanitize(o.session);
        if (session) {
          const projectsRoot = (o.projectsRoot && String(o.projectsRoot)) ||
            process.env.THREE_ROLE_PROJECTS_ROOT || PROJECTS_ROOT;
          try {
            const slugs = fs.readdirSync(projectsRoot);
            for (const slug of slugs) {
              const cand = path.join(projectsRoot, slug, session + '.jsonl');
              if (fileExists(cand)) { txPath = cand; break; }
            }
          } catch (e) { /* no derivable session path -> stays unknown/unknown */ }
        }
      }
      if (txPath) {
        const modelId = lastAssistantModelFromFile(txPath, { mainSessionOnly: true });
        if (modelId) {
          const t = modelIdToTier(modelId);
          if (t) { out.tier = t; out.source = 'session'; }
          // else: a resolved model id with an unrecognized tier prefix -> stays unknown/unknown (can't-tell).
        }
      }
    }
  } catch (e) {
    out.tier = 'unknown'; out.source = 'unknown';   // total function: never throws to the caller.
  }
  // Agent-def is PROVENANCE-ONLY — resolved independently of the precedence above, and can never widen it.
  try {
    const subagentType = (o.subagentType == null ? '' : String(o.subagentType)).trim();
    const agentsDir = o.agentsDir ? String(o.agentsDir) : '';
    if (subagentType && agentsDir) {
      const p = path.join(agentsDir, subagentType + '.md');
      if (fileExists(p)) {
        const content = fs.readFileSync(p, 'utf8');
        const m = content.match(/^model:\s*([a-z]+)/im);
        if (m && ROLE_MODELS.includes(m[1].toLowerCase())) out.agentdefTier = m[1].toLowerCase();
      }
    }
  } catch (e) { /* provenance is best-effort; must never affect tier */ }
  return out;
}

// Parse `--key value` flags. An empty next-arg ("") IS consumed (so `--skip-reason ""` records an
// explicit empty reason → caught as a non-specific skip). A flag with no following value → "".
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

// Phase 2 forgery-close: glob PROJECTS_ROOT/*/<session>/subagents/agent-<agentId>.jsonl ; ≥1 hit required.
function agentResolves(session, agentId) {
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  if (!aid) return false;
  const sess = sanitize(session);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return false; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    if (fileExists(f)) return true;
  }
  return false;
}

// #1575 Lane 1c — extract the plain TEXT of a subagent transcript's FIRST record (the initial spawn-prompt
// message). This is the SPAWN RECORD, as opposed to any LATER record (a Read tool-result, a pasted brief, a
// review byline) that can carry a 3ROLE_TASK tag as a MENTION rather than a spawn (round-3 D1: a real
// planner transcript ingests the plan-review tag via its own '## Review' byline, measured 4-of-7 on a real
// session). Every predicate in this file that decides "is agentId X bound to (task, role)" is re-scoped to
// test ONLY this first-record text — never `content.includes(tag)` over the whole file — so there is exactly
// ONE tag-binding predicate in the module (resolveAgent, agentBoundToTag, tagFromSubagentTranscript below all
// call this). Returns '' on any missing/unreadable/unparseable first line (fails closed to "no match").
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

// #860 / #1575 D1: resolve the agentId of the NEWEST-mtime subagent transcript whose SPAWN RECORD (first
// record, `firstRecordText()`) carries the exact spawn tag `3ROLE_TASK:<task> ROLE:<role>`. Returns the
// agentId string or '' when no transcript's spawn record carries the tag. Newest-mtime, not first-match: a
// tag can repeat across transcripts (an earlier probe/retry reusing a role tag), so the most recent write is
// the real role spawn. NOTE (round-4 D1 fix, at source): the predicate used to be a WHOLE-FILE
// `content.includes(tag)` — that binds to MENTIONS (a later record quoting the tag), not spawns; re-scoped
// to the spawn record only. This resolver remains a SEARCH-ACROSS-ALL-TRANSCRIPTS + newest-mtime-WINNER
// function — it is NOT the right predicate for verifying one SPECIFIC cited agentId's binding (a
// contaminated newer sibling can steal the "winner" slot, W27); that is what `agentBoundToTag()` below is for.
function resolveAgent(session, task, role) {
  const sess = sanitize(session);
  const tag = '3ROLE_TASK:' + sanitize(task) + ' ROLE:' + sanitize(role);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return ''; }
  let best = null;       // { agentId, mtimeMs }
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

// #1575 — test whether ONE SPECIFIC cited agentId is bound to (task, role): open exactly THAT agent's own
// transcript and test its spawn record. Unlike resolveAgent() (which SEARCHES every transcript and returns a
// newest-mtime WINNER), this never lets a contaminated, newer sibling transcript decide another row's
// binding (the W27 failure mode) — the correct predicate for verifying a ROW'S own claim (gate arm (1)/(2)
// and the 1a clause-2 supersede check all use this, per the Traps note: never resolveAgent/newest-mtime here).
function agentBoundToTag(session, agentId, task, role) {
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  if (!aid) return false;
  const sess = sanitize(session);
  const tag = '3ROLE_TASK:' + sanitize(task) + ' ROLE:' + sanitize(role);
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return false; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    let content;
    try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
    if (firstRecordText(content).includes(tag)) return true;
  }
  return false;
}

// #1575 §1b — the gate's universal verdict screen vocabulary, ONE allowlist shared by the gate (via
// `gate-plan-review`) and `cmdInherit`'s parent-verdict precondition ("the gate's own allowlist, one
// vocabulary, not two"). ALLOWLIST, never a denylist (D3): membership admits, everything else — BLOCK,
// SHIP-WITH-FIXES, a typo, an empty string, any novel token — blocks.
const AFFIRMATIVE_VERDICTS = new Set(['PASS', 'APPROVE', 'APPROVE-WITH-NOTES']);

// #1575 1a — thrown by overlayAppend when the terminal-EVIDENCE guard (clause 1 or clause 2) rejects a
// write. Callers (cmdAppend, cmdInherit) catch this, print the reason to stderr, write NOTHING, and exit
// nonzero — the ledger file is untouched (the prior terminal row survives byte-for-byte).
class GuardRejection extends Error {}

// #1580 Fix A — TERMINAL-EVIDENCE PREDICATE, monotonic-by-construction. #1575 keyed its guard on
// `prior.verdict` alone — correct for review roles (which are the only ones that ever carry a verdict) but
// BLIND to a completed EXECUTOR row, which carries `agentId + artifact_path + closedAt + self_authored` and
// NO verdict. This predicate is the full terminal-evidence CLASS #1575's one instance belonged to: verdict
// OR closedAt OR self_authored OR oracle OR a completed-run (agentId AND artifact_path) pair — the last
// disjunct is what catches the LEGACY orchestrator-writes-at-close shape (Invariant #6: `append --role
// executor --artifact <path>` with no --closed-at/--self-authored, composing onto a spawn-time agentId via
// #855 overlay — that row carries neither closedAt nor self_authored yet is fully "done"). Spawn-time
// ASSIGNED provenance (modelVersion/modelTier/effort) is DELIBERATELY excluded (plan-review non-blocking
// note 1) — a bare outcome-less spawn row (agentId + maybe assigned model/effort, nothing else) must remain
// legitimately clearable by a skip; that is the AC-2 "upgrade survives" arm, not a downgrade.
function priorHasTerminalEvidence(prior) {
  if (!prior) return false;
  if (prior.verdict) return true;
  if (prior.closedAt) return true;
  if (prior.self_authored) return true;
  if (prior.oracle) return true;
  if (prior.agentId && prior.artifact_path) return true;
  return false;
}

// Human-readable summary of WHICH terminal field(s) triggered the guard — generalizes #1575's message
// (which hardcoded "carries a completed verdict") to name whichever evidence is actually present, since a
// completed executor row triggers this with NO verdict at all.
function terminalEvidenceSummary(prior) {
  const parts = [];
  if (prior.verdict) parts.push('verdict "' + prior.verdict + '"');
  if (prior.closedAt) parts.push('closedAt "' + prior.closedAt + '"');
  if (prior.self_authored) parts.push('self_authored');
  if (prior.oracle) parts.push('oracle "' + prior.oracle + '"');
  if (prior.agentId && prior.artifact_path) {
    parts.push('a completed run (agentId "' + prior.agentId + '" + artifact_path "' + prior.artifact_path + '")');
  }
  return parts.join(', ');
}

// Mirror the gate's resolve_path: absolute / ~ / CLAUDE_PROJECT_DIR / cwd / $HOME.
function resolveArtifact(p) {
  if (!p) return '';
  const s = String(p);
  if (s.startsWith('/')) return fileExists(s) ? s : '';
  if (s.startsWith('~/')) { const q = path.join(HOME, s.slice(2)); return fileExists(q) ? q : ''; }
  const cands = [];
  if (process.env.CLAUDE_PROJECT_DIR) cands.push(path.join(process.env.CLAUDE_PROJECT_DIR, s));
  cands.push(path.join(process.cwd(), s));
  cands.push(path.join(HOME, s));
  cands.push(s);
  for (const c of cands) if (fileExists(c)) return c;
  return '';
}

// #1481 — the SHARED model-resolution helper both cmdAppend AND cmdRefreshModels call (reuse, never a
// second copy of the transcriptModel()->overlay-merge path). Given a role's explicitAgent (pass '' / falsy
// to fall back to resolveAgent's tag search) returns {} when no model is resolvable yet (fail-open,
// can't-tell), else {modelVersion[, modelTier]} (modelTier omitted only if the id doesn't map to a known
// tier prefix — modelIdToTier's own fail-open contract).
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
  } catch (e) { return {}; }   // fail-open: a resolution error must never wedge the caller.
}

// #1481 — resolve the directory this file ACTUALLY lives in (symlink-aware, mirrors resolveConfigPath's
// realpathSync trick — setup.sh installs this file as a SYMLINK at ~/.claude/hooks/3role-ledger.mjs, so a
// naive import.meta.url dirname would miss a sibling like kanban-resync.sh living next to the REPO file).
function selfDir() {
  try { return path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))); }
  catch (e) { return path.dirname(fileURLToPath(import.meta.url)); }
}

// #1481 — fire the shared kanban-resync.sh launcher as a DETACHED background subprocess (never blocks,
// never throws to the caller). Mirrors the existing bash callers' `bash kanban-resync.sh` contract (that
// script itself backgrounds the REAL sync via nohup and always exits 0) — this just gets us from a node
// caller to that same sibling script. Silently no-ops if the script is absent (ported/plugin copies that
// don't carry this machine-local agent-kanban helper) or on any spawn error.
function fireResyncBackground() {
  try {
    const script = path.join(selfDir(), 'kanban-resync.sh');
    if (!fileExists(script)) return;
    const child = spawn('bash', [script], { stdio: 'ignore', detached: true });
    child.unref();
  } catch (e) { /* fail-open */ }
}

function stripOraclePrefix(s) { return String(s == null ? '' : s).replace(/^oracle:/i, ''); }

// #1276 — vacuous-oracle classifier (RE-AUTHORED from the design intent of the upstream spec-driven
// harness's guardrails #9/#11 — see the Port-C "vacuous oracle" guard plan; no pattern was copied from
// any external source). An execution-review oracle that EXISTS and carries a PASS/verdict token but
// contains ZERO real assertions (all-trivially-true / bare-verdict / echo-only) proves nothing — "a PASS
// that asserts nothing is not a PASS." This classifier returns true ONLY when the oracle is POSITIVELY
// vacuous; ANY parse trouble / binary-ish content / unexpected shape returns false (FAIL-OPEN — never
// fail-closed: a malformed-but-present oracle is ALLOWED, not blocked).
//
// Operate over CONTENT lines (blank + `#`-comment lines dropped). A line is REAL-EVIDENCE when it either
// (R1) EXECUTES an assert command whose exit is the verdict, or (R2) carries a digit-bearing run-summary
// count. The R1 discriminator is that a REAL command is EXECUTED at a COMMAND POSITION (start of an
// `&&`-segment) — a command NAME quoted inside an echo/printf literal is printed TEXT, not run, so it does
// NOT count. The oracle is VACUOUS iff it has ZERO real-evidence content lines.

// R1 — does ONE `&&`-segment EXECUTE a real assert command (exit = verdict)?
function segmentIsRealAssert(seg) {
  const s = String(seg == null ? '' : seg).trim();
  if (!s) return false;
  // grep -q / -E / -F with an operand (the assert: search a file/stream, exit reflects a match).
  if (/^grep\b[^\n]*\s-[A-Za-z]*[qEF][A-Za-z]*\b[^\n]*\s\S/.test(s)) return true;
  // test / [ / [[ — REAL only with a $-var OR a filesystem-test flag (-e/-f/-d/-s/-r/-x) + operand; a
  // constant-vs-constant bracket ([ 1 = 1 ], [[ 1 = 1 ]], test 1 = 1) asserts nothing -> NOT real.
  if (/^(test\b|\[\[?)/.test(s)) {
    if (/\$[A-Za-z_{]/.test(s)) return true;
    if (/\s-[efdsrx]\s+\S/.test(s)) return true;
    return false;
  }
  // arithmetic (( ... )) test.
  if (/^\(\(.*\)\)/.test(s)) return true;
  // diff / cmp of two operands.
  if (/^(diff|cmp)\b\s+\S+\s+\S+/.test(s)) return true;
  // smoke / program / test-runner invocations executed for their exit code.
  if (/^bash\b[^\n]*smoke/i.test(s)) return true;
  if (/^\.\//.test(s)) return true;
  if (/^(pytest|jest|vitest)\b/.test(s)) return true;
  if (/^go\s+test\b/.test(s)) return true;
  if (/^npm\s+test\b/.test(s)) return true;
  if (/^node\b[^\n]*\.mjs\b/.test(s)) return true;
  return false;
}

// R2 — does ONE `&&`-segment carry a CAPTURED run-summary count (exit/output of a real run)? Mirrors R1's
// command-position echo-trap: a count sitting INSIDE an echo/printf literal is printed TEXT, not captured
// output, so a segment whose trimmed form STARTS with echo/printf is SKIPPED before the count regexes run.
// A bare captured line (no echo/printf prefix) is a single segment that keeps its count -> stays REAL.
function segmentIsCapturedCount(seg) {
  const s = String(seg == null ? '' : seg).trim();
  if (!s) return false;
  if (/^(echo|printf)\b/.test(s)) return false;   // printed literal, not captured output -> NOT real.
  if (/\b\d+\s+passed\b/i.test(s)) return true;
  if (/\b\d+\s+failed\b/i.test(s)) return true;
  if (/\bPASS=\d+\b[\s\S]*\bFAIL=\d+\b/i.test(s)) return true;
  if (/\bran\s+\d+\b/i.test(s)) return true;
  if (/\bOK\s*\(\d+/i.test(s)) return true;
  if (/\b\d+\s+(tests?|assertions?|checks?)\b/i.test(s)) return true;
  return false;
}

// Is ONE content line real-evidence (R1 OR R2 in any &&-segment)?
function lineIsRealEvidence(line) {
  const s = String(line == null ? '' : line);
  // Evaluate EACH &&-segment so a real command/count on EITHER side of `&&` counts (the LEFT-of-`&&`
  // realness is decided by the segment's command, NOT the bare presence of `&&`): `grep -q X f && echo
  // PASS` is real (left segment asserts), `true && echo PASS` is vacuous (both segments trivial). R2
  // counts are gated at COMMAND POSITION too (segmentIsCapturedCount skips echo/printf segments), so a
  // count quoted inside `echo "12 passed, 0 failed"` is printed TEXT, not captured output -> NOT real.
  const segs = s.split('&&');
  for (const seg of segs) {
    if (segmentIsRealAssert(seg)) return true;   // R1 — executed assert (exit = verdict).
    if (segmentIsCapturedCount(seg)) return true; // R2 — captured run-summary count.
  }
  return false;
}

// Returns true iff the oracle file is POSITIVELY vacuous. Fail-OPEN (false) on any error / kill-switch /
// binary-ish content.
function isVacuousOracle(filePath) {
  try {
    if (process.env.VACUOUS_ORACLE_OFF === '1') {   // belt-and-suspenders kill-switch.
      writeBypassLog('3role-ledger-isVacuousOracle', 'VACUOUS_ORACLE_OFF', 'PERMIT');
      return false;
    }
    const raw = fs.readFileSync(filePath, 'utf8');
    // Binary-ish / unparseable bytes (NUL present) -> cannot classify a script -> FAIL-OPEN.
    if (raw.indexOf('\u0000') >= 0) return false;
    let hasContent = false;
    for (const ln of raw.split('\n')) {
      const line = ln.trim();
      if (!line) continue;
      if (line.charAt(0) === '#') continue;   // comment line — drop.
      hasContent = true;
      if (lineIsRealEvidence(line)) return false;   // >= 1 real-evidence line -> NOT vacuous.
    }
    // Zero real-evidence lines among >=1 content line -> vacuous. No content lines at all -> can't-tell ->
    // fail-open (not vacuous).
    return hasContent;
  } catch (e) {
    return false;   // FAIL-OPEN — never fail-closed on a classifier error.
  }
}

// #1199 Part B — normalize a PATH-SHAPED artifact value to a CWD-INDEPENDENT form AT WRITE TIME, so a
// later `check` from any other cwd resolves it. A NON-path value (PR URL, branch name, commit sha,
// "shipped") is stored VERBATIM — never mangled into a bogus absolute path.
//
// R3/R4 — the value-shape guard must NOT treat "any slash" as a path. Two common executor values contain a
// slash but are NOT files: a branch (`feat/1199-x`) and a PR URL (`https://github.com/...`). So:
//   - URL scheme (`http(s)://`, `git://`, `ssh://`, ...) → verbatim.
//   - already a portable home-tilde path (`~/...`) → verbatim (no username, resolves from any cwd).
//   - explicit path shape (`/`, `./`, `../`, `.claude/`, `.ai-workspace/`) → resolve to absolute.
//   - an ambiguous slashed token (`src/llm/generate.ts` vs `feat/x`) → treat as a path ONLY if it resolves
//     to a file that EXISTS on disk (a real executor SOURCE artifact does; a branch never does).
//   - no slash (`PR #123`, a sha, `shipped`) → verbatim.
//
// R6 privacy — the ledger append fires a PostToolUse sync (kanban-sync-on-ledger-append.sh) that publishes
// ledger state to the Vercel-hosted agent-kanban board. To keep a raw `/Users/<name>/...` home path off
// both the at-rest ledger AND that publish surface, when the resolved absolute path is under $HOME we store
// the HOME-RELATIVE TILDE form `~/<rest>` — it carries NO username and resolveArtifact()'s `~/` arm expands
// it from ANY cwd. A path genuinely OUTSIDE $HOME is stored absolute (no home to leak).
function normalizeArtifact(raw) {
  const v = String(raw == null ? '' : raw);
  if (v === '') return v;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(v)) return v;   // URL scheme → not a filesystem path.
  if (v === '~' || v.startsWith('~/')) return v;        // already a portable home-tilde path.
  let abs = '';
  if (v.startsWith('/')) {
    abs = v;
  } else if (/^(\.\/|\.\.\/|\.claude\/|\.ai-workspace\/)/.test(v)) {
    abs = path.resolve(process.cwd(), v);               // explicit relative path shape → resolve.
  } else if (v.includes('/')) {
    const cand = path.resolve(process.cwd(), v);
    if (fileExists(cand)) abs = cand;                   // real source artifact (exists on disk).
    else return v;                                      // branch-shaped / non-file slashed token → verbatim.
  } else {
    return v;                                           // no slash → verbatim (PR #N, sha, "shipped").
  }
  abs = path.normalize(abs).replace(/\/+$/, '');
  const homePrefix = HOME.replace(/\/+$/, '') + path.sep;
  if (abs === HOME || abs.startsWith(homePrefix)) {     // R6: collapse $HOME prefix to `~` (no username).
    const rest = abs === HOME ? '' : abs.slice(homePrefix.length);
    return rest ? '~/' + rest : '~';
  }
  return abs;
}

// Returns {skip:false} when no skip was attempted; {skip:true, ok:true} for a valid reason;
// {skip:true, err:"..."} for an empty/non-specific reason.
function classifySkip(e) {
  if (!('skip_reason' in e)) return { skip: false };
  const t = String(e.skip_reason == null ? '' : e.skip_reason).trim();
  if (t === '') return { skip: true, err: 'skip reason is empty/whitespace' };
  if (NONSPECIFIC_RE.test(t)) return { skip: true, err: 'skip reason "' + t + '" is non-specific' };
  return { skip: true, ok: true };
}

// Returns null when the role is satisfied, else a problem string. `opts.rejectVacuousOracle` (#1276) — set
// ONLY by the instrumentation-gate's `check --reject-vacuous-oracle` — additionally REJECTS an
// execution-review oracle that exists + carries a PASS token but is vacuous (0 real assertions).
function checkRole(role, e, session, opts) {
  const sk = classifySkip(e);
  if (role === 'execution-review') {
    if (sk.skip) {
      return 'execution-review is NEVER inline-skippable (never grade your own homework) — it must resolve to a ' +
        'real reviewer agentId OR an oracle:<path> that exists with a PASS token; "ran it inline myself" is not allowed';
    }
    if (e.oracle) {
      const op = resolveArtifact(stripOraclePrefix(e.oracle));
      if (!op) return 'execution-review oracle path "' + e.oracle + '" does not exist';
      if (!fileHas(op, VERDICT_RE)) return 'execution-review oracle "' + op + '" lacks a PASS/verdict token';
      // #1276: a PASS that asserts nothing is not a PASS. When the gate opts in (and the feature kill-switch
      // is not set), reject a positively-vacuous oracle. The classifier fails OPEN, so this NEVER blocks on
      // a parse error — only on a file proven to carry zero real-evidence lines.
      if (opts && opts.rejectVacuousOracle && process.env.VACUOUS_ORACLE_OFF === '1') {
        writeBypassLog('3role-ledger-execution-review-oracle', 'VACUOUS_ORACLE_OFF', 'PERMIT');
      }
      if (opts && opts.rejectVacuousOracle && process.env.VACUOUS_ORACLE_OFF !== '1' && isVacuousOracle(op)) {
        return 'execution-review oracle "' + op + '" is vacuous — 0 real assertions (all-trivially-true / ' +
          'bare-verdict / echo-only); a PASS that asserts nothing is not a PASS. Add a REAL check (an assert ' +
          'command whose exit is the verdict, or a captured test-run summary with counts) OR name a real reviewer agentId';
      }
      return null;
    }
    if (!agentResolves(session, e.agentId)) {
      return 'execution-review agentId "' + (e.agentId || '') + '" does not resolve to a real subagent transcript (forged or no spawn)';
    }
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'execution-review artifact_path "' + (e.artifact_path || '') + '" not found';
    if (!fileHas(ap, VERDICT_RE)) return 'execution-review artifact "' + ap + '" lacks a verdict/PASS token';
    return null;
  }
  // planner / plan-review / executor — inline-skippable with a SPECIFIC reason.
  if (sk.skip) {
    if (sk.ok) return null;
    return role + ' ' + sk.err + ' — an inline-skip requires a SPECIFIC reason (the carve-out is for genuinely ' +
      'inseparable-from-session-state work; "ran the ' + role + ' inline myself" is NOT a valid skip)';
  }
  if (!agentResolves(session, e.agentId)) {
    return role + ' agentId "' + (e.agentId || '') + '" does not resolve to a real subagent transcript (' +
      PROJECTS_ROOT + '/*/' + sanitize(session) + '/subagents/agent-' + (e.agentId || '') + '.jsonl) — forged or no ' +
      'spawn happened; provide a real agentId OR an explicit inline-skip:<specific reason>';
  }
  if (role === 'planner') {
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'planner artifact_path "' + (e.artifact_path || '') + '" not found (the plan file)';
    if (!fileHas(ap, PLAN_RE)) return 'planner artifact "' + ap + '" lacks a plan marker — needs a heading like ' +
      '## ELI5, ### Binary AC, ## Binary acceptance criteria, ### Acceptance criteria, ## Acceptance, or ## AC';
    return null;
  }
  if (role === 'plan-review') {
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'plan-review artifact_path "' + (e.artifact_path || '') + '" not found';
    if (!fileHas(ap, VERDICT_RE)) return 'plan-review artifact "' + ap + '" lacks a verdict token (PASS/FAIL/APPROVE/verdict/## Review)';
    return null;
  }
  // executor — artifact_path is a string (PR URL / commit / branch); existence on disk not required.
  if (!e.artifact_path || String(e.artifact_path).trim() === '') {
    return 'executor artifact_path missing (PR URL / commit / branch string)';
  }
  return null;
}

// ── #1509 Leg A — TRACKED, not merely present ────────────────────────────────────────────────────────────
// The #861 class (6 recurrences): a reviewer's Bash cwd is the PRIMARY clone, not the PR worktree, so a
// disk-path artifact lands present-but-untracked and never ships with the PR — yet today's `check` only
// tests EXISTENCE (fileExists/resolveArtifact), which a present-but-untracked file passes. Leg A adds the
// missing test: is the cited path actually git-tracked (or staged)? `git ls-files --error-unmatch` run with
// `-C <the file's own containing directory>` so git auto-discovers whichever repo the artifact actually
// lives in (works identically from the primary clone or any worktree). Exit 0 => tracked/staged => true;
// exit 1 => a real "not known to git" verdict => false; any OTHER exit (128 not-a-repo, spawn error, missing
// git binary) => can't-tell => null => the caller fails OPEN (never a false block on an environment hiccup —
// mirrors every other can't-tell residual in this file).
function isGitTracked(absPath) {
  try {
    const dir = path.dirname(absPath);
    const res = spawnSync('git', ['-C', dir, 'ls-files', '--error-unmatch', '--', absPath], { encoding: 'utf8' });
    if (res.error) return null;
    if (res.status === 0) return true;
    if (res.status === 1) return false;
    return null;   // 128 (not a repo) or anything unexpected -> can't-tell -> fail-open.
  } catch (e) { return null; }
}

// The three roles whose artifact is a disk path (planner, plan-review, execution-review) — Leg A is
// role-keyed HARD on exactly these; executor is exempt BY ROLE (its legitimate artifact is a PR URL / sha /
// branch string), never by guessing at the value's shape.
const TRACKED_ROLES = ['planner', 'plan-review', 'execution-review'];

// Resolve the disk path Leg A should tracked-check for one of the TRACKED_ROLES entry, mirroring exactly
// what checkRole() already resolves for that role (oracle wins for execution-review, else artifact_path).
// Returns '' when there is no resolvable on-disk path for this role (nothing for Leg A to check — the base
// existence leg already reports that as its own problem; Leg A never duplicates it).
function resolveDiskPathForRole(role, e) {
  if (role === 'execution-review') {
    if (e.oracle) return resolveArtifact(stripOraclePrefix(e.oracle));
    if (e.artifact_path) return resolveArtifact(e.artifact_path);
    return '';
  }
  return resolveArtifact(e.artifact_path || '');
}

// Leg A per-role check. Returns null when satisfied (not a TRACKED_ROLES role, inline-skipped, no resolvable
// disk path, or genuinely tracked/can't-tell), else a "TRACKED:"-prefixed problem string.
function checkTrackedRole(role, e) {
  if (!TRACKED_ROLES.includes(role)) return null;   // executor exemption + non-disk-path roles.
  if (classifySkip(e).skip) return null;             // inline-skip has no artifact to tracked-check.
  const ap = resolveDiskPathForRole(role, e);
  if (!ap) return null;                              // no resolvable disk path -> the existence leg's problem, not Leg A's.
  if (isGitTracked(ap) === false) {
    return role + ' artifact "' + ap + '" exists on disk but is NOT git-tracked (present-but-untracked — it ' +
      'will never ship with the PR; the #861/#1509 class, 6 recurrences). git add + commit it (from a Rule-12 ' +
      'worktree), then re-complete.';
  }
  return null;   // tracked, staged, or can't-tell (fail-open) -> satisfied.
}

// ── #1537 — artifact PRIVACY scan over the SHIPPED, git-tracked 3-role artifacts ──────────────────────────
// Sibling of Leg A directly above: Leg A proves the cited artifact is git-TRACKED; this leg proves that
// TRACKED artifact's own PROSE is CLEAN of the three regulated token classes (home-path / personal-email /
// brand — #1588: an artifact's OWN privacy-report table can itself quote the token). Reuses the SAME
// resolveDiskPathForRole() Leg A already computes (one resolution site, no re-typed regex) and shells out to
// the canonical `scripts/privacy-scan.sh --working <path>` (count-based, fail-CLOSED, never echoes the
// matched bytes). The scanner's OWN absolute path is resolved ONCE by the BASH caller (which already
// presence-guards it for the ai-brain-only / plugin-dormant discipline) and passed in via the PRIVACY_SCAN_BIN
// env var — this file never hardcodes or re-derives that path.
const PRIVACY_ROLES = TRACKED_ROLES;   // the same three disk-path roles Leg A already tracked-checks.

// Run the canonical scanner over one resolved artifact path. Returns null when CLEAN (rc 0); otherwise a
// count-only detail string covering BOTH "dirty" (scanner rc 1, its own count-summary stderr) and "can't-tell"
// (scanner rc >=2 / spawn error) — #1266's fail-CLOSED discipline means BOTH outcomes BLOCK here, never wave
// through a scan that could not run. NEVER reads or re-prints the artifact's own content — only the scanner's
// own count-only stderr is captured.
function scanArtifactPrivacy(absPath, scannerBin) {
  const res = spawnSync(scannerBin, ['--working', absPath], {
    encoding: 'utf8',
    cwd: process.env.PRIVACY_SCAN_CWD || undefined,   // test-only isolation seam (#1537 AC6 email-source mutation); unset in production -> inherits the real process cwd (the primary clone), so `git config user.email` reads the REAL operator config there.
  });
  if (res.error) return 'privacy-scan could not run (' + res.error.message + ') — fail-closed, refusing to report clean';
  if (res.status === 0) return null;
  return (res.stderr || '').trim() || ('privacy-scan exited ' + res.status + ' with no detail — fail-closed');
}

// #1509 — the executor-cites-a-disk-path SURFACED NOTE (never a hard block; the #1494 shape). A measured
// sweep of 246 real ledgers found executor==planner in 62 of them (a live, coexisting, doctrine-sanctioned
// convention alongside the newer PR-URL citation) — so artifact_path alone cannot distinguish #1494's
// mis-citation from those 62 shipped chains; that discrimination needs KIND/authorship inference, which is
// #1532's own scope. This just makes the signal VISIBLE instead of silently dropped.
function executorDiskPathNote(e) {
  if (!e) return null;
  const raw = String(e.artifact_path == null ? '' : e.artifact_path).trim();
  if (!raw) return null;
  const ap = resolveArtifact(raw);
  if (!ap) return null;   // not an existing disk path (PR URL / branch / sha) -> nothing to surface.
  return 'executor artifact_path "' + raw + '" resolves to a DISK PATH (' + ap + ') rather than a PR/commit/' +
    'branch reference (the #1494 shape) — lower-fidelity, not blocked; kind/authorship verification is #1532.';
}

// OVERLAY-MERGE core (#855), extracted so both `append` and `inherit-plan-review` write through the SAME
// path (semantics unchanged vs the prior inline cmdAppend body). Reads the ledger, drops any prior line for
// `role` (capturing it to MERGE onto), overlays ONLY the fields supplied in `fields` (own-key presence is the
// "provided" signal — an absent key PERSISTS the prior value; role / session_id / ts always refresh), applies
// the same mutual-exclusion guard, writes back. Recognized `fields` keys: agentId, artifact_path, skip_reason,
// oracle, inherited_from. Returns the ledger file path.
function overlayAppend(session, task, role, fields) {
  const file = ledgerFile(session, task);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); } catch (e) { /* new file */ }
  const kept = [];
  // #1580 Fix B — retain EVERY earlier same-role row as HISTORY; only the LAST same-role row becomes
  // `prior` (the row this call may merge onto, or supersede with a genuinely new round). Pre-#1580 this
  // loop dropped ALL same-role lines unconditionally (only the last survived, as `prior`, itself about to
  // be overwritten) — harmless when a role only ever had ONE round, but it silently destroyed round-1's
  // evidence (e.g. its OBSERVED model) the instant a round-2 write landed. `olderRoundLines` are raw
  // strings, re-emitted VERBATIM — never re-parsed, re-ordered, or mutated once superseded.
  const priorSameRoleLines = [];
  for (const ln of lines) {
    try {
      const j = JSON.parse(ln);
      if (j && j.role === role) { priorSameRoleLines.push(ln); continue; }
      kept.push(ln);
    } catch (e) { kept.push(ln); }
  }
  let prior = null;
  if (priorSameRoleLines.length) {
    try { prior = JSON.parse(priorSameRoleLines[priorSameRoleLines.length - 1]); } catch (e) { prior = null; }
  }
  const olderRoundLines = priorSameRoleLines.slice(0, -1);
  // #1575 1a / #1580 Fix A — TERMINAL-EVIDENCE guard, TWO clauses, ONE principle: terminal evidence is
  // EVIDENCE, a bare re-append is an ASSERTION, and the weak must never erase the strong. #1580 widens the
  // outer TRIGGER from "prior carries a verdict" to "prior carries ANY terminal evidence"
  // (priorHasTerminalEvidence — see its doc comment) so a completed EXECUTOR row (no verdict, ever) gets
  // the SAME protection a completed review row already had; this is one extended guard, not a second one.
  // Runs BEFORE any field is overlaid onto `entry`, and THROWS (writes nothing) rather than silently
  // no-op'ing or preserving-and-mangling.
  if (priorHasTerminalEvidence(prior)) {
    // Clause 1 — verdict-LESS erasers are rejected. A skip_reason append (the clear-list below would erase
    // verdict/agentId/artifact_path/closedAt/self_authored/oracle) or an inherited_from overlay
    // (provenance-swap) that carries NO verdict of its own cannot erase ANY terminal evidence — not just a
    // verdict. Keyed on terminal-evidence PRESENCE, never the skip keyword nor the verdict field alone —
    // this closes the skip-eraser AND the inherit-eraser for EVERY terminal shape with one rule.
    if ((('skip_reason' in fields) || ('inherited_from' in fields)) && !('verdict' in fields)) {
      // Backward-compatible phrasing: when the terminal evidence includes a verdict, keep #1575's exact
      // "a completed verdict ..." substring (existing consumers, e.g. three-role-transition-gate-smoke-
      // test.sh AC-4b(i), grep for it) — the #1580-widened trigger only changes WHEN this clause fires, not
      // the wording of the pre-existing verdict case. A prior row with NO verdict (the new executor-shaped
      // case this fix adds) gets the generalized terminal-evidence summary instead.
      const evidenceLabel = prior.verdict
        ? ('a completed verdict "' + prior.verdict + '"' + (prior.agentId ? ' (agentId ' + prior.agentId + ')' : ''))
        : ('terminal evidence — ' + terminalEvidenceSummary(prior));
      throw new GuardRejection(
        'terminal-evidence guard (#1575/#1580): role ' + role + ' already carries ' + evidenceLabel +
        ' — a verdict-LESS write (skip / inherit) cannot erase it. Run a new, genuinely bound review/run to ' +
        'supersede it honestly.'
      );
    }
    // Clause 2 (UNCHANGED from #1575, still verdict-scoped — a "verdict change" is only a meaningful concept
    // when a verdict exists to change) — verdict-CHANGING appends require NEW, ATTRIBUTED evidence. A
    // DIFFERENT verdict value is accepted ONLY when the SAME command also cites (i) an --agent whose
    // transcript is SPAWN-RECORD-bound to this exact (task, role) AND distinct from the prior row's agentId
    // (when the prior row has one), AND (ii) a --closed-at strictly newer than the prior row's closedAt
    // (when the prior row has one). Same-VALUE re-appends and verdict-less writes are untouched by this
    // clause (checked above/below). A prior row with NO verdict (e.g. a completed executor row) has no
    // verdict for this clause to guard — that row's protection is entirely clause 1's job.
    if (prior.verdict && ('verdict' in fields) && fields.verdict !== prior.verdict) {
      const incomingAgent = ('agentId' in fields) ? fields.agentId : '';
      const boundNew = !!incomingAgent && agentBoundToTag(session, incomingAgent, task, role);
      const distinctAgent = !prior.agentId || (incomingAgent !== prior.agentId);
      const closedAtOk = !prior.closedAt ||
        (('closedAt' in fields) && !!fields.closedAt && String(fields.closedAt) > String(prior.closedAt));
      if (!(boundNew && distinctAgent && closedAtOk)) {
        throw new GuardRejection(
          'terminal-evidence guard (1a clause 2): role ' + role + ' already carries a completed verdict "' +
          prior.verdict + '"' + (prior.agentId ? ' (agentId ' + prior.agentId + ')' : '') +
          ' — superseding it requires a NEW, ATTRIBUTED review in the SAME command: an --agent whose ' +
          'transcript is spawn-record-bound to 3ROLE_TASK:' + task + ' ROLE:' + role + ', distinct from the ' +
          'prior agentId, AND a --closed-at strictly newer than the prior closedAt. A bare or same-agent ' +
          'verdict flip is refused; spawn a genuinely NEW plan-review/review subagent and cite it.'
        );
      }
    }
  }
  // #1580 Fix B — ROUND BOUNDARY. A NEW, DISTINCT --agent arriving over a prior row that ALREADY had an
  // agentId is the unforgeable-ish signal of a genuinely NEW round (a fresh subagent spawn), not a
  // same-round compose. When detected: retain the just-superseded round's row VERBATIM as history (pushed
  // below, never touched again) and start this entry FRESH — carrying only what THIS call provides, not
  // the old round's artifact_path/closedAt/verdict/self_authored/oracle (those belong to round-1's
  // evidence, already safely retained in its own line). A close-only append (no --agent at all) or a
  // same-agent re-append never triggers this, so the existing single-round spawn-then-close AND
  // close-then-spawn compose (#855, AC-4) is unaffected: on close-then-spawn the FIRST write (the close) has
  // no prior row yet, so when the spawn's --agent later arrives `prior.agentId` is still absent and this
  // stays false — that write correctly MERGES onto the close, one round, one line.
  const incomingAgentId = ('agentId' in fields) ? String(fields.agentId == null ? '' : fields.agentId) : '';
  const isNewRound = !!(prior && prior.agentId && incomingAgentId && incomingAgentId !== prior.agentId);
  for (const ln of olderRoundLines) kept.push(ln);
  if (isNewRound) kept.push(JSON.stringify(prior));
  // Start from the prior line for this role (SAME round: merge) or an empty base (NEW round: fresh row) and
  // overlay ONLY the fields this call provides. Unprovided fields PERSIST from the base; role / session_id /
  // ts always refresh. This is what lets "agentId at spawn" and "artifact_path at close" compose into ONE
  // line within a round, order-independent — neither writer clobbers the other — while a genuinely new
  // round starts its own line instead of Frankensteining onto the old one.
  const entry = { ...(isNewRound ? {} : (prior || {})), role, session_id: sanitize(session), ts: new Date().toISOString() };
  if ('agentId' in fields) entry.agentId = fields.agentId;
  if ('artifact_path' in fields) entry.artifact_path = fields.artifact_path;
  if ('skip_reason' in fields) entry.skip_reason = fields.skip_reason;
  if ('oracle' in fields) entry.oracle = fields.oracle;
  if ('inherited_from' in fields) entry.inherited_from = fields.inherited_from;
  // #1036: review roles (plan-review / execution-review / ship-review) may record a one-word VERDICT
  // (APPROVE / PASS / BLOCK / SHIP-WITH-FIXES / APPROVE-WITH-NOTES). Read-only downstream: the agent-kanban
  // board surfaces it as a colored pill. Overlay only when provided (back-compat: absent ⇒ no verdict).
  if ('verdict' in fields) entry.verdict = fields.verdict;
  // #1100 item 3: provenance stamp — overlay only when provided (back-compat: absent ⇒ unstamped).
  if ('self_authored' in fields) entry.self_authored = fields.self_authored;
  // #1516 — the EXPLICIT close-stamp. Overlay only when provided (own-key "provided" discipline, same as
  // every other field here). The ONLY writer that fires exclusively at close (three-role-subagent-ledger.sh,
  // on SubagentStop) passes this — never the spawn-time hook — which is what makes "closedAt present" a
  // trustworthy punch-out signal instead of a value that could land at dispatch. Optional + additive:
  // check/checkRole never reference it, so a chain-role line gains it harmlessly too.
  if ('closedAt' in fields) entry.closedAt = fields.closedAt;
  // #1465 — OPTIONAL model+effort provenance. Overlay only when this call resolved a value (own-key
  // presence is the "provided" signal, same discipline as every other field above); an unprovided key
  // PERSISTS the prior line's value, so "model resolved at spawn-time self-append" composes with
  // "artifact at close" exactly like agentId/artifact_path do (#855 overlay-merge).
  if ('modelVersion' in fields) entry.modelVersion = fields.modelVersion;
  if ('modelTier' in fields) entry.modelTier = fields.modelTier;
  if ('effort' in fields) entry.effort = fields.effort;
  // Mutual-exclusion guard: a "ran/verified" signal (agentId for a real spawn, or oracle for a passing test)
  // and a "skip" signal are mutually exclusive by intent, and checkRole tests skip FIRST. So providing
  // agentId or oracle clears any inherited skip_reason (a stale skip can't mask a real spawn/oracle);
  // conversely providing skip_reason clears inherited agentId/artifact_path/oracle (dead weight a merge could
  // otherwise resurrect) — modelVersion/modelTier/effort join that clear-list too (#1465): they are
  // provenance OF a real spawn's transcript, so a skip line must not carry a stale claimed model.
  if (('agentId' in fields) || ('oracle' in fields)) delete entry.skip_reason;
  if ('skip_reason' in fields) {
    delete entry.agentId; delete entry.artifact_path; delete entry.oracle; delete entry.verdict; delete entry.self_authored;
    delete entry.modelVersion; delete entry.modelTier; delete entry.effort; delete entry.closedAt;
  }
  kept.push(JSON.stringify(entry));
  fs.writeFileSync(file, kept.join('\n') + '\n');
  return file;
}

function cmdAppend(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('append: --session, --task, --role are required'); process.exit(2); }
  if (!RECORDABLE_ROLES.includes(role)) { console.error('append: --role must be one of ' + RECORDABLE_ROLES.join(', ')); process.exit(2); }
  // Map the CLI flag names onto the canonical entry field names overlayAppend overlays.
  const fields = {};
  if ('agent' in o) fields.agentId = o.agent;
  if ('artifact' in o) fields.artifact_path = normalizeArtifact(o.artifact);   // #1199 Part B: cwd-independent + home-tilde.
  if ('skip-reason' in o) fields.skip_reason = o['skip-reason'];
  if ('oracle' in o) fields.oracle = o.oracle;
  if ('verdict' in o) fields.verdict = o.verdict;
  // #1100 item 3: provenance — a line authored BY the role's own agent (its SubagentStop scan saw the agent
  // self-append for this role) carries self_authored:true. Flag presence is the "provided" signal; a bare
  // `--self-authored` (no value) is true, `--self-authored false` is false.
  if ('self-authored' in o) fields.self_authored = (o['self-authored'] !== 'false');
  // #1466 — EXPLICIT provenance overlay flags, parsed BEFORE the model auto-capture below so a resolvable
  // transcript (OBSERVED) can still overwrite an explicitly-asserted --model-version/--model-tier (ASSIGNED)
  // when both are present on the SAME call — normally they never co-occur (see the file-header comment).
  // --effort has NO auto-capture counterpart any more (removed below), so this is its ONLY source.
  if ('effort' in o) fields.effort = o.effort;
  if ('model-version' in o) fields.modelVersion = o['model-version'];
  if ('model-tier' in o) fields.modelTier = o['model-tier'];
  // #1516 — explicit close-stamp flag. ONLY three-role-subagent-ledger.sh (SubagentStop) passes this; every
  // other caller omits it, so overlayAppend's per-key "provided" discipline leaves an unstamped line alone.
  if ('closed-at' in o) fields.closedAt = o['closed-at'];
  // #1465 — CENTRALIZED best-effort MODEL capture (unchanged by #1466 — only the effort half below moved).
  // Runs on EVERY append (both a role's own self-append AND the SubagentStop hook's later --agent
  // re-append), so the stop-time re-append automatically backfills modelVersion/modelTier from the
  // by-then-COMPLETE transcript with ZERO edit to the shell hook (see AC1-LIVE's fallback branch). Fail-open
  // throughout: any resolution failure just omits the field (back-compat — old ledger lines and
  // check/checkRole never reference these).
  //   agentId for the model lookup <- --agent when present, ELSE resolveAgent(session, task, role) (a
  //   self-append carries no --agent; its own transcript is scanned for the literal spawn tag).
  //   model <- transcriptModel(session, agentId) -> modelVersion; modelIdToTier(modelVersion) -> modelTier.
  // This OBSERVED capture wins over an explicit --model-version/--model-tier from above ONLY when a real
  // message.model line already exists (at spawn time it never does yet, so an ASSIGNED stamp survives
  // untouched until the role's own transcript actually completes — #1466 AC-8b, "observed wins").
  // #1481: this now calls the SHARED resolveModelFields() helper (extracted, not re-implemented) — the
  // exact same transcriptModel()->overlay-merge path cmdRefreshModels reuses for the in-flight backfill.
  {
    const explicitAgent = ('agent' in o && o.agent) ? o.agent : '';
    const modelFields = resolveModelFields(session, task, role, explicitAgent);
    if (modelFields.modelVersion) fields.modelVersion = modelFields.modelVersion;
    if (modelFields.modelTier) fields.modelTier = modelFields.modelTier;
  }
  // #1466 — the #1465 AMBIENT `process.env.CLAUDE_EFFORT` auto-capture that used to sit here is REMOVED. It
  // stamped the ORCHESTRATOR's session effort on EVERY append — including a close-out `--artifact`-only call
  // with no effort opinion of its own — so the moment a role's real effort differed from the orchestrator's,
  // the very next unrelated append silently clobbered it back to the session value (the bug this fixes).
  // Effort is now written ONLY via the explicit --effort flag above: the spawn hook stamps ASSIGNED, the
  // SubagentStop hook stamps OBSERVED (`effort.level`), and every other append (self-record, close-out)
  // passes none — overlayAppend's per-key "provided" discipline then PRESERVES the role's real value untouched.
  // #897: a build worktree is transient (quarantined at cleanup), so an artifact_path under
  // `.claude/worktrees/<slug>/` DANGLES the moment the worktree is removed — and the completion gate
  // (which checks the artifact file EXISTS) then BLOCKs. The committed artifact also lives at a stable
  // primary-clone path after merge+FF; cite THAT. Warn (stderr is visible to the orchestrator, unlike an
  // exit-0 hook nudge — #769) but do NOT block: the path may legitimately still exist this instant.
  if (fields.artifact_path && /\/\.claude\/worktrees\//.test(String(fields.artifact_path))) {
    console.error('WARN (3role-ledger #897): --artifact path is inside a build worktree (.claude/worktrees/) — ' +
      'it will DANGLE once the worktree is quarantined, and the completion gate will then BLOCK. Cite the ' +
      'stable primary-clone path the artifact lands at after merge+FF, OR complete the task before quarantine.');
  }
  let file;
  try {
    file = overlayAppend(session, task, role, fields);
  } catch (e) {
    if (e instanceof GuardRejection) { console.error('BLOCK: ' + e.message); process.exit(2); }
    throw e;
  }
  console.log('OK appended role=' + role + ' -> ' + file);
  process.exit(0);
}

// #881: inherit-plan-review --session S --task T --parent P
// A LEG sub-task (T) may inherit its PARENT's (P) planner + plan-review ledger lines — but ONLY if the parent
// genuinely has a real, TRANSCRIPT-BACKED planner AND plan-review (verify-then-write, fail-closed). A missing /
// forged / inline-skipped parent review BLOCKs (exit 3) and writes NOTHING — you cannot launder an absent or
// fabricated parent review onto a leg, and the session-bound inline-skip carve-out does NOT transfer to a leg.
function cmdInherit(o) {
  const session = o.session, task = o.task, parent = o.parent;
  if (!session || !task || !parent) { console.error('inherit-plan-review: --session, --task, --parent are required'); process.exit(2); }
  const block = (reason) => {
    console.error('BLOCK: cannot inherit — parent task ' + sanitize(parent) + ' has no verified plan-review (' + reason + ')');
    process.exit(3);
  };
  const pfile = ledgerFile(session, parent);
  let lines;
  try { lines = fs.readFileSync(pfile, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) { block('no parent ledger file: ' + pfile); }
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  const planner = byRole['planner'];
  const planReview = byRole['plan-review'];
  if (!planner) block('parent has no planner line');
  if (!planReview) block('parent has no plan-review line');
  // EXPLICIT inline-skip rejection (the #881 catch). checkRole returns null for a well-formed inline-skip, so
  // we must reject skip_reason here BEFORE trusting either entry — the carve-out is session-bound and does not
  // transfer to a leg (a leg inherits ONLY a transcript-backed parent planner + plan-review).
  for (const [r, ent] of [['planner', planner], ['plan-review', planReview]]) {
    if ('skip_reason' in ent) {
      block('parent ' + r + ' was inline-skipped — the carve-out does not apply to legs; provide a real ' +
        'transcript-backed ' + r + ' for the parent first');
    }
  }
  // Verify-or-fail-closed: run the SAME checkRole `check` uses on both parent entries.
  for (const [r, ent] of [['planner', planner], ['plan-review', planReview]]) {
    const prob = checkRole(r, ent, session);
    if (prob) block(prob);
  }
  // #1575 1a-2 — three additional fail-closed PRECONDITIONS (verify-THEN-write, exit 3, writes NOTHING),
  // evaluated BEFORE either overlayAppend call below (round-4 D2: leg-terminality in particular must NOT be
  // delegated to the 1a guard inside overlayAppend — cmdInherit writes the planner row first, so a
  // guard-inside-the-overlay would fire only on the SECOND write, after the planner row already carries
  // inherited_from, breaking the "writes NOTHING" contract).
  const blockPrecond = (reason) => {
    console.error('BLOCK: cannot inherit — ' + reason);
    process.exit(3);
  };
  // Precondition 1 — PARENT-LEG RELATION: the parent's own ledgered PLANNER artifact (the reviewed plan
  // file) must NAME the leg task id (a genuine leg is a sub-slice of the parent's plan; #1064 discipline).
  {
    const ap = resolveArtifact(planner.artifact_path);   // already existence+PLAN_RE-verified by checkRole above.
    let content = '';
    try { content = fs.readFileSync(ap, 'utf8'); } catch (e) { /* fall through -> relation test fails below */ }
    const legToken = sanitize(task);
    const legRe = new RegExp('(^|[^0-9A-Za-z._-])' + legToken.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '($|[^0-9A-Za-z._-])');
    if (!legToken || !legRe.test(content)) {
      blockPrecond('parent planner artifact "' + ap + '" does not name leg task ' + legToken +
        ' — a genuine leg must be listed in the parent plan (the #1064 discipline: tag CHILD ids, not the ' +
        'epic\'s). Add the leg id to the plan (an honest, visible edit), or provide the correct --parent.');
    }
  }
  // Precondition 2 — PARENT VERDICT condition: the parent's plan-review row must carry an AFFIRMATIVE
  // verdict (the gate's own allowlist, one vocabulary, not two). Absent also refuses (fail-closed).
  {
    const v = typeof planReview.verdict === 'string' ? planReview.verdict.toUpperCase().trim() : '';
    if (!AFFIRMATIVE_VERDICTS.has(v)) {
      blockPrecond('parent plan-review verdict is ' + (v || '<absent>') + ' — inherit requires an AFFIRMATIVE ' +
        'verdict (' + [...AFFIRMATIVE_VERDICTS].join('|') + '); the parent\'s remediation is a re-review, not a ' +
        'silent inherit.');
    }
  }
  // Precondition 3 — LEG TERMINALITY: if the LEG's OWN plan-review row already carries a verdict, refuse up
  // front — a completed per-leg review is never papered over by a hand-me-down.
  {
    const legFile = ledgerFile(session, task);
    let legLines = [];
    try { legLines = fs.readFileSync(legFile, 'utf8').split('\n').filter((l) => l.trim()); } catch (e) { /* no leg ledger yet -> fine */ }
    let legPlanReview = null;
    for (const ln of legLines) { try { const j = JSON.parse(ln); if (j && j.role === 'plan-review') legPlanReview = j; } catch (e) { /* skip */ } }
    if (legPlanReview && legPlanReview.verdict) {
      blockPrecond('leg ' + sanitize(task) + ' already has a completed plan-review verdict "' + legPlanReview.verdict +
        '"' + (legPlanReview.agentId ? ' (agentId ' + legPlanReview.agentId + ')' : '') +
        ' — a hand-me-down inherit cannot paper over a completed per-leg review. Run a new, genuinely bound ' +
        'review to supersede it honestly.');
    }
  }
  // Success: append both parent entries into the LEG ledger verbatim (same agentId + artifact_path) + an
  // inherited_from marker, through the same overlay-merge path so a later real per-leg review overwrites
  // clean. The plan-review row ALSO carries the parent's verdict (the gate's universal screen reads it —
  // arm (2) is only reachable when the inherited row itself carries an affirmative verdict). The 1a guard
  // (clause 1/2) inside overlayAppend runs here too as a defense-in-depth BACKSTOP — unreachable in the
  // sanctioned flow given precondition 3 above, but never bypassed.
  try {
    overlayAppend(session, task, 'planner', { agentId: planner.agentId, artifact_path: planner.artifact_path, inherited_from: sanitize(parent) });
    overlayAppend(session, task, 'plan-review', { agentId: planReview.agentId, artifact_path: planReview.artifact_path, inherited_from: sanitize(parent), verdict: planReview.verdict });
  } catch (e) {
    if (e instanceof GuardRejection) blockPrecond(e.message);
    throw e;
  }
  console.log('OK inherited plan-review from parent ' + sanitize(parent) + ' -> task ' + sanitize(task));
  process.exit(0);
}

// #1575 Lane 1b — the transition gate's plan-review ADMISSION decision, as a single reusable function. The
// bash gate (three-role-transition-gate.sh) shells out to the `gate-plan-review` CLI below instead of
// re-implementing this contract in a second language — ONE evaluator, exercised directly by node-level
// smokes AND by the real gate. Returns { allow, class, detail }; `class` is '' when allow=true, else one of
// the SEVEN named fail-closed classes the plan requires the block message to distinguish:
//   not-finished / no-verdict / negative-verdict / no-bound-reviewer-spawn / inherited-row-unbound-to-parent /
//   deliberate-skip-closed / junk-line
function evaluatePlanReviewGate(session, task) {
  const file = ledgerFile(session, task);
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (e) {
    return { allow: false, class: 'not-finished', detail: file + ' (no ledger file — no plan-review has ever run for this task)' };
  }
  const rawLines = raw.split('\n').filter((l) => l.trim());
  // Evaluate the LAST PARSEABLE plan-review line — explicitly last-match (#1580 will make >=2 lines normal;
  // a first-match read would silently prefer a stale round-1 PASS over a round-2 BLOCK).
  let lastIdx = -1;
  let lastEntry = null;
  const parsedOk = [];
  for (let i = 0; i < rawLines.length; i++) {
    let j = null;
    let ok = true;
    try { j = JSON.parse(rawLines[i]); } catch (e) { ok = false; }
    parsedOk.push(ok);
    if (ok && j && j.role === 'plan-review') { lastIdx = i; lastEntry = j; }
  }
  if (lastIdx === -1) {
    return { allow: false, class: 'not-finished', detail: file + ' (no parseable plan-review line)' };
  }
  // Trailing-junk rule (pinned round 4, fail-closed): any UNPARSEABLE line AFTER the last parseable
  // plan-review line blocks — post-#1580 a "valid-PASS then junk" file is otherwise ambiguous between two
  // readings, and fail-closed is the safe one.
  for (let i = lastIdx + 1; i < parsedOk.length; i++) {
    if (!parsedOk[i]) {
      return { allow: false, class: 'junk-line', detail: file + ' (unparseable line ' + (i + 1) + ' follows the last plan-review line)' };
    }
  }
  const e = lastEntry;
  // Universal verdict screen (an ALLOWLIST in the code, never a denylist — D3): runs FIRST, on EVERY arm,
  // regardless of any other field on the line.
  const verdict = typeof e.verdict === 'string' ? e.verdict.toUpperCase().trim() : '';
  if (!verdict) {
    if ('skip_reason' in e && !e.agentId && !e.inherited_from) {
      return { allow: false, class: 'deliberate-skip-closed', detail: file + ' (line ' + (lastIdx + 1) + ') — there is NO skip path for plan-review at this gate' };
    }
    return { allow: false, class: 'no-verdict', detail: file + ' (line ' + (lastIdx + 1) + ') — no verdict recorded yet' };
  }
  if (!AFFIRMATIVE_VERDICTS.has(verdict)) {
    return { allow: false, class: 'negative-verdict', detail: file + ' (line ' + (lastIdx + 1) + ', verdict=' + verdict + ') — the review did not pass; re-plan, re-review' };
  }
  // Arm 1 — completed-review (primary): affirmative verdict (screened above) AND closedAt (the SubagentStop
  // punch-out) AND agentId, AND that agentId is SPAWN-RECORD-bound to 3ROLE_TASK:<task> ROLE:plan-review.
  if (e.closedAt && e.agentId && !e.inherited_from) {
    if (agentBoundToTag(session, e.agentId, task, 'plan-review')) return { allow: true, class: '', detail: '' };
    return {
      allow: false, class: 'no-bound-reviewer-spawn',
      detail: file + ' (line ' + (lastIdx + 1) + ') — agentId "' + e.agentId + '" is not spawn-record-bound to ' +
        '3ROLE_TASK:' + task + ' ROLE:plan-review (its transcript\'s FIRST record does not carry that tag)',
    };
  }
  // Arm 2 — inherited-review: inherited_from + agentId + artifact_path present, AND that agentId is
  // PARENT-bound (spawn-record carries 3ROLE_TASK:<inherited_from> ROLE:plan-review).
  if (e.inherited_from && e.agentId && e.artifact_path) {
    if (agentBoundToTag(session, e.agentId, e.inherited_from, 'plan-review')) return { allow: true, class: '', detail: '' };
    return {
      allow: false, class: 'inherited-row-unbound-to-parent',
      detail: file + ' (line ' + (lastIdx + 1) + ') — agentId "' + e.agentId + '" is not spawn-record-bound to ' +
        'parent 3ROLE_TASK:' + e.inherited_from + ' ROLE:plan-review',
    };
  }
  // Neither arm's structural shape is satisfied (missing closedAt/agentId, or an incomplete inherited row).
  return {
    allow: false, class: 'not-finished',
    detail: file + ' (line ' + (lastIdx + 1) + ') — missing completed-review evidence (closedAt + bound agentId, ' +
      'or a complete inherited row)',
  };
}

// #1575: gate-plan-review --session S --task T -> exit 0 (ALLOW, silent) or exit 2 (BLOCK, stderr names the
// evidence class + the ledger file/line). The transition gate's ENTIRE plan-review-admission decision lives
// HERE (evaluatePlanReviewGate) — the bash hook is a thin caller, not a second implementation.
function cmdGatePlanReview(o) {
  const session = o.session, task = o.task;
  if (!session || !task) { console.error('gate-plan-review: --session and --task are required'); process.exit(2); }
  const r = evaluatePlanReviewGate(session, task);
  if (r.allow) { process.exit(0); }
  console.error('BLOCK:' + r.class + '|' + r.detail);
  process.exit(2);
}

function cmdCheck(o) {
  const session = o.session, task = o.task;
  if (!session || !task) { console.log('BLOCK: check requires --session and --task'); process.exit(2); }
  const file = ledgerFile(session, task);
  let lines;
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) {
    console.log('BLOCK: no role-ledger found for task ' + sanitize(task) + ' in this session (' + file +
      '). Append a ledger line per role: node "${CLAUDE_PLUGIN_ROOT}/bin/3role-ledger.mjs" append --session <sid> --task <id> --role <role> ...');
    process.exit(2);
  }
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  // #1276: the vacuous-oracle rejection is OPT-IN via --reject-vacuous-oracle (only the instrumentation
  // gate passes it), so `check`'s other callers keep today's exists+PASS oracle acceptance.
  const checkOpts = { rejectVacuousOracle: ('reject-vacuous-oracle' in o) };
  const problems = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e) { problems.push('missing ' + role + ' ledger line'); continue; }
    const r = checkRole(role, e, session, checkOpts);
    if (r) problems.push(r);
  }
  // #1448 per-role MODEL-POLICY enforcement (opt-in via --enforce-role-models; only the instrumentation gate
  // passes it). Compare each REQUIRED role's ACTUAL transcript model to the tier cc-roles.env resolves for it.
  // Fail-SAFE: no config resolved => skip ENTIRELY (all-opus is the safe default we must not false-block).
  // Per role: inline-skip / missing / unresolvable-agentId / no message.model => fail-open (can't-tell). A
  // mismatch pushes a MODEL-POLICY: problem (=> exit 2). Fable->Opus silent reroute (expected fable, actual
  // opus) is OK-with-note. Also honors the feature kill-switch CC_ROLE_MODEL_GATE_OFF=1 internally (belt &
  // suspenders: the gate already strips the flag, but a direct `check --enforce-role-models` must skip too).
  // #1512 — resume-induced quality up-tier NOTEs (allowed, never silent — AC-3). Populated below, printed
  // near the end alongside PROVENANCE (only reachable when the loop below does NOT push a BLOCK problem).
  const resumeNotes = [];
  if (('enforce-role-models' in o) && process.env.CC_ROLE_MODEL_GATE_OFF === '1') {
    writeBypassLog('3role-ledger-enforce-role-models', 'CC_ROLE_MODEL_GATE_OFF', 'PERMIT');
  }
  if (('enforce-role-models' in o) && process.env.CC_ROLE_MODEL_GATE_OFF !== '1') {
    const { found, cfg } = loadRoleConfig();
    if (found) {
      lintRoleConfig(cfg);   // defect-3 visibility: fires on stderr on every enforce read (loud, once).
      for (const role of REQUIRED_ROLES) {
        const e = byRole[role];
        if (!e || ('skip_reason' in e)) continue;              // no transcript to read for a missing / inline-skip role
        if (!agentResolves(session, e.agentId)) continue;      // presence already reported above; can't-tell here
        // #1458: resolve the tier + the version PIN (if any) BEFORE reading the actual transcript model, so the
        // version sub-leg's fail-closed-on-can't-tell can fire even on the TIER can't-tell path below.
        const expected = roleModelFromCfg(cfg, role);
        const pin = roleVersionFromCfg(cfg, role, expected);
        if (pin && process.env.CC_ROLE_VERSION_GATE_OFF === '1') {
          writeBypassLog('3role-ledger-enforce-role-models', 'CC_ROLE_VERSION_GATE_OFF', 'PERMIT');
        }
        const versionOn = pin && process.env.CC_ROLE_VERSION_GATE_OFF !== '1';
        const actualId = transcriptModel(session, e.agentId);   // concrete id, '' if no assistant model line
        const actual = modelIdToTier(actualId);                 // tier, '' if empty/unknown-prefix
        if (!actual) {                                          // TIER can't-tell (existing fail-open) ...
          if (versionOn) problems.push('MODEL-VERSION: role ' + role + ' — the transcript model is unreadable/' +
            'unparseable (' + (actualId || '<none>') + ') so the ' + expected + ' pin ' + pin + ' CANNOT be ' +
            'verified (fail-closed: a configured pin means we do not wave through can\'t-tell). ' +
            'Kill-switch: CC_ROLE_VERSION_GATE_OFF=1 (or CC_ROLE_MODEL_GATE_OFF=1).');
          continue;                                              // ... but a pin fail-CLOSES the version sub-leg
        }
        if (actual === expected) {                               // tier match => OK; check the version sub-leg
          if (versionOn && actualId !== pin) problems.push('MODEL-VERSION: role ' + role + ' ran on ' + actualId +
            ' but cc-roles.env pins ' + expected + ' -> ' + pin + ' (ASSERT-LATEST drift: the tier latest may ' +
            'have moved, or the role ran on an unexpected version). If ' + actualId + ' is the new blessed ' +
            'latest, update CC_TIER_' + expected.toUpperCase() + '_VERSION (or CC_ROLE_' + roleKeyStem(role) +
            '_MODEL_VERSION), then re-run the plugin sync; else investigate. Kill-switch: CC_ROLE_VERSION_GATE_OFF=1.');
          continue;
        }
        if (expected === 'fable' && actual === 'opus') continue; // Anthropic silent fable->opus reroute => OK-with-note (version sub-leg skipped)
        // #1512 — resume-induced quality UP-tier: allow-with-note, narrowly scoped to (a) the role was
        // genuinely resumed via SendMessage (an unforgeable harness-authored boundary marker, not a proxy
        // event), (b) its PRE-resume model matched policy (so the mismatch is provably resume-caused, not a
        // wrong spawn), and (c) the OBSERVED tier is a STRICT quality up-tier over policy. Anything that
        // fails any of these three (a down-tier, a non-resume mismatch, or a resume whose pre-resume model
        // ALSO didn't match policy) falls straight through to the hard BLOCK below — AC-2's scope guard.
        if (isResumeUpTier(expected, actual)) {
          const rb = resumeBoundaryModels(session, e.agentId);
          if (rb.hasResume && modelIdToTier(rb.preResumeModel) === expected) {
            let note = 'RESUME-UPTIER: role ' + role + ' was resumed via SendMessage (not respawned) — its ' +
              'transcript shows model ' + (rb.preResumeModel || '<none>') + ' (matching policy ' + expected +
              ') BEFORE the resume boundary and ' + actualId + ' (' + actual + ') AFTER it. A resume-induced ' +
              'up-tier is allowed-with-note: it preserves the resumed agent\'s accumulated context (the whole ' +
              'reason to resume instead of respawn), and the only cost is running the rework on a costlier ' +
              'model. Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.';
            if (actual === 'fable') {
              note += ' FABLE-COST-CLIFF: Fable\'s subsidised usage bar expires ~July 7-8; after that a ' +
                'Fable reroute bills out-of-pocket (~2x Opus) — surfaced here so the cost is never hidden.';
            }
            resumeNotes.push(note);
            continue;
          }
        }
        problems.push('MODEL-POLICY: role ' + role + ' ran on ' + actual + ' (transcript model ' + actualId +
          ') but cc-roles.env resolves ' + role + ' -> ' + expected + '. Re-run the role on model:' + expected +
          ', or update CC_ROLE_' + roleKeyStem(role) + '_MODEL in cc-roles.env. Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.');
      }
    }
  }
  // #1100 item 3: provenance flags — a required role that ran as a REAL spawn (not an inline-skip) but whose
  // line lacks the self_authored stamp is provenance-unverified (an orchestrator-fabricated line has no
  // authoring agent turn). By DEFAULT this only SURFACES (never a silent brick — the honest residual: a
  // quiet-but-legit agent that forgot to self-append). Strict-block is opt-IN via --require-provenance.
  const provenanceFlags = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e || ('skip_reason' in e)) continue;        // missing handled above; skips don't have an authoring turn
    if (!e.self_authored) provenanceFlags.push(role);
  }
  const requireProv = ('require-provenance' in o);
  if (requireProv) {
    for (const role of provenanceFlags) problems.push(role + ' lacks a self_authored provenance stamp (--require-provenance)');
  }
  // #1509 Leg A — TRACKED, not merely present. Opt-in via --enforce-tracked-artifacts (only the completion
  // gate passes it; base `check` stays existence-only — AC-3). Role-keyed HARD block for the three disk-path
  // roles; executor is exempt by role but its disk-path row (if any) is surfaced as a NOTE, never blocked.
  const executorNotes = [];
  if ('enforce-tracked-artifacts' in o) {
    for (const role of REQUIRED_ROLES) {
      const e = byRole[role];
      if (!e) continue;   // missing-role already reported by the base existence leg above.
      const tp = checkTrackedRole(role, e);
      if (tp) problems.push('TRACKED: ' + tp);
    }
    const execNote = executorDiskPathNote(byRole['executor']);
    if (execNote) executorNotes.push(execNote);
  }
  // #1537 — artifact-privacy leg. Opt-in via --enforce-artifact-privacy (only the completion gate passes it).
  // DORMANT (no problems pushed, no error) when PRIVACY_SCAN_BIN is unset/unresolvable — the ai-brain-only /
  // plugin-safe discipline (the plugin ports this file but never the scanner, so a plugin install silently
  // no-ops here exactly like the tracked-artifacts leg's HELPER-absence residual elsewhere in this file).
  if ('enforce-artifact-privacy' in o) {
    const scannerBin = process.env.PRIVACY_SCAN_BIN || '';
    if (scannerBin && fileExists(scannerBin)) {
      for (const role of PRIVACY_ROLES) {
        const e = byRole[role];
        if (!e) continue;                            // missing-role already reported by the base existence leg.
        if (classifySkip(e).skip) continue;           // inline-skip has no artifact to scan.
        const ap = resolveDiskPathForRole(role, e);
        if (!ap) continue;                            // no resolvable disk path -> not this leg's problem.
        const detail = scanArtifactPrivacy(ap, scannerBin);
        if (detail) problems.push('PRIVACY: ' + role + ' artifact "' + ap + '" FAILED the privacy scan (' + detail + ')');
      }
      // The run's cited perf-log card (#1537 round-2 scope promotion). Boundary rule: IN scope ONLY when it
      // resolves to a file that is git-tracked INSIDE the ai-brain repo (reuse isGitTracked — the SAME
      // discriminator Leg A uses). Anything else (out-of-repo path, in-repo-but-untracked, unresolvable) is
      // fail-OPEN here: not scanned, no error, no block — an ai-brain completion gate structurally has no
      // jurisdiction over a file it cannot prove is a shipped ai-brain artifact.
      const perfLog = o['perf-log'] || '';
      if (perfLog && isGitTracked(perfLog) === true) {
        const detail = scanArtifactPrivacy(perfLog, scannerBin);
        if (detail) problems.push('PRIVACY: perf-log card "' + perfLog + '" FAILED the privacy scan (' + detail + ')');
      }
    }
  }
  if (problems.length) { console.log('BLOCK: ' + problems.join('; ')); process.exit(2); }
  if (resumeNotes.length) {
    console.log('NOTE: ' + resumeNotes.join(' | '));
  }
  if (executorNotes.length) {
    console.log('NOTE-EXECUTOR: ' + executorNotes.join(' | '));
  }
  if (provenanceFlags.length) {
    console.log('PROVENANCE: ' + provenanceFlags.join(', ') +
      ' provenance-unverified (no self_authored stamp — orchestrator-fabricated or a quiet agent that did not self-append)');
  }
  console.log('OK: role-ledger complete for task ' + sanitize(task) +
    ' (planner, plan-review, executor, execution-review all resolved)');
  process.exit(0);
}

// #860: resolve-agent --session S --task T --role R -> newest-mtime tagged transcript's agentId on stdout.
function cmdResolveAgent(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('resolve-agent: --session, --task, --role are required'); process.exit(2); }
  const agentId = resolveAgent(session, task, role);
  if (!agentId) process.exit(1);   // no transcript carries the tag — print nothing, fail.
  console.log(agentId);
  process.exit(0);
}

// #1303: resolve-artifact --session S --task T --role R -> existence-checked absolute artifact_path on stdout.
// Reuses ledgerFile() + resolveArtifact() (the load-bearing helpers) and the SAME last-line-per-role parse
// cmdCheck/cmdInherit use. Exits non-zero on every "no usable artifact" branch so the gate falls back to the
// convention dir (the #1266 ledger-first fix). Only artifact_path is read — verdict/skip fields are ignored.
function cmdResolveArtifact(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('resolve-artifact: --session, --task, --role are required'); process.exit(2); }
  const file = ledgerFile(session, task);
  let lines;
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); }
  catch (e) { process.exit(1); }   // no ledger -> caller falls back to convention dir
  const byRole = {};
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
  const e = byRole[role];
  if (!e || !e.artifact_path || String(e.artifact_path).trim() === '') process.exit(1);
  const abs = resolveArtifact(e.artifact_path); // expands ~ / CLAUDE_PROJECT_DIR / cwd / $HOME, '' if not on disk
  if (!abs) process.exit(1);
  console.log(abs);
  process.exit(0);
}

// #1350: heartbeat --session S --task T -> bump <task>.jsonl mtime to ~now (touch-existing OR create-zero-byte).
// Writes NO JSONL line (AC-4 non-corruption by construction). ALWAYS exits 0 (fail-open) — a heartbeat error
// must never wedge the spawn it instruments, so the whole body is wrapped and every failure path returns 0.
function cmdHeartbeat(o) {
  try {
    const session = o.session, task = o.task;
    // Missing args -> nothing to touch; fail-open (do NOT exit 2 like the other subcommands).
    if (!session || !task) process.exit(0);
    const file = ledgerFile(session, task);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    if (!fileExists(file)) {
      // Create a ZERO-byte file. 'a' (append) NEVER truncates — so even on a race where a real append just
      // created a non-empty <task>.jsonl, this opens-and-closes without clobbering its content.
      fs.closeSync(fs.openSync(file, 'a'));
    }
    // Advance mtime to ~now (the entire board signal). Content is left untouched on every path.
    const now = new Date();
    fs.utimesSync(file, now, now);
  } catch (e) { /* fail-open: a heartbeat error never blocks the spawn */ }
  process.exit(0);
}

// #1481: refresh-models --session S -> in-flight model backfill (the NEW in-flight TRIGGER'S oracle unit;
// see the file-header doc block above). Walks <LEDGER_DIR>/<S>/*.jsonl; for each REQUIRED-role line that
// lacks a modelVersion and is not inline-skipped, re-resolves the model via the SAME resolveModelFields()
// helper cmdAppend uses and overlay-appends ONLY the model fields (idempotent, absent->present only —
// never rewrites an already-present model, never touches agentId/artifact_path/effort/verdict/
// self_authored). Fires kanban-resync.sh (backgrounded) at most ONCE per invocation, only when >=1 role
// actually changed. ALWAYS exits 0 (fail-open) — mirrors cmdHeartbeat's contract: a refresh error must
// never wedge the caller (a backgrounded hook trigger with no one watching stderr).
function cmdRefreshModels(o) {
  try {
    const session = o.session;
    if (!session) { console.log('OK refresh-models: no --session given (fail-open, nothing to do)'); process.exit(0); }
    const sess = sanitize(session);
    const dir = path.join(LEDGER_DIR, sess);
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')); }
    catch (e) { console.log('OK refresh-models: no ledger dir for session ' + sess); process.exit(0); }
    let scanned = 0;
    let changed = 0;
    for (const fn of files) {
      const task = fn.slice(0, -('.jsonl'.length));
      const file = path.join(dir, fn);
      let lines;
      try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); }
      catch (e) { continue; }
      const byRole = {};
      for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role) byRole[j.role] = j; } catch (e) { /* skip */ } }
      for (const role of REQUIRED_ROLES) {
        const e = byRole[role];
        if (!e) continue;                       // no line for this role yet -> nothing to refresh
        if ('skip_reason' in e) continue;        // inline-skip -> no transcript to read
        if (e.modelVersion) continue;            // ABSENT->PRESENT ONLY: already has a model, never rewrite
        scanned++;
        const modelFields = resolveModelFields(sess, task, role, e.agentId || '');
        if (!modelFields.modelVersion) continue; // transcript still carries no message.model line yet -> too early
        overlayAppend(sess, task, role, modelFields);
        changed++;
      }
    }
    if (changed > 0) fireResyncBackground();
    console.log('OK refresh-models: session=' + sess + ' scanned=' + scanned + ' changed=' + changed);
    process.exit(0);
  } catch (e) {
    console.log('OK refresh-models: error (fail-open): ' + (e && e.message ? e.message : e));
    process.exit(0);
  }
}

// #1448: resolve-role-model --role <role> [--with-effort]
// Prints the configured model TIER for a role (the single value the orchestrator + both model hooks consume),
// fail-SAFE to opus (missing/malformed config OR an invalid per-role value => opus). With --with-effort prints
// "<model> <effort>". Lints the config on read (defect-3 stderr visibility). Always exits 0 — a resolver error
// must never wedge a spawn; opus is the safe answer.
function cmdResolveRoleModel(o) {
  const role = o.role;
  if (!role) { console.error('resolve-role-model: --role is required (planner|plan-review|executor|execution-review|orchestrator|research)'); process.exit(2); }
  const { found, cfg } = loadRoleConfig();
  if (found) lintRoleConfig(cfg);
  const model = found ? roleModelFromCfg(cfg, role) : 'opus';
  const effort = found ? roleEffortFromCfg(cfg, role) : '';
  const withEffort = ('with-effort' in o);
  const withVersion = ('with-version' in o);
  if (!withEffort && !withVersion) { console.log(model); process.exit(0); }
  if (withEffort && !withVersion) {
    // #1448 shape, UNCHANGED for back-compat (three-role-model-policy-gate.sh does `read -r EXPECTED EFFORT`):
    // "<model> <effort>", or bare "<model>" when no effort is configured (no trailing empty token).
    console.log(model + (effort ? ' ' + effort : ''));
    process.exit(0);
  }
  // #1466 — version requested (alone, or together with effort). roleVersionFromCfg's per-role/per-tier pin,
  // falling back to the tier alias itself when unset, so `version` is NEVER empty — a spawn-time badge stamp
  // must always have something non-blank to show. When effort is ALSO requested but unresolved, use a `-`
  // sentinel (not '') so a plain `read -r A B C` over the space-joined line always yields exactly 3 tokens.
  const version = (found && roleVersionFromCfg(cfg, role, model)) || model;
  const tokens = withEffort ? [model, effort || '-', version] : [model, version];
  console.log(tokens.join(' '));
  process.exit(0);
}

// #1494: resolve-effective-tier --model M --subagent-type T --transcript P [--session S] [--agents-dir D]
//        [--projects-root R]
// CLI mirror of resolveEffectiveTier() — prints "<tier> <source> agentdef=<tier|none>" on stdout, ALWAYS
// exits 0 (like resolve-role-model; a resolver error must never wedge the caller — it already fails CLOSED
// to tier=unknown internally, which is the caller's cue to block, not a process-level failure).
function cmdResolveEffectiveTier(o) {
  const r = resolveEffectiveTier({
    model: o.model,
    subagentType: o['subagent-type'],
    transcriptPath: o.transcript,
    session: o.session,
    agentsDir: o['agents-dir'],
    projectsRoot: o['projects-root'],
  });
  console.log(r.tier + ' ' + r.source + ' agentdef=' + (r.agentdefTier || 'none'));
  process.exit(0);
}

// ── #1543 log-bypass — the single shared WRITE-TIME attributed bypass-audit path ───────────────────────
// Every ai-brain hook that reads a `*_OVERRIDE`/`*_OFF` kill-switch and honors it routes through THIS
// subcommand instead of hand-rolling its own `echo ... >> .rule-12-overrides.log` line (the ~21 legacy
// writers) or staying silent (the ~61 readers that logged nothing — the #1543 core defect). One JSONL
// record per exercised bypass: `{ts,session,agent,task,role,hook,var,decision}` — see
// docs/rule-12-overrides-log-schema.md for the published shape.
//
// CLI surface (AC-4 / N5 — STRUCTURAL privacy enforcement): `log-bypass --hook H --var V --decision
// PERMIT|DENY [--session S] [--agent-id A] [--agent-type T]`. There is NO `--cmd` / command / positional
// parameter ANYWHERE on this subcommand — raw command text is UNREACHABLE by construction, not merely
// "not currently passed". When session/agent-id/agent-type are omitted, the CLI best-effort reads them
// from a JSON payload on STDIN (mirroring the hook's own PreToolUse payload, which the bash wrapper
// `hook_log_bypass` in lib-hook-override.sh pipes through unmodified) — but the STDIN parse below reads
// ONLY the three keys `session_id`/`agent_id`/`agent_type`; it never references `tool_input` or any
// command-bearing field, so piping a full raw hook payload (which DOES contain `tool_input.command` for
// a Bash hook) still cannot leak command text — the parser structurally never looks at that key.
//
// Attribution (AC-0a/AC-0b, live-captured 2026-07-11 — see
// .ai-workspace/research/2026-07-11-1543-in-subagent-pretooluse-bash-payload-capture.md):
//   - `agent_id` PRESENT  -> subagent-originated. Locate the dedicated per-agent transcript
//     `<PROJECTS_ROOT>/<slug>/<session>/subagents/agent-<agent_id>.jsonl` (the exact file
//     `agentResolves()`/`resolveAgent()` already target — mirrors, does not reuse, since the direction is
//     inverted: agentId -> task/role, not task/role -> agentId). Parse ONLY that file's FIRST JSONL
//     record's `message.content` text (never a raw whole-file grep — the parent transcript AND a
//     whole-file scan of the subagent transcript are both measured-polluted with historical/doc-example
//     `3ROLE_TASK:... ROLE:...` text re-injected on later turns; the tag is unambiguous only in the
//     original dispatch message). Regex `3ROLE_TASK:(\S+) ROLE:(\S+)` against that text. Match -> stamp
//     the real task/role. No match / file missing -> fall back to the untagged-subagent sentinel
//     (task:"", role:"") — NEVER fabricate a role for a subagent whose dispatch prompt carried no tag.
//   - `agent_id` ABSENT -> main-session/orchestrator event (measured discriminator, #1494 + this
//     capture). Stamped IMMEDIATELY as the orchestrator sentinel (task:"", role:"orchestrator") — the
//     transcript is NEVER parsed for a tag on this path (that is what keeps the doc/memory pollution
//     above from ever reaching a main-session record, not just an optimization).
function readStdinJSON() {
  try {
    if (process.stdin.isTTY) return null;
    const raw = fs.readFileSync(0, 'utf8');
    if (!raw || !raw.trim()) return null;
    const d = JSON.parse(raw);
    // Structural privacy enforcement: extract ONLY these three keys. Do not reference d.tool_input or
    // any other field anywhere in this function — that is what makes raw command text unreachable even
    // when a full raw hook payload is piped in.
    return {
      session_id: d.session_id != null ? String(d.session_id) : '',
      agent_id: d.agent_id != null ? String(d.agent_id) : '',
      agent_type: d.agent_type != null ? String(d.agent_type) : '',
    };
  } catch (e) { return null; }
}

// Parse ONLY message.content text of the subagent transcript's FIRST record for the live 3ROLE_TASK tag.
// #1575: reuses the shared firstRecordText() extractor (Lane 1c — ONE predicate, not a second copy).
function tagFromSubagentTranscript(session, agentId) {
  const sess = sanitize(session);
  const aid = String(agentId == null ? '' : agentId).replace(/[^0-9A-Za-z_-]/g, '');
  if (!sess || !aid) return null;
  let slugs = [];
  try { slugs = fs.readdirSync(PROJECTS_ROOT); } catch (e) { return null; }
  for (const slug of slugs) {
    const f = path.join(PROJECTS_ROOT, slug, sess, 'subagents', 'agent-' + aid + '.jsonl');
    if (!fileExists(f)) continue;
    let content;
    try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
    const text = firstRecordText(content);
    if (!text) continue;
    const m = text.match(/3ROLE_TASK:(\S+) ROLE:(\S+)/);
    if (m) return { task: m[1], role: m[2] };
  }
  return null;
}

function rule12LogPath() {
  return process.env.RULE12_LOG || path.join(HOME, '.claude', '.rule-12-overrides.log');
}

// #1543 — internal (in-process, non-exiting) sibling of cmdLogBypass for this file's OWN bypass-var
// reads (e.g. the `check --enforce-role-models` kill-switches below). Those call sites are a direct
// CLI/library invocation with no PreToolUse hook payload to read session/agent context from — same
// honest "no Claude Code session context" case as post-commit-auto-push.sh's native-git-hook path —
// so they correctly fall to the orchestrator sentinel (AC-8: never a fabricated role). Best-effort,
// never throws — a logging failure must never affect the caller's gate decision.
function writeBypassLog(hookName, varName, decision) {
  try {
    const record = {
      ts: new Date().toISOString(),
      session: '',
      agent: '',
      task: '',
      role: 'orchestrator',
      hook: sanitize(hookName),
      var: String(varName || '').replace(/[^A-Za-z0-9_]/g, ''),
      decision: (String(decision).toUpperCase() === 'DENY') ? 'DENY' : 'PERMIT',
    };
    const logPath = rule12LogPath();
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, JSON.stringify(record) + '\n');
  } catch (e) { /* best-effort — never throws, never blocks the caller */ }
}

// #1543 AC-4/N5: the ONLY key set ever written — a positional/`--cmd` param does not exist on this CLI,
// so there is no code path that could add a command-text key even if a caller tried to smuggle one in.
function cmdLogBypass(o) {
  const hookName = sanitize(o.hook || '');
  const varName = String(o.var || '').replace(/[^A-Za-z0-9_]/g, '');
  const decision = (String(o.decision || '').toUpperCase() === 'DENY') ? 'DENY' : 'PERMIT';
  if (!hookName || !varName) {
    console.log('BLOCK: log-bypass requires --hook and --var');
    process.exit(2);
  }
  const stdinPayload = readStdinJSON();
  const session = o.session || (stdinPayload && stdinPayload.session_id) || '';
  const agentId = o['agent-id'] || (stdinPayload && stdinPayload.agent_id) || '';
  const agentType = o['agent-type'] || (stdinPayload && stdinPayload.agent_type) || '';

  let task = '', role = '';
  if (agentId) {
    const tag = tagFromSubagentTranscript(session, agentId);
    if (tag) { task = tag.task; role = tag.role; }
    // else: subagent-originated but untagged -> task/role stay "" (distinguishable from a real role,
    // never fabricated; distinct from the orchestrator sentinel because `agent` is still non-empty).
  } else {
    role = 'orchestrator';
  }

  const record = {
    ts: new Date().toISOString(),
    session: sanitize(session),
    agent: String(agentId || '').replace(/[^0-9A-Za-z_-]/g, ''),
    task: sanitize(task),
    role: sanitize(role) || (agentId ? '' : 'orchestrator'),
    hook: hookName,
    var: varName,
    decision,
  };
  const logPath = rule12LogPath();
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, JSON.stringify(record) + '\n');
  } catch (e) {
    console.log('WARN: log-bypass could not write ' + logPath + ': ' + (e && e.message ? e.message : e));
    process.exit(0); // logging must never block the caller's gate — fail-open
  }
  console.log('OK: logged ' + hookName + '/' + varName + ' -> ' + logPath);
  process.exit(0);
  // (agentType is intentionally unused beyond availability for a future soft-fallback; keeping it
  // resolved-but-unused documents that it WAS considered, per the AC-0a capture's agent_type field.)
  void agentType;
}

const [, , cmd, ...rest] = process.argv;
const opts = parseArgs(rest);
try {
  if (cmd === 'append') cmdAppend(opts);
  else if (cmd === 'check') cmdCheck(opts);
  else if (cmd === 'heartbeat') cmdHeartbeat(opts);
  else if (cmd === 'refresh-models') cmdRefreshModels(opts);
  else if (cmd === 'resolve-agent') cmdResolveAgent(opts);
  else if (cmd === 'resolve-artifact') cmdResolveArtifact(opts);
  else if (cmd === 'resolve-role-model') cmdResolveRoleModel(opts);
  else if (cmd === 'resolve-effective-tier') cmdResolveEffectiveTier(opts);
  else if (cmd === 'inherit-plan-review') cmdInherit(opts);
  else if (cmd === 'gate-plan-review') cmdGatePlanReview(opts);
  else if (cmd === 'log-bypass') cmdLogBypass(opts);
  else {
    console.log('usage: 3role-ledger.mjs <append|check|heartbeat|refresh-models|resolve-agent|resolve-artifact|resolve-role-model|resolve-effective-tier|inherit-plan-review|gate-plan-review|log-bypass> ' +
      '--session S --task T [--role R --agent A --artifact P --skip-reason "..." --oracle P] [--parent P (inherit-plan-review)] ' +
      '[--session S (refresh-models)] [--role R [--with-effort] (resolve-role-model)] [--enforce-role-models (check)] ' +
      '[--enforce-tracked-artifacts (check, #1509)] ' +
      '[--enforce-artifact-privacy [--perf-log P] (check, #1537)] ' +
      '[--model M --subagent-type T --transcript P [--agents-dir D] [--projects-root R] (resolve-effective-tier)] ' +
      '[--session S --task T (gate-plan-review, #1575)] ' +
      '[--hook H --var V --decision PERMIT|DENY [--session S --agent-id A --agent-type T] (log-bypass, #1543)]');
    process.exit(2);
  }
} catch (e) {
  console.log('BLOCK: ledger helper error: ' + (e && e.message ? e.message : e));
  process.exit(2);
}

// #1494 frozen contract for #1497 Key-1 (role eligibility) — a future direct-JS consumer imports these
// instead of shelling out to the CLI. Exporting does not change this file's own CLI-dispatch behavior above
// (a plain `resolve-effective-tier` CLI invocation, unqualified by path, is unaffected).
export { resolveEffectiveTier, lastAssistantModelFromFile };
