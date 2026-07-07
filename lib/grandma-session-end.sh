#!/usr/bin/env bash
#
# grandma-session-end — SessionEnd hook entrypoint.
#
# Installed (async) in grandma-launched projects. When a session ends, it headless-
# distills the transcript into a grandma memory PROPOSAL file (applies nothing,
# commits nothing). You review proposals later with `grandma-review`.
#
# Args: <scope> [project]   (baked in by the installer)
# Reads the hook JSON on stdin to get transcript_path and reason.

set -euo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home

scope="${1:-}"; project="${2:-}"
[[ -z "$scope" ]] && exit 0

# RECURSION GUARD. The distill itself runs a headless `claude -p`, which is its own
# Claude Code session and fires SessionEnd when it finishes. Without this guard that
# re-triggers the distill -> infinite cascade (thousands of runaway processes). We mark
# the distill's environment with GRANDMA_DISTILLING=1; any SessionEnd fired from inside
# a distill sees it and bails. Only a real user session (no such env) proceeds.
[[ "${GRANDMA_DISTILLING:-0}" == "1" ]] && exit 0

input="$(cat 2>/dev/null || true)"
reason="$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null || true)"
tpath="$(printf '%s' "$input"  | jq -r '.transcript_path // empty' 2>/dev/null || true)"

# Only distill on a real session end. Skip /clear and resume (session continues).
case "$reason" in
  clear|resume) exit 0 ;;
esac

args=("$scope"); [[ -n "$project" ]] && args+=("$project")
[[ -n "$tpath" ]] && args+=(--transcript "$tpath")

# Fully DETACH the distill so it survives the session exit (Claude Code kills the hook's
# own process tree on shutdown, issue #41577). Export GRANDMA_DISTILLING=1 so the distill's
# own claude -p, and the SessionEnd it fires on completion, inherit it and bail (see guard).
GRANDMA_DISTILLING=1 nohup "$ENGINE/lib/grandma-save.sh" "${args[@]}" --auto >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
