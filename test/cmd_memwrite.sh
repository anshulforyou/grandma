#!/usr/bin/env bash
# Behavioral tests for grandma-memwrite-check.sh (PreToolUse on Write/Edit/MultiEdit): the
# always-loaded memory files refuse over-long lines and copies of a line they already hold.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

CHECK="$ENGINE/lib/grandma-memwrite-check.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home" HOME="$TMP/user"
mkdir -p "$HOME"
make_fixture_home "$GRANDMA_HOME"
FACTS="$GRANDMA_HOME/globex/facts.md"
LONGFACT="- THE BILLING RETRY IS A CLOCK BUG, NOT DATA (found 2026-10-27): the retry worker reads the server clock"
printf -- '%s\n' "$LONGFACT" >> "$FACTS"

# check <json tool_input> [tool]: run the hook the way Claude Code does
check() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[1])}))' \
    "$1" "${2:-Edit}" | "$CHECK"
}
denied() { [[ "$LAST_OUT" == *'"permissionDecision": "deny"'* ]]; }
edit_json() { python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "old_string": sys.argv[2], "new_string": sys.argv[3]}))' "$@"; }

section "memwrite - a copy of an existing line is refused"
capture check "$(edit_json "$FACTS" "$LONGFACT" "$LONGFACT
$LONGFACT")"
assert_rc 0 "the check exits 0"
denied && ok "appending the same note again is denied" || fail "duplicate allowed" "$LAST_OUT"
assert_contains "Update the existing line in place" "the reason says what to do instead"
capture check "$(edit_json "$FACTS" "$LONGFACT" "$LONGFACT
${LONGFACT}, and the fix landed in retry.go")"
denied && ok "a near copy (same first 80 chars) is denied too" || fail "near duplicate allowed" "$LAST_OUT"

section "memwrite - an over-long line is refused, a short one passes"
capture check "$(edit_json "$FACTS" "$LONGFACT" "$LONGFACT
- $(printf 'pose research detail %.0s' {1..30})")"
denied && ok "a 600-char line is denied" || fail "long line allowed" "$LAST_OUT"
assert_contains "notes/" "the reason points long detail to notes/"
capture check "$(edit_json "$FACTS" "$LONGFACT" "- The billing retry reads the server clock, fixed in retry.go (2026-10-29).")"
assert_rc 0 "rewriting the line in place exits 0"
[ -z "$LAST_OUT" ] && ok "a short in-place update passes silently" || fail "short update denied" "$LAST_OUT"

section "memwrite - files that do not load into every session are left alone"
mkdir -p "$GRANDMA_HOME/globex/notes" "$GRANDMA_HOME/globex/log"
for f in "$GRANDMA_HOME/globex/notes/pose.md" "$GRANDMA_HOME/globex/log/2026-10-29.md" "$TMP/elsewhere.md"; do
  capture check "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "content": sys.argv[2]*2}))' "$f" "$LONGFACT$LONGFACT$LONGFACT$LONGFACT
")" Write
  [ -z "$LAST_OUT" ] && ok "no check on ${f#"$TMP"/}" || fail "checked a file outside the loaded set" "$f"
done

section "memwrite - Write and MultiEdit are judged on the file they would leave"
capture check "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "content": open(sys.argv[1]).read() + sys.argv[2] + "\n"}))' "$FACTS" "$LONGFACT")" Write
denied && ok "a Write that repeats a line is denied" || fail "Write duplicate allowed" "$LAST_OUT"
capture check "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "edits": [{"old_string": sys.argv[2], "new_string": sys.argv[2] + "\n- a fresh short rule"}]}))' "$FACTS" "$LONGFACT")" MultiEdit
[ -z "$LAST_OUT" ] && ok "a MultiEdit adding one short new rule passes" || fail "clean MultiEdit denied" "$LAST_OUT"

section "memwrite - bad input never blocks the tool"
capture bash -c 'echo "not json" | "$1"' _ "$CHECK"
assert_rc 0 "garbage on stdin exits 0"
[ -z "$LAST_OUT" ] && ok "and denies nothing" || fail "garbage produced output" "$LAST_OUT"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_memwrite: PASS"; else echo "cmd_memwrite: $FAILS FAILURE(S)"; exit 1; fi
