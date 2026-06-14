#!/usr/bin/env bash
# bash -n (syntax check) every hook in hooks/. Exit non-zero on the first failure.
# Defensive: no hooks yet (bootstrap) -> PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
found=0
while IFS= read -r f; do
  found=1
  bash -n "$f" && echo "bash -n OK: $f"
done < <(find "$ROOT/hooks" -name '*.sh' 2>/dev/null)
if [ "$found" = "0" ]; then echo "no hooks yet (bootstrap) — nothing to lint"; fi
