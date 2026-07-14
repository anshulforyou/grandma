#!/usr/bin/env bash
# Behavioral tests for `grandma review`.
#
# Catches BUG #2: review.sh:52 referenced undefined $local_scope → the --apply dry-run
#   crashed under set -u.
# Catches BUG #3: review.sh:40 did `cut -d- -f1`, so a proposal for the kebab scope
#   `home-ops` resolved to scope `home` and loaded the wrong (nonexistent) memory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
PROP="$GRANDMA_HOME/proposals/home-ops-20260601T101010.md"

section "review — list"
capture env "$GBIN" review
assert_rc 0 "review (list) runs"
assert_contains "pending memory proposals: 1" "lists the one pending proposal"
assert_contains "home-ops-20260601T101010.md" "shows the proposal path"

section "review — filtered list by kebab scope"
capture env "$GBIN" review home-ops
assert_rc 0 "review home-ops runs"
assert_contains "home-ops-20260601T101010.md" "kebab filter matches the proposal"

section "review --apply dry-run (guards BUG #2 crash and BUG #3 wrong-scope)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply "$PROP"
assert_rc 0 "review --apply dry-run runs under set -u (BUG #2: was \$local_scope unbound)"
# BUG #3: cut -d- -f1 yields 'home'; the correct scope is the whole 'home-ops'.
assert_contains "scope=home-ops" "resolves the FULL kebab scope, not a '-' truncation (BUG #3)"
assert_not_contains "scope=home)" "does not truncate home-ops to home (BUG #3)"

section "review --apply <scope> dry-run (apply ALL of a scope's pending proposals in one session)"
# Launch execs this when you accept the review-before-we-start offer. A second proposal proves
# it gathers every pending file for the scope, not just one.
PROP2="$GRANDMA_HOME/proposals/home-ops-20260601T202020.md"
cp "$PROP" "$PROP2"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply home-ops
assert_rc 0 "review --apply <scope> dry-run runs under set -u"
assert_contains "scope=home-ops" "resolves the FULL kebab scope for the scope-level apply"
assert_contains "home-ops-20260601T101010.md" "gathers the first pending proposal"
assert_contains "home-ops-20260601T202020.md" "gathers the second pending proposal (all, not one)"
rm -f "$PROP2"

section "review --apply <unknown> is a clean error, not a set -u crash"
capture env GRANDMA_DRY_RUN=1 "$GBIN" review --apply not-a-scope-or-file
assert_rc 1 "review --apply <bogus> exits 1"
assert_contains "no proposal to apply" "reports nothing to apply for an unknown arg"

section "review --clear (destructive; fixture is per-test)"
capture env "$GBIN" review --clear home-ops
assert_rc 0 "review --clear home-ops runs"
assert_contains "cleared 1 proposal(s)" "clears the matching proposal"
assert_no_file "$PROP" "proposal file is gone"
capture env "$GBIN" review --clear
assert_rc 0 "review --clear on empty runs"
assert_contains "no proposals to clear" "reports nothing to clear"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_review: PASS"; else echo "cmd_review: $FAILS FAILURE(S)"; exit 1; fi
