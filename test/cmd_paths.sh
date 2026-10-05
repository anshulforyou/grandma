#!/usr/bin/env bash
# Behavioral test for projects registered on another machine.
#
# The catalog is synced memory, so a project's `- source:` is an absolute path from whichever
# machine registered it. On a different machine that folder does not exist, and the launcher
# used to mkdir under it for the hooks and then die on `cd`. The promise now: a per-machine map
# translates the path, grandma offers to write that map when you are standing in the project,
# and when it cannot find the project it stops before writing anything anywhere.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
export GRANDMA_HOME="$TMP/home"
# The map normally lives in the user's config dir. Point it into the sandbox so this suite can
# never write to a real one.
export GRANDMA_PATHS_FILE="$TMP/paths"
export SHELL="" GRANDMA_NO_SPLASH=1 GRANDMA_NO_AUTOSAVE=1 GRANDMA_NO_MCP=1
export GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_KNIT_CHECK=1
make_fixture_home "$GRANDMA_HOME"
# The fixture's pending proposal would make every launch offer a review first.
rm -f "$GRANDMA_HOME"/proposals/home-ops-*.md

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — hook installation needs it"
  echo; echo "cmd_paths: PASS"; exit 0
fi

# Registered on "another machine": a root that does not exist here. Kebab sweater, and a
# project name with a space, because both have broken path handling before.
OTHER="/nonexistent-grandma-otherbox/someone/code"
cat >> "$GRANDMA_HOME/home-ops/projects.md" <<EOF

## Garden Shed
- source: $OTHER/home-ops/Garden Shed/CLAUDE.md

## tool-rack
- source: $OTHER/home-ops/tool-rack/CLAUDE.md
EOF
BOX="$TMP/box/code"
mkdir -p "$BOX/home-ops/Garden Shed" "$BOX/home-ops/tool-rack" "$TMP/elsewhere" "$TMP/wrong-project"
echo "# shed" > "$BOX/home-ops/Garden Shed/CLAUDE.md"
echo "# rack" > "$BOX/home-ops/tool-rack/CLAUDE.md"
echo "# another project" > "$TMP/wrong-project/CLAUDE.md"

# A fake CLI that records the folder it was launched in.
SHIM="$TMP/bin"; mkdir -p "$SHIM"; export CWDLOG="$TMP/cwd.txt"
cat > "$SHIM/claude" <<'SHIMEOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version|-v) echo "0.0.0 (fake claude)"; exit 0 ;;
  --help) echo "  --append-system-prompt[-file] <prompt>"; exit 0 ;;
esac
pwd -P > "$CWDLOG"
exit 0
SHIMEOF
chmod +x "$SHIM/claude"
export PATH="$SHIM:$PATH"

# run_in <dir> <args...> — launch from a folder, non-interactively, capturing output and rc
# shellcheck disable=SC2034  # LAST_RC is read by assert_rc in assert.sh
run_in() { local d="$1"; shift; rm -f "$CWDLOG"; LAST_OUT="$(cd "$d" && "$GBIN" "$@" </dev/null 2>&1)"; LAST_RC=$?; }
launched_in() { cat "$CWDLOG" 2>/dev/null || echo "<not launched>"; }
other_root_untouched() {
  if [ -e "/nonexistent-grandma-otherbox" ]; then fail "$1" "something was created under the other machine's path"
  else ok "$1"; fi
}

# ---------------------------------------------------------------------------------------
section "a project that is not on this machine stops before touching anything"
run_in "$TMP/elsewhere" home-ops garden-shed
assert_rc 1 "it refuses rather than launching somewhere wrong"
assert_contains "not on this machine" "and says why"
assert_contains "$OTHER/home-ops/Garden Shed" "naming the path the catalog has"
assert_not_contains "launching Claude Code" "it stops before the launch rather than failing during it"
LAST_OUT="$(launched_in)"; assert_contains "<not launched>" "no session is started"
other_root_untouched "nothing is created under the other machine's path"
assert_no_file "$GRANDMA_PATHS_FILE" "and no map is written"

# ---------------------------------------------------------------------------------------
section "a folder with a CLAUDE.md but a different name is not taken for the project"
run_in "$TMP/wrong-project" home-ops garden-shed
assert_rc 1 "standing in another project does not launch this one there"
assert_no_file "$TMP/wrong-project/.claude" "and that project's folder is left alone"

# ---------------------------------------------------------------------------------------
section "standing in the project's folder here, it is used"
run_in "$BOX/home-ops/Garden Shed" home-ops garden-shed
assert_rc 0 "the launch goes ahead"
assert_contains "using this folder" "and says it is using this folder"
LAST_OUT="$(launched_in)"; assert_contains "$BOX/home-ops/Garden Shed" "the session runs in the folder on this machine"
assert_file "$BOX/home-ops/Garden Shed/.claude/settings.local.json" "the hooks land in that folder"
other_root_untouched "and nowhere under the other machine's path"
assert_no_file "$GRANDMA_PATHS_FILE" "without a terminal it does not write the map"

# A dry run never asks and never writes either.
LAST_OUT="$(cd "$BOX/home-ops/tool-rack" && GRANDMA_DRY_RUN=1 "$GBIN" home-ops tool-rack </dev/null 2>&1)"
assert_contains "$BOX/home-ops/tool-rack" "a dry run plans the folder on this machine"
assert_no_file "$GRANDMA_PATHS_FILE" "and writes no map"

# ---------------------------------------------------------------------------------------
section "on a terminal it offers to map the whole root, once"
if command -v python3 >/dev/null 2>&1; then
  cat > "$TMP/drive.py" <<'PY'
import os, pty, time, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.chdir(sys.argv[2]); os.execvp("bash", ["bash", "-c", sys.argv[1]])
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r: buf += os.read(fd, 65536)
        except OSError: return
pump(3.0)
try: os.write(fd, b"y\r")
except OSError: pass
pump(3.0)
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.write(buf.decode("utf-8", "replace"))
PY
  rm -f "$CWDLOG"
  RAW="$(python3 "$TMP/drive.py" "'$GBIN' home-ops garden-shed" "$BOX/home-ops/Garden Shed" 2>&1 || true)"
  LAST_OUT="$(printf '%s' "$RAW" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
  assert_contains "on another machine" "it explains the project was registered elsewhere"
  assert_contains "for every project under it" "and offers to map the root, not one project"
  LAST_OUT="$(cat "$GRANDMA_PATHS_FILE" 2>/dev/null)"
  # The shared tail (code/home-ops/Garden Shed) is stripped from both sides, leaving the roots.
  assert_contains "/nonexistent-grandma-otherbox/someone	$TMP/box" "the map holds the two roots, tab separated"
  other_root_untouched "nothing is created under the other machine's path on the way"
else
  skip "python3 missing — the interactive offer was not driven"
  printf '%s\t%s\n' "/nonexistent-grandma-otherbox/someone" "$TMP/box" > "$GRANDMA_PATHS_FILE"
fi

# ---------------------------------------------------------------------------------------
section "once mapped, every project under that root opens from anywhere"
run_in "$TMP/elsewhere" home-ops garden-shed
assert_rc 0 "the mapped project launches from an unrelated folder"
assert_not_contains "on another machine" "without asking again"
LAST_OUT="$(launched_in)"; assert_contains "$BOX/home-ops/Garden Shed" "in its folder on this machine"
run_in "$TMP/elsewhere" home-ops tool-rack
assert_rc 0 "a second project under the same root needs no mapping of its own"
LAST_OUT="$(launched_in)"; assert_contains "$BOX/home-ops/tool-rack" "and opens in its own folder"

# A project registered on THIS machine is not touched by the map.
mkdir -p "$GRANDMA_HOME/projects/yard"; echo "# yard" > "$GRANDMA_HOME/projects/yard/CLAUDE.md"
run_in "$TMP/elsewhere" home-ops yard
LAST_OUT="$(launched_in)"; assert_contains "$GRANDMA_HOME/projects/yard" "a local path is left as it is"

# ---------------------------------------------------------------------------------------
section "a prefix only matches a whole path component, and the longest one wins"
cp "$GRANDMA_PATHS_FILE" "$TMP/paths.saved"
# Alone in the map, a prefix that ends mid-name must not match. If it did, tool-rack would
# resolve to nowhereone/..., which is set up to exist so a wrong match would really launch there.
mkdir -p "$TMP/nowhereone/code/home-ops/tool-rack"; echo "# decoy" > "$TMP/nowhereone/code/home-ops/tool-rack/CLAUDE.md"
printf '%s\t%s\n' "/nonexistent-grandma-otherbox/some" "$TMP/nowhere" > "$GRANDMA_PATHS_FILE"
run_in "$TMP/elsewhere" home-ops tool-rack
LAST_OUT="$(launched_in)"; assert_not_contains "nowhereone" "a prefix ending mid-name does not match"
# The specific line comes FIRST, so a map that took the last match would get this wrong.
mkdir -p "$TMP/override/tool-rack"; echo "# rack here" > "$TMP/override/tool-rack/CLAUDE.md"
{ printf '%s\t%s\n' "/nonexistent-grandma-otherbox/someone/code/home-ops/tool-rack" "$TMP/override/tool-rack"
  printf '%s\t%s\n' "/nonexistent-grandma-otherbox/someone" "$TMP/box"; } > "$GRANDMA_PATHS_FILE"
run_in "$TMP/elsewhere" home-ops tool-rack
LAST_OUT="$(launched_in)"; assert_contains "$TMP/override/tool-rack" "the most specific mapping wins over a shorter one"
cp "$TMP/paths.saved" "$GRANDMA_PATHS_FILE"

# ---------------------------------------------------------------------------------------
section "the hook installer never creates a project folder"
# Defence in depth: whatever hands it a path, it may create .claude inside a folder that exists
# and never the folder itself.
LAST_OUT="$(bash -c '. "$1/lib/grandma-lib.sh"; install_hook "$2/.claude/settings.local.json" SessionStart compact /x/hook.sh "/x/hook.sh a" 5 0; echo "rc=$?"' _ "$ENGINE" "$TMP/missing-project" 2>&1)"
assert_contains "rc=1" "it reports that nothing was written"
assert_no_file "$TMP/missing-project" "and does not create the missing folder, even where it could"

# ---------------------------------------------------------------------------------------
section "the distill looks for this machine's transcripts"
# The CLI names its transcript folder after the folder the session ran in. Looking under the
# other machine's path finds nothing, so a session on this machine would never be learned from.
TDIR="$HOME/.claude/projects/$(printf '%s' "$BOX/home-ops/Garden Shed" | sed 's#/#-#g')"
mkdir -p "$TDIR"
printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$TDIR/abc.jsonl"
LAST_OUT="$(cd "$TMP/elsewhere" && GRANDMA_DRY_RUN=1 "$ENGINE/lib/grandma-save.sh" home-ops garden-shed --auto </dev/null 2>&1)"
assert_contains "$TDIR/abc.jsonl" "save finds the transcript under the mapped folder"
# And with no map at all, run from the project's folder the way the session-end hook runs it.
mv "$GRANDMA_PATHS_FILE" "$TMP/paths.off"
LAST_OUT="$(cd "$BOX/home-ops/Garden Shed" && GRANDMA_DRY_RUN=1 "$ENGINE/lib/grandma-save.sh" home-ops garden-shed --auto </dev/null 2>&1)"
assert_contains "$TDIR/abc.jsonl" "without a map, save finds it from the folder it runs in"
mv "$TMP/paths.off" "$GRANDMA_PATHS_FILE"

# ---------------------------------------------------------------------------------------
section "sharing a project that is not on this machine says so"
# knit reads the project's CLAUDE.md to share it. It fails here before GitHub is ever reached.
mv "$GRANDMA_PATHS_FILE" "$TMP/paths.off"
run_in "$TMP/elsewhere" knit share home-ops tool-rack --to octocat
assert_rc 1 "the share is refused"
assert_contains "not on this machine" "naming the real reason, not a missing file"
mv "$TMP/paths.off" "$GRANDMA_PATHS_FILE"

# ---------------------------------------------------------------------------------------
section "onboarding never offers a root from another machine"
rm -f "$GRANDMA_PATHS_FILE"
# Only projects from the other machine, so their common root really is that machine's path.
cp "$GRANDMA_HOME/home-ops/projects.md" "$TMP/projects.saved"
printf -- '---\nscope: home-ops\n---\n\n## tool-rack\n- source: %s/home-ops/tool-rack/CLAUDE.md\n\n## shed\n- source: %s/home-ops/shed/CLAUDE.md\n' "$OTHER" "$OTHER" > "$GRANDMA_HOME/home-ops/projects.md"
# shellcheck disable=SC2034  # assert_not_contains on the next line reads LAST_OUT
LAST_OUT="$(cd "$TMP/elsewhere" && GRANDMA_DRY_RUN=1 "$GBIN" home-ops brand-new-thing </dev/null 2>&1)"
assert_not_contains "nonexistent-grandma-otherbox" "a working root that is not on this machine is not offered"
other_root_untouched "and nothing is created there"
cp "$TMP/projects.saved" "$GRANDMA_HOME/home-ops/projects.md"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_paths: PASS"; else echo "cmd_paths: $FAILS FAILURE(S)"; exit 1; fi
