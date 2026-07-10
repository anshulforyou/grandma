#!/usr/bin/env bash
# Cold-install smoke test: fresh home -> init -> scope -> assemble -> launch dry-run -> suite.
# No claude CLI required (dry-runs only) so it runs in CI.
set -euo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRANDMA_HOME="$(mktemp -d)/home"; export GRANDMA_HOME
export SHELL=""   # never touch a real shell rc during tests

"$ENGINE/bin/grandma" init </dev/null >/dev/null
[[ -f "$GRANDMA_HOME/global/identity.md" ]] || { echo "init did not seed identity"; exit 1; }
[[ -d "$GRANDMA_HOME/.git" ]] || { echo "init did not git-init the home"; exit 1; }

mkdir -p "$GRANDMA_HOME/demo"
printf -- '---\nscope: demo\ntype: facts\nupdated: 2026-01-01\n---\n\n# Demo facts\n- the demo fact\n' \
  > "$GRANDMA_HOME/demo/facts.md"

out="$("$ENGINE/lib/assemble.sh" demo 2>/dev/null)"
echo "$out" | grep -q 'demo/facts.md'      || { echo "assemble missing scope file"; exit 1; }
echo "$out" | grep -q 'global/identity.md' || { echo "assemble missing global"; exit 1; }
echo "$out" | grep -q 'the demo fact'      || { echo "assemble missing content"; exit 1; }

launch_out="$(GRANDMA_DRY_RUN=1 "$ENGINE/bin/grandma" demo 2>&1 || true)"
echo "$launch_out" | grep -q 'banner:' || { echo "launch dry-run failed: $launch_out"; exit 1; }
"$ENGINE/bin/grandma" test >/dev/null || { echo "suite failed against fresh home"; exit 1; }

rm -rf "$(dirname "$GRANDMA_HOME")"
echo "smoke: PASS"
