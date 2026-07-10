#!/usr/bin/env bash
# Behavioral tests for `grandma <sweater>` launch — via GRANDMA_DRY_RUN=1 (no claude needed).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL="" GRANDMA_NO_SPLASH=1

make_fixture_home "$GRANDMA_HOME"

section "launch — dry-run, scope only"
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 0 "grandma globex (dry-run) runs"
assert_contains "banner:" "prints the launch banner"
assert_contains "memory: globex loaded" "banner names the loaded scope"

section "launch — dry-run, known project (fuzzy match)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex billing
assert_rc 0 "grandma globex billing runs"
assert_contains "KNOWN project 'Billing API'" "fuzzy-resolves 'billing' to the registered project"

section "launch — dry-run, kebab scope + known project"
capture env GRANDMA_DRY_RUN=1 "$GBIN" home-ops yard
assert_rc 0 "grandma home-ops yard (kebab scope) runs"
assert_contains "memory: home-ops loaded" "kebab scope memory loads correctly"
assert_contains "KNOWN project 'Yard'" "resolves the kebab scope's project"

section "launch — dry-run, unknown project -> onboard"
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex nope-not-real
assert_rc 0 "grandma globex <unknown> runs"
assert_contains "ONBOARD (project 'nope-not-real' unknown in globex)" "routes unknown project to onboard"

section "launch — no scope, non-tty stdin -> usage (not a hang)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" </dev/null
assert_rc 2 "bare grandma on a pipe exits with usage"
assert_contains "usage:" "prints usage instead of blocking on a picker"

section "launch — interactive picker in a pty (macOS/skip-if-no-pty)"
SHIM_PTY="$(make_fake_claude "$TMP/bin2")"; export SHIM_PTY GBIN_PTY="$GBIN" H="$GRANDMA_HOME"
# feed 'q' to quit the picker; we only assert it does not hang.
printf 'q\n' | run_in_pty 'GRANDMA_HOME="$H" GRANDMA_NO_SPLASH=1 PATH="$SHIM_PTY:$PATH" "$GBIN_PTY" >/dev/null 2>&1'
prc=$?
if [ "$prc" -eq 2 ]; then skip "no usable pty tool — interactive picker not exercised"
elif [ "$prc" -eq 142 ]; then fail "picker hung under a pty"
else ok "interactive picker runs and quits without hanging (rc=$prc)"; fi

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_launch: PASS"; else echo "cmd_launch: $FAILS FAILURE(S)"; exit 1; fi
