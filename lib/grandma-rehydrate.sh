#!/usr/bin/env bash
#
# grandma-rehydrate — restore grandma's context after a compaction.
#
# grandma injects scope memory via --append-system-prompt, which Claude Code
# THROWS AWAY when it auto-compacts a long session. This script is wired as a
# SessionStart(compact) hook in grandma-launched projects: after each compaction
# it re-assembles the scope bundle and feeds it back into context, so grandma's
# memory self-heals instead of evaporating.
#
# Usage (as a hook):  grandma-rehydrate.sh <scope>
#   --raw   print the human-readable payload instead of the hook JSON (for testing)
#
# It reads the hook's JSON stdin but only needs the scope arg.

set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$ENGINE/lib/assemble.sh"   # reads GRANDMA_HOME itself; no ROOT needed here

RAW=0
SCOPE=""
for arg in "$@"; do
  case "$arg" in
    --raw) RAW=1 ;;
    *) [[ -z "$SCOPE" ]] && SCOPE="$arg" ;;
  esac
done
[[ -z "$SCOPE" ]] && { echo "usage: grandma-rehydrate.sh <scope> [--raw]" >&2; exit 2; }

# Drain stdin (hook passes JSON there); we don't need it, but avoid SIGPIPE.
[[ -t 0 ]] || cat >/dev/null 2>&1 || true

BUNDLE="$("$ASSEMBLE" "$SCOPE" 2>/dev/null || true)"

REMINDER="[grandma] The conversation was just compacted, which drops the memory grandma
injected at launch. It is restored above. Reminders:
- Keep following the working preferences and writing style from this memory (including no LLM artifacts).
- This project's CLAUDE.md (re-read from disk) is authoritative for the task; follow the
  sweater-specific rules in the restored memory above.
- Any durable corrections or feedback the user gives should be recorded in the project's
  CLAUDE.md so they persist across future sessions."

PAYLOAD="===== GRANDMA MEMORY (scope=$SCOPE, re-injected after compaction) =====
$BUNDLE

$(cat "$ENGINE/prompts/capture.md" 2>/dev/null || true)

$REMINDER"

if [[ "$RAW" == "1" ]]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

# Emit as a SessionStart hook result. additionalContext is added to the session.
# (Exact field names confirmed against Claude Code hooks docs.)
python3 - "$PAYLOAD" <<'PY'
import json, sys
ctx = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx
    }
}))
PY
