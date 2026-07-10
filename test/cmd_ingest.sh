#!/usr/bin/env bash
# Behavioral tests for `grandma ingest`.
#
# Catches BUG #1: grandma-ingest.sh referenced undefined $ENGINE/$GRANDMA_ROOT, so under
# `set -u` the whole command crashed on every invocation. The "runs under set -u without an
# unbound variable" assertion below is the entire guard — the command was dead on arrival.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

# A scan root with two subfolders, each holding a CLAUDE.md, for ingest to find.
SCAN="$TMP/scan"; mkdir -p "$SCAN/svc-a/nested" "$SCAN/svc-b"
printf '# svc-a\n' > "$SCAN/svc-a/nested/CLAUDE.md"
printf '# svc-b\n' > "$SCAN/svc-b/CLAUDE.md"
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"

section "ingest — dry-run (guards BUG #1: the whole command crashed under set -u)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" ingest globex --root "$SCAN"
assert_rc 0 "ingest globex --root <scan> runs under set -u (no unbound variable)"
assert_contains "found 2 project CLAUDE.md files" "finds both CLAUDE.md files"
assert_contains "scope:       globex" "targets the requested scope"

section "ingest — kebab-case scope resolves by whole name (contrast with review's cut bug)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" ingest home-ops --root "$SCAN"
assert_rc 0 "ingest home-ops runs"
assert_contains "(new=0)" "existing kebab scope is recognized, not treated as new"
assert_contains "/home-ops" "scope dir is the full kebab name, not a truncation"

section "ingest — new scope"
capture env GRANDMA_DRY_RUN=1 "$GBIN" ingest brand-new --root "$SCAN"
assert_rc 0 "ingest brand-new runs"
assert_contains "(new=1)" "unknown scope is flagged new"

section "ingest — empty scan root"
capture env GRANDMA_DRY_RUN=1 "$GBIN" ingest globex --root "$EMPTY"
assert_rc 0 "empty scan exits cleanly"
assert_contains "nothing to ingest" "reports nothing to ingest"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_ingest: PASS"; else echo "cmd_ingest: $FAILS FAILURE(S)"; exit 1; fi
