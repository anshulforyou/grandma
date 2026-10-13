#!/usr/bin/env bash
# Behavioral tests for `grandma opencode` — the OpenCode adapter. A fake opencode (make_fake_opencode)
# stands in for the CLI and its API, so every path runs offline: dry-run plans, routing from plain
# `grandma`, a real launch, memory isolation through the adapter, no context file in the project
# tree, chunked loading, and the distill with each of its guards proven to FIRE.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
naptime() { perl -e 'select(undef,undef,undef,shift)' "$1"; }
TMP="$(mktemp -d)"; trap 'pkill -f "sleep 33[78]" 2>/dev/null; rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home" SHELL="" GRANDMA_NO_SPLASH=1 GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_KNIT_CHECK=1
unset GRANDMA_CLI GRANDMA_OPENCODE_MODEL GRANDMA_DISTILLING GRANDMA_DRY_RUN
make_fixture_home "$GRANDMA_HOME"
FB="$(make_fake_opencode "$TMP/bin")"
ST="$TMP/bin/state"
mkdir -p "$TMP/tmp"
export TMPDIR="$TMP/tmp"
OC=(env PATH="$FB:$PATH")

runs()       { ls "$ST/runs" 2>/dev/null | wc -l | tr -d ' '; }
last_sid()   { printf 'ses_fake%04d' "$(cat "$ST/counter" 2>/dev/null || echo 0)"; }
proposals()  { ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' '; }

# ------------------------------------------------------------------ dry-run plans ----
section "opencode — dry-run, sweater only"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode globex
assert_rc 0 "grandma opencode globex (dry-run) runs"
assert_contains "memory: globex loaded" "banner names the loaded sweater"
assert_contains "session instruction entries grandma.memory" "memory rides in session instructions"
assert_contains "external_directory: $GRANDMA_HOME/*" "the memory home is writable through a session rule"
assert_contains "would launch:" "prints what it would launch"

section "opencode — dry-run, known project (fuzzy match) and kebab sweater"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode globex billing
assert_rc 0 "grandma opencode globex billing runs"
assert_contains "KNOWN project 'Billing API'" "fuzzy-resolves 'billing' to the registered project"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode home-ops yard
assert_rc 0 "grandma opencode home-ops yard (kebab sweater) runs"
assert_contains "memory: home-ops loaded" "the kebab sweater loads whole, not cut at the dash"
assert_contains "KNOWN project 'Yard'" "resolves the kebab sweater's project"
assert_contains "grandma opencode review home-ops" "the review offer names the full kebab sweater"
assert_contains "1 pending proposal(s)" "and counts its pending proposal"

section "opencode — dry-run, unknown project -> onboard"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode globex nope-not-real
assert_rc 0 "grandma opencode globex <unknown> runs"
assert_contains "ONBOARD (project 'nope-not-real' unknown in globex)" "routes an unknown project to onboarding"

section "opencode — refusals and usage"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode </dev/null
assert_rc 2 "no sweater on a pipe exits with usage, not a hang"
assert_contains "usage:" "prints usage"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode proposals </dev/null
assert_rc 2 "a reserved name is refused"
assert_contains "grandma reserves" "and says why"
capture env GRANDMA_HOME="$GRANDMA_HOME" bash -c '. "'"$ENGINE"'/lib/grandma-lib.sh"; ROOT="'"$GRANDMA_HOME"'"; scope_name_is_reserved opencode'
assert_rc 0 "'opencode' is now a reserved sweater name (it is a subcommand)"
capture "$GBIN" opencode persona </dev/null
assert_rc 1 "an unknown sweater exits 1"
assert_contains "no sweater 'persona' yet" "with the friendly knit hint"
mkdir -p "$GRANDMA_HOME/legacy"; printf '# legacy\n- no frontmatter\n' > "$GRANDMA_HOME/legacy/facts.md"
capture "$GBIN" opencode legacy </dev/null
assert_rc 1 "a frontmatter-less folder does not launch"
assert_contains "no file in it carries" "and the missing frontmatter is explained"
rm -rf "$GRANDMA_HOME/legacy"
capture env GRANDMA_DRY_RUN=1 GRANDMA_OPENCODE_MODEL=not-a-model "$GBIN" opencode globex
assert_rc 2 "a malformed GRANDMA_OPENCODE_MODEL is refused before anything is created"

section "opencode save / review — dry-run and argument checks"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode save globex billing --session ses_abc123 --auto
assert_rc 0 "save --auto (dry-run) runs"
assert_contains "AUTO" "reports auto mode"
assert_contains "proposal ->" "prints the proposal path it would write"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode save globex --session ses_abc123
assert_rc 0 "interactive save (dry-run) runs"
assert_contains "INTERACTIVE" "reports interactive mode"
capture "$GBIN" opencode save globex --auto
assert_rc 2 "save without --session refuses (no guessing the newest transcript)"
capture "$GBIN" opencode save globex --session '../../etc' --auto
assert_rc 2 "save refuses anything that is not an OpenCode session id"
capture "$GBIN" opencode save no-such-scope --session ses_abc123 --auto
assert_rc 1 "save on an unknown sweater exits 1"
capture env GRANDMA_DRY_RUN=1 "$GBIN" opencode review home-ops
assert_rc 0 "review (dry-run) runs"
assert_contains "home-ops-20260601T101010.md" "lists the kebab sweater's own proposal"
assert_contains "(scope=home-ops)" "and keeps the sweater whole"

# ------------------------------------------------------ routing from plain grandma ----
section "routing — GRANDMA_CLI and a sweater's cli: line send plain grandma to opencode"
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 0 "plain grandma (default) still runs"
assert_contains "claude --name grandma:globex" "the default is still claude"
assert_not_contains "opencode" "and nothing about opencode leaks into it"
capture env GRANDMA_CLI=opencode GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 0 "GRANDMA_CLI=opencode grandma globex runs"
assert_contains "cli:          opencode" "GRANDMA_CLI routes to the opencode adapter"
capture env GRANDMA_CLI=nonsense GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 2 "an unknown GRANDMA_CLI is refused, not guessed"
mkdir -p "$GRANDMA_HOME/routed"
printf -- '---\nscope: routed\ntype: facts\ncli: opencode\nupdated: 2026-06-15\n---\n\n- this sweater runs in opencode\n' > "$GRANDMA_HOME/routed/facts.md"
capture env GRANDMA_DRY_RUN=1 "$GBIN" routed
assert_rc 0 "a sweater with cli: opencode launches"
assert_contains "cli:          opencode" "its own cli: line routes it to opencode"
capture env GRANDMA_CLI=claude GRANDMA_DRY_RUN=1 "$GBIN" routed
assert_contains "claude --name grandma:routed" "GRANDMA_CLI still wins over the sweater's line"
rm -rf "$GRANDMA_HOME/routed"

# --------------------------------------------------------------- a real launch ----
section "launch — a real session against fake opencode"
capture env "${OC[@]}" FAKE_OC_RECENT_MODEL='{"providerID":"fakeprov","id":"last-used"}' \
  "$GBIN" opencode globex billing </dev/null
assert_rc 0 "grandma opencode globex billing runs"
SID="$(last_sid)"
SJ="$ST/sessions/$SID.json"
assert_file "$SJ" "a session was created"
capture jq -r '.title' "$SJ";                assert_contains "grandma:globex/Billing API" "titled for the sweater and project"
capture jq -r '.location.directory' "$SJ";   assert_contains "$GRANDMA_HOME/projects/billing-api" "located in the project folder"
capture jq -r '.metadata.grandma.scope' "$SJ"; assert_contains "globex" "the session records which sweater it belongs to"
capture jq -r '.model.id' "$SJ";             assert_contains "last-used" "it starts on the model last used there, not a default"
capture jq -c '.permissions' "$SJ"
assert_contains "\"resource\":\"$GRANDMA_HOME/*\"" "the session may write the memory home"
assert_not_contains '"effect":"deny"' "and the work session itself is not tool-less"
MEM="$ST/entries/$SID/grandma.memory"
assert_file "$MEM" "memory was loaded as the grandma.memory instruction entry"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(cat "$MEM" 2>/dev/null)"
assert_contains "===== MEMORY BUNDLE: scope=globex" "it is the assembled bundle"
assert_contains "----- BEGIN global/identity.md" "with global memory"
assert_contains "----- BEGIN globex/facts.md" "and the sweater's memory"
assert_contains "seven categories" "and the capture doctrine"
assert_contains "the globex billing service" "and the project's own CLAUDE.md (OpenCode reads only AGENTS.md)"
assert_contains "The grandma memory repo is at $GRANDMA_HOME" "and where captures go"
assert_not_contains "home-ops" "isolation: no other sweater's memory rides in"
assert_not_contains "trash goes out Sunday night" "isolation: not even one of its facts"
TUI="$ST/tui-$SID.txt"
assert_file "$TUI" "the terminal UI was opened on that session"
LAST_OUT="$(cat "$TUI" 2>/dev/null)"
assert_contains "▣ memory: globex loaded" "its first message asks for the memory confirmation line"
assert_contains "project Billing API" "naming the project"
assert_contains "dir=$GRANDMA_HOME/projects/billing-api" "in the project folder"
capture ls -A "$GRANDMA_HOME/projects/billing-api"
assert_rc 0 "the project folder is readable"
assert_not_contains "AGENTS.md" "no memory-bearing AGENTS.md was written into the project tree"
assert_not_contains "GEMINI.md" "nor any other context file"
[ "$(ls -A "$GRANDMA_HOME/projects/billing-api" | wc -l | tr -d ' ')" = 1 ] \
  && ok "the project folder holds exactly what it held before (its CLAUDE.md)" \
  || fail "the launch left files in the project folder" "$(ls -A "$GRANDMA_HOME/projects/billing-api")"
leftover=0
for f in "$TMPDIR"/grandma-oc*; do [ -e "$f" ] && leftover=$((leftover + 1)); done
[ "$leftover" = 0 ] && ok "no private memory file outlives the session" || fail "temp memory files left behind: $(ls "$TMPDIR")"

section "launch — a sweater too big for one entry is split, and every piece fits"
{ printf -- '---\nscope: globex\ntype: notes\nupdated: 2026-06-15\n---\n\n'
  i=0; while [ "$i" -lt 6000 ]; do printf -- '- note %05d about the billing migration and its rollout plan\n' "$i"; i=$((i + 1)); done
} > "$GRANDMA_HOME/globex/notes.md"
capture env "${OC[@]}" "$GBIN" opencode globex </dev/null
assert_rc 0 "a 380 KB sweater still launches (one entry holds only 256 KiB)"
SID="$(last_sid)"
pieces="$(grep -c "^$SID grandma.memory" "$ST/puts.log" || true)"
[ "${pieces:-0}" -ge 4 ] && ok "memory was split across $pieces entries" || fail "expected the memory split into several entries (got ${pieces:-0})"
biggest="$(awk -v s="$SID" '$1 == s { if ($3 > m) m = $3 } END { print m + 0 }' "$ST/puts.log")"
[ "$biggest" -le 96000 ] && ok "every request body stayed inside the argv budget ($biggest bytes)" \
                         || fail "a request body went over the argv budget: $biggest bytes"
cat "$ST/entries/$SID"/grandma.memory* > "$TMP/joined" 2>/dev/null
grep -q 'note 05999 about the billing' "$TMP/joined" && ok "the last line of memory arrived" || fail "the tail of memory was lost in the split"
rm -f "$GRANDMA_HOME/globex/notes.md"

section "launch — a reload that shrinks drops the stale pieces"
# shellcheck disable=SC2016  # the snippet is expanded by the inner bash, on purpose
capture env PATH="$FB:$PATH" FAKE_OC_ROOT="$ST" bash -c '
  . "'"$ENGINE"'/lib/grandma-lib.sh"; . "'"$ENGINE"'/lib/adapters/opencode.sh"
  big="'"$TMP"'/big.txt"; small="'"$TMP"'/small.txt"
  python3 -c "print(\"x\" * 90 + \"\n\", end=\"\")" > "$small"
  python3 -c "import sys; sys.stdout.write((\"y\" * 90 + \"\n\") * 3000)" > "$big"
  echo "big=$(oc_load ses_shrink01 grandma.memory "$big")"
  echo "small=$(oc_load ses_shrink01 grandma.memory "$small")"
  echo "left=$(ls "'"$ST"'/entries/ses_shrink01" | tr "\n" " ")"'
assert_rc 0 "oc_load runs twice on one session"
assert_contains "small=1" "the second load wrote one piece"
assert_contains "left=grandma.memory " "and only that piece is left in the session"

section "launch — no session that claims to remember without the memory"
before_tui="$(grep -c '^tui ' "$ST/calls.log" || true)"
capture env "${OC[@]}" FAKE_OC_ENTRIES=off "$GBIN" opencode globex </dev/null
assert_rc 1 "a refused memory load stops the launch"
assert_contains "would not take the memory" "and says why"
SID="$(last_sid)"
grep -qx "$SID" "$ST/deleted.log" && ok "the half-made session was deleted" || fail "the session without memory was left behind"
[ "$(grep -c '^tui ' "$ST/calls.log" || true)" = "$before_tui" ] && ok "no terminal UI was opened" || fail "a UI was opened without memory loaded"

section "launch — never from inside a distill (recursion guard)"
before_tui="$(grep -c '^tui ' "$ST/calls.log" || true)"
capture env "${OC[@]}" GRANDMA_DISTILLING=1 "$GBIN" opencode globex </dev/null
assert_rc 0 "a launch inside a distill exits cleanly"
assert_contains "inside a distill" "and says why"
[ "$(grep -c '^tui ' "$ST/calls.log" || true)" = "$before_tui" ] && ok "the guard stopped the launch (no UI opened)" || fail "the recursion guard did not hold"

# --------------------------------------------------------------- the distill ----
section "save --auto — a proposal from the whole transcript, in a deny-all session"
capture env "${OC[@]}" "$GBIN" opencode save globex billing --session ses_test0001 --auto
assert_rc 0 "save --auto runs"
prop="$GRANDMA_HOME/proposals/globex-Billing API-ses_test0001.md"
assert_file "$prop" "a proposal lands in the memory home"
LAST_OUT="$(cat "$prop" 2>/dev/null)"
assert_contains "# scope=globex project=Billing API" "with the scope header review matches on"
assert_contains "FAKEOC-PROPOSAL" "holding the distiller's answer"
assert_contains "distilling=1" "GRANDMA_DISTILLING=1 reaches the headless call (guard active)"
R="$ST/runs/$(runs)"
capture jq -c '.permissions' "$R/session.json"
assert_contains '"action":"*","resource":"*","effect":"deny"' "the distill session denies every tool"
grep -qx "$(cat "$R/session")" "$ST/deleted.log" && ok "and is deleted once it has answered" || fail "the distill session was left behind"
capture cat "$R/model";  assert_contains "fakeprov/fake-model-2" "it answers on the model of the session's last turn"
capture cat "$R/files";  assert_contains "$GRANDMA_HOME/.distill/opencode-ses_test0001.md" "the transcript was staged inside the memory home"
LAST_OUT="$(cat "$R/opencode-ses_test0001.md" 2>/dev/null)"
assert_contains "USER: how do I run the billing migration?" "the transcript has the first page"
assert_contains "ASSISTANT: Noted: pnpm only." "and the second page"
assert_not_contains "PRIVATE-REASONING" "reasoning is dropped"
assert_not_contains "TOOL-NOISE" "tool noise is dropped"
LAST_OUT="$(cat "$R/opencode-ses_test0001.memory.md" 2>/dev/null)"
assert_contains "----- BEGIN globex/decisions.md" "the distiller sees memory in full (decisions too)"
assert_contains "the globex billing service" "and the project's CLAUDE.md"
assert_no_file "$GRANDMA_HOME/.distill/opencode-ses_test0001.md" "the staged transcript is cleaned up"
assert_no_file "$GRANDMA_HOME/.distill/.lock-opencode-ses_test0001" "and the lock released"
capture env "$GBIN" review globex
assert_contains "globex-Billing API-ses_test0001.md" "the engine's own review lists it (same proposal format)"

section "save --auto — the same transcript is drafted once"
before="$(runs)"
capture env "${OC[@]}" "$GBIN" opencode save globex billing --session ses_test0001 --auto
[ "$(runs)" = "$before" ] && ok "a second distill of an unchanged session makes no model call" || fail "the same transcript was distilled twice"

section "save --auto CIRCUIT BREAKER fires (delta test)"
for i in 1 2 3; do echo x > "$GRANDMA_HOME/proposals/dummy$i.md"; done
before="$(runs)"; bp="$(proposals)"
capture env "${OC[@]}" GRANDMA_AUTOSAVE_CAP=3 "$GBIN" opencode save globex --session ses_cap00001 --auto
assert_contains "CIRCUIT BREAKER" "the breaker announces itself when over cap"
[ "$(runs)" = "$before" ] && ok "the breaker stopped the model call itself" || fail "a model call ran past the breaker"
[ "$(proposals)" = "$bp" ] && ok "and no proposal was added" || fail "a proposal was added past the breaker"
capture env "${OC[@]}" GRANDMA_AUTOSAVE_CAP=100 "$GBIN" opencode save globex --session ses_cap00001 --auto
[ "$(runs)" -gt "$before" ] && ok "with headroom the distill runs (positive control)" || fail "no distill under a high cap"
rm -f "$GRANDMA_HOME/proposals/dummy"*.md

section "save --auto — the lock and the recursion guard fire"
mkdir -p "$GRANDMA_HOME/.distill/.lock-opencode-ses_lock0001"
before="$(runs)"
capture env "${OC[@]}" "$GBIN" opencode save globex --session ses_lock0001 --auto
assert_contains "already running" "a held lock is reported"
[ "$(runs)" = "$before" ] && ok "and no second distill ran for that session" || fail "the lock did not hold"
rmdir "$GRANDMA_HOME/.distill/.lock-opencode-ses_lock0001"
capture env "${OC[@]}" GRANDMA_DISTILLING=1 "$GBIN" opencode save globex --session ses_rec00001 --auto
[ "$(runs)" = "$before" ] && ok "inside a distill, save --auto makes no model call" || fail "the recursion guard did not hold"

section "save --auto — nothing durable, a crash, a failure: no proposal, no retry"
for mode in noop crash; do
  before="$(runs)"; bp="$(proposals)"
  capture env "${OC[@]}" FAKE_OC_RUN="$mode" "$GBIN" opencode save globex --session "ses_${mode}0001" --auto
  assert_rc 0 "save --auto with a $mode answer runs"
  [ "$(runs)" -gt "$before" ] && [ "$(proposals)" = "$bp" ] && ok "a $mode answer leaves no proposal to ping you about" \
    || fail "a $mode answer left a proposal (or never ran)"
done
before="$(runs)"; bp="$(proposals)"
capture env "${OC[@]}" FAKE_OC_RUN=fail "$GBIN" opencode save globex --session ses_fail0001 --auto
[ "$(runs)" = $((before + 1)) ] && ok "a failed call is made exactly once (never retried)" || fail "a failed call was retried or never made"
[ "$(proposals)" = "$bp" ] && ok "and leaves no proposal" || fail "a failed call left a proposal"
capture env "${OC[@]}" FAKE_OC_RUN=fail "$GBIN" opencode save globex --session ses_fail0001 --auto
[ "$(runs)" = $((before + 2)) ] && ok "a confirmed failure is not recorded as done, so you can run it again" \
  || fail "a confirmed failure blocked a later attempt"

# ------------------------------------------------------------------- review ----
section "review — a session in the memory home with the review doctrine"
capture env "${OC[@]}" "$GBIN" opencode review home-ops </dev/null
assert_rc 0 "grandma opencode review home-ops runs"
SID="$(last_sid)"
capture jq -r '.title, .location.directory' "$ST/sessions/$SID.json"
assert_contains "grandma:review" "a review session"
assert_contains "$GRANDMA_HOME" "run inside the memory home, as grandma review does"
LAST_OUT="$(cat "$ST/entries/$SID/grandma.review" 2>/dev/null)"
assert_contains "ONE AT A TIME" "carrying grandma review's own instructions"
assert_contains "home-ops-20260601T101010.md" "naming the sweater's pending proposal"
assert_contains "RUNNING IN OPENCODE" "with the paths translated for OpenCode"
assert_contains "----- BEGIN home-ops/log/2026-06-01.md" "and memory in full"
assert_not_contains "globex" "and nothing from another sweater"

# ---------------------------------------------------------- end of session (pty) ----
section "launch — a capture during the session triggers the review at exit (pty)"
rm -f "$GRANDMA_HOME/proposals/globex"*.md
export FBP="$FB" GBIN_P="$GBIN" H_P="$GRANDMA_HOME"
out="$(printf 'n\n' | run_in_pty 'GRANDMA_HOME="$H_P" GRANDMA_NO_SPLASH=1 GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_KNIT_CHECK=1 HOME="'"$TMP"'/fh" PATH="$FBP:$PATH" FAKE_OC_TUI_CAPTURE="$H_P/globex/facts.md" "$GBIN_P" opencode globex 2>&1')"
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool — end-of-session review not exercised"
else
  # shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
  LAST_OUT="$out"
  assert_contains "grandma is looking over the session" "the wrapped UI returns and the distill runs"
  assert_contains "1 memory file(s) updated live this session" "the session's own capture is detected"
  assert_contains "a drafted proposal to review" "the distill's draft is offered"
  assert_contains "review now?" "and the review is offered right then"
fi
git -C "$GRANDMA_HOME" checkout -q -- globex/facts.md 2>/dev/null || true

# ------------------------------------------------------------ an abrupt exit ----
# wait_for <file-glob-test-cmd...> — poll up to ~12s; the background distill is a detached process.
wait_for() { local i; for i in $(seq 1 60); do "$@" && return 0; naptime 0.2; done; return 1; }
has_prop() { ls "$GRANDMA_HOME/proposals/"globex-Billing\ API-*.md >/dev/null 2>&1; }

section "window close (SIGHUP to the session's group) — the capture survives and a distill lands"
rm -f "$GRANDMA_HOME/proposals/globex"*.md
LIVE="$TMP/live-a"
set -m
( exec env PATH="$FB:$PATH" FAKE_OC_TUI_LIVE="$LIVE" FAKE_OC_TUI_CAPTURE="$GRANDMA_HOME/globex/facts.md" \
    "$GBIN" opencode globex billing ) </dev/null > "$TMP/hup-a.log" 2>&1 &
pg=$!
set +m
if ! wait_for test -f "$LIVE"; then
  fail "the session never went live" "$(cat "$TMP/hup-a.log")"
else
  kill -s HUP -- -"$pg" 2>/dev/null || /bin/kill -s HUP -"$pg" 2>/dev/null
  grep -q 'captured mid-session' "$GRANDMA_HOME/globex/facts.md" \
    && ok "the in-flight capture survives a window close" || fail "the in-flight capture was lost"
  if wait_for has_prop; then
    ok "a window close still lands a background distill proposal"
    # shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
    LAST_OUT="$(cat "$GRANDMA_HOME/proposals/"globex-Billing\ API-*.md 2>/dev/null)"
    assert_contains "project=Billing API" "and the proposal keeps the project, a name with a space in it"
  else
    fail "the window close lost the exit distill" "$(cat "$TMP/hup-a.log")"
  fi
fi
git -C "$GRANDMA_HOME" checkout -q -- globex/facts.md 2>/dev/null || true

section "a hangup that reaches only the launcher still stops the UI and distills"
# The launcher is the session leader whenever it was exec'd or run straight from a terminal profile,
# and then the hangup reaches it alone. OpenCode's UI does not notice its terminal is gone, so a
# launcher that waited on it in the foreground would wait forever and never distill.
rm -f "$GRANDMA_HOME/proposals/globex"*.md
LIVE="$TMP/live-b"
( exec env PATH="$FB:$PATH" FAKE_OC_TUI_LIVE="$LIVE" FAKE_OC_TUI_SLEEP=338 "$GBIN" opencode globex billing ) \
  </dev/null > "$TMP/hup-b.log" 2>&1 &
lp=$!
if ! wait_for test -f "$LIVE"; then
  fail "the session never went live" "$(cat "$TMP/hup-b.log")"
else
  kill -s HUP "$lp"
  if wait_for has_prop; then ok "a hangup to the launcher alone still distills the session"
  else fail "a hangup to the launcher alone lost the distill" "$(cat "$TMP/hup-b.log")"; fi
  if wait_for sh -c '! pgrep -f "sleep 338" >/dev/null'; then ok "and the UI was told to stop, not left running unseen"
  else fail "the UI was left running after the launcher's hangup"; fi
fi

# ---------------------------------------------------------------------- doctor ----
section "doctor"
capture env "${OC[@]}" "$GBIN" opencode doctor
assert_rc 0 "doctor is healthy with opencode present"
assert_contains "load_mode=instruction_entries" "and prints what the adapter does"
capture env GRANDMA_OPENCODE_BIN=/nonexistent/opencode "$GBIN" opencode doctor
assert_rc 1 "doctor fails when opencode is missing"
assert_contains "opencode CLI not on PATH" "and says what to install"

# ------------------------------------------------------------------ integrity ----
section "integrity — the suite passes, and invariant 19 fails when a guard goes"
capture env "$GBIN" test
assert_rc 0 "grandma test passes on the fixture home"
assert_contains "opencode distill is guarded" "invariant 19 runs"
cp -R "$ENGINE" "$TMP/engine-copy"
sed -i.bak '/CIRCUIT BREAKER/d' "$TMP/engine-copy/lib/grandma-opencode.sh"
capture env "$TMP/engine-copy/bin/grandma" test
assert_rc 1 "deleting the opencode circuit breaker fails the suite"
assert_contains "the opencode distill has no circuit breaker" "and names what went missing"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_opencode: PASS"; else echo "cmd_opencode: $FAILS FAILURE(S)"; exit 1; fi
