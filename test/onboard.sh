#!/usr/bin/env bash
# End-to-end onboarding test — the full `curl ... | bash` flow.
#
# The onboarding hang (trust prompt frozen forever) only reproduces when TWO things are
# true at once: `claude` is on PATH, and stdin is a pipe (as it is under curl|bash). The
# integrity suite and smoke test miss it because CI has no `claude` binary, so the
# interview branch is never taken. This test supplies a FAKE claude and drives install
# through a pipe, then asserts the installer never launches an interactive TUI it cannot
# talk to. It also drives the interactive path (a real pty) to prove the interview DOES
# fire when — and only when — stdin is a terminal.
set -uo pipefail
ENGINE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Hermetic: never inherit a GRANDMA_HOME from the surrounding shell. Every case below
# expects `grandma init` to seed the sandbox's own $HOME/.grandma. A GRANDMA_HOME exported
# in a developer's shell (the local-dev setup points it at the real memory home) would
# otherwise redirect the seed there, writing real memory and failing the sandbox asserts.
unset GRANDMA_HOME

FAILS=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
skip() { printf '  \033[2mskip\033[0m %s\n' "$1"; }

# Run a command with a hard wall-clock cap. Exit 142 means it was killed (SIGALRM) —
# i.e. it hung. Portable (perl ships on macOS and Linux); alarm() survives the exec.
run_capped() { # <secs> <cmd...>
  local secs="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
}

# Run a shell command line inside a real pty, so `[ -t 0 ]`/`/dev/tty` behave like a
# terminal. Returns 2 if no usable `script` exists (caller should skip, not fail).
run_in_pty() { # <shell-command-line>
  local cmd="$1"
  if ! command -v script >/dev/null 2>&1; then return 2; fi
  if script --version >/dev/null 2>&1; then
    run_capped 30 script -qec "$cmd" /dev/null      # GNU coreutils
  else
    run_capped 30 script -q /dev/null bash -c "$cmd"  # BSD/macOS
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A stand-in `claude`: answers `--version` (doctor calls it) without recording a launch,
# and for any real invocation records a marker then blocks on stdin exactly like the frozen
# trust prompt. If onboarding execs it under a pipe, the marker appears and — absent the
# fix — the wait hangs until the watchdog kills it.
SHIM="$SANDBOX/bin"; mkdir -p "$SHIM"
MARKER="$SANDBOX/claude-was-launched"
cat > "$SHIM/claude" <<SHIM_EOF
#!/usr/bin/env bash
case "\${1:-}" in --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;; esac
echo launched >> "$MARKER"
[ -t 0 ] && exit 0
cat > /dev/null
SHIM_EOF
chmod +x "$SHIM/claude"

echo "== onboarding e2e: curl | bash (piped stdin) =="

# --- 1. full install.sh, cloning from the local committed tree, driven through a pipe ----
HOME1="$SANDBOX/home1"; mkdir -p "$HOME1"
rm -f "$MARKER"
out="$(
  HOME="$HOME1" \
  SHELL="/bin/zsh" \
  PATH="$SHIM:$PATH" \
  GRANDMA_REPO="$ENGINE_SRC" \
  GRANDMA_ENGINE="$SANDBOX/engine" \
  run_capped 40 bash "$ENGINE_SRC/install.sh" </dev/null 2>&1
)"; rc=$?

if [ "$rc" -eq 142 ]; then fail "install.sh hung under a pipe (killed by watchdog)"
else pass "install.sh completes under a pipe (no hang)"; fi
if [ -f "$MARKER" ]; then fail "launched interactive claude under a pipe — this is the hang"
else pass "did not launch the interactive TUI under a pipe"; fi
[ -x "$SANDBOX/engine/bin/grandma" ] && pass "engine cloned to GRANDMA_ENGINE" || fail "engine was not cloned"
[ -f "$HOME1/.grandma/global/identity.md" ] && pass "memory home seeded" || fail "memory home not seeded"
[ -d "$HOME1/.grandma/.git" ] && pass "memory home is a git repo" || fail "memory home not a git repo"
echo "$out" | grep -q "grandma is set up" && pass "prints a clear hand-off" || fail "no hand-off message printed"
grep -q "grandma engine" "$HOME1/.zshrc" 2>/dev/null && pass "PATH wired into shell rc" || fail "PATH not added to rc"

# --- 2. re-run is idempotent (engine pull + init again), still no hang, still no TUI -----
rm -f "$MARKER"
run_capped 40 env \
  HOME="$HOME1" SHELL="/bin/zsh" PATH="$SHIM:$PATH" \
  GRANDMA_REPO="$ENGINE_SRC" GRANDMA_ENGINE="$SANDBOX/engine" \
  bash "$ENGINE_SRC/install.sh" </dev/null >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 142 ] && [ ! -f "$MARKER" ]; } && pass "re-install is idempotent and safe" || fail "re-install hung or launched the TUI"

# --- 3. the exact real-world condition: controlling tty present, stdin a pipe -----------
# This is what `curl | bash` produces in a terminal: /dev/tty is openable, but fd 0 is not
# a tty. It is the case the fix hinges on and the one CI's plain-pipe run cannot create
# (CI has no controlling terminal at all). Reintroducing the /dev/tty-redirect launch would
# make this fire the TUI and hang — so this is the load-bearing regression guard.
echo "== onboarding e2e: controlling tty + piped stdin (the real curl|bash case) =="
HOME3="$SANDBOX/home3"; mkdir -p "$HOME3"
export SHIM_PTY="$SHIM" GBIN="$ENGINE_SRC/bin/grandma"
export HOME_PTY="$HOME3"
rm -f "$MARKER"
# script's OWN stdin is /dev/null (a char dev, not a socket) so pty setup does not choke;
# the inner `init </dev/null` is what makes fd 0 a pipe while /dev/tty stays the pty.
run_in_pty 'HOME="$HOME_PTY" SHELL=/bin/zsh PATH="$SHIM_PTY:$PATH" "$GBIN" init </dev/null >/dev/null 2>&1' </dev/null
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool (script) — real curl|bash condition not exercised"
elif [ ! -f "$HOME3/.grandma/global/identity.md" ]; then
  skip "pty could not be allocated in this environment — init did not run, condition not exercised"
elif [ "$prc" -eq 142 ]; then
  fail "onboarding hung with a controlling tty and piped stdin (the reported bug)"
elif [ -f "$MARKER" ]; then
  fail "launched the interactive TUI with piped stdin — would hang under curl|bash"
else
  pass "no TUI launched when stdin is a pipe, even with a controlling tty"
fi

# --- 4. the POSITIVE path: on a REAL interactive terminal the interview SHOULD fire ------
echo "== onboarding e2e: interactive terminal (pty) =="
HOME2="$SANDBOX/home2"; mkdir -p "$HOME2"
export HOME_PTY="$HOME2"
rm -f "$MARKER"
# stdin is the pty (a real terminal); answer the [Y/n] prompt with "y" via the pty input.
printf 'y\n' | run_in_pty 'HOME="$HOME_PTY" SHELL=/bin/zsh PATH="$SHIM_PTY:$PATH" "$GBIN" init >/dev/null 2>&1'
prc=$?
if [ "$prc" -eq 2 ]; then
  skip "no usable pty tool (script) — interactive path not exercised here"
elif [ ! -f "$HOME2/.grandma/global/identity.md" ]; then
  skip "pty could not be allocated in this environment — interactive path not exercised"
elif [ -f "$MARKER" ]; then
  pass "interview launches claude when stdin is a real terminal"
else
  fail "interview did NOT launch on a real terminal — onboarding would never interview"
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "onboard: PASS"; else echo "onboard: $FAILS FAILURE(S)"; exit 1; fi
