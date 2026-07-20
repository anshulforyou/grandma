#!/usr/bin/env bash
# Behavioral tests for `grandma update` / `grandma version` and the stale-engine launch nudge.
#
# What this pins:
#   - version prints the VERSION file (plus the commit).
#   - update honors GRANDMA_DRY_RUN: it prints a plan and pulls NOTHING (tests never touch a network).
#   - a non-git engine copy fails cleanly (exit 1), not a crash.
#   - the launch nudge is staleness-only (no network): it fires past the threshold, stays quiet when
#     fresh, respects GRANDMA_NO_UPDATE_CHECK=1, and nudges at most once a day.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H"
export GRANDMA_HOME="$H"; export SHELL=""

section "version — prints the running engine version"
capture env "$GBIN" version
assert_rc 0 "grandma version runs"
assert_contains "grandma" "labels the output"
assert_contains "$(head -n1 "$ENGINE/VERSION")" "shows the VERSION file's number"
capture env "$GBIN" --version
assert_rc 0 "--version is the same path"

section "update — GRANDMA_DRY_RUN plans, pulls nothing, touches no network"
capture env GRANDMA_DRY_RUN=1 "$GBIN" update
assert_rc 0 "dry-run update runs and survives set -u"
assert_contains "would run" "prints the plan instead of pulling"
assert_contains "pull --ff-only" "names the fast-forward pull it would do"

section "update — a non-git engine copy fails cleanly, does not crash"
BARE="$TMP/bare-engine"; mkdir -p "$BARE"
cp -R "$ENGINE/bin" "$ENGINE/lib" "$BARE/"
[ -f "$ENGINE/VERSION" ] && cp "$ENGINE/VERSION" "$BARE/"
capture env GRANDMA_HOME="$H" "$BARE/bin/grandma" update
assert_rc 1 "update on a non-git engine exits 1"
assert_contains "not a git checkout" "explains why (and points at reinstall)"

# ---- the launch nudge: a unit test of grandma_update_notice. No launch, no network. ----
now="$(date +%s)"
notice() {  # runs grandma_update_notice against ROOT=$H, under set -u like the real launcher
  env GRANDMA_HOME="$H" bash -c \
    'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$H"'"; grandma_update_notice' 2>&1
}

section "nudge — fires when the engine is stale"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 10*86400))" > "$H/.update-state"
capture notice
assert_contains "grandma engine is" "a >1-week-old engine gets a nudge"
assert_contains "grandma update" "and it names the fix"

section "nudge — quiet when the engine is fresh"
rm -f "$H/.update-nudged"; printf '%s' "$now" > "$H/.update-state"
capture notice
assert_not_contains "grandma engine is" "a just-updated engine does not nudge"

section "nudge — GRANDMA_NO_UPDATE_CHECK=1 silences it even when stale"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 30*86400))" > "$H/.update-state"
GRANDMA_NO_UPDATE_CHECK=1 capture notice
assert_not_contains "grandma engine is" "opt-out wins over staleness"

section "nudge — at most once a day"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 10*86400))" > "$H/.update-state"
capture notice; assert_contains "grandma engine is" "first launch of the day nudges"
capture notice; assert_not_contains "grandma engine is" "a second launch the same day stays quiet"

section "update — a missing memory home stamps quietly, no redirect-error leak"
capture env GRANDMA_HOME="$TMP/no-such-home" bash -c \
  'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$TMP"'/no-such-home"; note_engine_updated'
assert_rc 0 "note_engine_updated survives a missing home (no unbound var)"
assert_not_contains "No such file" "no redirect error leaks out"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_update: PASS"; else echo "cmd_update: $FAILS FAILURE(S)"; exit 1; fi
