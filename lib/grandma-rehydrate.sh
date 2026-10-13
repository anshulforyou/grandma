#!/usr/bin/env bash
#
# grandma-rehydrate - restore the session's working-state note after compaction.
#
# The appended system prompt survives compaction, including the memory bundle and
# capture doctrine. This SessionStart(compact) hook carries only the continuity note
# saved by grandma-precompact, capped so additionalContext fits into the session.
#
# Usage (as a hook): grandma-rehydrate.sh <scope>
#   --raw   print the human-readable payload instead of the hook JSON (for testing)

set -euo pipefail

ROOT="${GRANDMA_HOME:-$HOME/.grandma}"

RAW=0
SCOPE=""
for arg in "$@"; do
  case "$arg" in
    --raw) RAW=1 ;;
    *) [[ -z "$SCOPE" ]] && SCOPE="$arg" ;;
  esac
done
[[ -z "$SCOPE" ]] && { echo "usage: grandma-rehydrate.sh <scope> [--raw]" >&2; exit 2; }

# Use session_id to find the working-state note saved by grandma-precompact.
# PreCompact cannot inject context, so SessionStart carries the note back.
INPUT=""
[[ -t 0 ]] || INPUT="$(cat 2>/dev/null || true)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"

[[ -n "$SID" ]] || exit 0
cnote="$ROOT/.compact/$(printf '%s' "$SID" | tr -cd '[:alnum:]._-').md"
[[ -f "$cnote" ]] || exit 0

# Read from disk so even a large note cannot exceed the shell's argument limit.
python3 - "$cnote" "$RAW" <<'PY' || true
import json, sys

header = "===== SESSION CONTINUITY (restored after compaction) =====\n"
limit = 9000
with open(sys.argv[1], encoding="utf-8") as note:
    ctx = header + note.read(limit + 1)
if len(ctx) > limit:
    marker = "[grandma] Continuity note truncated.\n"
    end = ctx.rfind("\n", len(header), limit - len(marker)) + 1
    if end <= len(header):
        # one long line with nowhere to break: cut it hard rather than drop the whole note
        end = limit - len(marker) - 1
        ctx = ctx[:end] + "\n" + marker
    else:
        ctx = ctx[:end] + marker

if sys.argv[2] == "1":
    print(ctx, end="")
else:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": ctx
        }
    }))
PY
