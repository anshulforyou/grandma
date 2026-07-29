#!/usr/bin/env bash
# test/lib/fixture.sh — build a deterministic, populated GRANDMA_HOME with NO claude needed.
# Sourced by test/cmd_*.sh. The home satisfies every grandma-test invariant (frontmatter,
# isolation, INDEX, secrets) and, crucially, contains a KEBAB-CASE sweater plus a proposal
# whose filename trips the `cut -d-` scope-parsing bug.

FIXTURE_ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# _fx_md <path> <scope> <type> <body...> — write a memory file with matching frontmatter.
_fx_md() {
  local path="$1" scope="$2" type="$3"; shift 3
  mkdir -p "$(dirname "$path")"
  { printf -- '---\nscope: %s\ntype: %s\nupdated: 2026-06-15\n---\n\n' "$scope" "$type"
    printf '%s\n' "$@"; } > "$path"
}

# make_fixture_home <dir> — create a full memory home at <dir>.
make_fixture_home() {
  local home="$1"
  mkdir -p "$home"

  # ---- global (identity has NO "<your name>" placeholder → no interview branch) ----
  _fx_md "$home/global/identity.md"    global identity     "# Identity" "- Name: Test User" "- Role: engineer, works across multiple contexts"
  _fx_md "$home/global/preferences.md" global preferences  "# Preferences" "- never auto-commit, review diffs first" "- pnpm only, never yarn"
  _fx_md "$home/global/style.md"       global style        "# Style" "- terse, lowercase, no em-dashes"

  # Fixture scope names must not appear in any CORE engine file (grandma-test check #2 is
  # case-insensitive), so we use invented ones: `globex` (plain) and `home-ops` (kebab).

  # ---- sweater: globex (plain) with a registered project + on-demand files for --full ----
  mkdir -p "$home/projects/billing-api" "$home/projects/yard"
  printf '# Billing API\n- the globex billing service\n' > "$home/projects/billing-api/CLAUDE.md"
  printf '# Yard\n- home yard chores project\n'          > "$home/projects/yard/CLAUDE.md"

  _fx_md "$home/globex/facts.md"     globex facts     "# globex facts" "- Go on GCP, Postgres, migrations via atlas only"
  _fx_md "$home/globex/projects.md"  globex projects  "## Billing API" "- source: $home/projects/billing-api/CLAUDE.md"
  _fx_md "$home/globex/decisions.md" globex decisions "# globex decisions" "- 2026-05-01: chose atlas for migrations"
  _fx_md "$home/globex/log/2026-06-15.md" globex log  "# session log" "- shipped the billing migration"
  _fx_md "$home/globex/log/_rollup.md"    globex log  "# rollup" "- globex history compressed here"

  # ---- sweater: home-ops (KEBAB — the tripwire for the review `cut -d-` bug) ----
  _fx_md "$home/home-ops/facts.md"    home-ops facts    "# home-ops facts" "- trash goes out Sunday night"
  _fx_md "$home/home-ops/projects.md" home-ops projects "## Yard" "- source: $home/projects/yard/CLAUDE.md"
  _fx_md "$home/home-ops/log/2026-06-01.md" home-ops log "# session log" "- planted tomatoes"

  # ---- the load-bearing proposal: `cut -d- -f1` yields "home", the real scope is "home-ops" ----
  mkdir -p "$home/proposals" "$home/watches" "$home/.distill"
  { echo "# grandma memory proposal"
    echo "# scope=home-ops  transcript=abc123"
    echo
    echo "target: home-ops/facts.md | action: append | text: recycling is biweekly"
  } > "$home/proposals/home-ops-20260601T101010.md"

  # ---- INDEX (no bracketed .md refs → check #6 trivially clean), denylist, gitignore ----
  printf '# Memory index\n\nglobal, globex, home-ops.\n' > "$home/INDEX.md"
  cp "$FIXTURE_ENGINE/templates/denylist.txt"     "$home/denylist.txt"
  cp "$FIXTURE_ENGINE/templates/home-gitignore"   "$home/.gitignore"

  # ---- git repo (doctor + launch dirty-check + honest history) ----
  ( cd "$home" \
    && git init -q \
    && git add -A \
    && git -c user.name=grandma -c user.email=grandma@local commit -qm "fixture: seed memory home" \
  ) >/dev/null 2>&1
}

# make_fake_gh <bindir> <fake_github_dir> <login> — write a `gh` shim that stands in for GitHub
# with a folder of BARE git repos, so the knit share/pull round trip runs end to end with no
# network and no production backdoor (the engine only ever calls real gh verbs).
#   gh auth status                                  -> ok
#   gh api user --jq .login                         -> <login>
#   gh api /user/repository_invitations [--jq ...]  -> the JSON in <fake_github_dir>/invitations.json
#   gh api --method PATCH /user/repository_invitations/<id> -> records the id in accepted.log
#   gh api --method PUT repos/<o>/<r>/collaborators/<u>     -> records the invite in invites.log
#   gh api /user/repos [--jq ...]                   -> every bare repo, with owner.login
#   gh repo view <owner>/<name>                     -> 0 only if the bare repo exists
#   gh repo create <owner>/<name> --private         -> git init --bare
#   gh repo clone <owner>/<name> <dir>              -> git clone from the bare repo
# Set GH_FAKE_ROOT=<fake_github_dir> in the environment of anything using this shim.
make_fake_gh() {
  local dir="$1" ghroot="$2" login="$3"
  mkdir -p "$dir" "$ghroot"
  printf '[]\n' > "$ghroot/invitations.json"
  cat > "$dir/gh" <<SHIM
#!/usr/bin/env bash
R="\${GH_FAKE_ROOT:-$ghroot}"
LOGIN="\${GH_FAKE_LOGIN:-$login}"
case "\$1 \${2:-}" in
  "auth status") exit 0 ;;
esac
if [ "\$1" = "api" ]; then
  shift
  method=GET; target=""; jqexpr=""; inm=""; incl=0
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --method) method="\$2"; shift 2 ;;
      --jq) jqexpr="\$2"; shift 2 ;;
      -H) case "\$2" in "If-None-Match: "*) inm="\${2#If-None-Match: }" ;; esac; shift 2 ;;
      -i) incl=1; shift ;;
      -f) shift 2 ;;
      *) [ -z "\$target" ] && target="\$1"; shift ;;
    esac
  done
  case "\$method:\$target" in
    GET:user) [ "\$jqexpr" = ".login" ] && echo "\$LOGIN" || echo "{\"login\":\"\$LOGIN\"}"; exit 0 ;;
    GET:/user/repository_invitations)
      # ETag is the content hash, so an unchanged list answers 304 exactly like GitHub does
      tag=\$(cksum < "\$R/invitations.json" | tr -d " ")
      echo "\$(date +%s)" >> "\$R/api-calls.log"
      if [ -n "\$inm" ] && [ "\$inm" = "W/\"\$tag\"" ]; then
        echo "\$(date +%s)" >> "\$R/api-304.log"
        [ "\$incl" = 1 ] && printf 'HTTP/2.0 304 Not Modified\\r\\n\\r\\n'
        exit 1
      fi
      if [ "\$incl" = 1 ]; then
        printf 'HTTP/2.0 200 OK\\r\\nETag: W/"%s"\\r\\n\\r\\n' "\$tag"
        cat "\$R/invitations.json"; exit 0
      fi
      if [ -n "\$jqexpr" ]; then jq -r "\$jqexpr" < "\$R/invitations.json"; else cat "\$R/invitations.json"; fi; exit 0 ;;
    GET:/user/repos*)
      out=""
      for d in "\$R"/*/*.git; do
        [ -d "\$d" ] || continue
        o=\$(basename "\$(dirname "\$d")"); n=\$(basename "\$d" .git)
        out="\$out{\"name\":\"\$n\",\"full_name\":\"\$o/\$n\",\"owner\":{\"login\":\"\$o\"}},"
      done
      printf '[%s]\n' "\${out%,}" | { [ -n "\$jqexpr" ] && jq -r "\$jqexpr" || cat; }; exit 0 ;;
    PATCH:/user/repository_invitations/*)
      echo "\${target##*/}" >> "\$R/accepted.log"; exit 0 ;;
    PUT:repos/*/collaborators/*)
      echo "\$target" >> "\$R/invites.log"; exit 0 ;;
  esac
  exit 1
fi
if [ "\$1" = "repo" ]; then
  case "\$2" in
    view)   [ -d "\$R/\$3.git" ] && exit 0 || exit 1 ;;
    create) mkdir -p "\$(dirname "\$R/\$3.git")" && git init -q --bare "\$R/\$3.git" && exit 0 || exit 1 ;;
    clone)  git clone -q "\$R/\$3.git" "\$4" 2>/dev/null && exit 0 || exit 1 ;;
  esac
fi
exit 1
SHIM
  chmod +x "$dir/gh"
  printf '%s' "$dir/gh"
}

# fake_gh_invitations <fake_github_dir> <id:inviter:full_name>... — queue SEVERAL pending
# invitations at once. Needed to exercise deduplication: a list that changes while still
# containing something already announced is the only case where dedup does any work.
fake_gh_invitations() {
  local ghroot="$1"; shift
  local out="" spec id inviter full
  for spec in "$@"; do
    id="${spec%%:*}"; spec="${spec#*:}"; inviter="${spec%%:*}"; full="${spec#*:}"
    out="$out{\"id\":$id,\"inviter\":{\"login\":\"$inviter\"},\"repository\":{\"name\":\"${full#*/}\",\"full_name\":\"$full\"}},"
  done
  printf '[%s]\n' "${out%,}" > "$ghroot/invitations.json"
}

# fake_gh_invitation <fake_github_dir> <id> <inviter> <full_name> — queue a pending repository
# invitation for the shim to serve (the shape `gh api /user/repository_invitations` returns).
fake_gh_invitation() {
  local ghroot="$1" id="$2" inviter="$3" full="$4"
  printf '[{"id":%s,"inviter":{"login":"%s"},"repository":{"name":"%s","full_name":"%s"}}]\n' \
    "$id" "$inviter" "${full#*/}" "$full" > "$ghroot/invitations.json"
}

# make_fake_transcript <path> — a minimal Claude .jsonl that both save.sh (jq) and watch.sh
# (python metrics) parse: 2 user turns, 1 assistant turn with usage + a tool_use, timestamps.
make_fake_transcript() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JSONL'
{"type":"user","timestamp":"2026-06-15T10:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"how do I run the billing migration?"}]}}
{"type":"assistant","timestamp":"2026-06-15T10:00:05.000Z","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":120,"output_tokens":80,"cache_read_input_tokens":10,"cache_creation_input_tokens":5},"content":[{"type":"text","text":"Use atlas, never yarn."},{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","timestamp":"2026-06-15T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"thanks"}]}}
JSONL
}

# seed_claude_project <home_for_HOME> <munged_project_name> <session_id> — place a fake
# transcript where watch's find_transcripts looks ($HOME/.claude/projects/<name>/<id>.jsonl).
# The munged name should contain the intended --scope substring (e.g. contains "acme").
# Echoes the transcript path.
seed_claude_project() {
  local h="$1" name="$2" sid="$3" path
  path="$h/.claude/projects/$name/$sid.jsonl"
  make_fake_transcript "$path"
  printf '%s' "$path"
}
