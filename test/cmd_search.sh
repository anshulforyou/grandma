#!/usr/bin/env bash
# Behavioral tests for `grandma search` — read-only grep across memory.
#
# Bites this pins down:
#   - the KEBAB sweater (home-ops) must resolve whole, not truncate to "home" (the bug class
#     that already shipped twice here, in review's `cut -d-` and in completions).
#   - a ONE-word search is always a query, never a sweater, or `grandma search <sweater>`
#     would silently search that sweater for nothing.
#   - proposals/ are NOT memory yet, so they must stay out of results.
#   - rg and grep must agree: the same query is run under both engines below.
#   - no-match is exit 1 (grep's convention), usage error is exit 2.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

# Which engines can we exercise on this machine? grep always; rg only when installed.
ENGINES="grep"
command -v rg >/dev/null 2>&1 && ENGINES="grep rg"

for eng in $ENGINES; do
  export GRANDMA_SEARCH_TOOL="$eng"

  section "search [$eng] — wide search covers global and every sweater"
  capture env "$GBIN" search pnpm
  assert_rc 0 "one-word search runs under set -u and finds a match"
  assert_contains "global/preferences.md" "reaches global memory"
  capture env "$GBIN" search facts
  assert_rc 0 "a term in two sweaters searches both"
  assert_contains "globex/facts.md" "finds the plain sweater"
  assert_contains "home-ops/facts.md" "finds the kebab sweater"

  section "search [$eng] — output is file:line:text, like grep"
  capture env "$GBIN" search atlas
  assert_rc 0 "finds a sweater fact"
  case "$LAST_OUT" in
    *"globex/facts.md:"[0-9]*":"*) ok "prints <file>:<line>:<text> with a path relative to the home" ;;
    *) fail "expected file:line:text output" "$LAST_OUT" ;;
  esac
  assert_contains "match(es) in" "prints a summary count"

  section "search [$eng] — scoped to one sweater"
  capture env "$GBIN" search home-ops facts
  assert_rc 0 "scoped search resolves the KEBAB sweater whole (not truncated to 'home')"
  assert_contains "home-ops/facts.md" "returns the named sweater's hit"
  assert_not_contains "globex/facts.md" "does not leak the other sweater"
  capture env "$GBIN" search home-ops trash
  assert_rc 0 "scoped search finds a fact unique to that sweater"

  section "search [$eng] — scoped means that sweater ALONE, not global"
  capture env "$GBIN" search globex pnpm
  assert_rc 1 "a global-only term is absent from a scoped search"

  section "search [$eng] — a one-word search is a query, never a sweater"
  capture env "$GBIN" search globex
  assert_rc 0 "bare sweater name searches FOR the word instead of scoping to it"
  assert_contains "globex/facts.md" "matches the word where it appears in memory"

  section "search [$eng] — --all forces the wide read"
  # Without --all this scopes to home-ops and matches the log; with it, the literal
  # string "home-ops planted" is searched, which appears nowhere.
  capture env "$GBIN" search home-ops planted
  assert_rc 0 "without --all, a leading sweater name scopes the search"
  capture env "$GBIN" search --all home-ops planted
  assert_rc 1 "with --all, the sweater name is part of the query instead"

  section "search [$eng] — matching is literal, case-insensitive, multi-word"
  capture env "$GBIN" search PNPM
  assert_rc 0 "case-insensitive"
  capture env "$GBIN" search never yarn
  assert_rc 0 "multiple words join into one literal phrase"
  assert_contains "global/preferences.md" "finds the phrase"
  capture env "$GBIN" search "yarn never"
  assert_rc 1 "the phrase is literal, not a set of words in any order"

  section "search [$eng] — proposals are not memory yet, so they stay out"
  assert_file "$GRANDMA_HOME/proposals/home-ops-20260601T101010.md" "fixture has a proposal to exclude"
  capture env "$GBIN" search recycling
  assert_rc 1 "a term that exists ONLY in proposals/ does not match"

  section "search [$eng] — no match and bad usage are graceful"
  capture env "$GBIN" search definitely-not-in-any-memory
  assert_rc 1 "no match exits 1, grep's convention"
  assert_contains "no memory matches" "says so plainly"
  capture env "$GBIN" search definitely-not-a-scope facts
  assert_rc 1 "an unknown leading word is treated as query text, not a sweater"
  capture env "$GBIN" search
  assert_rc 2 "bare 'search' prints usage and exits 2"
  assert_contains "usage: grandma search" "prints usage"
  capture env "$GBIN" search --nope pnpm
  assert_rc 2 "an unknown flag exits 2"
done
unset GRANDMA_SEARCH_TOOL

section "search — rg and grep return the same matches"
if command -v rg >/dev/null 2>&1; then
  g="$(env GRANDMA_SEARCH_TOOL=grep "$GBIN" search facts 2>/dev/null | sort)"
  r="$(env GRANDMA_SEARCH_TOOL=rg   "$GBIN" search facts 2>/dev/null | sort)"
  [ "$g" = "$r" ] && ok "both engines agree on the same query" \
    || fail "engine outputs differ" "grep:
$g
rg:
$r"
else
  skip "ripgrep not installed — grep path covered above"
fi

section "search — degrades and refuses cleanly"
capture env GRANDMA_SEARCH_TOOL=ack "$GBIN" search pnpm
assert_rc 2 "an unknown GRANDMA_SEARCH_TOOL is refused, not silently ignored"
assert_contains "unknown GRANDMA_SEARCH_TOOL" "names the bad value"
# Asking for rg on a box without it must fall back to grep, not die. /usr/bin:/bin has the
# coreutils this command needs and (on any normal machine) no rg.
capture env PATH=/usr/bin:/bin GRANDMA_SEARCH_TOOL=rg "$GBIN" search pnpm
assert_rc 0 "GRANDMA_SEARCH_TOOL=rg with no rg on PATH degrades to grep"
assert_contains "global/preferences.md" "and still returns the match"
capture env "$GBIN" search --help
assert_rc 0 "--help exits 0"
assert_contains "usage: grandma search" "and prints the usage"

section "search — an empty or missing memory home says so, and does not crash"
capture env GRANDMA_HOME="$TMP/does-not-exist" "$GBIN" search pnpm
assert_rc 1 "a missing memory home is 'nothing found', not a crash"
assert_contains "no memory to search" "explains what to do about it"
mkdir -p "$TMP/bare"
capture env GRANDMA_HOME="$TMP/bare" "$GBIN" search pnpm
assert_rc 1 "a home with no global/ and no sweaters is the same"

section "search — wired into the CLI surface"
capture env "$GBIN" help
assert_rc 0 "help runs"
assert_contains "grandma search" "help lists the search subcommand"
assert_contains "grandma completions" "help block range still reaches the last usage line"
capture env "$GBIN" completions __scopes
assert_contains "search" "tab-completion offers search as a first word"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_search: PASS"; else echo "cmd_search: $FAILS FAILURE(S)"; exit 1; fi
