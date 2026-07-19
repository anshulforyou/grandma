#!/usr/bin/env bash
# Behavioral tests for `grandma watch` — the mechanical (zero-LLM) metrics path, plus the
# lockfile guard. The python metrics block also exercises the BSD/GNU file_mtime helpers,
# so this is a high-value test to run on macos-latest.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# watch reads $HOME/.claude/projects — point HOME at the sandbox.
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

section "watch — start"
capture env "$GBIN" watch start "why are sessions long" --days 14
assert_rc 0 "watch start runs"
assert_contains "watch started:" "confirms the campaign started"
slug="$(ls "$GRANDMA_HOME/watches/" | head -n1)"
assert_file "$GRANDMA_HOME/watches/$slug/watch.json" "writes watch.json"
capture env python3 -c "import json;json.load(open('$GRANDMA_HOME/watches/$slug/watch.json'))"
assert_rc 0 "watch.json is valid JSON"

section "watch — tick is blocked by a held lock (delta test)"
mkdir -p "$GRANDMA_HOME/watches/.tick.lock"
seed_claude_project "$HOME" "-tmp-proj-one" "sess1" >/dev/null
capture env PATH="/usr/bin:/bin" "$GBIN" watch tick
assert_rc 0 "tick with a held lock exits cleanly"
assert_no_file "$GRANDMA_HOME/watches/$slug/data/metrics.jsonl" "held lock prevents metric computation"
rm -rf "$GRANDMA_HOME/watches/.tick.lock"

section "watch — tick metrics-only (no claude) computes real metrics"
capture env PATH="/usr/bin:/bin" "$GBIN" watch tick
assert_rc 0 "metrics tick runs without claude"
assert_file "$GRANDMA_HOME/watches/$slug/data/metrics.jsonl" "writes metrics.jsonl"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(cat "$GRANDMA_HOME/watches/$slug/data/metrics.jsonl" 2>/dev/null)"
assert_contains '"user_turns": 2' "counts user turns from the transcript"
assert_contains '"tool_calls": 1' "counts tool calls"

section "watch — list / status"
capture env "$GBIN" watch list
assert_rc 0 "watch list runs"
assert_contains "$slug" "list shows the campaign"
capture env "$GBIN" watch status
assert_rc 0 "watch status runs"
assert_contains "sessions measured" "status reports progress"

section "watch — notify-test delivers via a backend (issue #4)"
# Shadow osascript with a failing stub (neutralizes the real macOS notifier so the suite
# never pops a live notification) and provide a fake notify-send that just succeeds.
NB="$TMP/notifybin"; mkdir -p "$NB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NB/osascript"   # "not macOS": force fallthrough
printf '#!/usr/bin/env bash\nexit 0\n' > "$NB/notify-send" # a working desktop notifier
chmod +x "$NB/osascript" "$NB/notify-send"
capture env PATH="$NB:/usr/bin:/bin" "$GBIN" watch notify-test
assert_rc 0 "notify-test exits 0 when a notifier delivers"
assert_contains "delivered" "reports delivery"

section "watch — notify-test logs (not silent) when delivery fails"
# Both backends fail (osascript stubbed off; notify-send present but errors, like a
# headless box with no session bus — the real Linux failure). Must log, not swallow.
NN="$TMP/nonotify"; mkdir -p "$NN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NN/osascript"
printf '#!/usr/bin/env bash\necho "Cannot autolaunch D-Bus without X11 DISPLAY" >&2; exit 1\n' > "$NN/notify-send"
chmod +x "$NN/osascript" "$NN/notify-send"
capture env PATH="$NN:/usr/bin:/bin" "$GBIN" watch notify-test
assert_rc 1 "notify-test exits 1 when delivery fails"
assert_file "$GRANDMA_HOME/.distill/notify.log" "failure is logged, not swallowed"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_watch: PASS"; else echo "cmd_watch: $FAILS FAILURE(S)"; exit 1; fi
