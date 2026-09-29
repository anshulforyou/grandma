#!/usr/bin/env bash
# Behavioral test for per-sweater MCP binding.
#
# The promise: a sweater's MCP servers reach every project in that sweater and no other sweater.
# Anything it does not bind falls through to the account's own connectors, and a sweater that
# asks for strict gets the CLI's --strict-mcp-config and nothing else. Composition order is the design: global servers
# enter under their own names, a sweater server of the same name replaces the global one for that
# sweater, and sweater servers are renamed last. Renaming last is what lets both rules hold, and
# it is also what gives each sweater its own stored login, because the CLI keys an MCP credential
# by server name and URL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
export GRANDMA_HOME="$TMP/home"
export SHELL="" GRANDMA_NO_SPLASH=1 GRANDMA_NO_HOOK=1 GRANDMA_NO_AUTOSAVE=1
make_fixture_home "$GRANDMA_HOME"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — MCP composition needs it"
  echo; echo "cmd_mcp: PASS"; exit 0
fi

# A fake CLI that records exactly what it was handed.
SHIM="$TMP/bin"; mkdir -p "$SHIM"; export MCPLOG="$TMP/seen.txt"
cat > "$SHIM/claude" <<'SHIMEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;;
  --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
prev=""; strict=no; cfg=""
for a in "$@"; do
  [ "$a" = "--strict-mcp-config" ] && strict=yes
  [ "$prev" = "--mcp-config" ] && cfg="$a"
  prev="$a"
done
{ echo "strict=$strict"
  if [ -n "$cfg" ]; then echo "servers=$(jq -r '.mcpServers|keys_unsorted|sort|join(",")' "$cfg")"
  else echo "servers=<none>"; fi
} > "$MCPLOG"
exit 0
SHIMEOF
chmod +x "$SHIM/claude"
export PATH="$SHIM:$PATH"

launch() { rm -f "$MCPLOG"; ( "$GBIN" "$@" </dev/null >/dev/null 2>&1 ); cat "$MCPLOG" 2>/dev/null | tr '\n' ' '; }

# ---------------------------------------------------------------------------------------
section "a provider needing a deposited secret is handled, not described"
# Some providers want a client secret at the token exchange. A sweater config carries a client
# ID but has no field for a secret: the CLI looks that up in its own store, and only
# `claude mcp add --client-secret` writes there. grandma asks for the secret and runs that
# itself, rather than printing a command for someone to carry out by hand.
DEP="$TMP/depbin"; mkdir -p "$DEP"
cat > "$DEP/claude" <<'DEPEOF'
#!/usr/bin/env bash
# A user-scope add behaves like the real CLI on a re-run: the name is already there. A project-
# scope add writes .mcp.json where it runs, which is what has to be cleaned up behind it.
STATE="${MCPSTATE:-$TMPDIR/mcp-registered-probe}"
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "add" ]; then
  shift 2
  case " $* " in *" --scope user "*) [ -f "$STATE" ] && { echo "MCP server already exists in user config"; exit 1; } ;; esac
  printf '%s' "$*" > "$MCPADDLOG"; printf '%s' "$PWD" > "$MCPADDLOG.cwd"
  if [ -n "${MCP_CLIENT_SECRET:-}" ]; then
    echo " secret-present" >> "$MCPADDLOG"; : > "$STATE"; echo '{}' > .mcp.json; echo "Added"; exit 0
  fi
  echo "no secret"; exit 1
fi
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "remove" ]; then echo "remove $*" >> "$MCPADDLOG.remove"; rm -f "$STATE"; echo "Removed"; exit 0; fi
case "${1:-}" in
  --version|-v) echo "0.0.0"; exit 0 ;;
  --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
exit 0
DEPEOF
chmod +x "$DEP/claude"
export MCPADDLOG="$TMP/mcpadd.txt"
cat > "$TMP/drive2.py" <<'DRIVE2'
import os, pty, time, select, sys
env = dict(os.environ); env["PATH"] = sys.argv[2] + ":" + env["PATH"]
pid, fd = pty.fork()
if pid == 0: os.execve("/bin/bash", ["bash", "-c", sys.argv[1]], env)
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r: buf += os.read(fd, 65536)
        except OSError: return
for keys in (b"s3cr3t\r", b"n\r"):
    pump(2.0)
    try: os.write(fd, keys)
    except OSError: break
pump(1.5)
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(buf.decode("utf-8", "replace"))
DRIVE2
if command -v python3 >/dev/null 2>&1; then
  rm -f "$MCPADDLOG"
  RAW="$(python3 "$TMP/drive2.py" "$GBIN mcp add globex gmail https://gmailmcp.googleapis.com/mcp/v1 --client-id abc.apps.googleusercontent.com" "$DEP" 2>&1 || true)"
  LAST_OUT="$(printf '%s' "$RAW" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
  assert_contains "needs a client secret once" "it says what it needs in one line"
  assert_not_contains "claude mcp add --scope user" "it does not hand over a command to run"
  LAST_OUT="$(cat "$MCPADDLOG" 2>/dev/null | tr '\n' ' ')"
  assert_contains "globex__gmail" "it deposits under the composed name, which is what the lookup keys on"
  assert_contains "secret-present" "and passes the secret through, without storing it itself"
  # At user scope the registration outlives the call and loads in every sweater that binds
  # nothing, carrying one sweater's account into all the others.
  assert_contains "--scope project" "it deposits at project scope"
  assert_not_contains "--scope user" "never at user scope, where every unbound sweater would load it"
  DEPDIR="$(cat "$MCPADDLOG.cwd" 2>/dev/null)"
  LAST_OUT="$DEPDIR"
  assert_contains "grandma-deposit." "inside a folder made for it, not the directory it was run from"
  if [ -n "$DEPDIR" ] && [ ! -e "$DEPDIR" ]; then ok "and that folder is gone afterwards"
  else fail "and that folder is gone afterwards" "still present: $DEPDIR"; fi
  LAST_OUT="$(cat "$GRANDMA_HOME/globex/mcp.json" 2>/dev/null)"
  assert_not_contains "ecret" "the secret never reaches grandma's own file"
  rm -f "$GRANDMA_HOME/globex/mcp.json"

  # Accepting the sign-in must not ask for the secret again: it is in the CLI's store by then.
  # Declining would never reach that prompt, so this driver says yes.
  cat > "$TMP/drive_yes.py" <<'DRIVEY'
import os, pty, time, select, sys
env = dict(os.environ); env["PATH"] = sys.argv[2] + ":" + env["PATH"]
pid, fd = pty.fork()
if pid == 0: os.execve("/bin/bash", ["bash", "-c", sys.argv[1]], env)
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r: buf += os.read(fd, 65536)
        except OSError: return
for keys in (b"s3cr3t\r", b"y\r"):
    pump(2.0)
    try: os.write(fd, keys)
    except OSError: break
pump(2.0)
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(buf.decode("utf-8", "replace"))
DRIVEY
  rm -f "$MCPADDLOG"
  RAW="$(python3 "$TMP/drive_yes.py" "$GBIN mcp add globex gmail https://gmailmcp.googleapis.com/mcp/v1 --client-id abc.apps.googleusercontent.com" "$DEP" 2>&1 || true)"
  LAST_OUT="$(printf '%s' "$RAW" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g' | grep -c 'Client secret' | tr -d ' ')"
  assert_contains "1" "accepting the sign-in does not ask for the secret a second time"
  rm -f "$GRANDMA_HOME/globex/mcp.json"

  # Re-running is the normal case. Each deposit gets a fresh folder, so an earlier attempt is
  # never in the way, and nothing is removed first, because a remove would delete the secret too.
  MCPSTATE="$TMP/registered"; export MCPSTATE; : > "$MCPSTATE"
  rm -f "$MCPADDLOG" "$MCPADDLOG.remove"
  RAW="$(python3 "$TMP/drive2.py" "$GBIN mcp add globex gmail https://gmailmcp.googleapis.com/mcp/v1 --client-id abc.apps.googleusercontent.com" "$DEP" 2>&1 || true)"
  LAST_OUT="$(printf '%s' "$RAW" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
  assert_contains "done" "a re-run over an earlier attempt deposits cleanly"
  assert_not_contains "that did not take" "and nothing is presented as an error"
  LAST_OUT="$(cat "$MCPADDLOG" 2>/dev/null | tr '\n' ' ')"
  assert_contains "secret-present" "the re-run still carries the secret"
  if [ ! -e "$MCPADDLOG.remove" ]; then ok "and nothing is removed, which would take the secret with it"
  else fail "and nothing is removed, which would take the secret with it" "$(cat "$MCPADDLOG.remove")"; fi
  unset MCPSTATE
  rm -f "$GRANDMA_HOME/globex/mcp.json"
else
  skip "python3 missing — the deposit was not exercised"
fi

# From nothing at all: it opens the page, walks the four clicks, takes both values and binds.
if command -v python3 >/dev/null 2>&1; then
  OPENB="$TMP/openb"; mkdir -p "$OPENB"
  printf '#!/bin/sh\nexit 0\n' > "$OPENB/open"; chmod +x "$OPENB/open"
  cp "$DEP/claude" "$OPENB/claude"
  cat > "$TMP/drive3.py" <<'DRIVE3'
import os, pty, time, select, sys
env = dict(os.environ); env["PATH"] = sys.argv[2] + ":" + env["PATH"]
pid, fd = pty.fork()
if pid == 0: os.execve("/bin/bash", ["bash", "-c", sys.argv[1]], env)
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r: buf += os.read(fd, 65536)
        except OSError: return
for keys in (b"\r", b"123-abc.apps.googleusercontent.com\r", b"s3cr3t\r", b"n\r"):
    pump(2.0)
    try: os.write(fd, keys)
    except OSError: break
pump(1.5)
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(buf.decode("utf-8", "replace"))
DRIVE3
  rm -f "$MCPADDLOG"
  RAW="$(python3 "$TMP/drive3.py" "$GBIN mcp add globex gmail https://gmailmcp.googleapis.com/mcp/v1" "$OPENB" 2>&1 || true)"
  LAST_OUT="$(printf '%s' "$RAW" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
  assert_contains "Opened https://console.cloud.google.com" "with no client id it opens the page rather than naming it"
  assert_contains "Desktop app" "and gives the step that has to be right"
  assert_contains "Internal" "and which audience to pick, which is what Google blocks on"
  LAST_OUT="$(jq -r '.mcpServers.gmail.oauth.clientId // "none"' "$GRANDMA_HOME/globex/mcp.json" 2>/dev/null)"
  assert_contains "123-abc.apps.googleusercontent.com" "the collected client id is what gets bound"
  LAST_OUT="$(cat "$MCPADDLOG" 2>/dev/null | tr '\n' ' ')"
  assert_contains "secret-present" "and the secret it collected is deposited in the same run"
  rm -f "$GRANDMA_HOME/globex/mcp.json"
fi

capture env "$GBIN" mcp add globex notion https://mcp.notion.example/mcp
assert_not_contains "client secret" "a provider that signs in on its own is not bothered with any of it"
rm -f "$GRANDMA_HOME/globex/mcp.json"

# ---------------------------------------------------------------------------------------
section "a provider that refuses dynamic registration can still be bound"
# Some auth servers will not let the CLI introduce itself, so sign-in dies before any consent
# screen. For those you supply your own OAuth client. The ID is public and gets stored; the
# secret never touches the file and is read from the environment at sign-in.
capture env "$GBIN" mcp add globex mail https://gmailmcp.googleapis.com/mcp/v1 --client-id abc.apps.googleusercontent.com --callback-port 51789
assert_rc 0 "a server can be bound with your own OAuth client"
LAST_OUT="$(jq -c '.mcpServers.mail.oauth' "$GRANDMA_HOME/globex/mcp.json")"
assert_contains '"clientId":"abc.apps.googleusercontent.com"' "the client id is recorded"
assert_contains '"callbackPort":51789' "so is the fixed callback port"
LAST_OUT="$(cat "$GRANDMA_HOME/globex/mcp.json")"
assert_not_contains "clientSecret" "the secret is never written to memory"

capture env "$GBIN" mcp add globex mail2 https://example.com/mcp --callback-port 51789
assert_rc 1 "a callback port without a client id is refused"
capture env "$GBIN" mcp add globex mail3 https://example.com/mcp --client-id abc --callback-port not-a-number
assert_rc 1 "a non-numeric port is refused"

capture env "$GBIN" mcp add globex mail4 https://gmailmcp.googleapis.com/mcp/v1
assert_contains "OAuth client of your own" "binding a google endpoint with no client id says what to make"
rm -f "$GRANDMA_HOME/globex/mcp.json"

section "the first binding says what it changes"
capture env "$GBIN" mcp add globex notion https://mcp.notion.example/mcp
assert_contains "account connectors" "the first binding says what happens to the account connectors"
assert_contains "grandma mcp strict globex on" "and how to keep the sweater to its own servers"
capture env "$GBIN" mcp add globex second https://second.example/mcp
assert_not_contains "account connectors" "and it is not repeated on every later binding"
rm -f "$GRANDMA_HOME/globex/mcp.json"

# ---------------------------------------------------------------------------------------
section "a local server keeps the flags it was given"
# `jq --args` treats anything starting with a dash as one of its own options, so passing the
# command's flags as jq operands made jq fail and an empty args array get written instead.
capture env "$GBIN" mcp add globex tools -- npx -y some-server --flag
assert_rc 0 "a stdio server can be bound"
LAST_OUT="$(jq -c '.mcpServers.tools' "$GRANDMA_HOME/globex/mcp.json")"
assert_contains '"-y","some-server","--flag"' "its flags are kept, dashes and all"
capture env "$GBIN" mcp remove globex tools
rm -f "$GRANDMA_HOME/globex/mcp.json"

section "onboarding a new project gets the sweater's servers too"
# Onboarding is a working session in that sweater, so it must not be the one path that
# silently runs without the servers everything else in the sweater has.
cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
rm -f "$MCPLOG"
( "$GBIN" globex a-project-that-does-not-exist </dev/null >/dev/null 2>&1 )
LAST_OUT="$(cat "$MCPLOG" 2>/dev/null | tr '\n' ' ')"
assert_contains "globex__notion" "an onboarding session is bound to the sweater's servers"
assert_contains "strict=no" "and falls through the same way a normal launch does"
capture env "$GBIN" mcp strict globex on
rm -f "$MCPLOG"
( "$GBIN" globex a-project-that-does-not-exist </dev/null >/dev/null 2>&1 )
LAST_OUT="$(cat "$MCPLOG" 2>/dev/null | tr '\n' ' ')"
assert_contains "strict=yes" "and a strict sweater's onboarding is strict too"
rm -f "$GRANDMA_HOME/globex/mcp.json"

section "the verbs are completable, like every other subcommand"
capture env "$GBIN" completions __mcp_commands
assert_rc 0 "completions knows the mcp verbs"
assert_contains "add" "add is offered"
assert_contains "remove" "remove is offered"
assert_contains "strict" "strict is offered"

# ---------------------------------------------------------------------------------------
section "a session opened to sign in has one job"
# `grandma mcp add` can start the session for you. That session exists to sign in to one
# server, so it must not stop to ask about unrelated memory first, and it should say what it
# was opened for rather than the usual ready-for-a-task line.
mkdir -p "$GRANDMA_HOME/proposals"
printf '# grandma memory proposal\n# scope=globex\n\n- something\n' > "$GRANDMA_HOME/proposals/globex-signin.md"

capture env GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_contains "ready — what are we working on?" "an ordinary launch asks for a task"
assert_not_contains "needs signing in" "and says nothing about signing in"

capture env GRANDMA_DRY_RUN=1 GRANDMA_MCP_SIGNIN=globex__slack "$GBIN" globex
assert_contains "globex__slack is bound to this sweater and still needs signing in" "a sign-in launch says what it is for"
assert_contains "/mcp" "and names the command to run"
assert_not_contains "ready — what are we working on?" "instead of the usual opening"

if command -v python3 >/dev/null 2>&1; then
  SIBIN="$TMP/sibin"; mkdir -p "$SIBIN"
  cat > "$SIBIN/claude" <<'SIEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v) echo "0.0.0"; exit 0 ;;
  --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
echo "SESSION-STARTED"; exit 0
SIEOF
  chmod +x "$SIBIN/claude"
  cat > "$TMP/si.py" <<'SIPY'
import os, pty, time, select, sys
env = dict(os.environ, GRANDMA_HOME=sys.argv[2], PATH=sys.argv[3] + ":" + os.environ["PATH"],
           GRANDMA_NO_HOOK="1", GRANDMA_NO_AUTOSAVE="1", GRANDMA_NO_SPLASH="1")
if len(sys.argv) > 4: env["GRANDMA_MCP_SIGNIN"] = sys.argv[4]
pid, fd = pty.fork()
if pid == 0: os.execve("/bin/bash", ["bash", "-c", sys.argv[1]], env)
buf = b""; end = time.time() + 8
while time.time() < end:
    try:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r: buf += os.read(fd, 65536)
    except OSError: break
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(buf.decode("utf-8", "replace"))
SIPY
  LAST_OUT="$(python3 "$TMP/si.py" "$GBIN globex" "$GRANDMA_HOME" "$SIBIN" 2>&1 || true)"
  assert_contains "review before we start" "on a terminal an ordinary launch does offer the review"
  LAST_OUT="$(python3 "$TMP/si.py" "$GBIN globex" "$GRANDMA_HOME" "$SIBIN" globex__slack 2>&1 || true)"
  assert_not_contains "review before we start" "a sign-in launch does not stop to ask"
  assert_contains "review them next time" "it says the proposals are still there"
  assert_contains "SESSION-STARTED" "and goes straight into the session"
fi
rm -f "$GRANDMA_HOME/proposals/globex-signin.md"

# ---------------------------------------------------------------------------------------
section "a sweater that binds nothing is untouched"
LAST_OUT="$(launch globex)"
assert_contains "servers=<none>" "no MCP flags are passed when nothing is bound"
assert_contains "strict=no" "strict mode is not switched on for a sweater with no servers"

# ---------------------------------------------------------------------------------------
section "the command, because nobody should hand-write this file"
capture env "$GBIN" mcp add globex notion https://mcp.notion.example/mcp
assert_rc 0 "grandma mcp add binds a server"
assert_contains "globex__notion" "it says what the server will be called"
assert_file "$GRANDMA_HOME/globex/mcp.json" "and writes the sweater's file"

capture env "$GBIN" mcp add global gmail https://mail.example/mcp
assert_rc 0 "a server can be bound for every sweater"
assert_contains "every sweater" "and it says so"

capture env "$GBIN" mcp list globex
assert_rc 0 "list shows what a sweater actually gets"
assert_contains "globex__notion" "including its own servers, under the name they will load as"
assert_contains "gmail" "and the global ones"

# A memory home is a git repo that may be pushed, so a literal credential must never land in it.
capture env "$GBIN" mcp add globex corridor https://corridor.example/mcp --header "Authorization: Bearer sk-live-aaaaaaaaaaaaaaaaaaaa"
assert_rc 1 "a literal secret is refused"
assert_contains "environment variable" "and it says what to do instead"
capture jq -e '.mcpServers | has("corridor") | not' "$GRANDMA_HOME/globex/mcp.json"
assert_rc 0 "the refused server was not written"

capture env "$GBIN" mcp add globex corridor https://corridor.example/mcp --header 'Authorization: Bearer $CORRIDOR_TOKEN'
assert_rc 0 "an environment reference is accepted"

capture env "$GBIN" mcp add no-such-sweater x https://y.example/mcp
assert_rc 1 "an unknown sweater is refused rather than silently created"

capture env "$GBIN" mcp remove globex corridor
assert_rc 0 "remove unbinds a server"
capture env "$GBIN" mcp remove globex notion
assert_no_file "$GRANDMA_HOME/globex/mcp.json" "removing the last one leaves no file pretending otherwise"
rm -f "$GRANDMA_HOME/global/mcp.json"

# ---------------------------------------------------------------------------------------
section "a sweater's own servers reach it, renamed so its login is its own"
cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
LAST_OUT="$(launch globex)"
assert_contains "globex__notion" "the sweater's server is namespaced with the sweater"
# Unbound providers come from the account's connectors. The CLI drops a connector that duplicates
# a bound server, so strict is not what keeps a bound provider from appearing twice.
assert_contains "strict=no" "anything it does not bind falls through to the account"
capture env GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_contains "plus your account connectors" "and the launch says so"

# ---------------------------------------------------------------------------------------
section "a sweater can ask to see only its own servers"
capture env "$GBIN" mcp strict globex
assert_contains "not strict" "strict is off until asked for"
capture env "$GBIN" mcp strict globex on
assert_rc 0 "strict can be switched on"
LAST_OUT="$(launch globex)"
assert_contains "strict=yes" "a strict sweater shuts every other source out"
assert_contains "globex__notion" "and still gets its own servers"
capture env "$GBIN" mcp strict globex
assert_contains "is strict" "and it reports that it is strict"
capture env "$GBIN" mcp list globex
assert_contains "strict" "list shows it too"
LAST_OUT="$(launch home-ops)"
assert_contains "strict=no" "one sweater's strict does not reach another"

# Unbinding the last server must not quietly drop strict along with the file.
capture env "$GBIN" mcp remove globex notion
assert_file "$GRANDMA_HOME/globex/mcp.json" "removing the last server keeps a strict sweater's file"
LAST_OUT="$(launch globex)"
assert_contains "strict=yes" "so a strict sweater with nothing bound is still strict, which means no MCP at all"

capture env "$GBIN" mcp strict globex off
assert_rc 0 "strict can be switched off"
assert_no_file "$GRANDMA_HOME/globex/mcp.json" "and with nothing bound, no file is left pretending otherwise"
LAST_OUT="$(launch globex)"
assert_contains "strict=no" "the sweater falls through again"

capture env "$GBIN" mcp strict global on
assert_rc 1 "strict is per sweater, global is refused"

# ---------------------------------------------------------------------------------------
section "a server configured elsewhere at the same address is named, not silently doubled"
# Fall-through lets servers from the CLI's own config and the folder in too. The CLI dedupes a
# claude.ai connector against a bound server, but not these, so two logins for one provider
# would load side by side. The launcher names each one.
cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
PROJ="$TMP/some-folder"; mkdir -p "$PROJ"
printf '{"mcpServers":{"my-notion":{"type":"http","url":"https://mcp.notion.example/mcp"},"other":{"type":"http","url":"https://other.example/mcp"}}}' > "$HOME/.claude.json"
LAST_OUT="$(cd "$PROJ" && "$GBIN" globex </dev/null 2>&1)"
assert_contains "my-notion (user config) points at the same server as globex__notion" "a user-scope server at the same address is named"
assert_not_contains "other (" "a server at a different address is left alone"
assert_contains "grandma mcp strict globex on" "and it says how to keep the sweater to its own"

PROJP="$(cd "$PROJ" && pwd -P)"
jq -n --arg d "$PROJP" '{projects: {($d): {mcpServers: {"proj-notion": {type:"http", url:"https://mcp.notion.example/mcp"}}}}}' > "$HOME/.claude.json"
LAST_OUT="$(cd "$PROJ" && "$GBIN" globex </dev/null 2>&1)"
assert_contains "proj-notion (this folder, in the CLI config)" "a server the CLI config holds for this folder is named"

rm -f "$HOME/.claude.json"
printf '{"mcpServers":{"folder-notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}' > "$PROJ/.mcp.json"
LAST_OUT="$(cd "$PROJ" && "$GBIN" globex </dev/null 2>&1)"
assert_contains "folder-notion (this folder, .mcp.json)" "a folder's own .mcp.json is named"

capture env "$GBIN" mcp strict globex on
LAST_OUT="$(cd "$PROJ" && "$GBIN" globex </dev/null 2>&1)"
assert_not_contains "points at the same server" "a strict sweater has nothing to warn about, nothing else loads"
rm -f "$PROJ/.mcp.json" "$GRANDMA_HOME/globex/mcp.json"

# ---------------------------------------------------------------------------------------
section "two sweaters holding the same provider never share a login"
cat > "$GRANDMA_HOME/home-ops/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
LAST_OUT="$(launch home-ops)"
assert_contains "home-ops__notion" "a kebab-named sweater namespaces correctly too"
assert_not_contains "globex__notion" "one sweater cannot see the other sweater's server"
LAST_OUT="$(launch globex)"
assert_not_contains "home-ops__notion" "and the reverse direction holds"

# ---------------------------------------------------------------------------------------
section "global servers reach every sweater, and a sweater can override one"
mkdir -p "$GRANDMA_HOME/global"
cat > "$GRANDMA_HOME/global/mcp.json" <<'EOF'
{"mcpServers":{"gmail":{"type":"http","url":"https://mail.example/mcp"},"drive":{"type":"http","url":"https://drive.example/mcp"}}}
EOF
LAST_OUT="$(launch home-ops)"
assert_contains "drive" "a global server reaches a sweater that did not ask for it"
assert_contains "gmail" "and keeps its bare name, so one login is shared"

cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"gmail":{"type":"http","url":"https://globex-mail.example/mcp"}}}
EOF
LAST_OUT="$(launch globex)"
assert_contains "globex__gmail" "the sweater's own account replaces the global one"
assert_not_contains "servers=drive,gmail" "the shadowed global entry is gone for this sweater"
assert_contains "drive" "an unrelated global server still comes through"

# ---------------------------------------------------------------------------------------
section "a broken file says so and still launches"
printf 'this is not json' > "$GRANDMA_HOME/globex/mcp.json"
rm -f "$MCPLOG"
capture env "$GBIN" globex
assert_rc 0 "a malformed mcp.json does not stop the session"
assert_contains "could not be read" "it says what went wrong"
# shellcheck disable=SC2034  # assert_contains reads LAST_OUT; shellcheck cannot see that
LAST_OUT="$(cat "$MCPLOG" 2>/dev/null | tr '\n' ' ')"
assert_contains "servers=<none>" "and it launches with no servers rather than a partial set"

# ---------------------------------------------------------------------------------------
section "the composed file does not outlive the session"
# Compare before and after rather than globbing the whole temp directory: another grandma
# session running on the same machine would otherwise fail this for us.
cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
ls "${TMPDIR:-/tmp}"/grandma-mcp.* 2>/dev/null | sort > "$TMP/mcp-before.txt" || true
# shellcheck disable=SC2034  # assert_contains on the next line reads LAST_OUT
LAST_OUT="$(launch globex)"
assert_contains "globex__notion" "the session really did get a composed config"
ls "${TMPDIR:-/tmp}"/grandma-mcp.* 2>/dev/null | sort > "$TMP/mcp-after.txt" || true
if [ -s "$TMP/mcp-after.txt" ] && ! diff -q "$TMP/mcp-before.txt" "$TMP/mcp-after.txt" >/dev/null 2>&1; then
  fail "this launch left its composed MCP config behind: $(comm -13 "$TMP/mcp-before.txt" "$TMP/mcp-after.txt" | tr '\n' ' ')"
else
  ok "no composed MCP config is left behind"
fi
rm -f "$GRANDMA_HOME/globex/mcp.json"

# ---------------------------------------------------------------------------------------
section "the memory bundle never carries the MCP config"
cat > "$GRANDMA_HOME/globex/mcp.json" <<'EOF'
{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.example/mcp"}}}
EOF
capture "$ENGINE/lib/assemble.sh" globex
assert_not_contains "mcpServers" "a sweater's mcp.json is not loaded as memory"
assert_not_contains "mcp.json" "and is not listed in the bundle manifest"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_mcp: PASS"; else echo "cmd_mcp: $FAILS FAILURE(S)"; exit 1; fi
