#!/usr/bin/env bash
#
# grandma-review — review memory proposals produced by auto-distill (SessionEnd).
#
# Auto-distill writes proposals to grandma/proposals/ after each session. This lists
# them, prints their contents, and can apply one interactively.
#
# Usage:
#   grandma-review [scope]            list + print pending proposals (optionally filtered)
#   grandma-review --apply <file>     open a session to apply that proposal, then delete it
#   grandma-review --clear [scope]    discard pending proposals (optionally filtered)

set -euo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"
ASSEMBLE="$ENGINE/lib/assemble.sh"
PROP="$ROOT/proposals"

MODE=list
SCOPE=""
FILE=""
NEXT_IS_FILE=0
for arg in "$@"; do
  case "$arg" in
    --apply) MODE=apply; NEXT_IS_FILE=1 ;;
    --clear) MODE=clear ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) if [[ "$NEXT_IS_FILE" == "1" ]]; then FILE="$arg"; NEXT_IS_FILE=0; else SCOPE="$arg"; fi ;;
  esac
done

mkdir -p "$PROP"

# ---- apply one proposal interactively ----
if [[ "$MODE" == "apply" ]]; then
  [[ -f "$FILE" ]] || FILE="$PROP/$FILE"
  [[ -f "$FILE" ]] || { echo "error: proposal not found: $FILE" >&2; exit 1; }
  # Scope is the leading portion of the filename (scope[-project]-<transcript>.md). Scope
  # names are kebab-case, so we cannot cut on the first '-' (that turns 'home-ops' into
  # 'home'). Pick the LONGEST leading dash-joined prefix that resolves to a real scope dir.
  RSCOPE=""
  _base="$(basename "$FILE" .md)"
  IFS='-' read -ra _toks <<< "$_base"
  _pfx=""
  for _t in ${_toks[@]+"${_toks[@]}"}; do
    _pfx="${_pfx:+$_pfx-}$_t"
    resolve_scope_dir "$_pfx" >/dev/null 2>&1 && RSCOPE="$_pfx"
  done
  [[ -n "$RSCOPE" ]] || RSCOPE="${_toks[0]}"
  SYS="You are applying a pre-computed grandma memory proposal. The proposal file is at
$FILE and lists target files, actions, and exact text. Current memory:

$("$ASSEMBLE" "$RSCOPE" --full 2>/dev/null || true)

Read the proposal, show it to the user, apply ONLY the edits they approve (respect the
memory rules: one fact per line, update in place, no LLM artifacts, absolute dates).
Commit sweater/global edits in the grandma repo with a short message. Project CLAUDE.md
edits live in that project's own working tree (not committed by grandma git). When done and
the user confirms, delete the proposal file $FILE. If they reject everything, delete it and stop."
  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    echo "would apply: $FILE (scope=$RSCOPE)" >&2; exit 0
  fi
  cd "$ROOT"
  exec claude --name "grandma:review" --append-system-prompt "$SYS" \
    "Apply the memory proposal at $FILE. Walk me through it, apply what I approve, commit, then delete the proposal."
fi

# ---- clear ----
if [[ "$MODE" == "clear" ]]; then
  shopt -s nullglob
  files=("$PROP/${SCOPE:+$SCOPE}"*.md); [[ -z "$SCOPE" ]] && files=("$PROP"/*.md)
  if [[ ${#files[@]} -eq 0 ]]; then echo "no proposals to clear."; exit 0; fi
  rm -f "${files[@]}"; echo "cleared ${#files[@]} proposal(s)."; exit 0
fi

# ---- list + print ----
shopt -s nullglob
if [[ -n "$SCOPE" ]]; then files=("$PROP/$SCOPE"*.md); else files=("$PROP"/*.md); fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "no pending proposals${SCOPE:+ for $SCOPE}."
  exit 0
fi
echo "pending memory proposals${SCOPE:+ for $SCOPE}: ${#files[@]}"
echo
for f in "${files[@]}"; do
  echo "======================================================================"
  echo "$f"
  echo "----------------------------------------------------------------------"
  cat "$f"
  echo
done
echo "apply one with:  grandma-review --apply <file>"
echo "discard with:    grandma-review --clear${SCOPE:+ $SCOPE}"
