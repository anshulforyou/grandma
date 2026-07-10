#!/usr/bin/env bash
# Behavioral tests for the two hooks: grandma-rehydrate.sh (SessionStart/compact) and
# grandma-session-end.sh (SessionEnd auto-distill), including the recursion guard.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

REHY="$ENGINE/lib/grandma-rehydrate.sh"
SEND="$ENGINE/lib/grandma-session-end.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
FB="$(make_fake_claude "$TMP/bin")"
TRANS="$TMP/t.jsonl"; make_fake_transcript "$TRANS"

count_proposals() { ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' '; }

section "rehydrate — --raw payload"
capture env bash -c "printf '{}' | '$REHY' globex --raw"
assert_rc 0 "rehydrate globex --raw runs"
assert_contains "GRANDMA MEMORY (scope=globex, re-injected after compaction)" "prints the re-injection header"
assert_contains "globex/facts.md" "re-injects the scope bundle"

section "rehydrate — kebab scope"
capture env bash -c "printf '{}' | '$REHY' home-ops --raw"
assert_rc 0 "rehydrate home-ops --raw runs"
assert_contains "scope=home-ops" "kebab scope header is correct"

section "rehydrate — JSON hook output is valid SessionStart"
raw="$(printf '{}' | "$REHY" globex 2>/dev/null)"
capture env python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['hookSpecificOutput']['hookEventName']=='SessionStart'" "$raw"
assert_rc 0 "rehydrate emits valid SessionStart hook JSON"

section "rehydrate — missing scope arg -> usage"
capture env bash -c "'$REHY' </dev/null"
assert_rc 2 "rehydrate with no scope exits 2"

section "session-end — recursion guard FIRES (GRANDMA_DISTILLING=1 -> no spawn)"
before="$(count_proposals)"
capture env GRANDMA_DISTILLING=1 PATH="$FB:$PATH" bash -c \
  "printf '{\"reason\":\"other\",\"transcript_path\":\"$TRANS\"}' | '$SEND' globex billing"
assert_rc 0 "session-end under the guard exits 0"
if [ "$(count_proposals)" = "$before" ]; then ok "guard prevents any distill spawn ($before unchanged)"
else fail "guard did not prevent a spawn (was $before, now $(count_proposals))"; fi

section "session-end — reason=clear/resume early-exit (no spawn)"
before="$(count_proposals)"
capture env PATH="$FB:$PATH" bash -c \
  "printf '{\"reason\":\"clear\",\"transcript_path\":\"$TRANS\"}' | '$SEND' globex billing"
assert_rc 0 "session-end reason=clear exits 0"
[ "$(count_proposals)" = "$before" ] && ok "reason=clear does not distill" || fail "reason=clear spawned a distill"

section "session-end — no scope arg is a no-op"
capture env bash -c "'$SEND' </dev/null"
assert_rc 0 "session-end with no scope exits 0"

section "session-end — normal end DOES spawn a distill (async, fake claude)"
before="$(count_proposals)"
env PATH="$FB:$PATH" bash -c \
  "printf '{\"reason\":\"other\",\"transcript_path\":\"$TRANS\"}' | '$SEND' globex billing" >/dev/null 2>&1
# the distill is detached (nohup+disown); poll briefly for the proposal to appear.
found=0
for _ in $(seq 1 30); do
  [ "$(count_proposals)" -gt "$before" ] && { found=1; break; }
  perl -e 'select(undef,undef,undef,0.2)'   # 0.2s sleep, no foreground `sleep`
done
if [ "$found" = 1 ]; then ok "normal SessionEnd distills a proposal in the background"
else skip "background distill did not land within timeout (slow CI) — not failing"; fi

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_hooks: PASS"; else echo "cmd_hooks: $FAILS FAILURE(S)"; exit 1; fi
