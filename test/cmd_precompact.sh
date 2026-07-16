#!/usr/bin/env bash
# Behavioral tests for grandma-precompact.sh (PreCompact hook: checkpoint session working
# state before compaction, keyed by session_id, for grandma-rehydrate to re-inject).
#
# Bites: it is a headless model call, so it MUST survive set -u, honor the dry run, and its
# recursion guard and cost cap must actually STOP the model call (delta with the fake claude
# shim), not merely exist. And it must ALWAYS exit 0 so it never blocks compaction.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/fixture.sh"

PC="$ENGINE/lib/grandma-precompact.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GRANDMA_HOME="$TMP/home"; export SHELL=""
make_fixture_home "$GRANDMA_HOME"
FB="$(make_fake_claude "$TMP/bin")"
TRANS="$TMP/t.jsonl"; make_fake_transcript "$TRANS"
CDIR="$GRANDMA_HOME/.compact"

# hook_json <session_id> — a PreCompact stdin payload pointing at the fixture transcript.
hook_json() { printf '{"session_id":"%s","transcript_path":"%s","compaction_trigger":"auto"}' "$1" "$TRANS"; }
note_of()   { printf '%s/%s.md' "$CDIR" "$1"; }

section "precompact — dry run prints the plan, makes no note, resolves the kebab scope"
capture env GRANDMA_DRY_RUN=1 PATH="$FB:$PATH" bash -c "printf '%s' '$(hook_json ses-dry)' | '$PC' home-ops yard"
assert_rc 0 "dry run exits 0 under set -u"
assert_contains "PRECOMPACT checkpoint" "prints the checkpoint plan"
assert_contains "scope:       home-ops" "carries the kebab scope through intact"
assert_no_file "$(note_of ses-dry)" "dry run writes no note (no model call)"

section "precompact — no scope arg is a no-op"
capture env bash -c "'$PC' </dev/null"
assert_rc 0 "no scope exits 0"

section "precompact — missing transcript still exits 0 (never blocks compaction)"
capture env PATH="$FB:$PATH" bash -c "printf '{\"session_id\":\"s\",\"transcript_path\":\"/no/such.jsonl\"}' | '$PC' globex"
assert_rc 0 "missing transcript exits 0"

section "precompact — normal run writes a session-keyed working-state note"
rm -f "$(note_of ses-live)"
capture env PATH="$FB:$PATH" bash -c "printf '%s' '$(hook_json ses-live)' | '$PC' globex billing"
assert_rc 0 "checkpoint run exits 0"
assert_file "$(note_of ses-live)" "writes the note keyed by session_id"
# shellcheck disable=SC2034  # LAST_OUT is read by assert_* after capture
capture env cat "$(note_of ses-live)"
assert_contains "working state, captured before compaction" "note carries the continuity header"

section "precompact — RECURSION GUARD fires (GRANDMA_DISTILLING=1 => no model call, no note)"
rm -f "$(note_of ses-guard)"
capture env GRANDMA_DISTILLING=1 PATH="$FB:$PATH" bash -c "printf '%s' '$(hook_json ses-guard)' | '$PC' globex billing"
assert_rc 0 "guarded run exits 0"
assert_no_file "$(note_of ses-guard)" "recursion guard stops the checkpoint before the model call"

section "precompact — GRANDMA_NO_CHECKPOINT disables it (no note)"
rm -f "$(note_of ses-nock)"
capture env GRANDMA_NO_CHECKPOINT=1 PATH="$FB:$PATH" bash -c "printf '%s' '$(hook_json ses-nock)' | '$PC' globex"
assert_rc 0 "disabled run exits 0"
assert_no_file "$(note_of ses-nock)" "GRANDMA_NO_CHECKPOINT prevents any note"

section "precompact — COST CAP airbag trips and skips the model call"
mkdir -p "$CDIR"
for i in $(seq 1 12); do : > "$CDIR/.run.9999.$i"; done   # >= default cap of 12, all fresh
rm -f "$(note_of ses-capped)"
capture env PATH="$FB:$PATH" bash -c "printf '%s' '$(hook_json ses-capped)' | '$PC' globex billing"
assert_rc 0 "capped run exits 0 (never blocks compaction)"
assert_contains "COST CAP" "announces the airbag"
assert_no_file "$(note_of ses-capped)" "cost cap stops the checkpoint before the model call"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_precompact: PASS"; else echo "cmd_precompact: $FAILS FAILURE(S)"; exit 1; fi
