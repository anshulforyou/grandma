#!/usr/bin/env bash
# Behavioral tests for scope resolution, proposal matching, and hook-command quoting.
#
# Four bugs, all found on a live memory home, none of which the suite could see before:
#
#   1. Any top-level directory resolved as a sweater, so `grandma proposals` assembled every
#      sweater's pending proposals into ONE session. Invisible to the isolation check because
#      that check only iterates list_scopes, which excludes exactly those directories.
#   2. Hook commands interpolated the scope and project raw. A project registered as
#      "yard (Back Garden)" produced a command that dies with a shell syntax error, so its
#      SessionEnd distill and PreCompact checkpoint never ran and never said so.
#   3. Proposal filenames were built from the scope AS TYPED while every reader globbed
#      case-sensitively, so `grandma Globex` wrote a proposal `grandma review globex` and the
#      launch-time review offer could not find.
#   4. Those globs matched on a bare prefix, so a sweater matched every longer sweater name:
#      reviewing `home` listed `home-ops` proposals and --clear would have deleted them.
set -uo pipefail
# Nothing here is interactive, so detach stdin: a child that reads it would otherwise block
# (or swallow the caller's input) depending on how the suite was invoked.
exec </dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; export GRANDMA_HOME="$H"; export SHELL=""
make_fixture_home "$H"

# ---------------------------------------------------------- 1. resolution ------
section "resolution — a directory that is not a sweater cannot be loaded"
mkdir -p "$H/proposals" "$H/watches"
printf '# p\n# scope=globex\n\ntarget: globex/facts.md | action: append | text: from globex\n' > "$H/proposals/globex-aaa.md"
printf '# p\n# scope=home-ops\n\ntarget: home-ops/facts.md | action: append | text: from home-ops\n' > "$H/proposals/home-ops-bbb.md"

capture env GRANDMA_DRY_RUN=1 "$GBIN" proposals
assert_rc 2 "'grandma proposals' is refused, not loaded as a sweater"
assert_not_contains "memory: proposals loaded" "it never assembles a bundle"
assert_not_contains "BEGIN proposals/" "and no other sweater's content rides along"
assert_contains "grandma reserves" "and it says why rather than erroring cryptically"

capture env GRANDMA_DRY_RUN=1 "$GBIN" watches
assert_rc 2 "'grandma watches' is refused too"
assert_not_contains "memory: watches loaded" "and assembles nothing"

capture env "$ENGINE/lib/assemble.sh" proposals
assert_not_contains "BEGIN proposals/" "assemble refuses the same name (no cross-sweater bundle)"

section "resolution — real sweaters still resolve, in any case"
for name in globex GLOBEX home-ops HOME-OPS; do
  capture env GRANDMA_DRY_RUN=1 "$GBIN" "$name"
  assert_rc 0 "'$name' still launches"
  assert_contains "memory:" "and assembles a bundle"
done

# ------------------------------------------------ 3 + 4. proposal matching -----
section "proposals — a sweater sees its own, whatever case was typed"
rm -f "$H/proposals/"*.md
printf '# p\n# scope=globex\n\ntarget: globex/facts.md | action: append | text: x\n' > "$H/proposals/globex-ccc.md"
capture env "$GBIN" review GLOBEX
assert_rc 0 "review runs with a differently-cased name"
assert_contains "globex-ccc.md" "the proposal is found regardless of the case typed"
capture env GRANDMA_DRY_RUN=1 "$GBIN" GLOBEX
assert_contains "pending proposal" "and the launch-time review offer sees it too"

section "proposals — saving under a differently-cased name stays findable"
# The round trip that used to break: save as typed, read back lowercased.
printf '# p\n# scope=globex\n\ntarget: globex/facts.md | action: append | text: y\n' > "$H/proposals/$(env GRANDMA_HOME="$H" bash -c '. '"$ENGINE"'/lib/grandma-lib.sh; ROOT="'"$H"'"; canonical_scope GLOBEX')-ddd.md"
assert_file "$H/proposals/globex-ddd.md" "canonical_scope lowercases to the sweater's own spelling"

section "proposals — one sweater never sees a longer-named sweater's proposals"
rm -f "$H/proposals/"*.md
printf '# p\n# scope=home-ops\n\ntarget: home-ops/facts.md | action: append | text: kebab canary\n' > "$H/proposals/home-ops-eee.md"
capture env "$GBIN" review home
assert_rc 0 "reviewing a shorter name runs"
assert_not_contains "home-ops-eee.md" "'home' does NOT match 'home-ops' proposals"
capture env "$GBIN" review home-ops
assert_contains "home-ops-eee.md" "but home-ops finds its own"

section "proposals — a headerless proposal does not blank out the whole listing"
# Matching on the `# scope=` header means grep exits 1 on a hand-written proposal that has
# none, and every caller runs under `set -euo pipefail`, so an unguarded read there aborts
# the listing and the sweater looks like it has nothing pending. Order matters: the
# headerless file has to sort BEFORE the real one to reproduce it.
printf '# grandma memory proposal\ntarget: home-ops/facts.md | action: append | text: no header here\n' \
  > "$H/proposals/aaa-headerless.md"
capture env "$GBIN" review home-ops
assert_rc 0 "review still runs with a headerless proposal sitting in the directory"
assert_contains "home-ops-eee.md" "the real proposal is still found (the listing did not abort)"
capture env GRANDMA_DRY_RUN=1 "$GBIN" home-ops
assert_contains "pending proposal" "and the launch offer still sees it under set -e"
rm -f "$H/proposals/aaa-headerless.md"

section "proposals — --clear only deletes the named sweater's proposals"
printf '# p\n# scope=globex\n\ntarget: globex/facts.md | action: append | text: keep me\n' > "$H/proposals/globex-fff.md"
capture env "$GBIN" review --clear home
assert_rc 0 "clearing a non-matching prefix runs"
assert_file "$H/proposals/home-ops-eee.md" "'--clear home' did NOT delete home-ops proposals"
assert_file "$H/proposals/globex-fff.md" "and left the other sweater alone"
capture env "$GBIN" review --clear home-ops
assert_no_file "$H/proposals/home-ops-eee.md" "clearing the real name does delete them"
assert_file "$H/proposals/globex-fff.md" "still only that sweater's"

# --------------------------------------------------- 2. hook quoting ----------
section "hooks — a project name with spaces and parentheses produces a runnable command"
# The live failure: a catalog heading like "yard (Back Garden)" wrote an unquoted command
# that every session died on with `syntax error near unexpected token '('`.
PROJ="$H/projects/yard"
sed -i.bak 's/^## Yard$/## yard (Back Garden)/' "$H/home-ops/projects.md" && rm -f "$H/home-ops/projects.md.bak"
CBIN="$TMP/cbin"; make_fake_claude "$CBIN" "$TMP/launched" >/dev/null
capture env GRANDMA_HOME="$H" GRANDMA_NO_SPLASH=1 PATH="$CBIN:$PATH" HOME="$TMP/fh" "$GBIN" home-ops yard </dev/null
assert_rc 0 "a launch into the awkwardly-named project runs"
CFG="$PROJ/.claude/settings.local.json"
assert_file "$CFG" "hooks were installed"
bad=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  bash -n -c "$c" 2>/dev/null || { bad=1; echo "         | unrunnable: $c"; }
done < <(jq -r '.hooks[]?[].hooks[].command' "$CFG" 2>/dev/null)
[ "$bad" = 0 ] && ok "every installed hook command parses in a shell" \
               || fail "an installed hook command is a shell syntax error"
capture jq -r '.hooks.SessionEnd[0].hooks[0].command' "$CFG"
assert_contains "Back" "the project name survives into the command"

section "hooks — re-launching replaces a stale command, never stacks a second one"
# Deciding 'already installed' by exact string match left a BROKEN command in place and
# added a correct one beside it, so the broken one kept firing.
python3 - "$CFG" "$ENGINE" <<'PY'
import json, sys
cfg, engine = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
d["hooks"]["SessionEnd"] = [{"matcher": "", "hooks": [{"type": "command",
  "command": f"{engine}/lib/grandma-session-end.sh home-ops yard (Back Garden)", "async": True, "timeout": 600}]}]
json.dump(d, open(cfg, "w"))
PY
capture env GRANDMA_HOME="$H" GRANDMA_NO_SPLASH=1 PATH="$CBIN:$PATH" HOME="$TMP/fh" "$GBIN" home-ops yard </dev/null
assert_rc 0 "the repair launch runs"
n="$(jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | contains("grandma-session-end.sh"))] | length' "$CFG" 2>/dev/null)"
[ "$n" = "1" ] && ok "exactly one session-end hook remains (the broken one was replaced)" \
               || fail "expected 1 session-end hook, found $n (a stale broken command survived)"
capture jq -r '.hooks.SessionEnd[].hooks[].command' "$CFG"
bad=0
while IFS= read -r c; do [ -n "$c" ] && { bash -n -c "$c" 2>/dev/null || bad=1; }; done \
  < <(jq -r '.hooks.SessionEnd[].hooks[].command' "$CFG" 2>/dev/null)
[ "$bad" = 0 ] && ok "and what remains is runnable" || fail "a broken command survived the relaunch"

section "hooks — pruning a stale grandma entry never touches the user's own hooks"
# The prune is the risky half of the fix: it edits a file the user also owns. Too broad and
# it silently deletes their hooks. Their entries must survive, both a sibling inside the same
# group and an unrelated event.
FCFG="$TMP/foreign/.claude/settings.local.json"; mkdir -p "$(dirname "$FCFG")"
python3 - "$FCFG" "$ENGINE" <<'PY'
import json, sys
cfg, engine = sys.argv[1], sys.argv[2]
json.dump({"hooks": {
  "SessionEnd": [{"matcher": "", "hooks": [
      {"type": "command", "command": "/usr/local/bin/my-own-notify.sh done", "timeout": 10},
      {"type": "command", "command": f"{engine}/lib/grandma-session-end.sh home-ops yard (Back Garden)",
       "async": True, "timeout": 600}]}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [
      {"type": "command", "command": "/usr/local/bin/audit.sh", "timeout": 5}]}]}}, open(cfg, "w"))
PY
capture env GRANDMA_HOME="$H" bash -c '
  . "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$H"'"
  s="$ENGINE/lib/grandma-session-end.sh"
  install_hook "'"$FCFG"'" SessionEnd "" "$s" "$(hook_cmd "$s" home-ops "yard (Back Garden)")" 600 1'
assert_rc 0 "installing over a config with foreign hooks succeeds"
capture jq -r '.hooks.PreToolUse[].hooks[].command' "$FCFG"
assert_contains "/usr/local/bin/audit.sh" "an unrelated event's hooks are untouched"
capture jq -r '.hooks.SessionEnd[].hooks[].command' "$FCFG"
assert_contains "/usr/local/bin/my-own-notify.sh" "a foreign hook sharing the group survives"
n="$(jq -r '[.hooks.SessionEnd[].hooks[] | select(.command | contains("grandma-session-end.sh"))] | length' "$FCFG")"
[ "$n" = "1" ] && ok "the stale grandma entry was replaced, not duplicated" \
               || fail "expected 1 grandma session-end hook, found $n"
capture jq -r '.hooks.SessionEnd[].hooks[] | select(.command | contains("grandma-session-end.sh")) | .command' "$FCFG"
assert_contains "Back" "and the replacement carries the quoted project name"

# ------------------------------------------------- 4. reserved sweater names ---
section "naming — a reserved name is refused at the real call site, not just in the helper"
# scope_name_is_reserved is unit-tested below, but a check nothing calls is not a check.
# The refusal happens BEFORE the terminal branch, so it is reachable without a pty and a
# script gets the same answer a person does.
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" proposals
assert_rc 2 "'grandma proposals' exits 2 instead of offering to knit it"
assert_contains "grandma reserves" "and says why it is refused"
assert_no_file "$H/writing" "no sweater directory was created"

# The names grandma's own docs hand people as examples MUST still work. The first cut of this
# check scanned the engine source and refused all of these, which would have been worse than
# the latent problem it was guarding against.
for name in job-search work personal home client acme reddit side-projects; do
  capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" "$name" </dev/null
  assert_rc 1 "'$name' is NOT refused (it reaches the normal unknown-sweater path)"
  assert_contains "no sweater" "and gets the usual knit-it message"
done

section "naming — a folder with no scope: frontmatter is explained, not silently hidden"
# Resolution now goes through list_scopes, which requires frontmatter. A folder that lacks it
# used to resolve; now it does not. Someone whose files are sitting right there must be told
# why, not offered to knit a sweater that looks like it already exists.
mkdir -p "$H/legacy"
printf '# legacy facts\n- notes with no frontmatter\n' > "$H/legacy/facts.md"
capture env GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 "$GBIN" legacy </dev/null
assert_rc 1 "a frontmatter-less folder does not launch"
assert_contains "no file in it carries" "it explains that frontmatter is missing"
assert_contains "scope: legacy" "and names the exact line to add"
assert_not_contains "knit it now" "it does NOT offer to knit over existing files"
rm -rf "$H/legacy"

section "naming — a sweater named after an engine word is refused up front"
for name in watch review proposals global; do
  capture env GRANDMA_HOME="$H" bash -c \
    '. "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$H"'"; scope_name_is_reserved "'"$name"'"'
  assert_rc 0 "'$name' is recognised as reserved (a subcommand, or a folder grandma owns)"
done
for name in globex home-ops acme-payments job-search work personal reddit; do
  capture env GRANDMA_HOME="$H" bash -c \
    '. "'"$ENGINE"'/lib/grandma-lib.sh"; ENGINE="'"$ENGINE"'"; ROOT="'"$H"'"; scope_name_is_reserved "'"$name"'"'
  assert_rc 1 "'$name' is allowed (a normal sweater name is not blocked)"
done

section "integrity — the suite still passes on the fixture home"
capture env GRANDMA_HOME="$H" "$GBIN" test
assert_rc 0 "grandma test passes"
assert_contains "only real sweaters resolve" "invariant 13 runs"
assert_contains "hook commands are quoted" "invariant 14 runs"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_scope: PASS"; else echo "cmd_scope: $FAILS FAILURE(S)"; exit 1; fi
