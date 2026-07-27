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
#   grandma knit share <sweater> <project> [--to <github-user>]... [--file <path>] [--yes]
#   grandma knit pull [--file <path>] [--as <sweater>]
#   grandma knit list
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
  sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ensure_knit_ignored — keep the local knit working copies out of the memory repo's history.
# Homes created before knit shipped have no .knit line in .gitignore, so add it on first use.
ensure_knit_ignored() {
  local gi="$ROOT/.gitignore"
  [[ -d "$ROOT" ]] || return 0
  grep -qx '.knit/' "$gi" 2>/dev/null && return 0
  printf '.knit/\n.knit-pending\n.knit-checked\n' >> "$gi" 2>/dev/null \
    && say "+ .knit/ added to $(basename "$ROOT")/.gitignore (share working copies stay local)"
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

# ------------------------------------------------------------------ strip ------
# The personal scope never leaves this machine. What goes out is ONE project's memory with
# every personal signal dropped, and the user sees the exact payload before it moves.

# personal_terms <outfile> — the fixed strings that mark a line as personal: the user's own
# name and their sweater-jargon denylist (the same list `grandma test` guards the engine with).
personal_terms() {
  local out="$1" nm
  printf '# personal terms (fixed strings, one per line)\n' > "$out"
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
  ' "$terms" "$src" \
    | sed -e "s|${HOME}|~|g" -e 's|/[Uu]sers/[A-Za-z0-9._-]*|~|g' -e 's|/home/[A-Za-z0-9._-]*|~|g'
}

# build_payload <src> <project> <sender> <outfile> <countfile> — the shareable artifact:
# a small header (so the receiving grandma knows what this is) plus the stripped memory.
build_payload() {
  local src="$1" project="$2" sender="$3" out="$4" cnt="$5"
  local terms; terms="$(mktemp "${TMPDIR:-/tmp}/grandma-knit-terms-XXXXXX")" || return 1
  personal_terms "$terms"
  {
    printf -- '---\nknit: 1\nproject: %s\nfrom: %s\nshared: %s\n---\n\n' \
      "$project" "$sender" "$(date +%Y-%m-%d)"
    printf '# %s — shared project memory\n\n' "$project"
    strip_personal "$src" "$terms" "$cnt"
  } > "$out"
  rm -f "$terms"
}

# payload_field <file> <key> — read one header field out of a received share.
payload_field() {
  sed -n '1,12p' "$1" | grep -m1 -E "^$2:" | sed "s/^$2:[[:space:]]*//" | sed 's/[[:space:]]*$//'
}

# note_ledger <direction> <peer> <project> <where> <id> — provenance, one line per share that
# crossed the boundary. Git-ignored: it is a local record, not memory.
note_ledger() {
  mkdir -p "$KNIT" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$1" "$2" "$3" "$4" "$5" >> "$LEDGER" 2>/dev/null || true
}

# ------------------------------------------------------------------- share -----

cmd_share() {
  local sweater="" project="" file="" yes=0 to=() nextto=0
  for arg in "$@"; do
    if [[ "$nextto" == "1" ]]; then to+=("$arg"); nextto=0; continue; fi
    case "$arg" in
      --to)   nextto=1 ;;
      --to=*) to+=("${arg#--to=}") ;;
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

  local slug repo; slug="$(knit_slug "$RP_NAME")"; repo="$REPO_PREFIX$slug"

  printf '\n  ── knit share: %s (from %s) ──\n' "$RP_NAME" "$sweater" >&2
  cat "$tmp" >&2
  printf '  ── end of share · %s personal line(s) stripped ──\n\n' "$cnt" >&2

  if [[ -n "$file" ]]; then
    if dry; then say "would write the share to: $file"; rm -f "$tmp"; exit 0; fi
    cp "$tmp" "$file" && say "wrote $file — hand it over however you like; they run: grandma knit pull --file <path>"
    note_ledger out "file" "$RP_NAME" "$file" "-"
    rm -f "$tmp"; exit 0
  fi

  if ! have_gh; then
    rm -f "$tmp"
    say "no usable gh CLI (install it and run 'gh auth login'), so there is no GitHub transport."
    die "share to a file instead: grandma knit share $sweater $project --file <path>"
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

  ensure_knit_ignored
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
backup: it is what each of us learned working $RP_NAME, personal scope stripped out.

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
    if gh api --method PUT "repos/$sender/$repo/collaborators/$u" -f permission=push >/dev/null 2>&1; then
      say "invited $u — GitHub emails them, and their grandma offers the pull at launch"
      note_ledger out "$u" "$RP_NAME" "$sender/$repo" "-"
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
    cat "$payload"
    printf -- '\n----- END SHARED MEMORY -----\n'
  } > "$out"
  printf '%s' "$out"
}

# ingest_dir <clonedir> <where> — write a proposal for each share in a pulled repo that is not
# ours and that we have not ingested before (the ledger is keyed by content, so re-pulling an
# unchanged share is a no-op and an updated one comes through again).
ingest_dir() {
  local d="$1" where="$2" me="$3" n=0 f peer sum out
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
    n=$((n + 1))
  done
  printf '%s' "$n"
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
    say "+ proposal: $out"
    say "review it: grandma review --apply $(basename "$out")"
    exit 0
  fi

  have_gh || die "no usable gh CLI — pull a handed-over file instead: grandma knit pull --file <path>"
  local me; me="$(gh_login)"; [[ -n "$me" ]] || die "gh is not logged in (run: gh auth login)"

  if dry; then
    say "would accept pending ${REPO_PREFIX}* invitations, clone them under $KNIT/in/,"
    say "refresh clones already there, and write one proposal per new teammate share"
    exit 0
  fi

  ensure_knit_ignored
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

  # 2. refresh everything we already have, and ingest what is new
  local total=0 d where got
  for d in "$KNIT"/in/*/; do
    [[ -d "$d/.git" ]] || continue
    where="$(basename "${d%/}" | tr '_' '/')"
    git_here "${d%/}" pull --ff-only --quiet >/dev/null 2>&1 || true
    got="$(ingest_dir "${d%/}" "$where" "$me")"
    total=$((total + ${got:-0}))
  done

  # the cache drove the launch banner; a pull is what clears it
  : > "$ROOT/.knit-pending" 2>/dev/null || true
  date +%s > "$ROOT/.knit-checked" 2>/dev/null || true

  if [[ "$total" -eq 0 ]]; then
    say "nothing new to knit in."
  else
    say "$total new share(s) waiting as proposals — review them: grandma review"
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
  mkdir "$lock" 2>/dev/null || exit 0
  # shellcheck disable=SC2064  # expand $lock now: the trap must survive whatever follows
  trap "rmdir '$lock' 2>/dev/null || true" EXIT

  # `gh auth status` can itself reach the network, so the poll only checks that gh EXISTS and
  # lets run_bounded cap the one call that matters. A logged-out gh just returns nothing.
  if ! command -v gh >/dev/null 2>&1; then date +%s > "$ROOT/.knit-checked" 2>/dev/null; exit 0; fi
  local lines tmp rc=0
  lines="$(run_bounded "${GRANDMA_KNIT_POLL_TIMEOUT:-20}" \
    gh api /user/repository_invitations \
      --jq ".[] | select(.repository.name | startswith(\"$REPO_PREFIX\")) | \"\(.inviter.login) shared project memory with you (\(.repository.full_name)) — pull it: grandma knit pull\"")" || rc=$?

  # Fail open. A timeout, a logged-out gh or an API hiccup leaves the previous cache exactly as
  # it was: the banner is a convenience, and a bad network must never look like "nothing waiting".
  # Only a call that actually SUCCEEDED is authoritative, and then an empty answer really does
  # mean no invitations are pending (they were accepted, or declined, elsewhere).
  if [[ "$rc" -eq 0 ]]; then
    if [[ -n "$lines" ]]; then
      tmp="$ROOT/.knit-pending.tmp"
      printf '%s\n' "$lines" > "$tmp" 2>/dev/null && mv "$tmp" "$ROOT/.knit-pending" 2>/dev/null
    else
      : > "$ROOT/.knit-pending" 2>/dev/null || true
    fi
  fi
  date +%s > "$ROOT/.knit-checked" 2>/dev/null
  exit 0
}

# ----------------------------------------------------------------- dispatch ----

case "${1:-}" in
  share) shift; cmd_share "$@" ;;
  pull)  shift; cmd_pull "$@" ;;
  list)  shift; cmd_list ;;
  poll)  shift; cmd_poll ;;
  help|-h|--help) usage 0 ;;
  *)     usage 2 ;;
esac
