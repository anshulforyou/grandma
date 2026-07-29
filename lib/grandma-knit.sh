#!/usr/bin/env bash
#
# grandma-knit — the sharing phase: hand a teammate your memory of a shared project.
#
# You and a teammate both work the same project and each build your own memory of it: the
# sharp edges, the decisions, the things that only bite you once. `knit share` packages YOUR
# memory of that project, strips the personal scope out of it, and puts it in a PRIVATE repo
# under your own GitHub account (grandma-knit-<project>) that your teammate is a collaborator
# on. GitHub emails them the invitation; their grandma notices it at launch and offers
# `grandma knit pull`, which turns the share into a normal memory proposal they review with
# `grandma review`. Nothing merges on its own — the last step is always a human reading a diff.
#
# There is no grandma server and no grandma account. The transport is the user's OWN GitHub,
# through the gh CLI they already log into. No gh (or no GitHub at all) still works: --file
# writes the same stripped bundle to disk, to hand over however you like.
#
# Usage:
#   grandma knit share <sweater> <project> [--to <name-or-github-user>]... [--name <name>]
#                                          [--file <path>] [--yes]
#   grandma knit pull [--file <path>] [--as <sweater>]
#   grandma knit list
#   grandma knit contacts [list|add <name> <github-handle> [email]|remove <name>]
#   grandma knit install-agent         check every 60s in the background (opt-in)
#   grandma knit uninstall-agent       remove it
#   grandma knit poll                  internal: refresh the invitation cache (backgrounded)
#
# Honest about its security level: a share is personal-stripped, non-secret project memory,
# and the boundary is the private repo's access list. Nothing is encrypted, so do not knit
# anything you would not paste into that teammate's inbox.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"

KNIT="$ROOT/.knit"
LEDGER="$KNIT/ledger.tsv"
REPO_PREFIX="grandma-knit-"

say()  { printf '  %s\n' "$1" >&2; }
die()  { printf '  %s\n' "$1" >&2; exit 1; }
dry()  { [[ "${GRANDMA_DRY_RUN:-0}" == "1" ]]; }

usage() {
  sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

# ---------------------------------------------------------------- plumbing ----

# knit_slug <text> — a safe repo/file name component: lowercase, alphanumerics and dashes.
knit_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
}

# have_gh — is the gh CLI installed AND logged in? Everything GitHub-side needs both.
have_gh() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

# gh_login — the authenticated GitHub username (the owner of the share repos).
gh_login() { gh api user --jq .login 2>/dev/null; }

# ensure_knit_ignored — keep knit's local scratch out of the memory repo's history. A home
# created before knit shipped has no .knit line in .gitignore, so add it on first use. This
# has to run before ANY knit write, not just the GitHub ones: the --file share writes a
# ledger and the launch poll writes its cache, and either one alone leaves untracked cruft
# sitting in a memory repo that is supposed to be reviewed a diff at a time. It is wired into
# the dispatcher for that reason, so a new subcommand cannot forget it.
ensure_knit_ignored() {
  local gi="$ROOT/.gitignore"
  [[ -d "$ROOT" ]] || return 0
  grep -qxF '.knit/' "$gi" 2>/dev/null && return 0   # -F: '.' is a wildcard in a BRE
  # A redirect that fails is reported by the SHELL, not the command, so `printf ... 2>/dev/null`
  # does not silence it. That matters for a job running every 60 seconds: on a memory home the
  # process cannot write (a launchd agent under ~/Documents, say) this wrote "Operation not
  # permitted" into the log on every single tick, for a case that is already handled. Test the
  # file is writable first, and put the redirect where its own failure can be swallowed.
  [[ -w "$gi" || ( ! -e "$gi" && -w "$ROOT" ) ]] || return 0
  { printf '.knit/\n.knit-pending\n.knit-checked\n' >> "$gi"; } 2>/dev/null \
    && say "+ .knit/ added to $(basename "$ROOT")/.gitignore (knit's scratch stays local)"
  return 0
}

# git_here <dir> <args...> — a git command in <dir> with an identity that always resolves, so
# a share still commits on a machine with no configured git user (CI, a fresh container).
git_here() {
  local dir="$1"; shift
  git -C "$dir" -c "user.name=${GIT_AUTHOR_NAME:-grandma}" \
      -c "user.email=${GIT_AUTHOR_EMAIL:-grandma@local}" "$@"
}

# find_project_scope <project> — which sweater knows this project? Prints "scope<TAB>name".
find_project_scope() {
  local sc dir
  while IFS= read -r sc; do
    [[ -n "$sc" ]] || continue
    dir="$(resolve_scope_dir "$sc" 2>/dev/null)" || continue
    [[ -n "$dir" ]] || continue
    resolve_project "$dir" "$1"
    if [[ "$RP_STATUS" == "OK" ]]; then printf '%s\t%s' "$sc" "$RP_NAME"; return 0; fi
  done < <(list_scopes)
  return 1
}

# --------------------------------------------------------------- gh setup ----
# knit's transport is the user's own GitHub, reached through the gh CLI. For someone who has
# never installed it, "no usable gh CLI" is a dead end naming a tool they have not heard of.
# These walk them through it instead: say what is missing, why knit needs it, and offer to do
# it for them. Installing software is a real action, so it always asks first, and it only
# asks on a terminal. Nothing here runs unattended.

# gh_install_cmd — the install command for this machine, or empty when we cannot tell.
# Printed as well as run, so the user can see exactly what they are agreeing to.
gh_install_cmd() {
  if command -v brew >/dev/null 2>&1; then echo "brew install gh"
  elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get update && sudo apt-get install -y gh"
  elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install -y gh"
  elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm github-cli"
  elif command -v zypper >/dev/null 2>&1; then echo "sudo zypper install -y gh"
  fi
}

# knit_explain_gh — why this tool is being asked for at all.
knit_explain_gh() {
  say ""
  say "knit shares memory through YOUR OWN GitHub: a private repo only you and the people"
  say "you invite can see. There is no grandma server and no grandma account, which is why"
  say "it needs the GitHub CLI (gh) to talk to GitHub on your behalf."
}

# knit_require_gh — make sure gh exists and is logged in, offering to fix whichever is
# missing. Returns 0 when knit can proceed. Never installs or logs in without a yes.
knit_require_gh() {
  local cmd ans
  if ! command -v gh >/dev/null 2>&1; then
    knit_explain_gh
    say ""
    cmd="$(gh_install_cmd)"
    if [[ -z "$cmd" ]]; then
      say "The GitHub CLI is not installed, and I cannot tell how to install it on this system."
      say "Install it from https://cli.github.com, then run this again."
      return 1
    fi
    if dry; then say "would offer to install the GitHub CLI with: $cmd"; return 1; fi
    if [ ! -t 0 ]; then
      say "The GitHub CLI is not installed. Install it with:  $cmd"
      say "Then run this again. (Or skip GitHub entirely: grandma knit share ... --file <path>)"
      return 1
    fi
    printf '  The GitHub CLI is not installed. Install it now with:\n    %s\n  [y/N] ' "$cmd" >&2
    IFS= read -r ans || return 1
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { say "no problem. You can also share without GitHub: --file <path>"; return 1; }
    say "installing..."
    if ! eval "$cmd" >&2; then
      say "that did not work. Install it from https://cli.github.com and run this again."
      return 1
    fi
    command -v gh >/dev/null 2>&1 || { say "gh still is not on PATH. Open a new terminal and try again."; return 1; }
    say "installed."
  fi

  if ! gh auth status >/dev/null 2>&1; then
    knit_explain_gh
    say ""
    if dry; then say "would offer to run: gh auth login"; return 1; fi
    if [ ! -t 0 ]; then
      say "The GitHub CLI is installed but not signed in. Run:  gh auth login"
      say "Then run this again."
      return 1
    fi
    printf '  You are not signed in to GitHub. Sign in now? It opens your browser. [y/N] ' >&2
    IFS= read -r ans || return 1
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { say "no problem. Sign in later with: gh auth login"; return 1; }
    gh auth login || { say "sign-in did not complete. Try again with: gh auth login"; return 1; }
    gh auth status >/dev/null 2>&1 || { say "still not signed in. Try: gh auth login"; return 1; }
    say "signed in."
  fi
  return 0
}

# ------------------------------------------------------------------ strip ------
# The personal scope never leaves this machine. What goes out is ONE project's memory with
# every personal signal dropped, and the user sees the exact payload before it moves.

# personal_terms <outfile> — the fixed strings that mark a line as personal: the user's own
# name and their sweater-jargon denylist (the same list `grandma test` guards the engine with).
personal_terms() {
  local out="$1" nm
  printf '# identifying terms (fixed strings, one per line)\n' > "$out"
  nm="$(grep -m1 -iE '^-?[[:space:]]*name:' "$ROOT/global/identity.md" 2>/dev/null \
        | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//')"
  [[ -n "$nm" ]] && printf '%s\n' "$nm" >> "$out"
  [[ -f "$ROOT/denylist.txt" ]] && cat "$ROOT/denylist.txt" >> "$out"
  return 0
}

# strip_personal <src> <terms> <countfile> — print <src> with the personal scope removed.
# A line goes if it carries a denylisted term or the user's name, looks like an address or a
# credential, or is marked private (`<!-- private -->` on the line, or inside a
# `<!-- knit:private -->` / `<!-- /knit:private -->` block). Absolute home paths are rewritten
# to ~. The number of dropped lines lands in <countfile> so the caller can report it.
# No ERE intervals here on purpose: the macOS awk does not reliably support {n,m}.
strip_personal() {
  local src="$1" terms="$2" cnt="$3"
  awk -v cntfile="$cnt" '
    FNR==NR { if ($0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/) t[++n]=tolower($0); next }
    {
      line=$0; low=tolower(line); drop=0
      if (line ~ /<!--[[:space:]]*knit:private[[:space:]]*-->/) { inblock=1; dropped++; next }
      if (line ~ /<!--[[:space:]]*\/knit:private[[:space:]]*-->/) { inblock=0; dropped++; next }
      if (inblock) { dropped++; next }
      if (line ~ /<!--[[:space:]]*private[[:space:]]*-->/) drop=1
      if (low ~ /[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z][a-z]+/) drop=1
      if (line ~ /eyJ[A-Za-z0-9_-]*\./ || line ~ /PRIVATE KEY/ || line ~ /[Bb]earer [A-Za-z0-9]/ \
          || line ~ /sk-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]/ || line ~ /gh[pousr]_[A-Za-z0-9]/) drop=1
      for (i=1; i<=n; i++) if (index(low, t[i]) > 0) { drop=1; break }
      if (drop) { dropped++; next }
      print line
    }
    END { printf "%d", dropped+0 > cntfile }
  ' "$terms" "$src"
}

# rewrite_paths — absolute home paths to ~. Runs BEFORE the line filter, not after: when the
# OS username matches the Name in identity.md, every line holding a home path contains the
# user's name, so the filter deletes it and the rewrite never sees it. Rewriting first means
# the path is already ~ by the time the filter looks, and the line survives on its merits.
rewrite_paths() {
  sed -e "s|${HOME}|~|g" -e 's|/[Uu]sers/[A-Za-z0-9._-]*|~|g' -e 's|/home/[A-Za-z0-9._-]*|~|g'
}

# build_payload <src> <project> <sender> <outfile> <countfile> — the shareable artifact:
# a small header (so the receiving grandma knows what this is) plus the stripped memory.
# shellcheck disable=SC2034  # termsfile is an output, read by cmd_share
build_payload() {
  local src="$1" project="$2" sender="$3" out="$4" cnt="$5"
  local rw
  terms="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-terms-XXXXXX")" || return 1
  rw="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-rw-XXXXXX")" || { rm -f "$terms"; return 1; }
  personal_terms "$terms"
  {
    printf -- '---\nknit: 1\nproject: %s\nfrom: %s\nshared: %s\n---\n\n' \
      "$project" "$sender" "$(date +%Y-%m-%d)"
    printf '# %s — shared project memory\n\n' "$project"
    rewrite_paths < "$src" > "$rw" 2>/dev/null || cp "$src" "$rw"
    strip_personal "$rw" "$terms" "$cnt"
  } > "$out"
  rm -f "$rw"
  termsfile="$terms"      # caller reports how many terms were actually in play, then removes it
}

# payload_field <file> <key> — read one header field out of a received share.
payload_field() {
  sed -n '1,12p' "$1" | grep -m1 -E "^$2:" | sed "s/^$2:[[:space:]]*//" | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------- contacts ----
# A local address book, so you type a person's name instead of remembering their GitHub
# handle. Lives beside the ledger under .knit/ (git-ignored, never shared, never distilled):
# it is convenience state, not memory. Tab-separated, three columns: name, handle, email.
#
# The handle is what actually makes an invite work, because GitHub's collaborator endpoint
# takes a username in the path and has no way to accept an address. The email column is a
# note for the --file handover, where YOU deliver the bundle and may want the address to
# hand it to.

CONTACTS="$KNIT/contacts.tsv"

# contact_lookup <name-or-handle> — print "name<TAB>handle<TAB>email" for a match on either
# the name or the handle, case-insensitively. Prints nothing when there is no match.
contact_lookup() {
  local q n h e
  q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -f "$CONTACTS" ]] || return 0
  while IFS=$'\t' read -r n h e; do
    [[ -n "${n:-}" ]] || continue
    case "$n" in \#*) continue ;; esac
    if [[ "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" == "$q" \
       || "$(printf '%s' "${h:-}" | tr '[:upper:]' '[:lower:]')" == "$q" \
       || "$(printf '%s' "${e:-}" | tr '[:upper:]' '[:lower:]')" == "$q" ]]; then
      printf '%s\t%s\t%s\n' "$n" "${h:-}" "${e:-}"; return 0
    fi
  done < "$CONTACTS"
  return 0
}

# contact_save <name> <handle> <email> — add or replace a contact, keyed on the name.
contact_save() {
  local name="$1" handle="$2" email="${3:-}" tmp n h e
  [[ -n "$name" ]] || return 0
  mkdir -p "$KNIT" 2>/dev/null
  tmp="$CONTACTS.tmp"
  : > "$tmp"
  if [[ -f "$CONTACTS" ]]; then
    while IFS=$'\t' read -r n h e; do
      [[ -n "${n:-}" ]] || continue
      [[ "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" == \
         "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" ]] && continue
      printf '%s\t%s\t%s\n' "$n" "${h:-}" "${e:-}" >> "$tmp"
    done < "$CONTACTS"
  fi
  printf '%s\t%s\t%s\n' "$name" "$handle" "$email" >> "$tmp"
  mv "$tmp" "$CONTACTS" 2>/dev/null || rm -f "$tmp"
}

# looks_like_email <token>
looks_like_email() { [[ "$1" == *@*.* && "$1" != *" "* ]]; }

# gh_user_for_email <email> — the GitHub handle whose PUBLIC profile email is this address.
# GitHub's collaborator API takes a username and cannot accept an address, so an email has to
# be turned into a handle first. This only works when the person has made their email public
# on their profile, which most people have not: the caller must handle "no match" as normal.
gh_user_for_email() {
  have_gh || return 1
  local out n
  out="$(gh api "/search/users?q=$(printf '%s' "$1" | sed 's/@/%40/')+in:email" \
          --jq '"\(.total_count)\t\(.items[0].login // "")"' 2>/dev/null)" || return 1
  n="${out%%$'\t'*}"
  [[ "${n:-0}" == "1" ]] || return 1
  printf '%s' "${out#*$'\t'}"
}


# contact_offer_name <handle> — after a successful invite to a handle grandma has not seen
# before, ask what to call them so next time the user can type that instead. Interactive
# terminals only, skipped under --yes and in dry runs: a convenience prompt must never be
# the reason a scripted share blocks.
contact_offer_name() {
  local handle="$1" known="${2:-}" hit name email
  hit="$(contact_lookup "$handle")"
  [[ -n "$hit" ]] && return 0            # already known, nothing to ask
  [ -t 0 ] || return 0
  printf '  save %s so you can share with them by name next time?\n' "$handle" >&2
  printf '  name to remember them by (empty to skip): ' >&2
  IFS= read -r name || return 0
  [[ -n "$name" ]] || return 0
  if [[ -n "$known" ]]; then
    email="$known"
  else
    printf "  their email address, only so you can find it later if you hand a --file share\n" >&2
    printf '  over yourself. Not sent anywhere. Press enter to skip: ' >&2
    IFS= read -r email || email=""
    if [[ -n "$email" ]] && ! looks_like_email "$email"; then
      say "that does not look like an email address, so it was not saved."
      say "add it later with: grandma knit contacts add $name $handle <email>"
      email=""
    fi
  fi
  contact_save "$name" "$handle" "$email"
  say "saved. next time: grandma knit share <sweater> <project> --to $name"
}

# note_ledger <direction> <peer> <project> <where> <id> — provenance, one line per share that
# crossed the boundary. Git-ignored: it is a local record, not memory.
note_ledger() {
  mkdir -p "$KNIT" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$1" "$2" "$3" "$4" "$5" >> "$LEDGER" 2>/dev/null || true
}

# ------------------------------------------------------------------- share -----

cmd_share() {
  local sweater="" project="" file="" yes=0 to=() nextto=0 asname="" nextname=0
  local -a TO_EMAIL=()
  local _uemail=""
  for arg in "$@"; do
    if [[ "$nextto" == "1" ]]; then to+=("$arg"); nextto=0; continue; fi
    if [[ "$nextname" == "1" ]]; then asname="$arg"; nextname=0; continue; fi
    case "$arg" in
      --to)   nextto=1 ;;
      --to=*) to+=("${arg#--to=}") ;;
      --name) nextname=1 ;;
      --name=*) asname="${arg#--name=}" ;;
      --file) file="-" ;;
      --file=*) file="${arg#--file=}" ;;
      --yes|-y) yes=1 ;;
      -*) die "unknown flag: $arg" ;;
      *) if   [[ -z "$sweater" ]]; then sweater="$arg"
         elif [[ -z "$project" ]]; then project="$arg"
         elif [[ "$file" == "-" ]]; then file="$arg"
         else die "unexpected argument: $arg"; fi ;;
    esac
  done
  [[ "$file" == "-" ]] && die "--file needs a path: grandma knit share <sweater> <project> --file <path>"
  [[ -n "$sweater" && -n "$project" ]] || usage 2

  # A --to token may be a saved contact name or a raw GitHub handle. Resolve names to
  # handles now, so everything downstream (the confirm prompt, the invite, the ledger) sees
  # the handle. An unknown token passes through untouched, so a handle still works as before.
  local _i _tok _hit _resolved
  for _i in "${!to[@]}"; do
    _tok="${to[$_i]}"
    _hit="$(contact_lookup "$_tok")"
    if [[ -n "$_hit" ]]; then
      # a saved name, handle, or email: the book answers without touching the network
      to[$_i]="$(printf '%s' "$_hit" | cut -f2)"
      [[ "${to[$_i]}" != "$_tok" ]] && say "$_tok -> ${to[$_i]} (from your knit contacts)"
      continue
    fi
    if looks_like_email "$_tok"; then
      # An address has to become a handle, because the collaborator API takes a username.
      # GitHub can only match an address that the person has made PUBLIC on their profile,
      # which most people have not, so a miss here is ordinary and gets a real explanation.
      _resolved="$(gh_user_for_email "$_tok" || true)"
      if [[ -n "$_resolved" ]]; then
        say "$_tok -> $_resolved (matched on their public GitHub email)"
        to[$_i]="$_resolved"
        TO_EMAIL[$_i]="$_tok"   # remember it, so saving them does not ask for it again
        continue
      fi
      say "GitHub has no user with $_tok as a public profile email, and an invite needs a handle."
      say "Their handle is on their GitHub profile page. Once you have it:"
      die "  grandma knit contacts add <name> <handle> $_tok   (then: --to <name>)"
    fi
    if [[ "$_tok" == *[!a-zA-Z0-9-]* ]]; then
      die "'$_tok' is not a saved contact, an email, or a valid GitHub handle. Add them with: grandma knit contacts add <name> <github-handle> [email]"
    fi
    : # an unsaved handle; contact_offer_name asks about it after the invite succeeds
  done

  local dir; dir="$(resolve_scope_dir "$sweater" 2>/dev/null)" \
    || die "no sweater '$sweater' — run 'grandma' to see yours."
  resolve_project "$dir" "$project"
  case "$RP_STATUS" in
    AMBIG) die "'$project' matches several projects in $sweater: $RP_CANDS" ;;
    NONE)  die "no project '$project' registered in $sweater — check $(basename "$dir")/projects.md" ;;
  esac
  local src="$RP_DIR/CLAUDE.md"
  [[ -f "$src" ]] || die "'$RP_NAME' has no memory yet ($src does not exist)."

  local sender="local"
  have_gh && sender="$(gh_login)"
  [[ -n "$sender" ]] || sender="local"

  local tmp cntf cnt
  tmp="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-payload-XXXXXX")" || die "cannot write a temp file"
  cntf="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-count-XXXXXX")" || die "cannot write a temp file"
  build_payload "$src" "$RP_NAME" "$sender" "$tmp" "$cntf" || die "could not build the share"
  cnt="$(cat "$cntf" 2>/dev/null || echo 0)"; rm -f "$cntf"

  # The repo name carries the SWEATER as well as the project. Without it, two sweaters that
  # each register a project called `api` share into one repo: the second push overwrites the
  # first, and everyone invited for the first then receives the second's memory. That is the
  # one thing the isolation promise says cannot happen, so knit must not route around it.
  local slug repo
  slug="$(knit_slug "$sweater")-$(knit_slug "$RP_NAME")"
  repo="$REPO_PREFIX$slug"

  printf '\n  ── knit share: %s (from %s) ──\n' "$RP_NAME" "$sweater" >&2
  cat "$tmp" >&2
  local nterms; nterms="$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$termsfile" 2>/dev/null || echo 0)"
  printf '  ── end of share · %s line(s) removed, matching %s term(s) ──\n' "$cnt" "$nterms" >&2
  if [[ "${nterms:-0}" -le 1 ]]; then
    printf '  read it: only your own name is being matched. Add employers, clients and\n' >&2
    printf '  product names to %s/denylist.txt to catch more.\n\n' "$(basename "$ROOT")" >&2
  else
    printf '\n' >&2
  fi
  rm -f "$termsfile" 2>/dev/null || true

  if [[ -n "$file" ]]; then
    if dry; then say "would write the share to: $file"; rm -f "$tmp"; exit 0; fi
    if ! cp "$tmp" "$file"; then rm -f "$tmp"; die "could not write $file"; fi
    say "wrote $file — hand it over however you like; they run: grandma knit pull --file <path>"
    note_ledger out "file" "$RP_NAME" "$file" "-"
    rm -f "$tmp"; exit 0
  fi

  if ! have_gh; then
    if ! knit_require_gh; then
      rm -f "$tmp"
      exit 1
    fi
  fi

  if dry; then
    say "would ensure private repo: $sender/$repo"
    say "would write:               shares/$sender.md ($(wc -l < "$tmp" | tr -d ' ') lines, $cnt stripped)"
    if [[ ${#to[@]} -gt 0 ]]; then say "would invite:              ${to[*]} (push access)"
    else say "would invite:              nobody (--to <github-user> to add a teammate)"; fi
    rm -f "$tmp"; exit 0
  fi

  # Outward move: never without a yes. This puts memory on a remote and mails a human.
  if [[ "$yes" != "1" ]]; then
    if [[ ! -t 0 ]]; then rm -f "$tmp"; die "not a terminal — re-run with --yes once you have read the share above."; fi
    printf '  push this to %s/%s%s? [y/N] ' "$sender" "$repo" \
      "$([[ ${#to[@]} -gt 0 ]] && printf ' and invite %s' "${to[*]}")" >&2
    local ans; read -r ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { rm -f "$tmp"; say "nothing shared."; exit 0; }
  fi

  mkdir -p "$KNIT/out"
  local wd="$KNIT/out/$repo"
  if [[ ! -d "$wd/.git" ]]; then
    gh repo view "$sender/$repo" >/dev/null 2>&1 \
      || gh repo create "$sender/$repo" --private \
           --description "grandma knit: shared memory for $RP_NAME" >/dev/null 2>&1 \
      || { rm -f "$tmp"; die "could not create $sender/$repo (check: gh auth status)"; }
    rm -rf "$wd"
    gh repo clone "$sender/$repo" "$wd" >/dev/null 2>&1 \
      || { rm -f "$tmp"; die "could not clone $sender/$repo"; }
  else
    git_here "$wd" pull --ff-only --quiet >/dev/null 2>&1 || true
  fi

  mkdir -p "$wd/shares"
  cp "$tmp" "$wd/shares/$sender.md"; rm -f "$tmp"
  cat > "$wd/README.md" <<EOF
# grandma knit: $RP_NAME

Shared project memory, one file per person under \`shares/\`. This is not code and not a
backup: it is what each of us learned working $RP_NAME, with identifying detail removed.

Pull it into your own memory with grandma:

    grandma knit pull

It arrives as a proposal you review line by line. Nothing merges on its own.
EOF

  git_here "$wd" add -A >/dev/null 2>&1
  if git_here "$wd" diff --cached --quiet 2>/dev/null; then
    say "no change since your last share of $RP_NAME."
  else
    git_here "$wd" commit -qm "knit: $RP_NAME memory from $sender" >/dev/null 2>&1 \
      || { die "could not commit the share (check: git -C $wd status)"; }
    git_here "$wd" push -u origin HEAD >/dev/null 2>&1 \
      || die "could not push to $sender/$repo (check: gh auth status, and git -C $wd push)"
    say "pushed your $RP_NAME memory to $sender/$repo"
  fi

  local u
  for u in ${to[@]+"${to[@]}"}; do
    # `pull`, not `push`: a recipient only ever clones and fetches. Write access would let an
    # invitee put a file into your repo, and since a pull ingests by filename, it would arrive
    # in your own review queue attributed to whoever they named it after.
    if gh api --method PUT "repos/$sender/$repo/collaborators/$u" -f permission=pull >/dev/null 2>&1; then
      say "invited $u — GitHub emails them, and their grandma offers the pull at launch"
      note_ledger out "$u" "$RP_NAME" "$sender/$repo" "-"
      _uemail=""
      for _i in "${!to[@]}"; do [[ "${to[$_i]}" == "$u" ]] && _uemail="${TO_EMAIL[$_i]:-}"; done
      if [[ -n "$asname" ]]; then contact_save "$asname" "$u" "$_uemail"; say "saved $u as '$asname'"
      elif [[ "$yes" != "1" ]]; then contact_offer_name "$u" "$_uemail"; fi
    else
      say "could not invite $u (is that a real GitHub username?)"
    fi
  done
  [[ ${#to[@]} -eq 0 ]] && note_ledger out "-" "$RP_NAME" "$sender/$repo" "-"
  printf '\n' >&2
}

# -------------------------------------------------------------------- pull -----

# write_proposal <payloadfile> <peer> <where> [<forced-scope>] — turn a received share into a
# normal memory proposal, so it merges through the review flow the user already knows.
# The filename is "<scope>-knit-<slug>-<stamp>.md": review resolves the scope by longest
# matching prefix, so a kebab-case sweater survives it.
write_proposal() {
  local payload="$1" peer="$2" where="$3" forced="${4:-}"
  local project scope rp
  project="$(payload_field "$payload" project)"
  [[ -n "$project" ]] || project="unknown"
  if [[ -n "$forced" ]]; then
    scope="$(resolve_scope_dir "$forced" >/dev/null 2>&1 && printf '%s' "$forced")"
    rp="$project"
  else
    local hit; hit="$(find_project_scope "$project" || true)"
    scope="${hit%%$'\t'*}"; rp="${hit#*$'\t'}"
  fi
  if [[ -z "$scope" ]]; then
    say "'$project' is not a project in any sweater yet — keeping the share at $payload"
    say "pull it into a sweater with: grandma knit pull --file $payload --as <sweater>"
    return 1
  fi

  mkdir -p "$ROOT/proposals"
  # Canonical (lowercased) sweater spelling, matching what save.sh writes and what
  # list_proposals matches on. Resolution is case-insensitive, filenames are not.
  scope="$(canonical_scope "$scope" || printf '%s' "$scope")"
  local out
  out="$ROOT/proposals/${scope}-knit-$(knit_slug "$project")-$(date +%Y%m%dT%H%M%S).md"
  {
    printf '# grandma memory proposal (knit)\n'
    printf '# scope=%s  project=%s  from=%s  via=%s\n\n' "$scope" "$rp" "$peer" "$where"
    printf '%s shared their memory of %s. This is THEIR memory, not yours: read it against\n' "$peer" "$rp"
    printf 'what %s already knows about %s and keep only what the user approves. Where the two\n' "$scope" "$rp"
    printf 'disagree, show both and ask — do not silently overwrite a local note. Attribute what\n'
    printf 'you keep to %s so its origin stays visible.\n\n' "$peer"
    printf -- '----- BEGIN SHARED MEMORY (%s) -----\n' "$peer"
    # Neutralise any line that would close the fence early. Without this, a share containing
    # the end delimiter puts the rest of its own text OUTSIDE the quoted block, where the
    # reviewing session reads it as instruction rather than as someone else's memory.
    sed 's/^----- END SHARED MEMORY -----$/- - - - - END SHARED MEMORY (quoted) - - - - -/' "$payload"
    printf -- '\n----- END SHARED MEMORY -----\n'
  } > "$out"
  printf '%s' "$out"
}

# ingest_dir <clonedir> <where> — write a proposal for each share in a pulled repo that is not
# ours and that we have not ingested before (the ledger is keyed by content, so re-pulling an
# unchanged share is a no-op and an updated one comes through again).
# Appends the proposals it writes to INGESTED, so a pull can point at the share that just
# arrived rather than at every pending proposal in the home. It must NOT be called through a
# command substitution: that is a subshell, and the array would never reach the caller.
ingest_dir() {
  local d="$1" where="$2" me="$3" f peer sum out
  for f in "$d"/shares/*.md; do
    [[ -f "$f" ]] || continue
    peer="$(basename "$f" .md)"
    [[ "$peer" == "$me" ]] && continue
    sum="$(cksum < "$f" | tr -d ' ')"
    grep -q "knit:$sum" "$LEDGER" 2>/dev/null && continue
    out="$(write_proposal "$f" "$peer" "$where" || true)"
    [[ -n "$out" ]] || continue
    note_ledger in "$peer" "$(payload_field "$f" project)" "$where" "knit:$sum"
    say "+ proposal from $peer: $(basename "$out")"
    INGESTED+=("$out")
  done
  return 0
}

cmd_pull() {
  local file="" as="" nextas=0
  for arg in "$@"; do
    if [[ "$nextas" == "1" ]]; then as="$arg"; nextas=0; continue; fi
    case "$arg" in
      --file) file="-" ;;
      --file=*) file="${arg#--file=}" ;;
      --as)   nextas=1 ;;
      --as=*) as="${arg#--as=}" ;;
      -*) die "unknown flag: $arg" ;;
      *) if [[ "$file" == "-" ]]; then file="$arg"; else die "unexpected argument: $arg"; fi ;;
    esac
  done
  [[ "$file" == "-" ]] && die "--file needs a path: grandma knit pull --file <path>"

  # ---- file handover: no GitHub involved ----
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || die "no such share file: $file"
    [[ "$(payload_field "$file" knit)" == "1" ]] || die "$file is not a grandma knit share."
    if dry; then say "would turn $file into a memory proposal${as:+ under $as}"; exit 0; fi
    local peer out
    peer="$(payload_field "$file" from)"; [[ -n "$peer" ]] || peer="a teammate"
    out="$(write_proposal "$file" "$peer" "$file" "$as" || true)"
    [[ -n "$out" ]] || exit 1
    note_ledger in "$peer" "$(payload_field "$file" project)" "$file" "knit:$(cksum < "$file" | tr -d ' ')"
    say "+ proposal: $(basename "$out")"
    say "read it on its own:  grandma review --apply $(basename "$out")"
    exit 0
  fi

  if ! have_gh; then
    knit_require_gh || die "or pull a handed-over file instead: grandma knit pull --file <path>"
  fi
  local me; me="$(gh_login)"; [[ -n "$me" ]] || die "gh is not logged in (run: gh auth login)"

  if dry; then
    say "would accept pending ${REPO_PREFIX}* invitations, clone them under $KNIT/in/,"
    say "pick up any ${REPO_PREFIX}* repo you already have access to, refresh clones already"
    say "there, and write one proposal per new teammate share"
    exit 0
  fi

  mkdir -p "$KNIT/in"

  # 1. accept pending invitations to knit repos (and only those)
  local invs id full
  invs="$(gh api /user/repository_invitations \
    --jq ".[] | select(.repository.name | startswith(\"$REPO_PREFIX\")) | \"\(.id)\t\(.repository.full_name)\"" 2>/dev/null || true)"
  while IFS=$'\t' read -r id full; do
    [[ -n "${id:-}" && -n "${full:-}" ]] || continue
    if gh api --method PATCH "/user/repository_invitations/$id" >/dev/null 2>&1; then
      say "accepted the invitation to $full"
    else
      say "could not accept the invitation to $full"; continue
    fi
    local dest
    dest="$KNIT/in/$(printf '%s' "$full" | tr '/' '_')"
    [[ -d "$dest/.git" ]] || gh repo clone "$full" "$dest" >/dev/null 2>&1 \
      || say "could not clone $full"
  done <<< "$invs"

  # 2. pick up knit repos we can already reach but have never cloned. This is the ordinary
  # case, not an edge one: the invitation email has an Accept button, and clicking it is the
  # obvious thing to do. That consumes the invitation, so step 1 finds nothing and without
  # this the share would be invisible with no hint as to why.
  local full dest
  while IFS= read -r full; do
    [[ -n "${full:-}" ]] || continue
    dest="$KNIT/in/$(printf '%s' "$full" | tr '/' '_')"
    [[ -d "$dest/.git" ]] && continue
    if gh repo clone "$full" "$dest" >/dev/null 2>&1; then
      say "found $full (you already had access)"
    fi
  # /user/repos returns repos you OWN as well as ones shared with you. Cloning your own turns
  # your outbox into an inbox: anything sitting in it is ingested as a share from whoever the
  # filename names. Your own shares are not news to you either way.
  done < <(gh api --paginate "/user/repos?per_page=100" \
             --jq ".[] | select(.name | startswith(\"$REPO_PREFIX\")) | select(.owner.login != \"$me\") | .full_name" 2>/dev/null || true)

  # 3. refresh everything we already have, and ingest what is new
  local d where
  INGESTED=()
  for d in "$KNIT"/in/*/; do
    [[ -d "$d/.git" ]] || continue
    where="$(basename "${d%/}" | tr '_' '/')"
    git_here "${d%/}" pull --ff-only --quiet >/dev/null 2>&1 || true
    ingest_dir "${d%/}" "$where" "$me"
  done
  local total=${#INGESTED[@]}

  # the cache drove the launch banner; a pull is what clears it
  : > "$ROOT/.knit-pending" 2>/dev/null || true
  date +%s > "$ROOT/.knit-checked" 2>/dev/null || true

  if [[ "$total" -eq 0 ]]; then
    say "nothing new to knit in."
    return 0
  fi

  # Point at what just arrived, not at the whole proposal queue. Someone else's memory is
  # exactly the thing you want to read on its own, and `grandma review` would bury it among
  # your own pending distills.
  if [[ ${#INGESTED[@]} -eq 1 ]]; then
    local one; one="$(basename "${INGESTED[0]}")"
    if [[ -t 0 ]] && ! dry; then
      printf '  read it now? [Y/n] ' >&2
      local ans; read -r ans
      if [[ "${ans:-y}" =~ ^[Yy]?$ ]]; then
        exec "$ENGINE/lib/grandma-review.sh" --apply "${INGESTED[0]}"
      fi
    fi
    say "read it on its own:  grandma review --apply $one"
  else
    say "$total new share(s). Read each on its own:"
    local f
    for f in ${INGESTED[@]+"${INGESTED[@]}"}; do
      say "  grandma review --apply $(basename "$f")"
    done
  fi
}

# -------------------------------------------------------------- list / poll ----

cmd_list() {
  printf '\n  knit\n' >&2
  if [[ -s "$ROOT/.knit-pending" ]]; then
    printf '  pending invitations (cached):\n' >&2
    sed 's/^/    /' "$ROOT/.knit-pending" >&2
  else
    printf '  pending invitations (cached): none\n' >&2
  fi
  local d n=0
  for d in "$KNIT"/in/*/; do
    [[ -d "$d/.git" ]] || continue
    [[ "$n" == 0 ]] && printf '  shared with you:\n' >&2
    printf '    %s\n' "$(basename "${d%/}" | tr '_' '/')" >&2; n=$((n + 1))
  done
  n=0
  for d in "$KNIT"/out/*/; do
    [[ -d "$d/.git" ]] || continue
    [[ "$n" == 0 ]] && printf '  you share:\n' >&2
    printf '    %s\n' "$(basename "${d%/}")" >&2; n=$((n + 1))
  done
  if [[ -s "$LEDGER" ]]; then
    printf '  recent (date, direction, peer, project, where):\n' >&2
    tail -n 5 "$LEDGER" | sed 's/^/    /' >&2
  fi
  printf '\n' >&2
}

cmd_contacts() {
  local action="${1:-list}"; shift 2>/dev/null || true
  case "$action" in
    list|"")
      printf '\n  knit contacts\n' >&2
      if [[ ! -s "$CONTACTS" ]]; then
        printf '    none yet — they are saved as you share, or add one:\n' >&2
        printf '    grandma knit contacts add <name> <github-handle> [email]\n\n' >&2
        return 0
      fi
      printf '    %-18s %-20s %s\n' NAME GITHUB EMAIL >&2
      local n h e
      while IFS=$'\t' read -r n h e; do
        [[ -n "${n:-}" ]] || continue
        printf '    %-18s %-20s %s\n' "$n" "${h:--}" "${e:--}" >&2
      done < "$CONTACTS"
      printf '\n    share with one: grandma knit share <sweater> <project> --to <name>\n\n' >&2
      ;;
    add)
      local name="${1:-}" handle="${2:-}" email="${3:-}"
      [[ -n "$name" && -n "$handle" ]] \
        || die "usage: grandma knit contacts add <name> <github-handle> [email]"
      if [[ -n "$email" ]] && ! looks_like_email "$email"; then
        die "'$email' is not an email address. Usage: grandma knit contacts add <name> <github-handle> [email]"
      fi
      dry && { say "would save $name -> $handle${email:+ <$email>}"; return 0; }
      contact_save "$name" "$handle" "$email"
      say "saved $name -> $handle${email:+ <$email>}"
      ;;
    remove|rm|forget)
      local name="${1:-}"
      [[ -n "$name" ]] || die "usage: grandma knit contacts remove <name>"
      [[ -n "$(contact_lookup "$name")" ]] || die "no contact named '$name'"
      dry && { say "would remove $name"; return 0; }
      local n h e tmp="$CONTACTS.tmp"; : > "$tmp"
      while IFS=$'\t' read -r n h e; do
        [[ -n "${n:-}" ]] || continue
        [[ "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" == \
           "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" ]] && continue
        printf '%s\t%s\t%s\n' "$n" "${h:-}" "${e:-}" >> "$tmp"
      done < "$CONTACTS"
      mv "$tmp" "$CONTACTS"; say "removed $name"
      ;;
    *) die "unknown contacts action: $action (list, add, remove)" ;;
  esac
}

# run_bounded <secs> <cmd...> — run a command with a wall-clock cap, print its stdout. The
# poll runs detached at launch time, so a network stall must never leave a process hanging
# around forever. Pure bash: no timeout(1) on macOS, no new dependency.
# Completion is detected by a marker file the child writes, NOT by `kill -0`: a finished
# child can sit as a zombie until it is reaped, and kill -0 reports a zombie as alive.
run_bounded() {
  local secs="$1"; shift
  local out finished pid i=0 rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-out-XXXXXX")" || return 1
  finished="$out.rc"
  ( "$@" > "$out" 2>/dev/null; printf '%s' "$?" > "$finished" ) &
  pid=$!
  while [[ "$i" -lt $((secs * 10)) ]]; do
    [[ -s "$finished" ]] && break
    sleep 0.1; i=$((i + 1))
  done
  if [[ -s "$finished" ]]; then
    rc="$(cat "$finished")"
  else
    # Kill the CHILDREN first. The command runs inside a backgrounded subshell, so signalling
    # only $pid reaps the subshell and leaves the actual network call running long past the
    # bound it was given. A negative pid does not help here either: the subshell inherits its
    # parent's process group rather than leading one of its own.
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null; rc=124
  fi
  wait "$pid" 2>/dev/null || true
  cat "$out"; rm -f "$out" "$finished"
  return "${rc:-1}"
}

# cmd_poll — refresh the pending-invitation cache that the launch banner reads. Runs detached
# and always exits 0: no network, no gh, no GitHub at all is a normal state, not an error.
# A lock keeps a stalled poll from spawning siblings on every launch.
cmd_poll() {
  local lock="$KNIT/poll.lock"
  mkdir -p "$KNIT" 2>/dev/null
  # A per-minute agent must never stack. mkdir is the atomic test-and-set; a tick that finds
  # the lock held exits immediately rather than queueing behind the one already running.
  # But the lock is released by an EXIT trap, and a SIGKILL, an OOM or a reboot mid-poll skips
  # traps entirely. Without recovery that leaves the directory behind forever and knit never
  # checks again. Steal a lock older than an hour: no tick lives anywhere near that long, since
  # the network call is capped in seconds. grandma-watch's tick already does exactly this.
  if ! mkdir "$lock" 2>/dev/null; then
    local lock_age now_s lock_s
    now_s="$(date +%s 2>/dev/null)"; lock_s="$(file_mtime "$lock")"
    lock_age=$(( ${now_s:-0} - ${lock_s:-0} ))
    if [[ "$lock_age" -lt "${GRANDMA_KNIT_LOCK_STALE:-3600}" ]]; then exit 0; fi
    rmdir "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  fi
  # shellcheck disable=SC2064  # expand $lock now: the trap must survive whatever follows
  trap "rmdir '$lock' 2>/dev/null || true" EXIT

  # `gh auth status` can itself reach the network, so the poll only checks that gh EXISTS and
  # lets run_bounded cap the one call that matters. A logged-out gh just returns nothing.
  if ! command -v gh >/dev/null 2>&1; then date +%s > "$ROOT/.knit-checked" 2>/dev/null; exit 0; fi

  # Conditional request. GitHub returns 304 when nothing has changed, and a 304 costs no rate
  # limit at all, which is what makes a 60-second tick affordable: the steady state is a free
  # round trip that does no work. Only a 200 is parsed, and only a 200 can notify.
  local etagf="$KNIT/invitations.etag" etag="" resp status body newetag rc=0
  # An ETag validates a cache we still hold. If the pending cache is gone — deleted by hand,
  # lost, or never written — a 304 would say "unchanged" and leave us with nothing, and the
  # banner would never return until the invitation list itself changed. So only send the
  # conditional header when there is actually a cached answer to keep.
  if [[ -f "$etagf" && -f "$ROOT/.knit-pending" ]]; then
    etag="$(head -n1 "$etagf" 2>/dev/null | tr -d '\r\n')"
  fi
  resp="$(run_bounded "${GRANDMA_KNIT_POLL_TIMEOUT:-20}" \
    gh api -i ${etag:+-H "If-None-Match: $etag"} /user/repository_invitations)" || rc=$?
  status="$(printf '%s' "$resp" | head -n1 | tr -d '\r')"

  case "$status" in
    *" 304"*)
      # nothing changed: no cache write, no notification, no work
      date +%s > "$ROOT/.knit-checked" 2>/dev/null
      exit 0 ;;
  esac
  # Fail open on anything that is not a clean 200: a timeout, a logged-out gh or an API hiccup
  # leaves the previous cache exactly as it was, because a bad network must never read as
  # "nothing waiting".
  case "$status" in
    *" 200"*) : ;;
    *) date +%s > "$ROOT/.knit-checked" 2>/dev/null; exit 0 ;;
  esac
  [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || { date +%s > "$ROOT/.knit-checked" 2>/dev/null; exit 0; }

  newetag="$(printf '%s\n' "$resp" | grep -i '^etag:' | head -n1 | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//')"
  body="$(printf '%s\n' "$resp" | awk 'f{print} /^\r?$/{f=1}')"
  local lines
  lines="$(printf '%s' "$body" | jq -r \
    ".[] | select(.repository.name | startswith(\"$REPO_PREFIX\")) | \"\(.inviter.login) shared project memory with you (\(.repository.full_name))\"" \
    2>/dev/null)" || lines=""

  if [[ -n "$lines" ]]; then
    # Notify only for shares that were not in the cache last time. The tick runs every minute,
    # so notifying on the whole pending list would re-ping the same share until it was pulled.
    local prev line
    prev="$(cat "$ROOT/.knit-pending" 2>/dev/null || true)"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '%s\n' "$prev" | grep -Fqx "$line" && continue
      notify_user "grandma knit" "$line" "grandma knit pull" || true
    done <<< "$lines"
    local tmp="$ROOT/.knit-pending.tmp"
    printf '%s\n' "$lines" > "$tmp" 2>/dev/null && mv "$tmp" "$ROOT/.knit-pending" 2>/dev/null
  else
    : > "$ROOT/.knit-pending" 2>/dev/null || true
  fi
  [[ -n "$newetag" ]] && printf '%s\n' "$newetag" > "$etagf" 2>/dev/null
  date +%s > "$ROOT/.knit-checked" 2>/dev/null
  exit 0
}

# ----------------------------------------------------------- agent ------------
# Optional, opt-in background check. Without it, knit only looks when you launch grandma and
# only every 8 hours, so a share can sit unseen for most of a day. With it, a tick every 60
# seconds makes arrival effectively instant.
#
# A per-minute job on someone's machine has to be boring: the tick takes a lock so ticks can
# never stack, caps its own network call, and sends a conditional request so the steady state
# is a 304 that costs no rate limit and does no work. It is never installed for you.

KNIT_AGENT_LABEL="com.grandma.knit"
# Under $KNIT, not /tmp. A fixed, predictable name in a world-writable directory can be
# pre-created or symlinked by another local user before the agent's first run, and launchd
# follows it and writes as you. Everything else knit writes already lives here, and
# notify_user logs under $ROOT/.distill, so this also stops being the one exception.
# Overridable so the tests can simulate a failing agent without touching a real agent's log.
KNIT_AGENT_LOG="${GRANDMA_KNIT_AGENT_LOG:-$KNIT/agent.log}"
# Overridable for the same reason as the log: a test that installs and removes a plist at the
# real ~/Library/LaunchAgents path uninstalls the agent of whoever is running the suite.
knit_agent_plist() {
  printf '%s/%s.plist' "${GRANDMA_KNIT_AGENT_DIR:-$HOME/Library/LaunchAgents}" "$KNIT_AGENT_LABEL"
}
# Clamped. The value goes straight into StartInterval, and `=1` would install a job ticking
# every second. Non-numeric already fails safe, since launchd refuses the plist and install
# reports it, but a small number is accepted silently and is the worse case.
knit_agent_interval() {
  local v="${GRANDMA_KNIT_AGENT_INTERVAL:-60}"
  case "$v" in ''|*[!0-9]*) printf '60'; return 0 ;; esac
  [[ "$v" -lt 30 ]] && { printf '30'; return 0; }
  printf '%s' "$v"
}

cmd_install_agent() {
  local interval; interval="$(knit_agent_interval)"
  local plist; plist="$(knit_agent_plist)"
  # The dry run answers first, and answers on every platform. Checking for launchctl before it
  # meant `GRANDMA_DRY_RUN=1 ... install-agent` exited 1 on Linux with cron advice instead of a
  # plan, which is not what a dry run is for.
  if dry; then
    if command -v launchctl >/dev/null 2>&1; then
      say "would install $KNIT_AGENT_LABEL: a check every ${interval}s"
      say "would write: $plist"
    else
      say "would print the cron line to run a check every ${interval}s (launchd is macOS-only)"
      say "would write: nothing"
    fi
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    say "launchd is macOS-only. On Linux, add a cron entry (this runs it every minute):"
    say "  * * * * * $ENGINE/lib/grandma-knit.sh poll"
    say "or a systemd user timer with OnUnitActiveSec=${interval}s."
    return 1
  fi
  # launchd is about to be given a StandardOutPath inside $KNIT, so $KNIT has to exist. It is
  # created by poll, share, contact_save and note_ledger, which covers anyone who has used knit
  # before and nobody whose FIRST knit command is install-agent, which is a normal way to start.
  # /tmp always existed, so moving the log here surfaced this.
  mkdir -p "$KNIT" "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$KNIT_AGENT_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$ENGINE/lib/grandma-knit.sh</string><string>poll</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>GRANDMA_HOME</key><string>$ROOT</string>
    <key>PATH</key><string>$(dirname "$(command -v gh 2>/dev/null || echo /usr/local/bin/gh)"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$KNIT_AGENT_LOG</string>
  <key>StandardErrorPath</key><string>$KNIT_AGENT_LOG</string>
</dict></plist>
EOF
  # Verify by EXISTENCE, not by timestamp. Every exit path of a tick writes .knit-checked, so
  # removing it first and waiting for it to come back is unambiguous. Comparing mtimes instead
  # looks reasonable and is not: the stamp has one-second granularity, so a tick landing in the
  # same second as the baseline is invisible and a working agent gets called broken.
  # Losing the old stamp is harmless, it only means the next launch checks straight away.
  local stampf="$ROOT/.knit-checked" i=0
  rm -f "$stampf"

  launchctl unload "$plist" 2>/dev/null || true
  if ! launchctl load "$plist" 2>/dev/null; then
    say "could not load the agent. The plist is at $plist"
    rm -f "$plist"
    return 1
  fi

  # Loading is not running. On macOS a launchd job cannot read ~/Documents without Full Disk
  # Access for /bin/bash, so an agent installed from a checkout living there fails on every
  # tick with "Operation not permitted" while launchctl still reports it as loaded. Saying
  # "installed" at that point is a lie the user only discovers by never being notified.
  #
  # So verify FUNCTIONALLY: RunAtLoad fires a tick immediately, and every exit path of a tick
  # stamps .knit-checked. If that stamp moves, the agent really can read the engine and write
  # the memory home. If it does not, this is not a working install and should not claim to be.
  say "installed, checking that it can actually run..."
  while [[ "$i" -lt 40 ]]; do
    [[ -f "$stampf" ]] && break
    sleep 0.25; i=$((i + 1))
  done

  if [[ -f "$stampf" ]]; then
    say "background check is live: every ${interval}s (log: $KNIT_AGENT_LOG)"
    say "a share now reaches you within a minute, without opening grandma."
    say "remove it any time with: grandma knit uninstall-agent"
    return 0
  fi

  # It loaded but did not work. Say why, using what launchd and the log actually reported,
  # and take the broken job back out rather than leaving it failing every minute forever.
  local st reason
  st="$(launchctl list 2>/dev/null | awk -v l="$KNIT_AGENT_LABEL" '$3 == l {print $2}')"
  reason="$(tail -n 1 "$KNIT_AGENT_LOG" 2>/dev/null)"
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  say ""
  say "the agent loaded but its first check did not run${st:+ (launchd exit $st)}, so it has been removed."
  [[ -n "$reason" ]] && say "launchd said: $reason"
  case "$reason" in
    *"Operation not permitted"*|*"Permission denied"*)
      say ""
      say "That is macOS file protection, not a bug in the job: a background agent cannot read"
      say "$ENGINE without permission. Two ways round it:"
      say "  1. move the engine somewhere unprotected (anywhere outside ~/Documents, ~/Desktop,"
      say "     ~/Downloads), then run this again. This is the simpler one."
      say "  2. grant Full Disk Access to /bin/bash in System Settings > Privacy & Security,"
      say "     then run this again. Broader than it sounds, since it applies to every script."
      ;;
    "") say "It wrote nothing to $KNIT_AGENT_LOG, so launchd could not start it at all."
        say "Most often that means it cannot write there: check the path exists and is writable." ;;
    *)  say "See $KNIT_AGENT_LOG for what it tried." ;;
  esac
  say ""
  say "Nothing else changed: knit still checks at launch, and 'grandma knit pull' always works."
  return 1
}

cmd_uninstall_agent() {
  local plist; plist="$(knit_agent_plist)"
  if dry; then say "would unload and remove $plist"; return 0; fi
  command -v launchctl >/dev/null 2>&1 && launchctl unload "$plist" 2>/dev/null
  if [[ -f "$plist" ]]; then rm -f "$plist"; say "background check removed."
  else say "no background check was installed."; fi
}

# ----------------------------------------------------------------- dispatch ----

# Anything that can write to the home ensures the ignore rule first. A dry run must stay
# side-effect free, so it is exempt (and it writes nothing to guard against either).
case "${1:-}" in
  share|pull|poll|contacts|install-agent) dry || ensure_knit_ignored ;;
esac

case "${1:-}" in
  share) shift; cmd_share "$@" ;;
  pull)  shift; cmd_pull "$@" ;;
  list)  shift; cmd_list ;;
  contacts) shift; cmd_contacts "$@" ;;
  poll)  shift; cmd_poll ;;
  install-agent)   shift; cmd_install_agent ;;
  uninstall-agent) shift; cmd_uninstall_agent ;;
  help|-h|--help) usage 0 ;;
  *)     usage 2 ;;
esac
