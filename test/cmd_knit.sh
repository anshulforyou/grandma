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
# Someone else's memory is the thing you want to read on its own, so pull names THAT file
# rather than sending you to `grandma review`, which buries it among your own distills.
assert_contains "review --apply" "points at the share that just arrived"
assert_contains "home-ops-knit-yard-" "naming that exact proposal file"
assert_not_contains "review them: grandma review" "not at the whole proposal queue"
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
assert_contains "review --apply" "the receiver is pointed at the updated share itself"

section "pull — two shares at once are each offered separately"
# Its own fake GitHub: the discovery step legitimately clones every knit repo the account can
# reach, so sharing the main one would fold in every repo the earlier sections created.
H10="$TMP/home10"; make_fixture_home "$H10"
GH2="$TMP/gh2"; mkdir -p "$GH2"; printf '[]\n' > "$GH2/invitations.json"
git init -q --bare "$GH2/two/grandma-knit-yard.git"
W="$TMP/twowork"; rm -rf "$W"; git clone -q "$GH2/two/grandma-knit-yard.git" "$W"
mkdir -p "$W/shares"
for who in ana bo; do
  printf -- '---\nknit: 1\nproject: Yard\nfrom: %s\nshared: 2026-07-29\n---\n\n- %s knows the gate sticks\n' \
    "$who" "$who" > "$W/shares/$who.md"
done
git -C "$W" add -A >/dev/null 2>&1
git -C "$W" -c user.name=t -c user.email=t@e commit -qm two >/dev/null 2>&1
git -C "$W" push -q origin HEAD >/dev/null 2>&1
capture env GRANDMA_HOME="$H10" GH_FAKE_ROOT="$GH2" GH_FAKE_LOGIN=mate "$GBIN" knit pull
assert_rc 0 "pull with two shares runs"
assert_contains "2 new share(s)" "it counts both"
assert_contains "Read each on its own" "and offers them separately"
n=$(printf '%s' "$LAST_OUT" | grep -c "review --apply")
[ "$n" = "2" ] && ok "one review command per share, not one for the pile" \
               || fail "expected 2 review commands, got $n"

fake_gh_invitation "$GHROOT" 4242 testuser "testuser/grandma-knit-yard"   # restore shared state

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

section "pull — a repo you already have access to is picked up, not just pending invitations"
# The ordinary case, not an edge one: the invitation email has an Accept button, and clicking
# it consumes the invitation. Without this, the share is invisible and nothing says why.
H4="$TMP/home4"; make_fixture_home "$H4"
printf '[]\n' > "$GHROOT/invitations.json"          # nothing pending: accepted on github.com
capture env GRANDMA_HOME="$H4" GH_FAKE_LOGIN=mate "$GBIN" knit pull
assert_rc 0 "pull runs with no pending invitation"
assert_contains "you already had access" "it finds the repo anyway"
assert_contains "proposal from" "and the share still lands as a proposal"
n="$(ls -1 "$H4/proposals/"*knit*.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] && ok "the teammate's memory is reviewable" || fail "no knit proposal landed"
fake_gh_invitation "$GHROOT" 4242 testuser "testuser/grandma-knit-yard"   # restore shared state

section "knit — an unwritable .gitignore is silent, not noisy on every tick"
# A failing redirect is reported by the shell, not the command, so `2>/dev/null` on the
# printf does not silence it. On a home the process cannot write, that put "Operation not
# permitted" in the log once every 60 seconds for a case that is already handled.
HRO="$TMP/readonly"; make_fixture_home "$HRO"
grep -v '^\.knit' "$HRO/.gitignore" > "$HRO/.gitignore.tmp" && mv "$HRO/.gitignore.tmp" "$HRO/.gitignore"
chmod a-w "$HRO/.gitignore"
capture env GRANDMA_HOME="$HRO" "$GBIN" knit contacts
assert_rc 0 "knit still runs with an unwritable .gitignore"
assert_not_contains "Operation not permitted" "no permission error is printed"
assert_not_contains "Permission denied" "nor the other wording"
chmod u+w "$HRO/.gitignore"

section "knit — the memory home keeps share clones out of its history"
capture cat "$H/.gitignore"
assert_contains ".knit/" "the working copies are gitignored"
capture env GRANDMA_HOME="$H" "$GBIN" test home-ops
assert_rc 0 "the integrity invariants still pass with knit in use"
assert_contains "knit guarded" "the knit invariant runs"

# ------------------------------------------------------------- no gh ----------
section "gh not signed in — explained and offered, not a dead end"
# For someone who has never used gh, "no usable gh CLI" names a tool they have not heard of
# and stops. It has to say what is missing, why knit needs it, and offer to fix it.
BADBIN="$TMP/badbin"; mkdir -p "$BADBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BADBIN/gh"; chmod +x "$BADBIN/gh"
capture env GRANDMA_HOME="$H" PATH="$BADBIN:$PATH" "$GBIN" knit share home-ops yard --to mate --yes
assert_rc 1 "share stops when gh cannot be used"
assert_contains "YOUR OWN GitHub" "it explains why knit needs GitHub at all"
assert_contains "no grandma server" "and that there is no service in the middle"
assert_contains "gh auth login" "and gives the exact command to sign in"
capture env GRANDMA_HOME="$H" PATH="$BADBIN:$PATH" "$GBIN" knit pull
assert_rc 1 "pull stops too"
assert_contains "gh auth login" "with the same guidance"
assert_contains "--file" "and the no-GitHub escape hatch is still offered"

section "gh setup — a dry run offers nothing and installs nothing"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 PATH="$BADBIN:$PATH" "$GBIN" knit pull
assert_contains "would offer to run: gh auth login" "a dry run only says what it would do"

section "gh missing entirely — explained, and the install command named for this machine"
# PATH is narrowed to nothing but the few externals the check itself needs, so `gh` is
# genuinely absent whatever the host (it is in /usr/bin on CI, elsewhere on macOS).
EMPTY="$TMP/emptybin"; mkdir -p "$EMPTY"
for t in uname brew apt-get dnf pacman zypper; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$EMPTY/$t" 2>/dev/null
done
# extract the functions FIRST, while sed is still reachable
sed -n '/^gh_install_cmd()/,/^}/p;/^knit_explain_gh()/,/^}/p;/^knit_require_gh()/,/^}/p' \
  "$ENGINE/lib/grandma-knit.sh" > "$TMP/ghfn.sh"
capture env PATH="$EMPTY" /bin/bash -c '
  say() { printf "  %s\n" "$1" >&2; }
  dry() { return 1; }
  . "'"$TMP"'/ghfn.sh"
  knit_require_gh </dev/null; echo "rc=$?"'
assert_contains "YOUR OWN GitHub" "a missing gh is explained the same way"
assert_contains "not installed" "it says the CLI is missing"
assert_contains "rc=1" "and stops rather than proceeding without it"

# ------------------------------------------------------------- contacts -------
section "contacts — the book starts empty and explains itself"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts
assert_rc 0 "'knit contacts' runs on an empty book"
assert_contains "none yet" "says the book is empty"
assert_contains "contacts add" "and shows how to add someone"

section "contacts — add, list, and share by NAME instead of a handle"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts add Priyansh priyansh-gh priyansh@example.com
assert_rc 0 "adding a contact runs"
assert_contains "Priyansh -> priyansh-gh" "reports what was saved"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts
assert_contains "Priyansh" "the book lists the name"
assert_contains "priyansh-gh" "and the handle that makes an invite work"
assert_contains "priyansh@example.com" "and the email, for the --file handover"

# The point of the whole feature: type the name, grandma supplies the handle.
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to Priyansh
assert_rc 0 "sharing to a saved NAME runs"
assert_contains "Priyansh -> priyansh-gh" "the name resolves from the contact book"
assert_contains "would invite:              priyansh-gh" "and the invite targets the handle, not the name"

capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to PRIYANSH
assert_contains "would invite:              priyansh-gh" "name matching is case-insensitive"

section "contacts — a non-email in the email field is refused, not stored"
# Found in real use: the prompt was ambiguous enough that a message got typed where an
# address belonged, and it was stored without complaint. Garbage in that column is not
# harmless, since --to matches on it.
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts add Someone someone-gh "this is a message not an email"
assert_rc 1 "adding a non-email is refused"
assert_contains "is not an email address" "and says why"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts
assert_not_contains "this is a message" "nothing was stored"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts add Someone someone-gh someone@example.com
assert_rc 0 "a real address is accepted"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts
assert_contains "someone@example.com" "and stored"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts remove Someone
assert_rc 0 "cleanup"

section "contacts — a saved EMAIL resolves too, without asking GitHub anything"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to priyansh@example.com
assert_rc 0 "sharing to a saved contact's email runs"
assert_contains "priyansh@example.com -> priyansh-gh" "the address resolves from your own book"
assert_contains "would invite:              priyansh-gh" "and the invite still targets the handle"

section "contacts — an unknown email explains itself instead of failing at GitHub"
# GitHub can only match an address the person made PUBLIC on their profile, which most have
# not. The failure has to name the reason and the fix, not just refuse.
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to nobody@example.com
assert_rc 1 "an unresolvable address stops before anything moves"
assert_contains "public profile email" "it says WHY GitHub could not match it"
assert_contains "contacts add" "and gives the exact command to fix it"

section "contacts — an unsaved handle still works exactly as before"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to someone-else
assert_rc 0 "an unknown handle is not blocked"
assert_contains "would invite:              someone-else" "it passes through untouched"

section "contacts — a name that is neither saved nor a valid handle is refused"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to "Not A Handle"
assert_rc 1 "a typo'd name does not silently become a bogus invite"
assert_contains "not a saved contact" "and says so"
assert_contains "contacts add" "pointing at how to fix it"

section "contacts — --name records the person on a real share"
capture env GRANDMA_HOME="$H" "$GBIN" knit share home-ops yard --to moksh-gh --name Moksh --yes
assert_rc 0 "sharing with --name runs"
assert_contains "saved moksh-gh as 'Moksh'" "the contact is recorded"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit share home-ops yard --to Moksh
assert_contains "would invite:              moksh-gh" "and is usable by name straight after"

section "contacts — remove"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts remove Moksh
assert_rc 0 "removing a contact runs"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts
assert_not_contains "moksh-gh" "the contact is gone"
assert_contains "Priyansh" "the others are untouched"
capture env GRANDMA_HOME="$H" "$GBIN" knit contacts remove Nobody
assert_rc 1 "removing an unknown contact fails cleanly"

section "contacts — the book is local scratch, never memory"
capture cat "$H/.gitignore"
assert_contains ".knit/" "it lives under the gitignored .knit/"
assert_file "$H/.knit/contacts.tsv" "and that is where it is written"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" knit contacts add Dry dry-gh
assert_rc 0 "a dry-run add runs"
assert_contains "would save" "and only says what it would do"
capture cat "$H/.knit/contacts.tsv"
assert_not_contains "dry-gh" "a dry run writes nothing"

# ------------------------------------------------------- the background agent -
# A job that runs every 60 seconds on someone's machine has two ways to be unacceptable:
# pinging them about the same thing forever, and piling up processes. Both are pinned here.

section "agent — repeated ticks ping ONCE per share, not once per tick"
H8="$TMP/home8"; make_fixture_home "$H8"
NB2="$TMP/notif2"; mkdir -p "$NB2"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$TMP/pings.log" > "$NB2/osascript"
chmod +x "$NB2/osascript"
: > "$TMP/pings.log"; : > "$GHROOT/api-calls.log"; : > "$GHROOT/api-304.log"
fake_gh_invitation "$GHROOT" 100 moksh "moksh/grandma-knit-sxs"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  env GRANDMA_HOME="$H8" GH_FAKE_LOGIN=me PATH="$NB2:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
done
pings=$(grep -c "shared project memory" "$TMP/pings.log" 2>/dev/null || echo 0)
[ "$pings" = "1" ] && ok "10 ticks produced exactly 1 notification" \
                   || fail "expected 1 notification from 10 ticks, got $pings"

section "agent — a tick that changes nothing costs no rate limit"
# The conditional request is what makes 60s affordable: GitHub answers 304 and does not bill
# it. Without it, a per-minute job would burn 1,440 requests a day to learn nothing.
calls=$(wc -l < "$GHROOT/api-calls.log" | tr -d ' ')
free=$(wc -l < "$GHROOT/api-304.log" | tr -d ' ')
[ "$calls" = "10" ] && ok "10 ticks made 10 requests"  || fail "expected 10 requests, got $calls"
[ "$free" = "9" ]   && ok "9 of them were free 304s (only the first did work)" \
                    || fail "expected 9 conditional 304s, got $free"

section "agent — a NEW share pings, and the one beside it is NOT re-announced"
# The case dedup actually exists for. Ticks that change nothing are already silenced by the
# 304, so the only way to exercise dedup is a list that CHANGES while still holding a share
# that was announced before: moksh stays pending, satwik arrives.
fake_gh_invitations "$GHROOT" "100:moksh:moksh/grandma-knit-sxs" "101:satwik:satwik/grandma-knit-adapter"
env GRANDMA_HOME="$H8" GH_FAKE_LOGIN=me PATH="$NB2:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
capture cat "$TMP/pings.log"
assert_contains "satwik shared project memory" "the new share is announced"
n=$(grep -c "moksh shared project memory" "$TMP/pings.log")
[ "$n" = "1" ] && ok "and moksh, still pending beside it, is NOT announced again" \
               || fail "the already-known share was re-announced ($n times total)"

section "agent — ticks cannot stack, however often they fire"
# The lock is the thing standing between a per-minute job and a pile of processes.
mkdir -p "$H8/.knit/poll.lock"
before=$(wc -l < "$GHROOT/api-calls.log" | tr -d ' ')
for _ in 1 2 3 4 5; do
  env GRANDMA_HOME="$H8" GH_FAKE_LOGIN=me PATH="$NB2:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
done
after=$(wc -l < "$GHROOT/api-calls.log" | tr -d ' ')
[ "$before" = "$after" ] && ok "5 ticks against a held lock made 0 requests and did no work" \
                         || fail "a locked-out tick still worked: $before -> $after"
rmdir "$H8/.knit/poll.lock"
env GRANDMA_HOME="$H8" GH_FAKE_LOGIN=me PATH="$NB2:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
[ "$(wc -l < "$GHROOT/api-calls.log" | tr -d ' ')" -gt "$after" ] \
  && ok "and the lock releasing is what let work resume" || fail "no work after the lock was freed"

section "agent — a tick leaves no process behind and bounds its own runtime"
SLOW2="$TMP/slow2"; mkdir -p "$SLOW2"
printf '#!/usr/bin/env bash\nsleep 120\n' > "$SLOW2/gh"; chmod +x "$SLOW2/gh"
t0=$(date +%s)
env GRANDMA_HOME="$H8" GRANDMA_KNIT_POLL_TIMEOUT=2 PATH="$SLOW2:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
el=$(( $(date +%s) - t0 ))
[ "$el" -le 8 ] && ok "a hung request was cut off after ${el}s, not left running" \
                || fail "the tick ran for ${el}s: the cap did not hold"
assert_no_file "$H8/.knit/poll.lock" "and the lock was released, so the next tick is not blocked forever"

section "agent — state files stay small no matter how many ticks run"
# A per-minute job that appends anywhere would fill a disk in a week.
for f in .knit-pending .knit-checked .knit/invitations.etag; do
  [ -f "$H8/$f" ] || continue
  sz=$(wc -c < "$H8/$f" | tr -d ' ')
  [ "$sz" -lt 4096 ] && ok "$f is ${sz} bytes after ~17 ticks (bounded)" \
                     || fail "$f grew to ${sz} bytes"
done

section "agent — a job that loads but cannot run is reported, not called installed"
# The real failure this guards: on macOS a launchd job cannot read ~/Documents without Full
# Disk Access, so it fails every tick with "Operation not permitted" while launchctl still
# reports it loaded. Claiming success there is a lie the user only finds out by never being
# notified. launchctl is stubbed so both outcomes run on any platform.
H9="$TMP/home9"; make_fixture_home "$H9"
LC="$TMP/lcbin"; mkdir -p "$LC"
cat > "$LC/launchctl" <<'LCS'
#!/usr/bin/env bash
case "$1" in
  load|unload) exit 0 ;;
  list) printf '%s\t%s\t%s\n' "-" "${FAKE_AGENT_STATUS:-0}" "com.grandma.knit" ;;
esac
exit 0
LCS
chmod +x "$LC/launchctl"
AGENTLOG="$TMP/agent.log"   # never the real one: a dev machine may have an agent using it
AGENTDIR="$TMP/LaunchAgents"; mkdir -p "$AGENTDIR"   # nor the real ~/Library/LaunchAgents
printf '/bin/bash: /x/grandma-knit.sh: Operation not permitted\n' > "$AGENTLOG"

# the job never ticks, so .knit-checked never moves
capture env GRANDMA_HOME="$H9" PATH="$LC:$PATH" FAKE_AGENT_STATUS=126 \
  GRANDMA_KNIT_AGENT_LOG="$AGENTLOG" GRANDMA_KNIT_AGENT_DIR="$AGENTDIR" \
  GRANDMA_KNIT_AGENT_INTERVAL=60 "$GBIN" knit install-agent
assert_rc 1 "a job that cannot run exits non-zero"
assert_contains "did not run" "it says the check never ran"
assert_contains "launchd exit 126" "and reports what launchd recorded"
assert_contains "Operation not permitted" "and quotes what launchd actually said"
assert_contains "macOS file protection" "and explains the cause in plain terms"
assert_contains "move the engine" "offering the simpler remedy first"
assert_contains "Full Disk Access" "and the other one"
assert_contains "has been removed" "the broken job is taken back out, not left failing every minute"
assert_no_file "$AGENTDIR/com.grandma.knit.plist" "and its plist is gone"
assert_contains "knit still checks at launch" "and it says what still works"

section "agent — a job that really ticks is reported as live"
# Same stub, but something moves the stamp the way a working tick would.
LC2="$TMP/lcbin2"; mkdir -p "$LC2"
cat > "$LC2/launchctl" <<LCS2
#!/usr/bin/env bash
case "\$1" in
  load) date +%s > "$H9/.knit-checked"; exit 0 ;;   # a working agent ticks on load
  unload) exit 0 ;;
  list) printf '%s\t%s\t%s\n' "1234" "0" "com.grandma.knit" ;;
esac
exit 0
LCS2
chmod +x "$LC2/launchctl"
printf '0\n' > "$H9/.knit-checked"
capture env GRANDMA_HOME="$H9" PATH="$LC2:$PATH" GRANDMA_KNIT_AGENT_LOG="$AGENTLOG" \
  GRANDMA_KNIT_AGENT_DIR="$AGENTDIR" GRANDMA_KNIT_AGENT_INTERVAL=60 "$GBIN" knit install-agent
assert_rc 0 "a working job exits 0"
assert_contains "is live" "and is only called live once a tick has actually happened"
assert_contains "60s" "naming the interval"
rm -f "$AGENTDIR/com.grandma.knit.plist"   # the dry-run section below asserts it writes none

section "agent — install and uninstall are opt-in and reversible"
capture env GRANDMA_HOME="$H8" GRANDMA_DRY_RUN=1 GRANDMA_KNIT_AGENT_DIR="$AGENTDIR" "$GBIN" knit install-agent
assert_rc 0 "a dry-run install runs (on any platform, not just macOS)"
assert_contains "60s" "naming the interval"
assert_no_file "$AGENTDIR/com.grandma.knit.plist" "a dry run installs nothing"
if command -v launchctl >/dev/null 2>&1; then
  assert_contains "would install" "macOS: it plans the launchd agent"
else
  assert_contains "launchd is macOS-only" "Linux: it says why there is nothing to install"
  assert_contains "would write: nothing" "and is explicit that it would write nothing"
fi
capture env GRANDMA_HOME="$H8" GRANDMA_DRY_RUN=1 GRANDMA_KNIT_AGENT_DIR="$AGENTDIR" "$GBIN" knit uninstall-agent
assert_rc 0 "a dry-run uninstall runs"
assert_contains "would unload" "and only says what it would do"
fake_gh_invitation "$GHROOT" 77 someone "someone/grandma-knit-yard"   # restore shared state

# ------------------------------------------------------- the launch poll -------
section "poll — fills the cache the launch banner reads"
H3="$TMP/home3"; make_fixture_home "$H3"
fake_gh_invitation "$GHROOT" 77 someone "someone/grandma-knit-yard"
capture env GRANDMA_HOME="$H3" GH_FAKE_LOGIN=mate "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "poll exits 0"
capture cat "$H3/.knit-pending"
assert_contains "someone shared project memory with you" "the cache holds a human line"
assert_not_contains "pull it:" "the cache holds the FACT only, not the call to action"
assert_file "$H3/.knit-checked" "the poll stamps when it last ran"

notice() {  # grandma_knit_notice on its own, under set -u, exactly as the launcher calls it
  env GRANDMA_HOME="$1" ${2:+"$2"} bash -c \
    'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$1"'"; grandma_knit_notice' 2>&1
}

section "notice — a first-time recipient is told on THIS launch, not the next one"
# The whole point of the flow: someone gets shared with, opens grandma, and is told. The poll
# is backgrounded, so the cache is written after the banner has been read — which made the one
# launch that matters to a new recipient the one that showed nothing.
H5="$TMP/home5"; make_fixture_home "$H5"
fake_gh_invitation "$GHROOT" 55 someone "someone/grandma-knit-yard"
CB2="$TMP/cbin2"; make_fake_claude "$CB2" "$TMP/launched2" >/dev/null
capture env GRANDMA_HOME="$H5" GH_FAKE_LOGIN=mate GRANDMA_NO_SPLASH=1 GRANDMA_NO_AUTOSAVE=1 \
  GRANDMA_NO_HOOK=1 PATH="$CB2:$PATH" HOME="$TMP/fh5" "$GBIN" globex
assert_rc 0 "the first launch after being invited runs"
assert_contains "someone shared project memory" "and tells them right away, on this launch"
assert_file "$H5/.knit-checked" "the check is stamped so later launches go back to the background"

section "notice — a stalled first check cannot hang the prompt"
H6="$TMP/home6"; make_fixture_home "$H6"
SLOW="$TMP/slowbin"; mkdir -p "$SLOW"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$SLOW/gh"; chmod +x "$SLOW/gh"
t0=$(date +%s)
capture env GRANDMA_HOME="$H6" GRANDMA_KNIT_FIRST_POLL_TIMEOUT=2 GRANDMA_NO_SPLASH=1 \
  GRANDMA_NO_AUTOSAVE=1 GRANDMA_NO_HOOK=1 PATH="$SLOW:$CB2:$PATH" HOME="$TMP/fh6" "$GBIN" globex
el=$(( $(date +%s) - t0 ))
assert_rc 0 "the launch still succeeds with a hanging gh"
[ "$el" -le 8 ] && ok "a dead network cost ${el}s, not a hung prompt" \
                || fail "first-poll cap did not hold: took ${el}s"

section "notice — prints the cached share, and honors its opt-out"
capture notice "$H3"
assert_rc 0 "the banner runs under set -u"
assert_contains "someone shared project memory" "launch surfaces the waiting share"
capture notice "$H3" GRANDMA_NO_KNIT_CHECK=1
assert_not_contains "someone shared" "GRANDMA_NO_KNIT_CHECK=1 silences it"

section "notice — a new share also fires a desktop notification, once"
# The banner only lands when they next open grandma. A share should reach them sooner, and
# the notification has to say what to run, since a macOS notification has no click action.
H7="$TMP/home7"; make_fixture_home "$H7"
NBIN="$TMP/notifbin"; mkdir -p "$NBIN"
# bake the absolute path in: the stub runs in its own environment, TMP is not exported
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$TMP/notified.log" > "$NBIN/osascript"
chmod +x "$NBIN/osascript"
fake_gh_invitation "$GHROOT" 77 someone "someone/grandma-knit-yard"
: > "$TMP/notified.log"
capture env GRANDMA_HOME="$H7" GH_FAKE_LOGIN=mate PATH="$NBIN:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
assert_rc 0 "the poll runs"
capture cat "$TMP/notified.log"
assert_contains "someone shared project memory" "a notification is sent for the new share"
assert_contains "grandma knit pull" "and it says exactly what to run"
assert_contains "grandma knit" "titled so it is obvious which part of grandma is talking"

n1=$(grep -c "shared project memory" "$TMP/notified.log")
capture env GRANDMA_HOME="$H7" GH_FAKE_LOGIN=mate PATH="$NBIN:$PATH" "$ENGINE/lib/grandma-knit.sh" poll
n2=$(grep -c "shared project memory" "$TMP/notified.log")
[ "$n1" = "1" ] && [ "$n2" = "1" ] && ok "the same share is not re-notified on every poll" \
  || fail "expected 1 notification across two polls, got $n1 then $n2"

section "notify_user — the command rides in the body when the notifier cannot click"
# terminal-notifier can run something on click; osascript cannot, so the body must carry it.
capture env bash -c '
  . "'"$ENGINE"'/lib/grandma-lib.sh"
  PATH="'"$NBIN"':$PATH"; GRANDMA_HOME="'"$H7"'"
  notify_user "grandma test" "something happened" "grandma do-the-thing"'
capture cat "$TMP/notified.log"
assert_contains "something happened — run: grandma do-the-thing" "the body is self-sufficient"

section "notice — throttled: a fresh check does not re-poll, a stale one does"
: > "$H3/.knit-pending"; rm -f "$H3/.knit/invitations.etag"; date +%s > "$H3/.knit-checked"
capture notice "$H3"
# a fresh cache should spawn nothing, so give a would-be poll ample time to prove it did not
wait_until 3 grep -q "someone shared" "$H3/.knit-pending" || true
capture cat "$H3/.knit-pending"
assert_not_contains "someone shared" "a fresh cache spawns no poll (nothing refilled it)"
printf '%s' "$(( $(date +%s) - 40000 ))" > "$H3/.knit-checked"
capture notice "$H3"
# the poll is BACKGROUNDED: wait for it to land rather than guessing at a fixed sleep, which
# passes on a quiet machine and fails on a loaded CI runner
wait_until 15 grep -q "someone shared" "$H3/.knit-pending"
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
: > "$H3/.knit-pending"; rm -f "$H3/.knit/invitations.etag"
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
