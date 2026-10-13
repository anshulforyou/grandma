#!/usr/bin/env bash
# ERE matching for the deterministic engine. Values arrive as quoted assignments on stdin.
set -uo pipefail
peek_match() {
  local pattern="$1" text="$2" rc=0
  [[ "$text" =~ $pattern ]]
  rc=$?
  printf '%s\0%s\0' "$rc" "${BASH_REMATCH[1]:-}"
}
