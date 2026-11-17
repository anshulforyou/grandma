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

section "test — core purity does not trip on the example names the docs hand people (#35)"
# These used to appear as examples in user-facing core strings, so a sweater with the very name
# the README suggested failed check 2 forever. home matched $HOME and GRANDMA_HOME everywhere.
for name in job-search reddit acme; do
  _fx_md "$GRANDMA_HOME/$name/facts.md" "$name" facts "# $name facts"
done
capture env "$GBIN" test
assert_not_contains "scope name 'job-search'" "job-search is not in any core file"
assert_not_contains "scope name 'reddit'" "reddit is not in any core file"
assert_not_contains "scope name 'acme'" "acme is not in any core file"
rm -rf "${GRANDMA_HOME:?}/job-search" "${GRANDMA_HOME:?}/reddit" "${GRANDMA_HOME:?}/acme"

_fx_md "$GRANDMA_HOME/home/facts.md" home facts "# home facts"
capture env "$GBIN" test
assert_not_contains "grandma-update.sh' hardcodes scope name 'home'" "an uppercase \$HOME is not a scope literal"

section "test — purity-allow.txt accepts an ordinary-word sweater, and only that one"
# `work` is everywhere in prompt prose, so it fails check 2 until the user accepts it.
_fx_md "$GRANDMA_HOME/work/facts.md" work facts "# work facts"
capture env "$GBIN" test
assert_rc 1 "an ordinary-word sweater fails check 2 by default"
assert_contains "add 'work' to" "and the failure says how to accept it"
printf 'work\n' > "$GRANDMA_HOME/purity-allow.txt"
capture env "$GBIN" test
assert_not_contains "scope name 'work'" "an allowed name is no longer flagged"
assert_contains "scope name 'home'" "a name that is not allowed still is"
printf 'work\nhome\n' > "$GRANDMA_HOME/purity-allow.txt"
capture env "$GBIN" test
assert_rc 0 "green once both are accepted"
rm -rf "${GRANDMA_HOME:?}/work" "${GRANDMA_HOME:?}/home" "$GRANDMA_HOME/purity-allow.txt"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_test: PASS"; else echo "cmd_test: $FAILS FAILURE(S)"; exit 1; fi
