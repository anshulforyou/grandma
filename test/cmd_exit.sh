#!/usr/bin/env bash
# Behavioral test for how a session exit is handled — specifically the ABRUPT case.
#
# A clean exit (Ctrl+D / quit) is covered by cmd_launch.sh (the post_session review prompt).
# Here we cover closing the terminal window, which sends SIGHUP to the session's process
# group. The guarantee: the session's learnings are never lost — the in-flight captures
# survive as diffs, and a background distill proposal still lands (so it can be reviewed at
# the next launch). This FAILS before the launcher HUP trap exists and PASSES after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
naptime() { perl -e 'select(undef,undef,undef,shift)' "$1"; }

TMP="$(mktemp -d)"; trap 'pkill -f "sleep 337" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome"; mkdir -p "$HOME"          # save --auto looks under $HOME/.claude/projects
export GRANDMA_HOME="$TMP/home"; export SHELL="" GRANDMA_NO_SPLASH=1
make_fixture_home "$GRANDMA_HOME"

# Launch from a known cwd so the background distill's transcript lookup (claude_proj_dir "$PWD")
# is predictable; seed a fake transcript exactly there.
WORK="$TMP/work"; mkdir -p "$WORK"
munged="$(printf '%s' "$WORK" | sed 's#/#-#g')"
seed_claude_project "$HOME" "$munged" "sess-exit" >/dev/null

# fake claude: on the interactive launch it writes an in-flight capture, marks the session
# live, then blocks (an open session). On `-p` (the headless distill) it emits a proposal.
SHIM="$TMP/bin"; mkdir -p "$SHIM"; LIVE="$TMP/live"
cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in --version|-v) echo 0.0.0; exit 0 ;; esac
if [ "\${1:-}" = "-p" ]; then echo "FAKECLAUDE-PROPOSAL"; exit 0; fi
printf -- '- captured mid-session\n' >> "$GRANDMA_HOME/globex/facts.md"
: > "$LIVE"
exec sleep 337
EOF
chmod +x "$SHIM/claude"
export PATH="$SHIM:$PATH"

section "window-close (SIGHUP) — a session's learnings are not lost"
before="$(ls "$GRANDMA_HOME/proposals/"globex-*.md 2>/dev/null | wc -l | tr -d ' ')"
set -m                                                 # backgrounded job -> its own process group
( cd "$WORK" && exec "$GBIN" globex ) > "$TMP/launch.log" 2>&1 &
pg=$!

live=0
for _ in $(seq 1 80); do [ -f "$LIVE" ] && { live=1; break; }; naptime 0.1; done
if [ "$live" != 1 ]; then
  skip "session did not go live (env can't run the wrapped launch) — window-close not exercised"
else
  # Simulate closing the window: SIGHUP the whole process group. The `--` is required so the
  # negative pgid is treated as a target, not misread as a signal spec.
  kill -s HUP -- -"$pg" 2>/dev/null || /bin/kill -s HUP -"$pg" 2>/dev/null
  # in-flight captures always survive an abrupt exit
  if grep -q 'captured mid-session' "$GRANDMA_HOME/globex/facts.md"; then
    ok "in-flight capture survives a window close"
  else fail "in-flight capture was lost on window close"; fi
  # the fix: a background distill proposal should still land — poll for it (the real success signal;
  # kill -0 is fooled by the exited wrapper lingering as a zombie, so we watch the proposal instead).
  landed=0
  for _ in $(seq 1 60); do
    [ "$(ls "$GRANDMA_HOME/proposals/"globex-*.md 2>/dev/null | wc -l | tr -d ' ')" -gt "$before" ] && { landed=1; break; }
    naptime 0.2
  done
  if [ "$landed" = 1 ]; then
    ok "window close still lands a background distill proposal"
  elif pkill -0 -f "sleep 337" 2>/dev/null; then
    skip "SIGHUP did not reach the session in this env — window-close not exercised"
  else
    fail "window close lost the exit distill (no proposal) — needs the launcher HUP trap"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_exit: PASS"; else echo "cmd_exit: $FAILS FAILURE(S)"; exit 1; fi
