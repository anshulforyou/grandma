#!/usr/bin/env bash
# test/run.sh — run the whole grandma test suite: the structural invariants, the cold-install
# smoke, the onboarding e2e, and every per-command behavioral test (test/cmd_*.sh).
# Each child is self-contained and exits non-zero on failure; we aggregate and mirror that.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"

FAILED=()
run_one() { # <label> <cmd...>
  local label="$1"; shift
  printf '\n\033[1m### %s\033[0m\n' "$label"
  if "$@"; then :; else FAILED+=("$label"); fi
}

# Structural invariants (no home) + cold install + onboarding e2e.
run_one "integrity suite (no home)" "$ENGINE/bin/grandma" test
run_one "cold-install smoke"        "$HERE/smoke.sh"
run_one "onboarding e2e"            "$HERE/onboard.sh"

# Per-command behavioral tests.
for t in "$HERE"/cmd_*.sh; do
  [ -f "$t" ] || continue
  run_one "$(basename "$t")" bash "$t"
done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "run.sh: ALL SUITES PASS"
else
  printf 'run.sh: %d SUITE(S) FAILED: %s\n' "${#FAILED[@]}" "${FAILED[*]}"
  exit 1
fi
