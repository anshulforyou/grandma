#!/usr/bin/env bash
# test/lib/assert.sh — tiny TAP-ish assertions + harness helpers, sourced by test/*.sh.
# No framework, no new deps: bash + coreutils + perl (+ the python3/jq the engine already needs).
#
# A sourcing script does:  set -uo pipefail; . test/lib/assert.sh; . test/lib/fixture.sh
# runs its asserts, then `exit $FAILS`.

: "${FAILS:=0}"
: "${TESTS:=0}"

ok()      { TESTS=$((TESTS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail()    { TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
            [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         | /'; return 0; }
skip()    { printf '  \033[2mskip\033[0m %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# capture <cmd...> — run it, store combined stdout+stderr in LAST_OUT and its rc in LAST_RC.
# Set per-call environment with an `env` prefix, e.g.:
#   capture env GRANDMA_DRY_RUN=1 "$GBIN" ingest acme --root "$scan"
capture() { LAST_OUT="$("$@" 2>&1)"; LAST_RC=$?; return 0; }

# capture_capped <secs> <cmd...> — like capture but hard-killed after <secs> (LAST_RC 142 = hung).
capture_capped() { local s="$1"; shift; LAST_OUT="$(run_capped "$s" "$@" 2>&1)"; LAST_RC=$?; return 0; }

# assert_rc <expected> <desc> — check LAST_RC, and ALWAYS that LAST_OUT has no
# "unbound variable" (the crash-under-set-u smell that shipped the ingest/review bugs).
assert_rc() {
  local want="$1" desc="$2"
  case "$LAST_OUT" in
    *"unbound variable"*) fail "$desc — crashed on an unbound variable (set -u)" "$LAST_OUT"; return 0 ;;
  esac
  if [ "${LAST_RC:-1}" = "$want" ]; then ok "$desc"
  else fail "$desc (rc=${LAST_RC:-?} want=$want)" "$LAST_OUT"; fi
}
assert_contains()     { case "$LAST_OUT" in (*"$1"*) ok "$2" ;; (*) fail "$2 — missing: $1" "$LAST_OUT" ;; esac; }
assert_not_contains() { case "$LAST_OUT" in (*"$1"*) fail "$2 — unexpected: $1" "$LAST_OUT" ;; (*) ok "$2" ;; esac; }
assert_file()         { if [ -e "$1" ]; then ok "$2"; else fail "$2 — missing file: $1"; fi; }
assert_no_file()      { if [ -e "$1" ]; then fail "$2 — unexpected file: $1"; else ok "$2"; fi; }

# ---- process helpers (lifted from test/onboard.sh, proven there) ----

# Run a command with a hard wall-clock cap. rc 142 = killed by SIGALRM (it hung).
# perl ships on macOS and Linux; alarm() survives the exec.
run_capped() { local secs="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"; }

# Run a shell command line inside a real pty (so [ -t 0 ]/dev/tty behave like a terminal).
# Returns 2 if no usable `script` exists — the caller must skip, not fail.
run_in_pty() {
  local cmd="$1"
  command -v script >/dev/null 2>&1 || return 2
  if script --version >/dev/null 2>&1; then run_capped 30 script -qec "$cmd" /dev/null      # GNU
  else run_capped 30 script -q /dev/null bash -c "$cmd"; fi                                  # BSD/macOS
}

# make_fake_claude <bindir> [marker] — write a deterministic `claude` shim into <bindir> so
# CI (which has no real claude) can exercise the exec/headless paths. Prepend <bindir> to PATH.
#   claude --version   -> prints a version (doctor calls it)
#   claude -p "<...>"  -> headless: emits a canned proposal/digest body to stdout AND echoes
#                         distilling=$GRANDMA_DISTILLING, so callers can prove the recursion
#                         guard's env is inherited by the child.
#   claude ... (else)  -> interactive exec: append a line to <marker>, then exit if stdin is a
#                         tty else drain stdin (mimics the TUI). Lets tests witness a launch.
make_fake_claude() {
  local dir="$1" marker="${2:-$1/.launched}"
  mkdir -p "$dir"
  cat > "$dir/claude" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;; esac
if [ "\${1:-}" = "-p" ]; then
  echo "FAKECLAUDE-PROPOSAL"
  echo "target: globex/facts.md | action: append | text: fake learning"
  echo "distilling=\${GRANDMA_DISTILLING:-unset}"
  exit 0
fi
echo launched >> "$marker"
[ -t 0 ] && exit 0
cat >/dev/null
SHIM
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}
