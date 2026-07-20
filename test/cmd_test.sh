#!/usr/bin/env bash
# Behavioral test for `grandma test` (the integrity invariants).
#
# Bite: a pending proposal must NOT be treated as a memory scope. A distilled proposal carries
# `scope:` frontmatter, and list_scopes used to enumerate proposals/ as a sweater the moment one
# existed. That tripped the core-purity check (check 2) against every core file that legitimately
# references the proposals/ folder, so the pre-commit hook blocked any memory commit while an
# unreviewed proposal sat on disk. Fails before the list_scopes fix, passes after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

section "test — a valid home passes the invariants (survives set -u)"
capture env "$GBIN" test
assert_rc 0 "grandma test is green on a valid home, no unbound variable"

section "test — a pending proposal is NOT treated as a memory scope"
# A real distiller proposal carries scope: frontmatter (the fixture's uses an old comment header,
# which never triggered this). Before the fix, this alone turns grandma test red.
printf -- '---\nscope: home-ops\n---\n- a drafted fact awaiting review\n' \
  > "$GRANDMA_HOME/proposals/real-20260101T000000.md"
capture env "$GBIN" test
assert_rc 0 "still green with a pending proposal on disk"
assert_not_contains "scope name 'proposals'" "proposals/ is not flagged by the core-purity check"
assert_not_contains "scope 'proposals'" "proposals/ is not treated as a scope in isolation"

section "test — list_scopes excludes every gitignored scratch dir, even with scope: frontmatter"
U="$TMP/u"; mkdir -p "$U/global" "$U/home-ops" "$U/proposals" "$U/watches" "$U/.distill"
printf -- '---\nscope: home-ops\n---\n- x\n' > "$U/home-ops/facts.md"
for d in proposals watches .distill; do printf -- '---\nscope: home-ops\n---\n- y\n' > "$U/$d/n.md"; done
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(GRANDMA_HOME="$U" bash -c '. "'"$ENGINE"'/lib/grandma-lib.sh"; ROOT="'"$U"'"; list_scopes' | sort | tr '\n' ' ')"
assert_contains "home-ops" "the real kebab sweater is listed"
assert_not_contains "proposals" "proposals/ is excluded"
assert_not_contains "watches" "watches/ is excluded"
assert_not_contains "distill" ".distill/ is excluded"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_test: PASS"; else echo "cmd_test: $FAILS FAILURE(S)"; exit 1; fi
