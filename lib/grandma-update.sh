#!/usr/bin/env bash
#
# grandma-update — pull the latest engine, or print its version.
#
# The engine is a git checkout (install.sh clones it), so an update is a fast-forward pull:
# it never rewrites history and never forces. On success it prints the new version and the
# top of the CHANGELOG. `--version` (or `version`) just prints the running version and exits.
# GRANDMA_DRY_RUN=1 prints the plan and pulls nothing.
set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # ROOT is read by note_engine_updated / update_state_file in grandma-lib.sh
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
source "$ENGINE/lib/grandma-lib.sh"

case "${1:-}" in
  version|--version|-v) printf 'grandma %s\n' "$(engine_version)"; exit 0 ;;
esac

if ! engine_is_git; then
  printf '  this grandma engine is not a git checkout (%s), so there is nothing to pull.\n' "$ENGINE" >&2
  printf '  reinstall to update — the one-line installer is in the grandma README.\n' >&2
  exit 1
fi

before="$(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null)"

if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  printf '  would run: git -C %s pull --ff-only\n' "$ENGINE" >&2
  printf '  current:   grandma %s\n' "$(engine_version)" >&2
  exit 0
fi

printf '  updating grandma engine at %s ...\n' "$ENGINE" >&2
if ! git -C "$ENGINE" pull --ff-only; then
  printf '  update failed. If the engine has local changes, stash or reset them, or reinstall.\n' >&2
  exit 1
fi
note_engine_updated   # reset the staleness nudge

after="$(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null)"
if [[ "$before" == "$after" ]]; then
  printf '  already up to date — grandma %s\n' "$(engine_version)" >&2
else
  printf '  updated grandma: %s -> %s\n\n' "$before" "$after" >&2
  if [[ -f "$ENGINE/CHANGELOG.md" ]]; then
    printf '  what changed (top of CHANGELOG.md):\n' >&2
    # print the first ## section (heading + body), stop at the next ##
    awk 'BEGIN{c=0} /^## /{c++} c==1{print "    " $0} c==2{exit}' "$ENGINE/CHANGELOG.md" >&2
  fi
fi
