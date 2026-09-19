#!/usr/bin/env bash
# grandma-lib — shared helpers. Source this; it expects $ROOT (grandma repo root) set.

# Resolve a scope name (case-insensitive) to its dir under ROOT. Prints dir or fails.
# It resolves through list_scopes, NOT a bare directory match, so only a real sweater can
# be loaded. Matching any directory meant `grandma proposals` assembled every sweater's
# pending proposals into one session, and `grandma watches` / `grandma docs` did the same
# for whatever happened to sit in the home. The isolation suite could never catch it:
# list_scopes excludes those directories, so they were never among the scopes under test.
resolve_scope_dir() {
  local name q
  q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" == "$q" ]]; then
      printf '%s' "$ROOT/$name"; return 0
    fi
  done < <(list_scopes)
  return 1
}

# canonical_scope <name> — the sweater's own spelling, lowercased. Everything that builds
# or matches a per-sweater FILENAME must go through this, because resolution is
# case-insensitive while filename globbing is not: `grandma Aarc` used to write
# Aarc-<id>.md, which `grandma review aarc` and the launch-time review offer could never
# see again. Prints nothing and fails when the name is not a sweater.
canonical_scope() {
  local dir; dir="$(resolve_scope_dir "$1")" || return 1
  basename "$dir" | tr '[:upper:]' '[:lower:]'
}

# list_proposals <scope> — this sweater's pending proposal files, one path per line (no
# output when there are none, and none at all when the name is not a sweater).
#
# It matches the `# scope=` header the distiller writes INSIDE each proposal, not the
# filename. Filenames cannot be matched safely: they are <scope>[-<project>]-<stamp>.md and
# both a sweater and a project may contain dashes, so no prefix pattern separates `home`
# from `home-ops`. Globbing on a bare prefix meant `grandma review persona` listed
# personal-chores proposals, `--clear persona` would have deleted them, and the launch-time
# review offer handed a persona session another sweater's memory to apply. Adding a trailing
# dash does not fix it either, since `home-` still matches `home-ops-<stamp>.md`.
# A proposal with no header (hand-written) falls back to the prefix, which is the only thing
# left to go on.
list_proposals() {
  local scope f hdr
  scope="$(canonical_scope "$1")" || return 0
  for f in "$ROOT"/proposals/*.md; do
    [[ -f "$f" ]] || continue
    # `|| true` is load-bearing: grep exits 1 on a proposal with no scope header, and every
    # caller runs under `set -euo pipefail`, so without it the first headerless proposal
    # aborts the whole listing and the sweater silently appears to have nothing pending.
    hdr="$(sed -n '1,5p' "$f" 2>/dev/null | grep -m1 -oE '^# scope=[^ ]+' | sed 's/^# scope=//' \
           | tr '[:upper:]' '[:lower:]' || true)"
    if [[ -n "$hdr" ]]; then
      [[ "$hdr" == "$scope" ]] && printf '%s\n' "$f"
    else
      case "$(basename "$f")" in "$scope"-*) printf '%s\n' "$f" ;; esac
    fi
  done
  return 0
}

# read_proposals <scope> — fill the caller's PROPOSAL_FILES array with list_proposals.
# Kept as a helper because every caller needs the same space-safe read loop.
# shellcheck disable=SC2034  # PROPOSAL_FILES is the output, read by callers
read_proposals() {
  local f; PROPOSAL_FILES=()
  while IFS= read -r f; do [[ -n "$f" ]] && PROPOSAL_FILES+=("$f"); done < <(list_proposals "$1")
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
  local reg="$1/projects.md" q raw dir nraw sc best=0 nbest=0
  q="$(norm "$2")"
  RP_STATUS=NONE; RP_NAME=""; RP_DIR=""; RP_CANDS=""
  [[ -z "$q" ]] && return
  # Rank each candidate and keep only the best tier, so a strong match beats a weak one
  # instead of colliding into AMBIG. Tiers: 4 exact, 3 the name starts with the query
  # (rainforest-midnight (...) for 'rainforest-midnight'), 2 the query is somewhere in the
  # name, 1 the name is a fragment of the query (the weak 'rainforest' case). Only true ties
  # at the top tier are ambiguous.
  while IFS=$'\t' read -r raw dir; do
    [[ -z "$raw" ]] && continue
    nraw="$(norm "$raw")"
    sc=0
    if   [[ "$nraw" == "$q" ]];   then sc=4
    elif [[ "$nraw" == "$q"* ]];  then sc=3
    elif [[ "$nraw" == *"$q"* ]]; then sc=2
    elif [[ "$q" == *"$nraw"* ]]; then sc=1
    fi
    [[ "$sc" -eq 0 ]] && continue
    if   (( sc > best )); then best=$sc; nbest=1; RP_NAME="$raw"; RP_DIR="$dir"; RP_CANDS="$raw"
    elif (( sc == best )); then nbest=$((nbest+1)); RP_NAME="$raw"; RP_DIR="$dir"; RP_CANDS+="${RP_CANDS:+, }$raw"
    fi
  done < <(project_entries "$reg")
  if   [[ $nbest -eq 1 ]]; then RP_STATUS=OK
  elif [[ $nbest -gt 1 ]]; then RP_STATUS=AMBIG; fi
}

# scope_name_is_reserved <name> — is this name structurally unusable as a sweater?
#
# Deliberately NARROW: the CLI subcommands (a sweater by that name is shadowed and can never
# be launched) and the directories grandma owns inside the memory home (loading one would
# assemble whatever sits in it). Those two lists are facts about the engine, not judgements.
#
# It does NOT scan the engine's source for the name, which was the first attempt. That
# refused `job-search`, `work`, `personal`, `home`, `client`, `acme` and `reddit` — the exact
# names grandma's own README and prompts hand people as examples. Those names really do fail
# the core-purity invariant today, but the defect there is the invariant matching prose in
# prompt files rather than engine logic, and the cure is to fix that check, not to refuse the
# names the product recommends. Tracked separately; see docs/architecture.md.
scope_name_is_reserved() {
  local q
  q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$q" ]] || return 0
  case "$q" in
    init|save|review|search|ingest|watch|knit|mcp|test|doctor|completions|update|version|help) return 0 ;;
    global|proposals|watches|templates) return 0 ;;
  esac
  return 1
}

# ---- hook installation (shared by the three installers in the launcher) ----

# hook_cmd <script> [args...] — a hook command line that survives being run by a shell.
# Sweater and project names carry spaces and parentheses in the wild, and interpolating one
# raw produced a command that died with a syntax error on every single session, silently:
# no proposal, no checkpoint, no message. printf %q is the fix, and it is bash 3.2 safe.
hook_cmd() {
  local out a; out="$(printf '%q' "$1")"; shift
  for a in "$@"; do out+=" $(printf '%q' "$a")"; done
  printf '%s' "$out"
}

# install_hook <cfg> <event> <matcher> <script> <cmd> <timeout> <async 0|1>
# Idempotent AND self-healing: it drops any existing entry that runs the same script before
# adding the current one. Deciding "already present" by exact command match (what this used
# to do) leaves a previously-installed BROKEN command sitting there and adds a correct one
# beside it, so the broken one keeps firing and failing forever. Returns 0 and writes
# nothing when the file already says exactly this. Prints nothing; the caller announces.
install_hook() {
  local cfg="$1" ev="$2" matcher="$3" script="$4" cmd="$5" to="$6" async="$7"
  local base out qscript
  qscript="$(printf '%q' "$script")"
  base="$(cat "$cfg" 2>/dev/null || echo '{}')"
  out="$(printf '%s' "$base" | jq --sort-keys \
    --arg e "$ev" --arg m "$matcher" --arg s "$script" --arg qs "$qscript" --arg c "$cmd" \
    --argjson to "$to" --argjson async "$async" '
      def prune: map(.hooks = ((.hooks // [])
                     | map(select(((.command // "") | startswith($s)) or
                                  ((.command // "") | startswith($qs)) | not))))
                 | map(select(((.hooks // []) | length) > 0));
      (({"type":"command","command":$c,"timeout":$to})
        + (if $async == 1 then {"async":true} else {} end)) as $h
      | {"matcher":$m,"hooks":[$h]} as $entry
      | .hooks = (.hooks // {})
      | .hooks[$e] = (((.hooks[$e] // []) | prune) + [$entry])
    ' 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  [[ "$out" == "$(printf '%s' "$base" | jq --sort-keys . 2>/dev/null)" ]] && return 1
  mkdir -p "$(dirname "$cfg")"
  printf '%s' "$out" > "$cfg.tmp" 2>/dev/null && mv "$cfg.tmp" "$cfg"
}

# Munge an absolute path to its Claude projects dir name (/ -> -).
claude_proj_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$1" | sed 's#/#-#g')"; }

# List scope names: a scope dir is one whose top-level .md has `scope:` frontmatter
# (excludes global, prompts, assets, proposals, tools, test, etc.).
list_scopes() {
  local d n
  for d in "$ROOT"/*/; do
    n="$(basename "$d")"
    # global is not a sweater; proposals/, watches/, .distill/ are gitignored scratch, not
    # memory. A proposal carries scope: frontmatter, so the filter below would otherwise
    # enumerate proposals/ as a scope the moment one exists (and trip the core-purity check).
    case "$n" in global|proposals|watches|.distill) continue ;; esac
    # /dev/null is a deliberate extra operand, not clutter: a caller may have `shopt -s nullglob`
    # set (grandma-review does), and then a media-only directory expands the glob to NOTHING, grep
    # falls back to stdin, and the whole CLI hangs on the terminal with no output at all.
    if grep -lqE '^scope:' "$d"/*.md /dev/null 2>/dev/null; then echo "$n"; fi
  done
}

# extract_readable_transcript <transcript.jsonl> <out.md> — write a readable USER/ASSISTANT
# text log (tool noise dropped, only text turns kept) that a headless model can read. Shared
# by the end-of-session distiller and the pre-compaction checkpoint.
extract_readable_transcript() {
  jq -r '
    select(.type=="user" or .type=="assistant")
    | (.message.role // .type) as $role
    | (.message.content) as $c
    | if ($c|type)=="string" then "\($role|ascii_upcase): \($c)\n"
      else ($c | map(select(.type=="text") | .text) | join("\n")) as $t
           | if ($t|length)>0 then "\($role|ascii_upcase): \($t)\n" else empty end
      end
  ' "$1" > "$2"
}

# ---- engine version + update nudge ----
# The engine is a git checkout (install.sh clones it). These read its version and, at launch,
# nudge once when it has gone stale. No network: staleness is measured from the last
# `grandma update`, so grandma never phones anywhere on its own. Callers must have ENGINE/ROOT set.

# engine_version — the VERSION file, plus the short commit when this is a git checkout, so a
# support request can pin the exact code the user is running.
engine_version() {
  local v="unknown" sha
  [[ -f "$ENGINE/VERSION" ]] && v="$(head -n1 "$ENGINE/VERSION" | tr -d '[:space:]')"
  sha="$(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then printf '%s (%s)' "$v" "$sha"; else printf '%s' "$v"; fi
}

# engine_is_git — is the engine an updatable git checkout (vs a bare copy)?
engine_is_git() { git -C "$ENGINE" rev-parse --git-dir >/dev/null 2>&1; }

# update_state_file — per-user marker holding the epoch of the last successful `grandma update`.
update_state_file() { printf '%s/.update-state' "$ROOT"; }

# note_engine_updated — stamp "now" so the launch nudge resets after an update. Best-effort:
# a missing or unwritable home is fine (the group redirect swallows even the redirect error).
note_engine_updated() {
  [[ -d "$ROOT" ]] || return 0
  { date +%s > "$(update_state_file)"; } 2>/dev/null || true
}

# engine_age_days — whole days since the last `grandma update`, or since the engine's HEAD
# commit if it was never updated here. No network. Prints 0 when it cannot tell.
engine_age_days() {
  local base now sf; sf="$(update_state_file)"
  if [[ -f "$sf" ]]; then base="$(head -n1 "$sf" 2>/dev/null | tr -cd '0-9')"
  else base="$(git -C "$ENGINE" log -1 --format=%ct 2>/dev/null | tr -cd '0-9')"; fi
  now="$(date +%s 2>/dev/null | tr -cd '0-9')"
  [[ -n "$base" && -n "$now" && "$base" -gt 0 && "$now" -ge "$base" ]] 2>/dev/null || { echo 0; return; }
  echo $(( (now - base) / 86400 ))
}

# grandma_update_notice — one quiet launch line when the engine has gone stale, at most once a
# day. Silence entirely with GRANDMA_NO_UPDATE_CHECK=1; tune the threshold with
# GRANDMA_UPDATE_STALE_DAYS (default 7). Never blocks and never touches the network.
grandma_update_notice() {
  [[ "${GRANDMA_NO_UPDATE_CHECK:-0}" == "1" ]] && return 0
  engine_is_git || return 0
  local days; days="$(engine_age_days)"
  [[ "${days:-0}" -ge "${GRANDMA_UPDATE_STALE_DAYS:-7}" ]] 2>/dev/null || return 0
  local marker today; marker="$ROOT/.update-nudged"; today="$(date +%Y%m%d 2>/dev/null)"
  [[ -f "$marker" && "$(cat "$marker" 2>/dev/null)" == "$today" ]] && return 0
  printf '%s' "$today" > "$marker" 2>/dev/null || true
  printf '  🧶 your grandma engine is %s days old — run: grandma update\n' "$days" >&2
}

# ---- knit: the shared-memory launch banner ----
# A teammate sharing their project memory shows up as a GitHub repo invitation. Checking for
# one means a network call, and launch must never wait on the network — so the launcher reads
# a CACHE and, when that cache has gone stale, kicks off a detached refresh for NEXT time.
# Same shape as the watch tick: print instantly from disk, refresh in the background.
# Silence it entirely with GRANDMA_NO_KNIT_CHECK=1; tune with GRANDMA_KNIT_POLL_HOURS.

knit_pending_file() { printf '%s/.knit-pending' "$ROOT"; }
knit_checked_file() { printf '%s/.knit-checked' "$ROOT"; }

# grandma_knit_notice — one line per waiting share, then a background refresh if the cache is
# stale. Always returns 0: no gh, no network and no memory home are all normal states here.
grandma_knit_notice() {
  [[ "${GRANDMA_NO_KNIT_CHECK:-0}" == "1" ]] && return 0
  local pf cf line now last age
  pf="$(knit_pending_file)"
  if [[ -s "$pf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  🧶 %s — pull it: grandma knit pull\n' "$line" >&2
    done < "$pf"
  fi
  command -v gh >/dev/null 2>&1 || return 0
  now="$(date +%s 2>/dev/null | tr -cd '0-9')"; [[ -n "$now" ]] || return 0
  age=$(( ${GRANDMA_KNIT_POLL_HOURS:-8} * 3600 ))
  cf="$(knit_checked_file)"
  if [[ -f "$cf" ]]; then
    last="$(head -n1 "$cf" 2>/dev/null | tr -cd '0-9')"
    [[ -n "$last" && $((now - last)) -lt "$age" ]] 2>/dev/null && return 0
    nohup "$ENGINE/lib/grandma-knit.sh" poll >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
  fi

  # FIRST check ever on this machine: poll in the foreground, tightly capped, so someone who
  # was just invited sees it on this launch instead of the next one. Backgrounding it means
  # the cache is written after the banner has already been read, so the very launch that
  # matters most to a new recipient is the one that shows nothing. Every later check goes
  # back to the background. The cap is small and it fails open, so a dead network costs a
  # couple of seconds once, not a hung prompt.
  GRANDMA_KNIT_POLL_TIMEOUT="${GRANDMA_KNIT_FIRST_POLL_TIMEOUT:-5}" \
    "$ENGINE/lib/grandma-knit.sh" poll >/dev/null 2>&1 || true
  if [[ -s "$pf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  🧶 %s — pull it: grandma knit pull\n' "$line" >&2
    done < "$pf"
  fi
  return 0
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
  # title, body, [command] — a desktop notification, and what to run about it.
  #
  # The third argument is the point. A notification you cannot act on is worse than none:
  # `osascript display notification` is attributed to Script Editor and carries NO click
  # action at all, so clicking one opens Script Editor's empty open-file panel, which reads
  # as grandma being broken. That cannot be fixed by any argument to osascript.
  #
  # So: when terminal-notifier is present, use it, because it can actually run something on
  # click. Otherwise fall back to osascript and put the command IN THE BODY, so the
  # notification is self-sufficient and there is no reason to click it.
  #
  # Returns 0 if a backend delivered, 1 if none did (and logs why). A detached watch tick has
  # no terminal, so failures must land in a file to be verifiable, not /dev/null.
  local root="${GRANDMA_HOME:-$HOME/.grandma}" log="${GRANDMA_HOME:-$HOME/.grandma}/.distill/notify.log" err
  local title="$1" body="$2" cmd="${3:-}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    if terminal-notifier -title "$title" -message "$body" -sound Glass \
         ${cmd:+-execute "$cmd"} >/dev/null 2>&1; then return 0; fi
  fi
  if command -v osascript >/dev/null 2>&1; then
    local shown="$body"
    [[ -n "$cmd" ]] && shown="$body — run: $cmd"
    osascript -e "display notification \"${shown//\"/\\\"}\" with title \"$title\" sound name \"Glass\"" 2>/dev/null && return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    # A backgrounded/nohup'd tick can inherit a shell with no session bus (SSH, tty, cron).
    # notify-send then fails "cannot connect to bus". Derive it from the runtime dir if we can.
    [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR:-}/bus" ]] \
      && export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    local lbody="$body"; [[ -n "$cmd" ]] && lbody="$body — run: $cmd"
    if err="$(notify-send -a grandma "$title" "$lbody" 2>&1)"; then return 0; fi
    mkdir -p "$root/.distill" 2>/dev/null
    printf '%s notify-send failed: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$err" >> "$log" 2>/dev/null
    return 1
  fi
  mkdir -p "$root/.distill" 2>/dev/null
  printf '%s no notifier (install libnotify-bin / libnotify): [%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$title" "$body" >> "$log" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------- argv limits ----
# The memory bundle used to ride to the CLI as ONE argv entry. Two different kernel limits
# make that fail, and neither is about how much memory is reasonable to load:
#   Linux  MAX_ARG_STRLEN caps a SINGLE argument at 131072 bytes (PAGE_SIZE * 32). It is
#          hardcoded since 2.6.23, unrelated to ARG_MAX, and cannot be raised. The kernel
#          measures the string INCLUDING its terminator, so the largest prompt that actually
#          fits is 131071. Reporting 131072 would let a prompt of exactly that size through
#          the check and straight into the E2BIG it was meant to prevent.
#   BSD    no per-argument cap, but argv plus envp together must fit ARG_MAX.
# So a home that is merely large stops launching, with the shell reporting "Argument list too
# long" after grandma has already said memory loaded. Prefer the file flag; fall back to argv
# and refuse early with a real explanation.

# argv_prompt_limit — largest system prompt that can safely travel on argv here.
argv_prompt_limit() {
  local am envb
  case "$(uname -s)" in
    Linux) echo 131071 ;;
    *)
      am="$(getconf ARG_MAX 2>/dev/null || echo 262144)"
      envb="$(env 2>/dev/null | wc -c | tr -d ' ')"
      [[ "$envb" =~ ^[0-9]+$ ]] || envb=8192
      echo $(( am - envb - 8192 ))
      ;;
  esac
}

# run_bounded <secs> <cmd...> — run a command with a wall-clock cap, print its stdout. The
# poll runs detached at launch time, so a network stall must never leave a process hanging
# around forever. Pure bash: no timeout(1) on macOS, no new dependency.
# Completion is detected by a marker file the child writes, NOT by `kill -0`: a finished
# child can sit as a zombie until it is reaped, and kill -0 reports a zombie as alive.
run_bounded() {
  local secs="$1"; shift
  local out finished pid i=0 rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-out-XXXXXX")" || return 1
  finished="$out.rc"
  ( "$@" > "$out" 2>/dev/null; printf '%s' "$?" > "$finished" ) &
  pid=$!
  while [[ "$i" -lt $((secs * 10)) ]]; do
    [[ -s "$finished" ]] && break
    sleep 0.1; i=$((i + 1))
  done
  if [[ -s "$finished" ]]; then
    rc="$(cat "$finished")"
  else
    # Kill the CHILDREN first. The command runs inside a backgrounded subshell, so signalling
    # only $pid reaps the subshell and leaves the actual network call running long past the
    # bound it was given. A negative pid does not help here either: the subshell inherits its
    # parent's process group rather than leading one of its own.
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null; rc=124
  fi
  wait "$pid" 2>/dev/null || true
  cat "$out"; rm -f "$out" "$finished"
  return "${rc:-1}"
}

# claude_accepts_prompt_file — does the installed claude take --append-system-prompt-file?
# Probed, not version-gated: some builds carry the flag without listing it in the main help
# block, so any version floor would be a guess. Normally about 0.1s, no cache worth keeping.
# BOUNDED, and stdin comes from /dev/null, because this runs BEFORE the launcher arms its
# HUP trap: a claude that never answers --help would otherwise hang the CLI with no output
# and no way to interrupt cleanly. A probe that cannot answer is treated as "no flag", which
# falls back to argv where the size guard explains itself.
# Takes the binary to probe, because watch resolves claude by path when it is not on PATH and
# must not be told "no flag" merely because a bare `claude` is missing.
claude_accepts_prompt_file() {
  local bin="${1:-claude}"
  run_bounded "${GRANDMA_PROBE_TIMEOUT:-5}" "$bin" --help < /dev/null 2>/dev/null \
    | grep -qE -- '--append-system-prompt\[?-file'
}

# write_sysprompt_file <text> — stash a system prompt in a private file, echo the path.
# mktemp creates it mode 600, and $TMPDIR is mode 700 per user, which matters because this
# file is the whole memory bundle. Caller removes it; a wrapped launch does so from a trap.
write_sysprompt_file() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/grandma-sysprompt.XXXXXX")" || return 1
  printf '%s' "$1" > "$f" || { rm -f "$f"; return 1; }
  printf '%s' "$f"
}

# heaviest_loaded_file <scope_dir> — path of the largest always-loaded .md in a scope, i.e.
# the file to shrink first. decisions.md is excluded because assemble already defers it.
heaviest_loaded_file() {
  local d="$1" f big="" bigsz=0 sz
  for f in "$d"/*.md; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "decisions.md" ]] && continue
    sz="$(file_size "$f")"; [[ "$sz" =~ ^[0-9]+$ ]] || continue
    if [[ "$sz" -gt "$bigsz" ]]; then bigsz="$sz"; big="$f"; fi
  done
  printf '%s' "$big"
}

# bundle_shrink_hint <root> <scope> — the most useful next action for an oversized scope.
# A flat log.md is always the wrong shape, so name it; otherwise name the biggest file.
bundle_shrink_hint() {
  local root="$1" scope="$2" d="$1/$2" big
  if [[ -f "$d/log.md" ]]; then
    printf '  A flat log.md loads on EVERY session and only grows. Move it into the dated log,\n'
    printf '  which is read only on demand:\n'
    printf '    mkdir -p %s/log && mv %s/log.md %s/log/%s.md\n' "$d" "$d" "$d" "$(date +%Y-%m-%d)"
    return
  fi
  big="$(heaviest_loaded_file "$d")"
  if [[ -n "$big" ]]; then
    printf '  Biggest file loaded every session: %s (%s bytes).\n' "$big" "$(file_size "$big")"
    printf '  Consolidate it, or move append-only parts to %s/log/%s.md, which is\n' "$d" "$(date +%Y-%m-%d)"
    printf '  read only on demand.\n'
  fi
}

# prepare_sysprompt <prompt> [scope] [root] — work out how a system prompt reaches the CLI and
# leave the flag pair in SYSPROMPT_ARGS for the caller to expand. Returns 1 when the prompt
# cannot be delivered at all, having already explained why, so a caller can exit instead of
# running head-first into the kernel's refusal.
# Results come back in globals rather than on stdout because a command substitution is a
# subshell, which would throw the array away.
# Sets SYSPROMPT_TMP to the file it wrote, or empty. cleanup_sysprompt removes it, and every
# caller must arrange that on EXIT: the file holds the user's memory and must not outlive us.
# Colour for prose grandma prints to a human. Everything user-facing goes to stderr, so the
# terminal test is on fd 2: colouring a piped or redirected run would put escape codes into
# logs and into anything reading our output. NO_COLOR is the convention people already set.
# shellcheck disable=SC2034  # C_KEY and C_WARN are read by callers in other files
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_KEY=$'\033[1;38;5;211m'
  C_WARN=$'\033[33m'
else
  C_RESET=''
  C_KEY=''
  C_WARN=''
fi

# open_url <url> — hand a URL to the user's browser, portably. Silent no-op when there is no
# opener, because a setup flow must degrade to "here is the link" rather than fail.
open_url() {
  local u="$1"
  if command -v open >/dev/null 2>&1; then open "$u" >/dev/null 2>&1 && return 0; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$u" >/dev/null 2>&1 && return 0; fi
  # WSL, where the README says Windows users live
  if command -v wslview >/dev/null 2>&1; then wslview "$u" >/dev/null 2>&1 && return 0; fi
  if command -v powershell.exe >/dev/null 2>&1; then powershell.exe -NoProfile Start "$u" >/dev/null 2>&1 && return 0; fi
  return 1
}

# read_secret <prompt> — read a line without echoing it. The value is returned on stdout for a
# caller to hold in a variable and nothing else: grandma never writes it anywhere.
read_secret() {
  local v=""
  printf '%s' "$1" >&2
  if [[ -t 0 ]]; then
    stty -echo 2>/dev/null || true
    IFS= read -r v || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
  else
    IFS= read -r v || true
  fi
  printf '%s' "$v"
}

# ------------------------------------------------------------------ mcp binding ----
# A sweater can bind MCP servers, and they reach every project in that sweater and nothing
# outside it. Isolation is the CLI's own `--strict-mcp-config`, which ignores every other MCP
# source, so this is a hard boundary rather than a convention, the same way sweater memory is.
#
# Two optional files, both in the CLI's own `{"mcpServers": {...}}` shape so a definition can be
# pasted straight from a vendor's docs:
#   $ROOT/global/mcp.json      servers every sweater gets
#   $ROOT/<sweater>/mcp.json   servers only this sweater gets
#
# Composition, in this order, and the order is the whole design:
#   1. global servers enter under their own names
#   2. a sweater server with the same name REPLACES the global one for this sweater
#   3. sweater servers are then renamed to <sweater>__<name>
# Renaming last is what makes both rules true at once. The CLI keys a stored MCP login by server
# NAME plus URL (measured: one `notion` credential serves four different project directories), so
# a global server keeping its bare name shares one login everywhere, which is what global means,
# while a sweater server gets a slot of its own and two sweaters can hold two different accounts
# on the same provider without ever sharing a token.
#
# A sweater with neither file passes no flags at all, so nothing changes for anyone not using it.

# mcp_compose <root> <scope> <out.json> — write the composed config. Returns 1 when there is
# nothing to bind (caller then passes no MCP flags), 2 when jq is missing or a file is malformed.
mcp_compose() {
  local root="$1" scope="$2" out="$3" gfile="$1/global/mcp.json" sfile
  sfile="$(resolve_scope_dir "$scope" 2>/dev/null || true)/mcp.json"
  [[ -f "$gfile" || -f "$sfile" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  [[ -f "$gfile" ]] || gfile="/dev/null"
  [[ -f "$sfile" ]] || sfile="/dev/null"
  jq -n --slurpfile g <(cat "$gfile" 2>/dev/null || echo '{}')         --slurpfile s <(cat "$sfile" 2>/dev/null || echo '{}')         --arg scope "$scope" '
    ($g[0].mcpServers // {}) as $G
    | ($s[0].mcpServers // {}) as $S
    # a sweater name removes the global entry it shadows, then the sweater entries are renamed
    | { mcpServers:
        ( ($G | with_entries(select(.key as $k | ($S | has($k)) | not)))
          + ($S | with_entries(.key = ($scope + "__" + .key))) ) }
  ' > "$out" 2>/dev/null || return 2
  # an empty result is the same as having nothing to bind
  [[ "$(jq -r '.mcpServers | length' "$out" 2>/dev/null || echo 0)" -gt 0 ]] || return 1
  return 0
}

# mcp_server_names <file> — space-separated names in a composed config, for the launch banner.
mcp_server_names() {
  jq -r '.mcpServers | keys_unsorted | join(" ")' "$1" 2>/dev/null || true
}

# prepare_sysprompt <prompt> [scope] [root] [claude-bin]
prepare_sysprompt() {
  local prompt="$1" scope="${2:-}" root="${3:-}" bin="${4:-claude}" limit
  SYSPROMPT_TMP=""
  # shellcheck disable=SC2034  # read by every caller in another file; this is the return value
  SYSPROMPT_ARGS=()
  if [[ "${GRANDMA_NO_PROMPT_FILE:-0}" != "1" ]] && claude_accepts_prompt_file "$bin"; then
    SYSPROMPT_TMP="$(write_sysprompt_file "$prompt")" || SYSPROMPT_TMP=""
  fi
  if [[ -n "$SYSPROMPT_TMP" ]]; then
    # shellcheck disable=SC2034  # ditto
    SYSPROMPT_ARGS=(--append-system-prompt-file "$SYSPROMPT_TMP")
    return 0
  fi
  limit="$(argv_prompt_limit)"
  if [[ "${#prompt}" -gt "$limit" ]]; then
    oversized_bundle_error "${#prompt}" "$limit" "$scope" "$root"
    return 1
  fi
  # shellcheck disable=SC2034  # ditto
  SYSPROMPT_ARGS=(--append-system-prompt "$prompt")
  return 0
}

# cleanup_sysprompt — remove the prompt file, if one was written. Safe to call twice.
cleanup_sysprompt() {
  if [[ -n "${SYSPROMPT_TMP:-}" ]]; then rm -f "$SYSPROMPT_TMP"; fi
  SYSPROMPT_TMP=""
  return 0
}

# oversized_bundle_error <bytes> <limit> <scope> <root> — say what broke and how to fix it,
# instead of leaving the shell to print "Argument list too long" with no context.
oversized_bundle_error() {
  local bytes="$1" limit="$2" scope="$3" root="$4" over=$(( $1 - $2 ))
  {
    printf '\n  🧶 MEMORY BUNDLE TOO LARGE TO LAUNCH\n'
    printf '     bundle        %s bytes\n' "$bytes"
    printf '     argv limit    %s bytes (%s)\n' "$limit" \
      "$([[ "$(uname -s)" == Linux ]] && echo 'Linux caps one argument at 128 KB' || echo 'ARG_MAX minus this environment')"
    printf '     over by       %s bytes\n\n' "$over"
    printf '  This claude has no --append-system-prompt-file, so the bundle rides on the command\n'
    printf '  line and the kernel refuses the exec. Upgrading claude removes the limit entirely.\n'
    printf '  To see everything that loads every session: grandma %s --dry-run\n\n' "$scope"
    bundle_shrink_hint "$root" "$scope"
    printf '\n'
  } >&2
}
