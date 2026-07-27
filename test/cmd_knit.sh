#!/usr/bin/env bash
# Behavioral tests for `grandma knit` — the sharing phase.
#
# What this pins, in order of how much it would hurt to get wrong:
#   1. THE STRIP. A share carries one project's memory and nothing else: not the sweater's
#      memory, not global identity, and not the personal lines inside the project file
#      (the user's name, addresses, credentials, denylisted jargon, anything marked private).
#      Absolute home paths come out as ~. This is the security-critical bit of the feature.
#   2. NOTHING GOES OUT WITHOUT A YES. A non-interactive share with no --yes must refuse and
#      leave the remote untouched.
#   3. Kebab-case survives. A share of a project under `home-ops` must produce a proposal that
#      review resolves back to `home-ops`, not `home` (the `cut -d-` bug class).
#   4. The full round trip over a FAKE GitHub (a folder of bare repos): share -> invite ->
#      accept -> pull -> proposal, then a second pull that correctly finds nothing new.
#   5. The launch poll never blocks, never spawns siblings, and fails open.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; GHROOT="$TMP/fake-github"; BIN="$TMP/bin"
export SHELL=""
make_fixture_home "$H"
make_fake_gh "$BIN" "$GHROOT" testuser >/dev/null
export PATH="$BIN:$PATH"
export GH_FAKE_ROOT="$GHROOT"

# The project memory we are going to share: a few genuinely shareable lines, and one of every
# personal signal the strip is supposed to catch.
printf 'acme-internal\n' >> "$H/denylist.txt"
cat > "$H/projects/yard/CLAUDE.md" <<EOF
# Yard

- the mower needs the choke held for ten seconds on a cold start
- irrigation zone 3 is on the same circuit as the shed, do not run both
- Test User keeps the spare key in the shed
- reach the landlord at landlord@example.com about the fence
- gate code lives at $H/projects/yard/secrets.md
- the acme-internal ticket for the fence is still open
- rent is auto-paid on the 1st <!-- private -->
<!-- knit:private -->
- the neighbour dispute is not for sharing
<!-- /knit:private -->
- compost goes out with the green bin
EOF

# ---------------------------------------------------------------- usage --------
section "knit — usage is complete (the help sed range covers every usage line)"
capture env GRANDMA_HOME="$H" "$GBIN" knit
assert_rc 2 "bare 'grandma knit' prints usage and exits 2"
assert_contains "grandma knit share" "usage names share"
capture env GRANDMA_HOME="$H" "$GBIN" knit help
assert_rc 0 "'grandma knit help' exits 0"
assert_contains "the sharing phase" "help starts at the top of the header block"
assert_contains "paste into that teammate" "help reaches the LAST usage line (range not truncated)"
capture env GRANDMA_HOME="$H" "$GBIN" help
assert_contains "grandma knit" "top-level help lists knit (its sed range was bumped too)"
assert_contains "grandma version" "top-level help still reaches the lines below knit"

# ----------------------------------------------------------------- strip -------
section "share --file — the payload is the project's memory, stripped"
SHARE="$TMP/yard.knit"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --file "$SHARE"
assert_rc 0 "share to a file runs under set -u"
assert_file "$SHARE" "the share file is written"
payload="$(cat "$SHARE" 2>/dev/null)"
# shellcheck disable=SC2034  # read by the assert helpers in test/lib/assert.sh
LAST_OUT="$payload"
# shellcheck disable=SC2034  # read by the assert helpers in test/lib/assert.sh
LAST_RC=0

assert_contains "choke held for ten seconds" "keeps the hard-won project knowledge"
assert_contains "irrigation zone 3" "keeps the second real note"
assert_contains "compost goes out" "keeps the note after the private block"
assert_not_contains "Test User" "drops the line naming the user"
assert_not_contains "landlord@example.com" "drops the line with an address"
assert_not_contains "acme-internal" "drops the line with a denylisted term"
assert_not_contains "spare key" "the dropped name line is gone whole, not just the name"
assert_not_contains "rent is auto-paid" "drops a line marked <!-- private -->"
assert_not_contains "neighbour dispute" "drops everything inside a knit:private block"
assert_not_contains "knit:private" "the block markers themselves do not travel"
assert_not_contains "$H" "no absolute home path survives"
assert_contains "project: Yard" "the header names the project so the receiver can place it"

section "share --file — sweater and global memory never ride along"
assert_not_contains "trash goes out Sunday" "the sweater's own facts stay home"
assert_not_contains "pnpm only" "global preferences stay home"
assert_not_contains "Role: engineer" "global identity stays home"

section "share --file — the user is told what was stripped"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --file "$SHARE"
assert_contains "personal line(s) stripped" "reports the strip count"
assert_not_contains " 0 personal line(s)" "and the count is not zero on a file with personal lines"

# ------------------------------------------------------------ kebab-case -------
section "pull --file — the proposal resolves back to the KEBAB sweater, not its first token"
capture env GRANDMA_HOME="$H" "$GBIN" knit pull --file "$SHARE"
assert_rc 0 "pull from a file runs"
assert_contains "proposal:" "it lands a proposal"
prop="$(ls -1 "$H/proposals/"home-ops-knit-*.md 2>/dev/null | head -1)"
if [ -n "$prop" ]; then ok "proposal is named for the kebab sweater (home-ops-knit-...)"
else fail "no home-ops-knit-* proposal in $H/proposals"; fi
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" review --apply "$(basename "${prop:-none}")"
assert_rc 0 "review can apply the knit proposal"
assert_contains "scope=home-ops" "review resolves the scope as home-ops, NOT home"
capture cat "${prop:-/dev/null}"
assert_contains "BEGIN SHARED MEMORY" "the proposal carries the shared memory verbatim"
assert_contains "do not silently overwrite" "and tells the reviewer to diff, not merge"
rm -f "$H/proposals/"home-ops-knit-*.md

# ------------------------------------------------------------- dry run ---------
section "share — GRANDMA_DRY_RUN plans the GitHub path and touches nothing"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to mate
assert_rc 0 "dry-run share runs"
assert_contains "would ensure private repo: testuser/grandma-knit-yard" "names the per-project private repo"
assert_contains "would invite:              mate" "names who would be invited"
assert_no_file "$GHROOT/testuser/grandma-knit-yard.git" "dry run created no repo"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit pull
assert_rc 0 "dry-run pull runs"
assert_contains "would accept pending" "explains what a real pull would do"

# ------------------------------------------------- nothing outward without a yes
section "share — a non-interactive share with no --yes refuses and pushes nothing"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --to mate
assert_rc 1 "share without --yes on a non-terminal exits 1"
assert_contains "re-run with --yes" "and says how to proceed once the share has been read"
assert_no_file "$GHROOT/testuser/grandma-knit-yard.git" "the remote repo was never created"

# ------------------------------------------------------------ round trip -------
section "share --yes — creates the private repo, pushes the share, invites the teammate"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --to mate --yes
assert_rc 0 "share runs end to end"
assert_contains "pushed your Yard memory to testuser/grandma-knit-yard" "reports the push"
assert_contains "invited mate" "reports the invitation"
assert_file "$GHROOT/testuser/grandma-knit-yard.git" "the private repo exists"
capture cat "$GHROOT/invites.log"
assert_contains "repos/testuser/grandma-knit-yard/collaborators/mate" "the collaborator invite really was sent"
capture env GRANDMA_HOME="$H" "$GBIN" knit list
assert_rc 0 "knit list runs"
assert_contains "grandma-knit-yard" "list shows what you share"

section "share --yes again — an unchanged share is a no-op, not an empty commit"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --yes
assert_rc 0 "re-share runs"
assert_contains "no change since your last share" "recognises there is nothing new to push"

section "pull — the receiver accepts the invitation, clones, and gets a proposal"
H2="$TMP/home2"; make_fixture_home "$H2"
fake_gh_invitation "$GHROOT" 4242 testuser "testuser/grandma-knit-yard"
capture env GRANDMA_HOME="$H2" GH_FAKE_LOGIN=mate "$GBIN" knit pull
assert_rc 0 "pull runs for the receiver"
assert_contains "accepted the invitation to testuser/grandma-knit-yard" "accepts the pending invitation"
assert_contains "proposal from testuser" "writes a proposal from the teammate's share"
assert_contains "1 new share(s)" "counts what came in"
capture cat "$GHROOT/accepted.log"
assert_contains "4242" "the invitation was accepted through the API, not just locally"
prop2="$(ls -1 "$H2/proposals/"home-ops-knit-*.md 2>/dev/null | head -1)"
if [ -n "$prop2" ]; then ok "the receiver's proposal is scoped to home-ops"
else fail "no proposal landed in $H2/proposals"; fi
capture cat "${prop2:-/dev/null}"
assert_contains "choke held for ten seconds" "the teammate's real note came through"
assert_not_contains "Test User" "and the sender's personal lines never left their machine"
capture cat "$H2/.knit/ledger.tsv"
assert_contains "testuser" "provenance is recorded in the ledger"

section "pull again — the ledger stops the same share arriving twice"
printf '[]\n' > "$GHROOT/invitations.json"
capture env GRANDMA_HOME="$H2" GH_FAKE_LOGIN=mate "$GBIN" knit pull
assert_rc 0 "second pull runs"
assert_contains "nothing new to knit in" "an unchanged share is not re-proposed"
n="$(ls -1 "$H2/proposals/"home-ops-knit-*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "1" ] && ok "still exactly one proposal" || fail "expected 1 proposal, found $n"

section "pull — a changed share does come through again"
printf -- '- the shed padlock sticks in the cold\n' >> "$H/projects/yard/CLAUDE.md"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --yes
assert_contains "pushed your Yard memory" "the sender pushes the update"
capture env GRANDMA_HOME="$H2" GH_FAKE_LOGIN=mate "$GBIN" knit pull
assert_contains "1 new share(s)" "the receiver sees the update as a new proposal"

section "knit — a home that predates knit gets the ignore rule before ANY write"
# The real case: a memory home created before knit shipped has no .knit line, and the very
# first knit write must add it. This bit on a live home once — the --file share writes a
# ledger and the launch poll writes its cache, and neither went through the GitHub path that
# used to be the only caller, so .knit/ and .knit-* sat untracked in a memory repo that is
# reviewed a diff at a time. Every writing subcommand is checked, not just share.
OLDH="$TMP/oldhome"; make_fixture_home "$OLDH"
grep -v '^\.knit' "$OLDH/.gitignore" > "$OLDH/.gitignore.tmp" && mv "$OLDH/.gitignore.tmp" "$OLDH/.gitignore"
capture cat "$OLDH/.gitignore"
assert_not_contains ".knit/" "the pre-knit home starts with no ignore rule (the fixture is set up right)"

capture env GRANDMA_HOME="$OLDH" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --file "$TMP/dry.knit"
assert_rc 0 "a dry run still runs"
capture cat "$OLDH/.gitignore"
assert_not_contains ".knit/" "a DRY RUN writes nothing, not even the ignore rule"

capture env GRANDMA_HOME="$OLDH" "$GBIN" knit share home-ops yard --file "$TMP/old.knit"
assert_rc 0 "the file share runs"
capture cat "$OLDH/.gitignore"
assert_contains ".knit/" "a --file share adds the rule (it writes a ledger, so it must)"
capture env GRANDMA_HOME="$OLDH" "$GBIN" test home-ops
assert_rc 0 "and the integrity invariants pass afterwards"

OLDH2="$TMP/oldhome2"; make_fixture_home "$OLDH2"
grep -v '^\.knit' "$OLDH2/.gitignore" > "$OLDH2/.gitignore.tmp" && mv "$OLDH2/.gitignore.tmp" "$OLDH2/.gitignore"
fake_gh_invitation "$GHROOT" 99 someone "someone/grandma-knit-yard"
capture env GRANDMA_HOME="$OLDH2" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "the background poll runs"
capture cat "$OLDH2/.gitignore"
assert_contains ".knit-pending" "the poll adds the rule too (it writes a cache into the home)"
capture env GRANDMA_HOME="$OLDH2" bash -c 'cd "$0" && git status --porcelain | grep "^??" | grep knit || true' "$OLDH2"
assert_not_contains ".knit" "and nothing knit-related shows up as untracked cruft"

section "knit — the memory home keeps share clones out of its history"
capture cat "$H/.gitignore"
assert_contains ".knit/" "the working copies are gitignored"
capture env GRANDMA_HOME="$H" "$GBIN" test home-ops
assert_rc 0 "the integrity invariants still pass with knit in use"
assert_contains "knit guarded" "the knit invariant runs"

# ------------------------------------------------------------- no gh ----------
section "no usable gh — share and pull say so and point at the file handover"
BADBIN="$TMP/badbin"; mkdir -p "$BADBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BADBIN/gh"; chmod +x "$BADBIN/gh"
capture env GRANDMA_HOME="$H" PATH="$BADBIN:$PATH" "$GBIN" knit share home-ops yard --to mate --yes
assert_rc 1 "share exits 1 when gh cannot be used"
assert_contains "--file" "and points at the file handover instead"
capture env GRANDMA_HOME="$H" PATH="$BADBIN:$PATH" "$GBIN" knit pull
assert_rc 1 "pull exits 1 when gh cannot be used"
assert_contains "--file" "and points at the file handover instead"

# ------------------------------------------------------- the launch poll -------
section "poll — fills the cache the launch banner reads"
H3="$TMP/home3"; make_fixture_home "$H3"
fake_gh_invitation "$GHROOT" 77 someone "someone/grandma-knit-yard"
capture env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "poll exits 0"
capture cat "$H3/.knit-pending"
assert_contains "someone shared project memory with you" "the cache holds a human line"
assert_contains "grandma knit pull" "and it names the command that acts on it"
assert_file "$H3/.knit-checked" "the poll stamps when it last ran"

notice() {  # grandma_knit_notice on its own, under set -u, exactly as the launcher calls it
  env GRANDMA_HOME="$1" ${2:+"$2"} bash -c \
    'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$1"'"; grandma_knit_notice' 2>&1
}

section "notice — prints the cached share, and honors its opt-out"
capture notice "$H3"
assert_rc 0 "the banner runs under set -u"
assert_contains "someone shared project memory" "launch surfaces the waiting share"
capture notice "$H3" GRANDMA_NO_KNIT_CHECK=1
assert_not_contains "someone shared" "GRANDMA_NO_KNIT_CHECK=1 silences it"

section "notice — throttled: a fresh check does not re-poll, a stale one does"
: > "$H3/.knit-pending"; date +%s > "$H3/.knit-checked"
capture notice "$H3"
sleep 1
capture cat "$H3/.knit-pending"
assert_not_contains "someone shared" "a fresh cache spawns no poll (nothing refilled it)"
printf '%s' "$(( $(date +%s) - 40000 ))" > "$H3/.knit-checked"
capture notice "$H3"
sleep 1
capture cat "$H3/.knit-pending"
assert_contains "someone shared" "a stale cache does spawn the background poll"

section "launch — a waiting share is surfaced, and the banner never breaks the launch"
CBIN="$TMP/cbin"; make_fake_claude "$CBIN" "$TMP/launched" >/dev/null
fake_gh_invitation "$GHROOT" 88 someone "someone/grandma-knit-yard"
env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
capture env GRANDMA_HOME="$H3" GRANDMA_NO_SPLASH=1 GRANDMA_NO_AUTOSAVE=1 GRANDMA_NO_HOOK=1 \
  PATH="$CBIN:$PATH" HOME="$TMP/fakehome" "$GBIN" globex </dev/null
assert_rc 0 "the session still launches with a share waiting"
assert_contains "someone shared project memory" "launch prints the waiting share"
assert_file "$TMP/launched" "and the session itself really started (the banner did not abort it)"

section "poll — a held lock stops a second poll (no siblings piling up on every launch)"
: > "$H3/.knit-pending"
mkdir -p "$H3/.knit/poll.lock"
capture env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "a locked-out poll still exits 0"
capture cat "$H3/.knit-pending"
assert_not_contains "someone shared" "and it wrote nothing while the lock was held"
rmdir "$H3/.knit/poll.lock"
capture env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
capture cat "$H3/.knit-pending"
assert_contains "someone shared" "with the lock released the same poll writes (the lock is what stopped it)"

section "poll — fails open: a broken gh leaves the last known state alone"
capture env GRANDMA_HOME="$H3" PATH="$BADBIN:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "poll exits 0 when the API call fails"
capture cat "$H3/.knit-pending"
assert_contains "someone shared" "a failed call does NOT clear the cache (no false 'nothing waiting')"
printf '[]\n' > "$GHROOT/invitations.json"
capture env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
capture cat "$H3/.knit-pending"
assert_not_contains "someone shared" "but a call that SUCCEEDS with no invitations does clear it"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_knit: PASS"; else echo "cmd_knit: $FAILS FAILURE(S)"; exit 1; fi
