#!/usr/bin/env bash
# Behavioral tests for `grandma doctor`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
FB="$(make_fake_claude "$TMP/bin")"

section "doctor — healthy (all deps present via fake claude)"
capture env PATH="$FB:$PATH" "$GBIN" doctor
assert_rc 0 "doctor exits 0 when healthy"
assert_contains "doctor: healthy" "reports healthy"

section "doctor — missing claude (scrubbed PATH excludes claude)"
# /usr/bin:/bin has git/python3 (and jq on CI) but never claude, so this is deterministic
# regardless of whether the dev machine has claude installed.
capture env PATH="/usr/bin:/bin" "$GBIN" doctor
assert_rc 1 "doctor exits 1 when a required dep is missing"
assert_contains "claude CLI not found" "names the missing claude CLI"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_doctor: PASS"; else echo "cmd_doctor: $FAILS FAILURE(S)"; exit 1; fi
