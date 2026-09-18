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

GOOGLE_CONSOLE_URL="https://console.cloud.google.com/apis/credentials"

# google_needs_own_client <url> — true for a provider that will not let the CLI register itself.
google_needs_own_client() {
  case "$1" in *googleapis.com*|*google.com*) return 0 ;; esac
  return 1
}

# guided_google_setup <target> <name> <url> — walk someone through making the one thing Google
# insists on. Returns the client ID on stdout, empty if they backed out.
#
# Interactive only. A scripted `mcp add` must never block on a prompt, so the caller checks the
# terminal first and falls back to printing what to do.
guided_google_setup() {
  local target="$1" name="$2" ans cid
  {
    printf '\n  Google will not let the CLI introduce itself, so a sign-in would fail before you ever\n'
    printf '  see a consent screen. Every other provider handles that automatically. Google does not.\n\n'
    printf '  What that means: to keep a separate %s inbox per sweater, you make one set of\n' "$name"
    printf '  credentials once, on this machine. It covers every sweater from then on, and each\n'
    printf '  sweater still signs in to its own account.\n\n'
    printf '  Press Enter to open the Google page, or s to skip and do it later: '
  } >&2
  IFS= read -r ans || true
  case "$ans" in [Ss]*) printf ''; return 1 ;; esac

  if open_url "$GOOGLE_CONSOLE_URL"; then
    printf '\n  Opened %s\n' "$GOOGLE_CONSOLE_URL" >&2
  else
    printf '\n  Open this page: %s\n' "$GOOGLE_CONSOLE_URL" >&2
  fi
  {
    printf '\n  On that page:\n'
    printf '    1. Create credentials  ->  OAuth client ID\n'
    printf '    2. Application type:   Desktop app      <- this exact type matters\n'
    printf '    3. Name it anything, then Create\n'
    printf '    4. Copy the client ID and the client secret it shows you\n\n'
    printf '  Desktop app is the part to get right. That type accepts any local port, so there is\n'
    printf '  no redirect address to fill in anywhere.\n\n'
    printf '  On the consent screen, the audience setting decides whether this keeps working:\n'
    printf '    - a Google Workspace account on your own domain: choose Internal. Nothing to verify,\n'
    printf '      and the sign-in lasts.\n'
    printf '    - a personal account: choose External and add yourself under Test users, or Google\n'
    printf '      blocks the sign-in outright. Note that this expires after 7 days and you will\n'
    printf '      have to sign in again, because Google does that to unverified apps.\n\n'
    printf '  An Internal client only admits accounts on THAT domain. A second account on a\n'
    printf '  different domain needs its own client, made inside that organisation. grandma keeps\n'
    printf '  a client per sweater, so that is the shape it expects:\n'
    printf '    grandma mcp add <other-sweater> %s <url> --client-id <client-from-that-domain>\n\n' "$name"
    printf '  Client ID (paste, or Enter to stop): '
  } >&2
  IFS= read -r cid || true
  [[ -n "$cid" ]] || { printf ''; return 1; }
  case "$cid" in
    *.apps.googleusercontent.com) ;;
    *) printf '\n  That does not look like a Google client ID. They end in .apps.googleusercontent.com\n' >&2
       printf ''; return 1 ;;
  esac
  printf '%s' "$cid"
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
  # A provider that refuses dynamic registration needs a client of your own. Rather than tell
  # someone to go and read about OAuth, walk them through it and open the page.
  if [[ -z "$client_id" ]] && google_needs_own_client "$url"; then
    if [[ -t 0 ]]; then
      client_id="$(guided_google_setup "$target" "$name" "$url" || true)"
    fi
    if [[ -z "$client_id" ]]; then
      {
        printf '\n  Note: signing in to this provider will fail until it has credentials of its own.\n'
        printf '  Make a Desktop app OAuth client at %s and re-run with --client-id.\n\n' "$GOOGLE_CONSOLE_URL"
      } >&2
    fi
  fi

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
      printf '\n  note: this is the first server bound to %s, so from now on %s sessions see only\n        the servers bound here. Your account connectors (Gmail, Drive, Calendar) are not\n        among them. Put anything you want everywhere under: grandma mcp add global ...\n' "$target" "$target" >&2
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
