#!/usr/bin/env bash
#
# grandma-precompact — PreCompact hook: checkpoint the session's working state just before
# Claude Code compacts, so grandma-rehydrate can re-inject it afterward instead of leaving
# it to Claude Code's lossy summary.
#
# grandma injects STANDING memory at launch, and rehydrate restores it after a compaction.
# But the SESSION's own evolving work (the current task, the decisions, what is already done)
# is not in memory yet and is exactly what compaction drops. This hook distills that working
# state into a small transient note keyed by session id; grandma-rehydrate.sh folds it back
# in on the way out (PreCompact itself cannot inject context, only the SessionStart side can).
#
# Args: <scope> [project]  (baked in by the installer)
# Reads the PreCompact hook JSON on stdin: session_id, transcript_path, compaction_trigger.
# ALWAYS exits 0 (never blocks compaction), even on failure or when there is nothing to save.
#
# GRANDMA_DRY_RUN=1 prints the plan and exits without a model call.

set -uo pipefail   # deliberately NOT -e: nothing here may abort in a way that blocks compaction

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"

scope="${1:-}"; project="${2:-}"
[[ -z "$scope" ]] && exit 0
[[ "${GRANDMA_NO_CHECKPOINT:-0}" == "1" ]] && exit 0

# RECURSION GUARD. The checkpoint runs its own headless `claude -p`. If that ever grew long
# enough to compact, it would fire PreCompact again and cascade. We mark the checkpoint's
# environment with GRANDMA_DISTILLING=1 (shared with the distiller) and bail here if we are
# already inside one. A real user session has no such env and proceeds.
[[ "${GRANDMA_DISTILLING:-0}" == "1" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$input"     | jq -r '.session_id // empty' 2>/dev/null || true)"
tpath="$(printf '%s' "$input"   | jq -r '.transcript_path // empty' 2>/dev/null || true)"
trigger="$(printf '%s' "$input" | jq -r '.compaction_trigger // empty' 2>/dev/null || true)"

# No session id -> rehydrate has no key to find the note. No transcript -> nothing to read.
[[ -z "$sid" || -z "$tpath" || ! -f "$tpath" ]] && exit 0

CDIR="$ROOT/.compact"
mkdir -p "$CDIR"
find "$CDIR" -name '*.md'   -mmin +180 -delete 2>/dev/null || true   # prune stale session notes
find "$CDIR" -name '.run.*' -mmin +10  -delete 2>/dev/null || true   # and stale cost-cap markers

# COST CAP (airbag), independent of the recursion guard. Bound how many checkpoints run in a
# short window so a pathological compaction loop cannot rack up model calls. A legit session
# compacts only a handful of times; a cascade trips this in seconds.
CAP="${GRANDMA_CHECKPOINT_CAP:-12}"
recent="$(find "$CDIR" -name '.run.*' -mmin -5 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${recent:-0}" -ge "$CAP" ]]; then
  echo "grandma precompact COST CAP: $recent checkpoints in the last 5 min (cap $CAP). Skipping." >&2
  exit 0
fi

# LOCK (per session, atomic mkdir) so two overlapping compactions cannot double-run.
lock="$CDIR/.lock-$(printf '%s' "$sid" | tr -cd '[:alnum:]._-')"
mkdir "$lock" 2>/dev/null || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

safe_sid="$(printf '%s' "$sid" | tr -cd '[:alnum:]._-')"
note="$CDIR/${safe_sid}.md"
readable="$CDIR/.readable-${safe_sid}.md"

extract_readable_transcript "$tpath" "$readable" 2>/dev/null || { rm -f "$readable"; exit 0; }
[[ -s "$readable" ]] || { rm -f "$readable"; exit 0; }

MODEL="${GRANDMA_CHECKPOINT_MODEL:-haiku}"
SYS="$(cat "$ENGINE/prompts/precompact.md" 2>/dev/null || true)"
PROMPT="Read the readable transcript at $readable and write the continuity note per your instructions."

if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  { echo "mode:        PRECOMPACT checkpoint (trigger=${trigger:-?})"
    echo "scope:       $scope${project:+  project=$project}"
    echo "session:     $sid"
    echo "transcript:  $tpath"
    echo "model:       $MODEL"
    echo "note ->      $note"; } >&2
  rm -f "$readable"
  exit 0
fi

# Run the checkpoint SYNCHRONOUSLY (compaction waits for it, so the note is ready before the
# SessionStart(compact) rehydrate fires). From the grandma repo (a neutral cwd with no
# PreCompact hook of its own) and with the recursion guard set on the child.
out="$( cd "$ROOT" && GRANDMA_DISTILLING=1 claude -p "$PROMPT" --model "$MODEL" --append-system-prompt "$SYS" 2>/dev/null )" || out=""
rm -f "$readable"
: > "$CDIR/.run.$(date +%s).$$" 2>/dev/null || true   # cost-cap marker: one per model call

# Nothing meaningful -> leave no note, so rehydrate has nothing to inject (which is correct).
if [[ -z "$out" ]] || printf '%s' "$out" | grep -qiF 'no active task state'; then
  rm -f "$note" 2>/dev/null || true
  exit 0
fi

{ printf '== working state, captured before compaction (%s) ==\n' "${trigger:-compaction}"
  printf '%s\n' "$out"
} > "$note"
exit 0
