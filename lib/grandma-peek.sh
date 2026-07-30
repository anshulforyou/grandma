#!/usr/bin/env bash
#
# grandma-peek — grade each assistant message against the memory you already wrote down.
#
# grandma loads your identity, preferences, sweater workflow and the project's CLAUDE.md into
# every session, and then nothing checks whether any of it was followed. peek closes that loop:
# it reads each finished assistant message plus a ledger of what actually ran, and reports only
# what breaks a line you wrote — quoting the line.
#
# THIS IS v0 (shadow mode). It observes and logs. It NEVER renders anything to the screen and
# never returns displayContent, so it cannot say anything wrong because it cannot say anything.
# The whole v0 -> v1 switch is the `render` branch in cmd_display.
#
# Because v0 does not render, it does not need the verdict synchronously: the grading is detached
# with nohup and the hook returns in ~1ms. v1 has to block for it (MessageDisplay holds the batch
# until the hook returns), which is why latency_ms is logged from the start.
#
# Hook modes (installed by grandma-launch.sh):
#   grandma-peek.sh display <scope> [project]   MessageDisplay — grade on the final batch
#   grandma-peek.sh batch   <scope>             PostToolBatch  — append tool calls to the ledger
#   grandma-peek.sh fail    <scope>             PostToolUseFailure — mark a failure
#   grandma-peek.sh grade   <jobfile>           internal: the detached child that calls the model
#
# CLI:
#   grandma peek [--session <id>] [--json]      what peek has logged this session
#
# Every path exits 0. A hook that fails must never block, slow, or corrupt a session.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"

PEEK_ROOT="$ROOT/.peek"
CAP="${GRANDMA_PEEK_CAP:-30}"            # model calls per 5 min, per session (provisional; v0 sets it)
MODEL="${GRANDMA_PEEK_MODEL:-haiku}"
MAX_MSG_CHARS="${GRANDMA_PEEK_MAX_MSG:-8000}"
MAX_LEDGER=40                            # ledger lines fed to the model, newest last

# ---- claude binary. A hook runs in a non-interactive sh -c whose PATH may not carry
# ~/.local/bin, so a bare `command -v claude` misses a perfectly good native install.
#
# GRANDMA_PEEK_CLAUDE pins the binary outright. It exists because the fallback list below is
# absolute: stripping PATH does NOT hide a real install, so the "claude is missing" path was
# untestable and a suite run on a developer machine would have made a live model call. It is
# also the escape hatch for anyone whose claude lives somewhere none of these look.
claude_bin() {
  if [[ -n "${GRANDMA_PEEK_CLAUDE:-}" ]]; then
    [[ -x "${GRANDMA_PEEK_CLAUDE}" ]] || return 1
    printf '%s' "$GRANDMA_PEEK_CLAUDE"; return 0
  fi
  command -v claude 2>/dev/null && return 0
  local c
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# safe_id <raw> — a session id fit to be a directory name.
safe_id() { printf '%s' "${1:-}" | tr -cd '[:alnum:]._-' | cut -c1-64; }

# sdir <session_id> — this session's peek directory. Created on demand.
sdir() { printf '%s/%s' "$PEEK_ROOT" "$(safe_id "$1")"; }

# jqr <json> <filter> — read one field, empty on any failure. Never lets jq's exit status escape.
jqr() { printf '%s' "$1" | jq -r "$2" 2>/dev/null || true; }

# ---- guards -----------------------------------------------------------------------------------
# peek_disabled — the cheap bail-outs, checked before anything costs anything.
peek_disabled() {
  [[ "${GRANDMA_NO_PEEK:-0}" == "1" ]] && return 0    # kill switch
  [[ "${GRANDMA_DISTILLING:-0}" == "1" ]] && return 0 # recursion guard: a distill/watch/peek child
  command -v jq >/dev/null 2>&1 || return 0           # no jq, no parsing
  return 1
}

# cap_tripped <sdir> — airbag, independent of the recursion guard. Bounds a runaway to CAP model
# calls instead of thousands. Markers are scoped PER SESSION: peek fires once per message, so a
# global counter would let three concurrent sessions trip a breaker none of them caused.
# The 5-minute window matches the hardcoded -mmin -5 in precompact and save.
cap_tripped() {
  local d="$1" recent
  recent="$(find "$d" -name '.run.*' -mmin -5 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${recent:-0}" -ge "$CAP" ]]
}

# ---- ledger -----------------------------------------------------------------------------------
# The ledger is what ACTUALLY ran, so a claim in a message can be checked against it. Tool output
# is deliberately NOT retained: claims are made about what ran and whether it worked, and a full
# tool_response would be unbounded. PostToolBatch carries no per-call success flag (verified on
# 2.1.219), which is why PostToolUseFailure is a separate sensor rather than a convenience.
ledger_append() {
  local d="$1" line="$2"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$d/ledger.jsonl" 2>/dev/null || true
}

# tool_target <tool_name> <tool_input_json> — the one field a claim is usually about.
tool_target() {
  local n="$1" inp="$2" t
  case "$n" in
    Bash) t="$(jqr "$inp" '.command // empty')" ;;
    Read|Edit|Write|NotebookEdit) t="$(jqr "$inp" '.file_path // empty')" ;;
    Glob|Grep) t="$(jqr "$inp" '.pattern // empty')" ;;
    *) t="$(jqr "$inp" '.file_path // .command // .pattern // .query // empty')" ;;
  esac
  printf '%s' "$(printf '%s' "$t" | tr '\n' ' ' | cut -c1-200)"
}

cmd_batch() {
  local input d n i tgt
  input="$(cat 2>/dev/null || true)"
  peek_disabled && return 0
  d="$(sdir "$(jqr "$input" '.session_id // empty')")"
  [[ "$d" == "$PEEK_ROOT/" ]] && return 0
  local calls; calls="$(jqr "$input" '(.tool_calls // []) | length')"
  [[ "${calls:-0}" -gt 0 ]] 2>/dev/null || return 0
  local k=0
  while [[ "$k" -lt "$calls" ]]; do
    n="$(jqr "$input" ".tool_calls[$k].tool_name // empty")"
    i="$(printf '%s' "$input" | jq -c ".tool_calls[$k].tool_input // {}" 2>/dev/null || echo '{}')"
    tgt="$(tool_target "$n" "$i")"
    ledger_append "$d" "$(jq -nc --arg t "$n" --arg g "$tgt" --arg o ok \
      '{tool:$t,target:$g,outcome:$o}' 2>/dev/null || true)"
    k=$((k + 1))
  done
  return 0
}

cmd_fail() {
  local input d n tgt err
  input="$(cat 2>/dev/null || true)"
  peek_disabled && return 0
  d="$(sdir "$(jqr "$input" '.session_id // empty')")"
  [[ "$d" == "$PEEK_ROOT/" ]] && return 0
  n="$(jqr "$input" '.tool_name // empty')"
  tgt="$(tool_target "$n" "$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null || echo '{}')")"
  err="$(jqr "$input" '.tool_error // empty' | tr '\n' ' ' | cut -c1-200)"
  ledger_append "$d" "$(jq -nc --arg t "$n" --arg g "$tgt" --arg o failed --arg e "$err" \
    '{tool:$t,target:$g,outcome:$o,error:$e}' 2>/dev/null || true)"
  return 0
}

# ---- display ----------------------------------------------------------------------------------
# The MessageDisplay hook. Claude Code holds each batch until this returns, so every non-final
# batch MUST return instantly. Only the final batch does any work, and in v0 even that work is
# handed to a detached child so the hook still returns in ~1ms.
cmd_display() {
  local scope="${1:-}" project="${2:-}" input
  input="$(cat 2>/dev/null || true)"
  peek_disabled && return 0

  # Non-final batches: nothing, immediately. This is the hot path.
  [[ "$(jqr "$input" '.final // false')" == "true" ]] || return 0

  local sid did tid mid delta
  sid="$(jqr "$input" '.session_id // empty')"
  tid="$(jqr "$input" '.turn_id // empty')"
  mid="$(jqr "$input" '.message_id // empty')"
  delta="$(jqr "$input" '.delta // empty')"
  [[ -n "$sid" ]] || return 0
  did="$(sdir "$sid")"
  mkdir -p "$did" 2>/dev/null || return 0

  # A final batch whose delta is empty still ends a message, but with no text there is nothing
  # to grade. In interactive runs that is the common case when a message ends on a newline.
  local msg; msg="$(printf '%s' "$delta" | cut -c1-"$MAX_MSG_CHARS")"
  if [[ -z "$(printf '%s' "$msg" | tr -d '[:space:]')" ]]; then
    log_line "$did" "$tid" "$mid" 0 0 0 0 0 0 '[]' 0 empty_message
    return 0
  fi

  if cap_tripped "$did"; then
    log_line "$did" "$tid" "$mid" "${#msg}" 0 0 0 0 0 '[]' 0 cap
    return 0
  fi

  # Stage the job for the child. Writing it to a file keeps every harvested string out of the
  # command line: a message, a sweater name or a rule can contain anything at all.
  local job; job="$did/.job.$(date +%s).$$"
  jq -nc --arg sid "$sid" --arg tid "$tid" --arg mid "$mid" --arg scope "$scope" \
        --arg project "$project" --arg msg "$msg" --arg dir "$did" \
    '{session_id:$sid,turn_id:$tid,message_id:$mid,scope:$scope,project:$project,message:$msg,dir:$dir}' \
    > "$job" 2>/dev/null || return 0

  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    { echo "mode:       PEEK display (v0 shadow)"
      echo "scope:      $scope${project:+  project=$project}"
      echo "session:    $sid"
      echo "message:    ${#msg} chars"
      echo "model:      $MODEL"
      echo "would run:  grandma-peek.sh grade $job (detached)"
      echo "renders:    nothing (v0)"; } >&2
    rm -f "$job" 2>/dev/null
    return 0
  fi

  # v0: detached, so the hook returns now and the session never waits.
  # v1: this becomes a synchronous call whose findings are returned as displayContent.
  #
  # GRANDMA_PEEK_SYNC=1 grades inline instead. The suite needs it, because a detached child
  # finishes after the assertion would run — but it is not a test-only hatch: it is the v1
  # code path, exercised now so the switch is a change of what we do with the findings rather
  # than a change of how we get them.
  if [[ "${GRANDMA_PEEK_SYNC:-0}" == "1" ]]; then
    GRANDMA_DISTILLING=1 "$ENGINE/lib/grandma-peek.sh" grade "$job" >/dev/null 2>&1
  else
    GRANDMA_DISTILLING=1 nohup "$ENGINE/lib/grandma-peek.sh" grade "$job" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  return 0
}

# ---- the graded call --------------------------------------------------------------------------
# log_line <dir> <turn> <msg_id> <msg_chars> <ledger_n> <rules_chars> <latency_ms> <in_tok> <out_tok>
#          <findings_json> <dropped_uncited> <suppressed_by>
# One line per graded message. This IS the v0 deliverable: the five threshold constants, tokens
# per message, messages per turn (group by turn_id), the pause v1 will cost, and the eval corpus.
log_line() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || return 0
  jq -nc --arg ts "$(date +%s)" --arg turn "$2" --arg msg "$3" \
    --argjson mc "${4:-0}" --argjson ln "${5:-0}" --argjson rc "${6:-0}" \
    --argjson ms "${7:-0}" --argjson it "${8:-0}" --argjson ot "${9:-0}" \
    --argjson f "${10:-[]}" --argjson du "${11:-0}" --arg sup "${12:-}" --arg model "$MODEL" \
    '{ts:($ts|tonumber),turn_id:$turn,message_id:$msg,message_chars:$mc,ledger_size:$ln,
      rules_chars:$rc,latency_ms:$ms,in_tokens_est:$it,out_tokens_est:$ot,model:$model,
      findings:$f,would_have_spoken:(($f|length)>0),dropped_uncited:$du,
      suppressed_by:(if $sup=="" then null else $sup end)}' \
    >> "$d/log.jsonl" 2>/dev/null || true
}

cmd_grade() {
  local job="${1:-}"
  [[ -f "$job" ]] || return 0
  local spec; spec="$(cat "$job" 2>/dev/null || true)"
  rm -f "$job" 2>/dev/null

  local d scope project msg tid mid
  d="$(jqr "$spec" '.dir // empty')"
  scope="$(jqr "$spec" '.scope // empty')"
  project="$(jqr "$spec" '.project // empty')"
  msg="$(jqr "$spec" '.message // empty')"
  tid="$(jqr "$spec" '.turn_id // empty')"
  mid="$(jqr "$spec" '.message_id // empty')"
  [[ -n "$d" && -n "$msg" ]] || return 0

  # LOCK, per session. MessageDisplay batches are serialised by Claude Code, but a detached child
  # outlives its hook, so two children of the same session can overlap. Atomic mkdir, stale after
  # 10 minutes so a killed child cannot wedge the session forever.
  local lock="$d/.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    local age; age=$(( $(date +%s) - $(file_mtime "$lock") ))
    if [[ "$age" -lt 600 ]]; then
      log_line "$d" "$tid" "$mid" "${#msg}" 0 0 0 0 0 '[]' 0 lock
      return 0
    fi
    rm -rf "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
  fi
  trap 'rm -rf "$lock" 2>/dev/null || true' EXIT

  local CB; CB="$(claude_bin)" || { log_line "$d" "$tid" "$mid" "${#msg}" 0 0 0 0 0 '[]' 0 no_claude; return 0; }

  # RULES — the same text the session itself was given, read fresh from disk so an instruction
  # captured mid-session is already visible here. assemble.sh covers global + sweater; the
  # project CLAUDE.md is NOT in that bundle (it reaches the session because the launcher cd's
  # into the folder), so it is appended explicitly, as grandma-save.sh already does.
  local rules=""
  [[ -n "$scope" ]] && rules="$("$ENGINE/lib/assemble.sh" "$scope" 2>/dev/null || true)"
  # Resolve the project's folder HERE rather than in the hook: this runs off the critical path,
  # and assemble.sh covers only global + sweater. The project CLAUDE.md holds the densest rules
  # in the tree and reaches the session because the launcher cd's into the folder, so without
  # this peek would grade against memory the session had but peek could not see.
  local pdir=""
  if [[ -n "$scope" && -n "$project" ]]; then
    local sdir_p; sdir_p="$(resolve_scope_dir "$scope" 2>/dev/null || true)"
    if [[ -n "$sdir_p" ]]; then
      resolve_project "$sdir_p" "$project" 2>/dev/null || true
      [[ "${RP_STATUS:-NONE}" == "OK" ]] && pdir="${RP_DIR:-}"
    fi
  fi
  if [[ -n "$pdir" && -f "$pdir/CLAUDE.md" ]]; then
    rules="$rules

===== BEGIN $project/CLAUDE.md =====
$(cat "$pdir/CLAUDE.md" 2>/dev/null || true)
===== END $project/CLAUDE.md ====="
  fi

  local ledger="" lcount=0
  if [[ -f "$d/ledger.jsonl" ]]; then
    ledger="$(tail -n "$MAX_LEDGER" "$d/ledger.jsonl" 2>/dev/null || true)"
    lcount="$(wc -l < "$d/ledger.jsonl" 2>/dev/null | tr -d ' ')"
  fi

  local SYS PROMPT
  SYS="$(cat "$ENGINE/prompts/peek.md" 2>/dev/null || true)"
  PROMPT="===== RULES =====
${rules:-(no memory loaded)}

===== LEDGER (what actually ran this session) =====
${ledger:-(nothing has run yet)}

===== MESSAGE (grade this) =====
$msg

Return JSON only, per your instructions."

  : > "$d/.run.$(date +%s).$$" 2>/dev/null || true   # cost-cap marker: one per model call

  local t0 t1 out ms
  t0="$(date +%s)"
  out="$( cd "$ROOT" && GRANDMA_DISTILLING=1 "$CB" -p "$PROMPT" \
          --model "$MODEL" --append-system-prompt "$SYS" 2>/dev/null )" || out=""
  t1="$(date +%s)"
  ms=$(( (t1 - t0) * 1000 ))

  local in_tok=$(( (${#PROMPT} + ${#SYS}) / 4 )) out_tok=$(( ${#out} / 4 ))

  # THE CITATION RULE, enforced here rather than in the prompt. A finding without a verbatim
  # cited_file AND cited_line is dropped before it can reach a log line or, in v1, a screen.
  # Doing it in the shell makes it deterministic and testable, and independent of the weak model
  # choosing to behave. Anything unparseable degrades to no findings.
  #
  # The fence strip is load-bearing, not cosmetic. Models routinely wrap JSON in a ```json
  # fence; cutting from the first brace to the end leaves the CLOSING fence behind, jq then
  # sees two inputs and prints two numbers, and "1\n0" reaching an arithmetic expansion is a
  # FATAL error in bash — the child died there, silently, before it could log anything. Slurping
  # and taking the first value tolerates the fence, trailing prose, and a stray second object.
  local raw kept dropped n_raw n_kept
  raw="$(printf '%s' "$out" | sed -e 's/```[a-zA-Z]*//g' -e '/^[[:space:]]*$/d' \
         | sed -n '/{/,$p' | jq -s -c '(.[0].findings) // []' 2>/dev/null || echo '[]')"
  [[ -n "$raw" ]] || raw='[]'
  kept="$(printf '%s' "$raw" | jq -c '[ .[] | select(
            ((.cited_file // "") | test("\\S")) and ((.cited_line // "") | test("\\S")) ) ]' \
          2>/dev/null || echo '[]')"
  [[ -n "$kept" ]] || kept='[]'
  # Counts go through head+tr before any arithmetic, so a multi-line or non-numeric jq result
  # can never reach $(( )). Same reason file_mtime pipes through tr -cd '0-9'.
  n_raw="$(printf '%s' "$raw"  | jq 'length' 2>/dev/null | head -n1 | tr -cd '0-9')"
  n_kept="$(printf '%s' "$kept" | jq 'length' 2>/dev/null | head -n1 | tr -cd '0-9')"
  dropped=$(( ${n_raw:-0} - ${n_kept:-0} ))
  [[ "$dropped" -ge 0 ]] || dropped=0

  log_line "$d" "$tid" "$mid" "${#msg}" "${lcount:-0}" "${#rules}" "$ms" "$in_tok" "$out_tok" \
           "$kept" "$dropped" ""

  # v0 STOPS HERE. It has graded, it has logged, and it renders nothing. v1 returns the findings
  # as displayContent from cmd_display instead of detaching to get here.
  return 0
}

# ---- CLI --------------------------------------------------------------------------------------
cmd_cli() {
  local want="" as_json=0 a
  for a in "$@"; do
    case "$a" in
      --json) as_json=1 ;;
      --session) want="__next__" ;;
      -h|--help) sed -n '3,30p' "$ENGINE/lib/grandma-peek.sh" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) [[ "$want" == "__next__" ]] && want="$a" ;;
    esac
  done
  if [[ ! -d "$PEEK_ROOT" ]]; then
    echo "peek has not run yet. It is installed at launch and logs to $PEEK_ROOT (v0: shadow mode, nothing is shown in-session)."
    return 0
  fi
  local latest
  if [[ -n "$want" && "$want" != "__next__" ]]; then latest="$(sdir "$want")"
  else latest="$(ls -td "$PEEK_ROOT"/*/ 2>/dev/null | head -n1)"; fi
  latest="${latest%/}"
  if [[ -z "$latest" || ! -f "$latest/log.jsonl" ]]; then
    echo "no peek log yet${want:+ for session $want}."
    return 0
  fi
  if [[ "$as_json" == "1" ]]; then cat "$latest/log.jsonl"; return 0; fi
  python3 - "$latest/log.jsonl" <<'PY' 2>/dev/null || cat "$latest/log.jsonl"
import json, sys, collections
rows = []
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if line:
        try: rows.append(json.loads(line))
        except Exception: pass
if not rows:
    print("no peek log yet."); raise SystemExit
graded = [r for r in rows if not r.get("suppressed_by")]
spoke  = [r for r in graded if r.get("would_have_spoken")]
turns  = collections.Counter(r.get("turn_id") for r in rows if r.get("turn_id"))
lat    = sorted(r.get("latency_ms") or 0 for r in graded if r.get("latency_ms"))
tok    = [r.get("in_tokens_est") or 0 for r in graded]
print(f"peek — shadow mode (v0). nothing was shown in-session.\n")
print(f"  messages seen      {len(rows)}")
print(f"  graded             {len(graded)}")
print(f"  would have spoken  {len(spoke)}" + (f"  ({100*len(spoke)//len(graded)}%)" if graded else ""))
print(f"  uncited dropped    {sum(r.get('dropped_uncited') or 0 for r in rows)}")
if turns:
    print(f"  messages per turn  avg {sum(turns.values())/len(turns):.1f}  max {max(turns.values())}")
if lat:
    print(f"  grading latency    median {lat[len(lat)//2]} ms   max {max(lat)} ms")
if tok:
    print(f"  tokens per message est. avg {sum(tok)//len(tok)}")
sup = collections.Counter(r.get("suppressed_by") for r in rows if r.get("suppressed_by"))
if sup:
    print("  suppressed         " + ", ".join(f"{k}={v}" for k, v in sup.items()))
if spoke:
    print("\n  what it would have said:")
    for r in spoke[-5:]:
        for f in r.get("findings") or []:
            print(f"    [{f.get('class','?')}] {f.get('what','')}")
            print(f"        cites {f.get('cited_file','')}: \"{f.get('cited_line','')}\"")
            if f.get("suggestion"): print(f"        suggests: {f['suggestion']}")
PY
  return 0
}

case "${1:-}" in
  display) shift; cmd_display "$@" ;;
  batch)   shift; cmd_batch   "$@" ;;
  fail)    shift; cmd_fail    "$@" ;;
  grade)   shift; cmd_grade   "$@" ;;
  *)       cmd_cli "$@" ;;
esac
exit 0
