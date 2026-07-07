#!/usr/bin/env bash
#
# grandma-ingest — learn all the projects in a master folder.
#
# Scans a folder's subfolders for CLAUDE.md files and ingests them into grandma as
# a compact project catalog (<Scope>/projects.md) for a scope. Run it inside (or
# point --root at) a master folder of projects, and grandma
# learns the projects so you can start using them.
#
# Usage:
#   grandma-ingest [scope] [--root <dir>] [--depth N]
#
#   scope      grandma scope to populate (default: basename of the scan folder, lowercased)
#   --root     folder to scan (default: current directory)
#   --depth    how deep under each subfolder to look for CLAUDE.md (default: 2)
#
# It finds each subfolder's CLAUDE.md, then launches a Claude session in the grandma
# repo that distills each into the catalog. Review the diff, then commit yourself.
#
# GRANDMA_DRY_RUN=1 lists what it found and would launch, without starting Claude.

set -euo pipefail

GRANDMA_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
INGEST_PROMPT="$ENGINE/prompts/ingest.md"
ASSEMBLE="$ENGINE/lib/assemble.sh"

SCAN_ROOT="$PWD"
SCOPE=""
DEPTH=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)  SCAN_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --depth) DEPTH="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  if [[ -z "$SCOPE" ]]; then SCOPE="$1"; fi; shift ;;
  esac
done
[[ -z "$SCOPE" ]] && SCOPE="$(basename "$SCAN_ROOT" | tr '[:upper:]' '[:lower:]')"

# ---- find CLAUDE.md in each immediate subfolder (shallowest wins) ----
ENTRIES=()   # "project|path"
for child in "$SCAN_ROOT"/*/; do
  [[ -d "$child" ]] || continue
  proj="$(basename "$child")"
  cmd="$(find "$child" -maxdepth "$DEPTH" -iname 'CLAUDE.md' 2>/dev/null | sort | head -n1 || true)"
  [[ -n "$cmd" ]] && ENTRIES+=("$proj|$cmd")
done

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "no CLAUDE.md found under $SCAN_ROOT (depth $DEPTH). nothing to ingest." >&2
  exit 0
fi

# ---- resolve grandma scope dir (case-insensitive), or mark as new ----
SCOPE_DIR=""
for d in "$GRANDMA_ROOT"/*/; do
  name="$(basename "$d")"; [[ "$name" == "global" ]] && continue
  if [[ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$SCOPE" | tr '[:upper:]' '[:lower:]')" ]]; then
    SCOPE_DIR="${d%/}"; break
  fi
done
NEW_SCOPE=0
if [[ -z "$SCOPE_DIR" ]]; then SCOPE_DIR="$GRANDMA_ROOT/$SCOPE"; NEW_SCOPE=1; fi

# ---- build the project list block for the prompt ----
LIST=""
for e in "${ENTRIES[@]}"; do
  LIST+="- ${e%%|*} -> ${e#*|}"$'\n'
done

if [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; then
  {
    echo "scope:       $SCOPE  (new=$NEW_SCOPE)"
    echo "scan root:   $SCAN_ROOT"
    echo "scope dir:   $SCOPE_DIR"
    echo "found ${#ENTRIES[@]} project CLAUDE.md files:"
    printf '%s' "$LIST" | sed 's/^/  /'
    echo "would launch: (cd $GRANDMA_ROOT && claude --name ingest:$SCOPE --add-dir $SCAN_ROOT --append-system-prompt <ingest+memory> \"<init>\")"
  } >&2
  exit 0
fi

SYSPROMPT="$(cat "$INGEST_PROMPT")

===== CURRENT MEMORY (scope=$SCOPE) =====
$("$ASSEMBLE" "$SCOPE" --full 2>/dev/null || echo '(scope not yet created)')"

INIT="Ingest these project CLAUDE.md files into the '$SCOPE' scope. Each line is 'project -> absolute path':

$LIST
Write/update the catalog at $(basename "$SCOPE_DIR")/projects.md per your instructions. Do not commit; I will review the diff."

mkdir -p "$SCOPE_DIR"

# Launch the ingest session in the grandma repo, with the scanned folder readable.
cd "$GRANDMA_ROOT"
exec claude --name "ingest:$SCOPE" --add-dir "$SCAN_ROOT" --append-system-prompt "$SYSPROMPT" "$INIT"
