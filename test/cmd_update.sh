#!/usr/bin/env bash
# Behavioral tests for `grandma update` / `grandma version` and the stale-engine launch nudge.
#
# What this pins:
#   - version prints the VERSION file (plus the commit).
#   - update honors GRANDMA_DRY_RUN: it prints a plan and pulls NOTHING (tests never touch a network).
#   - a non-git engine copy fails cleanly (exit 1), not a crash.
#   - update always lands on master, from a branch whose remote is gone AND from one that still
#     exists while master moved on. Both used to fail: the first with git's "no such ref was
#     fetched" plus a wrong hint about local changes, the second with exit 0 and a confident
#     "already up to date" while the engine stayed a commit behind.
#   - a dirty engine is refused with a list of what it found, --force stashes it and lands anyway,
#     and an untracked scratch file is neither a blocker nor something we sweep into a stash.
#   - it refuses instead of doing damage when: local master carries its own commits (update never
#     rewrites history), the engine sits inside someone else's repo (git walks up, so a raw checkout
#     would rearrange THEIR tree), the target branch is checked out in another worktree (checkout -B
#     ignores git's own guard), or a detached HEAD holds commits nothing else points at.
#   - a stale origin/HEAD (its branch deleted upstream) still resolves to the real default branch.
#   - the launch nudge is staleness-only (no network): it fires past the threshold, stays quiet when
#     fresh, respects GRANDMA_NO_UPDATE_CHECK=1, and nudges at most once a day.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H"
export GRANDMA_HOME="$H"; export SHELL=""

section "version — prints the running engine version"
capture env "$GBIN" version
assert_rc 0 "grandma version runs"
assert_contains "grandma" "labels the output"
assert_contains "$(head -n1 "$ENGINE/VERSION")" "shows the VERSION file's number"
capture env "$GBIN" --version
assert_rc 0 "--version is the same path"

section "update — GRANDMA_DRY_RUN plans, pulls nothing, touches no network"
capture env GRANDMA_DRY_RUN=1 "$GBIN" update
assert_rc 0 "dry-run update runs and survives set -u"
assert_contains "would run" "prints the plan instead of pulling"
assert_contains "fetch --prune origin" "names the fetch it would do (pruned: a stale origin/HEAD is how update silently went nowhere)"
# The tail of that line is environment-dependent, so assert only the part that is not.
# The dry run does not fetch, so it reports what the local cache already knows: `origin/<branch>`
# when origin/HEAD resolves, and "origin's default branch" when it does not — deliberately, rather
# than naming a default the real run might disagree with. A GitHub Actions PR checkout is the
# second case (shallow, detached at refs/pull/N/merge, no origin/HEAD), while a push to master is
# the first, so asserting the slash passed on master and failed on every pull request.
assert_contains "fast-forward onto origin" "and the branch it would land on"
assert_contains "on branch" "says which branch the engine is on now"

section "update — an unknown option fails with usage, before any git work"
# DRY_RUN even though the arg loop is supposed to exit first: if that ever regresses, this test
# would otherwise fetch and change branches in the developer's own live checkout.
capture env GRANDMA_DRY_RUN=1 "$GBIN" update --nope
assert_rc 1 "an unrecognized option exits 1"
assert_contains "usage: grandma update" "prints usage"
assert_not_contains "updating grandma engine" "and stops before touching the checkout"

section "update — asking for help is not an error"
capture env GRANDMA_DRY_RUN=1 "$GBIN" update --help
assert_rc 0 "update --help exits 0"
assert_contains "usage: grandma update" "and prints the usage"

section "update — the dry-run plan says when --force would stash"
capture env GRANDMA_DRY_RUN=1 "$GBIN" update --force
assert_rc 0 "dry-run with --force runs"
assert_contains "would be stashed first" "the plan admits what --force does before it does it"

section "update — a non-git engine copy fails cleanly, does not crash"
BARE="$TMP/bare-engine"; mkdir -p "$BARE"
cp -R "$ENGINE/bin" "$ENGINE/lib" "$BARE/"
[ -f "$ENGINE/VERSION" ] && cp "$ENGINE/VERSION" "$BARE/"
capture env GRANDMA_HOME="$H" "$BARE/bin/grandma" update
assert_rc 1 "update on a non-git engine exits 1"
assert_contains "not a git checkout" "explains why (and points at reinstall)"

# ---- update against a real remote, entirely on disk. No network: "origin" is a bare clone of a
# minimal engine (bin + lib + VERSION + CHANGELOG) built under $TMP, so nothing here reads or
# writes this checkout, and the tests do not depend on which branch a developer is sitting on.
# CI runners have no git identity, so every commit and every clone gets one locally.
# gpgsign off too: a developer who signs commits globally would otherwise have every commit and
# every stash in this suite prompt for a key.
gitc() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -C "$@"; }

mini_engine() {  # $1 = dir — enough of an engine for update to be a real git checkout
  mkdir -p "$1"
  cp -R "$ENGINE/bin" "$ENGINE/lib" "$1/"
  [ -f "$ENGINE/VERSION" ] && cp "$ENGINE/VERSION" "$1/"
  # a stub CHANGELOG, not the real one: update prints its top section on success, and asserting
  # against shipped release-note prose makes these tests fail the day the notes mention a git error.
  printf '# Changelog\n\n## Unreleased\n\n- a change worth reading\n\n## 0.0.1\n\n- a previous release entry\n' > "$1/CHANGELOG.md"
  printf 'seed\n' > "$1/README.md"
}

SRC="$TMP/src"; mini_engine "$SRC"
git init -q "$SRC"
git -C "$SRC" symbolic-ref HEAD refs/heads/master   # never inherit init.defaultBranch
gitc "$SRC" add -A; gitc "$SRC" commit -q -m "the engine"
ORIGIN="$TMP/origin.git"; git clone -q --bare "$SRC" "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master

PUSH="$TMP/pusher"; git clone -q "$ORIGIN" "$PUSH"
MASTER_SHA=""; N=0
advance_master() {  # someone else's PR lands: one new commit on origin/master
  N=$((N + 1))
  gitc "$PUSH" commit -q --allow-empty -m "engine feature $N lands on master"
  gitc "$PUSH" push -q origin master
  MASTER_SHA="$(git -C "$PUSH" rev-parse HEAD)"
}

clone_engine() {  # $1 = dir, $2 = "shallow" for an install-shaped --depth 1 clone
  if [ "${2:-}" = shallow ]; then git clone -q --depth 1 "file://$ORIGIN" "$1" 2>/dev/null
  else git clone -q "$ORIGIN" "$1"; fi
  git -C "$1" config user.email t@example.com; git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false   # update's own `stash push` commits, and must not need a key
}
run_update() { capture env GRANDMA_HOME="$H" "$1/bin/grandma" update ${2:+"$2"}; }

assert_branch() { local got; got="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$got" = "$2" ]; then ok "$3"; else fail "$3 — on branch $got, expected $2" "$LAST_OUT"; fi; }
assert_at_master() { local got; got="$(git -C "$1" rev-parse HEAD 2>/dev/null)"
  if [ "$got" = "$MASTER_SHA" ]; then ok "$2"; else fail "$2 — HEAD $got is not origin/master $MASTER_SHA" "$LAST_OUT"; fi; }
assert_not_at_master() { local got; got="$(git -C "$1" rev-parse HEAD 2>/dev/null)"
  if [ "$got" = "$MASTER_SHA" ]; then fail "$2 — HEAD moved to $got"; else ok "$2"; fi; }

section "update — from a branch whose remote is gone (the merged-PR case)"
A="$TMP/gone"; clone_engine "$A"
gitc "$A" checkout -q -b feature
gitc "$A" push -q -u origin feature
gitc "$A" push -q origin --delete feature      # the PR merged and the branch was deleted
advance_master
run_update "$A"
assert_rc 0 "update succeeds instead of dying on the missing upstream"
assert_not_contains "no such ref was fetched" "no raw git failure reaches the user"
assert_not_contains "stash or reset" "does not blame local changes on a clean tree"
assert_contains "now on master" "says it moved the engine onto master"
assert_contains "checkout feature" "and how to get back to the branch"
assert_branch "$A" master "the checkout ends up on master"
assert_at_master "$A" "and at origin/master's commit"
assert_contains "a change worth reading" "shows the CHANGELOG delta it pulled in"
assert_not_contains "a previous release entry" "and stops at the previous release heading"

section "update — from a live branch while master moved on (the false 'already up to date')"
B="$TMP/behind"; clone_engine "$B"
gitc "$B" checkout -q -b feature2
gitc "$B" push -q -u origin feature2
advance_master
run_update "$B"
assert_rc 0 "update succeeds"
assert_branch "$B" master "moves off the feature branch"
assert_at_master "$B" "and takes master's new commit rather than reporting up to date"

section "update — a dirty engine is refused, and nothing is touched"
C="$TMP/dirty"; clone_engine "$C"; advance_master
printf 'local hack\n' >> "$C/README.md"
run_update "$C"
assert_rc 1 "a dirty engine exits 1"
assert_contains "uncommitted changes" "explains why it stopped"
assert_contains "README.md" "lists what it found"
assert_contains "--force" "names the escape hatch"
assert_not_at_master "$C" "HEAD did not move"
if grep -q "local hack" "$C/README.md"; then ok "the local edit is still there"; else fail "the local edit was lost"; fi

section "update --force — stashes the local work, then lands on master"
D="$TMP/force"; clone_engine "$D"; advance_master
printf 'local hack\n' >> "$D/README.md"
run_update "$D" --force
assert_rc 0 "--force updates a dirty engine"
assert_contains "stash pop" "prints the way back to the stashed work"
assert_at_master "$D" "lands on origin/master"
if git -C "$D" stash list | grep -q "grandma update"; then ok "the work sits in a named stash"; else fail "no stash was made"; fi
if grep -q "local hack" "$D/README.md"; then fail "the edit should have been stashed out of the tree"; else ok "the tree is clean again"; fi

section "update — a local master with commits of its own is refused, never rewritten"
E="$TMP/diverged"; clone_engine "$E"
gitc "$E" commit -q --allow-empty -m "a local-only engine commit"
advance_master
run_update "$E"
assert_rc 1 "a diverged local master exits 1"
assert_contains "not a fast-forward" "says it is not a fast-forward"
assert_contains "never rewrites history" "and that grandma will not rewrite history"
if git -C "$E" log --oneline -1 | grep -q "a local-only engine commit"; then ok "the local commit survives"; else fail "the local commit was discarded"; fi

section "update — an install-shaped shallow clone still updates"
# A smoke case, not a regression guard: it passes on the old code too. It is here because
# install.sh clones with --depth 1, which is single-branch, and that is the shape real users run.
F="$TMP/shallow"; clone_engine "$F" shallow
advance_master
run_update "$F"
assert_rc 0 "a --depth 1 clone (what install.sh makes) updates"
assert_at_master "$F" "and reaches origin/master"

section "update — an engine sitting INSIDE someone else's repo is refused, not fast-forwarded"
# engine_is_git asks git, and git walks up. A plain copy of the engine dropped into another repo
# (a zip download, or a $HOME that is a dotfiles repo) answers yes, and update would then fetch and
# switch branches in THAT repo, rearranging a working tree that has nothing to do with grandma.
U="$TMP/userrepo"; mini_engine "$U/vendor/engine"
git init -q "$U"; git -C "$U" symbolic-ref HEAD refs/heads/main
printf 'theirs\n' > "$U/THEIRS.md"; gitc "$U" add -A; gitc "$U" commit -q -m theirs
gitc "$U" checkout -q -b experiment
printf 'wip\n' > "$U/EXPERIMENT.md"; gitc "$U" add -A; gitc "$U" commit -q -m wip
capture env GRANDMA_HOME="$H" "$U/vendor/engine/bin/grandma" update
assert_rc 1 "an engine inside another repo exits 1"
assert_contains "not the root of a git checkout" "says what is wrong"
assert_contains "$U" "and names the repo it would have touched"
assert_branch "$U" experiment "leaves the other repo on its own branch"
assert_file "$U/EXPERIMENT.md" "and leaves its uncommitted-branch work in the tree"

section "update — a stale origin/HEAD (default branch deleted upstream) still lands on master"
# origin/HEAD is written once at clone time and a plain fetch never revisits it, so without --prune
# plus a set-head refresh this pointed at a dead branch and update reported "already up to date"
# forever while sitting a commit behind.
G="$TMP/stalehead"; clone_engine "$G"
gitc "$G" checkout -q -b trunk; gitc "$G" push -q -u origin trunk
git -C "$G" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
gitc "$G" push -q origin --delete trunk
advance_master
run_update "$G"
assert_rc 0 "a stale default-branch symref does not stop the update"
assert_branch "$G" master "it falls through to the real default branch"
assert_at_master "$G" "and takes master's commit"

section "update — the target branch checked out in another worktree is refused"
# git refuses `checkout <branch>` when another worktree holds it, but NOT `checkout -B`, which
# would leave two worktrees claiming one branch and the other one's index reading as a staged
# revert. CLAUDE.md tells maintainers to use worktrees, so this is a real workflow.
W="$TMP/wt"; clone_engine "$W"; gitc "$W" checkout -q -b side
git -C "$W" worktree add -q "$TMP/wt-master" master
advance_master
run_update "$W"
assert_rc 1 "a branch held by another worktree exits 1"
assert_contains "another worktree" "explains the collision"
assert_branch "$W" side "the updating checkout stays put"
if [ -z "$(git -C "$TMP/wt-master" status --porcelain)" ]; then ok "the other worktree is left clean"
else fail "the other worktree was corrupted: $(git -C "$TMP/wt-master" status --porcelain)"; fi

section "update — a detached HEAD holding its own commits is refused, and the sha is named"
D2="$TMP/detached"; clone_engine "$D2"
gitc "$D2" checkout -q --detach
gitc "$D2" commit -q --allow-empty -m "a bisect commit"
DSHA="$(git -C "$D2" rev-parse HEAD)"
advance_master
run_update "$D2"
assert_rc 1 "a detached HEAD with unreachable work exits 1"
assert_contains "detached HEAD" "says where the engine is"
assert_contains "${DSHA:0:12}" "and names the commit so it can be kept"
if [ "$(git -C "$D2" rev-parse HEAD)" = "$DSHA" ]; then ok "the commit is still checked out, not orphaned"
else fail "HEAD moved off the detached commit"; fi

section "update — an untracked scratch file does not block the update"
# Only TRACKED changes are at risk from landing on another branch, and git refuses the checkout
# itself if an untracked file would be overwritten. Sweeping scratch files into a stash would hide
# work the user never asked us to move.
V="$TMP/untracked"; clone_engine "$V"
printf 'notes\n' > "$V/notes-to-self.txt"
advance_master
run_update "$V"
assert_rc 0 "an untracked file alone does not stop the update"
assert_at_master "$V" "the engine still lands on master"
assert_file "$V/notes-to-self.txt" "and the scratch file is left where it was"
if [ -z "$(git -C "$V" stash list)" ]; then ok "nothing was stashed behind the user's back"
else fail "an untracked file was swept into a stash"; fi

# ---- the launch nudge: a unit test of grandma_update_notice. No launch, no network. ----
now="$(date +%s)"
notice() {  # runs grandma_update_notice against ROOT=$H, under set -u like the real launcher
  env GRANDMA_HOME="$H" bash -c \
    'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$H"'"; grandma_update_notice' 2>&1
}

section "nudge — fires when the engine is stale"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 10*86400))" > "$H/.update-state"
capture notice
assert_contains "grandma engine is" "a >1-week-old engine gets a nudge"
assert_contains "grandma update" "and it names the fix"

section "nudge — quiet when the engine is fresh"
rm -f "$H/.update-nudged"; printf '%s' "$now" > "$H/.update-state"
capture notice
assert_not_contains "grandma engine is" "a just-updated engine does not nudge"

section "nudge — GRANDMA_NO_UPDATE_CHECK=1 silences it even when stale"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 30*86400))" > "$H/.update-state"
GRANDMA_NO_UPDATE_CHECK=1 capture notice
assert_not_contains "grandma engine is" "opt-out wins over staleness"

section "nudge — at most once a day"
rm -f "$H/.update-nudged"; printf '%s' "$((now - 10*86400))" > "$H/.update-state"
capture notice; assert_contains "grandma engine is" "first launch of the day nudges"
capture notice; assert_not_contains "grandma engine is" "a second launch the same day stays quiet"

section "update — a missing memory home stamps quietly, no redirect-error leak"
capture env GRANDMA_HOME="$TMP/no-such-home" bash -c \
  'set -uo pipefail; . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$TMP"'/no-such-home"; note_engine_updated'
assert_rc 0 "note_engine_updated survives a missing home (no unbound var)"
assert_not_contains "No such file" "no redirect error leaks out"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_update: PASS"; else echo "cmd_update: $FAILS FAILURE(S)"; exit 1; fi
