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


# deposit_secret <full-name> <url> <client-id> — some providers want a client secret at the
# token exchange. A sweater's config carries a client ID but has no field for a secret: the CLI
# looks that up in its OWN credential store, keyed by server name plus a hash of the config, and
# only `claude mcp add --client-secret` writes there. So grandma asks for the secret and hands it
# straight to that command. It holds it for the length of one call and stores nothing itself.
deposit_secret() {
  local full="$1" url="$2" cid="$3" sec out
  sec="$(read_secret "  Client secret for ${full} (hidden, Enter to skip): ")"
  [[ -n "$sec" ]] || { printf '  Skipped. Sign-in will fail until it is set.\n\n' >&2; return 1; }
  if out="$(MCP_CLIENT_SECRET="$sec" claude mcp add --scope user --transport http \
            "$full" "$url" --client-id "$cid" --client-secret 2>&1)"; then
    printf '  %sdone%s. the secret is held by claude, not by grandma.\n\n' "$C_KEY" "$C_RESET" >&2
    return 0
  fi
  printf '  that did not take:\n%s\n\n' "$out" >&2
  return 1
}

# secret_is_wanted <url> — providers that refuse to complete a sign-in without one.
secret_is_wanted() {
  case "$1" in *googleapis.com*|*google.com*) return 0 ;; esac
  return 1
}

cmd_add() {
  need_jq
  local target="${1:-}" name="${2:-}" url="" transport="http"; shift 2 2>/dev/null || true
  local -a hdr=() envv=() cmdargs=()
  local client_id="" callback_port=""
  [[ -n "$target" && -n "$name" ]] || die "usage: grandma mcp add <sweater|global> <name> <url>"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--transport) transport="$2"; shift 2 ;;
      -H|--header) reject_secret "--header" "$2"; hdr+=("$2"); shift 2 ;;
      --client-id) client_id="$2"; shift 2 ;;
      --callback-port) callback_port="$2"; shift 2 ;;
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
      # Some providers refuse dynamic client registration, so the CLI cannot introduce itself and
      # sign-in dies before any consent screen. For those you bring your own OAuth client. Only the
      # client ID and the callback port are stored: an ID is public, and the SECRET never lands in
      # a file, it is read from MCP_CLIENT_SECRET at sign-in time.
      if [[ -n "$client_id" || -n "$callback_port" ]]; then
        [[ -n "$client_id" ]] || die "--callback-port needs --client-id as well."
        local oauth; oauth="$(jq -n --arg i "$client_id" '{clientId:$i}')"
        if [[ -n "$callback_port" ]]; then
          [[ "$callback_port" =~ ^[0-9]+$ ]] || die "--callback-port must be a number."
          oauth="$(jq -n --argjson o "$oauth" --argjson p "$callback_port" '$o + {callbackPort:$p}')"
        fi
        entry="$(jq -n --argjson e "$entry" --argjson o "$oauth" '$e + {oauth:$o}')"
      fi
      if [[ ${#hdr[@]} -gt 0 ]]; then
        entry="$(printf '%s\n' "${hdr[@]}" | jq -R 'split(": ") | {(.[0]): (.[1:]|join(": "))}' \
          | jq -s --argjson e "$entry" 'add as $h | $e + {headers:$h}')"
      fi ;;
    stdio)
      [[ ${#cmdargs[@]} -gt 0 ]] || die "for a local server, put the command after --: grandma mcp add $target $name -- npx thing"
      # Build the args array through stdin, not as jq operands. `jq --args` reads anything
      # starting with a dash as one of its OWN options, so `-- npx -y pkg --flag` made jq fail
      # and the fallback wrote an empty array, dropping the flags without a word.
      local args_json='[]'
      if [[ ${#cmdargs[@]} -gt 1 ]]; then
        args_json="$(printf '%s\n' "${cmdargs[@]:1}" | jq -R . | jq -s .)"
      fi
      entry="$(jq -n --arg c "${cmdargs[0]}" --argjson a "$args_json" '{type:"stdio", command:$c, args:$a}')"
      if [[ ${#envv[@]} -gt 0 ]]; then
        entry="$(printf '%s\n' "${envv[@]}" | jq -R 'split("=") | {(.[0]): (.[1:]|join("="))}' \
          | jq -s --argjson e "$entry" 'add as $v | $e + {env:$v}')"
      fi ;;
    *) die "transport must be http, sse or stdio" ;;
  esac

  # Binding anything to a sweater switches that sweater to strict isolation, which also shuts out
  # the account connectors it used to get for free. That is the point of the feature, but it is
  # invisible, so say it once, on the binding that causes it.
  local first_binding=0
  [[ "$(jq -r '.mcpServers | length' "$f" 2>/dev/null || echo 0)" == "0" && "$target" != "global" ]] && first_binding=1

  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/grandma-mcpadd.XXXXXX")"
  jq --arg n "$name" --argjson e "$entry" '.mcpServers[$n] = $e' "$f" > "$tmp" && mv "$tmp" "$f"


  if [[ "$target" == "global" ]]; then
    printf '\n  bound %s for every sweater.\n' "$name" >&2
    printf '  it keeps that name, so one login covers all of them.\n\n' >&2
  else
    printf '\n  bound %s to %s. every project in that sweater gets it, nothing else does.\n' "$name" "$target" >&2
    printf '  it loads as %s__%s, which is what gives it a login of its own.\n\n' "$target" "$name" >&2
    [[ "$first_binding" == "1" ]] && \
      printf '\n  %snote%s: this is the first server bound to %s, so from now on %s sessions see only\n        the servers bound here. Your account connectors (Gmail, Drive, Calendar) are not\n        among them. Put anything you want everywhere under: grandma mcp add global ...\n' "$C_WARN" "$C_RESET" "$target" "$target" >&2
    # This provider will not finish a sign-in without a client secret, so offer to set it now
    # rather than leave the reader a command to carry out.
    if secret_is_wanted "$url"; then
      local _full="${target}__${name}"
      if [[ -n "$client_id" && -t 0 ]]; then
        printf '\n  %s needs a client secret once before it can sign in.\n' "$name" >&2
        deposit_secret "$_full" "$url" "$client_id" || true
      elif [[ -z "$client_id" ]]; then
        printf '\n  %s needs an OAuth client of your own before it can sign in.\n' "$name" >&2
        printf '  Make one at https://console.cloud.google.com/apis/credentials, then:\n' >&2
        printf '    grandma mcp add %s %s %s --client-id <id>\n\n' "$target" "$name" "$url" >&2
      else
        printf '\n  %s also needs its client secret deposited once:\n' "$name" >&2
        printf '    claude mcp add --scope user --transport http %s %s --client-id %s --client-secret\n\n' "$_full" "$url" "$client_id" >&2
      fi
    fi
    printf '\n  next:  grandma %s        then /mcp in the session to sign in the first time\n' "$target" >&2
    # A client of your own also means a secret, and the secret is the one thing grandma will not
    # keep. Take it here, hand it to the session that needs it, and let it go when that exits.
    if [[ -n "$client_id" && -t 0 ]]; then
      local go sec
      printf '\n  Sign in now? [Y/n] ' >&2
      IFS= read -r go || true
      if [[ "${go:-y}" =~ ^[Yy]?$ ]]; then
        sec="$(read_secret '  Client secret (hidden, never stored): ')"
        if [[ -n "$sec" ]]; then
          printf '  starting %s. run /mcp, then Authenticate on %s__%s\n\n' "$target" "$target" "$name" >&2
          MCP_CLIENT_SECRET="$sec" exec "$ENGINE/bin/grandma" "$target"
        fi
      fi
    fi
    printf '\n' >&2
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
