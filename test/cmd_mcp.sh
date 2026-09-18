#!/usr/bin/env bash
# Behavioral test for per-sweater MCP binding.
#
# The promise: a sweater's MCP servers reach every project in that sweater and nothing outside
# it. The isolation is the CLI's own --strict-mcp-config, which ignores every other MCP source,
# so this is a boundary rather than a convention. Composition order is the design: global servers
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
section "a provider needing its own client is walked through, not handed homework"
# Interactive only, so it needs a real terminal. Piping input would make stdin a pipe, the
# terminal check would fail, and the guided flow would never run at all: the same trap that
# stops a piped installer opening a TUI. Drive a pty and type into it instead.
OPENBIN="$TMP/openbin"; mkdir -p "$OPENBIN"
printf '#!/bin/sh\necho "[opened $1]"\n' > "$OPENBIN/open"; chmod +x "$OPENBIN/open"
cp "$OPENBIN/open" "$OPENBIN/xdg-open"
cat > "$TMP/drive.py" <<'DRIVE'
import os, pty, time, select, re, sys
env = dict(os.environ)
env["PATH"] = sys.argv[2] + ":" + env["PATH"]
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/bash", ["bash", "-c", sys.argv[1]], env)
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r: buf += os.read(fd, 65536)
        except OSError: return
for keys in (b"\r", b"1234567890.apps.googleusercontent.com\r", b"n\r"):
    pump(2.5)
    try: os.write(fd, keys)
    except OSError: break
pump(2.5)
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", buf).decode("utf-8", "replace"))
DRIVE
if command -v python3 >/dev/null 2>&1; then
  LAST_OUT="$(python3 "$TMP/drive.py" "$GBIN mcp add globex mail https://gmailmcp.googleapis.com/mcp/v1" "$OPENBIN" 2>&1 || true)"
  assert_contains "Desktop app" "it names the one setting that has to be right"
  assert_contains "Internal" "it says which audience to pick, which is what Google blocks on"
  assert_contains "only admits accounts on THAT domain" "and warns that an internal client is one domain only"
  assert_contains "console.cloud.google.com" "it points at the page"
  assert_contains "Opened https://console.cloud.google.com" "it opens the page rather than telling you to"
  LAST_OUT="$(jq -r '.mcpServers.mail.oauth.clientId // "none"' "$GRANDMA_HOME/globex/mcp.json" 2>/dev/null)"
  assert_contains "1234567890.apps.googleusercontent.com" "the client ID it collected is what gets bound"
  LAST_OUT="$(cat "$GRANDMA_HOME/globex/mcp.json" 2>/dev/null)"
  assert_not_contains "ecret" "no secret is written, whatever was typed"
  rm -f "$GRANDMA_HOME/globex/mcp.json"
else
  skip "python3 missing — the guided flow was not exercised"
fi

capture env "$GBIN" mcp add globex mail https://gmailmcp.googleapis.com/mcp/v1
assert_rc 0 "with no terminal it binds rather than hanging on a prompt"
assert_contains "credentials of its own" "and says what will be needed"
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
assert_contains "credentials of its own" "binding a google endpoint without a client id says so"
rm -f "$GRANDMA_HOME/globex/mcp.json"

section "the first binding says what it changes"
capture env "$GBIN" mcp add globex notion https://mcp.notion.example/mcp
assert_contains "account connectors" "the first binding warns that account connectors drop out"
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
assert_contains "strict=yes" "and is isolated the same way a normal launch is"
rm -f "$GRANDMA_HOME/globex/mcp.json"

section "the verbs are completable, like every other subcommand"
capture env "$GBIN" completions __mcp_commands
assert_rc 0 "completions knows the mcp verbs"
assert_contains "add" "add is offered"
assert_contains "remove" "remove is offered"

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
assert_contains "strict=yes" "every other MCP source is shut out"

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
