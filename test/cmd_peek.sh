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
export GRANDMA_HOME="$TMP/home" HOME="$TMP/user"; export SHELL=""
mkdir -p "$HOME"
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

section "peek - deterministic checks and replay"
if python3 "$HERE/lib/peek_engine.py"; then
  ok "deterministic checks and replay"
else
  fail "deterministic checks and replay"
fi

# ---------------------------------------------------------------------------------------------
# peek rules: memory becomes checks only through a typed yes. Runs after the engine tests, which
# leave their own facts and checks behind, so this section seeds what it needs.
G="$ENGINE/bin/grandma"
YARD="$GRANDMA_HOME/projects/yard"
mkdir -p "$YARD"
printf '# yard\n- never use the leaf blower before 9am\n- never mow wet grass\n' > "$YARD/CLAUDE.md"
printf -- '---\nscope: home-ops\ntype: facts\n---\n- trash goes out Sunday night\n' > "$GRANDMA_HOME/home-ops/facts.md"
rm -rf "$GRANDMA_HOME/home-ops/peek" "$PEEK/candidates" "$PEEK/rules"
CAND="$PEEK/candidates/home-ops/Yard.json"
CHK="$GRANDMA_HOME/home-ops/peek/Yard.json"

# Seven proposals, fenced and wrapped in prose the way models answer. Only two are sound.
RULES_REPLY='Here are the checks:
```json
{"checks":[
{"id":"No Blower!","kind":"forbid_command","cite":"never use the leaf blower before 9am","file":"project:CLAUDE.md","instead":"Rake by hand","match":"leaf-blower"},
{"id":"wet","kind":"forbid_command","cite":"never mow wet grass!!","file":"project:CLAUDE.md","instead":"Use the trimmer","match":"mow"},
{"id":"vibes","kind":"forbid_vibes","cite":"never mow wet grass","file":"project:CLAUDE.md","instead":"Use the trimmer"},
{"id":"bad","kind":"forbid_command","cite":"never mow wet grass","file":"project:CLAUDE.md","instead":"Use the trimmer","match":"("},
{"id":"waity","kind":"forbid_command","cite":"never mow wet grass","file":"project:CLAUDE.md","instead":"Wait until it dries","match":"mow"},
{"id":"Mow Reminder","kind":"recall_on","cite":"never mow wet grass","file":"project:CLAUDE.md","instead":"Check the lawn is dry","trigger":{"tool":"Bash","match":"mower"}},
{"id":"trash","kind":"recall_on","cite":"trash goes out Sunday night","file":"home-ops/facts.md","instead":"Put the bins out","trigger":{"tool":"Bash","match":"trash"}}
]}
```'

section "peek rules build - dry run makes no call"
FR="$(fake_claude_json "$TMP/r0" "$RULES_REPLY")"
capture env GRANDMA_PEEK_CLAUDE="$FR/claude" GRANDMA_DRY_RUN=1 "$G" peek rules build home-ops yard
assert_rc 0 "dry run exits 0"
assert_contains "PEEK rules build" "prints the plan"
assert_not_contains "unbound variable" "survives set -u"
[ "$(calls_of "$FR")" = "0" ] && ok "dry run never reaches the model" || fail "dry run called the model"
assert_no_file "$CAND" "dry run writes no candidates"

section "peek rules build - only sound proposals survive, none enforce"
capture env GRANDMA_PEEK_CLAUDE="$FR/claude" "$G" peek rules build home-ops yard
assert_rc 0 "build exits 0"
assert_not_contains "unbound variable" "survives set -u"
assert_contains "7 proposed, 2 kept" "keeps the two sound checks of seven"
assert_contains "cite not verbatim in memory" "drops a cite that is not word for word in memory"
assert_contains "unknown kind" "drops an unknown kind"
assert_contains "pattern does not compile" "drops a pattern that does not compile"
assert_contains "instead is not an action" "drops an instead that only says to wait"
assert_contains "not from the project file" "a project build drops a sweater rule, which belongs in the sweater file"
[ "$(jq -r '[.[].id]|join(",")' "$CAND")" = "no-blower,mow-reminder" ] && ok "candidate ids are slugged" || fail "candidate ids" "$(cat "$CAND")"
[ "$(jq -r '[.[].mode]|unique|join(",")' "$CAND")" = "shadow" ] && ok "every candidate is shadow" || fail "candidate modes"
assert_no_file "$CHK" "a build writes no checks file"
assert_no_file "$PEEK/rules/.lock" "the lock is released after a build"
capture bash -c "printf '%s' '{\"session_id\":\"r-unapproved\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"leaf-blower --on\"},\"cwd\":\"$YARD\"}' | python3 '$ENGINE/lib/grandma-peek-engine.py' pre home-ops Yard"
[ -z "$LAST_OUT" ] && ok "an unapproved candidate never denies" || fail "unapproved candidate acted" "$LAST_OUT"

section "peek rules - the launch notice names what is waiting"
capture bash -c "ROOT='$GRANDMA_HOME'; source '$ENGINE/lib/grandma-lib.sh'; grandma_peek_notice home-ops Yard"
assert_contains "2 proposed peek check(s) waiting," "launch says how many are waiting"
assert_contains "grandma peek rules review home-ops Yard" "and how to review them"

section "peek rules review - no answer approves nothing"
capture bash -c "'$G' peek rules review home-ops yard < /dev/null"
assert_rc 0 "review on closed stdin exits 0"
assert_no_file "$CHK" "closed stdin approves nothing"
[ "$(jq length "$CAND")" = "2" ] && ok "unanswered candidates stay pending" || fail "candidates lost on closed stdin"

capture bash -c "printf '\n\n' | '$G' peek rules review home-ops yard"
assert_no_file "$CHK" "pressing Enter approves nothing"
[ "$(jq length "$CAND")" = "2" ] && ok "skipped candidates stay pending" || fail "Enter dropped a candidate"

section "peek rules review - y approves, n rejects, history is shown"
TR="$TMP/transcripts"; mkdir -p "$TR"
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-07T10:00:00Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"leaf-blower --on"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}' 'not json' > "$TR/old.jsonl"
capture bash -c "printf 'y\nn\n' | GRANDMA_PEEK_TRANSCRIPTS='$TR' '$G' peek rules review home-ops yard"
assert_rc 0 "review exits 0"
assert_contains "would have blocked 1 time(s) in the last 1 session(s)" "shows what the check would have blocked in past sessions"
assert_contains "leaf-blower --on" "quotes the call it would have blocked"
assert_contains "would have reminded 0 time(s)" "a reminder check reports reminders, not blocks"
[ "$(jq -r '[.checks[].id]|join(",")' "$CHK")" = "no-blower" ] && ok "only the approved check is written" || fail "checks file" "$(cat "$CHK")"
[ "$(jq -r '.checks[0].mode' "$CHK")" = "shadow" ] && ok "an approved check starts in shadow" || fail "approved mode"
[ "$(jq length "$CAND")" = "0" ] && ok "answered candidates leave the queue" || fail "queue not drained"

section "peek rules build - a rebuild skips what was approved or rejected"
capture env GRANDMA_PEEK_CLAUDE="$FR/claude" "$G" peek rules build home-ops yard
assert_contains "7 proposed, 0 kept" "nothing already answered is proposed again"
assert_contains "already approved" "names the approved one"
assert_contains "rejected before" "names the rejected one"

section "peek rules - list and mode"
capture "$G" peek rules home-ops yard
assert_rc 0 "list exits 0"
assert_contains "no-blower" "lists the approved check"
assert_contains "shadow" "with its mode"
capture "$G" peek mode home-ops yard no-blower enforce
assert_rc 0 "mode exits 0"
[ "$(jq -r '.checks[0].mode' "$CHK")" = "enforce" ] && ok "mode flips one check to enforce" || fail "mode did not flip"
capture bash -c "printf '%s' '{\"session_id\":\"r-enforced\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"leaf-blower --on\"},\"cwd\":\"$YARD\"}' | python3 '$ENGINE/lib/grandma-peek-engine.py' pre home-ops Yard"
assert_contains '"permissionDecision":"deny"' "an approved, enforced check denies"
capture "$G" peek mode home-ops yard nope enforce
[ "$LAST_RC" -ne 0 ] && ok "an unknown id is an error" || fail "unknown id accepted"
printf '# yard\n- never mow wet grass\n' > "$YARD/CLAUDE.md"
capture "$G" peek rules home-ops yard
assert_contains "STALE" "a check whose line left memory is listed as stale"

section "peek rules build - the prompt carries the project first and what really ran"
# A shim that keeps the system prompt it was handed, file or inline, so the test can read it.
FP="$TMP/rp"; mkdir -p "$FP"
cat > "$FP/claude" <<'FPEOF'
#!/usr/bin/env bash
case "${1:-}" in --version|-v) echo "0.0.0 (fake)"; exit 0 ;; --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;; esac
dir="$(cd "$(dirname "$0")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --append-system-prompt-file) cp "$2" "$dir/.prompt"; shift ;;
    --append-system-prompt) printf '%s' "$2" > "$dir/.prompt"; shift ;;
  esac
  shift
done
echo '{"checks":[]}'
FPEOF
chmod +x "$FP/claude"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"cd /x && python3 rake.py --yard 0123456789abcdef0123 && python3 - <<EOF\nprint(1)\n# a long inline step that pads this command well past the cut so the named step is hidden from the digest head\ncall(\"leaf-blower\")\nEOF"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s2","name":"Bash","input":{"command":"curl -H \"Authorization: Bearer sk-live-PLANTEDSECRET1234\" https://api.example/x?token=PLANTEDTOKEN99"}}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s3","name":"Write","input":{"file_path":"/x/notes/today.md","content":"hi"}}]}}' > "$TR/shapes.jsonl"
printf '# yard\n- never run the `leaf-blower` before 9am\n' > "$YARD/CLAUDE.md"
capture env GRANDMA_PEEK_CLAUDE="$FP/claude" GRANDMA_PEEK_TRANSCRIPTS="$TR" "$G" peek rules build home-ops yard
assert_rc 0 "build with observed commands exits 0"
PROMPT="$(cat "$FP/.prompt" 2>/dev/null)"
case "$PROMPT" in *"MODE: project"*) ok "the prompt says it is a project build" ;; *) fail "no project mode line" ;; esac
case "$PROMPT" in *"PROJECT INSTRUCTIONS"*"BEGIN project:CLAUDE.md"*"OTHER MEMORY"*) ok "the project file comes before the rest of memory" ;; *) fail "project file not first" ;; esac
case "$PROMPT" in *"python3 rake.py --yard <id>"*) ok "observed commands reach the prompt, ids folded" ;; *) fail "observed command missing" "$(printf '%s' "$PROMPT" | grep -n rake)" ;; esac
case "$PROMPT" in *"[later in it: leaf-blower]"*) ok "a named step past the cut is still listed" ;; *) fail "hidden named step lost" ;; esac
case "$PROMPT" in *"/x/notes/today.md"*) ok "files written are listed" ;; *) fail "written file missing" ;; esac
case "$PROMPT" in *PLANTEDSECRET*|*PLANTEDTOKEN*) fail "a secret reached the model" ;; *) ok "bearer and token values are redacted before the call" ;; esac

section "peek rules - the checks file is named for the heading's first word"
SHED="$GRANDMA_HOME/projects/shed"; mkdir -p "$SHED"
printf '# shed\n- never run the table saw without the guard\n' > "$SHED/CLAUDE.md"
printf '\n## Shed (Q3 rebuild, tools | v2)\n- source: %s/CLAUDE.md\n' "$SHED" >> "$GRANDMA_HOME/home-ops/projects.md"
SHED_REPLY='{"checks":[{"id":"saw","kind":"forbid_command","cite":"never run the table saw without the guard","file":"project:CLAUDE.md","instead":"Fit the guard, then cut","match":"table-saw"}]}'
FS="$(fake_claude_json "$TMP/r2" "$SHED_REPLY")"
capture env GRANDMA_PEEK_CLAUDE="$FS/claude" "$G" peek rules build home-ops shed
assert_rc 0 "build for a heading with spaces, brackets and a pipe exits 0"
assert_file "$PEEK/candidates/home-ops/Shed.json" "candidates are named Shed.json"
assert_contains "review home-ops Shed" "the review hint is a command that can be typed"
capture bash -c "ROOT='$GRANDMA_HOME'; source '$ENGINE/lib/grandma-lib.sh'; grandma_peek_notice home-ops 'Shed (Q3 rebuild, tools | v2)'"
assert_contains "review home-ops Shed" "the launch notice takes the full heading and names the short one"
printf 'y\n' | "$G" peek rules review home-ops shed >/dev/null 2>&1
assert_file "$GRANDMA_HOME/home-ops/peek/Shed.json" "approving writes Shed.json"
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-07T10:00:00Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"table-saw --cut"}}]}}' > "$TMP/shed.jsonl"
capture python3 "$ENGINE/lib/grandma-peek-engine.py" replay "$TMP/shed.jsonl" --scope home-ops --project shed --json
[ "$(printf '%s' "$LAST_OUT" | jq -r '[.. | .would_deny? // empty] | add // 0' 2>/dev/null)" = "1" ] && ok "replay finds the project file by the short name" || fail "replay by short name" "$LAST_OUT"
capture bash -c "printf '%s' '{\"session_id\":\"r-shed\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"table-saw --cut\"},\"cwd\":\"$SHED\"}' | python3 '$ENGINE/lib/grandma-peek-engine.py' pre home-ops 'Shed (Q3 rebuild, tools | v2)'"
assert_not_contains '"permissionDecision":"deny"' "a hook given the full heading reads Shed.json (shadow, so no deny)"
[ -s "$PEEK/r-shed/decisions.jsonl" ] && ok "and logs a shadow decision for it" || fail "hook with the full heading found no checks"

LB="$TMP/launch-bin"; mkdir -p "$LB"
printf '#!/bin/sh\ncase "${1:-}" in --help) echo --append-system-prompt-file ;; esac\nexit 0\n' > "$LB/claude"; chmod +x "$LB/claude"
capture env PATH="$LB:$PATH" GRANDMA_NO_SPLASH=1 GRANDMA_NO_KNIT_CHECK=1 GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_AUTOSAVE=1 "$G" home-ops shed </dev/null
case "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SHED/.claude/settings.local.json" 2>/dev/null)" in *"grandma-peek-engine.py pre home-ops Shed 2>/dev/null || true") true ;; *) false ;; esac \
  && ok "launching the project installs the peek hooks against Shed.json" || fail "peek hooks for a spaced heading" "$(cat "$SHED/.claude/settings.local.json" 2>/dev/null)"

printf '\n## Shed (old one)\n- source: %s/CLAUDE.md\n' "$SHED" >> "$GRANDMA_HOME/home-ops/projects.md"
FC="$(fake_claude_json "$TMP/r3" "$SHED_REPLY")"
capture env GRANDMA_PEEK_CLAUDE="$FC/claude" "$G" peek rules build home-ops "Shed (Q3"
[ "$LAST_RC" -ne 0 ] && ok "two headings with one first word are refused" || fail "collision accepted"
assert_contains "would share one checks file" "and says why"
[ "$(calls_of "$FC")" = "0" ] && ok "no model call for a colliding name" || fail "collision reached the model"

section "peek rules build - a sweater build keeps sweater rules"
capture env GRANDMA_PEEK_CLAUDE="$FR/claude" "$G" peek rules build home-ops
assert_rc 0 "sweater build exits 0"
[ "$(jq -r '[.[].id]|join(",")' "$PEEK/candidates/home-ops/_sweater.json" 2>/dev/null)" = "trash" ] && ok "only the sweater rule is kept" || fail "sweater candidates" "$(cat "$PEEK/candidates/home-ops/_sweater.json" 2>/dev/null)"

section "peek rules build - guards stop the call (delta)"
rm -rf "$PEEK/rules"
FG="$(fake_claude_json "$TMP/r1" "$RULES_REPLY")"
capture env GRANDMA_PEEK_CLAUDE="$FG/claude" GRANDMA_DISTILLING=1 "$G" peek rules build home-ops yard
[ "$(calls_of "$FG")" = "0" ] && ok "recursion guard: no call under GRANDMA_DISTILLING" || fail "recursion guard let a call through"
mkdir -p "$PEEK/rules/.lock"
capture env GRANDMA_PEEK_CLAUDE="$FG/claude" "$G" peek rules build home-ops yard
[ "$(calls_of "$FG")" = "0" ] && ok "lock: no call while another build holds it" || fail "lock let a call through"
assert_contains "another build is running" "says why"
touch -t 202001010000 "$PEEK/rules/.lock"
capture env GRANDMA_PEEK_CLAUDE="$FG/claude" "$G" peek rules build home-ops yard
[ "$(calls_of "$FG")" = "1" ] && ok "a stale lock is taken over (the guard is the lock, not luck)" || fail "stale lock blocked the build"
capture env GRANDMA_PEEK_CLAUDE="$FG/claude" GRANDMA_PEEK_RULES_CAP=1 "$G" peek rules build home-ops yard
[ "$(calls_of "$FG")" = "1" ] && ok "cost cap: no call once the hourly cap is reached" || fail "cost cap let a call through"
capture env GRANDMA_PEEK_CLAUDE="$FG/claude" GRANDMA_PEEK_RULES_CAP=2 "$G" peek rules build home-ops yard
[ "$(calls_of "$FG")" = "2" ] && ok "under the cap the call goes through" || fail "cap blocked a call under the limit"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_peek: PASS"; else echo "cmd_peek: $FAILS FAILURE(S)"; exit 1; fi
