## Summary

<!-- What does this PR change, and why? One or two sentences. -->

## Build leg

<!-- Which build leg of the plugin does this advance? e.g. "Leg 2 — port + re-path hooks". -->

## Test plan

- [ ] `node scripts/ci-validate.mjs` passes (manifests + bin syntax + bundled tests)
- [ ] `bash -n` clean on any changed hook
- [ ] Any ported smoke test (`hooks/_smoke/*.sh`) passes with `CLAUDE_PLUGIN_ROOT` set to the repo root
- [ ] Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:` …)
- [ ] No absolute home paths, no `~/.claude/...` hardcodes left in ported files (use `${CLAUDE_PLUGIN_ROOT}`)

## Notes

<!-- Follow-ups, deferred work, portability caveats. -->
