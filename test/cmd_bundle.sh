#!/usr/bin/env bash
# Behavioral test for how the memory bundle reaches the CLI, and for the shape that makes a
# memory home grow until it cannot launch at all.
#
# Two kernel limits used to cap memory, and neither is about how much memory is sensible:
#   Linux  MAX_ARG_STRLEN caps ONE argument at 131072 bytes, hardcoded, unrelated to ARG_MAX.
#   BSD    argv plus envp together must fit ARG_MAX.
# The bundle rode as a single argument, so a large home died on "Argument list too long" from
# the shell, seconds after grandma printed that memory had loaded. These tests FAIL before the
# --append-system-prompt-file transport and the tier warning, and PASS after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
export GRANDMA_HOME="$TMP/home"; export SHELL="" GRANDMA_NO_SPLASH=1 GRANDMA_NO_HOOK=1 GRANDMA_NO_AUTOSAVE=1
make_fixture_home "$GRANDMA_HOME"

# A shim that records HOW the prompt arrived, so the transport is observed and not assumed.
SHIM="$TMP/bin"; mkdir -p "$SHIM"; SEEN="$TMP/seen"
cat > "$SHIM/claude" <<SHIMEOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;;
  --help) [ "\${FAKE_CLAUDE_NO_PROMPT_FILE:-0}" = 1 ] || echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
prev=""
for a in "\$@"; do
  case "\$prev" in
    --append-system-prompt-file) echo "transport=file bytes=\$(wc -c < "\$a" | tr -d ' ') mode=\$(stat -f '%Lp' "\$a" 2>/dev/null || stat -c '%a' "\$a")" > "$SEEN" ;;
    --append-system-prompt)      echo "transport=argv bytes=\${#a}" > "$SEEN" ;;
  esac
  prev="\$a"
done
exit 0
SHIMEOF
chmod +x "$SHIM/claude"
export PATH="$SHIM:$PATH"

# ---------------------------------------------------------------------------------------
section "the bundle does not ride on argv when the CLI can take a file"
rm -f "$SEEN"
capture "$GBIN" globex
assert_rc 0 "a normal launch succeeds"
if [ -f "$SEEN" ] && grep -q 'transport=file' "$SEEN"; then
  ok "prompt delivered by file, not argv ($(cat "$SEEN"))"
else
  fail "prompt did not use --append-system-prompt-file" "$(cat "$SEEN" 2>/dev/null)"
fi
if [ -f "$SEEN" ] && grep -q 'mode=600' "$SEEN"; then
  ok "the bundle file is private (mode 600)"
else
  fail "bundle file is not mode 600 — it holds the user's whole memory" "$(cat "$SEEN" 2>/dev/null)"
fi
if ls "${TMPDIR:-/tmp}"/grandma-sysprompt.* >/dev/null 2>&1; then
  fail "the temp bundle file was left behind"
else
  ok "the temp bundle file is removed after the session"
fi

# ---------------------------------------------------------------------------------------
section "a bundle past the argv limit still launches"
python3 - "$GRANDMA_HOME/globex/facts.md" <<'PY'
import sys
# comfortably past both MAX_ARG_STRLEN (131072) and a 1 MiB ARG_MAX
open(sys.argv[1],'a').write('- a durable fact about the widget pipeline\n' * 30000)
PY
rm -f "$SEEN"
capture "$GBIN" globex
assert_rc 0 "an oversized bundle launches instead of dying on argv"
assert_not_contains "Argument list too long" "the shell's argv error never appears"
if [ -f "$SEEN" ] && grep -q 'transport=file' "$SEEN"; then
  ok "the oversized bundle arrived whole ($(cat "$SEEN"))"
else
  fail "oversized bundle did not arrive by file" "$(cat "$SEEN" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------------------
section "an old CLI without the flag refuses with an explanation, not a kernel error"
rm -f "$SEEN"
FAKE_CLAUDE_NO_PROMPT_FILE=1 capture "$GBIN" globex
assert_rc 1 "grandma refuses rather than attempting a doomed exec"
assert_contains "MEMORY BUNDLE TOO LARGE TO LAUNCH" "it names the problem in grandma's own words"
assert_not_contains "Argument list too long" "the raw shell error is never what the user sees"
assert_contains "log/" "it points at the tier that rotates"

# ---------------------------------------------------------------------------------------
section "the capability probe can never hang the launcher"
# The probe runs BEFORE the HUP trap is armed, so a CLI that never answers --help would
# otherwise freeze the CLI with no output at all. Bound it, and fall back.
BLOCK="$TMP/blockbin"; mkdir -p "$BLOCK"
cat > "$BLOCK/claude" <<'BLOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in --version|-v) echo "0.0.0"; exit 0 ;; --help) exec sleep 337 ;; esac
exit 0
BLOCKEOF
chmod +x "$BLOCK/claude"
git -C "$GRANDMA_HOME" checkout -- globex/facts.md 2>/dev/null || \
  python3 - "$GRANDMA_HOME/globex/facts.md" <<'PY'
import sys
open(sys.argv[1],'w').write("---\nscope: globex\ntype: facts\n---\n\n- Go on GCP\n")
PY
start=$(date +%s)
PATH="$BLOCK:$PATH" GRANDMA_PROBE_TIMEOUT=2 capture_capped 30 "$GBIN" globex
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -lt 25 ]; then
  ok "a CLI that never answers --help does not hang the launch (${elapsed}s)"
else
  fail "the probe hung the launcher (${elapsed}s)"
fi
pkill -f 'sleep 337' 2>/dev/null || true

# ---------------------------------------------------------------------------------------
section "the bundle file does not survive an interrupted session"
# HUP and TERM are trapped, but Ctrl+C is not, and without an EXIT trap the file holding the
# user's whole memory was left in the temp dir on every interrupted session.
INTBIN="$TMP/intbin"; mkdir -p "$INTBIN"
cat > "$INTBIN/claude" <<'INTEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v) echo "0.0.0"; exit 0 ;;
  --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
exec sleep 331
INTEOF
chmod +x "$INTBIN/claude"
before_n=$(ls "${TMPDIR:-/tmp}"/grandma-sysprompt.* 2>/dev/null | wc -l | tr -d ' ')
set -m
( PATH="$INTBIN:$PATH" exec "$GBIN" globex >/dev/null 2>&1 ) & ipg=$!
if wait_until 15 pgrep -f 'sleep 331'; then
  during_n=$(ls "${TMPDIR:-/tmp}"/grandma-sysprompt.* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$during_n" -gt "$before_n" ]; then
    ok "the bundle file exists while the session runs"
  else
    fail "no bundle file was created, so this test proves nothing"
  fi
  kill -s INT -- -"$ipg" 2>/dev/null || true
  pkill -f 'sleep 331' 2>/dev/null || true
  cleaned=0
  for _ in $(seq 1 40); do
    [ "$(ls "${TMPDIR:-/tmp}"/grandma-sysprompt.* 2>/dev/null | wc -l | tr -d ' ')" -le "$before_n" ] && { cleaned=1; break; }
    sleep 0.25
  done
  if [ "$cleaned" = 1 ]; then
    ok "Ctrl+C leaves no copy of the memory bundle behind"
  else
    fail "an interrupted session left the bundle file in ${TMPDIR:-/tmp}"
    rm -f "${TMPDIR:-/tmp}"/grandma-sysprompt.*
  fi
else
  skip "session did not go live in this env — interrupt cleanup not exercised"
  pkill -f 'sleep 331' 2>/dev/null || true
fi
set +m

# ---------------------------------------------------------------------------------------
section "tier boundary: sweater-root files load every session, log/ does not"
capture "$ENGINE/lib/assemble.sh" globex
assert_contains "globex/facts.md" "a .md at the sweater root is always loaded"
assert_not_contains "log/2026-06-15.md" "a dated log is NOT loaded by default"
assert_not_contains "decisions.md" "decisions are NOT loaded by default"
capture "$ENGINE/lib/assemble.sh" globex --full
assert_contains "log/2026-06-15.md" "--full does load the newest dated log"

# ---------------------------------------------------------------------------------------
section "a flat log.md is called out, because it never stops growing"
printf -- '---\nscope: globex\ntype: log\n---\n\n- an append-only note\n' > "$GRANDMA_HOME/globex/log.md"
capture "$GBIN" globex
assert_contains "log.md loads every session" "the wrong-tier file is named at launch"
assert_contains "mkdir -p" "the fix is spelled out"
rm -f "$GRANDMA_HOME/globex/log.md"
capture "$GBIN" globex
assert_not_contains "log.md loads every session" "the warning stops once the file is moved"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_bundle: PASS"; else echo "cmd_bundle: $FAILS FAILURE(S)"; exit 1; fi
