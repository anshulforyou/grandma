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

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_watch: PASS"; else echo "cmd_watch: $FAILS FAILURE(S)"; exit 1; fi
