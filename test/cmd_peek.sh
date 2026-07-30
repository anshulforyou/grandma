#!/usr/bin/env bash
# Behavioral tests for grandma-peek.sh (v0 shadow mode: grade each finished assistant message
# against loaded memory, log the verdict, render NOTHING).
#
# Bites this suite exists for:
#  - MessageDisplay holds each streaming batch until the hook returns, so a non-final batch must
#    cost nothing. A delta-test proves no model call happens, not merely that it is fast.
#  - v0's whole safety claim is that it cannot speak. Asserted directly: stdout stays empty even
#    when the model returns findings.
#  - The citation rule is enforced in the shell, not the prompt, so an uncited finding must be
#    dropped even when the model insists on it.
#  - It is a headless model call: recursion guard, cost cap and lock must STOP the call (delta),
#    the dry run must make none, and every path must exit 0 and survive set -u.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

PK="$ENGINE/lib/grandma-peek.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
PEEK="$GRANDMA_HOME/.peek"

# fake_claude_json <dir> <payload> — a claude shim whose -p output is exactly <payload>, so a
# test can pin what peek does with a given model verdict. Also drops a marker per -p call, which
# is what makes the guard tests DELTA tests: no marker means the model was never reached.
fake_claude_json() {
  local dir="$1" payload="$2"
  mkdir -p "$dir"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "${1:-}" in --version|-v) echo "0.0.0 (fake)"; exit 0 ;; esac\n'
    printf 'if [ "${1:-}" = "-p" ]; then echo called >> "%s/.calls"; cat <<'\''EOJSON'\''\n' "$dir"
    printf '%s\n' "$payload"
    printf 'EOJSON\n  exit 0\nfi\nexit 0\n'
  } > "$dir/claude"
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}
calls_of() { local d="$1"; [ -f "$d/.calls" ] && wc -l < "$d/.calls" | tr -d ' ' || echo 0; }

# md_json <session> <final> <delta> — a MessageDisplay stdin payload.
md_json() {
  jq -nc --arg s "$1" --argjson f "$2" --arg d "$3" \
    '{session_id:$s,turn_id:"turn-1",message_id:"msg-1",index:0,final:$f,delta:$d,
      hook_event_name:"MessageDisplay",cwd:"/tmp"}'
}
log_of()    { printf '%s/%s/log.jsonl' "$PEEK" "$1"; }
ledger_of() { printf '%s/%s/ledger.jsonl' "$PEEK" "$1"; }
# last_log <session> <jq filter>
last_log() { tail -n1 "$(log_of "$1")" 2>/dev/null | jq -r "$2" 2>/dev/null; }

FINDING='{"findings":[{"class":"1","cited_file":"global/preferences.md","cited_line":"pnpm only, never yarn","what":"says it will run yarn","suggestion":"Use pnpm, not yarn."}]}'
UNCITED='{"findings":[{"class":"1","cited_file":"","cited_line":"","what":"seems inconsistent with your workflow"}]}'
NONE='{"findings":[]}'

# ---------------------------------------------------------------------------------------------
section "peek — a non-final batch costs nothing (delta: the model is never reached)"
FB="$(fake_claude_json "$TMP/b1" "$FINDING")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-nonfinal false "some streaming text")' | '$PK' display globex billing"
assert_rc 0 "non-final batch exits 0 under set -u"
[ "$(calls_of "$FB")" = "0" ] && ok "no model call on a non-final batch" || fail "non-final batch reached the model"
assert_no_file "$(log_of s-nonfinal)" "non-final batch writes no log line"

section "peek — v0 RENDERS NOTHING, even when the model returns a finding"
FB="$(fake_claude_json "$TMP/b2" "$FINDING")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-silent true "I will run yarn install now.")' | '$PK' display globex billing"
assert_rc 0 "graded message exits 0"
assert_not_contains "displayContent" "v0 never emits displayContent"
assert_not_contains "pnpm" "v0 leaks no finding text to stdout"
[ -z "${LAST_OUT// /}" ] && ok "stdout is completely empty (cannot alter the screen)" || fail "stdout was not empty" "$LAST_OUT"

section "peek — a cited finding is graded and logged"
assert_file "$(log_of s-silent)" "writes a log line"
[ "$(last_log s-silent '.would_have_spoken')" = "true" ] && ok "would_have_spoken is true" || fail "would_have_spoken not set"
[ "$(last_log s-silent '.findings[0].cited_line')" = "pnpm only, never yarn" ] && ok "keeps the cited line verbatim" || fail "cited line lost"
[ "$(last_log s-silent '.turn_id')" = "turn-1" ] && ok "log line carries turn_id (messages per turn)" || fail "turn_id missing"
[ "$(last_log s-silent '.in_tokens_est')" -gt 0 ] 2>/dev/null && ok "log line carries in_tokens_est (tokens per message)" || fail "in_tokens_est missing"
[ "$(last_log s-silent '.latency_ms')" != "null" ] && ok "log line carries latency_ms (the pause v1 will cost)" || fail "latency_ms missing"

section "peek — THE CITATION RULE: an uncited finding is dropped in the shell"
FB="$(fake_claude_json "$TMP/b3" "$UNCITED")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-uncited true "This approach seems off.")' | '$PK' display globex billing"
assert_rc 0 "uncited run exits 0"
[ "$(last_log s-uncited '.findings | length')" = "0" ] && ok "uncited finding never survives" || fail "an uncited finding got through"
[ "$(last_log s-uncited '.dropped_uncited')" = "1" ] && ok "records that one was dropped" || fail "dropped_uncited not counted"
[ "$(last_log s-uncited '.would_have_spoken')" = "false" ] && ok "would not have spoken" || fail "would_have_spoken wrongly true"

section "peek — no findings is the normal case and stays silent"
FB="$(fake_claude_json "$TMP/b4" "$NONE")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-clean true "Reading the config file.")' | '$PK' display globex"
assert_rc 0 "clean run exits 0"
[ "$(last_log s-clean '.would_have_spoken')" = "false" ] && ok "silent on a clean message" || fail "spoke on a clean message"

section "peek — a FENCED reply is parsed (what a real model actually returns)"
# The shim used to hand back bare JSON, which no real model does. A ```json fence left the
# closing fence in the slice, jq then printed one number per input, and "1\n0" reaching an
# arithmetic expansion is FATAL in bash — the child died before logging, silently, and every
# assertion here still passed. This case is why the suite missed it.
FENCED='```json
{"findings":[{"class":"1","cited_file":"global/preferences.md","cited_line":"pnpm only, never yarn","what":"says it will run yarn","suggestion":"Use pnpm, not yarn."}]}
```'
FB="$(fake_claude_json "$TMP/b5a" "$FENCED")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-fenced true "I will run yarn install.")' | '$PK' display globex billing"
assert_rc 0 "a fenced reply exits 0"
assert_file "$(log_of s-fenced)" "a fenced reply still produces a log line"
[ "$(last_log s-fenced '.findings | length')" = "1" ] && ok "the fence is stripped and the finding survives" || fail "fenced JSON was not parsed"
[ "$(last_log s-fenced '.dropped_uncited')" = "0" ] && ok "the closing fence is not counted as a dropped finding" || fail "fence miscounted"

section "peek — prose around the JSON does not break it"
CHATTY='Here is my assessment.

```json
{"findings":[]}
```
Let me know if you need more.'
FB="$(fake_claude_json "$TMP/b5b" "$CHATTY")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-chatty true "Reading the file now.")' | '$PK' display globex"
assert_rc 0 "a chatty reply exits 0"
[ "$(last_log s-chatty '.would_have_spoken')" = "false" ] && ok "prose around the JSON degrades to silence, not a crash" || fail "chatty reply mishandled"

section "peek — garbage from the model degrades to no findings"
FB="$(fake_claude_json "$TMP/b5" "Execution error, not json at all")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-garbage true "Some message text.")' | '$PK' display globex"
assert_rc 0 "garbage model output exits 0"
[ "$(last_log s-garbage '.findings | length')" = "0" ] && ok "unparseable output yields no findings" || fail "garbage produced findings"

section "peek — an empty final delta is logged, not graded (delta: no model call)"
FB="$(fake_claude_json "$TMP/b6" "$FINDING")"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-empty true "")' | '$PK' display globex"
assert_rc 0 "empty final delta exits 0"
[ "$(calls_of "$FB")" = "0" ] && ok "no model call when there is no text to grade" || fail "empty delta reached the model"
[ "$(last_log s-empty '.suppressed_by')" = "empty_message" ] && ok "records why it was skipped" || fail "empty_message not recorded"

section "peek — RECURSION GUARD fires (GRANDMA_DISTILLING=1 => nothing at all)"
FB="$(fake_claude_json "$TMP/b7" "$FINDING")"
capture env GRANDMA_DISTILLING=1 PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-guard true "I will run yarn install.")' | '$PK' display globex"
assert_rc 0 "guarded run exits 0"
[ "$(calls_of "$FB")" = "0" ] && ok "recursion guard stops the model call" || fail "guard did not stop the call"
assert_no_file "$(log_of s-guard)" "guarded run writes nothing"

section "peek — GRANDMA_NO_PEEK disables it entirely"
FB="$(fake_claude_json "$TMP/b8" "$FINDING")"
capture env GRANDMA_NO_PEEK=1 PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-off true "I will run yarn install.")' | '$PK' display globex"
assert_rc 0 "disabled run exits 0"
[ "$(calls_of "$FB")" = "0" ] && ok "kill switch stops the model call" || fail "kill switch did not stop the call"
assert_no_file "$(log_of s-off)" "kill switch writes nothing"

section "peek — COST CAP airbag trips before the model call"
FB="$(fake_claude_json "$TMP/b9" "$FINDING")"
mkdir -p "$PEEK/s-capped"
i=1; while [ "$i" -le 30 ]; do : > "$PEEK/s-capped/.run.9999.$i"; i=$((i+1)); done
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-capped true "I will run yarn install.")' | '$PK' display globex"
assert_rc 0 "capped run exits 0"
[ "$(calls_of "$FB")" = "0" ] && ok "cost cap stops the model call" || fail "cost cap did not stop the call"
[ "$(last_log s-capped '.suppressed_by')" = "cap" ] && ok "records the cap in the log" || fail "cap not recorded"

section "peek — a held lock stops the model call"
FB="$(fake_claude_json "$TMP/b10" "$FINDING")"
mkdir -p "$PEEK/s-lock/.lock"
capture env PATH="$FB:$PATH" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-lock true "I will run yarn install.")' | '$PK' display globex"
assert_rc 0 "locked run exits 0"
[ "$(calls_of "$FB")" = "0" ] && ok "held lock stops the model call" || fail "lock did not stop the call"
[ "$(last_log s-lock '.suppressed_by')" = "lock" ] && ok "records the lock in the log" || fail "lock not recorded"

section "peek — claude missing is silent, not a crash"
# GRANDMA_PEEK_CLAUDE pins the binary. Stripping PATH would not do it: claude_bin's fallback list
# is absolute, so a suite run on a machine with claude installed would reach the REAL model.
capture env GRANDMA_PEEK_CLAUDE="$TMP/no-such-claude" GRANDMA_PEEK_SYNC=1 bash -c "printf '%s' '$(md_json s-noclaude true "Some text.")' | '$PK' display globex"
assert_rc 0 "no claude available exits 0"
[ "$(last_log s-noclaude '.suppressed_by')" = "no_claude" ] && ok "records why it could not grade" || fail "no_claude not recorded"

section "peek — dry run prints the plan and makes no model call, kebab scope intact"
FB="$(fake_claude_json "$TMP/b11" "$FINDING")"
capture env GRANDMA_DRY_RUN=1 PATH="$FB:$PATH" bash -c "printf '%s' '$(md_json s-dry true "I will run yarn install.")' | '$PK' display home-ops yard"
assert_rc 0 "dry run exits 0"
assert_contains "PEEK display" "prints the plan"
assert_contains "scope:      home-ops" "carries the kebab scope through whole, not truncated to home"
assert_contains "renders:    nothing" "states that v0 renders nothing"
[ "$(calls_of "$FB")" = "0" ] && ok "dry run makes no model call" || fail "dry run called the model"

section "peek — the ledger records what ran, without tool output"
BATCH='{"session_id":"s-ledger","hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"Bash","tool_input":{"command":"yarn install"},"tool_use_id":"t1","tool_response":"SECRET-TOOL-OUTPUT-DO-NOT-KEEP"},{"tool_name":"Read","tool_input":{"file_path":"/tmp/pkg.json"},"tool_use_id":"t2","tool_response":"1\tstuff"}]}'
capture env bash -c "printf '%s' '$BATCH' | '$PK' batch globex"
assert_rc 0 "batch mode exits 0"
assert_file "$(ledger_of s-ledger)" "batch mode writes a ledger"
capture env cat "$(ledger_of s-ledger)"
assert_contains "yarn install" "records the command a claim would be about"
assert_contains "/tmp/pkg.json" "records the file a claim would be about"
assert_not_contains "SECRET-TOOL-OUTPUT-DO-NOT-KEEP" "tool output is deliberately NOT retained"

section "peek — failures are a separate sensor (PostToolBatch carries no success flag)"
FAILJ='{"session_id":"s-ledger","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_error":"exit 1"}'
capture env bash -c "printf '%s' '$FAILJ' | '$PK' fail globex"
assert_rc 0 "fail mode exits 0"
capture env cat "$(ledger_of s-ledger)"
assert_contains '"outcome":"failed"' "records the failure that a \"tests pass\" claim contradicts"

section "peek — the CLI summarises the shadow log"
capture env bash -c "'$ENGINE/bin/grandma' peek --session s-silent"
assert_rc 0 "grandma peek exits 0"
assert_contains "shadow mode" "says nothing was shown in-session"
assert_contains "would have spoken" "reports the rate that sets the thresholds"

section "peek — the CLI is clean on a home that has never run peek"
capture env GRANDMA_HOME="$TMP/empty-home" bash -c "'$ENGINE/bin/grandma' peek"
assert_rc 0 "empty home exits 0"
assert_contains "has not run yet" "explains itself rather than erroring"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_peek: PASS"; else echo "cmd_peek: $FAILS FAILURE(S)"; exit 1; fi
