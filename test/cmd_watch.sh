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

section "watch — tool lens counts calls per tool name"
# A second session with two Edit calls, so the breakdown has something to rank.
sess2="$HOME/.claude/projects/-tmp-proj-two/sess2.jsonl"
seed_claude_project "$HOME" "-tmp-proj-two" "sess2" >/dev/null
cat >> "$sess2" <<'JSONL'
{"type":"assistant","timestamp":"2026-06-15T11:00:00.000Z","message":{"role":"assistant","model":"claude-test","usage":{},"content":[{"type":"tool_use","name":"Edit","input":{}},{"type":"tool_use","name":"Edit","input":{}}]}}
JSONL
capture env PATH="/usr/bin:/bin" "$GBIN" watch tick
assert_rc 0 "tick with a second session runs"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(cat "$GRANDMA_HOME/watches/$slug/data/metrics.jsonl")"
assert_contains '"Bash": 1' "records the per-tool name, not just the total"
assert_contains '"Edit": 2' "counts repeated calls to the same tool"

capture env "$GBIN" watch status
assert_rc 0 "status runs with tool counts"
assert_contains "top tools: Bash=2 Edit=2" "status ranks tools by call count"

section "watch — report synthesis feeds the tool lens to the model, guard intact"
FB="$TMP/fakebin"; make_fake_claude "$FB" >/dev/null
capture env PATH="$FB:/usr/bin:/bin" "$GBIN" watch finish "$slug"
assert_rc 0 "finish synthesizes a report"
assert_file "$GRANDMA_HOME/watches/$slug/.work/metrics-summary.md" "writes the metrics summary"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* (sourced from lib/assert.sh)
LAST_OUT="$(cat "$GRANDMA_HOME/watches/$slug/.work/metrics-summary.md")"
assert_contains "tool usage (all sessions" "summary carries the tool breakdown"
assert_contains "Bash=2 Edit=2" "summary lists the ranked tools"
# shellcheck disable=SC2034
LAST_OUT="$(cat "$GRANDMA_HOME/watches/$slug/report.md")"
assert_contains "distilling=1" "synthesis child inherits the recursion guard"

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
