#!/usr/bin/env bash
# Behavioral tests for `grandma completions` - shell tab-completion.
#
# Bites: before this feature `grandma completions` did not exist (it fell through to launch
# and errored). The listers must survive set -u, name every sweater plus the subcommands, and
# resolve a KEBAB scope (home-ops) to a SPACE-FREE project token (a multi-word raw name like
# "Billing API" inserted verbatim would be parsed as a task, not a project).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"

section "completions - first-word candidates (sweaters + subcommands)"
capture env "$GBIN" completions __scopes
assert_rc 0 "completions __scopes runs under set -u"
assert_contains "globex" "lists the plain sweater"
assert_contains "home-ops" "lists the kebab sweater"
assert_contains "save" "includes the subcommands as first-word candidates"
assert_contains "completions" "includes the completions subcommand itself"

section "completions - watch commands"
capture env "$GBIN" completions __watch_commands
assert_rc 0 "watch command lister runs under set -u"
for command in start tick list status report finish notify-test install-agent; do
  assert_contains "$command" "lists watch command '$command'"
done

section "completions - projects under a scope (kebab-safe)"
capture env "$GBIN" completions __projects home-ops
assert_rc 0 "completions __projects home-ops runs (kebab scope resolves, not truncated to 'home')"
assert_contains "Yard" "offers the kebab scope's project"

section "completions - a multi-word project becomes a space-free token"
# "Billing API" would be split into a task if passed whole; completion offers the first token.
tok="$(env "$GBIN" completions __projects globex | cut -f1)"
[ "$tok" = "Billing" ] && ok "first token of 'Billing API' is the space-free 'Billing'" \
  || fail "expected token 'Billing', got '$tok'"
desc="$(env "$GBIN" completions __projects globex | cut -f2)"
[ "$desc" = "Billing API" ] && ok "full name rides along as a zsh completion description" \
  || fail "expected description 'Billing API', got '$desc'"

section "completions - emits shell scripts that register the completion"
capture env "$GBIN" completions bash
assert_rc 0 "completions bash runs"
assert_contains "complete -F _grandma_complete grandma" "bash script registers the completion"
assert_contains "grandma completions __scopes" "bash script calls the scope lister at TAB time"
capture env "$GBIN" completions zsh
assert_rc 0 "completions zsh runs"
assert_contains "compdef _grandma_complete grandma" "zsh script registers via compdef"

section "completions - subcommand routing"
# Source the generated bash completion exactly as a user would. A function named grandma
# keeps its helper calls inside this fixture rather than depending on an installed command.
grandma() { "$GBIN" "$@"; }
eval "$("$GBIN" completions bash)"

for sub in save review ingest test; do
  COMP_WORDS=(grandma "$sub" h); COMP_CWORD=2; COMPREPLY=()
  _grandma_complete
  # shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
  LAST_OUT="${COMPREPLY[*]}"
  # shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
  LAST_RC=0
  assert_rc 0 "$sub completion runs"
  assert_contains "home-ops" "$sub completes sweaters, including kebab-case names"
done

COMP_WORDS=(grandma watch s); COMP_CWORD=2; COMPREPLY=()
_grandma_complete
# shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
LAST_OUT="${COMPREPLY[*]}"
# shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
LAST_RC=0
assert_rc 0 "watch completion runs"
assert_contains "start" "watch completes its subcommands"
assert_contains "status" "watch includes every matching subcommand"

COMP_WORDS=(grandma globex B); COMP_CWORD=2; COMPREPLY=()
_grandma_complete
# shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
LAST_OUT="${COMPREPLY[*]}"
# shellcheck disable=SC2034  # read by assert helpers from test/lib/assert.sh
LAST_RC=0
assert_rc 0 "launch completion still runs"
assert_contains "Billing" "launch completion still offers projects"

if command -v zsh >/dev/null 2>&1; then
  capture env GBIN="$GBIN" GRANDMA_HOME="$GRANDMA_HOME" zsh -fc '
    grandma() { "$GBIN" "$@"; }
    compdef() { :; }
    compadd() {
      local target
      if [[ "$1" == "-a" ]]; then
        target="$2"
        print -rl -- "${(@P)target}"
      fi
    }
    eval "$("$GBIN" completions zsh)"
    words=(grandma save h); CURRENT=3; _grandma_complete
    words=(grandma watch s); CURRENT=3; _grandma_complete
  '
  assert_rc 0 "zsh subcommand completion runs"
  assert_contains "home-ops" "zsh scope-taking subcommands complete sweaters"
  assert_contains "start" "zsh watch completion lists watch subcommands"
else
  skip "zsh is unavailable"
fi

section "completions - bad or empty args are graceful, not crashes"
capture env "$GBIN" completions
assert_rc 2 "bare 'completions' prints usage and exits 2"
assert_contains "usage: grandma completions" "prints usage"
capture env "$GBIN" completions __projects definitely-not-a-scope
assert_rc 0 "projects for an unknown scope is empty, not an error"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_completions: PASS"; else echo "cmd_completions: $FAILS FAILURE(S)"; exit 1; fi
