#!/usr/bin/env bash
#
# grandma-completions - shell tab-completion for `grandma`.
#
# Completes the first word against your sweaters (plus the subcommands), and the second
# word against the projects registered under the named sweater. The generated scripts do
# NOT source the engine into your interactive shell (zsh breaks BASH_SOURCE and globbing);
# they shell out to `grandma completions __scopes` / `__projects` / `__watch_commands`,
# which run under bash.
#
# Usage:
#   grandma completions bash      print the bash completion script
#   grandma completions zsh       print the zsh completion script
#
# Enable (see README):
#   bash:  eval "$(grandma completions bash)"     # add to ~/.bashrc
#   zsh:   eval "$(grandma completions zsh)"       # add to ~/.zshrc (needs compinit)

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # ROOT is read by the sourced grandma-lib.sh helpers (list_scopes, resolve_scope_dir)
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"

# First-word candidates that are NOT sweaters: the reserved subcommands (keep in sync with
# bin/grandma). A sweater whose name collides with one of these is shadowed, as documented.
SUBCOMMANDS="init save review search ingest watch test doctor completions update version help"
WATCH_COMMANDS="start tick list status report finish notify-test install-agent"

# _gc_scopes - completable first words: every sweater, then the subcommands.
_gc_scopes() {
  list_scopes 2>/dev/null || true
  printf '%s\n' $SUBCOMMANDS
}

# _gc_projects <scope> - emit "token<TAB>full name" per registered project, deduped by token.
# The token is the first whitespace-delimited word of the project's display name: it is
# space-free (so it survives as a single CLI arg) and resolve_project fuzzy-matches it back
# to the full name. The full name rides along as a zsh completion description.
_gc_projects() {
  local dir
  dir="$(resolve_scope_dir "$1" 2>/dev/null)" || return 0
  [[ -n "$dir" ]] || return 0
  project_entries "$dir/projects.md" | awk -F'\t' '
    { raw=$1; n=split(raw, a, /[ \t]+/); tok=a[1] }
    tok != "" && !seen[tok]++ { print tok "\t" raw }
  '
}

# _gc_watch_commands - emit the verbs accepted by `grandma watch`.
_gc_watch_commands() {
  printf '%s\n' $WATCH_COMMANDS
}

# _gc_emit_bash - the bash completion script (quoted heredoc: emitted verbatim).
_gc_emit_bash() {
  cat <<'BASH'
# grandma bash completion. Enable with:  eval "$(grandma completions bash)"
_grandma_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "--full --writing" -- "$cur") )
    return 0
  fi
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$(grandma completions __scopes 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_CWORD} -eq 2 ]]; then
    case "${COMP_WORDS[1]}" in
      save|review|ingest|test|search)
        COMPREPLY=( $(compgen -W "$(grandma completions __scopes 2>/dev/null)" -- "$cur") ) ;;
      watch)
        COMPREPLY=( $(compgen -W "$(grandma completions __watch_commands 2>/dev/null)" -- "$cur") ) ;;
      *)
        COMPREPLY=( $(compgen -W "$(grandma completions __projects "${COMP_WORDS[1]}" 2>/dev/null | cut -f1)" -- "$cur") ) ;;
    esac
  fi
  return 0
}
complete -F _grandma_complete grandma
BASH
}

# _gc_emit_zsh - the zsh completion script (native compsys; shows full project names as
# descriptions). Requires compinit (autoload -Uz compinit && compinit) in the user's zshrc.
_gc_emit_zsh() {
  cat <<'ZSH'
# grandma zsh completion. Enable with:  eval "$(grandma completions zsh)"
# (needs compinit first:  autoload -Uz compinit && compinit)
_grandma_complete() {
  local cur="${words[CURRENT]}"
  local -a scopes watch_commands lines toks descs
  if [[ "$cur" == -* ]]; then
    compadd -- --full --writing
    return 0
  fi
  if (( CURRENT == 2 )); then
    scopes=(${(f)"$(grandma completions __scopes 2>/dev/null)"})
    compadd -a scopes
  elif (( CURRENT == 3 )); then
    case "${words[2]}" in
      save|review|ingest|test|search)
        scopes=(${(f)"$(grandma completions __scopes 2>/dev/null)"})
        compadd -a scopes ;;
      watch)
        watch_commands=(${(f)"$(grandma completions __watch_commands 2>/dev/null)"})
        compadd -a watch_commands ;;
      *)
        lines=(${(f)"$(grandma completions __projects ${words[2]} 2>/dev/null)"})
        local l
        for l in $lines; do
          toks+=("${l%%$'\t'*}")
          descs+=("${l#*$'\t'}")
        done
        (( ${#toks} )) && compadd -d descs -a toks ;;
    esac
  fi
}
compdef _grandma_complete grandma
ZSH
}

case "${1:-}" in
  bash)        _gc_emit_bash ;;
  zsh)         _gc_emit_zsh ;;
  __scopes)    _gc_scopes ;;
  __projects)  shift; _gc_projects "${1:-}" ;;
  __watch_commands) _gc_watch_commands ;;
  *)           echo "usage: grandma completions <bash|zsh>" >&2; exit 2 ;;
esac
