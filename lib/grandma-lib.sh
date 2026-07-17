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
# shellcheck disable=SC2034  # RP_STATUS/RP_NAME/RP_DIR/RP_CANDS are outputs read by callers
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

# ---- portability helpers (BSD/macOS vs GNU/Linux) ----
# GNU form (-c) FIRST: on Linux it succeeds cleanly; on macOS it fails with no stdout, so
# the BSD (-f) fallback runs. The reverse order is unsafe — GNU parses `stat -f %m FILE` as
# `-f` (file-system mode) plus a bogus filename `%m`, printing the real file's fs block
# ("File: ...") to stdout AND exiting nonzero, which then also runs the fallback and yields
# contaminated output. That fed non-numeric junk into arithmetic (the watch tick crash).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
file_size()  { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }
epoch_date() { date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d' 2>/dev/null || echo "$1"; }
notify_user() {
  # title, body — macOS notification, Linux notify-send, else silent
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" 2>/dev/null \
    || notify-send "$1" "$2" 2>/dev/null || true
}

# Select a model CLI adapter: environment, sweater frontmatter, home config, default.
grandma_select_cli() { # optional sweater name
  local sweater="${1:-}" selected="${GRANDMA_CLI:-}" dir="" file="" value=""
  if [[ -z "$selected" && -n "$sweater" ]]; then
    dir="$(resolve_scope_dir "$sweater" 2>/dev/null || true)"
    if [[ -n "$dir" ]]; then
      for file in "$dir"/*.md; do
        [[ -f "$file" ]] || continue
        value="$(awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit}
          f && /^[[:space:]]*cli:[[:space:]]*/ {sub(/^[[:space:]]*cli:[[:space:]]*/,"");
          gsub(/[[:space:]]+$/,""); print; exit}' "$file")"
        [[ -n "$value" ]] && { selected="$value"; break; }
      done
    fi
  fi
  if [[ -z "$selected" ]]; then
    for file in "$ROOT/config" "$ROOT/config.md"; do
      [[ -f "$file" ]] || continue
      value="$(sed -n 's/^[[:space:]]*cli:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$file" | head -n1)"
      [[ -n "$value" ]] && { selected="$value"; break; }
    done
  fi
  selected="$(printf '%s' "${selected:-claude}" | tr '[:upper:]' '[:lower:]')"
  case "$selected" in (*[!a-z0-9_-]*|'') echo "invalid grandma CLI adapter: $selected" >&2; return 2 ;; esac
  printf '%s' "$selected"
}

grandma_load_adapter() { # optional sweater name
  GRANDMA_CLI_SELECTED="$(grandma_select_cli "${1:-}")" || return
  GRANDMA_ADAPTER="$ENGINE/lib/adapters/$GRANDMA_CLI_SELECTED.sh"
  [[ -r "$GRANDMA_ADAPTER" ]] || {
    echo "unknown grandma CLI adapter '$GRANDMA_CLI_SELECTED'" >&2; return 2;
  }
  # shellcheck source=/dev/null
  source "$GRANDMA_ADAPTER"
  command -v adapter_capabilities >/dev/null 2>&1 \
    && command -v adapter_headless >/dev/null 2>&1 \
    && command -v adapter_launch >/dev/null 2>&1 || {
      echo "adapter '$GRANDMA_CLI_SELECTED' is missing a required function" >&2; return 2;
    }
}
