#!/usr/bin/env bash
#
# grandma-status — one screen for the whole memory home.
#
# Read-only: it reports what is there without opening a session or touching a file.
#
# Usage:
#   grandma status
#
# Per sweater it prints the number of registered projects and the number of pending
# review proposals, then two home-wide lines: whether tracked memory has uncommitted
# changes, and whether any watch has a finished report you have not read.
#
# Everything here is counted with the helpers that already own these questions, rather
# than re-deriving them:
#
#   projects   project_entries on the sweater's projects.md — the registry is the source
#              of truth, not the projects/ directory, which also holds unregistered work.
#   proposals  list_proposals, which matches the `# scope=` header INSIDE each file. The
#              filename cannot be matched safely: proposals are <scope>[-<project>]-<stamp>.md
#              and both parts may contain dashes, so a `home-` prefix also catches home-ops.
#   dirty      git -C $ROOT status --porcelain on markdown only. proposals/ and watches/ are
#              gitignored scratch, so they are not memory and must not read as unsaved work.
#   unread     watches/*/report.md with no sibling .seen.
#
# A home that is not a git repository is not an error: memory works without one, so the
# dirty line says so rather than failing.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
source "$ENGINE/lib/grandma-lib.sh"

[[ -d "$ROOT" ]] || { echo "no memory home at $ROOT — run: grandma init" >&2; exit 1; }

# count_lines <<< output — `wc -l` alone counts 1 for an empty string, because the here-string
# adds a trailing newline. Every count below is zero for an empty sweater, so that matters.
count_lines() {
  local n=0 line
  while IFS= read -r line; do [[ -n "$line" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}

printf 'memory home: %s\n\n' "$ROOT"

scopes=()
while IFS= read -r s; do [[ -n "$s" ]] && scopes+=("$s"); done < <(list_scopes)

if [[ "${#scopes[@]}" -eq 0 ]]; then
  printf '  no sweaters yet — start one with: grandma <name>\n'
else
  for sc in ${scopes[@]+"${scopes[@]}"}; do
    projects="$(project_entries "$ROOT/$sc/projects.md" | count_lines)"
    pending="$(list_proposals "$sc" | count_lines)"
    line="$(printf '  %-18s %s project' "$sc" "$projects")"
    [[ "$projects" == "1" ]] || line="${line}s"
    if [[ "$pending" != "0" ]]; then
      line="$(printf '%s, %s pending proposal' "$line" "$pending")"
      [[ "$pending" == "1" ]] || line="${line}s"
    fi
    printf '%s\n' "$line"
  done
fi

printf '\n'

if [[ -d "$ROOT/.git" ]]; then
  dirty="$(git -C "$ROOT" status --porcelain -- '*.md' 2>/dev/null | count_lines)"
  if [[ "$dirty" == "0" ]]; then
    printf '  memory:  saved\n'
  else
    printf '  memory:  %s file(s) with unsaved changes\n' "$dirty"
  fi
else
  printf '  memory:  not under git (nothing to save against)\n'
fi

unread=0
for r in "$ROOT"/watches/*/report.md; do
  [[ -f "$r" ]] || continue
  [[ -f "$(dirname "$r")/.seen" ]] || unread=$((unread + 1))
done
if [[ "$unread" == "0" ]]; then
  printf '  watches: no unread reports\n'
else
  printf '  watches: %s unread report(s) — grandma watch list\n' "$unread"
fi
