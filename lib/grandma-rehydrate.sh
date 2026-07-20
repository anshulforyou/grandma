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
ASSEMBLE="$ENGINE/lib/assemble.sh"   # reads GRANDMA_HOME itself
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # for the transient session-continuity note

RAW=0
SCOPE=""
for arg in "$@"; do
  case "$arg" in
    --raw) RAW=1 ;;
    *) [[ -z "$SCOPE" ]] && SCOPE="$arg" ;;
  esac
done
[[ -z "$SCOPE" ]] && { echo "usage: grandma-rehydrate.sh <scope> [--raw]" >&2; exit 2; }

# Read the hook's JSON stdin (SessionStart passes session_id, transcript_path, source). We use
# session_id to find the working-state note that grandma-precompact stashed just before this
# compaction, and fold it back in below. PreCompact itself cannot inject context; this is where
# the note gets re-injected.
INPUT=""
[[ -t 0 ]] || INPUT="$(cat 2>/dev/null || true)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

CONTINUITY=""
if [[ -n "$SID" ]]; then
  cnote="$ROOT/.compact/$(printf '%s' "$SID" | tr -cd '[:alnum:]._-').md"
  if [[ -f "$cnote" ]]; then
    CONTINUITY="===== SESSION CONTINUITY (restored after compaction) =====
The detailed conversation was just compacted. This is where the current task stood, captured
right before compaction. Continue from this working state, it is not in the summary above:

$(cat "$cnote")"
  fi
fi

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

${CONTINUITY:+$CONTINUITY

}$(cat "$ENGINE/prompts/capture.md" 2>/dev/null || true)

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
