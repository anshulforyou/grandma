#!/usr/bin/env bash
#
# grandma-save — the distiller (session -> memory write path).
#
# Reads a finished Claude Code session transcript and distills durable learnings
# into grandma memory. Two modes:
#   interactive (default): launch a distiller session that proposes edits, gets
#     your approval, applies them, and commits.
#   --auto: run headless, write a proposal file to grandma/proposals/ and exit.
#     Applies nothing, commits nothing. Used by the SessionEnd hook.
#
# Usage:
#   grandma-save <sweater> [project] [--transcript <path>] [--auto]
#
#   <scope>              scope the session belonged to (e.g. acme, writing)
#   [project]            optional project (single bare word); routes learnings to
#                        that project's CLAUDE.md as well as scope/global memory,
#                        and looks for the transcript in the project's folder.
#   --transcript <path>  use a specific transcript .jsonl (default: latest for the
#                        project folder if given, else the current dir)
#   --auto               headless propose-only (no session, no apply, no commit)
#
# GRANDMA_DRY_RUN=1 prints what it found and would launch, without starting Claude.

set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"
ASSEMBLE="$ENGINE/lib/assemble.sh"
DISTILLER="$ENGINE/prompts/distiller.md"

SCOPE=""
PROJECT=""
TRANSCRIPT=""
AUTO=0
NEXT_IS_TRANSCRIPT=0
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=1 ;;
    --last) ;;
    --transcript) NEXT_IS_TRANSCRIPT=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *)
      if [[ "$NEXT_IS_TRANSCRIPT" == "1" ]]; then TRANSCRIPT="$arg"; NEXT_IS_TRANSCRIPT=0
      elif [[ -z "$SCOPE" ]]; then SCOPE="$arg"
      elif [[ -z "$PROJECT" && "$arg" != *" "* ]]; then PROJECT="$arg"
      fi ;;
  esac
done

if [[ -z "$SCOPE" ]]; then
  echo "usage: grandma-save <sweater> [project] [--transcript <path>] [--auto]" >&2
  exit 2
fi

# ---- resolve project (optional) ----
SCOPE_DIR=""
PROJECT_DIR=""
PROJECT_NAME=""
if [[ -n "$PROJECT" ]]; then
  SCOPE_DIR="$(resolve_scope_dir "$SCOPE" || true)"
  [[ -z "$SCOPE_DIR" ]] && { echo "error: unknown scope '$SCOPE'" >&2; exit 1; }
  resolve_project "$SCOPE_DIR" "$PROJECT"
  case "$RP_STATUS" in
    OK)    PROJECT_DIR="$RP_DIR"; PROJECT_NAME="$RP_NAME" ;;
    AMBIG) echo "'$PROJECT' matches multiple in $SCOPE: $RP_CANDS. Be specific." >&2; exit 2 ;;
    NONE)  echo "error: project '$PROJECT' not found in $SCOPE (onboard it first with: grandma $SCOPE $PROJECT)" >&2; exit 1 ;;
  esac
fi

# ---- locate transcript ----
if [[ -z "$TRANSCRIPT" ]]; then
  if [[ -n "$PROJECT_DIR" ]]; then proj_dir="$(claude_proj_dir "$PROJECT_DIR")"
  else proj_dir="$(claude_proj_dir "$PWD")"; fi
  if [[ ! -d "$proj_dir" ]]; then
    echo "error: no Claude project dir ($proj_dir). Pass --transcript." >&2
    exit 1
  fi
  TRANSCRIPT="$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  echo "error: no transcript found. Pass --transcript <path>." >&2
  exit 1
fi

# ---- extract a readable transcript (drop tool noise, keep text turns) ----
# Write it INSIDE the grandma repo (.distill/), not system temp: the headless distiller
# runs claude -p from the grandma repo (neutral cwd, no SessionEnd hook) and is sandboxed
# to that dir, so a /var/folders temp file would be unreadable. Prune stale ones first.
mkdir -p "$ROOT/.distill"
find "$ROOT/.distill" -name '*.md' -mmin +120 -delete 2>/dev/null || true
readable="$ROOT/.distill/$(basename "$TRANSCRIPT" .jsonl).md"
extract_readable_transcript "$TRANSCRIPT" "$readable"
lines=$(wc -l < "$readable" | tr -d ' ')

# ---- assemble current memory context (scope, plus the project CLAUDE.md if any) ----
MEMORY="$("$ASSEMBLE" "$SCOPE" --full 2>/dev/null || true)"
if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/CLAUDE.md" ]]; then
  MEMORY="$MEMORY

===== PROJECT CLAUDE.md ($PROJECT_NAME) =====
$(cat "$PROJECT_DIR/CLAUDE.md")"
fi

ROUTING="Route each learning to the RIGHT layer:
- Something about THIS project (a lesson, a gotcha, feedback, a how-to) -> the project's CLAUDE.md at $PROJECT_DIR/CLAUDE.md.
- Something about how the user works in this whole scope -> $SCOPE_DIR/*.md.
- Something universal about the user or how they work everywhere -> global/*.md.
- Follow any sweater-specific routing/feedback conventions described in the loaded sweater memory."
[[ -z "$PROJECT_DIR" ]] && ROUTING="Route sweater-specific learnings to the sweater's files, universal ones to global/*.md."

# ============================ AUTO (headless propose-only) ============================
if [[ "$AUTO" == "1" ]]; then
  # CIRCUIT BREAKER (airbag). Independent of the recursion guard: if an abnormal number of
  # proposals appeared very recently, a runaway is in progress — refuse to add more. This
  # bounds any future distill bug to at most CAP files instead of thousands. Legit use never
  # exits CAP sessions inside the window; a cascade trips it in seconds.
  mkdir -p "$ROOT/proposals"
  CAP="${GRANDMA_AUTOSAVE_CAP:-10}"
  recent="$(find "$ROOT/proposals" -name '*.md' -mmin -5 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${recent:-0}" -ge "$CAP" ]]; then
    echo "grandma auto-distill CIRCUIT BREAKER: $recent proposals in the last 5 min (cap $CAP). Refusing (likely runaway)." >&2
    exit 0
  fi
  stamp="$(basename "$TRANSCRIPT" .jsonl)"
  out="$ROOT/proposals/${SCOPE}${PROJECT_NAME:+-$PROJECT_NAME}-${stamp}.md"
  ASYS="$(cat "$DISTILLER")

$(cat "$ENGINE/prompts/capture.md")

===== CURRENT MEMORY (scope=$SCOPE${PROJECT_NAME:+, project=$PROJECT_NAME}) =====
$MEMORY"
  APROMPT="Read the readable transcript at $readable. Following your distiller instructions,
propose 0-5 atomic memory edits, but DO NOT apply or commit anything. $ROUTING
Output ONLY a concise proposal: for each edit give target file, action, exact text, and a
one-line why. If nothing is durable, output exactly 'No durable learnings.'"

  if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
    { echo "mode:        AUTO (headless propose-only)"
      echo "scope:       $SCOPE${PROJECT_NAME:+  project=$PROJECT_NAME}"
      echo "transcript:  $TRANSCRIPT ($lines lines)"
      echo "proposal ->  $out"; } >&2
    exit 0
  fi

  # Headless distill; write proposal file. Never touches memory.
  # Run claude -p from a NEUTRAL dir (grandma repo, which has no SessionEnd hook) and with
  # the recursion guard set, so this headless session cannot fire a project SessionEnd hook
  # and cascade into another distill. Two independent safeguards against the runaway loop.
  { echo "# grandma memory proposal"
    echo "# scope=$SCOPE${PROJECT_NAME:+ project=$PROJECT_NAME}  transcript=$(basename "$TRANSCRIPT")"
    echo
    ( cd "$ROOT" && GRANDMA_DISTILLING=1 claude -p "$APROMPT" --append-system-prompt "$ASYS" 2>/dev/null ) || echo "(distiller failed)"
  } > "$out"
  rm -f "$readable"
  # Keep the proposal only if the distiller actually proposed something. A "No durable
  # learnings" result (the model often adds justification prose, so match the phrase anywhere),
  # a failed distill, or a header-only file must NOT linger or ping the user for review later.
  # claude -p can also crash with exit 0, printing "Execution error" as its whole output, so
  # the nonzero-exit marker never lands; match that as a full line (a real proposal could
  # legitimately quote the phrase mid-sentence).
  if grep -qiF 'no durable learnings' "$out" \
     || grep -qF '(distiller failed)' "$out" \
     || grep -qxF 'Execution error' "$out" \
     || ! grep -qvE '^#|^[[:space:]]*$' "$out"; then
    rm -f "$out"
  else
    echo "$out"
  fi
  exit 0
fi

# ============================ INTERACTIVE (default) ============================
SYSPROMPT="$(cat "$DISTILLER")

$(cat "$ENGINE/prompts/capture.md")

===== CURRENT MEMORY (scope=$SCOPE${PROJECT_NAME:+, project=$PROJECT_NAME}) =====
$MEMORY"

INIT="Distill the work session for scope '$SCOPE'${PROJECT_NAME:+, project '$PROJECT_NAME'}. The readable transcript is at:
$readable

$ROUTING

Read it, then follow your distiller instructions: propose 0-5 atomic memory edits,
get my approval, apply them, and commit. Be conservative."

ADD_DIR=()
[[ -n "$PROJECT_DIR" ]] && ADD_DIR=(--add-dir "$PROJECT_DIR")

if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  { echo "mode:        INTERACTIVE"
    echo "scope:       $SCOPE${PROJECT_NAME:+  project=$PROJECT_NAME}"
    echo "transcript:  $TRANSCRIPT ($lines lines)"
    [[ -n "$PROJECT_DIR" ]] && echo "add-dir:     $PROJECT_DIR (can edit its CLAUDE.md)"
    echo "would launch: (cd $ROOT && claude --name distill:$SCOPE${PROJECT_NAME:+/$PROJECT_NAME} ${ADD_DIR[*]:-} --append-system-prompt <distiller+memory> <init>)"; } >&2
  exit 0
fi

cd "$ROOT"
exec claude --name "distill:$SCOPE${PROJECT_NAME:+/$PROJECT_NAME}" ${ADD_DIR[@]+"${ADD_DIR[@]}"} --append-system-prompt "$SYSPROMPT" "$INIT"
