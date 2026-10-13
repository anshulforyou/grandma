#!/usr/bin/env bash
# lib/adapters/opencode.sh — the OpenCode adapter. Sourced by lib/grandma-opencode.sh after
# grandma-lib.sh, whose run_bounded caps every call made here.
#
# Transport, nothing more. The engine still selects memory (assemble.sh) and owns every doctrine
# (prompts/*.md). This file carries those into an OpenCode session and carries the session's words
# back out, through the opencode CLI and its HTTP API (`opencode api`) and nothing else. It installs
# no plugin, writes no OpenCode config, and never puts a file in a project tree, so a memory-bearing
# AGENTS.md cannot end up in somebody's repository.
#
# How each grandma job maps onto OpenCode, measured against opencode 2.0.27:
#   load     Memory rides in as session instruction entries. They sit at the system level beside
#            AGENTS.md, they are not conversation, so compaction cannot drop them, and a PUT
#            updates them live. One entry holds 256 KiB, and `opencode api` takes its body on argv,
#            where Linux caps a single argument at 128 KiB, so memory is split into entries that
#            each stay well under both.
#   write    The session carries its own rule allowing the memory home as an external directory:
#            the claude launcher's --add-dir "$ROOT", holding for that session only.
#   survive  Nothing to re-inject after compaction, for the reason above. OpenCode's own summary
#            keeps the task state (objective, decisions, work done, next move).
#   end      OpenCode has no session-end signal (idle is not an end), so the launcher wraps the
#            terminal UI and distills when it returns.
#   infer    A throwaway session whose rules deny every tool, its inputs attached as files with
#            `opencode run --file` so their size never meets argv, deleted once it has answered.

OC_BODY_MAX="${GRANDMA_OPENCODE_BODY_MAX:-96000}"   # bytes in one API body, which rides on argv
OC_API_TIMEOUT="${GRANDMA_OPENCODE_TIMEOUT:-30}"    # seconds for one API call
OC_INFER_TIMEOUT="${GRANDMA_DISTILL_TIMEOUT:-300}"  # seconds for one unattended model call

# One page of GET /api/session/<id>/message as grandma's readable transcript: the same shape
# extract_readable_transcript writes for claude. Text turns only; tool calls and reasoning dropped.
OC_TRANSCRIPT_JQ='
  (.data // [])[]
  | if .type == "user" then
      (.text // "") as $t | if ($t | length) > 0 then "USER: \($t)\n" else empty end
    elif .type == "assistant" then
      ([.content[]? | select(.type == "text") | .text] | join("\n")) as $t
      | if ($t | length) > 0 then "ASSISTANT: \($t)\n" else empty end
    else empty end'

# oc_capabilities — what this adapter can and cannot do, as the flag block the adapter design in
# docs/opencode.md describes. The engine reads none of it yet; doctor prints it.
oc_capabilities() {
  cat <<'CAPS'
load_mode=instruction_entries     memory is session instructions, never a file in the project
headless=yes                      opencode run, in a deny-all throwaway session
end_signals=wrapper               no native session end, so the launcher wraps the TUI
checkpoint=native_summary         no pre-compaction hook; OpenCode's summary keeps task state
restore=not_needed                instruction entries are not conversation, compaction keeps them
transcript=api                    every page of /api/session/<id>/message
mcp_per_sweater=no                OpenCode cannot scope MCP servers to one session
auto_commit=no                    nothing is committed without you
CAPS
}

oc_bin() { printf '%s' "${GRANDMA_OPENCODE_BIN:-opencode}"; }
oc_available() { command -v "$(oc_bin)" >/dev/null 2>&1; }

# oc_bytes <string> — its length in bytes, which is what argv limits count.
oc_bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

# oc_api <METHOD> <path> [json-body] — one bounded `opencode api` call. It finds and authenticates
# with the background service by itself. Prints the response and returns opencode's own status,
# which is non-zero for any HTTP error. A body past OC_BODY_MAX is refused here, with a reason,
# rather than handed to the kernel to refuse as "Argument list too long" with no context at all.
# The response goes through run_bounded's file, never straight into a pipe: `opencode api` writing
# a large response into a pipe was measured to stop at 192 KiB.
oc_api() {
  local method="$1" path="$2" body="${3:-}" n
  if [[ -z "$body" ]]; then
    run_bounded "$OC_API_TIMEOUT" "$(oc_bin)" api "$method" "$path"
    return
  fi
  n="$(oc_bytes "$body")"
  if [[ "$n" -gt "$OC_BODY_MAX" ]]; then
    printf '  grandma opencode: a %s-byte request body is over the %s-byte argv budget; not sending it.\n' \
      "$n" "$OC_BODY_MAX" >&2
    return 2
  fi
  run_bounded "$OC_API_TIMEOUT" "$(oc_bin)" api "$method" "$path" --data "$body"
}

# oc_session_create <dir> <title> <rules-json> <metadata-json> [model-json] — prints the new id.
oc_session_create() {
  local dir="$1" title="$2" rules="$3" meta="$4" model="${5:-}" body resp
  [[ -n "$model" ]] || model=null
  body="$(jq -nc --arg d "$dir" --arg t "$title" --argjson r "$rules" --argjson m "$meta" --argjson model "$model" \
    '{title: $t, location: {directory: $d}, permissions: $r, metadata: $m}
     + (if $model == null then {} else {model: $model} end)')" || return 2
  if ! resp="$(oc_api post /api/session "$body")"; then
    [[ -n "$resp" ]] && printf '  opencode said: %s\n' "$resp" >&2
    return 1
  fi
  printf '%s' "$resp" | jq -r '(.data // .).id // empty' 2>/dev/null
}

oc_session_delete() { oc_api delete "/api/session/$1" >/dev/null 2>&1 || true; }

# oc_entry_put <sid> <key> <file> — the file's text as one instruction entry. The JSON is built
# from the file on stdin, so the text never rides argv on its way into the body.
oc_entry_put() {
  local body resp
  body="$(jq -Rsc '{value: .}' < "$3")" || return 2
  if ! resp="$(oc_api put "/api/experimental/session/$1/instructions/entries/$2" "$body")"; then
    [[ -n "$resp" ]] && printf '  opencode said: %s\n' "$resp" >&2
    return 1
  fi
}

# oc_entry_keys <sid> — the keys of the session's instruction entries, one per line.
oc_entry_keys() {
  local resp
  resp="$(oc_api get "/api/experimental/session/$1/instructions/entries")" || return 1
  printf '%s' "$resp" | jq -r '(.data // .)[]?.key // empty' 2>/dev/null
}

oc_entry_delete() { oc_api delete "/api/experimental/session/$1/instructions/entries/$2" >/dev/null 2>&1 || true; }

# oc_chunk <file> <dir> — split the file into pieces whose JSON body {"value": piece} fits
# OC_BODY_MAX, cutting at line ends, and inside a line only when that one line is too big alone.
# Writes <dir>/1, <dir>/2, ... and prints how many. JSON escaping is per character, so a piece's
# encoded size is the sum of its lines' encoded sizes and the split costs one pass.
oc_chunk() {
  python3 - "$1" "$2" "$OC_BODY_MAX" <<'PY'
import json, os, sys
src, outdir, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]) - 64
text = open(src, encoding="utf-8", errors="replace").read()
def enc(s):
    return len(json.dumps(s, ensure_ascii=False).encode("utf-8")) - 2
base = len(json.dumps({"value": ""}).encode("utf-8"))
chunks, cur, size = [], [], base
for line in text.splitlines(True):
    n = enc(line)
    if size + n <= limit:
        cur.append(line)
        size += n
        continue
    if cur:
        chunks.append("".join(cur))
        cur, size = [], base
    while base + enc(line) > limit:
        lo, hi = 1, len(line)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if base + enc(line[:mid]) <= limit:
                lo = mid
            else:
                hi = mid - 1
        chunks.append(line[:lo])
        line = line[lo:]
    cur, size = [line], base + enc(line)
if "".join(cur):
    chunks.append("".join(cur))
for i, c in enumerate(chunks, 1):
    with open(os.path.join(outdir, str(i)), "w", encoding="utf-8") as f:
        f.write(c)
print(len(chunks))
PY
}

# oc_load <sid> <key> <file> — the file's text as instruction entries <key>, <key>.2, <key>.3 ...,
# dropping any higher-numbered piece an earlier, longer load left behind. Prints how many it wrote.
# A failure part way returns non-zero, and the caller then deletes the session: a session that
# says memory loaded when only some of it did is worse than no session.
oc_load() {
  local sid="$1" key="$2" file="$3" dir n i k num
  dir="$(mktemp -d "${TMPDIR:-/tmp}/grandma-oc-chunks-XXXXXX")" || return 1
  if ! n="$(oc_chunk "$file" "$dir")" || [[ ! "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]]; then
    rm -rf "$dir"
    return 1
  fi
  i=1
  while [[ "$i" -le "$n" ]]; do
    k="$key"
    if [[ "$i" -gt 1 ]]; then k="$key.$i"; fi
    if ! oc_entry_put "$sid" "$k" "$dir/$i"; then rm -rf "$dir"; return 1; fi
    i=$((i + 1))
  done
  rm -rf "$dir"
  while IFS= read -r k; do
    case "$k" in
      "$key".*)
        num="${k#"$key".}"
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -gt "$n" ]]; then oc_entry_delete "$sid" "$k"; fi ;;
    esac
  done < <(oc_entry_keys "$sid" 2>/dev/null || true)
  printf '%s' "$n"
}

# oc_rules_allow <dir>... — a session ruleset letting those directories be used as external
# directories, in both spellings when a path runs through a symlink (macOS /var is one): a tool
# checks the path the way it was written, so a rule naming only the physical form can miss it.
oc_rules_allow() {
  local d p out="[]"
  for d in "$@"; do
    [[ -n "$d" ]] || continue
    out="$(printf '%s' "$out" | jq -c --arg r "${d%/}/*" '. + [{action: "external_directory", resource: $r, effect: "allow"}]')"
    p="$(cd "$d" 2>/dev/null && pwd -P || true)"
    if [[ -n "$p" && "$p" != "${d%/}" ]]; then
      out="$(printf '%s' "$out" | jq -c --arg r "$p/*" '. + [{action: "external_directory", resource: $r, effect: "allow"}]')"
    fi
  done
  printf '%s' "$out"
}

# oc_model_spec <model-json> — provider/model[#variant], the form `opencode run --model` takes.
oc_model_spec() {
  printf '%s' "$1" | jq -r '"\(.providerID)/\(.id)"
    + (if (.variant // "") != "" and .variant != "default" then "#\(.variant)" else "" end)' 2>/dev/null
}

# oc_model_json <provider/model[#variant]> — the JSON form the API takes. Fails on anything else.
oc_model_json() {
  local spec="$1" prov rest id var=""
  [[ "$spec" == */* ]] || return 1
  prov="${spec%%/*}"; rest="${spec#*/}"
  id="${rest%%#*}"
  if [[ "$rest" == *"#"* ]]; then var="${rest#*#}"; fi
  [[ -n "$prov" && -n "$id" ]] || return 1
  jq -nc --arg p "$prov" --arg i "$id" --arg v "$var" \
    '{providerID: $p, id: $i} + (if $v == "" then {} else {variant: $v} end)'
}

# oc_session_model <sid> — the session's model as JSON, or nothing.
oc_session_model() {
  local resp
  resp="$(oc_api get "/api/session/$1")" || return 0
  printf '%s' "$resp" | jq -c '(.data // .).model // empty' 2>/dev/null || true
}

# oc_recent_model <dir> — the model of the newest session in <dir> that has one: what the user last
# chose there. A session grandma creates with no model starts on the configured default, and a
# default that cannot answer turns the very first line of a remembered session into an error.
oc_recent_model() {
  local resp q
  q="$(jq -rn --arg d "$1" '$d | @uri')"
  resp="$(oc_api get "/api/session?limit=20&directory=$q")" || return 0
  printf '%s' "$resp" | jq -c '[(.data // [])[] | select(.metadata.grandma.role != "infer")
    | .model | select(. != null)][0] // empty' 2>/dev/null || true
}

# oc_transcript <sid> <out.md> — the session's whole history as grandma's readable transcript, and
# prints the model of its last assistant turn (JSON) when it has one. Every page, not the window
# the model currently sees: after a compaction that window is a summary plus the recent tail, and
# a distiller handed only that would miss most of a long session.
oc_transcript() {
  local sid="$1" out="$2" page path next n m model="" i=0
  page="$(mktemp "${TMPDIR:-/tmp}/grandma-oc-page-XXXXXX")" || return 1
  : > "$out"
  path="/api/session/$sid/message?limit=200&order=asc"
  while [[ "$i" -lt "${GRANDMA_OPENCODE_MAX_PAGES:-500}" ]]; do
    i=$((i + 1))
    if ! oc_api get "$path" > "$page"; then rm -f "$page"; return 1; fi
    if ! jq -r "$OC_TRANSCRIPT_JQ" "$page" >> "$out" 2>/dev/null; then rm -f "$page"; return 1; fi
    m="$(jq -c '[(.data // [])[] | select(.type == "assistant") | .model | select(. != null)] | last // empty' \
          "$page" 2>/dev/null || true)"
    if [[ -n "$m" ]]; then model="$m"; fi
    n="$(jq -r '(.data // []) | length' "$page" 2>/dev/null || echo 0)"
    next="$(jq -r '.cursor.next // empty' "$page" 2>/dev/null || true)"
    if [[ -z "$next" || "$n" == "0" ]]; then break; fi
    path="/api/session/$sid/message?cursor=$next"
  done
  rm -f "$page"
  printf '%s' "$model"
}

# oc_infer <dir> <title> <model-json|""> <instructions> <file>... — one unattended model call.
# Prints the answer. Returns 0 when it ran, 1 when it failed, 4 when the outcome is unknown (sent,
# then timed out). A caller never retries 1 or 4 and never hands the work to another CLI: a call
# that may already have run is not one to run twice.
#
# Its session denies every tool, so the pass can only read what it is handed and answer. It cannot
# edit memory, run a shell, or reach the network. The inputs travel as file attachments, so a long
# transcript never meets an argv limit, and the session is deleted as soon as the call returns.
oc_infer() {
  local dir="$1" title="$2" model="$3" text="$4" dsid out rc=0 f
  shift 4
  local args=(run --format json)
  if [[ "$(oc_bytes "$text")" -gt "$OC_BODY_MAX" ]]; then
    printf '  grandma opencode: the instructions are over the %s-byte argv budget; not sending them.\n' "$OC_BODY_MAX" >&2
    return 1
  fi
  dsid="$(oc_session_create "$dir" "$title" '[{"action":"*","resource":"*","effect":"deny"}]' \
            '{"grandma":{"v":1,"role":"infer"}}' "$model")" || return 1
  [[ -n "$dsid" ]] || return 1
  args+=(--session "$dsid")
  if [[ -n "$model" ]]; then args+=(--model "$(oc_model_spec "$model")"); fi
  for f in "$@"; do args+=(--file "$f"); done
  args+=("$text")
  out="$(mktemp "${TMPDIR:-/tmp}/grandma-oc-run-XXXXXX")" || { oc_session_delete "$dsid"; return 1; }
  run_bounded "$OC_INFER_TIMEOUT" "$(oc_bin)" "${args[@]}" > "$out" || rc=$?
  oc_session_delete "$dsid"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    if [[ "$rc" -eq 124 ]]; then return 4; fi
    return 1
  fi
  jq -r 'select(.type == "text") | .part.text // empty' "$out" 2>/dev/null || true
  rm -f "$out"
}

# oc_tui <sid> <dir> <first-message> [opencode flags...] — become the terminal UI on that session.
# It REPLACES the shell it runs in, so call it as a background child: `oc_tui ... <&0 &`, then wait.
# That way $! is the UI itself and a signal can be passed straight to it. The first message is a few
# hundred bytes of instructions, never memory: memory rides in the session's instruction entries.
oc_tui() {
  local sid="$1" dir="$2" first="$3"
  shift 3
  cd "$dir" || return 1
  exec "$(oc_bin)" --session "$sid" --prompt "$first" "$@" "$dir"
}
