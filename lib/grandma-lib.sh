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

# Does this terminal have a real inline-image protocol? Only these can render the GIF crisply.
# Everywhere else (Apple Terminal, most VS Code, plain xterm) an image degrades to colored
# blocks that read as a broken picture — so grandma draws crafted ANSI art there instead.
terminal_supports_graphics() {
  case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm) return 0 ;; esac
  case "${TERM:-}" in *kitty*|*sixel*) return 0 ;; esac
  [[ -n "${KITTY_WINDOW_ID:-}" ]] && return 0
  return 1
}

# Pick a renderer for the mascot GIF, but ONLY on a graphics-capable terminal. imgcat is
# iTerm2-native; chafa auto-detects kitty/sixel/iTerm2 graphics. Echo the tool, or nothing —
# nothing means "no crisp GIF here, use the typographic wordmark instead."
pick_mascot_renderer() {
  terminal_supports_graphics || return 0
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v imgcat >/dev/null 2>&1; then
    echo imgcat
  elif command -v chafa >/dev/null 2>&1; then
    echo chafa
  fi
}

# _grandma_word_frame — one frame of the wordmark: needle tip, six gradient letter rows with a
# standing knitting needle (shaft + pink yarn stitches), and the needle knob. Pre-rendered
# "grandma" (figlet slant), so no figlet dependency. $1 = glint column (-1 = static, no shimmer).
_grandma_word_frame() {
  local c="$1" R=$'\033[0m' TAN=$'\033[38;5;180m' WOOD=$'\033[38;5;137m' STITCH=$'\033[38;5;211m'
  local PAD=48 HL=231 i base l x ch col
  local WL=(
    '                               __               '
    '   ____ __________ _____  ____/ /___ ___  ____ _'
    '  / __ `/ ___/ __ `/ __ \/ __  / __ `__ \/ __ `/'
    ' / /_/ / /  / /_/ / / / / /_/ / / / / / / /_/ / '
    ' \__, /_/   \__,_/_/ /_/\__,_/_/ /_/ /_/\__,_/  '
    '/____/                                          '
  )
  local G=(218 212 206 205 169 168)   # light pink -> deep magenta, per row
  printf '%*s%s▴%s\n' "$((PAD+1))" '' "$TAN" "$R"          # needle tip, above the word
  for i in 0 1 2 3 4 5; do
    base=${G[$i]}; l=${WL[$i]}
    while [ ${#l} -lt "$PAD" ]; do l="$l "; done
    if [ "$c" -lt 0 ]; then
      printf '\033[38;5;%sm%s%s' "$base" "$l" "$R"          # whole row, one color (static)
    else
      x=0                                                    # per-character, with a moving glint
      while [ "$x" -lt ${#l} ]; do
        ch=${l:$x:1}
        if [ "$(( x>=c ? x-c : c-x ))" -le 2 ]; then col=$HL; else col=$base; fi
        printf '\033[38;5;%sm%s' "$col" "$ch"; x=$((x+1))
      done
      printf '%s' "$R"
    fi
    # standing needle beside the row — glyphs are literals in the format (multibyte-safe)
    if [ "$i" -le 2 ]; then printf ' %s┃%s %s◦%s\n' "$TAN" "$R" "$STITCH" "$R"
    else printf ' %s┃%s\n' "$TAN" "$R"; fi
  done
  printf '%*s%s◖●◗%s\n' "$PAD" '' "$WOOD" "$R"             # needle knob, below the word
}

# _grandma_yarn — the knitted yarn thread + tagline. $1 = thread length (0..14).
_grandma_yarn() {
  local n="$1" R=$'\033[0m' D=$'\033[2m' GREY=$'\033[38;5;247m'
  local MAG=$'\033[38;5;205m' BALL=$'\033[38;5;213m' t='' i=0
  while [ "$i" -lt "$n" ]; do t="$t~"; i=$((i+1)); done
  printf '   %s●%s%s%s   %s%sshe remembers everything%s\n' "$BALL" "$MAG" "$t" "$R" "$D" "$GREY" "$R"
}

# grandma_wordmark — a sharp typographic "grandma" logo for terminals with no image protocol
# (Apple Terminal, VS Code, plain xterm), where a raster image only renders as blurry blocks.
# On a wide TTY it plays a light shimmer + a knitting yarn once; otherwise it draws static.
grandma_wordmark() {
  local FULL=14 PAD=48 step=0 c yl cols
  cols=$(tput cols 2>/dev/null); [ -n "$cols" ] || cols=80
  if [ -t 1 ] && [ "${GRANDMA_SPLASH_STATIC:-0}" != "1" ] && [ "$cols" -ge 54 ]; then
    _grandma_word_frame -1; _grandma_yarn 0
    for c in $(seq -3 3 $((PAD+3))); do
      printf '\033[9A'                              # up over 8 word rows + 1 yarn row
      _grandma_word_frame "$c"
      yl=$(( step * FULL / ((PAD+6)/3) )); [ "$yl" -gt "$FULL" ] && yl=$FULL
      _grandma_yarn "$yl"
      step=$((step+1)); sleep 0.025
    done
    printf '\033[9A'; _grandma_word_frame -1; _grandma_yarn "$FULL"   # settle
  else
    _grandma_word_frame -1; _grandma_yarn "$FULL"
  fi
}

# grandma_splash — the "grandma pops up" moment before a session or the interview. On a
# graphics-capable terminal it renders assets/grandma.gif; otherwise it draws the typographic
# wordmark. Shared by launch and init so every entry point matches. Skip with GRANDMA_NO_SPLASH=1.
grandma_splash() {
  [[ "${GRANDMA_NO_SPLASH:-0}" == "1" ]] && return 0
  local scope="$1" gif="$ENGINE/assets/grandma.gif"
  local P=$'\033[95m' B=$'\033[1m' D=$'\033[2m' R=$'\033[0m'
  local shown=0
  printf '\n'
  if [[ -f "$gif" ]]; then
    case "$(pick_mascot_renderer)" in
      imgcat) imgcat --height "${GRANDMA_SPLASH_HEIGHT:-16}" "$gif" 2>/dev/null && shown=1 ;;
      chafa)  chafa --animate off --size "${GRANDMA_SPLASH_SIZE:-40x20}" "$gif" 2>/dev/null && shown=1 ;;
    esac
  fi
  if [[ "$shown" == 1 ]]; then
    printf '  %s%sGRANDMA%s  %sshe remembers everything%s\n' "$B" "$P" "$R" "$D" "$R"   # text under the GIF
  else
    grandma_wordmark                                                                    # the wordmark IS the text
  fi
  printf '  %sfetching %s memory...%s\n\n' "$D" "$scope" "$R"
  sleep "${GRANDMA_SPLASH_SECS:-0.7}"
}

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
