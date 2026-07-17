#!/usr/bin/env bash
adapter_capabilities() { printf '%s\n' 'injection=append headless=yes compaction_hook=yes auto_commit=no'; }
adapter_headless() { GRANDMA_DISTILLING=1 claude -p "$1" --append-system-prompt "$2"; }
adapter_launch() {
  claude --name "$SESSION_NAME" --add-dir "$ROOT" \
    ${PASSTHRU[@]+"${PASSTHRU[@]}"} --append-system-prompt "$SYSPROMPT" "$INIT"
}
adapter_install_compaction_hook() { install_rehydrate_hook "$@"; }
adapter_cleanup() { :; }
