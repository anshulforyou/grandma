#!/usr/bin/env bash
# Behavioral coverage for the hookless Gemini adapter and its cleanup boundary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

GBIN="$ENGINE/bin/grandma"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home" HOME="$TMP/fakehome" SHELL="" GRANDMA_NO_SPLASH=1
make_fixture_home "$GRANDMA_HOME"

SHIM="$TMP/bin"; mkdir -p "$SHIM"
cat > "$SHIM/gemini" <<'SHIM'
#!/usr/bin/env bash
mkdir -p "$HOME/.gemini/tmp/fake-project/chats"
printf '%s\n' '{"id":"u1","timestamp":"2026-07-17T00:00:00Z","type":"user","content":[{"text":"remember this"}]}' > "$HOME/.gemini/tmp/fake-project/chats/session-test.json"
printf '%s\n' '{"id":"a1","timestamp":"2026-07-17T00:00:01Z","type":"gemini","content":[{"text":"understood"}]}' >> "$HOME/.gemini/tmp/fake-project/chats/session-test.json"
printf 'distilling=%s\n' "${GRANDMA_DISTILLING:-unset}"
exit 0
SHIM
chmod +x "$SHIM/gemini"

section "gemini — dry-run and hookless degradation"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=gemini GRANDMA_DRY_RUN=1 "$GBIN" home-ops yard
assert_rc 0 "Gemini dry-run survives set -u with kebab sweater"
assert_contains "adapter:      gemini" "selects the Gemini adapter"
assert_contains "injection=contextfile" "reports native context-file injection"
assert_contains "rehydrate:    unavailable" "degrades honestly without a compaction hook"
assert_contains "KNOWN project 'Yard'" "resolves the kebab fixture project"

section "gemini — config and environment precedence"
printf 'cli: gemini\n' > "$GRANDMA_HOME/config"
capture env PATH="$SHIM:$PATH" GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_contains "adapter:      gemini" "home config selects Gemini"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=claude GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_contains "adapter:      claude" "environment overrides home config"
{ head -n4 "$GRANDMA_HOME/home-ops/facts.md"; echo 'cli: gemini'; tail -n +5 "$GRANDMA_HOME/home-ops/facts.md"; } > "$TMP/facts.md"
mv "$TMP/facts.md" "$GRANDMA_HOME/home-ops/facts.md"
printf 'cli: claude\n' > "$GRANDMA_HOME/config"
capture env PATH="$SHIM:$PATH" GRANDMA_DRY_RUN=1 "$GBIN" home-ops
assert_contains "adapter:      gemini" "sweater frontmatter overrides home config"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=claude GRANDMA_DRY_RUN=1 "$GBIN" home-ops
assert_contains "adapter:      claude" "environment overrides sweater frontmatter"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI='../bad' GRANDMA_DRY_RUN=1 "$GBIN" globex
assert_rc 2 "rejects a traversal-shaped adapter name"

section "gemini — temporary context cleanup"
project="$GRANDMA_HOME/projects/yard"
rm -f "$project/GEMINI.md"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=gemini GRANDMA_NO_AUTOSAVE=1 "$GBIN" home-ops yard </dev/null
assert_rc 0 "wrapped Gemini session returns its status"
assert_no_file "$project/GEMINI.md" "removes the temporary memory-bearing context file"

printf '# user-owned Gemini context\n' > "$project/GEMINI.md"
before="$(cksum < "$project/GEMINI.md")"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=gemini GRANDMA_NO_AUTOSAVE=1 "$GBIN" home-ops yard </dev/null
assert_rc 0 "Gemini runs when a user context file already exists"
after="$(cksum < "$project/GEMINI.md")"
if [[ "$before" == "$after" ]]; then ok "preserves an existing GEMINI.md byte-for-byte"
else fail "changed a user-owned GEMINI.md"; fi

section "gemini — guarded headless adapter"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=gemini bash -c 'ENGINE="$1"; ROOT="$2"; source "$ENGINE/lib/grandma-lib.sh"; grandma_load_adapter ""; adapter_headless prompt system' _ "$ENGINE" "$GRANDMA_HOME"
assert_rc 0 "Gemini headless adapter runs"
assert_contains "distilling=1" "headless calls inherit the recursion guard"

section "gemini — transcript reaches the existing distiller"
transcript="$HOME/.gemini/tmp/fake-project/chats/session-test.json"
capture env PATH="$SHIM:$PATH" GRANDMA_CLI=gemini "$ENGINE/lib/grandma-save.sh" home-ops --transcript "$transcript" --auto
assert_rc 0 "Gemini JSONL transcript can be distilled"
proposal="$(find "$GRANDMA_HOME/proposals" -name 'home-ops-session-test.md' -print | head -n1)"
assert_file "$proposal" "writes a proposal from the Gemini session transcript"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_gemini: PASS"; else echo "cmd_gemini: $FAILS FAILURE(S)"; exit 1; fi
