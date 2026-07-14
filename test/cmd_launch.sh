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

section "launch — end-of-session review prompt in a pty (macOS/skip-if-no-pty)"
# Make the memory home dirty so post_session has something to surface deterministically
# (no transcript needed). Then run the wrapped launch in a pty; the fake claude exits at
# once, post_session sees the uncommitted diff and offers a review; we answer 'n'.
printf -- '- extra note added mid-session\n' >> "$GRANDMA_HOME/globex/facts.md"
SHIM_L="$(make_fake_claude "$TMP/bin3")"; export SHIM_L GBIN_L="$GBIN" H_L="$GRANDMA_HOME"
# Assert only on output printed BEFORE the read prompt — pty input timing across the
# claude-exit boundary is not reliable enough to pin which answer branch runs.
out="$(printf 'n\n' | run_in_pty 'GRANDMA_HOME="$H_L" GRANDMA_NO_SPLASH=1 HOME="'"$TMP"'/fh" PATH="$SHIM_L:$PATH" "$GBIN_L" globex 2>&1')"
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool — end-of-session review not exercised"
else
  # shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
  LAST_OUT="$out"
  assert_contains "grandma is looking over the session" "post_session runs after the wrapped session"
  assert_contains "grandma noted something" "detects the session's memory changes"
  assert_contains "review now?" "offers an immediate review at session end (not left for later)"
fi

section "launch — offers to review a prior session's proposal (pty)"
# A window-closed session leaves a pending proposal; the next launch should OFFER to review it.
cat > "$GRANDMA_HOME/proposals/globex-20260601T090000.md" <<'P'
# grandma memory proposal
target: globex/facts.md | action: append | text: prior-session note
P
SHIM_O="$(make_fake_claude "$TMP/bin4")"; export SHIM_O GBIN_O="$GBIN" H_O="$GRANDMA_HOME"
out="$(printf 'n\n' | run_in_pty 'GRANDMA_HOME="$H_O" GRANDMA_NO_SPLASH=1 GRANDMA_NO_AUTOSAVE=1 HOME="'"$TMP"'/fh" PATH="$SHIM_O:$PATH" "$GBIN_O" globex 2>&1')"
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool — review-on-launch offer not exercised"
else
  # shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
  LAST_OUT="$out"
  assert_contains "review before we start?" "offers to review a prior session's notes at launch"
fi

section "launch — accepting the review offer routes to a review session (dry-run plan)"
# The pty harness cannot drive a specific answer past an interactive read (see note above), so
# we assert the WIRING via the dry-run plan: with a pending proposal, accepting the offer must
# exec `grandma review --apply <scope>` (Design A: review, then re-run), NOT list-and-continue.
# home-ops carries the fixture proposal; the scope must survive kebab intact.
capture env GRANDMA_DRY_RUN=1 "$GBIN" home-ops
assert_rc 0 "grandma home-ops (dry-run) runs"
assert_contains "grandma review --apply home-ops" "accepting the review offer execs an apply session for the full kebab scope"
assert_contains "1 pending proposal(s)" "the plan reports the pending proposal count"

section "launch — no pending proposals means no review line in the plan"
rm -f "$GRANDMA_HOME/proposals/globex"*.md   # earlier pty test seeded one; start clean here
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 0 "grandma globex (dry-run, no proposal) runs"
assert_not_contains "grandma review --apply globex" "no review line when the scope has no pending proposals"

section "launch — unknown sweater offers to knit it, not a cryptic error"
capture env "$GBIN" persona </dev/null                    # non-tty: friendly, actionable error
assert_rc 1 "grandma <unknown> exits 1 (no hang/crash)"
assert_contains "no sweater 'persona' yet" "gives a friendly message for an unknown sweater"
assert_not_contains "no scope matching" "no longer surfaces the raw assemble scope error"

section "launch — unknown sweater knit offer on a real terminal (pty)"
SHIM_U="$(make_fake_claude "$TMP/bin5")"; export SHIM_U GBIN_U="$GBIN" H_U="$GRANDMA_HOME"
out="$(printf 'n\n' | run_in_pty 'GRANDMA_HOME="$H_U" GRANDMA_NO_SPLASH=1 HOME="'"$TMP"'/fh" PATH="$SHIM_U:$PATH" "$GBIN_U" persona 2>&1')"
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool — knit-offer not exercised"
else
  # shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
  LAST_OUT="$out"
  assert_contains "knit it now?" "offers to knit an unknown sweater on a real terminal"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_launch: PASS"; else echo "cmd_launch: $FAILS FAILURE(S)"; exit 1; fi
