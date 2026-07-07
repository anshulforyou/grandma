#!/usr/bin/env bash
#
# grandma — the master terminal.
#
# Assembles a scope's memory bundle and launches a Claude Code session with it
# injected as context. You just declare scope + task; the right memory rides along.
#
# Usage:
#   grandma <scope> [project] [task words...] [--full] [--writing]
#
# Examples:
#   grandma acme                       # interactive, scope memory loaded
#   grandma acme "plan the payments refactor"
#   grandma acme billing-api           # known project: cd into it, its CLAUDE.md auto-loads
#   grandma acme new-service           # unknown project: guided onboarding, then stop
#
# The optional [project] is a single bare word right after the scope. It is
# fuzzy-matched against <Scope>/projects.md. Known -> launch in that folder.
# Unknown -> an onboarding session registers a pointer, then tells you to re-run.
# Flags --full / --writing are forwarded to assemble.sh (see that file).

set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
ASSEMBLE="$ENGINE/lib/assemble.sh"

# grandma_splash — the "grandma pops up" moment before the session loads.
# Plays assets/grandma.gif via imgcat (iTerm2) if present, else prints ASCII granny.
# Skip with GRANDMA_NO_SPLASH=1; tune the pause with GRANDMA_SPLASH_SECS.
grandma_splash() {
  [[ "${GRANDMA_NO_SPLASH:-0}" == "1" ]] && return 0
  local scope="$1" gif="$ENGINE/assets/grandma.gif"
  local P=$'\033[95m' B=$'\033[1m' D=$'\033[2m' R=$'\033[0m'
  printf '\n'
  if [[ -f "$gif" ]] && command -v imgcat >/dev/null 2>&1; then
    imgcat --height "${GRANDMA_SPLASH_HEIGHT:-14}" "$gif" 2>/dev/null || true
  else
    printf '%s' "$P"
    printf '%s\n' "        .-\"\"\"\"\"-."
    printf '%s\n' "       / .---. \\"
    printf '%s\n' "      / /     \\ \\"
    printf '%s\n' "      | | o o | |"
    printf '%s\n' "     _|  \\ ^ /  |_"
    printf '%s\n' "    / |   '-'   | \\"
    printf '%s\n' "      |         |"
    printf '%s%s' "$R" ""
  fi
  printf '  %s%sGRANDMA%s  %sshe remembers everything%s\n' "$B" "$P" "$R" "$D" "$R"
  printf '  %sfetching %s memory...%s\n\n' "$D" "$scope" "$R"
  sleep "${GRANDMA_SPLASH_SECS:-1.2}"
}

# ---- helpers ----
source "$ENGINE/lib/grandma-lib.sh"

# Launch the new-scope creator: read a free-text description, hand it to an LLM session
# that scaffolds the scope, then stops. Execs claude (does not return).
create_new_scope() {
  printf '\n  Describe the new scope — what it is, what you do there, and any pointers\n  (e.g. "my resume is at ~/docs/cv.pdf, I am job hunting for staff eng roles"):\n  > ' >&2
  local desc; IFS= read -r desc
  [[ -z "$desc" ]] && { echo "  no description given, aborting." >&2; exit 1; }
  local SYS
  SYS="$(cat "$ENGINE/prompts/new-scope.md")

===== GLOBAL MEMORY (who the user is) =====
$(cat "$ROOT/global/identity.md" "$ROOT/global/preferences.md" "$ROOT/global/style.md" 2>/dev/null || true)"
  grandma_splash "new scope"
  printf '  ⟳ creating a new scope from your description...\n\n' >&2
  cd "$ROOT"
  exec claude --name "grandma:new-scope" ${PASSTHRU[@]+"${PASSTHRU[@]}"} \
    --append-system-prompt "$SYS" \
    "Create a new grandma scope from this description, following your instructions: $desc"
}

# Interactive scope picker (plain `grandma` with no scope). Sets SCOPE, or execs the
# new-scope creator, or exits.
pick_scope() {
  local scopes=() s choice n idx
  while IFS= read -r s; do [[ -n "$s" ]] && scopes+=("$s"); done < <(list_scopes)
  scopes=(${scopes[@]+"${scopes[@]}"})   # reindex 0-based (bash 3.2 safety)
  n=${#scopes[@]}
  printf '\n  grandma — which scope?\n' >&2
  for (( idx=0; idx<n; idx++ )); do printf '   %d) %s\n' "$((idx+1))" "${scopes[idx]}" >&2; done
  printf '   n) + describe a new scope\n   q) quit\n  > ' >&2
  read -r choice
  case "$choice" in
    q|Q|"") exit 0 ;;
    n|N)    create_new_scope ;;   # execs, does not return
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
        SCOPE="${scopes[$((choice-1))]}"
      else
        echo "  invalid choice." >&2; exit 2
      fi ;;
  esac
}

# Ensure a grandma-launched project has the SessionStart(compact) rehydrate hook, so
# grandma's memory is restored after Claude Code auto-compacts a long session.
# Idempotent; writes to the project's .claude/settings.local.json (personal, non-committed).
# Sets GRANDMA_HOOK_INSTALLED=1 when it adds the hook. Skip with GRANDMA_NO_HOOK=1.
install_rehydrate_hook() {
  local dir="$1" scope="$2"
  [[ "${GRANDMA_NO_HOOK:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0   # jq required; skip quietly if absent
  local cfg="$dir/.claude/settings.local.json"
  local cmd="$ENGINE/lib/grandma-rehydrate.sh $scope"
  local base present
  base="$(cat "$cfg" 2>/dev/null || echo '{}')"
  present="$(printf '%s' "$base" | jq -r --arg c "$cmd" \
    '[.hooks.SessionStart[]? | select(.matcher=="compact") | .hooks[]? | .command] | map(. == $c) | any' 2>/dev/null || echo false)"
  [[ "$present" == "true" ]] && return 0
  mkdir -p "$dir/.claude"
  printf '%s' "$base" | jq --arg c "$cmd" \
    '.hooks = (.hooks // {}) | .hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"compact","hooks":[{"type":"command","command":$c,"timeout":15}]}])' \
    > "$cfg.tmp" 2>/dev/null && mv "$cfg.tmp" "$cfg" && GRANDMA_HOOK_INSTALLED=1
}

# Ensure a grandma-launched project has the SessionEnd auto-distill hook (async), so
# each finished session is headless-distilled into a memory proposal for later review.
# Idempotent. Skip with GRANDMA_NO_HOOK=1 or GRANDMA_NO_AUTOSAVE=1.
install_session_end_hook() {
  local dir="$1" scope="$2" project="$3"
  [[ "${GRANDMA_NO_HOOK:-0}" == "1" || "${GRANDMA_NO_AUTOSAVE:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cfg="$dir/.claude/settings.local.json"
  local cmd="$ENGINE/lib/grandma-session-end.sh $scope $project"
  local base present
  base="$(cat "$cfg" 2>/dev/null || echo '{}')"
  present="$(printf '%s' "$base" | jq -r --arg c "$cmd" \
    '[.hooks.SessionEnd[]? | .hooks[]? | .command] | map(. == $c) | any' 2>/dev/null || echo false)"
  [[ "$present" == "true" ]] && return 0
  mkdir -p "$dir/.claude"
  printf '%s' "$base" | jq --arg c "$cmd" \
    '.hooks = (.hooks // {}) | .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"matcher":"","hooks":[{"type":"command","command":$c,"async":true,"timeout":600}]}])' \
    > "$cfg.tmp" 2>/dev/null && mv "$cfg.tmp" "$cfg" && GRANDMA_AUTOSAVE_INSTALLED=1
}

# Common parent folder of a scope's registered projects (for onboarding new projects).
scope_working_root() {
  local reg="$1/projects.md"
  [[ -f "$reg" ]] || return 0
  project_entries "$reg" | cut -f2 | python3 -c "
import sys, os
dirs=[l.strip() for l in sys.stdin if l.strip()]
print(os.path.commonpath(dirs) if dirs else '')
" 2>/dev/null || true
}

# ---- parse args: grandma <scope> [project] [task...] [--full] [--writing] ----
# A single bare word right after the scope (no spaces, before any task words) is the project.
SCOPE=""
PROJECT=""
TASK=()
PASS=()        # forwarded to assemble.sh
PASSTHRU=()    # forwarded verbatim to the launched `claude` (e.g. --debug)
ddash=0        # everything after a literal `--` goes to claude
for arg in "$@"; do
  if [[ "$ddash" == "1" ]]; then PASSTHRU+=("$arg"); continue; fi
  case "$arg" in
    --) ddash=1 ;;
    --full|--writing) PASS+=("$arg") ;;
    --debug) PASSTHRU+=(--debug hooks) ;;          # default filter to hooks
    --debug=*) PASSTHRU+=(--debug "${arg#--debug=}") ;;
    --debug-file=*) PASSTHRU+=(--debug-file "${arg#--debug-file=}") ;;
    -*) echo "unknown flag: $arg (forward claude flags after --, e.g. grandma ... -- --debug api)" >&2; exit 2 ;;
    *)
      if [[ -z "$SCOPE" ]]; then SCOPE="$arg"
      elif [[ -z "$PROJECT" && ${#TASK[@]} -eq 0 && "$arg" != *" "* ]]; then PROJECT="$arg"
      else TASK+=("$arg"); fi ;;
  esac
done

if [[ -z "$SCOPE" ]]; then
  # No scope given. Interactively pick one (or describe a new one) when on a terminal.
  if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then
    pick_scope   # sets SCOPE, or execs the new-scope creator, or exits
  else
    echo "usage: grandma <scope> [project] [task...] [--full] [--writing]" >&2
    echo "  (run 'grandma' on a terminal with no scope to pick one or create a new scope)" >&2
    exit 2
  fi
fi

# Assemble the scope bundle (global + scope memory). Same for all paths below.
BUNDLE="$("$ASSEMBLE" "$SCOPE" ${PASS[@]+"${PASS[@]}"})"
FILE_COUNT="$(printf '%s\n' "$BUNDLE" | grep -c '^----- BEGIN ' || true)"
TOKENS=$(( ${#BUNDLE} / 4 ))

PREAMBLE="You are operating with a memory bundle for scope '$SCOPE'. Treat it as authoritative context about the user and this work context (their name and identity are in the bundle): follow the working preferences and writing style it describes, and use its facts/people/decisions. Do not echo the bundle back; just act on it."
SYSPROMPT="$PREAMBLE

$BUNDLE

$(cat "$ENGINE/prompts/capture.md")

The grandma memory repo is at $ROOT (you have write access to it for captures)."

# ---- project layer (third tier) ----
LAUNCH_DIR=""   # if set, launch the session in this folder so its CLAUDE.md auto-loads
ONBOARD=0
if [[ -n "$PROJECT" ]]; then
  SCOPE_DIR="$(resolve_scope_dir "$SCOPE" || true)"
  if [[ -z "$SCOPE_DIR" ]]; then echo "error: unknown scope '$SCOPE'" >&2; exit 1; fi
  resolve_project "$SCOPE_DIR" "$PROJECT"
  case "$RP_STATUS" in
    OK)    LAUNCH_DIR="$RP_DIR" ;;
    AMBIG) echo "'$PROJECT' matches multiple projects in $SCOPE: $RP_CANDS" >&2
           echo "be more specific." >&2; exit 2 ;;
    NONE)  ONBOARD=1 ;;
  esac
fi

# ---- ONBOARD path: unknown project → guided registration session, then stop ----
if [[ "$ONBOARD" == "1" ]]; then
  WROOT="$(scope_working_root "$SCOPE_DIR")"
  OSYS="$(cat "$ENGINE/prompts/onboard.md")

===== CURRENT MEMORY (scope=$SCOPE) =====
$BUNDLE"
  OINIT="I ran: grandma $SCOPE $PROJECT — but '$PROJECT' is not registered in the $SCOPE scope.
Scope working root: ${WROOT:-unknown}. Onboard '$PROJECT' per your instructions (discover an existing folder, or create a new project), register a pointer in $(basename "$SCOPE_DIR")/projects.md, then stop and tell me to re-run."

  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    echo "mode:         ONBOARD (project '$PROJECT' unknown in $SCOPE)" >&2
    echo "working root: ${WROOT:-unknown}" >&2
    echo "would launch: (cd $ROOT && claude --name grandma:onboard/$PROJECT --add-dir ${WROOT:-<none>} --append-system-prompt <onboard+memory> <init>)" >&2
    exit 0
  fi

  grandma_splash "$SCOPE"
  printf "  ⟳ %s does not know '%s' yet — let's set it up...\n\n" "$SCOPE" "$PROJECT" >&2
  cd "$ROOT"
  if [[ -n "$WROOT" ]]; then
    exec claude --name "grandma:onboard/$PROJECT" --add-dir "$WROOT" ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$OSYS" "$OINIT"
  else
    exec claude --name "grandma:onboard/$PROJECT" ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$OSYS" "$OINIT"
  fi
fi

# ---- normal / known-project launch ----
BANNER="memory: $SCOPE loaded · $FILE_COUNT files · ~${TOKENS} tokens"
[[ -n "$LAUNCH_DIR" ]] && BANNER="$BANNER · project $RP_NAME"

CONFIRM="Before anything else, print exactly one short confirmation line in this shape, filling the hint from the loaded identity/facts (e.g. role + current focus):
  ▣ $BANNER — <3-6 word who-I-am-in-this-scope hint>
Then"
if [[ -n "$LAUNCH_DIR" ]]; then
  CONFIRM="$CONFIRM note that you are in project '$RP_NAME' and its CLAUDE.md is loaded from this folder. Then"
fi

if [[ ${#TASK[@]} -gt 0 ]]; then
  INIT="$CONFIRM address this task:

${TASK[*]}"
else
  INIT="$CONFIRM reply only with 'ready — what are we working on?' and wait for my task."
fi

# Dry run: show what would launch, don't start Claude.
if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  if [[ -f "$ENGINE/assets/grandma.gif" ]] && command -v imgcat >/dev/null 2>&1; then
    echo "splash:       gif (assets/grandma.gif via imgcat)" >&2
  else
    echo "splash:       ascii granny (drop assets/grandma.gif for the gif)" >&2
  fi
  if [[ -n "$LAUNCH_DIR" ]]; then
    echo "mode:         KNOWN project '$RP_NAME' → cd $LAUNCH_DIR (its CLAUDE.md auto-loads)" >&2
    if [[ "${GRANDMA_NO_HOOK:-0}" == "1" ]]; then
      echo "rehydrate:    skipped (GRANDMA_NO_HOOK=1)" >&2
      echo "autosave:     skipped (GRANDMA_NO_HOOK=1)" >&2
    else
      echo "rehydrate:    would ensure SessionStart(compact) hook in $LAUNCH_DIR/.claude/settings.local.json" >&2
      if [[ "${GRANDMA_NO_AUTOSAVE:-0}" == "1" ]]; then
        echo "autosave:     skipped (GRANDMA_NO_AUTOSAVE=1)" >&2
      else
        echo "autosave:     would ensure SessionEnd(async) auto-distill hook (proposal on exit)" >&2
      fi
    fi
  fi
  [[ ${#PASSTHRU[@]} -gt 0 ]] && echo "passthru:     ${PASSTHRU[*]} (forwarded to claude)" >&2
  echo "capture:      doctrine loaded (prompts/capture.md) · grandma repo writable via --add-dir" >&2
  echo "banner:       $BANNER" >&2
  echo "would launch: (cd ${LAUNCH_DIR:-.} && claude --name grandma:$SCOPE${RP_NAME:+/$RP_NAME} ${PASSTHRU[*]:-} --append-system-prompt <bundle> <init>)" >&2
  echo "--- init prompt ---" >&2
  printf '%s\n' "$INIT" >&2
  echo "--- sysprompt: ${#SYSPROMPT} chars ---" >&2
  exit 0
fi

# For a known project, ensure the compaction-rehydrate + auto-distill hooks are installed.
if [[ -n "$LAUNCH_DIR" ]]; then
  install_rehydrate_hook "$LAUNCH_DIR" "$SCOPE"
  install_session_end_hook "$LAUNCH_DIR" "$SCOPE" "$RP_NAME"
  [[ "${GRANDMA_HOOK_INSTALLED:-0}" == "1" || "${GRANDMA_AUTOSAVE_INSTALLED:-0}" == "1" ]] && \
    printf '  + installed grandma hooks (%s/.claude/settings.local.json)\n' "$RP_NAME" >&2
fi

# Notice pending memory proposals for this scope (from auto-distill on prior exits).
if compgen -G "$ROOT/proposals/${SCOPE}*.md" >/dev/null 2>&1; then
  n="$(ls -1 "$ROOT/proposals/${SCOPE}"*.md 2>/dev/null | wc -l | tr -d ' ')"
  printf '  📝 %s pending memory proposal(s) for %s — run: grandma-review %s\n' "$n" "$SCOPE" "$SCOPE" >&2
fi

# Notice uncommitted memory changes (in-flight captures land as diffs you review).
dirty="$(git -C "$ROOT" status --porcelain -- '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${dirty:-0}" -gt 0 ]]; then
  printf '  🧶 memory has %s uncommitted change(s) — review: git -C %s diff\n' "$dirty" "$ROOT" >&2
fi

# Watch notices: finished reports not yet read, and keep active watches ticking.
for _sd in "$ROOT"/watches/*/; do
  [[ -f "$_sd/report.md" && ! -f "$_sd/.seen" ]] && \
    printf '  📊 grandma finished watching: %s — read it: grandma-watch report %s\n' "$(basename "$_sd")" "$(basename "$_sd")" >&2
done
if compgen -G "$ROOT/watches/*/watch.json" >/dev/null 2>&1; then
  if grep -l '"status": "active"' "$ROOT"/watches/*/watch.json >/dev/null 2>&1; then
    nohup "$ENGINE/lib/grandma-watch.sh" tick >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# grandma pops up, then a one-line status, then the session.
grandma_splash "$SCOPE"
printf '  ⟳ %s — launching Claude Code...\n\n' "$BANNER" >&2

# Launch in the project folder if known (so its CLAUDE.md auto-loads), else current dir.
# --add-dir grants write access to the grandma repo so in-flight captures can land.
[[ -n "$LAUNCH_DIR" ]] && cd "$LAUNCH_DIR"
exec claude --name "grandma:$SCOPE${RP_NAME:+/$RP_NAME}" --add-dir "$ROOT" ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$SYSPROMPT" "$INIT"
