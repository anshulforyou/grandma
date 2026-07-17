#!/usr/bin/env bash
adapter_capabilities() { printf '%s\n' 'injection=contextfile headless=yes compaction_hook=no auto_commit=no'; }
adapter_headless() { GRANDMA_DISTILLING=1 gemini -p "$2

$1"; }
adapter_context_file_path() { printf '%s/GEMINI.md' "$PWD"; }
adapter_cleanup() {
  [[ "${ADAPTER_CONTEXT_ACTIVE:-0}" == "1" ]] || return 0
  rm -f "${ADAPTER_CONTEXT_FILE:-}"
  ADAPTER_CONTEXT_ACTIVE=0
}
adapter_launch() {
  local prompt="$INIT" started rc=0 f m newest="" newest_m=0
  ADAPTER_CONTEXT_ACTIVE=0
  ADAPTER_CONTEXT_FILE="$(adapter_context_file_path)"
  if [[ -e "$ADAPTER_CONTEXT_FILE" ]]; then
    # Never risk replacing a user's context file. Prepend memory for this session.
    prompt="$SYSPROMPT

$INIT"
  else
    printf '%s\n' "$SYSPROMPT" > "$ADAPTER_CONTEXT_FILE"
    ADAPTER_CONTEXT_ACTIVE=1
  fi
  started="$(date +%s)"
  gemini --include-directories "$ROOT" -i "$prompt" ${PASSTHRU[@]+"${PASSTHRU[@]}"} || rc=$?
  # Gemini records newline-delimited JSON under project-specific chats dirs.
  # Remember only a file touched by this session; save.sh receives it explicitly.
  for f in "$HOME"/.gemini/tmp/*/chats/session-*.json; do
    [[ -f "$f" ]] || continue
    m="$(file_mtime "$f")"
    [[ "$m" -ge "$started" && "$m" -ge "$newest_m" ]] || continue
    newest="$f"; newest_m="$m"
  done
  # shellcheck disable=SC2034  # consumed by launcher's post-session distiller
  GRANDMA_LAST_TRANSCRIPT="$newest"
  return "$rc"
}
