#!/usr/bin/env bash
# Behavioral tests for lib/assemble.sh — the bundle builder.
# Also documents that assemble is kebab-correct, isolating the review `cut -d-` defect.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

ASM="$ENGINE/lib/assemble.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

section "assemble — isolation (bundle = global + one scope only)"
capture env "$ASM" globex
assert_rc 0 "assemble globex runs"
assert_contains "globex/facts.md" "includes the scope's facts"
assert_contains "global/identity.md" "includes global identity"
assert_not_contains "home-ops/" "does NOT leak the other sweater"

section "assemble — --full adds on-demand tiers"
capture env "$ASM" globex --full
assert_rc 0 "assemble globex --full runs"
assert_contains "globex/decisions.md" "--full adds decisions"
assert_contains "global/style.md" "--full adds global style"

section "assemble — kebab scope resolves by whole name (review's bug is NOT here)"
capture env "$ASM" home-ops
assert_rc 0 "assemble home-ops (kebab) resolves"
assert_contains "home-ops/facts.md" "loads the kebab scope's memory"
capture env "$ASM" home
assert_rc 1 "assemble home (a '-' truncation) correctly fails"
assert_contains "no scope matching" "reports the unknown scope"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_assemble: PASS"; else echo "cmd_assemble: $FAILS FAILURE(S)"; exit 1; fi
