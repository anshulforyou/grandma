#!/usr/bin/env bash
#
# grandma-search — grep across your memory.
#
# Read-only: it finds things in your memory without opening a session or touching a file.
#
# Usage:
#   grandma search <query...>              search global + every sweater
#   grandma search <sweater> <query...>    search one sweater only
#   grandma search --all <query...>        force the every-sweater form
#
# The first word counts as a sweater ONLY when it names a real sweater AND at least one
# more word follows. So a one-word search is always a query, never a sweater, and when a
# query's first word collides with a sweater name, --all forces the wide read.
#
# Scoped search covers that sweater alone — NOT global. "Scoped to one" should mean one,
# so a hit always tells you which sweater owns the memory. Use the wide form for global.
#
# Matching is a case-insensitive FIXED string, not a regex. BSD grep, GNU grep and ripgrep
# agree on literals but diverge on patterns, and a memory search that answers differently
# depending on which machine you are sitting at is worse than one that cannot do regex.
# Multiple words are joined with a single space and matched as one literal.
#
# Searched: global/ and each sweater folder. Deliberately NOT searched: proposals/ and
# watches/ (gitignored scratch — not memory until you accept it) and .distill/ (staged
# transcripts). Those directories are simply never passed to the search tool, which is
# also why no --exclude flag is needed: BSD and GNU spell those differently.
#
# ripgrep is used when it is on PATH, grep otherwise, so this adds no hard dependency.
# GRANDMA_SEARCH_TOOL=rg|grep|auto pins the engine (default auto) — the test suite uses
# it to exercise both paths on one machine.
#
# Output: <file>:<line>:<text>, paths relative to GRANDMA_HOME, like grep. A one-line
# summary goes to stderr, so `grandma search x | ...` pipes only matches.
#
# Exit: 0 matches found · 1 no matches (grep's convention, so `grandma search x || ...`
# works as expected) · 2 usage error.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"

usage() {
  cat <<'USAGE'
usage: grandma search <query...>            search global + every sweater
       grandma search <sweater> <query...>  search one sweater only
       grandma search --all <query...>      force the every-sweater form

Matches a case-insensitive literal string. Prints <file>:<line>:<text>.
Exit 0 = matches, 1 = no matches, 2 = usage error.
USAGE
}

# ---- args ----
ALL=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --all)          ALL=1 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown flag: $arg" >&2; usage >&2; exit 2 ;;
    *)              ARGS+=("$arg") ;;
  esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then usage >&2; exit 2; fi

# ---- split off a leading sweater, if that is what it is ----
SCOPE=""
if [[ "$ALL" -eq 0 && ${#ARGS[@]} -ge 2 ]] && resolve_scope_dir "${ARGS[0]}" >/dev/null 2>&1; then
  SCOPE="${ARGS[0]}"
  ARGS=("${ARGS[@]:1}")
fi
QUERY="${ARGS[*]}"

# ---- which directories to search (naming them IS the exclusion of proposals/watches) ----
DIRS=()
if [[ -n "$SCOPE" ]]; then
  # resolve_scope_dir gives the real (case-correct) folder; search it by name, relative to ROOT
  DIRS=("$(basename "$(resolve_scope_dir "$SCOPE")")")
else
  [[ -d "$ROOT/global" ]] && DIRS+=(global)
  while IFS= read -r s; do [[ -n "$s" ]] && DIRS+=("$s"); done < <(list_scopes)
fi

if [[ ${#DIRS[@]} -eq 0 ]]; then
  echo "no memory to search at $ROOT — run 'grandma init', or 'grandma' to knit a sweater." >&2
  exit 1
fi

cd "$ROOT" 2>/dev/null || { echo "error: no memory home at $ROOT" >&2; exit 2; }

# ---- pick the engine ----
TOOL="${GRANDMA_SEARCH_TOOL:-auto}"
case "$TOOL" in
  auto)     if command -v rg >/dev/null 2>&1; then TOOL="rg"; else TOOL="grep"; fi ;;
  rg)       command -v rg >/dev/null 2>&1 || TOOL="grep" ;;   # asked for rg, has none: degrade
  grep)     ;;
  *)        echo "unknown GRANDMA_SEARCH_TOOL '$TOOL' (want rg, grep or auto)" >&2; exit 2 ;;
esac

# --no-ignore keeps ripgrep from honoring the memory repo's .gitignore, so both engines
# see the same files. -I means "skip binary" to grep but "hide the filename" to ripgrep —
# hence it goes to grep only; ripgrep skips binary files on its own.
out=""
if [[ "$TOOL" == "rg" ]]; then
  out="$(rg --no-heading --with-filename --line-number --color never --no-ignore --sort path \
          -F -i -- "$QUERY" ${DIRS[@]+"${DIRS[@]}"} 2>/dev/null)"
else
  out="$(grep -rn -I -F -i -- "$QUERY" ${DIRS[@]+"${DIRS[@]}"} 2>/dev/null)"
fi

if [[ -z "$out" ]]; then
  printf '  no memory matches "%s"%s\n' "$QUERY" "${SCOPE:+ in $SCOPE}" >&2
  exit 1
fi

printf '%s\n' "$out"
n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
nf="$(printf '%s\n' "$out" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')"
printf '  %s match(es) in %s file(s)%s\n' "$n" "$nf" "${SCOPE:+ · sweater $SCOPE}" >&2
