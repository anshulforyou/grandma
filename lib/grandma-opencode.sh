#!/usr/bin/env bash
#
# grandma-opencode — run a sweater's session in OpenCode instead of Claude Code.
#
# Same promise as `grandma <sweater>`: global + sweater memory loaded, captures written while you
# work, a distill when you leave. Memory is selected exactly as for claude (assemble.sh) and every
# doctrine is the same prompts/*.md file. Only the transport differs, and it lives in
# lib/adapters/opencode.sh. Nothing is installed into OpenCode: no plugin, no config.
#
# Usage:
#   grandma opencode <sweater> [project] [task...] [--full] [--writing] [-- opencode flags]
#   grandma opencode save <sweater> [project] --session <id> [--auto]
#   grandma opencode review [sweater]
#   grandma opencode doctor
#
# Plain `grandma <sweater>` lands here too when GRANDMA_CLI=opencode, or when the sweater's own
# frontmatter carries a `cli: opencode` line.
#
# GRANDMA_OPENCODE_MODEL=provider/model[#variant] picks the model (default: the one last used in
# that folder). GRANDMA_DRY_RUN=1 prints the plan and contacts nothing. GRANDMA_NO_AUTOSAVE=1
# skips the distill when you leave.

set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
ASSEMBLE="$ENGINE/lib/assemble.sh"
SELF="$ENGINE/lib/grandma-opencode.sh"
source "$ENGINE/lib/grandma-lib.sh"
source "$ENGINE/lib/adapters/opencode.sh"

usage() { sed -n '3,22p' "$SELF" | sed 's/^# \{0,1\}//'; }

# ---- private temp files: memory text and staged transcripts must not outlive this run ----
TMPFILES=()
cleanup_tmp() {
  if [[ ${#TMPFILES[@]} -gt 0 ]]; then rm -rf "${TMPFILES[@]}" 2>/dev/null || true; fi
  return 0
}
# new_tmp <var> — a mode-600 temp file, stored in <var> and remembered for cleanup. It sets a
# variable instead of printing, because a command substitution would forget the cleanup entry.
new_tmp() {
  local _f
  _f="$(mktemp "${TMPDIR:-/tmp}/grandma-oc.XXXXXX")" || return 1
  TMPFILES+=("$_f")
  printf -v "$1" '%s' "$_f"
}

need_home() {
  if [[ ! -d "$ROOT/global" ]]; then
    printf '  no memory home at %s — run: grandma init\n' "$ROOT" >&2
    exit 1
  fi
}

need_opencode() {
  if ! oc_available; then
    printf '  the opencode CLI is not on PATH — install it from https://opencode.ai, then retry.\n' >&2
    exit 1
  fi
}

# check_model_env — refuse a malformed GRANDMA_OPENCODE_MODEL before anything is created.
check_model_env() {
  if [[ -n "${GRANDMA_OPENCODE_MODEL:-}" ]] && ! oc_model_json "$GRANDMA_OPENCODE_MODEL" >/dev/null; then
    printf '  GRANDMA_OPENCODE_MODEL must look like provider/model[#variant], not: %s\n' "$GRANDMA_OPENCODE_MODEL" >&2
    exit 2
  fi
}

# pick_model <dir> — the model for a new session, as JSON: GRANDMA_OPENCODE_MODEL when set, else
# the one last used in <dir> or the current folder, else nothing, which leaves it to OpenCode.
pick_model() {
  local m=""
  if [[ -n "${GRANDMA_OPENCODE_MODEL:-}" ]]; then
    oc_model_json "$GRANDMA_OPENCODE_MODEL"
    return 0
  fi
  m="$(oc_recent_model "$1")"
  if [[ -z "$m" && "$1" != "$PWD" ]]; then m="$(oc_recent_model "$PWD")"; fi
  printf '%s' "$m"
}

model_plan() {
  if [[ -n "${GRANDMA_OPENCODE_MODEL:-}" ]]; then printf '%s (GRANDMA_OPENCODE_MODEL)' "$GRANDMA_OPENCODE_MODEL"
  else printf 'the one last used in %s' "$1"; fi
}

# adapter_note <dir> — what an engine doctrine cannot know about OpenCode. The doctrines were written
# for a claude session started inside the memory repo; this says where things actually are.
adapter_note() {
  printf '\n\n===== RUNNING IN OPENCODE =====\n'
  printf 'This session runs in OpenCode, in %s.\n' "$1"
  printf 'The grandma memory repo is %s: address memory files there by absolute path, and run git as: git -C %s ...\n' "$ROOT" "$ROOT"
  printf 'Where your instructions say ./grandma-test.sh, run: GRANDMA_HOME=%s %s test\n' "$ROOT" "$ENGINE/bin/grandma"
  printf 'Where they tell the user to run grandma <sweater> [project], say: grandma opencode <sweater> [project]\n'
}

# project_doc <dir> — the project CLAUDE.md to carry into the session, or nothing. Claude Code
# reads that file by itself when it starts in the folder; OpenCode reads only AGENTS.md, so without
# this the third memory tier would quietly vanish. When AGENTS.md is the same file (a symlink, or a
# copy), OpenCode already has it and carrying it again would only say everything twice.
project_doc() {
  local c="$1/CLAUDE.md" a="$1/AGENTS.md"
  [[ -f "$c" ]] || return 0
  if [[ -f "$a" ]] && cmp -s "$c" "$a"; then return 0; fi
  printf '%s' "$c"
}

# compose_memory <out> — what a work session carries: the claude launcher's system prompt word for
# word, plus the project's own CLAUDE.md. Reads SCOPE, BUNDLE, RP_NAME and PDOC.
compose_memory() {
  {
    printf "You are operating with a memory bundle for scope '%s'. Treat it as authoritative context about the user and this work context (their name and identity are in the bundle): follow the working preferences and writing style it describes, and use its facts/people/decisions. Do not echo the bundle back; just act on it.\n\n" "$SCOPE"
    printf '%s\n\n' "$BUNDLE"
    if [[ -n "${PDOC:-}" ]]; then
      printf '===== PROJECT CLAUDE.md (%s) =====\n' "$RP_NAME"
      cat "$PDOC"
      printf '\n(This is the project playbook at %s. Follow it, and record project-only captures there.)\n\n' "$PDOC"
    fi
    cat "$ENGINE/prompts/capture.md"
    printf '\n\nThe grandma memory repo is at %s (you have write access to it for captures).\n' "$ROOT"
  } > "$1"
}

# plan_session <title> <dir> <key> <file> <first-message> [allow-dir...] — the dry-run report.
plan_session() {
  local title="$1" dir="$2" key="$3" file="$4" first="$5" cdir n bytes d allow=""
  shift 5
  cdir="$(mktemp -d "${TMPDIR:-/tmp}/grandma-oc-plan-XXXXXX")"
  n="$(oc_chunk "$file" "$cdir" 2>/dev/null || echo '?')"
  rm -rf "$cdir"
  bytes="$(wc -c < "$file" | tr -d ' ')"
  for d in "$ROOT" "$@"; do
    if [[ -n "$d" ]]; then allow="$allow ${d%/}/*"; fi
  done
  {
    echo "cli:          opencode (adapter: lib/adapters/opencode.sh)"
    echo "session:      $title, in $dir"
    echo "memory:       session instruction entries $key (${n} piece(s), $bytes bytes) · outside the project tree, kept through compaction"
    echo "write:        session rule allowing external_directory:$allow"
    echo "model:        $(model_plan "$dir")"
    echo "would launch: (cd $dir && opencode --session <new> --prompt <first message>)"
    echo "--- first message ---"
    printf '%s\n' "$first"
    echo "--- instructions: $bytes bytes ---"
  } >&2
}

# create_session <mode> <title> <dir> <key> <file> [allow-dir...] — create the session and load the
# text into it as instruction entries. Sets SID, and SDIR to the folder it was created in: the
# physical path, the spelling OpenCode records its own sessions under, so a grandma session sits
# with the user's other sessions for that folder. Never leaves behind a session that claims to
# remember without the memory in it: a failed load deletes the session before saying why.
create_session() {
  local mode="$1" title="$2" dir="$3" key="$4" file="$5" model rules meta n
  shift 5
  model="$(pick_model "$dir")"   # before resolving the path: the lookup asks both spellings
  dir="$(oc_physical "$dir")"
  SDIR="$dir"
  rules="$(oc_rules_allow "$ROOT" "$@")"
  meta="$(jq -nc --arg m "$mode" --arg s "${CSCOPE:-}" --arg p "${RP_NAME:-}" \
    '{grandma: {v: 1, mode: $m, scope: (if $s == "" then null else $s end), project: (if $p == "" then null else $p end)}}')"
  SID=""
  if ! SID="$(oc_session_create "$dir" "$title" "$rules" "$meta" "$model")" || [[ -z "$SID" ]]; then
    printf '  🧶 OpenCode would not create a session. Check it with: opencode service status, then: grandma opencode doctor\n' >&2
    exit 1
  fi
  if ! n="$(oc_load "$SID" "$key" "$file")"; then
    oc_session_delete "$SID"
    printf '  🧶 OpenCode would not take the memory as session instructions, so no session was opened:\n' >&2
    printf '     a session that claims to remember without the memory loaded is worse than none.\n' >&2
    printf '     check: grandma opencode doctor\n' >&2
    exit 1
  fi
  if [[ -z "$model" ]]; then
    printf '  🧶 no model was chosen, so OpenCode uses its default. Pick one with GRANDMA_OPENCODE_MODEL=provider/model\n' >&2
  fi
  LOADED="$n"
}

# ---- the terminal UI ----
# The UI runs as a background child that is then waited on, with stdin handed over explicitly (a
# script's background child reads /dev/null otherwise). A foreground child would be simpler, but
# bash defers a trap while a foreground child runs, and OpenCode's UI does not exit when its
# terminal goes away. A hangup that reached only this script, which happens whenever it is the
# terminal's session leader, would then wait forever on a UI nobody can see, and the session would
# never be distilled. `wait` returns the moment a trapped signal arrives, so the trap can pass it on.
TUI_PID=""
forward_tui() {
  if [[ -n "$TUI_PID" ]]; then kill -s "$1" "$TUI_PID" 2>/dev/null || true; fi
  return 0
}

# run_tui <dir> <first-message> — run the UI on $SID until it exits. Its status lands in TUI_RC.
run_tui() {
  oc_tui "$SID" "$1" "$2" ${PASSTHRU[@]+"${PASSTHRU[@]}"} <&0 &
  TUI_PID=$!
  TUI_RC=0
  wait "$TUI_PID" || TUI_RC=$?
  TUI_PID=""
}

# run_doctrine_session <mode> <title> <dir> <key> <file> <first-message> [allow-dir...] — a session
# with one job (onboard, review, knit, interview, an interactive distill): it carries that job's
# doctrine as its instructions, opens the UI, and exits with the UI's status. No distill afterwards,
# the same as the claude launcher, which execs straight into these.
run_doctrine_session() {
  local mode="$1" title="$2" dir="$3" key="$4" file="$5" first="$6"
  shift 6
  create_session "$mode" "$title" "$dir" "$key" "$file" "$@"
  trap 'cleanup_tmp' EXIT
  trap 'forward_tui HUP; exit 129' HUP
  trap 'forward_tui TERM; exit 143' TERM
  run_tui "$SDIR" "$first"
  exit "$TUI_RC"
}

# ------------------------------------------------------------------- knit + interview ----

# knit_sweater [suggested-name] — knit a new sweater from a description, in OpenCode.
knit_sweater() {
  local suggested="${1:-}" desc docfile first
  if [[ -n "$suggested" ]] && scope_name_is_reserved "$suggested"; then
    printf "\n  '%s' is a word grandma's own engine uses, so a sweater by that name would\n" "$suggested" >&2
    printf "  permanently fail 'grandma test'. Pick another name for it.\n" >&2
    exit 2
  fi
  need_opencode
  if [[ -n "$suggested" ]]; then
    printf "\n  Let's knit the '%s' sweater. In a sentence, what is it?\n  (a company, a client, a platform, or an area of your life)\n  > " "$suggested" >&2
  else
    printf '\n  Describe the new sweater — a part of your life to keep memory under.\n  (a company, a client, a platform, or an area like job-search)\n  e.g. "job hunting for staff eng roles; resume at ~/docs/cv.pdf"\n  > ' >&2
  fi
  IFS= read -e -r desc || true
  [[ -n "$desc" ]] || { echo "  no description given, aborting." >&2; exit 1; }
  new_tmp docfile
  {
    cat "$ENGINE/prompts/new-scope.md"
    printf '\n\n===== GLOBAL MEMORY (who the user is) =====\n'
    cat "$ROOT/global/identity.md" "$ROOT/global/preferences.md" "$ROOT/global/style.md" 2>/dev/null || true
    adapter_note "$ROOT"
  } > "$docfile"
  first="Create a new grandma sweater from this description, following your instructions: $desc"
  if [[ -n "$suggested" ]]; then first="The user wants a sweater named '$suggested'. $first"; fi
  grandma_splash "new sweater"
  printf '  ⟳ knitting a new sweater from your description...\n\n' >&2
  run_doctrine_session knit "grandma:new-sweater" "$ROOT" grandma.knit "$docfile" "$first"
}

# first_run — no sweaters yet. Interview the user if the identity is still the template.
first_run() {
  local docfile
  printf '\n  Hello, dear. I am grandma. I remember things for you so your AI never forgets.\n' >&2
  printf '  You keep memory under sweaters: one per part of your life (a job, a client,\n' >&2
  printf '  a platform like reddit, an area like job-search). Under a sweater live your projects.\n\n' >&2
  if grep -q '<your name>' "$ROOT/global/identity.md" 2>/dev/null; then
    printf "  Let's start by getting to know you. (Ctrl+C to skip.)\n\n" >&2
    new_tmp docfile
    { cat "$ENGINE/prompts/init-interview.md"; adapter_note "$ROOT"; } > "$docfile"
    need_opencode
    grandma_splash "grandma"
    run_doctrine_session interview "grandma:init" "$ROOT" grandma.interview "$docfile" \
      "Introduce yourself, explain what a sweater is, interview me, and set up my identity, preferences, and first sweaters per your instructions."
  fi
  printf "  Let's knit your first sweater.\n" >&2
  knit_sweater
}

# pick_scope — `grandma opencode` with no sweater on a terminal. Sets SCOPE, or knits, or exits.
pick_scope() {
  local scopes=() s choice n idx
  while IFS= read -r s; do [[ -n "$s" ]] && scopes+=("$s"); done < <(list_scopes)
  n=${#scopes[@]}
  if (( n == 0 )); then first_run; fi
  printf '\n  grandma — which sweater? (opens in OpenCode)\n' >&2
  for (( idx=0; idx<n; idx++ )); do printf '   %d) %s\n' "$((idx+1))" "${scopes[idx]}" >&2; done
  printf '   n) + knit a new sweater\n   q) quit\n  > ' >&2
  read -r choice || true
  case "$choice" in
    q|Q|"") exit 0 ;;
    n|N)    knit_sweater ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
        SCOPE="${scopes[$((choice-1))]}"
      else
        echo "  invalid choice." >&2; exit 2
      fi ;;
  esac
}

# not_a_sweater <name> — the same answers the claude launcher gives, then exit (or knit).
not_a_sweater() {
  local name="$1" mk
  if scope_name_is_reserved "$name"; then
    printf "\n  '%s' is a name grandma reserves (a subcommand, or a folder it owns in your\n" "$name" >&2
    printf "  memory home), so a sweater by that name could never be loaded. Pick another.\n\n" >&2
    exit 2
  fi
  if [[ -d "$ROOT/$name" ]]; then
    printf "\n  '%s' is a folder in your memory home, but no file in it carries a\n" "$name" >&2
    printf "  'scope: %s' frontmatter line, so grandma does not treat it as a sweater.\n" "$name" >&2
    printf "  Add that line to %s/facts.md (or any .md directly inside it) and re-run.\n\n" "$name" >&2
    exit 1
  fi
  if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then
    printf "\n  no sweater '%s' yet. knit it now? [Y/n] " "$name" >&2
    read -r mk || true
    if [[ "${mk:-y}" =~ ^[Yy]?$ ]]; then knit_sweater "$name"; fi
    echo "  ok — run 'grandma opencode' anytime to pick or knit a sweater." >&2
    exit 0
  fi
  echo "no sweater '$name' yet — run 'grandma opencode' to knit one, or 'grandma opencode <existing-sweater>'." >&2
  exit 1
}

# ---------------------------------------------------------------------------- launch ----

# launch_notices — the lines the claude launcher prints before a session: engine age, waiting
# shares, uncommitted memory, a flat log.md, finished watch reports.
launch_notices() {
  local dirty sd
  grandma_update_notice
  grandma_knit_notice
  dirty="$(git -C "$ROOT" status --porcelain -- '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${dirty:-0}" -gt 0 ]]; then
    printf '  🧶 memory has %s uncommitted change(s) — review: git -C %s diff\n' "$dirty" "$ROOT" >&2
  fi
  if [[ "${GRANDMA_NO_SIZE_WARN:-0}" != "1" && -f "$SCOPE_DIR/log.md" ]]; then
    printf '  🧶 %s/log.md loads every session and only grows — move it into the dated log:\n' "$SCOPE" >&2
    printf '     mkdir -p %s/log && mv %s/log.md %s/log/%s.md\n' "$SCOPE_DIR" "$SCOPE_DIR" "$SCOPE_DIR" "$(date +%Y-%m-%d)" >&2
  fi
  for sd in "$ROOT"/watches/*/; do
    if [[ -f "$sd/report.md" && ! -f "$sd/.seen" ]]; then
      printf '  📊 grandma finished watching: %s — read it: grandma-watch report %s\n' "$(basename "$sd")" "$(basename "$sd")" >&2
    fi
  done
  return 0
}

# post_session — after the UI returns: distill in the foreground, then offer to review what THIS
# session produced. The claude launcher's post_session, with the OpenCode distill and review.
post_session() {
  set +e
  [ -t 0 ] || return 0
  [[ "${GRANDMA_NO_AUTOSAVE:-0}" == "1" ]] && return 0
  cd "$ROOT" 2>/dev/null || return 0
  distilled=1

  printf '\n  🧶 grandma is looking over the session… (Ctrl+C to skip)\n' >&2
  local proposal=""
  # The project travels as the word that was typed, not RP_NAME: save takes one bare word for a
  # project, and a registered name with a space in it would be dropped without a sound.
  proposal="$("$SELF" save "$CSCOPE" ${PROJECT:+"$PROJECT"} --session "$SID" --auto 2>/dev/null | tail -n1)"

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
      printf '\n  apply it in OpenCode with:  grandma opencode review %s\n' "$SCOPE" >&2
    fi
    printf '\n' >&2
  else
    printf '  🧶 left for later — grandma opencode review %s, or git -C %s diff\n' "$SCOPE" "$ROOT" >&2
  fi
  [[ ${#stale[@]} -gt 0 ]] && printf '  🧶 %s earlier memory change(s) still uncommitted — review: git -C %s diff\n' "${#stale[@]}" "$ROOT" >&2
  printf '\n' >&2
}

# background_distill / on_hangup — the window closed under a running session. Distill detached so
# the session is never lost; the proposal is offered at the next launch. `distilled` makes sure a
# session is never distilled twice.
background_distill() {
  [ "${distilled:-0}" = 1 ] && return 0
  distilled=1
  nohup "$SELF" save "$CSCOPE" ${PROJECT:+"$PROJECT"} --session "$SID" --auto >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
on_hangup() { rm -f "${PRE_DIRTY_SNAP:-}" 2>/dev/null; background_distill; exit 129; }

cmd_launch() {
  if [[ "${GRANDMA_DISTILLING:-0}" == "1" ]]; then
    echo "grandma opencode: not starting a session from inside a distill." >&2
    exit 0
  fi
  SCOPE=""; PROJECT=""; TASK=(); PASS=(); PASSTHRU=()
  local ddash=0 arg
  for arg in "$@"; do
    if [[ "$ddash" == "1" ]]; then PASSTHRU+=("$arg"); continue; fi
    case "$arg" in
      --) ddash=1 ;;
      --full|--writing) PASS+=("$arg") ;;
      -*) echo "unknown flag: $arg (forward opencode flags after --, e.g. grandma opencode ... -- --auto)" >&2; exit 2 ;;
      *)
        if [[ -z "$SCOPE" && ${#TASK[@]} -eq 0 && "$arg" != *" "* ]]; then SCOPE="$arg"
        elif [[ -z "$SCOPE" && "$arg" == *" "* ]]; then TASK+=("$arg")
        elif [[ -z "$PROJECT" && ${#TASK[@]} -eq 0 && "$arg" != *" "* ]]; then PROJECT="$arg"
        else TASK+=("$arg"); fi ;;
    esac
  done
  need_home
  check_model_env

  if [[ -z "$SCOPE" ]]; then
    if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then
      pick_scope
    else
      echo "usage: grandma opencode <sweater> [project] [task...] [--full] [--writing]" >&2
      echo "  (run 'grandma opencode' on a terminal with no sweater to pick one or knit a new one)" >&2
      exit 2
    fi
  fi
  resolve_scope_dir "$SCOPE" >/dev/null 2>&1 || not_a_sweater "$SCOPE"

  SCOPE_DIR="$(resolve_scope_dir "$SCOPE")"
  CSCOPE="$(canonical_scope "$SCOPE")"
  BUNDLE="$("$ASSEMBLE" "$SCOPE" ${PASS[@]+"${PASS[@]}"})"
  local file_count tokens banner first dir memfile n
  file_count="$(printf '%s\n' "$BUNDLE" | grep -c '^----- BEGIN ' || true)"
  tokens=$(( ${#BUNDLE} / 4 ))

  # ---- project layer ----
  LAUNCH_DIR=""; RP_NAME=""; PDOC=""
  if [[ -n "$PROJECT" ]]; then
    resolve_project "$SCOPE_DIR" "$PROJECT"
    case "$RP_STATUS" in
      OK)    LAUNCH_DIR="$RP_DIR"; PDOC="$(project_doc "$RP_DIR")" ;;
      AMBIG) echo "'$PROJECT' matches multiple projects in $SCOPE: $RP_CANDS" >&2
             echo "be more specific." >&2; exit 2 ;;
      NONE)  launch_onboard ;;
    esac
  fi

  if [[ -f "$SCOPE_DIR/mcp.json" || -f "$ROOT/global/mcp.json" ]] && [[ "${GRANDMA_NO_MCP:-0}" != "1" ]]; then
    printf '  🧶 mcp: this sweater binds MCP servers, and OpenCode cannot scope servers to one session,\n' >&2
    printf '     so they are not loaded here. They still apply when the sweater runs in Claude Code.\n' >&2
  fi

  banner="memory: $SCOPE loaded · $file_count files · ~${tokens} tokens"
  [[ -n "$LAUNCH_DIR" ]] && banner="$banner · project $RP_NAME"
  first="Before anything else, print exactly one short confirmation line in this shape, filling the hint from the loaded identity/facts (e.g. role + current focus):
  ▣ $banner — <3-6 word who-I-am-in-this-sweater hint>
Then"
  if [[ -n "$LAUNCH_DIR" ]]; then
    first="$first note that you are in project '$RP_NAME' and its CLAUDE.md is loaded from this folder. Then"
  fi
  if [[ ${#TASK[@]} -gt 0 ]]; then
    first="$first address this task:

${TASK[*]}"
  else
    first="$first reply only with 'ready — what are we working on?' and wait for my task."
  fi

  dir="${LAUNCH_DIR:-$PWD}"
  new_tmp memfile
  compose_memory "$memfile"
  read_proposals "$SCOPE"

  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "$LAUNCH_DIR" ]]; then
      echo "mode:         KNOWN project '$RP_NAME' → session in $LAUNCH_DIR (its CLAUDE.md rides in the session instructions)" >&2
    fi
    if [[ ${#PROPOSAL_FILES[@]} -gt 0 ]]; then
      echo "review:       ${#PROPOSAL_FILES[@]} pending proposal(s) — accepting the offer opens: grandma opencode review $CSCOPE" >&2
    fi
    echo "capture:      doctrine loaded (prompts/capture.md) · memory home writable through a session rule" >&2
    echo "banner:       $banner" >&2
    [[ ${#PASSTHRU[@]} -gt 0 ]] && echo "passthru:     ${PASSTHRU[*]} (forwarded to opencode)" >&2
    plan_session "grandma:$CSCOPE${RP_NAME:+/$RP_NAME}" "$dir" grandma.memory "$memfile" "$first"
    cleanup_tmp
    exit 0
  fi

  need_opencode
  if [[ ${#PROPOSAL_FILES[@]} -gt 0 ]]; then
    n="${#PROPOSAL_FILES[@]}"
    if [ -t 0 ]; then
      printf '  🧶 grandma noted %s thing(s) from a previous session — review before we start? [Y/n] ' "$n" >&2
      local _ans; read -r _ans || true
      if [[ "${_ans:-y}" =~ ^[Yy]?$ ]]; then
        printf '  🧶 opening review — apply what you approve, then re-run: grandma opencode %s\n\n' "$SCOPE" >&2
        cleanup_tmp
        exec "$SELF" review "$CSCOPE"
      fi
    else
      printf '  📝 %s pending memory proposal(s) for %s — run: grandma opencode review %s\n' "$n" "$SCOPE" "$SCOPE" >&2
    fi
  fi
  launch_notices

  # Fingerprint what is dirty now, so post_session can tell this session's captures from older diffs.
  PRE_DIRTY_SNAP=""
  new_tmp PRE_DIRTY_SNAP
  dirty_md_files | while IFS= read -r _f; do md_fingerprint "$_f"; done > "$PRE_DIRTY_SNAP"

  create_session work "grandma:$CSCOPE${RP_NAME:+/$RP_NAME}" "$dir" grandma.memory "$memfile"
  grandma_splash "$SCOPE"
  printf '  ⟳ %s\n  ⟳ memory is in the session instructions (%s entr%s), so compaction keeps it\n' \
    "$banner" "$LOADED" "$([[ "$LOADED" == 1 ]] && echo y || echo ies)" >&2
  printf '  ⟳ launching OpenCode — she confirms memory in her first line\n\n' >&2

  # WRAP the UI (do not exec): OpenCode has no session-end signal, so this is how grandma knows the
  # session ended. A closed window distills in the background; a clean exit distills right here.
  distilled=0
  trap 'cleanup_tmp' EXIT
  trap 'cleanup_tmp; forward_tui HUP; on_hangup' HUP
  trap 'cleanup_tmp; forward_tui TERM; on_hangup' TERM
  run_tui "$SDIR" "$first"
  trap - HUP TERM
  post_session
  exit "$TUI_RC"
}

# launch_onboard — the project is unknown in this sweater: a session that registers it, then stops.
launch_onboard() {
  local wroot docfile first
  wroot="$(scope_working_root "$SCOPE_DIR")"
  new_tmp docfile
  {
    cat "$ENGINE/prompts/onboard.md"
    printf '\n\n===== CURRENT MEMORY (scope=%s) =====\n%s' "$SCOPE" "$BUNDLE"
    adapter_note "$ROOT"
  } > "$docfile"
  first="I ran: grandma $SCOPE $PROJECT — but '$PROJECT' is not registered in the $SCOPE scope.
Scope working root: ${wroot:-unknown}. Onboard '$PROJECT' per your instructions (discover an existing folder, or create a new project), register a pointer in $(basename "$SCOPE_DIR")/projects.md, then stop and tell me to re-run."
  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    echo "mode:         ONBOARD (project '$PROJECT' unknown in $SCOPE)" >&2
    echo "working root: ${wroot:-unknown}" >&2
    plan_session "grandma:onboard/$PROJECT" "$ROOT" grandma.onboard "$docfile" "$first" ${wroot:+"$wroot"}
    cleanup_tmp
    exit 0
  fi
  need_opencode
  grandma_splash "$SCOPE"
  printf "  ⟳ %s does not know '%s' yet — let's set it up...\n\n" "$SCOPE" "$PROJECT" >&2
  run_doctrine_session onboard "grandma:onboard/$PROJECT" "$ROOT" grandma.onboard "$docfile" "$first" ${wroot:+"$wroot"}
}

# ---------------------------------------------------------------------------- review ----

cmd_review() {
  local scope="" arg docfile flist first
  for arg in "$@"; do
    case "$arg" in
      -*) echo "unknown flag: $arg" >&2; exit 2 ;;
      *)  scope="$arg" ;;
    esac
  done
  need_home
  check_model_env
  if [[ -z "$scope" ]]; then
    if [[ -t 0 && "${GRANDMA_DRY_RUN:-0}" != "1" ]]; then pick_scope; scope="$SCOPE"
    else echo "usage: grandma opencode review <sweater>" >&2; exit 2; fi
  fi
  resolve_scope_dir "$scope" >/dev/null 2>&1 || { echo "error: no sweater '$scope'" >&2; exit 1; }
  SCOPE="$scope"; CSCOPE="$(canonical_scope "$scope")"; RP_NAME=""
  read_proposals "$scope"
  if [[ ${#PROPOSAL_FILES[@]} -eq 0 ]]; then echo "no pending proposals for $scope."; exit 0; fi
  flist="$(printf '  %s\n' "${PROPOSAL_FILES[@]}")"
  new_tmp docfile
  # The review instructions are grandma-review.sh's, word for word.
  {
    printf 'You are applying pre-computed grandma memory proposal(s). Each proposal file lists\n'
    printf 'target files, actions, and exact text. The pending file(s) for this review:\n%s\n' "$flist"
    printf 'Current memory:\n\n'
    "$ASSEMBLE" "$scope" --full 2>/dev/null || true
    printf '\nWork through the proposals ONE AT A TIME. For each: show it to the user, apply ONLY the\n'
    printf 'edits they approve (respect the memory rules: one fact per line, update in place, no LLM\n'
    printf 'artifacts, absolute dates). Commit sweater/global edits in the grandma repo with a short\n'
    printf 'message. Project CLAUDE.md edits live in that project'"'"'s own working tree (not committed by\n'
    printf 'grandma git). Once a proposal is handled (applied or rejected), delete that proposal file.\n'
    printf 'When every listed proposal has been handled, stop.'
    adapter_note "$ROOT"
  } > "$docfile"
  first="Walk me through the pending memory proposal(s), apply what I approve, commit each, then delete each handled proposal."
  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    echo "would apply: ${PROPOSAL_FILES[*]} (scope=$CSCOPE)" >&2
    plan_session "grandma:review" "$ROOT" grandma.review "$docfile" "$first"
    cleanup_tmp
    exit 0
  fi
  need_opencode
  run_doctrine_session review "grandma:review" "$ROOT" grandma.review "$docfile" "$first"
}

# ------------------------------------------------------------------------------ save ----

# cmd_save — the distiller, for a session that ran in OpenCode. --auto drafts a proposal headlessly
# and applies nothing; without it, a distiller session walks the edits with you, as `grandma save`
# does. The session is always named: picking "the newest transcript" guesses wrong the moment two
# sessions are open, and the session id is the one thing that cannot.
cmd_save() {
  local scope="" project="" sid="" auto=0 next_sid=0 arg
  for arg in "$@"; do
    case "$arg" in
      --auto) auto=1 ;;
      --session) next_sid=1 ;;
      --session=*) sid="${arg#--session=}" ;;
      -*) echo "unknown flag: $arg" >&2; exit 2 ;;
      *)
        if [[ "$next_sid" == "1" ]]; then sid="$arg"; next_sid=0
        elif [[ -z "$scope" ]]; then scope="$arg"
        elif [[ -z "$project" && "$arg" != *" "* ]]; then project="$arg"
        fi ;;
    esac
  done
  if [[ -z "$scope" || -z "$sid" ]]; then
    echo "usage: grandma opencode save <sweater> [project] --session <id> [--auto]" >&2
    exit 2
  fi
  # The id goes into API paths and file names, so it must be exactly an OpenCode session id.
  if [[ ! "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
    echo "error: '$sid' is not an OpenCode session id (ses_...)" >&2
    exit 2
  fi
  need_home
  check_model_env

  local scope_dir project_dir="" project_name="" cscope
  scope_dir="$(resolve_scope_dir "$scope" || true)"
  [[ -n "$scope_dir" ]] || { echo "error: unknown scope '$scope'" >&2; exit 1; }
  cscope="$(canonical_scope "$scope")"
  if [[ -n "$project" ]]; then
    resolve_project "$scope_dir" "$project"
    case "$RP_STATUS" in
      OK)    project_dir="$RP_DIR"; project_name="$RP_NAME" ;;
      AMBIG) echo "'$project' matches multiple in $scope: $RP_CANDS. Be specific." >&2; exit 2 ;;
      NONE)  echo "error: project '$project' not found in $scope (onboard it first with: grandma opencode $scope $project)" >&2; exit 1 ;;
    esac
  fi

  local routing="Route each learning to the RIGHT layer:
- Something about THIS project (a lesson, a gotcha, feedback, a how-to) -> the project's CLAUDE.md at $project_dir/CLAUDE.md.
- Something about how the user works in this whole scope -> $scope_dir/*.md.
- Something universal about the user or how they work everywhere -> global/*.md.
- Follow any sweater-specific routing/feedback conventions described in the loaded sweater memory."
  [[ -z "$project_dir" ]] && routing="Route sweater-specific learnings to the sweater's files, universal ones to global/*.md."

  mkdir -p "$ROOT/proposals" "$ROOT/.distill"
  # The readable transcript is staged INSIDE the memory home, as the claude distiller's is.
  local readable="$ROOT/.distill/opencode-$sid.md"
  local memfile="$ROOT/.distill/opencode-$sid.memory.md"
  local out="$ROOT/proposals/${cscope}${project_name:+-${project_name//\//-}}-$sid.md"

  if [[ "$auto" == "1" ]]; then
    # RECURSION GUARD. Nothing in OpenCode calls back into grandma, and the distill session can run
    # no tool, so a cascade has no way in today. The guard stays anyway: it is the same contract the
    # claude distiller keeps, and it costs nothing.
    [[ "${GRANDMA_DISTILLING:-0}" == "1" ]] && exit 0
    # CIRCUIT BREAKER (airbag), independent of the guard above: if proposals are piling up in the
    # last five minutes, something is looping, so refuse to add another.
    local cap="${GRANDMA_AUTOSAVE_CAP:-10}" recent
    recent="$(find "$ROOT/proposals" -name '*.md' -mmin -5 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${recent:-0}" -ge "$cap" ]]; then
      echo "grandma auto-distill CIRCUIT BREAKER: $recent proposals in the last 5 min (cap $cap). Refusing (likely runaway)." >&2
      exit 0
    fi
    if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
      { echo "mode:        AUTO (headless propose-only, in a deny-all OpenCode session)"
        echo "scope:       $scope${project_name:+  project=$project_name}"
        echo "session:     $sid (its whole transcript is read from OpenCode at run time)"
        echo "proposal ->  $out"; } >&2
      exit 0
    fi
    need_opencode
    # LOCK, one distill per session at a time (the hangup path and a clean exit can race).
    local lock="$ROOT/.distill/.lock-opencode-$sid"
    find "$ROOT/.distill" -maxdepth 1 -name '.lock-opencode-*' -mmin +30 -exec rmdir {} \; 2>/dev/null || true
    if ! mkdir "$lock" 2>/dev/null; then
      echo "grandma opencode: a distill of $sid is already running." >&2
      exit 0
    fi
    local release
    printf -v release 'rmdir %q 2>/dev/null || true; rm -f %q %q' "$lock" "$readable" "$memfile"
    # shellcheck disable=SC2064  # expanding now is the point: the paths are frozen, already %q-quoted
    trap "$release" EXIT
    distill_auto
    exit 0
  fi

  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    { echo "mode:        INTERACTIVE (a distiller session in OpenCode)"
      echo "scope:       $scope${project_name:+  project=$project_name}"
      echo "session:     $sid (its whole transcript is read from OpenCode at run time)"
      [[ -n "$project_dir" ]] && echo "add-dir:     $project_dir (can edit its CLAUDE.md)"
      echo "would launch: (cd $ROOT && opencode --session <new distill:$scope${project_name:+/$project_name}> --prompt <init>)"; } >&2
    exit 0
  fi
  need_opencode
  TMPFILES+=("$readable")
  local tmodel docfile first
  tmodel="$(oc_transcript "$sid" "$readable")" || { echo "error: could not read session $sid from OpenCode." >&2; exit 1; }
  [[ -s "$readable" ]] || { echo "error: session $sid has no text turns to distill." >&2; exit 1; }
  new_tmp docfile
  {
    cat "$ENGINE/prompts/distiller.md"
    printf '\n\n'
    cat "$ENGINE/prompts/capture.md"
    printf '\n\n===== CURRENT MEMORY (scope=%s%s) =====\n' "$scope" "${project_name:+, project=$project_name}"
    "$ASSEMBLE" "$scope" --full 2>/dev/null || true
    if [[ -n "$project_dir" && -f "$project_dir/CLAUDE.md" ]]; then
      printf '\n\n===== PROJECT CLAUDE.md (%s) =====\n' "$project_name"
      cat "$project_dir/CLAUDE.md"
    fi
    adapter_note "$ROOT"
  } > "$docfile"
  first="Distill the work session for scope '$scope'${project_name:+, project '$project_name'}. The readable transcript is at:
$readable

$routing

Read it, then follow your distiller instructions: propose 0-5 atomic memory edits,
get my approval, apply them, and commit. Be conservative."
  SCOPE="$scope"; CSCOPE="$cscope"; RP_NAME="$project_name"
  if [[ -z "${GRANDMA_OPENCODE_MODEL:-}" && -n "$tmodel" ]]; then GRANDMA_OPENCODE_MODEL="$(oc_model_spec "$tmodel")"; fi
  run_doctrine_session distill "distill:$scope${project_name:+/$project_name}" "$ROOT" grandma.distill "$docfile" "$first" \
    ${project_dir:+"$project_dir"}
}

# distill_auto — the headless half of cmd_save (it reads that function's locals). Writes a
# proposal, or nothing at all when there is nothing durable, and never retries a call.
distill_auto() {
  local tmodel model lines hash ledger="$ROOT/.distill/opencode-ledger" asys aprompt dir rc=0 answer
  find "$ROOT/.distill" -maxdepth 1 -name '*.md' -mmin +120 -delete 2>/dev/null || true
  if ! tmodel="$(oc_transcript "$sid" "$readable")"; then
    echo "grandma opencode: could not read session $sid from OpenCode." >&2
    return 0
  fi
  [[ -s "$readable" ]] || return 0
  lines="$(wc -l < "$readable" | tr -d ' ')"
  # One distill per transcript: the same session seen twice (a hangup and a clean exit) is drafted
  # once. A session that went on afterwards has new text, a new hash, and is drafted again.
  hash="$(cksum < "$readable" | tr -d ' ')"
  if grep -qxF "$sid $hash" "$ledger" 2>/dev/null; then return 0; fi

  {
    "$ASSEMBLE" "$scope" --full 2>/dev/null || true
    if [[ -n "$project_dir" && -f "$project_dir/CLAUDE.md" ]]; then
      printf '\n\n===== PROJECT CLAUDE.md (%s) =====\n' "$project_name"
      cat "$project_dir/CLAUDE.md"
    fi
  } > "$memfile"

  model=""
  if [[ -n "${GRANDMA_OPENCODE_MODEL:-}" ]]; then model="$(oc_model_json "$GRANDMA_OPENCODE_MODEL")"
  elif [[ -n "$tmodel" ]]; then model="$tmodel"
  else model="$(oc_session_model "$sid")"; fi

  asys="$(cat "$ENGINE/prompts/distiller.md")

$(cat "$ENGINE/prompts/capture.md")"
  aprompt="$asys

The current memory (scope=$scope${project_name:+, project=$project_name}) is the attached file $(basename "$memfile").
Read the readable transcript, the attached file $(basename "$readable") ($lines lines). Following your distiller instructions,
propose 0-5 atomic memory edits, but DO NOT apply or commit anything. $routing
Output ONLY a concise proposal: for each edit give target file, action, exact text, and a
one-line why. If nothing is durable, output exactly 'No durable learnings.'"

  # The pass runs in the session's own folder when OpenCode still knows it, so it lands in a project
  # OpenCode already tracks instead of making the memory home look like one.
  dir="$(oc_api get "/api/session/$sid" 2>/dev/null | jq -r '(.data // .).location.directory // empty' 2>/dev/null || true)"
  [[ -n "$dir" && -d "$dir" ]] || dir="$ROOT"

  answer="$(export GRANDMA_DISTILLING=1; oc_infer "$dir" "grandma:distill/$cscope" "$model" "$aprompt" "$readable" "$memfile")" || rc=$?
  {
    echo "# grandma memory proposal"
    echo "# scope=$cscope${project_name:+ project=$project_name}  transcript=$(basename "$readable")"
    echo
    if [[ "$rc" -eq 0 ]]; then printf '%s\n' "$answer"; else echo "(distiller failed)"; fi
  } > "$out"
  # The outcome is recorded unless the call is known to have failed: a draft, "nothing durable" and
  # an unknown outcome are all final for this transcript, while a confirmed failure may be retried.
  if [[ "$rc" -ne 1 ]]; then printf '%s %s\n' "$sid" "$hash" >> "$ledger"; fi
  # Keep the proposal only if it proposes something: the claude distiller's content filter.
  if grep -qiF 'no durable learnings' "$out" \
     || grep -qF '(distiller failed)' "$out" \
     || grep -qxF 'Execution error' "$out" \
     || ! grep -qvE '^#|^[[:space:]]*$' "$out"; then
    rm -f "$out"
  else
    echo "$out"
  fi
  return 0
}

# ---------------------------------------------------------------------------- doctor ----

cmd_doctor() {
  local bad=0 v n
  ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
  warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
  miss() { printf '  \033[31mmiss\033[0m %s\n' "$1"; bad=1; }
  echo "grandma opencode doctor"
  echo "== engine =="
  ok "grandma $(engine_version)"
  if [[ -d "$ROOT/global" ]]; then ok "memory home $ROOT"; else miss "no memory home at $ROOT — run: grandma init"; fi
  if grep -q '<your name>' "$ROOT/global/identity.md" 2>/dev/null; then
    warn "identity is still the template — run: grandma opencode (no sweater) to be interviewed"
  fi
  n="$(list_scopes | wc -l | tr -d ' ')"
  if [[ "$n" -gt 0 ]]; then ok "$n sweater(s)"; else warn "no sweaters yet — run: grandma opencode"; fi
  echo "== opencode =="
  if oc_available; then
    v="$(run_bounded 10 "$(oc_bin)" --version < /dev/null 2>/dev/null | head -n1 || true)"
    ok "opencode CLI ${v:-}"
    if oc_api get "/api/session?limit=1" >/dev/null 2>&1; then ok "background service answers (opencode api)"
    else miss "the opencode background service does not answer — try: opencode service restart"; fi
  else
    miss "opencode CLI not on PATH — install it from https://opencode.ai"
  fi
  if [[ -n "${GRANDMA_OPENCODE_MODEL:-}" ]]; then
    if oc_model_json "$GRANDMA_OPENCODE_MODEL" >/dev/null; then ok "model $GRANDMA_OPENCODE_MODEL (GRANDMA_OPENCODE_MODEL)"
    else miss "GRANDMA_OPENCODE_MODEL is not provider/model[#variant]: $GRANDMA_OPENCODE_MODEL"; fi
  else
    ok "model: the one last used in each folder (set GRANDMA_OPENCODE_MODEL to pin one)"
  fi
  echo "== dependencies =="
  for v in jq python3 git; do
    if command -v "$v" >/dev/null 2>&1; then ok "$v"; else miss "$v not found"; fi
  done
  echo "== what this adapter does =="
  oc_capabilities | sed 's/^/  /'
  if [[ "$bad" == "0" ]]; then echo "doctor: healthy"; else echo "doctor: fix the items above"; return 1; fi
}

case "${1:-}" in
  save)           shift; cmd_save "$@" ;;
  review)         shift; cmd_review "$@" ;;
  doctor)         shift; cmd_doctor ;;
  help|-h|--help) usage ;;
  *)              cmd_launch "$@" ;;
esac
