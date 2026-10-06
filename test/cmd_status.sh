#!/usr/bin/env bash
# Behavioral tests for `grandma status` — the counts must be right against the fixture,
# and the kebab sweater is the one that matters: a proposal for home-ops is named
# home-ops-<stamp>.md, so anything that splits the filename on `-` counts it under a
# sweater called "home" that does not exist.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

section "status — lists every sweater with its counts"
capture env "$GBIN" status
assert_rc 0 "status runs"
assert_contains "globex" "names the plain sweater"
assert_contains "home-ops" "names the kebab sweater"
assert_contains "1 project" "counts registered projects from the registry"
assert_contains "1 pending proposal" "counts the kebab sweater's pending proposal"
assert_not_contains "unbound variable" "survives set -u"

section "status — a proposal belongs to the sweater its header names, not a prefix"
# home-ops-<stamp>.md must never be counted under a sweater called "home", and globex
# owns no proposals at all, so its line must carry no pending count.
capture env "$GBIN" status
LAST_OUT="$(printf '%s\n' "$LAST_OUT" | grep globex)"
assert_not_contains "pending" "the kebab sweater's proposal is not attributed to globex"
LAST_OUT="$(env "$GBIN" status 2>&1)"
assert_not_contains "  home  " "no phantom sweater is invented from the filename prefix"

section "status — reports unsaved memory"
printf '\n- edited\n' >> "$GRANDMA_HOME/globex/facts.md"
capture env "$GBIN" status
assert_rc 0 "status still runs with a dirty home"
assert_contains "unsaved changes" "says memory has unsaved work"

section "status — counts only watch reports without a .seen sibling"
mkdir -p "$GRANDMA_HOME/watches/unread-one" "$GRANDMA_HOME/watches/read-one"
printf '# report\n' > "$GRANDMA_HOME/watches/unread-one/report.md"
printf '# report\n' > "$GRANDMA_HOME/watches/read-one/report.md"
touch "$GRANDMA_HOME/watches/read-one/.seen"
capture env "$GBIN" status
assert_contains "1 unread report" "a report with a .seen sibling is already read"

section "status — an empty home says so instead of printing nothing"
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
capture env GRANDMA_HOME="$EMPTY" "$GBIN" status
assert_rc 0 "an empty home is not an error"
assert_contains "no sweaters yet" "and says what to do about it"
assert_contains "not under git" "and does not claim memory is saved when there is no repo"

section "status — a missing home is an error, not an empty screen"
capture env GRANDMA_HOME="$TMP/nope" "$GBIN" status
assert_rc 1 "a home that does not exist exits non-zero"
assert_contains "grandma init" "and points at init"

if [ "$FAILS" -eq 0 ]; then echo "cmd_status: PASS"; else echo "cmd_status: $FAILS FAILURE(S)"; exit 1; fi
