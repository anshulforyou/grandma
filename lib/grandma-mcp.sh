#!/usr/bin/env bash
# grandma-mcp.sh — bind MCP servers to a sweater.
#
#   grandma mcp                              what every sweater binds
#   grandma mcp list [<sweater>]             what a sweater actually gets, global included
#   grandma mcp add <sweater> <name> <url>   bind a server to that sweater
#   grandma mcp add global <name> <url>      bind it to every sweater
#   grandma mcp remove <sweater> <name>      unbind
#
# Servers are stored as <sweater>/mcp.json in the memory home, in the CLI's own shape, so the
# file stays hand-editable and a definition can still be pasted from a vendor's docs.
#
# NO SECRET IS EVER WRITTEN HERE. A memory home is a git repo the user may push, so a header
# or environment value must be a reference like $TOKEN, never the token. An OAuth server needs
# only its address: the login lives in the CLI's own credential store, outside memory.
set -euo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
source "$ENGINE/lib/grandma-lib.sh"

die() { printf '  %s\n' "$*" >&2; exit 1; }
need_jq() { command -v jq >/dev/null 2>&1 || die "this needs jq. brew install jq (or apt install jq)"; }

# target_dir <name> — the folder whose mcp.json we edit. 'global' is a legal target.
target_dir() {
  local t="$1"
  if [[ "$t" == "global" ]]; then printf '%s/global' "$ROOT"; return 0; fi
  local d; d="$(resolve_scope_dir "$t" 2>/dev/null || true)"
  [[ -n "$d" ]] || die "no sweater '$t'. run grandma with no arguments to see or knit one."
  printf '%s' "$d"
}

# reject_secret <flag> <value> — a literal credential must not enter a file that gets committed.
reject_secret() {
  case "$2" in
    *'$'*) return 0 ;;   # an environment reference is what we want
  esac
  die "$1 looks like a literal value. Put the secret in an environment variable and reference it,
     for example: $1 'Authorization: Bearer \$MY_TOKEN'
     Memory is a git repo you may push, so grandma will not write a credential into it."
}

cmd_add() {
  need_jq
  local target="${1:-}" name="${2:-}" url="" transport="http"; shift 2 2>/dev/null || true
  local -a hdr=() envv=() cmdargs=()
  [[ -n "$target" && -n "$name" ]] || die "usage: grandma mcp add <sweater|global> <name> <url>"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--transport) transport="$2"; shift 2 ;;
      -H|--header) reject_secret "--header" "$2"; hdr+=("$2"); shift 2 ;;
      -e|--env) reject_secret "--env" "$2"; envv+=("$2"); shift 2 ;;
      --) shift; cmdargs=("$@"); transport="stdio"; break ;;
      -*) die "unknown option: $1" ;;
      *) url="$1"; shift ;;
    esac
  done
  local dir; dir="$(target_dir "$target")"
  mkdir -p "$dir"
  local f="$dir/mcp.json"
  [[ -f "$f" ]] || printf '{"mcpServers":{}}\n' > "$f"
  jq -e . "$f" >/dev/null 2>&1 || die "$f is not valid JSON. fix or delete it, then retry."

  local entry
  case "$transport" in
    http|sse)
      [[ -n "$url" ]] || die "give the server's address: grandma mcp add $target $name <url>"
      entry="$(jq -n --arg t "$transport" --arg u "$url" '{type:$t, url:$u}')"
      if [[ ${#hdr[@]} -gt 0 ]]; then
        entry="$(printf '%s\n' "${hdr[@]}" | jq -R 'split(": ") | {(.[0]): (.[1:]|join(": "))}' \
          | jq -s --argjson e "$entry" 'add as $h | $e + {headers:$h}')"
      fi ;;
    stdio)
      [[ ${#cmdargs[@]} -gt 0 ]] || die "for a local server, put the command after --: grandma mcp add $target $name -- npx thing"
      entry="$(jq -n --arg c "${cmdargs[0]}" --args '{type:"stdio", command:$c, args:$ARGS.positional}' \
                 "${cmdargs[@]:1}" 2>/dev/null || jq -n --arg c "${cmdargs[0]}" '{type:"stdio", command:$c, args:[]}')"
      if [[ ${#envv[@]} -gt 0 ]]; then
        entry="$(printf '%s\n' "${envv[@]}" | jq -R 'split("=") | {(.[0]): (.[1:]|join("="))}' \
          | jq -s --argjson e "$entry" 'add as $v | $e + {env:$v}')"
      fi ;;
    *) die "transport must be http, sse or stdio" ;;
  esac

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/grandma-mcpadd.XXXXXX")"
  jq --arg n "$name" --argjson e "$entry" '.mcpServers[$n] = $e' "$f" > "$tmp" && mv "$tmp" "$f"
  if [[ "$target" == "global" ]]; then
    printf '\n  bound %s for every sweater.\n' "$name" >&2
    printf '  it keeps that name, so one login covers all of them.\n\n' >&2
  else
    printf '\n  bound %s to %s. every project in that sweater gets it, nothing else does.\n' "$name" "$target" >&2
    printf '  it loads as %s__%s, which is what gives it a login of its own.\n\n' "$target" "$name" >&2
    printf '  next:  grandma %s        then /mcp in the session to sign in the first time\n\n' "$target" >&2
  fi
}

cmd_remove() {
  need_jq
  local target="${1:-}" name="${2:-}"
  [[ -n "$target" && -n "$name" ]] || die "usage: grandma mcp remove <sweater|global> <name>"
  local dir f; dir="$(target_dir "$target")"; f="$dir/mcp.json"
  [[ -f "$f" ]] || die "$target has no MCP servers bound."
  jq -e --arg n "$name" '.mcpServers | has($n)' "$f" >/dev/null 2>&1 \
    || die "$target has no server called '$name'. see: grandma mcp list $target"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/grandma-mcprm.XXXXXX")"
  jq --arg n "$name" 'del(.mcpServers[$n])' "$f" > "$tmp" && mv "$tmp" "$f"
  # leave no empty file behind pretending something is bound
  [[ "$(jq -r '.mcpServers | length' "$f")" == "0" ]] && rm -f "$f"
  printf '  unbound %s from %s.\n' "$name" "$target" >&2
}

# one sweater: what it actually gets, which is the composed set, not just its own file
show_scope() {
  local scope="$1" tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/grandma-mcpls.XXXXXX")"
  rc=0; mcp_compose "$ROOT" "$scope" "$tmp" || rc=$?
  if [[ "$rc" == "0" ]]; then
    printf '  %s\n' "$scope"
    jq -r '.mcpServers | to_entries[] | "      \(.key)  \(.value.url // .value.command // "")"' "$tmp"
  elif [[ "$rc" == "2" ]]; then
    printf '  %s   (its mcp.json could not be read)\n' "$scope"
  else
    printf '  %s   (nothing bound)\n' "$scope"
  fi
  rm -f "$tmp"
}

cmd_list() {
  need_jq
  local only="${1:-}"
  if [[ -n "$only" ]]; then
    [[ "$only" == "global" ]] || target_dir "$only" >/dev/null
    printf '\n  what a %s session gets, global servers included:\n\n' "$only" >&2
    show_scope "$only"; printf '\n'
    return 0
  fi
  printf '\n  MCP servers by sweater (a sweater with nothing bound is left out):\n\n' >&2
  if [[ -f "$ROOT/global/mcp.json" ]]; then
    printf '  global (every sweater)\n'
    jq -r '.mcpServers | to_entries[] | "      \(.key)  \(.value.url // .value.command // "")"' "$ROOT/global/mcp.json" 2>/dev/null
  fi
  local s
  while IFS= read -r s; do
    [[ -f "$(resolve_scope_dir "$s" 2>/dev/null || echo /nonexistent)/mcp.json" ]] || continue
    show_scope "$s"
  done < <(list_scopes 2>/dev/null || true)
  printf '\n'
}

case "${1:-list}" in
  add)    shift; cmd_add "$@" ;;
  remove|rm) shift; cmd_remove "$@" ;;
  list|"") shift 2>/dev/null || true; cmd_list "$@" ;;
  -h|--help|help) sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: grandma mcp <list|add|remove>" ;;
esac
