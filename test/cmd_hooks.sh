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
export GRANDMA_HOME="$TMP/home" HOME="$TMP/user"; export SHELL=""
mkdir -p "$HOME"
make_fixture_home "$GRANDMA_HOME"
FB="$(make_fake_claude "$TMP/bin")"
TRANS="$TMP/t.jsonl"; make_fake_transcript "$TRANS"

count_proposals() { ls "$GRANDMA_HOME/proposals/"*.md 2>/dev/null | wc -l | tr -d ' '; }

section "hooks - migrate commands from other machines and preserve user hooks"
. "$ENGINE/lib/grandma-lib.sh"
CFG="$TMP/settings.local.json"
python3 - "$CFG" <<'PYCFG'
import json, sys
commands = [
    '/some/other/machine/.grandma-engine/lib/grandma-rehydrate.sh compact',
    '"/other engine/lib/grandma-rehydrate.sh" compact',
    '/other\\ engine/lib/grandma-rehydrate.sh compact',
    '"${GRANDMA_ENGINE:-$HOME/.grandma-engine}"/lib/grandma-rehydrate.sh old',
    '/user/hooks/notify.sh',
    '/user/hooks/grandma-rehydrate.sh',
    '/user/lib/grandma-rehydrate.sh.backup',
    '/user/lib/my-grandma-rehydrate.sh',
]
json.dump({"hooks": {"SessionStart": [{"matcher": "compact", "hooks": [
    {"type": "command", "command": c} for c in commands]}]}}, open(sys.argv[1], "w"))
PYCFG
CMD="$(hook_cmd "$REHY" home-ops "yard (Back Garden)")"
capture install_hook "$CFG" SessionStart compact "$REHY" "$CMD" 15 0
assert_rc 0 "migrating old hook commands writes settings"
capture python3 - "$CFG" <<'PYCFG'
import json, sys
commands = [h['command'] for g in json.load(open(sys.argv[1]))['hooks']['SessionStart'] for h in g['hooks']]
expected = '"${GRANDMA_ENGINE:-$HOME/.grandma-engine}"/lib/grandma-rehydrate.sh home-ops yard\\ \\(Back\\ Garden\\)'
assert commands == [
    '/user/hooks/notify.sh', '/user/hooks/grandma-rehydrate.sh',
    '/user/lib/grandma-rehydrate.sh.backup', '/user/lib/my-grandma-rehydrate.sh', expected,
], commands
PYCFG
assert_rc 0 "one portable rehydrate command replaces all old forms and user hooks survive"
cp "$CFG" "$TMP/settings.before"
inode="$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$CFG")"
capture install_hook "$CFG" SessionStart compact "$REHY" "$CMD" 15 0
assert_rc 1 "a second install returns 1"
capture cmp "$CFG" "$TMP/settings.before"
assert_rc 0 "a second install leaves settings byte-for-byte unchanged"
capture python3 -c 'import os,sys; assert str(os.stat(sys.argv[1]).st_ino) == sys.argv[2]' "$CFG" "$inode"
assert_rc 0 "a second install does not replace the settings file"

section "hooks - written commands resolve the engine at runtime"
STUB_ENGINE="$TMP/custom engine"
mkdir -p "$STUB_ENGINE/lib" "$HOME/.grandma-engine/lib"
cat > "$STUB_ENGINE/lib/grandma-rehydrate.sh" <<'SH'
#!/bin/sh
set -eu
printf 'stub ran: <%s> <%s>\n' "$1" "$2"
SH
chmod +x "$STUB_ENGINE/lib/grandma-rehydrate.sh"
cp "$STUB_ENGINE/lib/grandma-rehydrate.sh" "$HOME/.grandma-engine/lib/grandma-rehydrate.sh"
# Read the command actually written into settings, including its quoted arguments.
WRITTEN="$(jq -r '.hooks.SessionStart[-1].hooks[0].command' "$CFG")"
capture env GRANDMA_ENGINE="$STUB_ENGINE" sh -uc "$WRITTEN"
assert_rc 0 "the written command runs with GRANDMA_ENGINE set"
assert_contains 'stub ran: <home-ops> <yard (Back Garden)>' "runtime engine receives the original arguments"
capture env -u GRANDMA_ENGINE sh -uc "$WRITTEN"
assert_rc 0 "the written command runs from the default engine under temporary HOME"
assert_contains 'stub ran: <home-ops> <yard (Back Garden)>' "default engine receives the original arguments"

section "hooks - launcher exports its resolved engine and installs all three portable commands"
mkdir -p "$TMP/launch-bin"
cat > "$TMP/launch-bin/claude" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  --help) echo '--append-system-prompt-file'; exit 0 ;;
esac
printf '%s' "${GRANDMA_ENGINE:-unset}" > "$HOME/session-engine"
SH
chmod +x "$TMP/launch-bin/claude"
capture env -u GRANDMA_ENGINE PATH="$TMP/launch-bin:$PATH" GRANDMA_NO_SPLASH=1 \
  GRANDMA_NO_KNIT_CHECK=1 GRANDMA_NO_UPDATE_CHECK=1 "$ENGINE/bin/grandma" globex billing </dev/null
assert_rc 0 "a session launches with the harmless shim"
capture cat "$HOME/session-engine"
[ "$LAST_OUT" = "$ENGINE" ] && ok "the session inherits the resolved GRANDMA_ENGINE" \
  || fail "the session did not inherit the resolved GRANDMA_ENGINE" "$LAST_OUT"
capture python3 - "$GRANDMA_HOME/projects/billing-api/.claude/settings.local.json" <<'PYCFG'
import json, sys
hooks = json.load(open(sys.argv[1]))['hooks']
for event, script in [('SessionStart', 'rehydrate'), ('SessionEnd', 'session-end'), ('PreCompact', 'precompact')]:
    command = hooks[event][0]['hooks'][0]['command']
    assert command.startswith('"${GRANDMA_ENGINE:-$HOME/.grandma-engine}"/lib/grandma-' + script + '.sh '), command
PYCFG
assert_rc 0 "all three launcher hook commands use runtime engine expansion"

section "rehydrate - only the session note is emitted even with a large bundle"
mkdir -p "$GRANDMA_HOME/.compact"
printf '== working state ==\nTask: wire the webhook retry\n' > "$GRANDMA_HOME/.compact/ses-xyz.md"
python3 - "$GRANDMA_HOME/globex/facts.md" <<'PYNOTE'
import sys
with open(sys.argv[1], 'a') as f:
    f.write('BUNDLE-MUST-NOT-RETURN\n' * 3200)
PYNOTE
rehydrate() { printf '{"session_id":"%s"}' "$1" | "$REHY" "${2:-globex}" "${@:3}"; }
capture rehydrate ses-xyz
assert_rc 0 "rehydrate with a large bundle and a session note runs"
printf '%s' "$LAST_OUT" > "$TMP/rehydrate.json"
capture python3 - "$TMP/rehydrate.json" "$GRANDMA_HOME/.compact/ses-xyz.md" <<'PYNOTE'
import json, sys
out = json.load(open(sys.argv[1]))['hookSpecificOutput']
assert out['hookEventName'] == 'SessionStart'
ctx = out['additionalContext']
assert len(ctx) < 9000, len(ctx)
assert ctx == '===== SESSION CONTINUITY (restored after compaction) =====\n' + open(sys.argv[2]).read()
assert 'BUNDLE-MUST-NOT-RETURN' not in ctx
PYNOTE
assert_rc 0 "context contains exactly the one-line header and note with no bundle or doctrine"
capture rehydrate ses-xyz home-ops --raw
assert_rc 0 "raw output still works with a kebab scope"
assert_contains "wire the webhook retry" "raw output carries the note"
assert_not_contains "GRANDMA MEMORY" "raw output does not carry a memory bundle"

section "rehydrate - oversized notes are capped at complete lines"
for shape in lines single boundary; do
  python3 - "$GRANDMA_HOME/.compact/ses-large.md" "$shape" <<'PYNOTE'
import sys
header = '===== SESSION CONTINUITY (restored after compaction) =====\n'
notes = {'lines': ('complete line ' + chr(233) * 65 + '\n') * 200,
         'single': 'x' * 20000,
         'boundary': 'x' * (9000 - len(header) - 1) + '\n'}
with open(sys.argv[1], 'w') as f:
    f.write(notes[sys.argv[2]])
PYNOTE
  capture rehydrate ses-large
  assert_rc 0 "rehydrate handles a $shape note"
  printf '%s' "$LAST_OUT" > "$TMP/rehydrate.json"
  capture python3 - "$TMP/rehydrate.json" "$GRANDMA_HOME/.compact/ses-large.md" <<'PYNOTE'
import json, sys
ctx = json.load(open(sys.argv[1]))['hookSpecificOutput']['additionalContext']
header = '===== SESSION CONTINUITY (restored after compaction) =====\n'
full = header + open(sys.argv[2]).read()
marker = '[grandma] Continuity note truncated.\n'
assert len(ctx) <= 9000, len(ctx)
if len(full) <= 9000:
    assert ctx == full
else:
    assert ctx.endswith(marker), ctx[-100:]
    prefix = ctx[:-len(marker)]
    assert prefix.endswith('\n')
    if '\n' in full[len(header):9000]:
        assert full.startswith(prefix)
        assert len(prefix + full[len(prefix):].split('\n')[0] + '\n' + marker) > 9000
    else:
        # a note with no line break to cut at is cut hard, so its content still arrives
        assert full.startswith(prefix[:-1]) and len(prefix) > 8000, len(prefix)
PYNOTE
  assert_rc 0 "the $shape note respects the cap and keeps complete lines with a truncation notice when needed"
done

section "rehydrate - no note means no context"
for sid in ses-none ''; do
  for mode in json raw; do
    if [ "$mode" = raw ]; then capture rehydrate "$sid" globex --raw
    else capture rehydrate "$sid"; fi
    assert_rc 0 "missing note or session id exits 0 ($sid, $mode)"
    [ -z "$LAST_OUT" ] && ok "no context is emitted ($sid, $mode)" \
      || fail "unexpected context without a session note ($sid, $mode)"
  done
done

section "rehydrate - a long session is asked to hand over to a fresh one"
printf '== working state ==\nTask: ship the sitemap\n' > "$GRANDMA_HOME/.compact/ses-long.md"
echo 2 > "$GRANDMA_HOME/.compact/ses-long.count"
capture rehydrate ses-long globex --raw
assert_not_contains "FRESH SESSION" "two compactions in a young session: no handover yet"
echo 3 > "$GRANDMA_HOME/.compact/ses-long.count"
capture env GRANDMA_PROJECT=billing GRANDMA_LAUNCH_DIR=/work/billing bash -c \
  'printf "{\"session_id\":\"ses-long\"}" | "$1" globex --raw' _ "$REHY"
assert_contains "ship the sitemap" "the continuity note still comes back"
assert_contains "TIME FOR A FRESH SESSION" "a third compaction asks for a fresh session"
assert_contains "$GRANDMA_HOME/.handoff/globex__work-billing.md" "the handoff goes where the next launch in that folder looks"
assert_contains "cd /work/billing && grandma globex billing" "the fresh session is the same sweater and project"
python3 -c 'import datetime;print("{\"timestamp\":\"%s\",\"type\":\"user\"}" % (datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=25)).isoformat())' > "$TMP/old.jsonl"
capture env GRANDMA_LAUNCH_DIR=/work/billing bash -c \
  'printf "{\"session_id\":\"ses-none\",\"transcript_path\":\"%s\"}" "$2" | "$1" globex --raw' _ "$REHY" "$TMP/old.jsonl"
assert_contains "has run 25 hours" "a session open a day is asked to hand over even with no note"
rm -f "$GRANDMA_HOME/.compact/ses-long.count"

section "rehydrate - a formatter failure cannot fail the session"
mkdir -p "$TMP/broken-python"
printf '#!/bin/sh\nexit 7\n' > "$TMP/broken-python/python3"
chmod +x "$TMP/broken-python/python3"
capture env PATH="$TMP/broken-python:$PATH" bash -c \
  'printf "{\"session_id\":\"ses-xyz\"}" | "$1" globex' _ "$REHY"
assert_rc 0 "a failed context formatter still exits 0"
[ -z "$LAST_OUT" ] && ok "a failed formatter emits no context" \
  || fail "a failed formatter emitted context" "$LAST_OUT"

section "rehydrate - missing scope arg keeps the usage guard"
capture env bash -c '"$1" </dev/null' _ "$REHY"
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

section "session-end — DEFER guard (GRANDMA_DEFER_DISTILL=1 -> launcher handles it, no spawn)"
before="$(count_proposals)"
capture env GRANDMA_DEFER_DISTILL=1 PATH="$FB:$PATH" bash -c \
  "printf '{\"reason\":\"other\",\"transcript_path\":\"$TRANS\"}' | '$SEND' globex billing"
assert_rc 0 "session-end defers cleanly when the launcher owns the distill"
[ "$(count_proposals)" = "$before" ] && ok "deferred hook does not spawn a background distill" \
                                     || fail "deferred hook spawned a distill anyway"

section "session-end - normal end spawns a distill with fake claude"
before="$(count_proposals)"
env -u GRANDMA_DEFER_DISTILL PATH="$FB:$PATH" bash -c \
  "printf '{\"reason\":\"other\",\"transcript_path\":\"$TRANS\"}' | '$SEND' globex billing" >/dev/null 2>&1
proposal_landed() { [ "$(count_proposals)" -gt "$before" ]; }
if wait_until 10 proposal_landed; then ok "normal SessionEnd distills a proposal in the background"
else fail "background distill did not land within timeout"; fi

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_hooks: PASS"; else echo "cmd_hooks: $FAILS FAILURE(S)"; exit 1; fi
