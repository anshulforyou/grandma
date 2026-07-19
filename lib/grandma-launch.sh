#!/usr/bin/env bash
#
# grandma — the master terminal.
#
# Assembles a scope's memory bundle and launches a Claude Code session with it
# injected as context. You just declare scope + task; the right memory rides along.
#
# Usage:
#   grandma <sweater> [project] [task words...] [--full] [--writing]
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

# ---- helpers ----
# grandma_splash lives in grandma-lib.sh so launch and init share one mascot implementation.
source "$ENGINE/lib/grandma-lib.sh"

# Launch the new-sweater creator: read a free-text description, hand it to an LLM session
# that scaffolds the sweater, then stops. Execs claude (does not return).
# create_new_scope: knit a new sweater. Optional $1 is a name the user already typed at the
# CLI (as in `grandma <name>`), used as the suggested sweater name so the flow proposes it.
create_new_scope() {
  local suggested="${1:-}"
  if [[ -n "$suggested" ]]; then
    printf "\n  Let's knit the '%s' sweater. In a sentence, what is it?\n  (a company, a client, a platform, or an area of your life)\n  > " "$suggested" >&2
  else
    printf '\n  Describe the new sweater — a part of your life to keep memory under.\n  (a company, a client, a platform, or an area like job-search)\n  e.g. "job hunting for staff eng roles; resume at ~/docs/cv.pdf"\n  > ' >&2
  fi
  # read -e -> readline line editing (arrow keys, cursor movement) for the free-text answer
  local desc; IFS= read -e -r desc
  [[ -z "$desc" ]] && { echo "  no description given, aborting." >&2; exit 1; }
  local SYS
  SYS="$(cat "$ENGINE/prompts/new-scope.md")

===== GLOBAL MEMORY (who the user is) =====
$(cat "$ROOT/global/identity.md" "$ROOT/global/preferences.md" "$ROOT/global/style.md" 2>/dev/null || true)"
  local INIT="Create a new grandma sweater from this description, following your instructions: $desc"
  [[ -n "$suggested" ]] && INIT="The user wants a sweater named '$suggested'. $INIT"
  grandma_splash "new sweater"
  printf '  ⟳ knitting a new sweater from your description...\n\n' >&2
  cd "$ROOT"
  exec claude --name "grandma:new-sweater" ${PASSTHRU[@]+"${PASSTHRU[@]}"} \
    --append-system-prompt "$SYS" "$INIT"
}

# First run: no sweaters yet. Warmly onboard instead of showing a bare picker.
first_run_onboard() {
  printf '\n  Hello, dear. I am grandma. I remember things for you so your AI never forgets.\n' >&2
  printf '  You keep memory under sweaters: one per part of your life (a job, a client,\n' >&2
  printf '  a platform like reddit, an area like job-search). Under a sweater live your projects.\n\n' >&2
  # If they never did the interview, offer it; else go straight to making a sweater.
  # "interviewed" = identity no longer contains the template placeholder
  if command -v claude >/dev/null 2>&1 && grep -q '<your name>' "$ROOT/global/identity.md" 2>/dev/null; then
    printf "  Let's start by getting to know you. (Ctrl+C to skip.)\n\n" >&2
    local SYS; SYS="$(cat "$ENGINE/prompts/init-interview.md")"
    grandma_splash "grandma"
    cd "$ROOT"
    exec claude --name "grandma:init" ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$SYS" \
      "Introduce yourself, explain what a sweater is, interview me, and set up my identity, preferences, and first sweaters per your instructions."
  fi
  printf "  Let's knit your first sweater.\n" >&2
  create_new_scope   # execs
}

# Interactive picker (plain `grandma` with no sweater named). Sets SCOPE, execs a
# creator/onboarder, or exits.
pick_scope() {
  local scopes=() s choice n idx
  while IFS= read -r s; do [[ -n "$s" ]] && scopes+=("$s"); done < <(list_scopes)
  scopes=(${scopes[@]+"${scopes[@]}"})   # reindex 0-based (bash 3.2 safety)
  n=${#scopes[@]}
  (( n == 0 )) && first_run_onboard   # execs, does not return
  printf '\n  grandma — which sweater?\n' >&2
  for (( idx=0; idx<n; idx++ )); do printf '   %d) %s\n' "$((idx+1))" "${scopes[idx]}" >&2; done
  printf '   n) + knit a new sweater\n   q) quit\n  > ' >&2
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

# Ensure a grandma-launched project has the PreCompact checkpoint hook (synchronous), so the
# session's working state is captured just before Claude Code compacts and re-injected by the
# rehydrate hook afterward. Idempotent. Skip with GRANDMA_NO_HOOK / GRANDMA_NO_AUTOSAVE /
# GRANDMA_NO_CHECKPOINT. Timeout bounds how long compaction can wait on it.
install_precompact_hook() {
  local dir="$1" scope="$2" project="$3"
  [[ "${GRANDMA_NO_HOOK:-0}" == "1" || "${GRANDMA_NO_AUTOSAVE:-0}" == "1" || "${GRANDMA_NO_CHECKPOINT:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cfg="$dir/.claude/settings.local.json"
  local cmd="$ENGINE/lib/grandma-precompact.sh $scope $project"
  local base present
  base="$(cat "$cfg" 2>/dev/null || echo '{}')"
  present="$(printf '%s' "$base" | jq -r --arg c "$cmd" \
    '[.hooks.PreCompact[]? | .hooks[]? | .command] | map(. == $c) | any' 2>/dev/null || echo false)"
  [[ "$present" == "true" ]] && return 0
  mkdir -p "$dir/.claude"
  printf '%s' "$base" | jq --arg c "$cmd" \
    '.hooks = (.hooks // {}) | .hooks.PreCompact = ((.hooks.PreCompact // []) + [{"matcher":"","hooks":[{"type":"command","command":$c,"timeout":60}]}])' \
    > "$cfg.tmp" 2>/dev/null && mv "$cfg.tmp" "$cfg" && GRANDMA_CHECKPOINT_INSTALLED=1
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

# dirty_md_files — repo-relative paths of uncommitted .md changes in the memory home.
# proposals/ and watches/ are gitignored, so this is reviewable memory only.
dirty_md_files() {
  git -C "$ROOT" status --porcelain -- '*.md' 2>/dev/null | while IFS= read -r _l; do
    _f="${_l:3}"; printf '%s\n' "${_f##* -> }"
  done
}

# md_fingerprint <relpath> — one stable line for a dirty file's working content (cksum is
# POSIX, same output on BSD and GNU). post_session compares these against a launch-time
# snapshot to tell files captured DURING this session from dirt that predates it.
md_fingerprint() {
  if [[ -f "$ROOT/$1" ]]; then printf '%s %s\n' "$(cksum < "$ROOT/$1")" "$1"
  else printf 'deleted %s\n' "$1"; fi
}

# post_session — runs after a wrapped session returns (we do NOT exec claude). Distills the
# just-ended session in the FOREGROUND and offers an immediate review of what THIS session
# produced (live captures + the drafted proposal). Files that were already dirty at launch
# (reviewed earlier, not yet committed) are fingerprint-matched out: they get one quiet
# footer line, never a second review prompt. After a reviewed diff, offers a user-confirmed
# commit so reviewed captures stop re-appearing as dirt.
# Interactive terminals only; honors GRANDMA_NO_AUTOSAVE. Uses $SCOPE / $RP_NAME / $ROOT.
post_session() {
  set +e                                                # best-effort UX; never abort the exit
  [ -t 0 ] || return 0
  [[ "${GRANDMA_NO_AUTOSAVE:-0}" == "1" ]] && return 0
  cd "$ROOT" 2>/dev/null || return 0
  distilled=1                                    # this session is being handled here; no background pass

  printf '\n  🧶 grandma is looking over the session… (Ctrl+C to skip)\n' >&2
  local proposal=""
  proposal="$("$ENGINE/lib/grandma-save.sh" "$SCOPE" ${RP_NAME:+"$RP_NAME"} --auto 2>/dev/null | tail -n1)"

  # Split dirty files: touched during this session vs already dirty at launch. A missing
  # snapshot (abrupt earlier path, mktemp failure) degrades to the old count-everything.
  local changed=() stale=() _f
  while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    if [[ -f "${PRE_DIRTY_SNAP:-}" ]] && grep -Fxq "$(md_fingerprint "$_f")" "${PRE_DIRTY_SNAP:-}" 2>/dev/null; then
      stale+=("$_f")
    else
      changed+=("$_f")
    fi
  done < <(dirty_md_files)
  rm -f "${PRE_DIRTY_SNAP:-}" 2>/dev/null

  local prop_ok=0
  if [[ -n "$proposal" && -f "$proposal" ]] \
     && grep -qvE '^#|^[[:space:]]*$|No durable learnings|\(distiller failed\)' "$proposal" 2>/dev/null; then
    prop_ok=1
  fi

  if [[ ${#changed[@]} -eq 0 && "$prop_ok" -eq 0 ]]; then
    printf '  🧶 nothing new to remember from this session.\n' >&2
    [[ ${#stale[@]} -gt 0 ]] && printf '  🧶 %s earlier memory change(s) still uncommitted — review: git -C %s diff\n' "${#stale[@]}" "$ROOT" >&2
    printf '\n' >&2
    return 0
  fi

  printf '\n  🧶 grandma noted something from this %s session:\n' "$SCOPE" >&2
  [[ ${#changed[@]} -gt 0 ]] && printf '     • %s memory file(s) updated live this session (uncommitted)\n' "${#changed[@]}" >&2
  [[ "$prop_ok" -eq 1 ]]     && printf '     • a drafted proposal to review\n' >&2
  printf '  review now? [Y/n] ' >&2
  local ans; read -r ans
  if [[ "${ans:-y}" =~ ^[Yy]?$ ]]; then
    if [[ ${#changed[@]} -gt 0 ]]; then
      printf '\n  ── live memory diff (this session) ──\n' >&2
      git -C "$ROOT" --no-pager diff -- ${changed[@]+"${changed[@]}"} >&2
      # brand-new files are invisible to plain diff; show their content too
      for _f in ${changed[@]+"${changed[@]}"}; do
        git -C "$ROOT" ls-files --error-unmatch "$_f" >/dev/null 2>&1 && continue
        [[ -f "$ROOT/$_f" ]] || continue
        printf '  ── new file: %s ──\n' "$_f" >&2
        cat "$ROOT/$_f" >&2
      done
      printf '\n  commit these %s file(s) now? [y/N] ' "${#changed[@]}" >&2
      local cans; read -r cans
      if [[ "${cans:-n}" =~ ^[Yy]$ ]]; then
        if git -C "$ROOT" add -- ${changed[@]+"${changed[@]}"} \
           && git -C "$ROOT" commit -q -m "$SCOPE: session captures"; then
          printf '  🧶 committed.\n' >&2
        else
          printf '  🧶 commit failed — check by hand: git -C %s status\n' "$ROOT" >&2
        fi
      fi
    fi
    if [[ "$prop_ok" -eq 1 ]]; then
      printf '\n  ── drafted proposal (%s) ──\n' "$proposal" >&2
      cat "$proposal" >&2
      printf '\n  apply it interactively with:  grandma review --apply %s\n' "$proposal" >&2
    fi
    printf '\n' >&2
  else
    printf '  🧶 left for later — grandma review %s, or git -C %s diff\n' "$SCOPE" "$ROOT" >&2
  fi
  [[ ${#stale[@]} -gt 0 ]] && printf '  🧶 %s earlier memory change(s) still uncommitted — review: git -C %s diff\n' "${#stale[@]}" "$ROOT" >&2
  printf '\n' >&2
}

# background_distill / on_hangup — the ABRUPT-exit path. If the window is closed (SIGHUP) or
# the process is terminated, bash runs this trap once the foreground `claude` returns. There is
# no terminal left to review in, so we spawn a DETACHED, non-interactive distill that outlives
# us (nohup+disown); it lands a proposal, surfaced at the next launch. The `distilled` flag
# guarantees a session is never distilled twice (post_session sets it on the clean-exit path).
background_distill() {
  [ "${distilled:-0}" = 1 ] && return
  distilled=1
  nohup "$ENGINE/lib/grandma-save.sh" "$SCOPE" ${RP_NAME:+"$RP_NAME"} --auto >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
on_hangup() { rm -f "${PRE_DIRTY_SNAP:-}" 2>/dev/null; background_distill; exit 129; }

# ---- parse args: grandma <sweater> [project] [task...] [--full] [--writing] ----
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
      if [[ -z "$SCOPE" && ${#TASK[@]} -eq 0 && "$arg" != *" "* ]]; then SCOPE="$arg"
      elif [[ -z "$SCOPE" && "$arg" == *" "* ]]; then TASK+=("$arg")   # quoted task, no scope: picker will ask
      elif [[ -z "$PROJECT" && ${#TASK[@]} -eq 0 && "$arg" != *" "* ]]; then PROJECT="$arg"
      else TASK+=("$arg"); fi ;;
  esac
done

if [[ -z "$SCOPE" ]]; then
  # No scope given. Interactively pick one (or describe a new one) when on a terminal.
  if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then
    pick_scope   # sets SCOPE, or execs the new-scope creator, or exits
  else
    echo "usage: grandma <sweater> [project] [task...] [--full] [--writing]" >&2
    echo "  (run 'grandma' on a terminal with no sweater to pick one or knit a new one)" >&2
    exit 2
  fi
fi

# Scope named but not a sweater yet: offer to knit it, instead of a cryptic assemble error.
if ! resolve_scope_dir "$SCOPE" >/dev/null 2>&1; then
  if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then
    printf "\n  no sweater '%s' yet. knit it now? [Y/n] " "$SCOPE" >&2
    read -r _mk
    [[ "${_mk:-y}" =~ ^[Yy]?$ ]] && create_new_scope "$SCOPE"   # execs; does not return
    echo "  ok — run 'grandma' anytime to pick or knit a sweater." >&2
    exit 0
  else
    echo "no sweater '$SCOPE' yet — run 'grandma' to knit one, or 'grandma <existing-sweater>'." >&2
    exit 1
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
  ▣ $BANNER — <3-6 word who-I-am-in-this-sweater hint>
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
  splash_renderer="$(pick_mascot_renderer)"
  if [[ -f "$ENGINE/assets/grandma.gif" && -n "$splash_renderer" ]]; then
    echo "splash:       gif (assets/grandma.gif via $splash_renderer)" >&2
  else
    echo "splash:       wordmark logo (this terminal has no image protocol)" >&2
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
        echo "checkpoint:   skipped (GRANDMA_NO_AUTOSAVE=1)" >&2
      else
        echo "autosave:     would ensure SessionEnd(async) auto-distill hook (proposal on exit)" >&2
        if [[ "${GRANDMA_NO_CHECKPOINT:-0}" == "1" ]]; then
          echo "checkpoint:   skipped (GRANDMA_NO_CHECKPOINT=1)" >&2
        else
          echo "checkpoint:   would ensure PreCompact hook (session working-state saved before compaction, re-injected after)" >&2
        fi
      fi
    fi
  fi
  [[ ${#PASSTHRU[@]} -gt 0 ]] && echo "passthru:     ${PASSTHRU[*]} (forwarded to claude)" >&2
  if compgen -G "$ROOT/proposals/${SCOPE}*.md" >/dev/null 2>&1; then
    pn="$(ls -1 "$ROOT/proposals/${SCOPE}"*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "review:       $pn pending proposal(s) — accepting the offer execs: grandma review --apply $SCOPE" >&2
  fi
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
  install_precompact_hook "$LAUNCH_DIR" "$SCOPE" "$RP_NAME"
  [[ "${GRANDMA_HOOK_INSTALLED:-0}" == "1" || "${GRANDMA_AUTOSAVE_INSTALLED:-0}" == "1" || "${GRANDMA_CHECKPOINT_INSTALLED:-0}" == "1" ]] && \
    printf '  + installed grandma hooks (%s/.claude/settings.local.json)\n' "$RP_NAME" >&2
fi

# Pending memory proposals for this scope (e.g. from a session whose window was closed, so
# it distilled in the background). On a real terminal, OFFER to review them before we start —
# this is where a window-closed session actually gets reviewed. Non-interactive: passive notice.
if compgen -G "$ROOT/proposals/${SCOPE}*.md" >/dev/null 2>&1; then
  n="$(ls -1 "$ROOT/proposals/${SCOPE}"*.md 2>/dev/null | wc -l | tr -d ' ')"
  if [ -t 0 ]; then
    printf '  🧶 grandma noted %s thing(s) from a previous session — review before we start? [Y/n] ' "$n" >&2
    read -r _ans
    if [[ "${_ans:-y}" =~ ^[Yy]?$ ]]; then
      # Open a real review session over ALL of this scope's pending proposals: you approve,
      # decline, and apply each, it commits and deletes them. Applying a proposal is an LLM
      # task (they are free-form prose with caveats), so it needs its own session. We EXEC it
      # (do not fall through to the work session): review, then re-run grandma to start work.
      printf '  🧶 opening review — apply what you approve, then re-run: grandma %s\n\n' "$SCOPE" >&2
      exec "$ENGINE/lib/grandma-review.sh" --apply "$SCOPE"
    fi
  else
    printf '  📝 %s pending memory proposal(s) for %s — run: grandma review %s\n' "$n" "$SCOPE" "$SCOPE" >&2
  fi
fi

# Notice uncommitted memory changes (in-flight captures land as diffs you review).
dirty="$(git -C "$ROOT" status --porcelain -- '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${dirty:-0}" -gt 0 ]]; then
  printf '  🧶 memory has %s uncommitted change(s) — review: git -C %s diff\n' "$dirty" "$ROOT" >&2
fi

# Fingerprint what is dirty NOW, so post_session can tell this session's captures from
# older, already-reviewed diffs. Without this, every uncommitted file re-triggered the
# end-of-session review prompt on every launch until it was committed.
PRE_DIRTY_SNAP="$(mktemp "${TMPDIR:-/tmp}/grandma-predirty-XXXXXX" 2>/dev/null || true)"
if [[ -n "$PRE_DIRTY_SNAP" ]]; then
  dirty_md_files | while IFS= read -r _f; do md_fingerprint "$_f"; done > "$PRE_DIRTY_SNAP"
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
printf '  ⟳ %s\n  ⟳ launching Claude Code — a few seconds; she confirms memory in her first line\n\n' "$BANNER" >&2

# Launch in the project folder if known (so its CLAUDE.md auto-loads), else current dir.
# --add-dir grants write access to the grandma repo so in-flight captures can land.
[[ -n "$LAUNCH_DIR" ]] && cd "$LAUNCH_DIR"
# WRAP the session (do not exec): we regain control when it exits and run post_session to
# distill + offer an immediate review. GRANDMA_DEFER_DISTILL tells the SessionEnd hook to
# stand down so the same session is not distilled twice.
export GRANDMA_DEFER_DISTILL=1
distilled=0
# Abrupt exit (window closed / terminated): capture the session in the background so it is
# never lost. Clean exit: disarm, then post_session distills + reviews in the foreground.
trap on_hangup HUP TERM
CLAUDE_RC=0
claude --name "grandma:$SCOPE${RP_NAME:+/$RP_NAME}" --add-dir "$ROOT" ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$SYSPROMPT" "$INIT" || CLAUDE_RC=$?
trap - HUP TERM
post_session
exit "$CLAUDE_RC"
