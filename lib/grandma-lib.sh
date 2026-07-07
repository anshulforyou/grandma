#!/usr/bin/env bash
# grandma-lib — shared helpers. Source this; it expects $ROOT (grandma repo root) set.

# Resolve a scope name (case-insensitive) to its dir under ROOT. Prints dir or fails.
resolve_scope_dir() {
  local d name
  for d in "$ROOT"/*/; do
    name="$(basename "$d")"; [[ "$name" == "global" ]] && continue
    if [[ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]]; then
      printf '%s' "${d%/}"; return 0
    fi
  done
  return 1
}

# Normalize a name for fuzzy matching: lowercase, alphanumeric only.
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }

# Emit "rawname<TAB>dir" for each project in a scope's projects.md (dir = folder holding CLAUDE.md).
project_entries() {
  local reg="$1"
  [[ -f "$reg" ]] || return 0
  awk '
    /^## / { raw=substr($0,4); sub(/[ \t]+$/,"",raw); haveraw=1; next }
    /^- source:/ && haveraw==1 {
      src=$0; sub(/^- source:[ \t]*/,"",src); sub(/[ \t]+$/,"",src);
      dir=src; sub(/\/[^\/]*$/,"",dir);
      print raw "\t" dir; haveraw=0
    }
  ' "$reg"
}

# Fuzzy-resolve a project name against a scope dir's registry.
# Sets RP_STATUS (OK|AMBIG|NONE), RP_NAME, RP_DIR, RP_CANDS.
resolve_project() {
  local reg="$1/projects.md" q raw dir nraw matches=0
  q="$(norm "$2")"
  RP_STATUS=NONE; RP_NAME=""; RP_DIR=""; RP_CANDS=""
  while IFS=$'\t' read -r raw dir; do
    [[ -z "$raw" ]] && continue
    nraw="$(norm "$raw")"
    if [[ -n "$q" && ( "$nraw" == *"$q"* || "$q" == *"$nraw"* ) ]]; then
      matches=$((matches+1)); RP_NAME="$raw"; RP_DIR="$dir"
      RP_CANDS+="${RP_CANDS:+, }$raw"
    fi
  done < <(project_entries "$reg")
  if   [[ $matches -eq 1 ]]; then RP_STATUS=OK
  elif [[ $matches -gt 1 ]]; then RP_STATUS=AMBIG; fi
}

# Munge an absolute path to its Claude projects dir name (/ -> -).
claude_proj_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$1" | sed 's#/#-#g')"; }

# List scope names: a scope dir is one whose top-level .md has `scope:` frontmatter
# (excludes global, prompts, assets, proposals, tools, test, etc.).
list_scopes() {
  local d n
  for d in "$ROOT"/*/; do
    n="$(basename "$d")"; [[ "$n" == "global" ]] && continue
    if grep -lqE '^scope:' "$d"/*.md 2>/dev/null; then echo "$n"; fi
  done
}
