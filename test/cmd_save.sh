#!/usr/bin/env bash
# Behavioral tests for `grandma save` (the distiller) — dry-run, real headless via fake
# claude, and the two safety guards proven to FIRE (not merely exist as strings).
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
TRANS="$TMP/t.jsonl"; make_fake_transcript "$TRANS"

section "save — dry-run (interactive + auto modes)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" save globex billing --transcript "$TRANS"
assert_rc 0 "save (interactive dry-run) runs"
assert_contains "INTERACTIVE" "reports interactive mode"
capture env GRANDMA_DRY_RUN=1 "$GBIN" save globex billing --auto --transcript "$TRANS"
assert_rc 0 "save --auto (dry-run) runs"
assert_contains "AUTO" "reports auto mode"
assert_contains "proposal ->" "prints the proposal path it would write"

section "save --auto (real, fake claude): proposal placement + sandbox cleanup"
capture env PATH="$FB:$PATH" "$GBIN" save globex billing --auto --transcript "$TRANS"
assert_rc 0 "save --auto runs"
prop="$(ls "$GRANDMA_HOME/proposals/"globex-*.md 2>/dev/null | head -n1)"
assert_file "$prop" "a proposal file lands in the home (not /tmp)"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(cat "$prop" 2>/dev/null)"
assert_contains "FAKECLAUDE-PROPOSAL" "proposal contains the distiller output"
# Recursion guard proven to be INHERITED by the headless child (the shim echoes it):
assert_contains "distilling=1" "GRANDMA_DISTILLING=1 reaches the headless distiller (guard active)"
assert_no_file "$GRANDMA_HOME/.distill/t.md" "readable transcript is cleaned up after distill"

section "save --auto CIRCUIT BREAKER fires (delta test)"
# Fill proposals/ with recent files so the last-5-min count is at/over the cap.
for i in 1 2 3; do echo x > "$GRANDMA_HOME/proposals/dummy$i.md"; done
before="$(ls "$GRANDMA_HOME/proposals/"*.md | wc -l | tr -d ' ')"
capture env PATH="$FB:$PATH" GRANDMA_AUTOSAVE_CAP=3 "$GBIN" save globex billing --auto --transcript "$TRANS"
after="$(ls "$GRANDMA_HOME/proposals/"*.md | wc -l | tr -d ' ')"
assert_contains "CIRCUIT BREAKER" "breaker announces itself when over cap"
if [ "$before" = "$after" ]; then ok "breaker adds NO new proposal when over cap ($before==$after)"
else fail "breaker did not hold (before=$before after=$after)"; fi
# positive control: with a high cap, a new proposal IS added. Use a distinct transcript
# name so the proposal filename differs (it is derived from the transcript basename).
TRANS2="$TMP/fresh-session.jsonl"; make_fake_transcript "$TRANS2"
before2="$(ls "$GRANDMA_HOME/proposals/"*.md | wc -l | tr -d ' ')"
capture env PATH="$FB:$PATH" GRANDMA_AUTOSAVE_CAP=100 "$GBIN" save globex billing --auto --transcript "$TRANS2"
after2="$(ls "$GRANDMA_HOME/proposals/"*.md | wc -l | tr -d ' ')"
if [ "$after2" -gt "$before2" ]; then ok "with headroom, a proposal IS written ($before2->$after2)"
else fail "expected a new proposal under a high cap (before=$before2 after=$after2)"; fi

section "save --auto drops a no-op distill (No durable learnings) — no file, no future ping"
NOOP="$TMP/noop-bin"; mkdir -p "$NOOP"
cat > "$NOOP/claude" <<'NOOPSHIM'
#!/usr/bin/env bash
case "${1:-}" in --version|-v) echo 0.0.0; exit 0 ;; esac
if [ "${1:-}" = "-p" ]; then
  echo "No durable learnings."
  echo
  echo "Everything discussed was undecided brainstorm, nothing to persist."
  exit 0
fi
exit 0
NOOPSHIM
chmod +x "$NOOP/claude"
TRANS3="$TMP/noop-session.jsonl"; make_fake_transcript "$TRANS3"   # unique name so it can't collide
before="$(ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' ')"
capture env PATH="$NOOP:$PATH" "$GBIN" save globex billing --auto --transcript "$TRANS3"
assert_rc 0 "save --auto with nothing durable runs"
after="$(ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$after" = "$before" ] && ok "a no-op distill leaves no proposal file (won't ping you later)" \
                         || fail "no-op distill left a proposal ($before -> $after)"

section "save --auto drops a crashed distill that exits 0 (Execution error) — no corpse proposal"
# claude -p can fail with exit 0: it prints "Execution error" to stdout and exits clean,
# so the (distiller failed) marker never lands. The content filter must catch it instead.
ERRB="$TMP/err-bin"; mkdir -p "$ERRB"
cat > "$ERRB/claude" <<'ERRSHIM'
#!/usr/bin/env bash
case "${1:-}" in --version|-v) echo 0.0.0; exit 0 ;; esac
if [ "${1:-}" = "-p" ]; then echo "Execution error"; exit 0; fi
exit 0
ERRSHIM
chmod +x "$ERRB/claude"
TRANS4="$TMP/err-session.jsonl"; make_fake_transcript "$TRANS4"
before="$(ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' ')"
capture env PATH="$ERRB:$PATH" "$GBIN" save globex billing --auto --transcript "$TRANS4"
assert_rc 0 "save --auto with an exit-0 crash runs"
after="$(ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$after" = "$before" ] && ok "an exit-0 Execution error leaves no proposal file (no review offer on a corpse)" \
                         || fail "exit-0 Execution error left a corpse proposal ($before -> $after)"

section "save — unknown scope with a project fails cleanly"
capture env "$GBIN" save no-such-scope billing --transcript "$TRANS"
assert_rc 1 "save on an unknown scope exits 1 (no unbound crash)"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_save: PASS"; else echo "cmd_save: $FAILS FAILURE(S)"; exit 1; fi
