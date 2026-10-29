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

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
safe_sid="$(printf '%s' "$SID" | tr -cd '[:alnum:]._-')"
cnote="$ROOT/.compact/$safe_sid.md"
count="$(cat "$ROOT/.compact/$safe_sid.count" 2>/dev/null || echo 0)"
tpath="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
cwd="${GRANDMA_LAUNCH_DIR:-${cwd:-$PWD}}"   # the folder grandma launched in, where the next launch looks
# shellcheck source=grandma-lib.sh
source "$ENGINE/lib/grandma-lib.sh"
handoff="$(handoff_path "$ROOT" "$SCOPE" "$cwd")"
relaunch="grandma $SCOPE${GRANDMA_PROJECT:+ $GRANDMA_PROJECT}"

# Read from disk so even a large note cannot exceed the shell's argument limit.
python3 - "$cnote" "$RAW" "$count" "$tpath" "$handoff" "$relaunch" "$cwd" \
  "${GRANDMA_FRESH_AFTER_COMPACTIONS:-3}" "${GRANDMA_FRESH_AFTER_HOURS:-24}" <<'PY' || true
import json, os, sys, time
from datetime import datetime

cnote, raw, count, tpath, handoff, relaunch, cwd, max_count, max_hours = sys.argv[1:10]
count, max_count, max_hours = int(count or 0), int(max_count), float(max_hours)

def started(path):
    # the first timestamp in the transcript is when the session began
    try:
        with open(path, encoding="utf-8", errors="ignore") as t:
            for line in t:
                if '"timestamp"' in line:
                    ts = json.loads(line).get("timestamp")
                    if ts:
                        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (OSError, ValueError):
        pass
    return None

limit = 9000
ctx = ""
if os.path.isfile(cnote):
    header = "===== SESSION CONTINUITY (restored after compaction) =====\n"
    with open(cnote, encoding="utf-8") as note:
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

# A session that has compacted a few times, or run for a day, loses a little more at each
# compaction. Ask it to hand over to a fresh one at the next clean stopping point.
begun = started(tpath) if tpath else None
hours = (time.time() - begun) / 3600 if begun else 0
if count >= max_count or hours >= max_hours:
    age = " and ".join(x for x in (f"{count} compactions" if count else "", f"{hours:.0f} hours" if hours >= 1 else "") if x)
    ctx += f"""
===== TIME FOR A FRESH SESSION =====
This session has run {age}. Every compaction loses detail, and long sessions are where the
user's corrections pile up. At the next clean stopping point (the current step finished and
verified, nothing half done), do this without asking:
1. Write a handoff note to {handoff} (under 400 words): the task, decisions and why, what is
   done, what is open and the next step, and every lesson and correction from this session.
   Also put any lesson that will matter beyond this task in memory now.
2. Open the fresh session in a new iTerm tab: osascript -e 'tell application "iTerm2" to tell current window to create tab with default profile' -e 'tell application "iTerm2" to tell current session of current window to write text "cd {cwd} && {relaunch}"'
   It picks up the handoff note on its own.
3. Tell the user in one line that the work continues in the new tab and this one can be closed.
"""

if not ctx:
    sys.exit(0)
if raw == "1":
    print(ctx, end="")
else:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": ctx
        }
    }))
PY
