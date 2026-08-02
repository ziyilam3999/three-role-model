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
//   check --session S --task T --enforce-tracked-artifacts --perf-log P                        (#1544)
//     Perf-log tracked-check, riding the SAME Leg A flag (git-only, always-on — NOT the privacy leg, so
//     THREE_ROLE_ARTIFACT_PRIVACY_OFF=1 cannot erase it — monotonicity, #1590). JURISDICTION-KEYED (the fix
//     for the #1544 false-blocker BLOCKER): a "TRACKED:" problem fires ONLY when P resolves to a file whose
//     containing-repo toplevel EQUALS the ai-brain toplevel (derived from this ledger file's own resolved
//     location, symlink-aware) AND that file is untracked. Any other outcome fails OPEN (exit 0, no
//     problem): a different real git repo (a legitimate perf-log home outside ai-brain), a non-repo path (the
//     template's real home, `~/.claude/agent-working-memory/...`, is NOT a git worktree), or an unresolvable
//     path (nothing to check). This is deliberate — the gate has no jurisdiction over a file it cannot prove
//     is a shipped ai-brain artifact. No grace/bypass flag by design (mirrors Leg A above); the only escapes
//     are (a) `git add`+commit the cited perf-log (when it does live in ai-brain), or (b) the master
//     THREE_ROLE_INSTRUMENT_OFF=1.
//   check --session S --task T --enforce-artifact-role-kind                                    (#1532)
//     Executor artifact-KIND leg — the #1494 fix. Opt-in (only the instrumentation gate passes this flag on
//     the tagged completion path). Catches an executor row whose artifact_path resolves to the PLANNER's
//     plan-kind document instead of a real ship reference (PR URL / commit sha / branch) — #1494's exact
//     shape, previously only a silently-dropped "NOTE-EXECUTOR:" line (#1509). HARD CONSTRAINT: engages ONLY
//     when the executor artifact_path resolves to an EXISTING DISK PATH (resolveArtifact) — a PR-URL/commit/
//     branch never resolves to disk, so it short-circuits out before either predicate below runs; this leg
//     can never existence- or git-check a legitimate ship-reference executor row. Among disk-resolving
//     executor rows, "plan-kind" (=> a "KIND:" problem, exit 2) is evidenced by EITHER (a) the resolved path
//     equals THIS task's planner row's resolved path (the exact #1494 shape), OR (b) the resolved path lies
//     on a `/.ai-workspace/plans/` segment (any other plan-kind document). A disk-resolving executor artifact
//     satisfying NEITHER (e.g. a genuinely executor-authored SKILL.md/.mjs off any plans/ path) is NOT
//     plan-kind and passes — guards against an over-broad "block any disk path" regression. Deliberately does
//     NOT implement "no two roles may cite the same path" (rejected on measured evidence: 43+ legitimate
//     planner==plan-review collisions — the doctrine-sanctioned reviewer-writes-into-the-plan-file pattern).
//     Same no-new-bypass-token discipline as Leg A above: THREE_ROLE_INSTRUMENT_OFF=1 is the only escape.
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
//   reconcile-spawns --session S                                    (#1229, incremental rewrite #1851)
//     MISSING-ROW backfill for the dropped-harness-event gap: for a meaningful fraction of background Agent
//     dispatches, NEITHER the spawn-ledger hook (PostToolUse) NOR the SubagentStop ledger hook fires, even
//     though the subagent's own transcript genuinely exists at <PROJECTS_ROOT>/*/<S>/subagents/agent-<id>.jsonl
//     and its spawn record carries a `3ROLE_TASK:<task> ROLE:<role>` tag — so the ledger row is ABSENT
//     entirely (refresh-models cannot help; it only touches EXISTING rows, see cmdRefreshModels above).
//     #1851 — the ORIGINAL implementation called resolveAgent() (a full corpus re-scan) ONCE PER (task, role)
//     GROUP, making the sweep O(G x corpus) (~1,006 groups x 979 MB ~= 1 TB decoded, ~24.5 min CPU on a
//     marathon session — measured). The coarse watermark below never engaged on a live session (some
//     transcript is always advancing), so a runaway sweep pinned a CPU core essentially continuously. This
//     rewrite collapses that to O(corpus), by construction, via three changes (D1/D2/D3 of
//     .ai-workspace/plans/2026-07-27-1851-reconcile-spawns-incremental.md):
//       D1 (hoist) — the discovery pass below extracts EVERY transcript's spawn-tag facts ONCE (not once per
//         group): a DISCOVERY tag (the loose first-match rule the old code used to populate `groups`) and every
//         WINNER-candidate tag (re-verified as a literal substring of the sanitize()-reconstructed tag string,
//         reproducing resolveAgent()'s `.includes()` semantics exactly — including its two documented seams: a
//         task id containing a sanitize()-stripped character correctly fails to bind, and a first record naming
//         TWO tags correctly binds to BOTH groups). The group loop then does a Map lookup, never a corpus scan.
//       D2 (bounded read) — `readFirstNonEmptyLine()` reads only up to the transcript's first NON-EMPTY line
//         (matching firstRecordText()'s own `.find(l => l.trim())` predicate exactly, never a looser "read line
//         1"), growing its read window until it finds that line or hits EOF — never a fixed cap that silently
//         truncates a transcript out of the mapping (D2's "single worst regression" this fix could cause).
//       D3 (per-file checkpoint) — a per-session sidecar (`.reconcile-checkpoint.json`, dotted so invisible to
//         the `.jsonl` glob cmdRefreshModels/cmdCheck use) caches each transcript's derived tag facts keyed on
//         file IDENTITY (dev+ino) + size-at-derive-time; unchanged-or-grown files reuse the cache (D2's read
//         never happens again), a REPLACED (new identity) or SHRUNK (possible truncation/rewrite) file is
//         re-derived. Rests on the load-bearing, Rule-18-gated assumption that a subagent transcript's first
//         record never changes once written (append-only) — degraded safely by a MANDATORY periodic full
//         re-derivation (every RECONCILE_SPAWNS_FULL_REDERIVE_EVERY_N runs, or when the last full derive is
//         older than RECONCILE_SPAWNS_FULL_REDERIVE_MAX_AGE_MS) that ignores the cache outright.
//     D4/D6 correctness: the group -> row loop still evaluates EVERY known group EVERY run (no transcript is
//     ever "too old" to enter the mapping; a cold start or a corrupt/unreadable/schema-mismatched sidecar —
//     schema-versioned — is treated as a full re-derivation, never "nothing to do"). `modelVersion` resolution
//     is now GATED on `!prior.modelVersion` (previously unconditional — a fixed bug: an already-stamped row paid
//     a full transcript re-parse on every sweep forever); `self_authored` keeps its existing `!prior.self_authored`
//     gate. Both gates are the POSITIVE-side skip only — a row that legitimately never earns a field is
//     re-attempted every run it's still missing (a known, bounded, OBSERVABLE residual cost — see
//     `laterRecordRederives` in the log line below — never a WRONG ledger value, since the row is either still
//     unstamped or is correctly stamped once the fact becomes available). Root-cause fix (AC2(ii)): when EITHER
//     field is missing, `deriveLaterRecordFacts()` derives BOTH from a SINGLE read+parse of the winner's
//     transcript (using its path already known from the corpus pass) instead of two independent full re-reads
//     (resolveModelFields->transcriptModel, then transcriptSelfAuthored) — halving the per-group residual cost,
//     which is what made it scale visibly with GROUP COUNT on a cold sweep (measured under CPU throttling; see
//     deriveLaterRecordFacts's own header comment). D4(c): the coarse watermark now
//     advances ONLY after a sweep that completed with nothing truncated or row-failed (previously unconditional
//     — a real bug: a failed row was never retried unless some transcript's mtime happened to advance).
//     D5 bounded worst case: a wall-clock budget (RECONCILE_SPAWNS_BUDGET_MS) bounds the WHOLE sweep (both the
//     tag-derivation pass, run OLDEST-transcript-first for strict forward progress, and the group loop);
//     exceeding it STOPS the sweep, PERSISTS every per-file checkpoint already earned, does NOT advance the
//     coarse watermark, and still exits 0 — the union of a truncated run plus its successors equals one
//     unbounded run (transcripts/groups a truncated run didn't reach are simply left for the next invocation,
//     which resumes cheaply from the persisted cache).
//     Every per-row overlayAppend call is individually wrapped — one row's failure is logged-and-skipped, never
//     fatal (and marks the sweep as row-failed for the D4(c) watermark rule above). Fires kanban-resync.sh
//     (backgrounded, fail-open) exactly ONCE per invocation, ONLY when >=1 row actually changed. Idempotent: a
//     group with nothing left to add makes NO overlayAppend call at all (byte-identical ledger on a no-op run).
//     Never stamps `closedAt` or `artifact_path` (unchanged from the original design — a transcript existing on
//     disk does not prove the subagent stopped, and a swept row must never be able to launder a completion).
//     Prints one structured completion line prefixed `OK reconcile-spawns: session=... scanned=... changed=...`
//     (the original prefix, kept — verified zero consumers outside this file via `git grep`, so extending it is
//     safe) followed by: transcripts=<N> firstRecordsRead=<R> firstRecordsCached=<C> groupsKnown=<G>
//     groupsEvaluated=<E> laterRecordRederives=<count> elapsedMs=<ms> truncated=<bool> coldStart=<bool>
//     fullRederive=<bool>. ALWAYS exits 0 (fail-open) — a sweep error must never wedge the hook call it rides
//     (hooks/lane-heartbeat.sh, piggybacked on the SAME throttled touch-branch refresh-models already uses).
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
//   provenance-kind --session S --task T --role R                    (#2075 Phase 1, AC-1)
//     Prints exactly one of E1|E2|E3|none (optionally " legacy"-suffixed) on stdout, exit 0, for the LAST
//     line recorded for this role — including a missing row, which prints 'none'. This is D1's REPORTING
//     construction ONLY (min(stored run_kind, verified kind)) — no gate in this file consults it; every
//     write-side guard reads VERIFIED kind directly (recomputed fresh from the row's own evidence every
//     time), so a stored `run_kind` label can only ever make this command's OWN output read lower than the
//     evidence supports, never higher (AC-24's anti-forgery power test).
//   append ... --run-kind witnessed|bound|inferred [--run-id ID] [--run-source S]     (#2075 Phase 1, D1)
//     OPTIONAL provenance-kind fields — written ONLY by the writer that obtained the identity (never
//     re-derived by a reader): `run_id` is the run's own identity (agentId for E1, nonce for E2, absent for
//     E3); `run_kind` is WRITE-ONCE / monotone-non-decreasing under overlayAppend (witnessed(3) > bound(2) >
//     inferred(1) — an incoming write whose rank is <= the row's current stored rank is a no-op on this
//     field alone; the append itself still exits 0 and every OTHER field still merges normally); `run_source`
//     names which writer stamped it, diagnostic only, never consulted by a gate.
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
//   RECONCILE_SPAWNS_BUDGET_MS (#1851) — wall-clock budget bounding a WHOLE reconcile-spawns sweep (default
//                            20000 = 20s — a large safety margin over the ~seconds cold-start the D1/D2 hoist
//                            achieves BY CONSTRUCTION on today's ~2,000-transcript/979MB corpus; this is a
//                            safety net for a corpus far larger than today's, not the primary mechanism). `0`
//                            is a valid value (truncate before processing anything — used by the AC6 smoke to
//                            force truncation deterministically); only an unset/non-numeric/negative value
//                            falls back to the 20s default.
//                            Exceeding it stops the sweep, persists every per-file checkpoint already earned,
//                            and does NOT advance the coarse watermark (D5).
//   RECONCILE_SPAWNS_FULL_REDERIVE_EVERY_N (#1851) — every Nth reconcile-spawns run for a session ignores the
//                            per-file checkpoint cache outright and re-derives every transcript's tag facts
//                            fresh (default 20). Belt-and-braces against the D3 append-only assumption ever
//                            being silently violated (AC5). 0 or unset/invalid disables the count-based trigger
//                            (the age-based trigger below still applies).
//   RECONCILE_SPAWNS_FULL_REDERIVE_MAX_AGE_MS (#1851) — force a full re-derivation when the last one is older
//                            than this many ms (default 21600000 = 6h), independent of the run-count trigger
//                            above. A cold start (no sidecar yet) always counts as "due".

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
//   3. FABLE-CAP-BUDGET — any VALID *_MODEL=fable (cap-budget reminder: up to 50% of the weekly limit, not a
//      deadline — see the "Planner" comment block in cc-roles.env for the full corrected framing).
// #1640 S8(b) — OPTIONAL 2nd param `routes` (an already-loaded SSOT object, or null/undefined). Every EXISTING
// call site passes ONE arg (routes===undefined), so vocabHint stays '' and the INVALID-MODEL message is
// BYTE-IDENTICAL to before (the frozen `resolve-role-model` contract never passes a 2nd arg — see its own call
// sites below, unchanged). ONLY the completion gate's `--enforce-role-models` leg passes a loaded SSOT, so an
// inexpressible/typo legacy value ALSO names the SSOT-declared vocabulary the author may have meant, instead of
// a typo silently reading as "no such thing as a declared switch exists."
function lintRoleConfig(cfg, routes) {
  let vocabHint = '';
  if (routes && typeof routes === 'object' && routes.providers) {
    const tokens = [];
    for (const [pid, row] of Object.entries(routes.providers)) {
      const vocab = (row && row.model_vocabulary) || {};
      for (const [mid, entry] of Object.entries(vocab)) {
        tokens.push(pid + '/' + mid + ' (' + ((entry && entry.tier_equivalent) || '?') + ')');
      }
    }
    if (tokens.length) vocabHint = ' SSOT-declared provider vocabulary you may have meant (config/cc-routes.json): ' + tokens.join(', ') + '.';
  }
  for (const k of Object.keys(cfg)) {
    const m = k.match(/^CC_ROLE_(.+)_MODEL$/);
    if (!m) continue;
    const val = cfg[k];
    if (!ROLE_MODELS.includes(val)) {
      process.stderr.write('INVALID-MODEL cc-roles.env: ' + k + '="' + val + '" is not a known tier ' +
        '(opus|sonnet|haiku|fable) — falling back to opus (you are paying OPUS rates while thinking you set "' +
        val + '").' + vocabHint + '\n');
      continue;   // an invalid value is not also a fable warning.
    }
    if (val === 'fable') {
      if (m[1] === 'ORCHESTRATOR') {
        process.stderr.write('FABLE-ON-ORCHESTRATOR cc-roles.env: ' + k + '=fable — refusing to pin the ' +
          'always-on orchestrator seat to Fable (2x Opus API-billing rate, high-frequency; burns the weekly ' +
          'cap fast). The orchestrator is documented opus-only.\n');
      }
      process.stderr.write('FABLE-CAP-BUDGET cc-roles.env: ' + k + '=fable — Fable is a capped seat: up to ' +
        '50% of the weekly limit, not a deadline (no expiry — the previously-claimed one was voided). Budget ' +
        'it for the highest-leverage work (design, hard research), never a high-volume grunt seat. The ' +
        '~2x-Opus-per-token figure applies to API/usage-credit billing only, not Max-plan-included usage.\n');
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
// #1640 S11 — WIDENED to also consult the SSOT vocabulary (identifyModelViaSSOT, defined in the M0 section
// below — forward reference; hoisted `function` declarations make this safe) when the value is neither a
// tier alias nor a claude-* id: a genuinely-declared non-Anthropic id (e.g. a qwen/gemma tag) now resolves to
// its SSOT tier_equivalent instead of falling through to 'unknown'. STRICTLY ADDITIVE — a value that resolved
// via the tier-alias or claude-* branch is UNCHANGED, and a value in NEITHER the alias list, NOR claude-*, NOR
// any provider's declared vocabulary still correctly returns '' (unknown) exactly as before.
function modelIdOrAliasToTier(v) {
  const s = String(v == null ? '' : v).trim().toLowerCase();
  if (!s) return '';
  if (ROLE_MODELS.includes(s)) return s;
  const legacy = modelIdToTier(s);
  if (legacy) return legacy;
  return identifyModelViaSSOT(v);
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
          else {
            // #1640 S11 — widen: a session-inherited non-Anthropic model id (e.g. the whole session is running
            // under a rerouted ANTHROPIC_BASE_URL gateway) resolves via the SSOT vocabulary instead of falling
            // through to 'unknown'. A model id in NEITHER claude-* form NOR any declared provider vocabulary
            // still correctly stays unknown/unknown below (can't-tell) — this only WIDENS what resolves.
            const w = identifyModelViaSSOT(modelId);
            if (w) { out.tier = w; out.source = 'session'; }
          }
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
  return firstRecordTextFromLine(firstLine);
}

// #1851 D2 — the JSON-envelope-extraction body factored OUT of firstRecordText() so a caller that already
// has the isolated first-non-empty-LINE (e.g. readFirstNonEmptyLine()'s bounded read below) can reuse the
// EXACT SAME extraction, never a second, potentially-diverging parser. Fed a falsy/unparseable line, returns
// '' (fails closed to "no match"), identical to firstRecordText()'s own contract.
function firstRecordTextFromLine(firstLine) {
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

// #1851 D2 — bounded read of a transcript's FIRST NON-EMPTY line, cost proportional to THAT line's size, not
// the whole file. Grows its read window (in RECONCILE_READ_CHUNK_BYTES steps) until it finds the
// line-terminating newline or reaches EOF — never a fixed cap that gives up, which would silently truncate a
// transcript out of the reconciliation mapping (D2: "the single worst regression this plan can cause").
// Matches firstRecordText()'s own predicate exactly — the first NON-empty line (`.find(l => l.trim())`), not
// literally byte-offset-0 line 1 — so a leading blank line degrades identically whether read via this bounded
// path or the whole-file path (the F2 plan-review finding: a naive "read to the first \n" would diverge from
// firstRecordText's actual "first non-empty line" semantics on such a file). Fails OPEN (returns '') on any
// open/read error, mirroring firstRecordText()'s own unreadable-file contract.
const RECONCILE_READ_CHUNK_BYTES = 8192;
function readFirstNonEmptyLine(filePath) {
  let fd;
  try { fd = fs.openSync(filePath, 'r'); } catch (e) { return ''; }
  try {
    let buf = Buffer.alloc(0);
    let pos = 0;
    for (;;) {
      // Drain every complete line already buffered before issuing another read — avoids a redundant syscall
      // when the first non-empty line is already fully inside `buf` from a prior chunk.
      for (;;) {
        const nl = buf.indexOf(0x0a);
        if (nl === -1) break;
        const line = buf.subarray(0, nl).toString('utf8');
        if (line.trim()) return line;
        buf = buf.subarray(nl + 1);
      }
      const chunk = Buffer.alloc(RECONCILE_READ_CHUNK_BYTES);
      let n;
      try { n = fs.readSync(fd, chunk, 0, RECONCILE_READ_CHUNK_BYTES, pos); } catch (e) { break; }
      if (n <= 0) break; // EOF
      buf = buf.length ? Buffer.concat([buf, chunk.subarray(0, n)]) : chunk.subarray(0, n);
      pos += n;
    }
    // EOF reached with no newline-terminated non-empty line found; the last (possibly unterminated) line in
    // `buf` is still a valid candidate (mirrors String.split('\n') including a trailing unterminated segment).
    const leftover = buf.toString('utf8');
    return leftover.trim() ? leftover : '';
  } finally {
    try { fs.closeSync(fd); } catch (e) { /* ignore */ }
  }
}

// #1851 D1 — extract BOTH tag facts a transcript's first-record TEXT carries, in ONE pass over that (small,
// bounded-read) string:
//   .discovery — the LOOSE, first-match rule the original cmdReconcileSpawns used to populate its `groups`
//     Set: sanitize(task), the RAW captured role (RECORDABLE_ROLES-checked), no reconstructed-substring
//     re-check. Only the FIRST occurrence in the text counts (mirrors the original non-global `.match()`).
//   .winners — every occurrence, each individually re-verified as a literal substring of the
//     SANITIZE()-RECONSTRUCTED tag string (`3ROLE_TASK:<sanitize(task)> ROLE:<role>`). This is the exact
//     predicate resolveAgent()'s `.includes(tag)` test enforces, reproduced without re-scanning every OTHER
//     transcript per group. Preserves both documented seams: (1) a task id containing a sanitize()-stripped
//     character fails the reconstructed-substring check (the tag as WRITTEN in the raw text differs from the
//     sanitized reconstruction) — that transcript never becomes a winner-candidate for that group, matching
//     resolveAgent()'s own '' return for it; (2) a first record naming TWO tags contributes TWO winner
//     candidates (one per occurrence), so it can bind to BOTH groups exactly as `.includes()` would find it
//     from either tag's own reconstructed string, even though only the FIRST occurrence feeds `.discovery`.
function extractTagsFromText(text) {
  const result = { discovery: null, winners: [] };
  if (!text) return result;
  const re = /3ROLE_TASK:(\S+) ROLE:(\S+)/g;
  let m;
  let first = true;
  const seen = new Set();
  while ((m = re.exec(text))) {
    const rawTask = m[1];
    const rawRole = m[2];
    if (first) {
      first = false;
      const dTask = sanitize(rawTask);
      if (dTask && RECORDABLE_ROLES.includes(rawRole)) result.discovery = { task: dTask, role: rawRole };
    }
    const sTask = sanitize(rawTask);
    if (sTask && RECORDABLE_ROLES.includes(rawRole)) {
      const reconstructed = '3ROLE_TASK:' + sTask + ' ROLE:' + rawRole;
      if (text.includes(reconstructed)) {
        const key = sTask + ' ' + rawRole;
        if (!seen.has(key)) { seen.add(key); result.winners.push({ task: sTask, role: rawRole }); }
      }
    }
  }
  return result;
}

// #1851 D3/D6 — per-session INCREMENTAL CHECKPOINT sidecar for cmdReconcileSpawns. Dotted filename (hidden
// from the `.jsonl` task-file glob cmdRefreshModels/cmdCheck use, same precedent as the existing
// `.reconcile-watermark`). Schema-versioned: an unreadable, corrupt, or schema-mismatched file is treated as
// a COLD START (returns the SAME empty shape a genuinely-first-ever run would see) — never as "nothing to
// do" (D6).
const RECONCILE_CHECKPOINT_SCHEMA = 1;
function reconcileCheckpointFile(sess) { return path.join(LEDGER_DIR, sess, '.reconcile-checkpoint.json'); }
function readReconcileCheckpoint(sess) {
  const empty = { schemaVersion: RECONCILE_CHECKPOINT_SCHEMA, runCount: 0, lastFullDeriveTs: 0, files: {} };
  let raw;
  try { raw = fs.readFileSync(reconcileCheckpointFile(sess), 'utf8'); } catch (e) { return empty; }
  let j;
  try { j = JSON.parse(raw); } catch (e) { return empty; }
  if (!j || j.schemaVersion !== RECONCILE_CHECKPOINT_SCHEMA || typeof j.files !== 'object' || !j.files) return empty;
  return {
    schemaVersion: RECONCILE_CHECKPOINT_SCHEMA,
    runCount: Number.isFinite(j.runCount) ? j.runCount : 0,
    lastFullDeriveTs: Number.isFinite(j.lastFullDeriveTs) ? j.lastFullDeriveTs : 0,
    files: j.files,
  };
}
function writeReconcileCheckpoint(sess, data) {
  try {
    const file = reconcileCheckpointFile(sess);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data));
  } catch (e) { /* best-effort — a checkpoint write failure never blocks the sweep (D5/D6 fail-open) */ }
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
  // #1947 (generalized #2075 AC-2) — a completed subprocess dispatch has no agentId (no Agent-subagent
  // transcript exists), so the disjunct above is blind to it; a completed run (dispatch marker +
  // artifact_path) is the same terminal-evidence SHAPE one provenance kind over (mirrors the
  // agentId+artifact_path disjunct exactly) — provider-agnostic via isSubprocessDispatch().
  if (isSubprocessDispatch(prior.dispatch) && prior.artifact_path) return true;
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
  if (isSubprocessDispatch(prior.dispatch) && prior.artifact_path) {
    parts.push('a completed ' + prior.dispatch + ' run (artifact_path "' + prior.artifact_path + '")');
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

// #2023 diagnosis-speed prevention: a stored artifact_path pointing inside a git worktree subtree
// resolves fine while that worktree exists, but DANGLES the moment it is quarantined/removed (Rule 14)
// — the exact defect hit live on task #1981 (planner's self-append ran from inside the worktree,
// storing a `.claude/worktrees/<slug>/...` path instead of the stable primary-clone path the other
// two review roles used). Surface the likely cause immediately in the failure message instead of
// forcing a manual trace through enforce-review-or-lfah.sh -> resolveArtifact -> normalizeArtifact,
// as happened this session.
function worktreeDangleHint(rawPath) {
  const p = String(rawPath == null ? '' : rawPath);
  if (!/(^|\/)\.claude\/worktrees\//.test(p)) return '';
  return ' (HINT: this path points inside a git worktree subtree — if that worktree was quarantined/removed, ' +
    're-point the ledger via `3role-ledger.mjs append --artifact <primary-clone-relative-path>` run FROM THE ' +
    'PRIMARY CLONE, not from inside a worktree, after copying/committing the artifact to that stable path.)';
}

// #1481 — the SHARED model-resolution helper both cmdAppend AND cmdRefreshModels call (reuse, never a
// second copy of the transcriptModel()->overlay-merge path). Given a role's explicitAgent (pass '' / falsy
// to fall back to resolveAgent's tag search) returns {} when no model is resolvable yet (fail-open,
// can't-tell), else {modelVersion[, modelTier]} (modelTier omitted only if the id doesn't map to a known
// tier prefix — modelIdToTier's own fail-open contract).
// #1640 S12 — the `modelTier` fallback WIDENS to the SSOT vocabulary (identifyModelViaSSOT) when the observed
// id is not a claude-* id, so the badge-driving field carries the declared tier_equivalent (e.g. 'local-agentic')
// for an in-vocabulary non-Anthropic model instead of staying ABSENT (the #1481/#1494 silent-misattribution
// class the cairn stone names — a blank/lingering-Anthropic badge). `modelVersion` (the raw observed id) is
// UNCHANGED — it was already recorded regardless of tier resolution.
function resolveModelFields(session, task, role, explicitAgent) {
  try {
    const agentIdForModel = explicitAgent || resolveAgent(session, task, role);
    if (!agentIdForModel) return {};
    const modelId = transcriptModel(session, agentIdForModel);
    if (!modelId) return {};
    const fields = { modelVersion: modelId };
    const tier = modelIdToTier(modelId) || identifyModelViaSSOT(modelId);
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
//   - explicit path shape (`/`, `./`, `../`, `.claude/`, `.ai-workspace/`) → resolve to absolute ONLY if
//     the resolved candidate EXISTS on disk (#1868 — the calling agent's cwd is not necessarily the
//     artifact's own repo; a wrong-cwd resolution must not be stored as a plausible-looking-but-wrong
//     absolute path). No file at the resolved candidate → store verbatim, deferring to resolveArtifact()'s
//     cwd/CLAUDE_PROJECT_DIR/$HOME candidate chain at check-time (which may run from the right cwd).
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
    // #1868 — explicit relative shape still resolves against the CALLING agent's cwd, which is not
    // necessarily the artifact's own repo (a role can be spawned with its Bash cwd in a different
    // repo than the one it wrote into). Verify the resolved candidate is real before trusting it,
    // mirroring the ambiguous-slash branch below — a wrong-repo resolution falls back to verbatim
    // so a later `check` can re-resolve it from a cwd that actually matches (resolveArtifact()'s
    // CLAUDE_PROJECT_DIR/cwd/$HOME candidate chain), instead of silently storing a plausible-looking
    // absolute path that points into the wrong repo entirely.
    const cand = path.resolve(process.cwd(), v);
    if (fileExists(cand)) abs = cand;                   // resolves under this cwd — verify it's real.
    else return v;                                      // cwd/repo mismatch → defer to check-time resolution.
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

// #1947 D2/M1/M2 — the subprocess-openrouter provenance arm. A third provenance shape alongside today's
// agentId (harness-signed Agent-subagent transcript) and inline-skip (a self-declared assertion): a role
// dispatched by tools/openrouter-role-dispatch.sh as a hermetic `claude -p` subprocess, which has no
// Agent-subagent transcript and no agentId an Agent-tool spawn would produce.
//
// M1 — admissibility is decided SOLELY by the SSOT, read FRESH at check time
// (routes.seats[role].dispatch === 'subprocess-openrouter'), NEVER by the mere presence of the
// `dispatch` marker on the ledger row itself (the row is orchestrator-writable; the SSOT field is not — a
// forged row pointing at any transcript could otherwise satisfy even execution-review's
// never-inline-skippable invariant). A role whose SSOT seat lacks that dispatch field falls through to
// today's ordinary agentId arm UNCHANGED, even when the row carries the marker.
//
// M2 — the transcript is bound to (task, role, THIS dispatch) via a per-dispatch nonce: the helper mints the
// nonce and renders it plus `3ROLE_TASK:<id> ROLE:<role>` into the brief's first line, so the transcript's
// FIRST record (firstRecordText() — the SAME tag-binding predicate the rest of this file already uses,
// never a whole-file scan) must carry BOTH. The same nonce must also appear in the named artifact — this is
// what makes a REPLAYED transcript (any older gateway transcript already on disk, e.g. a prior smoke run)
// inadmissible even when its served model happens to equal the SSOT slug.
function escapeRegExp(s) { return String(s == null ? '' : s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// #2075 D1/AC-2 — the ONE shared predicate for "is this a non-Agent-tool (subprocess) dispatch class?".
// Replaces the ~5 per-site literal `dispatch === 'subprocess-openrouter'` comparisons the pre-#2075 file
// re-derived at every call site (C2's diagnosis: the concept was re-implemented, never named once). A
// prefix test rather than an enum: `subprocess-openrouter` is the only class that exists in production
// today, but a future `subprocess-ollama` class (§D4) is recognized by every site that calls this with ZERO
// further edits (AC-3's provider-agnosticism proof) — the class boundary is "not an Agent-tool spawn",
// never a specific vendor name.
function isSubprocessDispatch(v) { return typeof v === 'string' && v.indexOf('subprocess-') === 0; }

// Fresh SSOT read: is this role's SEAT declared a subprocess (non-Agent-tool) dispatch right now? Returns
// {ok:false} on ANY unresolvable SSOT (missing/corrupt file, missing seat, wrong dispatch value) — every one
// of those cases must fall through to the ordinary agentId arm, never silently admit the weak arm.
function seatDispatchIsSubprocess(role) {
  const routesLoaded = loadRoutesConfig();
  if (!routesLoaded.ok) return { ok: false, seat: null };
  const seat = (routesLoaded.routes.seats || {})[role];
  if (!seat || !isSubprocessDispatch(seat.dispatch)) return { ok: false, seat: null };
  return { ok: true, seat };
}

// Read a NAMED subprocess transcript path (NOT a PROJECTS_ROOT/<slug>/<session>/subagents/agent-<id>.jsonl
// harness-written file — a `claude -p` one-shot's own transcript, named explicitly on the ledger row).
// Fails closed to the empty/false defaults on any missing/unreadable/unparseable file — mirrors every other
// can't-tell residual in this module (never a false pass on a read error).
// A `claude -p` subprocess's OWN top-level session transcript has a DIFFERENT first-record shape than an
// Agent-subagent transcript: its first line is a `{"type":"queue-operation","operation":"enqueue",...,
// "content":"<brief text>"}` record — the brief text (carrying the 3ROLE_TASK/ROLE tag + DISPATCH-NONCE line)
// sits at the TOP LEVEL `content` field, never under `message.content` the way firstRecordText() (built for
// the Agent-subagent transcript shape) expects. Reusing firstRecordText() here silently returned '' for
// every real subprocess dispatch — measured live on session 27a10ef1-... (#1947 AC-5 live smoke) — so this
// is a dedicated extractor, not a wrapper.
// A leading `{"type":"ai-title",...}` bookkeeping record (an auto-generated conversation title) can sit
// BEFORE the real `queue-operation`/`enqueue` spawn record on disk — measured live on session
// bd8c0aec-... (#1947 AC-6 live smoke): the GLM transcript's line 0 was `ai-title`, line 1 the real enqueue.
// An `ai-title` record structurally can NEVER carry the rendered brief (it has only an `aiTitle` string, no
// `content`/`message` field), so it is the ONE narrowly-named type this scan skips past. Every other record
// type ends the scan immediately (return whatever text it has, or '' if none) — this still never scans past
// the first REAL turn, which is what defeats mention-vs-spawn confusion (M2); it only tolerates ONE specific,
// content-free metadata record shape in front of it.
function subprocessFirstRecordText(content) {
  const lines = String(content == null ? '' : content).split('\n');
  for (const raw of lines) {
    if (!raw.trim()) continue;
    let rec;
    try { rec = JSON.parse(raw); } catch (e) { return ''; }
    if (rec && rec.type === 'ai-title') continue;
    if (rec && typeof rec.content === 'string') return rec.content;
    const msg = (rec && rec.message) || {};
    if (typeof msg.content === 'string') return msg.content;
    if (Array.isArray(msg.content)) {
      let text = '';
      for (const c of msg.content) { if (c && c.type === 'text' && typeof c.text === 'string') text += c.text; }
      return text;
    }
    return '';
  }
  return '';
}

function subprocessTranscriptInfo(transcriptPath) {
  const out = { exists: false, firstText: '', servedModel: '' };
  let p = String(transcriptPath == null ? '' : transcriptPath);
  // transcript_path is stored in portable home-tilde form by normalizeArtifact() (R6) — expand it back to
  // an absolute path before touching the filesystem; fs.* never expands `~` the way a shell does, so a
  // tilde-form path here previously read as "does not exist" even when the file was genuinely on disk.
  if (p === '~') p = HOME;
  else if (p.startsWith('~/')) p = path.join(HOME, p.slice(2));
  if (!p || !fileExists(p)) return out;
  out.exists = true;
  try {
    const content = fs.readFileSync(p, 'utf8');
    out.firstText = subprocessFirstRecordText(content);
    for (const ln of content.split('\n')) {
      if (!ln.trim()) continue;
      try {
        const rec = JSON.parse(ln);
        const m = rec && rec.message && rec.message.model;
        if (m) { out.servedModel = String(m); break; }   // first served model line wins (the dispatch's own turn).
      } catch (e) { /* skip an unparsable line, keep scanning */ }
    }
  } catch (e) { /* fail closed to the empty defaults above */ }
  return out;
}

// M2 — the transcript's FIRST record must carry BOTH the exact spawn tag and this dispatch's nonce. A bare
// tag with no nonce (or a nonce belonging to a DIFFERENT dispatch) never binds — this is what defeats a
// replayed/reused transcript sitting on disk from an earlier run.
function subprocessFirstRecordBound(firstText, task, role, nonce) {
  const n = String(nonce == null ? '' : nonce).trim();
  if (!firstText || !n) return false;
  const tagRe = new RegExp('3ROLE_TASK:' + escapeRegExp(task) + ' ROLE:' + escapeRegExp(role));
  return tagRe.test(firstText) && firstText.indexOf(n) !== -1;
}

// The full subprocess-openrouter provenance arm for one role's ledger row. Returns:
//   null  -> NOT admissible (SSOT doesn't declare this seat subprocess-dispatched, or the row carries no
//            dispatch marker) -> checkRole must fall through to the ordinary agentId arm UNCHANGED.
//   ''    -> admissible AND fully verified -> treat as a pass.
//   <str> -> admissible but verification FAILED -> this string is the block reason.
function checkSubprocessProvenance(role, e, session, task) {
  if (!e || !isSubprocessDispatch(e.dispatch)) return null;
  const decl = seatDispatchIsSubprocess(role);
  if (!decl.ok) return null;   // M1 forged-marker control: SSOT silent -> marker ignored, fall through.

  // #1947 M-A (execution-review round-2 FAIL) — a harness-signed, RESOLVING agentId on the SAME row must
  // ALWAYS outrank a stale/self-declared subprocess marker; the stronger provenance must win a tie. This is
  // the #1590-class monotonicity fix: D3's bounded fallback (a subprocess dispatch that stamped
  // dispatch/transcript_path/nonce, then got rejected, then a bounded Anthropic Agent-tool retry self-appends
  // a REAL agentId + its own artifact + verdict) previously left the STALE dispatch marker in place, so this
  // function kept re-evaluating the SUPERSEDED subprocess evidence and false-BLOCKed the genuinely-completed
  // fallback. Belt-and-braces alongside the overlayAppend clear-list fix below (which is the PRIMARY fix — a
  // genuine agentId/oracle append now also clears dispatch/transcript_path/nonce, so this branch is normally
  // unreachable for a correctly-composed row) — this tie-break covers any row that somehow still carries BOTH
  // fields (e.g. an out-of-band ledger edit, or a compose path this round didn't anticipate).
  if (e.agentId && agentResolves(session, e.agentId)) return null;

  const info = subprocessTranscriptInfo(e.transcript_path);
  if (!info.exists) {
    return role + ' dispatch=subprocess-openrouter but transcript_path "' + (e.transcript_path || '') +
      '" does not exist on disk';
  }
  if (!subprocessFirstRecordBound(info.firstText, task, role, e.nonce)) {
    return role + ' dispatch=subprocess-openrouter transcript "' + e.transcript_path + '" first record does ' +
      'not carry BOTH the spawn tag (3ROLE_TASK:' + task + ' ROLE:' + role + ') and this dispatch\'s nonce "' +
      (e.nonce || '<missing>') + '" — a replayed/reused transcript is not admissible (M2)';
  }
  if (!info.servedModel || info.servedModel !== decl.seat.model) {
    return role + ' dispatch=subprocess-openrouter transcript "' + e.transcript_path + '" served model "' +
      (info.servedModel || '<none>') + '" != SSOT-declared seat model "' + decl.seat.model + '"';
  }
  const ap = resolveArtifact(e.artifact_path || '');
  if (ap) {
    if (!e.nonce || !fileHas(ap, new RegExp(escapeRegExp(e.nonce)))) {
      return role + ' dispatch=subprocess-openrouter artifact "' + ap + '" does not contain this dispatch\'s ' +
        'nonce "' + (e.nonce || '<missing>') + '" (M2 — binds artifact to this exact run)';
    }
  } else if (role !== 'executor') {
    // executor's artifact is legitimately a PR URL/commit/branch string, never required to resolve on disk
    // (mirrors the ordinary arm's own role-shaped exemption below); every other role needs a real disk path.
    return role + ' dispatch=subprocess-openrouter artifact_path "' + (e.artifact_path || '') + '" not found' +
      worktreeDangleHint(e.artifact_path);
  }
  if (role === 'plan-review' && (!ap || !fileHas(ap, VERDICT_RE))) {
    return 'plan-review artifact "' + (ap || e.artifact_path) + '" lacks a verdict token (PASS/FAIL/APPROVE/verdict/## Review)';
  }
  if (role === 'executor' && (!e.artifact_path || String(e.artifact_path).trim() === '')) {
    return 'executor artifact_path missing (PR URL / commit / branch string)';
  }
  return '';   // admissible + fully verified -> pass.
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
// #2075 Phase 1 — D1's shared Provenance Record primitive: ONE strength lattice (E1 > E2 > E3), consulted by
// every reader AND writer instead of ~14 sites each re-deriving "which vendor produced this row?" ad hoc.
//
// Two DISTINCT "verified kind" predicates on purpose (R5-N3 — the design's own round-5 review named this
// split; AC-11's own protection-vs-admissibility test is the binary oracle that forces it):
//   - computeVerifiedKind()            — the ADMISSIBILITY triple (does this row's evidence fully verify,
//                                         including served-model equality?). Used by provenance-kind's
//                                         REPORTING formula (AC-1/AC-24) — never by a write-side guard.
//   - computeVerifiedKindForProtection() — the narrower PROTECTION predicate (execution record exists AND
//                                         its first record is tag+nonce bound — served-model equality is an
//                                         admissibility concern, not a protection one). Used ONLY to decide
//                                         whether an E3-derived background sweep (reconcile-spawns /
//                                         refresh-models) may write over a row at all (§D5(c), AC-9/AC-11a).
// Neither predicate reads the STORED run_kind label — both recompute fresh from the row's own evidence every
// time (agentResolves/agentBoundToTag for E1, the transcript-existence+binding check for E2), so a forged or
// stale stored label can never inflate what a row is actually proven to be.
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

// ADMISSIBILITY-scoped verified kind: 'E1' | 'E2' | 'none'. E1 requires a resolving AND spawn-record-bound
// agentId (never resolveAgent()'s newest-mtime search — that is E3, a guess, never "verified"). E2 reuses
// checkSubprocessProvenance UNCHANGED (the #2051 discipline: one evaluator, no mirror) — the full triple,
// including served-model equality.
function computeVerifiedKind(role, row, session, task) {
  if (row && row.agentId && agentResolves(session, row.agentId) && agentBoundToTag(session, row.agentId, task, role)) {
    return 'E1';
  }
  if (row && isSubprocessDispatch(row.dispatch) && checkSubprocessProvenance(role, row, session, task) === '') {
    return 'E2';
  }
  return 'none';
}

// PROTECTION-scoped verified kind: 'E1' | 'E2' | 'none'. Same E1 test as above (a resolving+bound agentId is
// unconditionally strong evidence for both questions). The E2 arm is DELIBERATELY narrower than
// checkSubprocessProvenance's full admissibility triple — it does NOT require served-model equality, only
// that the row's own execution record exists and its first record is tag+nonce bound — because an E2 row
// whose model happens to be unreadable is still real, verified evidence that must not be erased by a guess
// (AC-11's honest-blank-beats-confidently-wrong split; R5-N3).
function computeVerifiedKindForProtection(role, row, session, task) {
  if (row && row.agentId && agentResolves(session, row.agentId) && agentBoundToTag(session, row.agentId, task, role)) {
    return 'E1';
  }
  if (row && isSubprocessDispatch(row.dispatch)) {
    const decl = seatDispatchIsSubprocess(role);
    if (decl.ok) {
      const info = subprocessTranscriptInfo(row.transcript_path);
      if (info.exists && subprocessFirstRecordBound(info.firstText, task, role, row.nonce)) return 'E2';
    }
  }
  return 'none';
}

// §D1 storage-layer rank order — witnessed(3) > bound(2) > inferred(1) > unset/absent(0). Governs the
// write-once clamp in overlayAppend AND provenance-kind's REPORTING formula below (min(stored, verified)) —
// the ONLY two consumers of the stored run_kind label; every write-side GUARD in this file reads verified
// kind directly (see computeVerifiedKind[ForProtection] above), never this label.
const RUN_KIND_RANK = { witnessed: 3, bound: 2, inferred: 1 };
const KIND_LABEL_BY_RANK = { 3: 'E1', 2: 'E2', 1: 'E3', 0: 'none' };
function verifiedKindRank(label) { return label === 'E1' ? 3 : (label === 'E2' ? 2 : 0); }

// AC-1's REPORTING construction: min(stored run_kind, verified kind). A row with NO stored run_kind at all
// (a pre-#2075 "legacy" row — AC-23) reports its verified kind directly, suffixed " legacy" so a consumer
// can tell a classified-by-inference row from a genuinely stored one — never suffixed for a 'none' verdict
// (there is nothing to distinguish a legacy 'none' from a stored one; AC-1's own "bare spawn placeholder"
// arm asserts a bare 'none', no suffix).
function provenanceKindOf(role, row, session, task) {
  const verified = computeVerifiedKind(role, row, session, task);
  if (!row || !('run_kind' in row) || row.run_kind == null) {
    return verified === 'none' ? 'none' : (verified + ' legacy');
  }
  const storedRank = RUN_KIND_RANK[row.run_kind] || 0;
  const rank = Math.min(storedRank, verifiedKindRank(verified));
  return KIND_LABEL_BY_RANK[rank];
}

// provenance-kind --session S --task T --role R (#2075 AC-1). Prints exactly one of E1|E2|E3|none (optionally
// " legacy"-suffixed) on stdout, exit 0, for every row shape — including a missing row (no line at all for
// this role), which reports 'none'.
function cmdProvenanceKind(o) {
  const session = o.session, task = o.task, role = o.role;
  if (!session || !task || !role) { console.error('provenance-kind: --session, --task, --role are required'); process.exit(2); }
  const file = ledgerFile(session, task);
  let lines = [];
  try { lines = fs.readFileSync(file, 'utf8').split('\n').filter(l => l.trim()); } catch (e) { /* no ledger yet */ }
  let row = null;
  for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role === role) row = j; } catch (e) { /* skip */ } }
  console.log(provenanceKindOf(role, row, session, task));
  process.exit(0);
}

// Returns null when the role is satisfied, else a problem string. `opts.rejectVacuousOracle` (#1276) — set
// ONLY by the instrumentation-gate's `check --reject-vacuous-oracle` — additionally REJECTS an
// execution-review oracle that exists + carries a PASS token but is vacuous (0 real assertions).
function checkRole(role, e, session, opts, task) {
  // #1947 M1/M2 — try the subprocess-openrouter arm FIRST. It returns null (not admissible for this row/SSOT
  // state) for every ordinary Agent-tool-dispatched role, so this is a pure addition for everyone else.
  const sub = checkSubprocessProvenance(role, e, session, task);
  if (sub !== null) return sub || null;
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
    if (!ap) return 'execution-review artifact_path "' + (e.artifact_path || '') + '" not found' +
      worktreeDangleHint(e.artifact_path);
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
    if (!ap) return 'planner artifact_path "' + (e.artifact_path || '') + '" not found (the plan file)' +
      worktreeDangleHint(e.artifact_path);
    if (!fileHas(ap, PLAN_RE)) return 'planner artifact "' + ap + '" lacks a plan marker — needs a heading like ' +
      '## ELI5, ### Binary AC, ## Binary acceptance criteria, ### Acceptance criteria, ## Acceptance, or ## AC';
    return null;
  }
  if (role === 'plan-review') {
    const ap = resolveArtifact(e.artifact_path);
    if (!ap) return 'plan-review artifact_path "' + (e.artifact_path || '') + '" not found' +
      worktreeDangleHint(e.artifact_path);
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

// ── #1544 — perf-log jurisdiction key (ai-brain-toplevel membership) ───────────────────────────────────────
// `isGitTracked(perfLog) === false` alone is jurisdiction-BLIND: it fires for an untracked file inside ANY
// real git repo, not only ai-brain (verified 2026-07-17 — a hermetic `git init` temp dir + untracked file
// also returns `false`). Blocking on that would be a false-BLOCKER (the one error class with no reviewer) for
// a perf-log that legitimately lives in a DIFFERENT repo (the template's real home,
// `~/.claude/agent-working-memory/...`, is NOT a git worktree at all — non-repo -> null -> already fail-open;
// but a sibling git-tracked working-memory clone, or any other real repo, is NOT automatically safe without
// this key). The fix: key the block on ai-brain-repo TOPLEVEL MEMBERSHIP, not bare tracked-ness.

// Resolve the ai-brain toplevel from THIS ledger file's own resolved location (symlink-aware — reuses
// selfDir()'s realpathSync trick so a ~/.claude/hooks/3role-ledger.mjs symlink install still resolves to the
// real repo, not the dangling ~/.claude/hooks dir). Memoized (git spawnSync is not free); null when this
// file itself somehow isn't inside a git repo (can't-tell -> every jurisdiction check below fails open).
let _aiBrainToplevelCache;
function aiBrainToplevel() {
  if (_aiBrainToplevelCache !== undefined) return _aiBrainToplevelCache;
  try {
    const res = spawnSync('git', ['-C', selfDir(), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' });
    _aiBrainToplevelCache = (res.status === 0) ? (res.stdout || '').trim() : null;
  } catch (e) { _aiBrainToplevelCache = null; }
  return _aiBrainToplevelCache;
}

// Resolve the git toplevel containing absPath's directory. null when absPath is not inside any real git repo
// (exit 128), or on any spawn error / unexpected exit — the SAME can't-tell -> fail-open contract as
// isGitTracked() above (never a false block on an environment hiccup).
function repoToplevelFor(absPath) {
  try {
    const res = spawnSync('git', ['-C', path.dirname(absPath), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' });
    return (res.status === 0) ? (res.stdout || '').trim() : null;
  } catch (e) { return null; }
}

// The #1544 perf-log tracked-check. Returns null when satisfied (out of jurisdiction, can't-tell, or
// genuinely tracked/staged), else a "TRACKED:"-caller-prefixed problem string (the caller adds the prefix,
// mirroring checkTrackedRole()'s contract). BLOCKS only when perfLogPath resolves to a file whose containing
// repo's toplevel EQUALS the ai-brain toplevel (jurisdiction) AND that file is untracked. Every other
// outcome — a different real repo, a non-repo path, an unresolvable path, or this ledger's own toplevel
// being undeterminable — fails OPEN by design (#1544 BLOCKER 1 fix; see the doc comment above TRACKED_ROLES).
function checkPerfLogTracked(perfLogPath) {
  if (!perfLogPath) return null;
  const abTop = aiBrainToplevel();
  if (!abTop) return null;                          // can't determine our own jurisdiction -> fail open.
  const fileTop = repoToplevelFor(perfLogPath);
  if (!fileTop || fileTop !== abTop) return null;    // different repo / non-repo / unresolvable -> OUT of jurisdiction.
  if (isGitTracked(perfLogPath) === false) {
    return 'perf-log "' + perfLogPath + '" exists on disk inside the ai-brain repo but is NOT git-tracked ' +
      '(present-but-untracked — it will never ship with the PR; the #1544 class, the same #861/#1509 leak one ' +
      'surface over). git add + commit it (from a Rule-12 worktree), then re-complete.';
  }
  return null;   // tracked, staged, or can't-tell -> satisfied.
}

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

// #1532 — executor artifact-KIND leg. Returns null when satisfied (not an executor row, inline-skipped,
// missing artifact_path — the base existence leg already reports those — or a ship reference / a
// disk-resolving-but-non-plan-kind artifact), else a problem string. See the `check --enforce-artifact-
// role-kind` doc comment above for the full discrimination + the hard-constraint safety property.
function executorKindProblem(byRole) {
  const e = byRole['executor'];
  if (!e) return null;                              // missing-role already reported by the base existence leg.
  if (classifySkip(e).skip) return null;             // inline-skip has no artifact to KIND-check.
  const raw = String(e.artifact_path == null ? '' : e.artifact_path).trim();
  if (!raw) return null;                             // base existence leg already reports this.
  const ap = resolveArtifact(raw);
  if (!ap) return null;                              // NOT an existing disk path -> a PR-URL/commit/branch
                                                      // ship reference -> the hard constraint: never touched.
  const plannerRow = byRole['planner'];
  const plannerRaw = plannerRow ? String(plannerRow.artifact_path == null ? '' : plannerRow.artifact_path).trim() : '';
  const plannerPath = plannerRaw ? resolveArtifact(plannerRaw) : '';
  const sameAsPlanner = !!plannerPath && ap === plannerPath;          // predicate (a) — the exact #1494 shape.
  const onPlansSegment = /(^|\/)\.ai-workspace\/plans\//.test(ap);    // predicate (b) — any other plan-kind doc.
  if (!sameAsPlanner && !onPlansSegment) return null;   // disk-resolving but NOT plan-kind -> AC-4 pass.
  const why = sameAsPlanner
    ? 'equals the planner\'s own artifact_path (the exact #1494 shape — the executor re-cited the planner\'s ' +
      'plan file instead of citing its own ship reference)'
    : 'lies on a /.ai-workspace/plans/ path segment (a plan-kind document, not a ship reference)';
  return 'executor artifact_path "' + raw + '" resolves to a DISK PATH (' + ap + ') that ' + why + '. An ' +
    'executor\'s real artifact is a PR URL / commit sha / branch — never a plan document; cite the actual PR/commit.';
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
  // #1640 S11 — the RUN-TIME reroute stamp. Overlay only when THIS call's --sense-reroute actually resolved
  // one (own-key "provided" discipline, same as every field above): the spawn edge (three-role-spawn-ledger.sh)
  // and the SubagentStop edge (three-role-subagent-ledger.sh) both pass --sense-reroute on every call, but
  // senseReroute() returns null (no field set) whenever the session's ANTHROPIC_BASE_URL is empty, or the seat
  // isn't SSOT-declared to a non-Anthropic provider, or the base-url doesn't resolve to any declared provider
  // row — so an ordinary Anthropic-only role's line NEVER gains a reroute field. This is the ONLY writer of
  // `reroute`; the completion gate (cmdCheck) only ever READS it, never senses env/base-url itself (S10
  // anti-spoof — the stamp must be a run-time RECORD, not a check-time re-derivation).
  if ('reroute' in fields) entry.reroute = fields.reroute;
  // #1947 S3 — the subprocess-openrouter provenance fields (D2/M1/M2). Same own-key "provided" overlay
  // discipline as every field above: unprovided keys persist the prior line's value, so a spawn-time
  // dispatch/transcript/nonce stamp composes with a later close-only `--artifact` repoint exactly like
  // agentId/artifact_path already compose.
  if ('dispatch' in fields) entry.dispatch = fields.dispatch;
  if ('transcript_path' in fields) entry.transcript_path = fields.transcript_path;
  if ('nonce' in fields) entry.nonce = fields.nonce;
  // #2075 D1 — run_id is an ordinary own-key overlay (same discipline as every field above): E1 -> agentId,
  // E2 -> nonce, E3 -> absent. run_source is diagnostic-only, same discipline, never consulted by a gate.
  if ('run_id' in fields) entry.run_id = fields.run_id;
  if ('run_source' in fields) entry.run_source = fields.run_source;
  // #2075 D1/§D5(a) round-4 storage-layer fix (R3-B1/R3-B2) — run_kind is WRITE-ONCE / monotone-non-
  // decreasing, NOT an ordinary last-writer-wins overlay: `entry.run_kind` at this point already carries the
  // PRIOR line's stored value (composed onto `entry` from `prior` above, for a same-round merge) or nothing
  // (a genuinely new round, isNewRound above — that row's first run_kind write is legitimately unconstrained,
  // matching the "round split runs first" ordering §D5(a) requires). An incoming write whose rank is <= the
  // row's CURRENT stored rank is a field-level no-op — every OTHER field this call carries still merges
  // exactly as before, and the append itself still exits 0 (submitting a stale/weaker claim is not an error).
  // This is what closes R3-B1/R3-B2 at the storage layer: no later bare `--run-kind inferred` append can ever
  // push an already-classified row's stored label back down, so §D5(a)/(c)'s VERIFIED-kind-only guards never
  // need to defend against a demotion trick that reaches them through the stored field.
  if ('run_kind' in fields) {
    const incomingRank = RUN_KIND_RANK[fields.run_kind] || 0;
    const existingRank = ('run_kind' in entry) ? (RUN_KIND_RANK[entry.run_kind] || 0) : 0;
    if (!('run_kind' in entry) || incomingRank > existingRank) entry.run_kind = fields.run_kind;
    // else: no-op — `entry.run_kind` is left at its current (higher-or-equal) value.
  }
  // Mutual-exclusion guard: a "ran/verified" signal (agentId for a real spawn, or oracle for a passing test)
  // and a "skip" signal are mutually exclusive by intent, and checkRole tests skip FIRST. So providing
  // agentId or oracle clears any inherited skip_reason (a stale skip can't mask a real spawn/oracle);
  // conversely providing skip_reason clears inherited agentId/artifact_path/oracle (dead weight a merge could
  // otherwise resurrect) — modelVersion/modelTier/effort/reroute join that clear-list too (#1465/#1640): they
  // are provenance OF a real spawn's transcript/session, so a skip line must not carry a stale claimed model
  // or a stale declared-reroute stamp. dispatch/transcript_path/nonce (#1947) join it for the same reason.
  // #1947 M-A (execution-review round-2 FAIL) — a genuine, harness-signed agentId/oracle is STRICTLY
  // STRONGER evidence than a self-declared subprocess-openrouter marker (no harness signs that marker at
  // all), so it must supersede it the SAME way it supersedes a stale skip_reason: an agentId/oracle append
  // now ALSO clears any inherited dispatch/transcript_path/nonce. Without this, D3's bounded fallback (a
  // rejected subprocess dispatch stamped dispatch/transcript_path/nonce, then a bounded Anthropic retry
  // self-appends a real agentId+artifact+verdict onto the SAME row) left the stale marker in place, and
  // checkSubprocessProvenance kept re-evaluating the SUPERSEDED subprocess evidence against the FALLBACK's
  // own artifact — which of course never contains the superseded dispatch's nonce — false-BLOCKing a
  // genuinely-completed role. This is the primary fix; checkSubprocessProvenance's own agentId tie-break
  // above is the belt-and-braces backstop for a row that reaches it with both fields still present.
  if (('agentId' in fields) || ('oracle' in fields)) {
    delete entry.skip_reason;
    // #1947 M-A-2 (execution-review round-2 FAIL — fix-round 2) — the line above unconditionally cleared
    // dispatch/transcript_path/nonce on the mere PRESENCE of an agentId/oracle KEY, never checking that
    // either one actually RESOLVES. checkSubprocessProvenance's own tie-break (:1249) already gates the
    // identical supersession decision on `agentResolves(session, e.agentId)` — a non-resolving agentId (a
    // bogus/forged value, or an inert `--oracle` that this role's checkRole never even reads — it's read
    // ONLY for execution-review, :1294/:1299) carries ZERO evidentiary weight and must not erase
    // nonce-bound, transcript-verified subprocess provenance (the #1590 monotonicity rule: supersession must
    // be evidence-gated, erasure-on-mere-presence never is). Preserving the fields when neither resolves is
    // safe: :1249's tie-break still lets a LATER-resolving agentId win the comparison outright.
    const agentSupersedes = ('agentId' in fields) && agentResolves(session, fields.agentId);
    const oracleSupersedes = ('oracle' in fields) && role === 'execution-review' && (() => {
      const op = resolveArtifact(stripOraclePrefix(fields.oracle));
      return !!op && fileHas(op, VERDICT_RE);
    })();
    if (agentSupersedes || oracleSupersedes) {
      delete entry.dispatch; delete entry.transcript_path; delete entry.nonce;
    }
  }
  if ('skip_reason' in fields) {
    delete entry.agentId; delete entry.artifact_path; delete entry.oracle; delete entry.verdict; delete entry.self_authored;
    delete entry.modelVersion; delete entry.modelTier; delete entry.effort; delete entry.closedAt; delete entry.reroute;
    delete entry.dispatch; delete entry.transcript_path; delete entry.nonce;
    // #2075 D1 — run_id/run_kind/run_source join the clear-list too: a skip line must not carry a stale
    // claimed provenance kind (join the SAME reasoning as modelVersion/dispatch above — these are provenance
    // OF a real run, and a skip is a declaration that no run happened).
    delete entry.run_id; delete entry.run_kind; delete entry.run_source;
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
  // #1947 S3 — the subprocess-openrouter provenance fields (D2/M1/M2). Written ONLY by
  // tools/openrouter-role-dispatch.sh's own self-append (or the role's own self-append, mirroring today's
  // agentId self-append convention) — `check`'s admissibility gate (checkSubprocessProvenance) reads these
  // three fields ONLY when the SSOT independently declares this role's seat dispatch=subprocess-openrouter;
  // writing them on any other role's row is inert (the SSOT gate ignores an unrecognised marker).
  if ('dispatch' in o) fields.dispatch = o.dispatch;
  if ('transcript' in o) fields.transcript_path = normalizeArtifact(o.transcript);
  if ('nonce' in o) fields.nonce = o.nonce;
  // #2075 Phase 1, D1 — the provenance-kind fields. Written ONLY by the writer that obtained the identity
  // (three-role-subagent-ledger.sh -> witnessed; the dispatch helper -> bound; cmdReconcileSpawns /
  // cmdRefreshModels -> inferred, stamped internally below, never via this flag). --run-kind is WRITE-ONCE /
  // monotone-non-decreasing under overlayAppend (see its own comment there); --run-id/--run-source are
  // ordinary own-key overlays.
  if ('run-kind' in o) fields.run_kind = o['run-kind'];
  if ('run-id' in o) fields.run_id = o['run-id'];
  if ('run-source' in o) fields.run_source = o['run-source'];
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
  // #1640 S11 — the reroute-stamp RECORDER. Opt-in via --sense-reroute (only the spawn edge
  // three-role-spawn-ledger.sh and the SubagentStop edge three-role-subagent-ledger.sh pass it); reads ONLY
  // this process's OWN environment (the session's inherited ANTHROPIC_BASE_URL) at RUN-TIME, resolved against
  // the SSOT's declared provider rows for THIS role's seat — never at check-time (see cmdCheck's declared
  // sensor, which reads ONLY the field this writes). senseReroute() fails closed to null (field omitted) on
  // any ambiguity, so an ordinary Anthropic session never gains a stamp.
  if ('sense-reroute' in o) {
    const r = senseReroute(role);
    if (r) fields.reroute = r;
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
  // #1769: a BARE repoint (no --agent, no --verdict, no --skip-reason — i.e. only artifact_path and/or the
  // best-effort model fields are being provided) merges onto overlayAppend's "prior" row: whichever line was
  // written LAST for this (task, role), NOT necessarily the review event the caller has in mind. When one
  // 3ROLE_TASK id has been reused across MULTIPLE independent reviews of this role (a compound ticket bundling
  // several PRs, each execution-reviewed separately), "prior" may already belong to a LATER, unrelated review
  // by the time this repoint runs — silently cross-attributing this artifact_path to the wrong agentId with no
  // error anywhere in the pipeline (live incident 2026-07-20, #1749: a follow-up archival reviewer's own
  // self-append became "prior" before an artifact-only repoint landed on it). Detect: count prior same-role
  // lines for this task BEFORE this call; if >1 exist and this call supplies NEITHER --agent NOR --verdict
  // NOR --skip-reason, the merge target is ambiguous — warn (do not block; the caller may genuinely intend
  // the latest row).
  {
    const isBareRepoint = !('agent' in o) && !('verdict' in o) && !('skip-reason' in o);
    if (isBareRepoint) {
      let priorSameRoleCount = 0;
      try {
        const raw = fs.readFileSync(ledgerFile(session, task), 'utf8').split('\n').filter(l => l.trim());
        for (const ln of raw) { try { const j = JSON.parse(ln); if (j && j.role === role) priorSameRoleCount++; } catch (e) { /* skip */ } }
      } catch (e) { /* no ledger file yet -> priorSameRoleCount stays 0 */ }
      if (priorSameRoleCount > 1) {
        console.error('WARN (3role-ledger #1769): AMBIGUOUS repoint target — role ' + role + ' already has ' +
          priorSameRoleCount + ' prior lines for task ' + sanitize(task) + ' (this task id has been reused ' +
          'across multiple independent reviews of this role). This bare append (no --agent/--verdict/' +
          '--skip-reason) will merge onto whichever row is CURRENTLY LAST — possibly a DIFFERENT review than ' +
          'the one you mean to repoint. Pass --agent <the specific reviewer\'s agentId> explicitly (plus ' +
          '--verdict/--effort/--self-authored/--closed-at to preserve them — an agent-change starts a FRESH ' +
          'row, not a merge) to pin the target unambiguously.');
      }
    }
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
    const prob = checkRole(r, ent, session, undefined, parent);
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
// the EIGHT named fail-closed classes the plan requires the block message to distinguish:
//   not-finished / no-verdict / negative-verdict / no-bound-reviewer-spawn / inherited-row-unbound-to-parent /
//   deliberate-skip-closed / junk-line / subprocess-unverified
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
  // Arm 3 (#2051) — subprocess-openrouter provenance, consulted FIRST after the universal verdict screen,
  // mirroring checkRole's own consult-order (:1305-1308). Calls the SAME checkSubprocessProvenance the
  // completion gate already trusts (the #1947 verifier) — never re-implements it (C1/C2: one evaluator, no
  // mirror; Scope discipline forbids touching that function). Tri-state contract mapped onto the gate:
  //   null  -> NOT admissible for this row/SSOT state (no dispatch marker, or SSOT silent, or a RESOLVING
  //            agentId outranks the dispatch marker at checkSubprocessProvenance's own :1264 tie-break) ->
  //            fall through to arms 1/2 COMPLETELY UNCHANGED — a pure addition for every ordinary row.
  //   ''    -> admissible AND fully verified -> ALLOW.
  //   <str> -> admissible but verification FAILED -> BLOCK, fail-closed, class subprocess-unverified (the
  //            8th named class, #2051 C5), carrying that string as the detail.
  // Placement is pinned (C2/#1590 monotonicity), not stylistic: a NON-resolving agentId is NOISE and must
  // never erase otherwise-valid nonce evidence — arm-3-last would let arm 1's no-bound-reviewer-spawn false-
  // block a valid dual-signal row before the subprocess arm ever ran (AC-10 discriminates the two placements).
  const sub = checkSubprocessProvenance('plan-review', e, session, task);
  if (sub !== null) {
    if (sub === '') return { allow: true, class: '', detail: '' };
    return { allow: false, class: 'subprocess-unverified', detail: file + ' (line ' + (lastIdx + 1) + ') — ' + sub };
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

// ── #1936 — read-side history lanes (STRICTLY ADDITIVE; `byRole` selection, checkRole, and the ENTIRE
// write path — cmdAppend, both terminal-evidence clauses, round-boundary logic — are UNTOUCHED). `check`
// today reads only the byRole-selected (last-parse-wins) row per role and references neither `.verdict` nor
// `.closedAt` (see the plan's Context section). These two lanes read PAST that single row, across each
// role's FULL history, so a content-free row (bare spawn, artifact-only re-point, unattributed verdict
// overlay) can never silently bury a recorded review outcome. Default-ON, no opt-in flag, no kill-switch,
// no bypass token (round-1 decision, confirmed by four plan-review rounds): the observed failure was an
// orchestrator trusting a bare `check` OK, and the remedy for a legitimate block is always available —
// spawn a fresh review, whose sanctioned three-write lifecycle (spawn-shaped agent append, mid-turn
// self-append, stop-shaped closed-at append) both records honestly and satisfies the read precondition
// with no extra ceremony (see the plan's §"The sanctioned supersession flow").

// Check-lane affirmative set = AFFIRMATIVE_VERDICTS (:844, UNCHANGED — it keeps gating cmdInherit and the
// executor-spawn gate at their current strictness) PLUS `PASS-WITH-FIXES`, as a SEPARATE check-lane
// constant (round-1 review N2, corpus-measured: 12 effective PASS-WITH-FIXES closes across 9 tasks, 6 of
// which pass `check` today and would false-block under `:844` verbatim). Still an ALLOWLIST (D3):
// NEEDS-WORK, SHIP-WITH-FIXES, BLOCK-resolved, REVISE, typos, empty — all block.
const CHECK_LANE_AFFIRMATIVE = new Set([...AFFIRMATIVE_VERDICTS, 'PASS-WITH-FIXES']);

// Parse an ISO-ish closedAt string to epoch MILLISECONDS (round-3 review N-d): the corpus provably carries
// mixed sub-second/second precision that inverts lexicographically inside a shared second
// (`"...:20.500Z" < "...:20Z"` as strings while 20.500s > 20s as instants) — so every closedAt comparison in
// both lanes below compares PARSED epoch values, never strings. Absent/unparseable -> null, treated as
// ABSENT throughout (never a false "equal" or a string-order artifact).
function parseClosedAtMs(v) {
  if (!v) return null;
  const t = Date.parse(String(v));
  return Number.isNaN(t) ? null : t;
}

// Every row for ONE role, in ledger PARSE ORDER (file top-to-bottom) — the role's FULL history, never just
// the byRole-selected (last-parse-wins) row. Unparseable lines are silently skipped (mirrors the byRole
// build loop's own `catch (e) { /* skip */ }`). File order is chronological within a role by construction
// (overlayAppend always retains an older round's row, verbatim, ahead of the new/merged row it writes —
// see the plan's Context section and the round-3/round-4 reviewers' independent fixture proofs).
function rowsForRole(lines, role) {
  const out = [];
  for (const ln of lines) {
    try { const j = JSON.parse(ln); if (j && j.role === role) out.push(j); } catch (e) { /* skip */ }
  }
  return out;
}

// Verdict-BEARING rows only (a truthy `.verdict` field). A bare spawn row, an artifact-only re-point, or a
// provenance/oracle-only row carries no verdict and is read PAST — never treated as evidence by Lane B. A
// row carrying BOTH a verdict and an oracle is verdict-bearing (the recorded decision outranks a token-file
// — the plan's Lane B bullet); nothing here inspects `.oracle` at all.
function verdictRows(rows) {
  return rows.filter((r) => r && r.verdict);
}

// The monotonicity ruling (Intent §"The monotonicity ruling"): a later verdict-bearing row supersedes a
// currently-effective NEGATIVE verdict ONLY when it carries an agentId DISTINCT from the negative row's AND
// a closedAt STRICTLY newer than the negative row's (parsed-epoch comparison; equal is NOT strictly newer
// -> refuse). Absence semantics: the superseding row MUST itself carry both an agentId and a closedAt that
// PARSES — an absent/unparseable value on the superseding side can never supersede (an unparseable
// superseder is treated exactly like an absent one). A negative row lacking either field makes that half
// trivially satisfied (an attributed, punched-out superseder is distinct/newer than nothing by
// construction) — this is what lets AC-14's raw hand-written shapes and the real #1821 fixture (whose bare
// shield row is never itself the negative — the negative is the FAIL row, which always carries both fields
// in the corpus) resolve correctly without a separate code path.
function supersedesNegative(candidate, negative) {
  if (!candidate || !candidate.agentId) return false;
  const candMs = parseClosedAtMs(candidate.closedAt);
  if (candMs === null) return false;
  const distinct = !negative.agentId || (candidate.agentId !== negative.agentId);
  if (!distinct) return false;
  const negMs = parseClosedAtMs(negative.closedAt);
  const newer = (negMs === null) ? true : (candMs > negMs);
  return newer;
}

// Walk a role's verdict-bearing rows OLDEST -> NEWEST, folding them into ONE effective verdict row per the
// ruling above. A later row supersedes a currently-effective AFFIRMATIVE verdict UNCONDITIONALLY (newest
// wins); it supersedes a currently-effective NEGATIVE verdict only per supersedesNegative() above — otherwise
// the row is read PAST and the negative stays effective. Returns null when the role carries NO
// verdict-bearing row at all (Lane B stays SILENT — today's honest fail-open residual, pinned by AC-7(c)).
function effectiveVerdictRow(vrows) {
  let eff = null;
  for (const row of vrows) {
    if (!eff) { eff = row; continue; }
    if (CHECK_LANE_AFFIRMATIVE.has(eff.verdict)) { eff = row; continue; }   // affirmative -> unconditional newest-wins
    if (supersedesNegative(row, eff)) eff = row;                            // negative -> gated supersession
    // else: read PAST this row, keep the negative effective.
  }
  return eff;
}

// Lane B — outcome MONOTONICITY, for ONE review-pair role (execution-review OR plan-review — the shield is
// role-symmetric, round-2 review N1). Returns null (silent) when the role carries no verdict anywhere in its
// history, or its effective verdict is check-lane affirmative; else a `NEGATIVE-VERDICT:` problem string.
function laneBProblem(role, lines) {
  const vrows = verdictRows(rowsForRole(lines, role));
  if (!vrows.length) return null;                        // no verdict on ANY row of the role -> silent (AC-7(c)).
  const eff = effectiveVerdictRow(vrows);
  if (CHECK_LANE_AFFIRMATIVE.has(eff.verdict)) return null;
  return 'NEGATIVE-VERDICT: role ' + role + ' — effective recorded verdict is "' + eff.verdict + '" (agentId ' +
    (eff.agentId || '<none>') + ', ' + (eff.closedAt ? 'closedAt ' + eff.closedAt : 'no closedAt') +
    ') — a recorded negative verdict is superseded only by a later verdict row carrying an agentId DISTINCT ' +
    'from the negative row\'s AND a closedAt STRICTLY newer than the negative row\'s. Sanctioned remedy: ' +
    'spawn a fresh ' + role + ' (the three-write lifecycle records + supersedes with no extra ceremony).';
}

// Lane A — round-aware FRESHNESS (rebuilt per B3; never a raw timestamp inequality). For a (subject ->
// review) pair, a `STALE-REVIEW:` problem fires ONLY when the ledger shows a genuinely NEW subject round
// left unreviewed — ALL THREE conditions below. Any missing/unparseable input -> that condition can't hold
// -> fail OPEN (silent) — never a false block on an environment can't-tell.
function laneAProblem(subjectRole, reviewRole, byRole, lines) {
  // (1) the review role's authoritative row carries closedAt.
  const review = byRole[reviewRole];
  if (!review || !review.closedAt) return null;
  const reviewMs = parseClosedAtMs(review.closedAt);
  if (reviewMs === null) return null;

  // (2) the subject role's history has >=2 rows, and its authoritative row carries an agentId AND a
  //     closedAt STRICTLY newer than the review's closedAt (equal allows — same parsed-epoch semantics as
  //     Lane B).
  const subjectAuth = byRole[subjectRole];
  if (!subjectAuth || !subjectAuth.agentId || !subjectAuth.closedAt) return null;
  const subjMs = parseClosedAtMs(subjectAuth.closedAt);
  if (subjMs === null) return null;
  if (!(subjMs > reviewMs)) return null;                 // equal or older -> not a newer unreviewed round.

  const subjectRows = rowsForRole(lines, subjectRole);
  if (subjectRows.length < 2) return null;                // no second round exists to have been left unreviewed
                                                            // (kills the #1760/#1719 resume-re-close class — a
                                                            // same-agent SubagentStop re-append merges onto the
                                                            // SAME row rather than creating a second one).

  // (3) an OLDER subject row exists with a DISTINCT agentId whose closedAt is at-or-before the review's
  //     closedAt — the round the review could actually have covered.
  const olderRows = subjectRows.slice(0, -1);
  const hasCoveredRound = olderRows.some((r) => {
    if (!r || !r.agentId || r.agentId === subjectAuth.agentId) return false;
    const ms = parseClosedAtMs(r.closedAt);
    if (ms === null) return false;
    return ms <= reviewMs;
  });
  if (!hasCoveredRound) return null;

  return 'STALE-REVIEW: ' + reviewRole + ' (closedAt ' + review.closedAt + ') is stale against a newer ' +
    subjectRole + ' round (agentId ' + subjectAuth.agentId + ', closedAt ' + subjectAuth.closedAt +
    ') that the review could not have covered — spawn a fresh ' + reviewRole + ' to cover it.';
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
  // #1947 M-B (execution-review round-2 FAIL) — D2 promised "check output labels these rows distinctly", but
  // the string `dispatch=subprocess-openrouter` previously appeared ONLY in comments and in BLOCK-reason
  // text — never on the success path, so a subprocess-verified row was indistinguishable in `check`'s output
  // from an ordinary harness-signed pass. Collected here and printed unconditionally (success or not, so it
  // is visible even when other roles still have problems) — see the DISPATCH: print near the end.
  const dispatchLabels = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e) { problems.push('missing ' + role + ' ledger line'); continue; }
    const r = checkRole(role, e, session, checkOpts, task);
    if (r) { problems.push(r); continue; }
    // Re-run the SAME pure, side-effect-free admissibility check checkRole() itself just consulted — an
    // empty-string result means "admissible AND fully verified", i.e. this role's pass came from the
    // subprocess arm, not the ordinary agentId arm. #2075 AC-3: label the ROW's actual dispatch value, never
    // a hardcoded vendor literal — a subprocess-ollama row must not be mislabeled subprocess-openrouter.
    if (checkSubprocessProvenance(role, e, session, task) === '') {
      const decl = seatDispatchIsSubprocess(role);
      dispatchLabels.push('role=' + role + ' dispatch=' + e.dispatch + ' model=' + ((decl.seat && decl.seat.model) || '<unknown>'));
    }
  }
  // #1936 -- Lane B (outcome monotonicity) + Lane A (round-aware freshness). Read-side only, strictly
  // additive: both lanes only ADD problems on top of whatever the base existence/checkRole loop above
  // already found (or didn't) -- they never suppress or loosen an existing test, and they run unconditionally
  // (no opt-in flag) for both review-pair roles / both subject-review pairs. Each lane is independently
  // silent on any missing/unparseable/absent input (fail-open by design -- see each function's doc comment).
  for (const role of ['execution-review', 'plan-review']) {
    const laneB = laneBProblem(role, lines);
    if (laneB) problems.push(laneB);
  }
  {
    const laneAExec = laneAProblem('executor', 'execution-review', byRole, lines);
    if (laneAExec) problems.push(laneAExec);
    const laneAPlan = laneAProblem('planner', 'plan-review', byRole, lines);
    if (laneAPlan) problems.push(laneAPlan);
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
    // #1640 S8/S10 — SSOT consultation for the expected side + the declared-reroute contract. Mirrors
    // cmdResolveRoleModel's precedence EXACTLY: an explicit CC_ROLES_ENV override is AUTHORITATIVE + TERMINAL,
    // so it short-circuits SSOT consultation entirely — every PRE-#1640 fixture in this file sets CC_ROLES_ENV
    // and is therefore COMPLETELY UNAFFECTED by anything below (routesLoaded.ok stays false for them, exactly
    // reproducing today's roleModelFromCfg-only comparison).
    const routesLoaded = ('CC_ROLES_ENV' in process.env) ? { ok: false, routes: null, configPath: '' } : loadRoutesConfig();
    if (found) {
      lintRoleConfig(cfg, routesLoaded.ok ? routesLoaded.routes : null);   // S8(b): SSOT-vocabulary hint, additive-only.
      // #1640 S10 binding point 4 — an enforcement run under a caller-supplied CC_ROUTES_JSON audits itself
      // ONCE per invocation, naming the task, regardless of whether any individual role turns out declared.
      if (('CC_ROUTES_JSON' in process.env) && routesLoaded.ok) {
        writeBypassLog('3role-ledger-enforce-role-models', 'ROUTES-OVERRIDE', 'PERMIT',
          { task: sanitize(task), route_config: routesLoaded.configPath });
      }
      for (const role of REQUIRED_ROLES) {
        const e = byRole[role];
        if (!e || ('skip_reason' in e)) continue;              // no transcript to read for a missing / inline-skip role
        if (!agentResolves(session, e.agentId)) continue;      // presence already reported above; can't-tell here

        // #1640 S8 — the SSOT-aware expected side (viaSSOT=false and IDENTICAL to today's roleModelFromCfg
        // whenever CC_ROLES_ENV is set, the role has no declared SSOT seat, or the seat's model is undeclared).
        const expectedSide = resolveExpectedSide(routesLoaded, cfg, role);

        const actualId = transcriptModel(session, e.agentId);   // concrete id, '' if no assistant model line
        const actualAnthropicTier = modelIdToTier(actualId);     // '' unless actualId is a claude-* id

        if (!actualAnthropicTier && !(routesLoaded.ok && identifyModel(routesLoaded.routes, actualId).ok)) {
          // TIER can't-tell (existing fail-open, UNCHANGED) — neither a claude-* id nor SSOT-declared anywhere.
          // The version-pin sub-leg is keyed to the LEGACY expected tier (roleModelFromCfg), exactly as before
          // #1640 — a declared non-Anthropic seat never even reaches a CC_TIER_*_VERSION pin (no such pin
          // exists for a non-Anthropic tier name), so this branch's behavior is byte-identical pre/post-#1640.
          const legacyExpected = roleModelFromCfg(cfg, role);
          const pin = roleVersionFromCfg(cfg, role, legacyExpected);
          if (pin && process.env.CC_ROLE_VERSION_GATE_OFF === '1') {
            writeBypassLog('3role-ledger-enforce-role-models', 'CC_ROLE_VERSION_GATE_OFF', 'PERMIT');
          }
          const versionOn = pin && process.env.CC_ROLE_VERSION_GATE_OFF !== '1';
          if (versionOn) problems.push('MODEL-VERSION: role ' + role + ' — the transcript model is unreadable/' +
            'unparseable (' + (actualId || '<none>') + ') so the ' + legacyExpected + ' pin ' + pin + ' CANNOT be ' +
            'verified (fail-closed: a configured pin means we do not wave through can\'t-tell). ' +
            'Kill-switch: CC_ROLE_VERSION_GATE_OFF=1 (or CC_ROLE_MODEL_GATE_OFF=1).');
          continue;                                              // ... but a pin fail-CLOSES the version sub-leg
        }

        // #1640 S10 binding point 1 — the DECLARED sensor. READ-ONLY: consults ONLY the role's OWN already-
        // recorded ledger stamp (e.reroute, written by S11's spawn/SubagentStop recorder edges) — NEVER
        // process.env.ANTHROPIC_BASE_URL, NEVER a base-url, NEVER a routes-file override, at THIS (check) time.
        // An exported base-url in the check's OWN environment blesses NOTHING (the anti-spoof fixture, AC1.8(e)).
        const stamp = (e.reroute && e.reroute.provider) ? e.reroute : null;
        const seatDeclaredNonAnthropic = !!(expectedSide.viaSSOT && expectedSide.provider && expectedSide.provider !== 'anthropic');
        const declared = !!(stamp && seatDeclaredNonAnthropic && stamp.provider === expectedSide.provider);

        if (actualAnthropicTier) {
          // #1640 S10 binding point 2 — an ANTHROPIC OBSERVATION keeps FULL tier+version enforcement, declared
          // or not: the comparison is against the role's ORDINARY (legacy) policy tier, never the SSOT's
          // declared non-Anthropic tier (which an Anthropic observation could never equal anyway). This is
          // BYTE-IDENTICAL to the pre-#1640 comparison for every role whose seat is not SSOT-declared non-
          // Anthropic (expectedSide.tier === legacyExpected in that case).
          const expected = roleModelFromCfg(cfg, role);
          const pin = roleVersionFromCfg(cfg, role, expected);
          if (pin && process.env.CC_ROLE_VERSION_GATE_OFF === '1') {
            writeBypassLog('3role-ledger-enforce-role-models', 'CC_ROLE_VERSION_GATE_OFF', 'PERMIT');
          }
          const versionOn = pin && process.env.CC_ROLE_VERSION_GATE_OFF !== '1';
          const actual = actualAnthropicTier;
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
          // wrong spawn), and (c) the OBSERVED tier is a STRICT quality up-tier over policy.
          // #1624 (operator decision 2026-07-17): model-cost is enforced at booking/spawn time (the leading-edge
          // gate), not at close — by close the spend is already SUNK, so blocking a role that ran on a STRICTLY
          // more-capable tier than policy does nothing for cost control, it only withholds a quality win. So ANY
          // strict up-tier (isResumeUpTier===true) is now allowed-with-note at close, WITH or WITHOUT a resume
          // boundary. The resume-matched shape above keeps its own RESUME-UPTIER wording (it is telling a true,
          // more specific story — a resumed role, not a fresh spawn); every OTHER strict-up-tier shape (no resume
          // boundary at all, or a resume boundary whose pre-resume model didn't match policy) falls to the
          // CLOSE-UPTIER branch below — a DISTINCT, honestly-worded note (plan-review F1): it must never claim a
          // resume boundary that didn't happen. A DOWN-tier (isResumeUpTier===false) never reaches either branch
          // and still falls straight through to the hard BLOCK below — the guardrail this change does not relax.
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
                note += ' FABLE-CAP-BUDGET: Fable is a capped seat (up to 50% of the weekly limit, not a ' +
                  'deadline); the ~2x-Opus-per-token figure applies to API/usage-credit billing only, not ' +
                  'Max-plan-included usage — surfaced here so the cost is never hidden.';
              }
              resumeNotes.push(note);
              continue;
            }
            // #1624 — no resume boundary (or a resume boundary whose PRE-resume model didn't match policy, so it
            // cannot honestly be attributed to the resume). Either way the role's ACTUAL tier is a strict quality
            // up-tier over policy; the spend is already sunk at close. Allow-with-note using a token that does NOT
            // claim a resume boundary happened (F1 — the resume wording would be a false statement here).
            let closeNote = 'CLOSE-UPTIER: role ' + role + ' ran on a MORE-capable tier than policy — a quality ' +
              'up-tier; the cost is already sunk at close (transcript model ' + actualId + ' (' + actual + ') vs ' +
              'policy ' + expected + '). Model cost is enforced at booking/spawn time, not at close. ' +
              'Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.';
            if (actual === 'fable') {
              closeNote += ' FABLE-CAP-BUDGET: Fable is a capped seat (up to 50% of the weekly limit, not a ' +
                'deadline); the ~2x-Opus-per-token figure applies to API/usage-credit billing only, not ' +
                'Max-plan-included usage — surfaced here so the cost is never hidden.';
            }
            resumeNotes.push(closeNote);
            continue;
          }
          problems.push('MODEL-POLICY: role ' + role + ' ran on ' + actual + ' (transcript model ' + actualId +
            ') but cc-roles.env resolves ' + role + ' -> ' + expected + '. Re-run the role on model:' + expected +
            ', or update CC_ROLE_' + roleKeyStem(role) + '_MODEL in cc-roles.env. Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.' +
            (declared ? ' (NOTE: this role is DECLARED to non-Anthropic provider ' + expectedSide.provider +
              ', but the OBSERVED model is Anthropic and mismatches the ordinary policy tier — declaration ' +
              'never waves an Anthropic mismatch through.)' : ''));
          continue;
        }

        // ── Non-Anthropic observation (actualId resolves via the SSOT vocabulary to SOME provider/tier). ──
        const obsIdent = routesLoaded.ok ? identifyModel(routesLoaded.routes, actualId) : { ok: false };
        const actualProvider = obsIdent.ok ? obsIdent.provider : '';
        const actualTier = obsIdent.ok ? obsIdent.tierEquivalent : '';

        if (!declared) {
          // #1640 S10 binding point 1 — an UNDECLARED non-Anthropic model HARD-BLOCKS, regardless of whether
          // the observed id happens to be a real, SSOT-declared vocabulary entry (S10(b): "catches a sensor
          // that would declare on ANY non-claude id" — a valid-looking vocabulary match is NOT itself a
          // declaration; only a recorded run-time stamp is).
          problems.push('MODEL-POLICY: role ' + role + ' ran on a non-Anthropic model (' + actualId +
            (actualTier ? ', tier_equivalent ' + actualTier : '') + (actualProvider ? ', provider ' + actualProvider : '') +
            ') with NO recorded run-time reroute stamp on its own ledger line — an undeclared non-Anthropic ' +
            'model is hard-blocked (the gate catching an off-policy model is it working). If this is a ' +
            'deliberate declared switch, the role must be spawned/closed through the recorder edges ' +
            '(three-role-spawn-ledger.sh / three-role-subagent-ledger.sh) while the session\'s inherited ' +
            'ANTHROPIC_BASE_URL resolves to a declared SSOT provider row. Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.');
          continue;
        }

        // declared === true from here (stamp present, seat SSOT-declared non-Anthropic, stamp names that seat's
        // OWN declared provider). Binding point 2's fail-closed half: the observed id must be IN-VOCABULARY for
        // the DECLARED provider specifically — a stamp naming provider X never blesses an id from provider Y.
        if (!actualProvider || actualProvider !== expectedSide.provider || actualTier !== expectedSide.tier) {
          problems.push('MODEL-POLICY: role ' + role + ' is DECLARED to provider ' + expectedSide.provider +
            ' (' + expectedSide.model + ', tier_equivalent ' + expectedSide.tier + ') but the OBSERVED model ' +
            actualId + ' resolves to ' + (actualProvider ? 'provider ' + actualProvider + ' / tier_equivalent ' + actualTier : 'no declared provider') +
            ' — off-vocabulary for the declared provider; fail-closed (declaration never waves through an ' +
            'off-vocabulary observation). Kill-switch: CC_ROLE_MODEL_GATE_OFF=1.');
          continue;
        }

        // #1640 S9 — DECLARED ALLOW. The version-pin sub-leg is DORMANT for this observation (per-OBSERVATION,
        // never per-session — an Anthropic observation on this SAME declared role would still hit the fully-
        // enforced branch above): a non-Anthropic observed id can never equal a claude-* version pin, so
        // silently NOT checking it here (rather than always-mismatching) is the correct dormancy, not a gap.
        // #1640 S10 binding point 3 — every declared allow writes the unified audit log (SESSION-REROUTE),
        // naming the task + role + resolved provider; a DATA-SENSITIVITY note rides along when the flipped-to
        // provider does not clear the seat's declared sensitivity class. Read the note text back (parent M1
        // verification): it names the provider row resolved, satisfying S8(a)'s expected-side probe too (the
        // SAME fixture — a declared, in-vocabulary, matching seat — is what makes the expected side observable
        // via THIS surface; see the plan's Advisory A1 gradeability clause).
        const liveSeat = (routesLoaded.routes.seats || {})[role] || {};
        const seatForSensCheck = Object.assign({}, liveSeat, { provider: expectedSide.provider });
        const sensClearance = checkDataSensitivity(routesLoaded.routes, seatForSensCheck);
        let reroteNote = 'SESSION-REROUTE: role ' + role + ' DECLARED to provider ' + expectedSide.provider +
          ' (model ' + expectedSide.model + ', tier_equivalent ' + expectedSide.tier + ') — allowed with note; ' +
          'audit logged; MODEL-VERSION sub-leg dormant for this observation.';
        if (!sensClearance.ok) {
          // #1880 intent 6/7a -- the advisory is NOT silenced by an acceptance; it is REWORDED. A matching
          // acceptance names itself (never claims a refusal that isn't happening); a drifted/absent/mismatched
          // acceptance behaves EXACTLY as if none were present -- the plain uncleared DATA-SENSITIVITY note.
          const acc = checkAcceptance(routesLoaded.routes, seatForSensCheck);
          if (acc.ok) {
            const a = acc.acceptance;
            reroteNote += ' DATA-SENSITIVITY-ACCEPTED: seat ' + role + ' provider ' + a.provider +
              ' posture-at-decision ' + a.posture_at_decision + ' decided ' + a.decided + ' authority ' + a.authority +
              ' — accepted risk, not a refusal.';
          } else {
            reroteNote += ' DATA-SENSITIVITY: ' + sensClearance.reason;
          }
        }
        resumeNotes.push(reroteNote);
        writeBypassLog('3role-ledger-enforce-role-models', 'SESSION-REROUTE', 'PERMIT',
          { task: sanitize(task), role, provider: expectedSide.provider });
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
  // #2075 AC-23 — legacy-row surfacing: ALWAYS-ON (never opt-in, never blocking), the drift detector for an
  // unpatched writer. A required-role row with NO stored `run_kind` key at all predates this design (or was
  // written by a writer that has not been taught to stamp it yet) — its kind is still computed correctly
  // (from live, verified evidence — see provenanceKindOf's legacy branch), this is visibility only.
  const legacyRoles = [];
  for (const role of REQUIRED_ROLES) {
    const e = byRole[role];
    if (!e || ('skip_reason' in e)) continue;   // missing handled above; a skip has no run to classify
    if (!('run_kind' in e)) legacyRoles.push(role);
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
    // #1544 — perf-log jurisdiction-keyed tracked-check, riding the SAME Leg A flag (git-only, always-on).
    // NOT gated on --enforce-artifact-privacy — that is the monotonicity fix (#1590): the perf-log's
    // tracked-ness must not be silenceable by THREE_ROLE_ARTIFACT_PRIVACY_OFF=1.
    const perfLogTracked = o['perf-log'] || '';
    if (perfLogTracked) {
      const pp = checkPerfLogTracked(perfLogTracked);
      if (pp) problems.push('TRACKED: ' + pp);
    }
  }
  // #1532 — executor artifact-KIND leg. Opt-in via --enforce-artifact-role-kind (only the instrumentation
  // gate passes it on the tagged completion path). See executorKindProblem() above for the discrimination;
  // this is a hard BLOCK (pushed to problems[], routed to the same exit-2 path below), not a note — it
  // upgrades the #1509 NOTE-EXECUTOR advisory into a real gate for the #1494 shape.
  if ('enforce-artifact-role-kind' in o) {
    const kp = executorKindProblem(byRole);
    if (kp) problems.push('KIND: ' + kp);
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
  // #1947 M-B — print AFTER the problems-guard (so it only reaches stdout on genuine roles-satisfied paths,
  // matching AC-5(d)/AC-6(d)'s "check exits 0 AND its output labels the row" contract) but BEFORE the final
  // OK: line, honestly distinct from a harness-signed pass exactly as D2 promised.
  if (dispatchLabels.length) {
    console.log('DISPATCH: ' + dispatchLabels.join(' | '));
  }
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
  if (legacyRoles.length) {
    console.log('PROVENANCE-LEGACY: ' + legacyRoles.join(', ') +
      ' — no stored run_kind (pre-#2075 row, or a writer not yet taught to stamp it); kind is computed fresh ' +
      "from this row's live, verified evidence — see `provenance-kind` — never from a stored label.");
  }
  // #1989 — ROUTE-BYPASS trailing-edge detector: an always-on, pure-output advisory (exit code UNCHANGED — the
  // model-policy legs own blocking; this is visibility, not a gate) printed on the roles-satisfied path, sibling
  // of DISPATCH:/NOTE:/NOTE-EXECUTOR:/PROVENANCE:. Fires PER required role when ALL hold: (1) the routes SSOT,
  // read FRESH through seatDispatchIsSubprocess() (M1: the SSOT decides admissibility, never the row — a future
  // seat flip is covered automatically), declares that seat dispatch==subprocess-openrouter; (2) the role's
  // ledger line exists and is not an inline-skip; (3) NO subprocess dispatch stamp SURVIVES on ANY of the role's
  // ledger lines (scans ALL lines[], not just the merged byRole last row — a stamp on ANY surviving line
  // suppresses the advisory for that role).
  //
  // HONEST DETECTION SEMANTICS (round-2 B1 fix, option (i)): absence of a surviving stamp does NOT mean "never
  // attempted" — both sanctioned D3-fallback shapes leave zero surviving ledger evidence: a dispatch that fails
  // pre-success never reaches the helper's success-path stamp write (tools/openrouter-role-dispatch.sh stamps
  // only on success), and a stamped dispatch SUPERSEDED by the bounded Agent-tool retry is ERASED by
  // overlayAppend's clear-list (delete entry.dispatch/transcript_path/nonce, gated on agentResolves — the
  // #1590 monotonicity arm, NOT weakened here). So the advisory's claim is exactly "no surviving subprocess
  // dispatch stamp" — wording that is honest in BOTH a habitual-bypass case AND a genuine D3 fallback (each an
  // exceptional, visible event). It NEVER says "never attempted", and it names the receipt file's
  // OR-DISPATCH-FALLBACK / OR-SEAT-SMOKE lines (task-keyed via task=) as the human disambiguator between the two
  // causes. No absolute $HOME/`/Users/` paths (N5 — the helper is named repo-relatively; advisory stdout gets
  // quoted into committed artifacts). INDEPENDENT of the Direction-2 block-once marker (N3 — different
  // surfaces, different keys, NO shared state; a future "optimization" that suppressed this behind the
  // spawn-time marker would recreate the silent-bypass hole, so the two stay independent in fact, not intent).
  // First-wave volume (N4): both plan-review AND executor are subprocess-declared today, so this fires on
  // essentially every existing task in current session ledgers — the ticket's requested retroactive visibility,
  // not a regression.
  for (const role of REQUIRED_ROLES) {
    const decl = seatDispatchIsSubprocess(role);
    if (!decl.ok) continue;                          // (1) SSOT declares this seat subprocess-dispatched right now
    const e = byRole[role];
    if (!e || ('skip_reason' in e)) continue;         // (2) role line exists and is not an inline-skip
    // (3) no surviving subprocess dispatch stamp on ANY of the role's ledger lines.
    let stampSurvives = false;
    for (const ln of lines) {
      let j; try { j = JSON.parse(ln); } catch (er) { continue; }
      if (j && j.role === role && isSubprocessDispatch(j.dispatch)) { stampSurvives = true; break; }
    }
    if (stampSurvives) continue;
    const seatModel = (decl.seat && decl.seat.model) || '<unknown>';
    console.log('ROUTE-BYPASS: role=' + role + ' (seat model ' + seatModel + ', declared dispatch=subprocess-openrouter)' +
      " — no surviving subprocess dispatch stamp on this routed seat's ledger lines, so its work did not CLOSE" +
      ' via the subprocess route (tools/openrouter-role-dispatch.sh). agent_tool_fallback made the run gate-clean:' +
      ' this is a VISIBILITY note, not a verdict invalidation. The two causes are a habitual Agent-tool bypass OR' +
      " a sanctioned D3 fallback — disambiguate by reading .ai-workspace/status/1947-seat-mix-live-smoke.md's" +
      ' OR-DISPATCH-FALLBACK / OR-SEAT-SMOKE receipt lines (task-keyed via their task= field).');
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
        // #2075 D5(c) — E3 CONTAINMENT (AC-9/AC-11a): a row already carrying protection-verified E2 evidence
        // (a subprocess dispatch, no agentId of its own) must not have its blank modelVersion filled from an
        // unrelated sibling — resolveModelFields('' explicitAgent) would fall back to a blind cross-session
        // search precisely for this row shape. A verified-E1 row is unaffected (its own e.agentId is passed
        // explicitly below, so no search ever runs for it) — AC-10's ordinary-row backfill keeps working.
        if (computeVerifiedKindForProtection(role, e, sess, task) === 'E2') continue;
        scanned++;
        const modelFields = resolveModelFields(sess, task, role, e.agentId || '');
        if (!modelFields.modelVersion) continue; // transcript still carries no message.model line yet -> too early
        // #2075 D1/D5(c) item 2 — stamp run_kind:inferred on anything this heuristic sweep DOES write (same
        // reasoning as cmdReconcileSpawns above; D1 names resolveModelFields's own callers explicitly).
        modelFields.run_kind = 'inferred';
        modelFields.run_source = 'refresh-models';
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

// #1229 — reproduces three-role-subagent-ledger.sh's EXACT self_authored provenance predicate (never a
// blind stamp): an ASSISTANT message in the agent's OWN transcript containing a Bash tool_use whose command
// invokes `3role-ledger.mjs ... append ...` AND names `--role <role>`. Fail-open: any read/parse trouble
// returns false (never fabricates a stamp on a can't-tell path).
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

// #1851 root-cause fix (AC2(ii) -- the hoist's own residual per-group scaling cost; plan finding F1 named this
// exact risk as non-blocking, on the assumption AC9's 60s live ceiling would absorb it -- AC2(ii)'s own load-
// bearing timing assertion proves that assumption wrong for the group-count axis specifically). Before this
// fix, cmdReconcileSpawns's group loop called resolveModelFields() (-> transcriptModel(), which re-`readdir`s
// PROJECTS_ROOT AND full-`readFileSync`s the winner's transcript) AND transcriptSelfAuthored() (an INDEPENDENT
// full `readFileSync` + per-line `JSON.parse` of the SAME winner transcript) as two SEPARATE calls per group.
// D1's hoist collapsed the DISCOVERY pass to O(corpus), but these two later-record derivations read PAST the
// bounded first-record window D2 deliberately stops at, so neither can be served from the D3 per-file
// checkpoint -- leaving a cost that scales with GROUP COUNT ALONE (not corpus size) whenever a meaningful
// fraction of groups still lack modelVersion/self_authored (the cold-start shape AC2(ii)'s fixture measures).
// Measured (Docker --cpus=0.5 --memory=512m, 8 reps, same corpus/5x-G-contrast shape as the smoke's arm(ii)):
// pre-fix ratio ~1.44-1.52x; this fix alone (no test-threshold or fixture change) brings it to ~1.0-1.1x (see
// PR body for the full before/after table) -- confirming the redundant double-read was the dominant driver,
// not environmental noise. deriveLaterRecordFacts() reads the winner's transcript file EXACTLY ONCE and
// extracts everything BOTH fields need in that single pass -- halving the worst-case (both fields missing)
// per-group later-record cost -- and takes the transcript's PATH directly (already known via
// transcriptByAgentId from the single corpus pass) instead of re-deriving it through transcriptModel()'s
// readdir(PROJECTS_ROOT) + per-slug path guess, eliminating a second per-group directory scan entirely.
// transcriptModel()/transcriptSelfAuthored()/resolveModelFields() are left UNCHANGED for their other caller
// (cmdRefreshModels), which does not already hold a transcript-path map and must keep the readdir-based lookup.
function deriveLaterRecordFacts(file, role) {
  const result = { modelId: '', selfAuthored: false };
  let content;
  try { content = fs.readFileSync(file, 'utf8'); } catch (e) { return result; }
  const roleRe = new RegExp('--role\\s+' + role);
  for (const ln of content.split('\n')) {
    const s = ln.trim();
    if (!s) continue;
    let j; try { j = JSON.parse(s); } catch (e) { continue; }
    if (!j) continue;
    const isAsst = j.type === 'assistant' || (j.message && j.message.role === 'assistant');
    if (!isAsst) continue;
    if (j.message && typeof j.message.model === 'string' && j.message.model) result.modelId = j.message.model;
    if (!result.selfAuthored) {
      const c = j.message && j.message.content;
      if (Array.isArray(c)) {
        for (const blk of c) {
          if (!blk || blk.type !== 'tool_use') continue;
          if (String(blk.name || '').toLowerCase() !== 'bash') continue;
          const cmd = String((blk.input && blk.input.command) || '');
          if (/3role-ledger\.mjs[\s\S]*?\bappend\b/.test(cmd) && roleRe.test(cmd)) { result.selfAuthored = true; break; }
        }
      }
    }
  }
  return result;
}

// #1229 / #1851: reconcile-spawns --session S — see the file-header doc block near the top of this file
// (the "reconcile-spawns" subcommand entry) for the full design rationale, including the #1851 incremental
// rewrite (D1 hoist / D2 bounded read / D3 per-file checkpoint / D4 correctness / D5 wall-clock budget / D6
// no-silent-loss). Short version: walks every subagent transcript for the session, discovers tagged (task,
// role) pairs with a REAL transcript, and backfills only what a missing/self-append-only row is missing:
// agentId, modelVersion/modelTier, self_authored. Never touches artifact_path/closedAt/verdict/skip_reason.
// ALWAYS exits 0 (fail-open) — a sweep error must never wedge the hook call it rides.
function cmdReconcileSpawns(o) {
  try {
    const session = o.session;
    if (!session) { console.log('OK reconcile-spawns: no --session given (fail-open, nothing to do)'); process.exit(0); }
    const sess = sanitize(session);
    const startTs = Date.now();
    const budgetMsRaw = Number(process.env.RECONCILE_SPAWNS_BUDGET_MS);
    const budgetMs = Number.isFinite(budgetMsRaw) && budgetMsRaw >= 0 ? budgetMsRaw : 20000; // 0 is a valid ("truncate immediately") value -- must not fall through `||`'s falsy-zero coercion
    const fullRederiveEveryN = Number(process.env.RECONCILE_SPAWNS_FULL_REDERIVE_EVERY_N);
    const FULL_REDERIVE_EVERY_N = Number.isFinite(fullRederiveEveryN) && fullRederiveEveryN > 0 ? fullRederiveEveryN : 20;
    const fullRederiveMaxAgeMs = Number(process.env.RECONCILE_SPAWNS_FULL_REDERIVE_MAX_AGE_MS);
    const FULL_REDERIVE_MAX_AGE_MS = Number.isFinite(fullRederiveMaxAgeMs) && fullRederiveMaxAgeMs > 0 ? fullRederiveMaxAgeMs : (6 * 60 * 60 * 1000);

    let slugs = [];
    try { slugs = fs.readdirSync(PROJECTS_ROOT); }
    catch (e) { console.log('OK reconcile-spawns: no projects root'); process.exit(0); }

    // Discovery pass (unchanged cost model -- cheap, readdir + stat only). Now ALSO captures each transcript's
    // (dev, ino) file identity (the D3 checkpoint cache key).
    let newestMtime = 0;
    const transcripts = []; // {agentId, file, mtimeMs, dev, ino, size}
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
        transcripts.push({ agentId: m[1], file: f, mtimeMs: st.mtimeMs, dev: st.dev, ino: st.ino, size: st.size });
        if (st.mtimeMs > newestMtime) newestMtime = st.mtimeMs;
      }
    }
    if (transcripts.length === 0) { console.log('OK reconcile-spawns: no subagent transcripts for session ' + sess); process.exit(0); }

    // #1851 D6 -- an unreadable/corrupt/schema-mismatched sidecar fails open to the SAME empty shape a
    // genuinely-first-ever run sees (readReconcileCheckpoint's own contract) -- coldStart below is true in
    // both cases, forcing a full re-derivation rather than "nothing to do".
    const checkpoint = readReconcileCheckpoint(sess);
    const coldStart = Object.keys(checkpoint.files).length === 0;
    const nextRunCount = checkpoint.runCount + 1;
    const dueByCount = (nextRunCount % FULL_REDERIVE_EVERY_N) === 0;
    const dueByAge = checkpoint.lastFullDeriveTs === 0 || (Date.now() - checkpoint.lastFullDeriveTs) > FULL_REDERIVE_MAX_AGE_MS;
    const dueForFullRederive = coldStart || dueByCount || dueByAge; // #1851 D6 periodic belt-and-braces (AC5)

    // Cheap per-session watermark: short-circuits to the readdir/stat scan above (no per-transcript read, no
    // writes) when no transcript has advanced past the last sweep AND a periodic full re-derive isn't due
    // (a full re-derive must be able to run even on an otherwise-quiescent session, per D6).
    const watermarkFile = path.join(LEDGER_DIR, sess, '.reconcile-watermark');
    let lastWatermark = 0;
    try { lastWatermark = Number(fs.readFileSync(watermarkFile, 'utf8').trim()) || 0; } catch (e) { lastWatermark = 0; }
    if (!dueForFullRederive && newestMtime > 0 && newestMtime <= lastWatermark) {
      console.log('OK reconcile-spawns: session=' + sess + ' no new transcript activity since last sweep (watermark)');
      process.exit(0);
    }

    // #1851 D1/D2/D3/D5 -- the ONE pass that replaces the old per-group resolveAgent() re-scan. Oldest-first
    // (D5: strict forward progress under a wall-clock budget -- if truncated, the OLDEST unprocessed
    // transcripts are exactly what the NEXT invocation picks up first). For each transcript: reuse its
    // per-file checkpoint (D3) when NOT due a full re-derive AND the file's identity is unchanged AND its
    // size has not SHRUNK (D3: a shrink means possible truncation/rewrite -> re-derive); otherwise a bounded
    // D2 read + D1 tag extraction. Builds `groups` (every known (task, role) pair -- D6: never skipped just
    // because its transcript didn't change) and `tagWinners` (the newest-mtime candidate per group, replacing
    // resolveAgent()'s per-group corpus re-scan with a Map lookup).
    const sortedTranscripts = transcripts.slice().sort((a, b) => a.mtimeMs - b.mtimeMs);
    const newFilesCache = Object.assign({}, checkpoint.files); // seed with prior knowledge (D5 partial-progress safety)
    const groups = new Set(); // "task role"
    const tagWinners = new Map(); // "task role" -> {agentId, mtimeMs}
    const transcriptByAgentId = new Map();
    for (const t of transcripts) transcriptByAgentId.set(t.agentId, t);

    let firstRecordsRead = 0;
    let firstRecordsCached = 0;
    let truncated = false;
    for (const t of sortedTranscripts) {
      if (Date.now() - startTs >= budgetMs) { truncated = true; break; }
      const identity = t.dev + ':' + t.ino;
      const cachedEntry = !dueForFullRederive ? checkpoint.files[identity] : undefined;
      let discovery, winners;
      if (cachedEntry && t.size >= cachedEntry.size) {
        discovery = cachedEntry.discovery || null;
        winners = Array.isArray(cachedEntry.winners) ? cachedEntry.winners : [];
        firstRecordsCached++;
      } else {
        const line = readFirstNonEmptyLine(t.file);
        const text = firstRecordTextFromLine(line);
        const extracted = extractTagsFromText(text);
        discovery = extracted.discovery;
        winners = extracted.winners;
        firstRecordsRead++;
      }
      newFilesCache[identity] = { size: t.size, discovery, winners };
      if (discovery) groups.add(discovery.task + ' ' + discovery.role);
      for (const w of winners) {
        const key = w.task + ' ' + w.role;
        const cur = tagWinners.get(key);
        if (!cur || t.mtimeMs > cur.mtimeMs) tagWinners.set(key, { agentId: t.agentId, mtimeMs: t.mtimeMs });
      }
    }

    // #1851 D1/D4/D6 -- group -> row loop. Same per-row semantics as before (never disturb an inline-skip row
    // or a row already bound to a DIFFERENT agentId -- the #1580 round-boundary trap), but the winner is now a
    // Map lookup (tagWinners), never a resolveAgent() corpus re-scan. modelVersion resolution is now GATED on
    // `!prior.modelVersion` (D1 item 5 fix -- previously unconditional); self_authored keeps its existing gate.
    let scanned = 0;
    let groupsEvaluated = 0;
    let changed = 0;
    let laterRecordRederives = 0;
    let anyRowFailed = false;
    const groupsArr = Array.from(groups);
    for (const key of groupsArr) {
      if (Date.now() - startTs >= budgetMs) { truncated = true; break; }
      const [task, role] = key.split(' ');
      groupsEvaluated++;
      scanned++;

      const winner = tagWinners.get(key);
      const agentId = winner ? winner.agentId : '';
      if (!agentId) continue; // fail-open: matches resolveAgent()'s own '' return for an unbound group (D1 seam).

      const file = ledgerFile(sess, task);
      let lines = [];
      try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()); } catch (e) { /* no ledger yet */ }
      let prior = null;
      for (const ln of lines) { try { const j = JSON.parse(ln); if (j && j.role === role) prior = j; } catch (e) { /* skip */ } }

      // Never disturb an inline-skip row (mirrors cmdRefreshModels's own `if ('skip_reason' in e) continue`).
      if (prior && ('skip_reason' in prior)) continue;
      // Never disturb a row that already carries a DIFFERENT real agentId (the #1580 round-boundary trap) --
      // write ONLY when the row is absent, its agentId is absent, or its agentId equals the resolved one.
      if (prior && prior.agentId && prior.agentId !== agentId) continue;
      // #2075 D5(c) — E3 CONTAINMENT (fixes B16, the ~30s corruption timer). `agentId` above is ALWAYS
      // E3-derived (a blind, cross-session, newest-mtime SEARCH — resolveAgent()'s own contract), so the one
      // genuine corruption vector is a row that ALREADY carries protection-verified E2 evidence (a subprocess
      // dispatch with no agentId of its own): this sweep's search could otherwise find an unrelated Anthropic
      // sibling's transcript and misattribute its model onto this row (measured live, cairn 2026-07-28:270).
      // A row already carrying a resolving+bound agentId (verified E1) is UNAFFECTED by this guard — its own
      // agentId is passed explicitly to deriveLaterRecordFacts below, so no blind search ever runs for it
      // (AC-10's ordinary-Anthropic-row backfill keeps working unchanged).
      if (computeVerifiedKindForProtection(role, prior, sess, task) === 'E2') continue;

      // Compute ONLY the fields genuinely missing so a group with nothing left to add makes NO overlayAppend
      // call at all (idempotency -- a bare re-append would still refresh `ts` and break byte-identity).
      const fields = {};
      let hasChange = false;
      if (!prior || !prior.agentId) { fields.agentId = agentId; hasChange = true; }

      // #1851 D1 item 5 fix: GATE modelVersion/self_authored resolution on absence (previously modelVersion was
      // unconditional -- a fixed bug: an already-stamped row paid a full transcript re-parse on every sweep
      // forever). #1851 root-cause fix (AC2(ii)): a group needing EITHER field used to pay TWO separate full
      // transcript re-reads (resolveModelFields -> transcriptModel, then transcriptSelfAuthored) -- now ONE
      // deriveLaterRecordFacts() call serves both, halving the per-group later-record cost (see its own header
      // comment for the measured before/after).
      const needModelVersion = !prior || !prior.modelVersion;
      const needSelfAuthored = !prior || !prior.self_authored;
      if (needModelVersion || needSelfAuthored) {
        laterRecordRederives++;
        const tr = transcriptByAgentId.get(agentId);
        const facts = tr ? deriveLaterRecordFacts(tr.file, role) : { modelId: '', selfAuthored: false };
        if (needModelVersion && facts.modelId) {
          fields.modelVersion = facts.modelId;
          hasChange = true;
          const tier = modelIdToTier(facts.modelId) || identifyModelViaSSOT(facts.modelId);
          if (tier && (!prior || !prior.modelTier)) { fields.modelTier = tier; hasChange = true; }
        }
        if (needSelfAuthored && facts.selfAuthored) { fields.self_authored = true; hasChange = true; }
      }

      if (!hasChange) continue;
      // #2075 D1/D5(c) item 2 — stamp run_kind:inferred on anything this heuristic sweep DOES write (round-1
      // blocker B3's fix: a search-backfilled row must never be byte-identical on disk to a genuine E1 row).
      // The write-once clamp in overlayAppend means this can only ever RAISE an absent/lower stored value,
      // never lower an already-classified row's — no extra guard needed here.
      fields.run_kind = 'inferred';
      fields.run_source = 'reconcile-spawns';
      try { overlayAppend(sess, task, role, fields); changed++; }
      catch (e) { anyRowFailed = true; /* one row's failure is logged-and-skipped, never fatal */ console.error('WARN reconcile-spawns: row ' + task + '/' + role + ' failed: ' + (e && e.message ? e.message : e)); }
    }

    // #1851 D3 -- persist every per-file checkpoint earned this run (even a truncated one -- D5 partial-progress
    // safety) and the run bookkeeping (runCount always advances; lastFullDeriveTs advances only when a full
    // re-derive actually happened this run).
    writeReconcileCheckpoint(sess, {
      schemaVersion: RECONCILE_CHECKPOINT_SCHEMA,
      runCount: nextRunCount,
      lastFullDeriveTs: dueForFullRederive ? Date.now() : checkpoint.lastFullDeriveTs,
      files: newFilesCache,
    });

    // #1851 D4(c) -- the coarse watermark advances ONLY after a sweep that completed with nothing truncated or
    // row-failed (previously unconditional -- a real bug: a failed row was never retried unless some
    // transcript's mtime happened to advance past it).
    if (!truncated && !anyRowFailed) {
      try { fs.mkdirSync(path.dirname(watermarkFile), { recursive: true }); fs.writeFileSync(watermarkFile, String(newestMtime)); } catch (e) { /* best-effort */ }
    }
    if (changed > 0) fireResyncBackground();
    const elapsedMs = Date.now() - startTs;
    console.log(
      'OK reconcile-spawns: session=' + sess + ' scanned=' + scanned + ' changed=' + changed +
      ' transcripts=' + transcripts.length +
      ' firstRecordsRead=' + firstRecordsRead + ' firstRecordsCached=' + firstRecordsCached +
      ' groupsKnown=' + groups.size + ' groupsEvaluated=' + groupsEvaluated +
      ' laterRecordRederives=' + laterRecordRederives +
      ' elapsedMs=' + elapsedMs +
      ' truncated=' + truncated +
      ' coldStart=' + coldStart + ' fullRederive=' + dueForFullRederive
    );
    process.exit(0);
  } catch (e) {
    console.log('OK reconcile-spawns: error (fail-open): ' + (e && e.message ? e.message : e));
    process.exit(0);
  }
}
// #1448: resolve-role-model --role <role> [--with-effort] [--with-version]
// Prints the configured model TIER for a role (the single value the orchestrator + both model hooks consume),
// fail-SAFE to opus (missing/malformed config OR an invalid per-role value => opus). With --with-effort prints
// "<model> <effort>". Lints the config on read (defect-3 stderr visibility). Always exits 0 — a resolver error
// must never wedge a spawn; opus is the safe answer.
//
// #1640 S6/S7 — SSOT-first read path, presence-guarded fallback (SKIP-not-FAIL, #1619). This is the ONLY
// consumer of config/cc-routes.json for role->model resolution — `check --enforce-role-models`'s own
// roleModelFromCfg() call (below) is UNTOUCHED, still 100% the legacy path; widening it is out of scope here
// and would risk the byte-frozen hooks/3role-ledger-smoke-test.sh (its M1-M9 arms, AC1.3). Precedence, in
// priority order (each short-circuits the ones below it):
//   1. SSOT PRESENT but CORRUPT (unparseable JSON / unreadable) -> UNCONDITIONAL fail-safe to opus for the
//      requested role, regardless of CC_ROLES_ENV — never a silent fall-through to a possibly-stale legacy
//      view (S7 AC1.5 a-control: a present, differently-configured env view must NOT rescue a broken SSOT —
//      the safety-critical case). The lint (routesLoaded.error) names the offending file on stderr.
//   2. CC_ROLES_ENV explicitly SET in process.env -> an explicit legacy-only override, extending the
//      existing AUTHORITATIVE+TERMINAL test/debug-isolation semantic (#1448, resolveConfigPath() above) to
//      also mean "skip SSOT" — resolves via TODAY'S frozen legacy path verbatim. This is what keeps the
//      byte-frozen smoke's CC_ROLES_ENV-driven arms (M1-M9, always explicitly set) passing unedited (AC1.3).
//   3. SSOT PRESENT + VALID + CC_ROLES_ENV unset -> the real SSOT-first path (S6): look up
//      routes.seats[role]; a MISSING key fail-safes JUST that role to opus (S7 AC1.5 b — proves per-role
//      isolation, not a global crash); a PRESENT seat resolves its declared model's tier via identifyModel().
//      Effort/version are enriched from the legacy cfg (same default candidate chain) when resolvable — the
//      SSOT schema doesn't carry per-role effort/version yet, and this keeps a real, unguarded invocation's
//      output identical to today's (the two sources agree on every role's TIER as of the S1 import / #1813
//      re-verify — hand-verified byte-identical for all six roles across all three flag shapes at S6 time —
//      so this branch is provably a no-op on THIS repo's checked-in files today, AC1.1).
//   4. SSOT genuinely ABSENT (ROUTE-NOT-FOUND) -> presence-guarded SKIP-not-FAIL (S6/AC1.2): fall back 100%
//      to today's frozen legacy path — a consumer that hasn't adopted the SSOT yet must not break.
function printRoleModel(model, effort, version, withEffort, withVersion) {
  if (!withEffort && !withVersion) { console.log(model); process.exit(0); }
  if (withEffort && !withVersion) {
    // #1448 shape, UNCHANGED for back-compat (three-role-model-policy-gate.sh does `read -r EXPECTED EFFORT`):
    // "<model> <effort>", or bare "<model>" when no effort is configured (no trailing empty token).
    console.log(model + (effort ? ' ' + effort : ''));
    process.exit(0);
  }
  // #1466 — version requested (alone, or together with effort). `version` is NEVER empty — a spawn-time
  // badge stamp must always have something non-blank to show. When effort is ALSO requested but unresolved,
  // use a `-` sentinel (not '') so a plain `read -r A B C` over the space-joined line always yields exactly
  // 3 tokens.
  const tokens = withEffort ? [model, effort || '-', version || model] : [model, version || model];
  console.log(tokens.join(' '));
  process.exit(0);
}

// TODAY'S frozen resolution — byte-identical to the pre-#1640-S6 `cmdResolveRoleModel` body. Used both as the
// CC_ROLES_ENV-explicit-override branch and as the SSOT-genuinely-absent fallback branch.
function legacyResolveRoleModel(role, withEffort, withVersion) {
  const { found, cfg } = loadRoleConfig();
  if (found) lintRoleConfig(cfg);
  const model = found ? roleModelFromCfg(cfg, role) : 'opus';
  const effort = found ? roleEffortFromCfg(cfg, role) : '';
  const version = (found && roleVersionFromCfg(cfg, role, model)) || model;
  printRoleModel(model, effort, version, withEffort, withVersion);
}

function cmdResolveRoleModel(o) {
  const role = o.role;
  if (!role) { console.error('resolve-role-model: --role is required (planner|plan-review|executor|execution-review|orchestrator|research)'); process.exit(2); }
  const withEffort = ('with-effort' in o);
  const withVersion = ('with-version' in o);

  // Step 1 — corrupt/unreadable SSOT: unconditional fail-safe, checked BEFORE any CC_ROLES_ENV override
  // (S7 a-control: a present, differently-configured legacy view must NEVER rescue a broken SSOT).
  const routesLoaded = loadRoutesConfig();
  if (!routesLoaded.ok && /^ROUTE-(PARSE|READ)-ERROR/.test(routesLoaded.error)) {
    process.stderr.write(routesLoaded.error + '\n');
    printRoleModel('opus', '', 'opus', withEffort, withVersion);
    return;
  }

  // Step 2 — explicit legacy-only override (see precedence note above).
  if ('CC_ROLES_ENV' in process.env) {
    return legacyResolveRoleModel(role, withEffort, withVersion);
  }

  // Step 3 — SSOT present + valid + no override: the real SSOT-first path (S6).
  if (routesLoaded.ok) {
    const seat = (routesLoaded.routes.seats || {})[role];
    if (!seat) {
      process.stderr.write('ROUTE-ROLE-MISSING: routes.seats.' + role + ' not declared in ' + routesLoaded.configPath +
        ' -- falling back to opus fail-safe (this role only).\n');
      printRoleModel('opus', '', 'opus', withEffort, withVersion);
      return;
    }
    // #1947 AC-2/M3 -- a seat carrying an explicit `agent_tool_fallback` tier (the two subprocess-dispatched
    // seats, plan-review/executor) resolves to THAT tier here, NEVER to model_vocabulary's tier_equivalent.
    // Both OpenRouter dispatch slugs (moonshotai/kimi-k3, z-ai/glm-5.2) carry tier_equivalent:"fable" -- using
    // it here would silently burn the Fable weekly cap the moment any accidental Agent-tool spawn (or a D3
    // bounded fallback-to-Anthropic retry) resolved this role. `resolve-role-model` must keep answering with
    // the SAFE fallback tier so that path lands on today's proven behavior (opus/sonnet), never fable.
    if (seat.agent_tool_fallback && ROLE_MODELS.includes(seat.agent_tool_fallback)) {
      const fbTier = seat.agent_tool_fallback;
      const { found: fbFound, cfg: fbCfg } = loadRoleConfig();
      if (fbFound) lintRoleConfig(fbCfg);
      const fbEffort = fbFound ? roleEffortFromCfg(fbCfg, role) : '';
      const fbVersion = (fbFound && roleVersionFromCfg(fbCfg, role, fbTier)) || fbTier;
      printRoleModel(fbTier, fbEffort, fbVersion, withEffort, withVersion);
      return;
    }
    const ident = identifyModel(routesLoaded.routes, seat.model);
    if (!ident.ok || !ident.tierEquivalent) {
      process.stderr.write('ROUTE-MODEL-UNDECLARED: routes.seats.' + role + '.model "' + seat.model +
        '" is not in any provider\'s declared vocabulary -- falling back to opus fail-safe (this role only).\n');
      printRoleModel('opus', '', 'opus', withEffort, withVersion);
      return;
    }
    const tier = ident.tierEquivalent;
    const { found: legacyFound, cfg: legacyCfg } = loadRoleConfig();
    if (legacyFound) lintRoleConfig(legacyCfg);
    const effort = legacyFound ? roleEffortFromCfg(legacyCfg, role) : '';
    const version = (legacyFound && roleVersionFromCfg(legacyCfg, role, tier)) || seat.model || tier;
    printRoleModel(tier, effort, version, withEffort, withVersion);
    return;
  }

  // Step 4 — SSOT genuinely ABSENT (ROUTE-NOT-FOUND): presence-guarded SKIP-not-FAIL (S6/AC1.2).
  return legacyResolveRoleModel(role, withEffort, withVersion);
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
// #1640 S10 point 3/4 — OPTIONAL 4th param `extra` ({task, role, provider, route_config}), overlaid onto the
// record only when the caller supplies it. Every PRE-#1640 call site (the *_OFF/*_OVERRIDE kill-switch bypass
// logging elsewhere in this file) passes 3 args, so `extra` is undefined and the record keeps writing EXACTLY
// the pre-#1640 8-key shape (see docs/rule-12-overrides-log-schema.md) — additive-only, never a behavior change
// for those writers. The declared-reroute `SESSION-REROUTE`/`ROUTES-OVERRIDE` audit lines (cmdCheck's enforce
// leg, below) are the only callers that pass `extra`, naming the task/role/resolved-provider so the printed
// note's claim ("allowed with note; audit logged") is independently checkable in the log file itself — never a
// second, quieter log (the parent's binding point 3).  Also widens the `var` sanitizer to allow `-` (unchanged
// for every existing all-underscore *_OFF/*_OVERRIDE varName; needed so 'SESSION-REROUTE'/'ROUTES-OVERRIDE'
// survive intact for the grep-based ACs).
function writeBypassLog(hookName, varName, decision, extra) {
  try {
    const record = {
      ts: new Date().toISOString(),
      session: '',
      agent: '',
      task: '',
      role: 'orchestrator',
      hook: sanitize(hookName),
      var: String(varName || '').replace(/[^A-Za-z0-9_-]/g, ''),
      decision: (String(decision).toUpperCase() === 'DENY') ? 'DENY' : 'PERMIT',
    };
    if (extra && typeof extra === 'object') {
      if (extra.task) record.task = sanitize(extra.task);
      if (extra.role) record.role = sanitize(extra.role);
      if (extra.provider) record.provider = sanitize(extra.provider);
      if (extra.route_config) record.route_config = String(extra.route_config);
    }
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

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
// #1640 M0 — Model Router SSOT v2: resolve-route / identify-model / lint-routes (build-slices S1-S4).
//
// ADDITIVE ONLY: nothing above this block is touched. The frozen `resolve-role-model` contract (roleModelFromCfg,
// lintRoleConfig, modelIdToTier, resolveConfigPath/loadRoleConfig, CC_ROLES_ENV) is untouched — AC0.3/AC0.4 prove
// byte-for-byte zero behavior change. Nothing in the existing chain consumes any of this yet (M0 is a
// zero-behavior-change milestone; config/cc-roles.env stays authoritative for the interactive chain until M1/S13).
// See `.ai-workspace/plans/2026-07-17-fable-router.md` (parent, milestone M0) and its decomposition
// `.ai-workspace/plans/2026-07-17-fable-1640-router-build-slices.md` (S1-S5).

// Resolve config/cc-routes.json's path. Mirrors resolveConfigPath()'s CC_ROLES_ENV pattern exactly:
//   CC_ROUTES_JSON, when SET, is AUTHORITATIVE + TERMINAL (unreadable/absent path => not-found, same shape as
//   CC_ROLES_ENV=/nonexistent above) — this is what every M0 fixture uses to point at a bundled red/green file
//   without touching the shipped config/cc-routes.json. Unset => config/cc-routes.json next to this file,
//   walked through fs.realpathSync (symlink-safe — same defect-1b rationale as resolveConfigPath()).
function resolveRoutesConfigPath() {
  if ('CC_ROUTES_JSON' in process.env) {
    const p = process.env.CC_ROUTES_JSON;
    return (p && fileExists(p)) ? p : '';
  }
  let selfDir;
  try { selfDir = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))); }
  catch (e) { selfDir = path.dirname(fileURLToPath(import.meta.url)); }
  const cand = path.join(selfDir, '..', 'config', 'cc-routes.json');
  return fileExists(cand) ? cand : '';
}

// Load + parse the routes SSOT. Never throws: { ok, routes, error, configPath }. A missing file, an unreadable
// file, and unparseable JSON are all distinct, honestly-labeled ROUTE-* errors (never a silent {}).
function loadRoutesConfig() {
  const configPath = resolveRoutesConfigPath();
  if (!configPath) return { ok: false, routes: null, error: 'ROUTE-NOT-FOUND: no config/cc-routes.json resolved (checked CC_ROUTES_JSON / config/cc-routes.json)', configPath: '' };
  let raw;
  try { raw = fs.readFileSync(configPath, 'utf8'); }
  catch (e) { return { ok: false, routes: null, error: 'ROUTE-READ-ERROR: ' + configPath + ': ' + (e && e.message ? e.message : e), configPath }; }
  let routes;
  try { routes = JSON.parse(raw); }
  catch (e) { return { ok: false, routes: null, error: 'ROUTE-PARSE-ERROR: ' + configPath + ': ' + (e && e.message ? e.message : e), configPath }; }
  return { ok: true, routes, error: '', configPath };
}

// Credential-hygiene lint (AC0.6, #1640 S1). Every `auth`/`*credential*`-class field on a provider row must be
// an env:/keychain: indirection — no literal credential value, no "non-secret literal" escape (review B3 deleted
// that escape; endpoint URLs are not credential-class and are covered by the smoke's separate count-based scans,
// not this lint). Returns an array of problem strings naming the offending key (empty = clean).
function lintRoutesConfig(routes) {
  const problems = [];
  if (!routes || typeof routes !== 'object') return problems;
  const providers = routes.providers || {};
  for (const [pid, row] of Object.entries(providers)) {
    if (!row || typeof row !== 'object') continue;
    for (const key of Object.keys(row)) {
      if (!/^auth$/i.test(key) && !/credential/i.test(key)) continue;
      const val = row[key];
      if (typeof val !== 'string') continue;
      if (!/^(env:|keychain:)/.test(val)) {
        problems.push('ROUTE-SECRET-LITERAL: providers.' + pid + '.' + key + ' is not an env:/keychain: indirection');
      }
    }
  }
  return problems;
}

// C-2 capability guard (resolve-time, parent AC0.2 / S2). Fail-closed on a missing OR unknown task_class,
// treated as the MOST restrictive class (sustained-agentic) — never silently permissive. Three-part refusal
// shape is assembled by the caller (nonzero exit + this reason on stderr + empty stdout); this function only
// decides ok/reason.
const MOST_RESTRICTIVE_TASK_CLASS = 'sustained-agentic';
function checkCapability(routes, seatRow) {
  const taskClasses = (routes && routes.task_classes) || {};
  const rawClass = seatRow && seatRow.task_class;
  const effectiveClass = (rawClass && Object.prototype.hasOwnProperty.call(taskClasses, rawClass))
    ? rawClass : MOST_RESTRICTIVE_TASK_CLASS;
  const classDef = taskClasses[effectiveClass];
  const provider = seatRow && seatRow.provider;
  const allowed = (classDef && Array.isArray(classDef.allowed_providers)) ? classDef.allowed_providers : [];
  if (!allowed.includes(provider)) {
    return { ok: false, reason: 'ROUTE-FEASIBILITY: provider "' + provider + '" is not allowed for task_class "' +
      effectiveClass + '" (seat declared: ' + (rawClass || '<missing>') + ')' };
  }
  return { ok: true, reason: '' };
}

// C-3 data-sensitivity guard (resolve-time, parent AC0.8 / S3). Fail-closed on a missing seat sensitivity
// (treated operator-private) AND on a missing/unverified/unrecognized provider posture (treated
// unverified-or-trains) — an unverified external fact can only over-restrict, never leak. The lattice's middle
// class (no-training-default) clears `internal` but REFUSES `operator-private` — the review-B2 boundary.
const DATA_POSTURE_CLASSES = ['local', 'zdr-enforced', 'anthropic-baseline', 'no-training-default', 'unverified-or-trains'];
const DATA_SENSITIVITY_CLEARANCE = {
  'operator-private': ['local', 'zdr-enforced', 'anthropic-baseline'],
  'internal': ['local', 'zdr-enforced', 'anthropic-baseline', 'no-training-default'],
  'public': null, // bounded only by C-2 — every posture clears
};
function checkDataSensitivity(routes, seatRow) {
  const providers = (routes && routes.providers) || {};
  const rawSensitivity = seatRow && seatRow.data_sensitivity;
  const sensitivity = Object.prototype.hasOwnProperty.call(DATA_SENSITIVITY_CLEARANCE, rawSensitivity)
    ? rawSensitivity : 'operator-private';
  const provider = seatRow && seatRow.provider;
  const providerRow = providers[provider];
  const rawPosture = providerRow && providerRow.data_posture && providerRow.data_posture.class;
  const posture = (rawPosture && DATA_POSTURE_CLASSES.includes(rawPosture)) ? rawPosture : 'unverified-or-trains';
  const clearance = DATA_SENSITIVITY_CLEARANCE[sensitivity];
  if (clearance !== null && !clearance.includes(posture)) {
    return { ok: false, reason: 'ROUTE-DATA-SENSITIVITY: seat sensitivity "' + sensitivity + '" (declared: ' +
      (rawSensitivity || '<missing>') + ') is not cleared for provider "' + provider + '" posture "' + posture +
      '" (declared: ' + (rawPosture || '<missing>') + ')' };
  }
  return { ok: true, reason: '' };
}

// C-3W — the accepted-disclosure last-resort check (#1880, Intent 3/3a). Consulted ONLY when C-3 has already
// refused (resolveRoute/checkEnvelope both gate this behind a failed checkDataSensitivity — C-3W can never
// touch C-2, never widen C-3's own lattice, and never apply to a provider it does not name). Clears a C-3
// refusal for a seat ONLY when `seatRow.accepted_disclosure` (an array) contains a record whose `provider`,
// `sensitivity_at_decision`, and `posture_at_decision` all match — EXACTLY, three-way — the seat's declared
// provider and the RAW DECLARED values `checkDataSensitivity` reads BEFORE normalising them (never the
// normalised `operator-private`/`unverified-or-trains` fallback locals): a typo'd/omitted/unrecognised
// sensitivity, or a missing/deleted/changed posture, therefore matches no record and the C-3 refusal stands.
// Never throws on absent/malformed/wrong-typed input — a crash is not a refusal (AC-7 arms (d)/(f3)).
const ROUTE_ACCEPTED_RISK_TOKEN = 'ROUTE-ACCEPTED-RISK';
const ACCEPTANCE_REQUIRED_FIELDS = ['provider', 'sensitivity_at_decision', 'posture_at_decision', 'decided', 'authority'];
function checkAcceptance(routes, seatRow) {
  const providers = (routes && routes.providers) || {};
  const rawSensitivity = seatRow && seatRow.data_sensitivity;
  const provider = seatRow && seatRow.provider;
  const providerRow = providers[provider];
  const rawPosture = providerRow && providerRow.data_posture && providerRow.data_posture.class;
  const records = Array.isArray(seatRow && seatRow.accepted_disclosure) ? seatRow.accepted_disclosure : [];
  for (const rec of records) {
    if (!rec || typeof rec !== 'object' || Array.isArray(rec)) continue; // wrong-type entry -- skip, never throw
    let hasAllRequired = true;
    for (const f of ACCEPTANCE_REQUIRED_FIELDS) {
      if (typeof rec[f] !== 'string' || rec[f].length === 0) { hasAllRequired = false; break; }
    }
    if (!hasAllRequired) continue; // missing/blank required field -- invalid record, skip
    if (rec.provider !== provider) continue; // wrong-provider record -- never leaks across providers
    if (rec.sensitivity_at_decision !== rawSensitivity) continue; // matched against the RAW string, not the normalised fallback
    if (rec.posture_at_decision !== rawPosture) continue; // matched against the RAW string, not the normalised fallback
    return { ok: true, acceptance: rec };
  }
  return { ok: false, acceptance: null };
}

// Model-identity vocabulary query (AC0.9, S4 — the ROOT fix for stack break 1: modelIdToTier() returns '' for
// any non-claude-* id today). Given a model id, returns its SSOT-declared provider + tier-equivalent; an
// undeclared id refuses (caller emits nonzero exit + empty stdout, no fabricated match).
function identifyModel(routes, modelId) {
  const providers = (routes && routes.providers) || {};
  for (const [pid, row] of Object.entries(providers)) {
    const vocab = (row && row.model_vocabulary) || {};
    if (Object.prototype.hasOwnProperty.call(vocab, modelId)) {
      const entry = vocab[modelId] || {};
      return { ok: true, provider: pid, tierEquivalent: entry.tier_equivalent || '' };
    }
  }
  return { ok: false, provider: '', tierEquivalent: '' };
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
// #1640 M1 (S8-S13) — expected-side expressibility, provider-scoped version pins, the DECLARED-REROUTE
// contract, the spawn-gate sensor + recorder, and board-badge honesty. Every helper below is a NEW consumer of
// the M0 primitives above (identifyModel / loadRoutesConfig) — nothing in M0 (S1-S5) or the frozen S6/S7
// `resolve-role-model` path is edited. See .ai-workspace/plans/2026-07-23-1640-s8-s13.md.

// Best-effort bridge: resolve a model id's SSOT tier_equivalent, or '' on ANY failure (no SSOT resolvable, id
// undeclared in every provider's vocabulary, read/parse error). Used to WIDEN several pre-existing "claude-*
// only" tier readers (modelIdOrAliasToTier, resolveEffectiveTier's session-read branch, resolveModelFields)
// so a genuinely SSOT-declared non-Anthropic id resolves instead of falling through to 'unknown'/absent. Never
// throws; never invents a match the SSOT does not declare.
function identifyModelViaSSOT(modelId) {
  try {
    const rl = loadRoutesConfig();
    if (!rl.ok) return '';
    const ident = identifyModel(rl.routes, modelId);
    return (ident.ok && ident.tierEquivalent) ? ident.tierEquivalent : '';
  } catch (e) { return ''; }
}

// #1640 S10/S11 — resolve a provider id from a base-url via `providers.<id>.endpoint` (a Lane-I FIXTURE-ONLY
// schema field in this PR — the live config/cc-routes.json provider rows carry no endpoint yet; see the plan's
// advisory A2 / `## Deferred-follow-ups`, S18 populates the live rows). Returns '' when the url is empty or
// matches no provider row.
function resolveProviderByEndpoint(routes, baseUrl) {
  const url = String(baseUrl == null ? '' : baseUrl).trim();
  if (!url) return '';
  const providers = (routes && routes.providers) || {};
  for (const [pid, row] of Object.entries(providers)) {
    if (row && typeof row.endpoint === 'string' && row.endpoint && row.endpoint === url) return pid;
  }
  return '';
}

// #1640 S11 — the RUN-TIME reroute SENSOR (the "declared" stamp's ONLY producer). Called EXCLUSIVELY at RUN
// edges — the PostToolUse spawn-ledger hook and the SubagentStop subagent-ledger hook, via `append
// --sense-reroute` — NEVER at CHECK time (S10 binding point 1: the completion gate reads only the recorded
// stamp it produces, never re-senses `process.env.ANTHROPIC_BASE_URL` itself; `cmdCheck` below never calls this
// function). Reads the CURRENT environment's inherited `ANTHROPIC_BASE_URL` (the two-var gateway switch — see
// the plan's precondition note) at THIS moment, resolves it to an SSOT provider row, and — ONLY when the role's
// OWN SSOT seat is BOTH `session-reroutable:true` AND itself provider-non-anthropic (the seat's declared
// intent) — returns a stamp `{provider, resolvedAt}`. Returns null (no stamp recorded — the role stays
// UNDECLARED, the correct fail-closed default) on any ineligible/unresolvable combination: no base-url
// inherited, the SSOT unreadable, the role has no declared seat, the seat is not session-reroutable, the seat's
// own declared provider IS anthropic (nothing to declare), or the base-url resolves to no provider row.
function senseReroute(role) {
  try {
    const baseUrl = process.env.ANTHROPIC_BASE_URL || '';
    if (!baseUrl) return null;
    const rl = loadRoutesConfig();
    if (!rl.ok) return null;
    const seat = (rl.routes.seats || {})[role];
    if (!seat || !seat['session-reroutable']) return null;
    if (!seat.provider || seat.provider === 'anthropic') return null;
    const pid = resolveProviderByEndpoint(rl.routes, baseUrl);
    if (!pid) return null;
    return { provider: pid, resolvedAt: new Date().toISOString() };
  } catch (e) { return null; }
}

// #1640 S8 — the completion gate's SSOT-aware EXPECTED-side resolver (the enforce/gate consumer S8 adds — NOT
// `cmdResolveRoleModel`, which stays frozen; see the file's #1640 S6/S7 section and the plan's "Critical
// constraints" clause). Mirrors `cmdResolveRoleModel`'s precedence STRUCTURALLY (SSOT-first; an explicit
// `CC_ROLES_ENV` override is authoritative+terminal so `routesLoaded` is pre-computed by the caller honoring
// that precedence) but returns a RICHER shape {tier, provider, model, viaSSOT} — S9/S10 need the declared
// PROVIDER to bind a run-time reroute stamp, not merely a tier token. Falls back to the frozen
// `roleModelFromCfg` (byte-unchanged legacy resolver) whenever the SSOT is not consulted, the role has no
// declared seat, or the seat's model is not in any provider's declared vocabulary (S8(b)'s inexpressible-value
// path) — this is what preserves `roleModelFromCfg`'s existing behavior for every pre-#1640 fixture.
function resolveExpectedSide(routesLoaded, cfg, role) {
  if (routesLoaded && routesLoaded.ok) {
    const seat = (routesLoaded.routes.seats || {})[role];
    if (seat) {
      const ident = identifyModel(routesLoaded.routes, seat.model);
      if (ident.ok && ident.tierEquivalent) {
        return { tier: ident.tierEquivalent, provider: ident.provider, model: seat.model, viaSSOT: true };
      }
    }
  }
  return { tier: roleModelFromCfg(cfg, role), provider: '', model: '', viaSSOT: false };
}

// Seat resolution: look up the seat row, then run BOTH resolve-time guards in order (C-2 then C-3) — both are
// enforced again at invoke-time in M2 with the resolver out of the loop; this is the resolve-time half only.
function resolveRoute(routes, seatKey) {
  const seats = (routes && routes.seats) || {};
  const seatRow = seats[seatKey];
  if (!seatRow) return { ok: false, reason: 'ROUTE-SEAT-NOT-FOUND: no seat "' + seatKey + '" in the SSOT' };
  const cap = checkCapability(routes, seatRow);
  if (!cap.ok) return { ok: false, reason: cap.reason };
  const sens = checkDataSensitivity(routes, seatRow);
  if (sens.ok) return { ok: true, seatKey, seat: seatRow, acceptance: null };
  // C-3 refused -- C-3W (#1880) gets exactly one more chance, never ahead of C-2, never widening C-3 itself.
  const acc = checkAcceptance(routes, seatRow);
  if (acc.ok) return { ok: true, seatKey, seat: seatRow, acceptance: acc.acceptance };
  return { ok: false, reason: sens.reason };
}

// resolve-route --seat <domain.seat> [--json]
function cmdResolveRoute(opts) {
  const seatKey = opts.seat;
  if (!seatKey) { console.log('BLOCK: resolve-route requires --seat <domain.seat>'); process.exit(2); }
  const loaded = loadRoutesConfig();
  if (!loaded.ok) { process.stderr.write(loaded.error + '\n'); process.exit(2); }
  const result = resolveRoute(loaded.routes, seatKey);
  if (!result.ok) { process.stderr.write(result.reason + '\n'); process.exit(2); }
  if (result.acceptance) {
    // #1880 intent 5 -- a route allowed only because of an acceptance must be observably different from one
    // that clears normally. Emitted on stderr at exit 0 (breaks no existing consumer -- stdout is unchanged
    // and the probe/CLI callers that discard stderr on success are unaffected).
    const a = result.acceptance;
    process.stderr.write(ROUTE_ACCEPTED_RISK_TOKEN + ': seat ' + seatKey + ' provider ' + a.provider +
      ' posture-at-decision ' + a.posture_at_decision + ' decided ' + a.decided + ' authority ' + a.authority + '\n');
  }
  if ('json' in opts) {
    const payload = Object.assign({ seat: seatKey }, result.seat);
    if (result.acceptance) payload.accepted_disclosure_applied = result.acceptance;
    console.log(JSON.stringify(payload));
  } else {
    console.log(seatKey + ' -> ' + result.seat.provider + ' / ' + (result.seat.model || ''));
  }
  process.exit(0);
}

// identify-model --id <model-id> [--json]
function cmdIdentifyModel(opts) {
  const modelId = opts.id;
  if (!modelId) { console.log('BLOCK: identify-model requires --id <model-id>'); process.exit(2); }
  const loaded = loadRoutesConfig();
  if (!loaded.ok) { process.stderr.write(loaded.error + '\n'); process.exit(2); }
  const result = identifyModel(loaded.routes, modelId);
  if (!result.ok) {
    process.stderr.write('ROUTE-MODEL-UNDECLARED: "' + modelId + '" is not in any provider\'s declared vocabulary\n');
    process.exit(2);
  }
  if ('json' in opts) {
    console.log(JSON.stringify({ id: modelId, provider: result.provider, tierEquivalent: result.tierEquivalent }));
  } else {
    console.log(result.provider + ' ' + result.tierEquivalent);
  }
  process.exit(0);
}

// lint-routes — credential-hygiene lint over the resolved routes file (AC0.6). Exit 0 clean; exit 2 + the
// offending key(s) on stderr otherwise.
function cmdLintRoutes(opts) {
  void opts;
  const loaded = loadRoutesConfig();
  if (!loaded.ok) { process.stderr.write(loaded.error + '\n'); process.exit(2); }
  const problems = lintRoutesConfig(loaded.routes);
  if (problems.length) {
    for (const p of problems) process.stderr.write(p + '\n');
    process.exit(2);
  }
  console.log('OK: routes lint clean (' + loaded.configPath + ')');
  process.exit(0);
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════
// #2105 — Mode switch SSOT: resolve-mode / set-mode. A tiny operator posture pin (~/.config/cc-mode.json,
// machine-local, never tracked/synced) governs TWO axes read from the tracked table below:
//   - lane_ceiling:        the hard cap a NEW lane-start may not exceed (hooks/mode-pin-lane-gate.sh).
//   - openrouter_dispatch: whether tools/openrouter-*-dispatch.sh may reach OpenRouter at all.
// Fail-safe direction (D1): EVERY failure shape (absent/unreadable/unparseable pin, unknown mode value,
// broken/absent tracked table) resolves to `normal` — the harm asymmetry is that an accidental non-Anthropic
// dispatch violates the operator's directive AND a data-posture boundary, while 3 lanes is the operator's own
// declared normal-mode default (#2216, 2026-08-01 — lowered from 4). Garbage state can never resolve to speed-boost and can never resolve to
// openrouter_dispatch=permitted.
// Fixture seams (mirrors CC_ROUTES_JSON): CC_MODE_FILE (the pin) and CC_MODE_POLICY_JSON (the tracked table).
// No smoke may ever omit both — the real ~/.config/cc-mode.json is NEVER read or written by any test arm.

const MODE_FALLBACK = Object.freeze({
  mode: 'normal',
  lane_ceiling: 3,
  openrouter_dispatch: 'forbidden',
});

function resolveModePolicyPath() {
  if ('CC_MODE_POLICY_JSON' in process.env) {
    const p = process.env.CC_MODE_POLICY_JSON;
    return (p && fileExists(p)) ? p : '';
  }
  let selfDir;
  try { selfDir = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url))); }
  catch (e) { selfDir = path.dirname(fileURLToPath(import.meta.url)); }
  const cand = path.join(selfDir, '..', 'config', 'cc-mode-policy.json');
  return fileExists(cand) ? cand : '';
}

// The pin lives OUTSIDE every repo (#1918's measured location argument — no git verb, no PR, Rule 12 can
// never fire, and every consumer below is a fresh process per event so an edit is live on the next spawn).
function resolveModePinPath() {
  if ('CC_MODE_FILE' in process.env) return process.env.CC_MODE_FILE;
  return path.join(HOME, '.config', 'cc-mode.json');
}

// Load + validate the tracked mode-policy table. Never throws: { ok, policy, error, path }. A missing file,
// an unreadable file, unparseable JSON, or a shape that lacks a resolvable default_mode/modes entry are all
// treated as "broken table" -> the caller falls back to MODE_FALLBACK in-code constants (AC 3(g)).
function loadModePolicy() {
  const p = resolveModePolicyPath();
  if (!p) return { ok: false, policy: null, error: 'MODE-POLICY-NOT-FOUND', path: '' };
  let raw;
  try { raw = fs.readFileSync(p, 'utf8'); }
  catch (e) { return { ok: false, policy: null, error: 'MODE-POLICY-READ-ERROR: ' + (e && e.message ? e.message : e), path: p }; }
  let policy;
  try { policy = JSON.parse(raw); }
  catch (e) { return { ok: false, policy: null, error: 'MODE-POLICY-PARSE-ERROR: ' + (e && e.message ? e.message : e), path: p }; }
  if (!policy || typeof policy !== 'object' || !policy.modes || typeof policy.modes !== 'object' ||
      !policy.default_mode || !policy.modes[policy.default_mode]) {
    return { ok: false, policy: null, error: 'MODE-POLICY-SHAPE-ERROR: missing modes/default_mode', path: p };
  }
  return { ok: true, policy, error: '', path: p };
}

// Resolve a mode-id string (possibly an alias, e.g. #2035's "token-conservative") against the loaded policy
// table. Returns '' if unresolvable (unknown mode, unknown alias).
function resolveModeAlias(policy, rawMode) {
  const m = String(rawMode == null ? '' : rawMode).trim();
  if (!m) return '';
  if (policy.modes[m]) return m;
  const aliases = (policy && policy.aliases && typeof policy.aliases === 'object') ? policy.aliases : {};
  const aliased = aliases[m];
  if (aliased && policy.modes[aliased]) return aliased;
  return '';
}

// The single choke point (D1). Never throws — every failure shape resolves to a SAFE mode, loudly labeled
// via `source`. Returns { mode, ceiling, openrouter_dispatch, source, reason, set_at, task }.
function resolveMode() {
  const loaded = loadModePolicy();
  if (!loaded.ok) {
    // AC 3(g) — a broken/absent TRACKED TABLE can neither brick the resolver nor widen anything: the
    // fallback constants (the directive's own numbers) live in code, never in a file a bad edit can corrupt.
    return { mode: MODE_FALLBACK.mode, ceiling: MODE_FALLBACK.lane_ceiling,
             openrouter_dispatch: MODE_FALLBACK.openrouter_dispatch, source: 'invalid-pin-fallback',
             reason: 'broken-mode-policy-table', set_at: '', task: '' };
  }
  const policy = loaded.policy;
  const pinPath = resolveModePinPath();
  let pinRaw;
  try { pinRaw = fs.readFileSync(pinPath, 'utf8'); }
  catch (e) {
    // Absent pin (ENOENT) is the NORMAL, expected steady state -> source=default. Any OTHER read error
    // (permission, a directory in its place, ...) is treated the same as unparseable -> invalid-pin-fallback,
    // never silently promoted to "default".
    const isAbsent = e && e.code === 'ENOENT';
    if (isAbsent) {
      const dm = policy.default_mode;
      const row = policy.modes[dm];
      return { mode: dm, ceiling: row.lane_ceiling, openrouter_dispatch: row.openrouter_dispatch,
               source: 'default', reason: '', set_at: '', task: '' };
    }
    return { mode: MODE_FALLBACK.mode, ceiling: MODE_FALLBACK.lane_ceiling,
             openrouter_dispatch: MODE_FALLBACK.openrouter_dispatch, source: 'invalid-pin-fallback',
             reason: 'unreadable-pin', set_at: '', task: '' };
  }
  let pin;
  try { pin = JSON.parse(pinRaw); }
  catch (e) {
    // AC 3(a)/(f) — unparseable JSON, INCLUDING a torn/truncated prefix an aborted flip can leave, resolves
    // to normal. No partial write can ever land in a permitting state.
    return { mode: MODE_FALLBACK.mode, ceiling: MODE_FALLBACK.lane_ceiling,
             openrouter_dispatch: MODE_FALLBACK.openrouter_dispatch, source: 'invalid-pin-fallback',
             reason: 'unparseable-pin', set_at: '', task: '' };
  }
  if (!pin || typeof pin !== 'object') {
    return { mode: MODE_FALLBACK.mode, ceiling: MODE_FALLBACK.lane_ceiling,
             openrouter_dispatch: MODE_FALLBACK.openrouter_dispatch, source: 'invalid-pin-fallback',
             reason: 'unparseable-pin', set_at: '', task: '' };
  }
  const resolved = resolveModeAlias(policy, pin.mode);
  if (!resolved) {
    // AC 3(b) — an unknown mode value in the pin resolves the same as unparseable.
    return { mode: MODE_FALLBACK.mode, ceiling: MODE_FALLBACK.lane_ceiling,
             openrouter_dispatch: MODE_FALLBACK.openrouter_dispatch, source: 'invalid-pin-fallback',
             reason: 'unknown-mode-value', set_at: '', task: '' };
  }
  const row = policy.modes[resolved];
  return { mode: resolved, ceiling: row.lane_ceiling, openrouter_dispatch: row.openrouter_dispatch,
           source: 'pin', reason: String(pin.reason == null ? '' : pin.reason),
           set_at: String(pin.set_at == null ? '' : pin.set_at), task: String(pin.task == null ? '' : pin.task) };
}

function cmdResolveMode(opts) {
  void opts;
  const r = resolveMode();
  console.log('mode=' + r.mode);
  console.log('ceiling=' + r.ceiling);
  console.log('openrouter_dispatch=' + r.openrouter_dispatch);
  console.log('source=' + r.source);
  console.log('reason=' + r.reason);
  // AC 20(b) (#2197) — `set_at=` is emitted ONLY on the source=pin arm, and only when the pin actually
  // carries a timestamp. This is the PAIRED ABSENCE contract both consumers already state in their own
  // comments (tools/openrouter-role-dispatch.sh:158-160 and tools/openrouter-research-dispatch.sh:565-568):
  // "a source=default refusal carries NEITHER field, never an empty placeholder". Before this line the
  // command emitted exactly five keys and NO set_at at all, so the consumers' `grep -m1 '^set_at='`
  // resolved to the empty string and every conservative-mode MODE line shipped a bare `set_at=` with no
  // value -- the provenance half of AC 20(b) was permanently unmet. resolveMode() has always COMPUTED
  // set_at correctly (:4099); only the print path dropped it.
  if (r.source === 'pin' && r.set_at) console.log('set_at=' + r.set_at);
  process.exit(0);
}

// Best-effort ambient invoking-identity resolution (D1, round 3 — attribution-BY-RECORD, never
// authentication): an explicit --session/--agent-id/--agent flag wins; else the harness's own ambient
// CLAUDE_CODE_SESSION_ID env var (set inside a live Claude Code Bash tool call — see
// hooks/openrouter-role-dispatch-smoke-test.sh:194-198 for the same convention); else the literal
// 'unknown' — NEVER an absent/omitted field.
function ambientIdentity(o) {
  const explicit = o.session || o['agent-id'] || o.agent;
  if (explicit) { const s = sanitize(explicit); if (s) return s; }
  const envSid = process.env.CLAUDE_CODE_SESSION_ID;
  if (envSid && String(envSid).trim()) { const s = sanitize(envSid); if (s) return s; }
  return 'unknown';
}

// set-mode --mode <m> [--reason <text>] [--task <id>] [--session <id>] — validates against the tracked
// table, refuses an unknown mode with the pin file BYTE-UNCHANGED (AC 3(c)), and writes ATOMICALLY
// (temp-file-plus-rename in the pin's OWN directory, AC 19) so the pin is, at every instant, either the
// prior valid state or the new valid state — never a torn intermediate. Every SUCCESSFUL flip appends one
// audit line to the unified override/audit log (never on a refusal, AC 20(a)).
function cmdSetMode(o) {
  const loaded = loadModePolicy();
  if (!loaded.ok) {
    console.log('BLOCK: set-mode: ' + loaded.error);
    process.exit(2);
  }
  const policy = loaded.policy;
  const requested = o.mode;
  const resolved = resolveModeAlias(policy, requested);
  if (!resolved) {
    console.log('BLOCK: set-mode: unknown mode "' + (requested || '') + '" — valid: ' +
      Object.keys(policy.modes).concat(Object.keys(policy.aliases || {})).join(', '));
    process.exit(2);
  }
  const pinPath = resolveModePinPath();
  // Read the PRIOR mode for the audit line's transition= field (best-effort; unresolvable -> 'unknown').
  let priorMode = 'unknown';
  try { priorMode = resolveMode().mode; } catch (e) { /* best-effort */ }

  const nowIso = new Date().toISOString();
  const pinObj = { mode: resolved, set_at: nowIso };
  if (o.reason) pinObj.reason = String(o.reason);
  if (o.task) pinObj.task = String(o.task);

  const dir = path.dirname(pinPath);
  try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* best-effort; write below surfaces a real error */ }
  const tmpPath = path.join(dir, '.cc-mode.json.tmp-' + process.pid + '-' + Date.now());
  try {
    fs.writeFileSync(tmpPath, JSON.stringify(pinObj, null, 2) + '\n');
    fs.renameSync(tmpPath, pinPath);
  } catch (e) {
    // AC 19 — a write-protected directory (temp-file create/rename needs dir-write perms) must fail
    // WITHOUT mutating the real pin. Clean up any partial temp file, never touch pinPath.
    try { fs.unlinkSync(tmpPath); } catch (e2) { /* best-effort */ }
    console.log('BLOCK: set-mode: could not write pin atomically: ' + (e && e.message ? e.message : e));
    process.exit(2);
  }

  // AC 20(a) — audit ONLY on success, into the SAME unified log as every other bypass/override record
  // (rule12LogPath(), the ledger's existing env override RULE12_LOG). Additive `kind: 'mode-flip'` record —
  // never replaces the base 8-key shape any other writer emits (mirrors #1640 S10's own additive keys).
  try {
    const record = {
      ts: nowIso,
      session: '',
      agent: '',
      task: sanitize(o.task || ''),
      role: 'orchestrator',
      hook: 'mode-flip',
      var: 'CC_MODE',
      decision: 'PERMIT',
      kind: 'mode-flip',
      transition: priorMode + '->' + resolved,
      reason: o.reason ? String(o.reason) : '',
      actor: ambientIdentity(o),
    };
    const logPath = rule12LogPath();
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, JSON.stringify(record) + '\n');
  } catch (e) { /* best-effort — audit failure must never un-do an already-committed pin write */ }

  console.log('OK: mode set to ' + resolved + ' (' + priorMode + ' -> ' + resolved + ')');
  process.exit(0);
}
// ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

const [, , cmd, ...rest] = process.argv;
const opts = parseArgs(rest);
try {
  if (cmd === 'append') cmdAppend(opts);
  else if (cmd === 'check') cmdCheck(opts);
  else if (cmd === 'heartbeat') cmdHeartbeat(opts);
  else if (cmd === 'refresh-models') cmdRefreshModels(opts);
  else if (cmd === 'reconcile-spawns') cmdReconcileSpawns(opts);
  else if (cmd === 'resolve-agent') cmdResolveAgent(opts);
  else if (cmd === 'resolve-artifact') cmdResolveArtifact(opts);
  else if (cmd === 'resolve-role-model') cmdResolveRoleModel(opts);
  else if (cmd === 'resolve-effective-tier') cmdResolveEffectiveTier(opts);
  else if (cmd === 'inherit-plan-review') cmdInherit(opts);
  else if (cmd === 'gate-plan-review') cmdGatePlanReview(opts);
  else if (cmd === 'log-bypass') cmdLogBypass(opts);
  else if (cmd === 'resolve-route') cmdResolveRoute(opts);
  else if (cmd === 'identify-model') cmdIdentifyModel(opts);
  else if (cmd === 'lint-routes') cmdLintRoutes(opts);
  else if (cmd === 'provenance-kind') cmdProvenanceKind(opts);
  else if (cmd === 'resolve-mode') cmdResolveMode(opts);
  else if (cmd === 'set-mode') cmdSetMode(opts);
  else {
    console.log('usage: 3role-ledger.mjs <append|check|heartbeat|refresh-models|reconcile-spawns|resolve-agent|resolve-artifact|resolve-role-model|resolve-effective-tier|inherit-plan-review|gate-plan-review|log-bypass|resolve-route|identify-model|lint-routes|provenance-kind|resolve-mode|set-mode> ' +
      '--session S --task T [--role R --agent A --artifact P --skip-reason "..." --oracle P] [--parent P (inherit-plan-review)] ' +
      '[--session S (refresh-models)] [--session S (reconcile-spawns, #1229)] [--role R [--with-effort] (resolve-role-model)] [--enforce-role-models (check)] ' +
      '[--enforce-tracked-artifacts [--perf-log P] (check, #1509 + #1544)] ' +
      '[--enforce-artifact-role-kind (check, #1532)] ' +
      '[--enforce-artifact-privacy [--perf-log P] (check, #1537)] ' +
      '[--model M --subagent-type T --transcript P [--agents-dir D] [--projects-root R] (resolve-effective-tier)] ' +
      '[--session S --task T (gate-plan-review, #1575)] ' +
      '[--hook H --var V --decision PERMIT|DENY [--session S --agent-id A --agent-type T] (log-bypass, #1543)] ' +
      '[--seat S [--json] (resolve-route, #1640 M0)] [--id ID [--json] (identify-model, #1640 M0)] [(lint-routes, #1640 M0)] ' +
      '[--session S --task T --role R (provenance-kind, #2075 AC-1) — prints E1|E2|E3|none[ legacy]] ' +
      '[(resolve-mode, #2105) — prints mode= ceiling= openrouter_dispatch= source= reason=] ' +
      '[--mode M [--reason "..."] [--task T] [--session S] (set-mode, #2105)]');
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
