#!/usr/bin/env bash
# test/lib/assert.sh — tiny TAP-ish assertions + harness helpers, sourced by test/*.sh.
# No framework, no new deps: bash + coreutils + perl (+ the python3/jq the engine already needs).
#
# A sourcing script does:  set -uo pipefail; . test/lib/assert.sh; . test/lib/fixture.sh
# runs its asserts, then `exit $FAILS`.

: "${FAILS:=0}"
: "${TESTS:=0}"

# `git bisect run ./test/run.sh` and `git rebase --exec` export these, and they win over `git -C`:
# every git command in the suite would then act on the CALLER's repository. The tests switch
# branches, stash, and commit, so that is a working tree we could damage. Clear them once, here.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

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

# wait_until <secs> <cmd...> — poll until the command succeeds, or give up after <secs>.
# For anything racing a BACKGROUND process: a fixed `sleep 1` is a guess that passes on a
# quiet machine and fails on a loaded CI runner, which is the worst kind of test.
wait_until() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt $((secs * 10)) ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- process helpers (lifted from test/onboard.sh, proven there) ----

# Run a command with a hard wall-clock cap. rc 142 = killed by SIGALRM (it hung).
# perl ships on macOS and Linux; alarm() survives the exec.
run_capped() { local secs="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"; }

# Run a shell command line inside a real pty (so [ -t 0 ]/dev/tty behave like a terminal).
# Returns 2 if no usable `script` exists — the caller must skip, not fail.
run_in_pty() {
  local cmd="$1"
  command -v script >/dev/null 2>&1 || return 2
  if script --version >/dev/null 2>&1; then
    # GNU script runs `-c` via $SHELL; tests set SHELL="" (to avoid touching an rc), which
    # would make it exec an empty shell. Force a real shell just for this call.
    local sh=/bin/bash
    [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ] && sh="$SHELL"
    SHELL="$sh" run_capped 30 script -qec "$cmd" /dev/null
  else
    run_capped 30 script -q /dev/null bash -c "$cmd"   # BSD/macOS: explicit shell, SHELL-agnostic
  fi
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
case "\${1:-}" in
  --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;;
  # Real claude answers --help, and the launcher probes it for --append-system-prompt-file.
  # A shim that stayed silent here would send every launch down the probe-timeout path.
  # Set FAKE_CLAUDE_NO_PROMPT_FILE=1 to impersonate a build without the flag.
  --help) [ "\${FAKE_CLAUDE_NO_PROMPT_FILE:-0}" = 1 ] || echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
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

# make_fake_opencode <bindir> — write an `opencode` shim into <bindir> that stands in for the CLI and
# the slice of its HTTP API the OpenCode adapter uses, so every adapter path runs offline. State and
# a record of every call land in $FAKE_OC_ROOT (default: <bindir>/state). Prepend <bindir> to PATH.
#   opencode --version                                    -> a version
#   opencode api post /api/session --data <json>          -> creates ses_fakeNNNN, stores the body
#   opencode api get|delete /api/session/<id>             -> the stored body / deleted.log
#   opencode api get /api/session?...&directory=<d>       -> the sessions in state/list.json recorded under
#                                                            exactly <d>, as opencode lists them; without
#                                                            that file, one carrying $FAKE_OC_RECENT_MODEL
#   opencode api get /api/session/<id>/message?...        -> two canned transcript pages (cursor c2)
#   opencode api put|get|delete .../instructions/entries  -> entries/<id>/<key>, puts.log; refuses a
#                                                            value over 256 KiB exactly as opencode
#                                                            does, or every put when FAKE_OC_ENTRIES=off
#   opencode run --session <id> ... --file <f> <msg>      -> records it under runs/<n>/ (attached files
#                                                            copied, GRANDMA_DISTILLING echoed) and
#                                                            answers per FAKE_OC_RUN: propose (default),
#                                                            noop, crash (exit 0 + Execution error),
#                                                            fail (exit 1), hang
#   opencode --session <id> --prompt <text> ... <dir>     -> the terminal UI: tui-<id>.txt records it;
#                                                            FAKE_OC_TUI_CAPTURE=<file> appends a line
#                                                            there, as a live capture would, and
#                                                            FAKE_OC_TUI_LIVE=<marker> touches it and
#                                                            then never exits on its own (sleep
#                                                            $FAKE_OC_TUI_SLEEP), like OpenCode's UI
#                                                            on a terminal that has gone away
make_fake_opencode() {
  local dir="$1"
  mkdir -p "$dir/state"
  cat > "$dir/opencode" <<'SHIM'
#!/usr/bin/env bash
S="${FAKE_OC_ROOT:-$(cd "$(dirname "$0")" && pwd)/state}"
mkdir -p "$S/sessions" "$S/entries" "$S/runs"
log() { printf '%s\n' "$*" >> "$S/calls.log"; }
next_id() {
  local n; n=$(( $(cat "$S/counter" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/counter"
  printf 'ses_fake%04d' "$n"
}
page1() {
  cat <<'P1'
{"cursor":{"previous":null,"next":"c2"},"data":[
 {"type":"agent-switched","id":"m0"},
 {"type":"user","id":"m1","text":"how do I run the billing migration?"},
 {"type":"assistant","id":"m2","model":{"providerID":"fakeprov","id":"fake-model","variant":"max"},
  "content":[{"type":"reasoning","text":"PRIVATE-REASONING"},{"type":"tool","name":"bash"},{"type":"text","text":"Use atlas, never yarn."}]},
 {"type":"idle","id":"m3"}]}
P1
}
page2() {
  cat <<'P2'
{"cursor":{"previous":"c1","next":null},"data":[
 {"type":"synthetic","id":"m4","text":"<shell>TOOL-NOISE</shell>"},
 {"type":"user","id":"m5","text":"thanks, remember pnpm only"},
 {"type":"assistant","id":"m6","model":{"providerID":"fakeprov","id":"fake-model-2"},
  "content":[{"type":"text","text":"Noted: pnpm only."}]}]}
P2
}
case "${1:-}" in
  --version|-v) echo "2.0.27 (fake opencode)"; exit 0 ;;
  service) echo "http://127.0.0.1:0"; exit 0 ;;
  api)
    method="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; path="$3"; body=""
    [ "${4:-}" = "--data" ] && body="${5:-}"
    log "api $method $path"
    case "$method $path" in
      "POST /api/session")
        id="$(next_id)"
        printf '%s' "$body" | jq -c --arg id "$id" '. + {id: $id}' > "$S/sessions/$id.json"
        jq -c '{data: .}' "$S/sessions/$id.json"; exit 0 ;;
      "GET /api/session?"*)
        if [ -f "$S/list.json" ]; then
          enc="$(printf '%s' "$path" | sed -n 's/.*[?&]directory=\([^&]*\).*/\1/p')"
          d="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$enc")"
          jq -c --arg d "$d" '{data: [.[] | select(.location.directory == $d)]}' "$S/list.json"
        elif [ -n "${FAKE_OC_RECENT_MODEL:-}" ]; then printf '{"data":[{"id":"ses_old","model":%s}]}\n' "$FAKE_OC_RECENT_MODEL"
        else echo '{"data":[]}'; fi
        exit 0 ;;
      "GET /api/session/"*"/message"*)
        case "$path" in *cursor=c2*) page2 ;; *) page1 ;; esac
        exit 0 ;;
      "GET /api/session/"*)
        id="${path#/api/session/}"
        if [ -f "$S/sessions/$id.json" ]; then jq -c '{data: .}' "$S/sessions/$id.json"; exit 0; fi
        echo '{"_tag":"SessionNotFoundError"}'; echo "HTTP 404 Not Found" >&2; exit 1 ;;
      "DELETE /api/session/"*)
        id="${path#/api/session/}"; echo "$id" >> "$S/deleted.log"; exit 0 ;;
      "PUT /api/experimental/session/"*"/instructions/entries/"*)
        rest="${path#/api/experimental/session/}"; id="${rest%%/*}"; key="${rest##*/}"
        if [ "${FAKE_OC_ENTRIES:-on}" = off ]; then echo '{"_tag":"NotFound"}'; echo "HTTP 404 Not Found" >&2; exit 1; fi
        size="$(printf '%s' "$body" | jq -c '.value' | wc -c | tr -d ' ')"
        if [ "$size" -gt 262145 ]; then
          printf '{"_tag":"InstructionEntryValueTooLargeError","actualBytes":%s,"maxBytes":262144}\n' "$size"
          echo "HTTP 413 Payload Too Large" >&2; exit 1
        fi
        mkdir -p "$S/entries/$id"; printf '%s' "$body" | jq -r '.value' > "$S/entries/$id/$key"
        echo "$id $key $(printf '%s' "$body" | wc -c | tr -d ' ')" >> "$S/puts.log"; exit 0 ;;
      "GET /api/experimental/session/"*"/instructions/entries")
        rest="${path#/api/experimental/session/}"; id="${rest%%/*}"; out='[]'
        for f in "$S/entries/$id"/*; do
          [ -f "$f" ] || continue
          out="$(printf '%s' "$out" | jq -c --arg k "$(basename "$f")" '. + [{key: $k, value: "x"}]')"
        done
        printf '{"data":%s}\n' "$out"; exit 0 ;;
      "DELETE /api/experimental/session/"*"/instructions/entries/"*)
        rest="${path#/api/experimental/session/}"; id="${rest%%/*}"; key="${rest##*/}"
        rm -f "$S/entries/$id/$key"; echo "$id $key" >> "$S/entry-deletes.log"; exit 0 ;;
    esac
    echo '{"_tag":"RouteNotFound"}'; echo "HTTP 404 Not Found" >&2; exit 1 ;;
  run)
    shift; sid=""; model=""; msg=""; files=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) sid="$2"; shift 2 ;;
        --model) model="$2"; shift 2 ;;
        --file) files+=("$2"); shift 2 ;;
        --format) shift 2 ;;
        *) msg="$1"; shift ;;
      esac
    done
    n=$(( $(ls "$S/runs" | wc -l | tr -d ' ') + 1 )); R="$S/runs/$n"; mkdir -p "$R"
    log "run $sid"
    printf '%s\n' "$sid" > "$R/session"; printf '%s\n' "$model" > "$R/model"; printf '%s' "$msg" > "$R/message"
    printf '%s\n' "${GRANDMA_DISTILLING:-unset}" > "$R/distilling"
    cp "$S/sessions/$sid.json" "$R/session.json" 2>/dev/null || true
    for f in ${files[@]+"${files[@]}"}; do cp "$f" "$R/$(basename "$f")"; echo "$f" >> "$R/files"; done
    case "${FAKE_OC_RUN:-propose}" in
      fail)  exit 1 ;;
      hang)  sleep 30; exit 0 ;;
      crash) text="Execution error" ;;
      noop)  text="No durable learnings.

Everything discussed was undecided brainstorm, nothing to persist." ;;
      *)     text="FAKEOC-PROPOSAL
target: globex/facts.md | action: append | text: fake learning
distilling=${GRANDMA_DISTILLING:-unset}" ;;
    esac
    printf '{"type":"step_start","sessionID":"%s"}\n' "$sid"
    jq -nc --arg t "$text" --arg s "$sid" '{type: "text", sessionID: $s, part: {type: "text", text: $t}}'
    exit 0 ;;
esac
sid=""; prompt=""; dirarg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sid="$2"; shift 2 ;;
    --prompt)  prompt="$2"; shift 2 ;;
    --*)       shift ;;
    *)         dirarg="$1"; shift ;;
  esac
done
log "tui $sid"
printf 'session=%s\ndir=%s\ncwd=%s\n--- prompt ---\n%s\n' "$sid" "$dirarg" "$PWD" "$prompt" > "$S/tui-$sid.txt"
[ -n "${FAKE_OC_TUI_CAPTURE:-}" ] && printf -- '- captured mid-session\n' >> "$FAKE_OC_TUI_CAPTURE"
if [ -n "${FAKE_OC_TUI_LIVE:-}" ]; then : > "$FAKE_OC_TUI_LIVE"; exec sleep "${FAKE_OC_TUI_SLEEP:-337}"; fi
[ -t 0 ] && exit 0
cat >/dev/null
exit 0
SHIM
  chmod +x "$dir/opencode"
  printf '%s' "$dir"
}
