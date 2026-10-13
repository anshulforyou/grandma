#!/usr/bin/env bash
# test/live/opencode.sh — the OpenCode adapter end to end, against the real opencode on this machine.
#
# Opt-in, and never part of run.sh or CI: it drives a real terminal UI and makes real model calls
# (Haiku by default; a full run costs a few cents). test/cmd_opencode.sh covers the same paths
# offline against a fake opencode; this is the native compatibility check that says whether a given
# opencode release still behaves the way the adapter was built against.
#
#   test/live/opencode.sh                 every scenario
#   test/live/opencode.sh s2 s9           just those
#   GRANDMA_LIVE_MODEL=provider/model     a different model (default anthropic/claude-haiku-5-5)
#   GRANDMA_LIVE_KEEP=1                   keep the test sessions and fixtures for inspection
#
# Every run uses a throwaway fixture memory home (test/lib/fixture.sh), never yours, and changes no
# OpenCode configuration. test/live/drive.exp plays the person at the terminal: it types replies,
# answers the launcher's questions, and picks the affirmative or recommended choice in any question
# dialog the model opens. Every result is read back from files, git and OpenCode's API, never from
# the screen. The sessions a run creates are deleted when it ends. Exit status: the number of
# failed checks.
#
# Requires: opencode (with a working provider for the model), expect, jq, python3, git, perl.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/../.." && pwd)"
MODEL="${GRANDMA_LIVE_MODEL:-anthropic/claude-haiku-5-5}"
. "$ENGINE/test/lib/fixture.sh"
OUT="$(mktemp -d)"
RESULTS="$OUT/results.txt"; : > "$RESULTS"
DIRS_FILE="$OUT/dirs.txt"; : > "$DIRS_FILE"
FAILS=0

for dep in opencode expect jq python3 git perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "test/live/opencode.sh needs $dep on PATH" >&2; exit 2; }
done
if ! opencode api get "/api/session?limit=1" >/dev/null 2>&1; then
  echo "the opencode background service does not answer (try: opencode service status)" >&2; exit 2
fi
echo "live opencode e2e · model $MODEL · $(opencode --version 2>/dev/null | head -1) · state in $OUT"

pass() { printf 'PASS  %s\n' "$1" | tee -a "$RESULTS"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1" | tee -a "$RESULTS"
         if [ -n "${2:-}" ]; then printf '%s\n' "$2" | tail -15 | sed 's/^/      | /' | tee -a "$RESULTS"; fi; }
info() { printf 'INFO  %s\n' "$1" | tee -a "$RESULTS"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# The launch environment: the model pinned, no splash and no network notices, no shell rc touched.
G=(env GRANDMA_NO_SPLASH=1 GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_KNIT_CHECK=1 SHELL= \
     GRANDMA_OPENCODE_MODEL="$MODEL" PATH="$ENGINE/bin:$PATH")
G_NOMODEL=(env GRANDMA_NO_SPLASH=1 GRANDMA_NO_UPDATE_CHECK=1 GRANDMA_NO_KNIT_CHECK=1 SHELL= PATH="$ENGINE/bin:$PATH")

new_base() { local b; b="$(mktemp -d)"; mkdir -p "$b/work"; printf '%s\n' "$b" >> "$DIRS_FILE"; printf '%s' "$b"; }
new_home() { local b; b="$(new_base)"; make_fixture_home "$b/home"; printf '%s' "$b/home"; }

# mk_turns <session-dir> <title-prefix> <state-dir> — the probe drive.exp polls: it prints
# "<completed turns> <type of the last message>" for the newest matching session, and answers any
# question dialog the model opened (the question tool holds the turn open until it is answered).
mk_turns() {
  {
    printf '#!/usr/bin/env bash\nDIR=%q\nPREFIX=%q\nST=%q\n' "$1" "$2" "$3"
    cat <<'EOF'
for d in "$(cd "$DIR" 2>/dev/null && pwd)" "$(cd "$DIR" 2>/dev/null && pwd -P)"; do
  q=$(jq -rn --arg d "$d" '$d|@uri')
  sid=$(opencode api get "/api/session?limit=20&directory=$q" 2>/dev/null \
        | jq -r --arg p "$PREFIX" '[.data[] | select((.title // "") | startswith($p))][0].id // empty')
  [ -n "$sid" ] && break
done
[ -n "$sid" ] || { echo "0 none"; exit 0; }
echo "$sid" > "$ST/sid"
opencode api get "/api/session/$sid/form" > "$ST/forms.json" 2>/dev/null
jq -c '.data[]?' "$ST/forms.json" 2>/dev/null | while IFS= read -r frm; do
  fid=$(printf '%s' "$frm" | jq -r '.id')
  ans=$(printf '%s' "$frm" | jq -c '[.fields[] | {key: .key, value: ((.options // []) as $o
        | (([$o[] | select(.label | test("^(apply|yes|approve|create|register|confirm|accept|commit|proceed|write|save)"; "i"))][0])
           // ([$o[] | select(.label | test("recommended"; "i"))][0]) // $o[0])
        | if . == null then "yes" else .value end)}] | from_entries')
  if opencode api post "/api/session/$sid/form/$fid/reply" --data "{\"answer\":$ans}" >/dev/null 2>&1; then
    echo "$(date +%T) $fid $ans" >> "$ST/forms.log"
  fi
done
opencode api get "/api/session/$sid/message?limit=200&order=asc" > "$ST/msgs.json" 2>/dev/null
jq -r '"\([.data[] | select(.type=="idle")] | length) \(.data[-1].type // "none")"' "$ST/msgs.json" 2>/dev/null || echo "0 none"
EOF
  } > "$3/turns.sh"
}

# drive <state> <cwd> <cmd...> — play <state>/steps through expect, hard-capped at ten minutes.
drive() {
  local st="$1" cwd="$2"; shift 2
  ( cd "$cwd" && perl -e 'alarm shift @ARGV; exec @ARGV' 600 \
      expect "$HERE/drive.exp" "$st/steps" "$st/term.log" "$st/turns.sh" "$@" ) > "$st/drive.out" 2>&1
}

refresh() { local sid; sid="$(cat "$1/sid" 2>/dev/null)"; [ -n "$sid" ] && opencode api get "/api/session/$sid/message?limit=200&order=asc" > "$1/msgs.json" 2>/dev/null; return 0; }
said() { jq -r '[.data[] | select(.type=="assistant") | .content[]? | select(.type=="text") | .text] | join("\n")' "$1/msgs.json" 2>/dev/null; }
ledger_has() { grep -q "^$2 " "$1/.distill/opencode-ledger" 2>/dev/null; }
wait_distills() { local i; for i in $(seq 1 90); do pgrep -f "grandma-opencode.sh save" >/dev/null || return 0; sleep 2; done; return 1; }
no_orphans() { ! pgrep -f "lib/grandma-opencode.sh" >/dev/null && ! pgrep -f "opencode --session ses_" >/dev/null; }
step_note() { grep -h "STEP-FAIL\|STEPS-DONE" "$1/drive.out" 2>/dev/null | head -3; }
state() { rm -rf "${OUT:?}/${1:?}"; mkdir -p "$OUT/$1"; printf '%s' "$OUT/$1"; }

# ------------------------------------------------------------------------------- scenarios ----
s1() {   # doctor against the real service
  local H out rc; H="$(new_home)"
  out="$("${G[@]}" GRANDMA_HOME="$H" grandma opencode doctor 2>&1)"; rc=$?
  check "S1 doctor: healthy against the real service (rc=$rc)" [ "$rc" = 0 ]
  case "$out" in *"background service answers"*) pass "S1 doctor reached the background service" ;;
                 *) fail "S1 doctor did not reach the background service" "$out" ;; esac
}

s2() {   # launch with a task -> live capture -> clean exit -> post-session review and commit
  local H st proj rc sid t; H="$(new_home)"; st="$(state s2)"; proj="$H/projects/billing-api"
  mk_turns "$proj" "grandma:globex/" "$st"
  printf 'turns 1 180\nquit\nrespond 300\n' > "$st/steps"
  t="two notes. first: for all globex work, timestamps are always stored in UTC. capture that one now per your capture doctrine. second: the billing on-call rotation changes every Tuesday. do not capture that one, only acknowledge it."
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode globex billing "$t"; rc=$?
  check "S2 launch, one turn, clean exit, post-session answers (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  refresh "$st"; sid="$(cat "$st/sid" 2>/dev/null)"
  printf '%s\n%s\n' "$H" "$sid" > "$OUT/s2.ctx"
  case "$(said "$st")" in *"▣ memory: globex loaded"*"project Billing API"*) pass "S2 the first line is the memory confirmation, naming the project" ;;
                          *) fail "S2 no memory confirmation line" "$(said "$st")" ;; esac
  if grep -rqi 'UTC' "$H/globex" "$proj/CLAUDE.md" 2>/dev/null; then pass "S2 the UTC fact was captured live into memory"
  else fail "S2 the UTC fact was not captured" "$(said "$st")"; fi
  if grep -q 'grandma is looking over the session' "$st/term.log"; then pass "S2 the clean exit ran the post-session review"
  else fail "S2 the post-session review did not run" "$(tail -c 2000 "$st/term.log")"; fi
  wait_distills
  if ledger_has "$H" "$sid"; then pass "S2 the exit distill ran"; else fail "S2 no exit distill recorded"; fi
  if git -C "$H" log --oneline | grep 'session captures' >/dev/null; then pass "S2 the post-session commit landed"
  else info "S2 no post-session commit (the capture went to the project CLAUDE.md, outside the memory repo)"; fi
  if ls "$H/proposals/"globex-*.md >/dev/null 2>&1; then info "S2 the exit distill drafted a proposal"
  else info "S2 the exit distill found nothing new to propose"; fi
  check "S2 no orphaned launcher or UI" no_orphans
}

hup_case() {   # <label> <group|launcher> — the window closes under a live session
  local H st proj t sp lp i ok=0 sid; H="$(new_home)"; st="$(state "$1")"; proj="$H/projects/billing-api"
  mk_turns "$proj" "grandma:globex/" "$st"
  ( cd "$H/../work" && exec perl -e 'alarm 400; exec @ARGV' script -q /dev/null "${G[@]}" GRANDMA_HOME="$H" \
      grandma opencode globex billing "note for later: billing invoices are numbered per calendar year. capture that per your capture doctrine." ) > "$st/term.log" 2>&1 &
  sp=$!
  for i in $(seq 1 90); do t="$(bash "$st/turns.sh")"; [ "${t%% *}" -ge 1 ] 2>/dev/null && { ok=1; break; }; sleep 2; done
  check "$1 the session went live and finished its first turn" [ "$ok" = 1 ]
  sid="$(cat "$st/sid" 2>/dev/null)"
  lp="$(pgrep -f "lib/grandma-opencode.sh globex billing note for later" | head -1)"
  if [ -z "$lp" ]; then fail "$1 launcher process not found"; kill "$sp" 2>/dev/null; return; fi
  if [ "$2" = group ]; then kill -s HUP -- -"$lp" 2>/dev/null; else kill -s HUP "$lp"; fi
  ok=0; for i in $(seq 1 60); do ledger_has "$H" "$sid" && { ok=1; break; }; sleep 2; done
  check "$1 hangup ($2): the detached distill ran" [ "$ok" = 1 ]
  wait_distills; sleep 2
  check "$1 no orphaned launcher or UI after the hangup" no_orphans
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
}
s3() { hup_case S3 group; }      # what a login shell sends when its window closes
s4() { hup_case S4 launcher; }   # the launcher alone: it is the terminal's session leader

s5() {   # memory survives a real compaction
  local H sid i st ans summary
  [ -f "$OUT/s2.ctx" ] || { fail "S5 needs S2"; return; }
  H="$(sed -n 1p "$OUT/s2.ctx")"; sid="$(sed -n 2p "$OUT/s2.ctx")"
  opencode api post "/api/session/$sid/compact" --data '{}' >/dev/null 2>&1
  for i in $(seq 1 60); do
    st="$(opencode api get "/api/session/$sid/message?limit=20&order=desc" 2>/dev/null | jq -r '[.data[] | select(.type=="compaction")][0].status // empty')"
    if [ "$st" = completed ] || [ "$st" = failed ]; then break; fi; sleep 2
  done
  check "S5 the grandma session compacted ($st)" [ "$st" = completed ]
  summary="$(opencode api get "/api/session/$sid/message?limit=20&order=desc" 2>/dev/null | jq -r '[.data[] | select(.type=="compaction")][0].summary')"
  ans="$(cd "$H/projects/billing-api" && perl -e 'alarm shift @ARGV; exec @ARGV' 150 opencode run --session "$sid" --model "$MODEL" \
        "Answer only from your instructions, without using any tool: which package manager does the user insist on? Reply with one word." 2>&1 | tail -1)"
  case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in *pnpm*) pass "S5 after compaction the session still knows memory (answered: $ans)" ;;
    *) fail "S5 memory was lost after compaction" "$ans" ;; esac
  case "$summary" in *pnpm*) info "S5 (the summary mentions pnpm too)" ;; *) pass "S5 the summary never mentions pnpm, so the answer came from the instructions" ;; esac
}

s6() {   # a sweater too big for one instruction entry
  local H st i rc n; H="$(new_home)"; st="$(state s6)"
  { printf -- '---\nscope: globex\ntype: notes\nupdated: 2026-06-15\n---\n\n'
    for i in $(seq 1 5000); do printf -- '- note %05d: routine billing reconciliation detail with no special meaning\n' "$i"; done
    printf -- '- the vault code is TANGERINE-4417\n'; } > "$H/globex/notes.md"
  git -C "$H" add -A >/dev/null; git -C "$H" -c user.name=t -c user.email=t@l commit -qm notes
  mk_turns "$H/../work" "grandma:globex" "$st"
  printf 'turns 1 300\nquit\neof 120\n' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_NO_AUTOSAVE=1 GRANDMA_HOME="$H" grandma opencode globex \
    "What is the vault code in your memory? Reply with only the code."; rc=$?
  check "S6 a 380 KB sweater launches and answers (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  refresh "$st"
  # to a file first: opencode writing a large response into a pipe stops at 192 KiB
  opencode api get "/api/experimental/session/$(cat "$st/sid" 2>/dev/null)/instructions/entries" > "$st/entries.json" 2>/dev/null
  n="$(jq '[.data[] | select(.key | startswith("grandma.memory"))] | length' "$st/entries.json" 2>/dev/null)"
  check "S6 memory was split across ${n:-0} instruction entries" [ "${n:-0}" -ge 3 ]
  case "$(said "$st")" in *TANGERINE-4417*) pass "S6 the model read the fact on the last line of the last piece" ;;
                          *) fail "S6 the model could not see the end of memory" "$(said "$st")" ;; esac
}

s7() {   # save --auto on a real session
  local H sid out rc before after left infer f
  [ -f "$OUT/s2.ctx" ] || { fail "S7 needs S2"; return; }
  H="$(sed -n 1p "$OUT/s2.ctx")"; sid="$(sed -n 2p "$OUT/s2.ctx")"
  before="$(grep -c "^$sid " "$H/.distill/opencode-ledger" 2>/dev/null || echo 0)"
  out="$("${G[@]}" GRANDMA_HOME="$H" grandma opencode save globex billing --session "$sid" --auto 2>&1)"; rc=$?
  after="$(grep -c "^$sid " "$H/.distill/opencode-ledger" 2>/dev/null || echo 0)"
  check "S7 save --auto runs on a real session (rc=$rc)" [ "$rc" = 0 ]
  check "S7 the transcript changed since the exit distill, so it was distilled again ($before -> $after)" [ "$after" -gt "$before" ]
  left=""
  for f in "$H/.distill/"* "$H/.distill/".[!.]*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in opencode-ledger) ;; *) left="$left $(basename "$f")" ;; esac
  done
  check "S7 nothing staged is left behind [${left}]" [ -z "$left" ]
  infer="$(opencode api get "/api/session?limit=50&directory=$(jq -rn --arg d "$(cd "$H/projects/billing-api" && pwd -P)" '$d|@uri')" 2>/dev/null \
           | jq '[.data[] | select(.metadata.grandma.role == "infer")] | length')"
  check "S7 the throwaway distill session was deleted (${infer:-?} left)" [ "${infer:-1}" = 0 ]
  if [ -n "$out" ] && [ -f "$(printf '%s' "$out" | tail -1)" ]; then info "S7 drafted $(basename "$(printf '%s' "$out" | tail -1)")"
  else info "S7 nothing durable to propose"; fi
}

s8() {   # interactive save: a distiller session in the TUI, approved by the user
  local H sid st rc c0 c1 proj
  [ -f "$OUT/s2.ctx" ] || { fail "S8 needs S2"; return; }
  H="$(sed -n 1p "$OUT/s2.ctx")"; sid="$(sed -n 2p "$OUT/s2.ctx")"; proj="$H/projects/billing-api"
  st="$(state s8)"; mk_turns "$H" "distill:globex" "$st"
  c0="$(git -C "$H" rev-list --count HEAD)"
  printf 'turns 1 300\ntype yes, apply every edit you proposed now, then commit them.\nsettle 400\nquit\neof 120\n' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode save globex billing --session "$sid"; rc=$?
  check "S8 the distiller session ran, got approval and finished (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  refresh "$st"; c1="$(git -C "$H" rev-list --count HEAD)"
  check "S8 the staged transcript was cleaned up afterwards" [ ! -f "$H/.distill/opencode-$sid.md" ]
  if [ "$c1" -gt "$c0" ]; then pass "S8 the distiller committed its edits ($c0 -> $c1 commits)"
  elif grep -qi tuesday "$proj/CLAUDE.md"; then pass "S8 the distiller wrote the project-only fact to the project CLAUDE.md"
  elif said "$st" | grep -i 'durable' >/dev/null; then pass "S8 the distiller judged nothing durable left"
  else fail "S8 the distiller produced no visible outcome" "$(said "$st")"; fi
}

s9() {   # the launch offers a pending review; the review session applies it
  local H st rc i c0 c1 gone=0; H="$(new_home)"; st="$(state s9)"
  c0="$(git -C "$H" rev-list --count HEAD)"
  { echo "# grandma memory proposal"; echo "# scope=globex  transcript=crafted"; echo
    echo "target: globex/facts.md | action: new-fact | text: deploy freeze runs from December 20 to January 3 | why: no future session may schedule a deploy in that window"
  } > "$H/proposals/globex-crafted-20261013.md"
  mk_turns "$H" "grandma:review" "$st"
  printf '%s\n' 'plain review before we start\? \[Y/n\]' 'answer y' \
    "goal $H/globex/facts.md December 3 400 yes, apply it exactly as proposed, commit it, and delete the proposal file." \
    'settle 400' 'quit' 'eof 120' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode globex; rc=$?
  check "S9 the launch offered the pending review and the review session ran (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  if grep -q 'December 20' "$H/globex/facts.md"; then pass "S9 the proposal was applied to globex/facts.md"
  else fail "S9 the proposal was not applied" "$(cat "$H/globex/facts.md")"; fi
  for i in $(seq 1 10); do [ -f "$H/proposals/globex-crafted-20261013.md" ] || { gone=1; break; }; sleep 1; done
  check "S9 the handled proposal file was deleted" [ "$gone" = 1 ]
  c1="$(git -C "$H" rev-list --count HEAD)"
  if [ "$c1" -gt "$c0" ] && git -C "$H" show --name-only --format= HEAD | grep 'globex/facts.md' >/dev/null; then
    pass "S9 the edit was committed in the memory repo ($c0 -> $c1 commits)"
  else fail "S9 the applied edit was not committed" "$(git -C "$H" log --oneline | head -3; git -C "$H" status --short)"; fi
  if [ -f "$st/forms.log" ]; then info "S9 answered the model's question dialog: $(cut -d' ' -f3- "$st/forms.log" | head -2 | tr '\n' ' ')"; fi
  check "S9 the other sweater's proposal was left alone (isolation)" [ -f "$H/proposals/home-ops-20260601T101010.md" ]
}

s11() {   # onboard a project the sweater does not know yet
  local H st rc out; H="$(new_home)"; st="$(state s11)"
  mkdir -p "$H/projects/ledger-svc"
  printf '# Ledger Service\n- double-entry ledger for globex payments\n- role: writer\n' > "$H/projects/ledger-svc/CLAUDE.md"
  mk_turns "$H" "grandma:onboard/" "$st"
  printf '%s\n' 'turns 1 300' \
    "type (a) it already exists. The folder is $H/projects/ledger-svc and it has a CLAUDE.md. Register it as ledger." \
    "goal $H/globex/projects.md ledger 3 400 yes, register it now exactly as you described." \
    'settle 400' 'quit' 'eof 120' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode globex ledger; rc=$?
  check "S11 the onboarding session registered the project (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  if grep -q 'ledger-svc/CLAUDE.md' "$H/globex/projects.md"; then pass "S11 globex/projects.md points at the project's CLAUDE.md"
  else fail "S11 no catalog entry" "$(cat "$H/globex/projects.md")"; fi
  if "${G[@]}" GRANDMA_HOME="$H" grandma test >/dev/null 2>&1; then pass "S11 grandma test passes after onboarding"
  else fail "S11 grandma test fails after onboarding" "$("${G[@]}" GRANDMA_HOME="$H" grandma test 2>&1 | grep FAIL)"; fi
  out="$("${G[@]}" GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 grandma opencode globex ledger 2>&1)"
  case "$out" in *"KNOWN project"*) pass "S11 grandma opencode globex ledger now resolves the project" ;; *) fail "S11 the project still does not resolve" "$out" ;; esac
}

s12() {   # knit a new sweater from a typed description
  local H st rc out; H="$(new_home)"; st="$(state s12)"
  mk_turns "$H" "grandma:new-sweater" "$st"
  printf '%s\n' 'plain knit it now\? \[Y/n\]' 'answer y' 'plain what is it\?' \
    'answer my vegetable garden at home with raised beds, a watering schedule, and seed orders every spring' \
    "goal $H/hobby-garden/facts.md scope:.*hobby-garden 3 400 yes, create it now with exactly the name hobby-garden." \
    'settle 400' 'quit' 'eof 120' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode hobby-garden; rc=$?
  check "S12 knitting a new sweater finished (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  if grep -q '^scope: *hobby-garden' "$H/hobby-garden/facts.md" 2>/dev/null; then pass "S12 hobby-garden/facts.md exists with its scope frontmatter"
  else fail "S12 the sweater was not created" "$(ls "$H")"; fi
  out="$("${G[@]}" GRANDMA_HOME="$H" GRANDMA_DRY_RUN=1 grandma opencode hobby-garden 2>&1)"
  case "$out" in *"memory: hobby-garden loaded"*) pass "S12 the new sweater launches" ;; *) fail "S12 the new sweater does not launch" "$out" ;; esac
  if "${G[@]}" GRANDMA_HOME="$H" grandma test >/dev/null 2>&1; then pass "S12 grandma test passes after knitting"
  else fail "S12 grandma test fails after knitting" "$("${G[@]}" GRANDMA_HOME="$H" grandma test 2>&1 | grep FAIL)"; fi
}

s13() {   # first run on a fresh home: the interview
  local b H st rc; b="$(new_base)"; H="$b/home"; st="$(state s13)"
  ( GRANDMA_HOME="$H" SHELL='' "$ENGINE/bin/grandma" init </dev/null >/dev/null 2>&1 )
  check "S13 a fresh home starts with the template identity" grep -q '<your name>' "$H/global/identity.md"
  mk_turns "$H" "grandma:init" "$st"
  printf '%s\n' 'turns 1 300' \
    'type I am Sam, a firmware engineer writing embedded C for a wearable device. I like terse direct answers and a plan before code. My contexts are work firmware and a home lab. Please write my identity and preferences files now and do not create any sweaters.' \
    "goal $H/global/identity.md Sam 3 400 That is everything. Please write global/identity.md and global/preferences.md now." \
    'settle 400' 'quit' 'eof 120' > "$st/steps"
  drive "$st" "$b/work" "${G[@]}" GRANDMA_HOME="$H" grandma opencode; rc=$?
  check "S13 first run: the interview ran in OpenCode (rc=$rc) $(step_note "$st")" [ "$rc" = 0 ]
  if grep -q 'Sam' "$H/global/identity.md" && ! grep -q '<your name>' "$H/global/identity.md"; then pass "S13 global/identity.md was written from the interview"
  else fail "S13 the identity was not written" "$(cat "$H/global/identity.md")"; fi
}

s14() {   # plain `grandma` routed to OpenCode: GRANDMA_CLI, and a sweater's own cli: line
  local H st rc; H="$(new_home)"; st="$(state s14a)"
  mk_turns "$H/../work" "grandma:globex" "$st"
  printf 'turns 1 240\nquit\neof 120\n' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_CLI=opencode GRANDMA_NO_AUTOSAVE=1 GRANDMA_HOME="$H" grandma globex; rc=$?
  refresh "$st"
  case "$(said "$st")" in *"memory: globex loaded"*) pass "S14 GRANDMA_CLI=opencode: plain 'grandma globex' opened OpenCode with memory (rc=$rc)" ;;
    *) fail "S14 GRANDMA_CLI routing" "$(said "$st") $(step_note "$st")" ;; esac
  mkdir -p "$H/routed"
  printf -- '---\nscope: routed\ntype: facts\ncli: opencode\nupdated: 2026-10-13\n---\n\n- the routed sweater keeps its own notes\n' > "$H/routed/facts.md"
  st="$(state s14b)"; mk_turns "$H/../work" "grandma:routed" "$st"
  printf 'turns 1 240\nquit\neof 120\n' > "$st/steps"
  drive "$st" "$H/../work" "${G[@]}" GRANDMA_NO_AUTOSAVE=1 GRANDMA_HOME="$H" grandma routed; rc=$?
  refresh "$st"
  case "$(said "$st")" in *"memory: routed loaded"*) pass "S14 cli: opencode in a sweater: plain 'grandma routed' opened OpenCode (rc=$rc)" ;;
    *) fail "S14 cli: frontmatter routing" "$(said "$st") $(step_note "$st")" ;; esac
}

s15() {   # no model pinned: the last one used successfully in that folder
  local H st rc proj m; H="$(new_home)"; st="$(state s15)"; proj="$H/projects/billing-api"
  ( cd "$proj" && perl -e 'alarm shift @ARGV; exec @ARGV' 150 opencode run --model "$MODEL" "Reply with exactly: seeded" >/dev/null 2>&1 )
  mk_turns "$proj" "grandma:globex/" "$st"
  printf 'turns 1 240\nquit\neof 120\n' > "$st/steps"
  drive "$st" "$H/../work" "${G_NOMODEL[@]}" GRANDMA_NO_AUTOSAVE=1 GRANDMA_HOME="$H" grandma opencode globex billing; rc=$?
  m="$(opencode api get "/api/session/$(cat "$st/sid" 2>/dev/null)" 2>/dev/null | jq -r '(.data // .).model | "\(.providerID)/\(.id)"' 2>/dev/null)"
  check "S15 with no model pinned, the session starts on the last one used in that folder ($m)" [ "$m" = "${MODEL%%#*}" ]
  refresh "$st"
  case "$(said "$st")" in *"memory: globex loaded"*) pass "S15 and it answered with memory loaded" ;; *) fail "S15 no answer" "$(said "$st")" ;; esac
}

# sweep — delete every session the run created (they all live in fixture folders), then the fixtures.
sweep() {
  local base d p q sid n=0
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    for d in "$base/home" "$base/work" "$base/home/projects/"*; do
      [ -d "$d" ] || continue
      for p in "$d" "$(cd "$d" && pwd -P)"; do
        q="$(jq -rn --arg d "$p" '$d|@uri')"
        for sid in $(opencode api get "/api/session?limit=100&directory=$q" 2>/dev/null | jq -r '.data[].id' 2>/dev/null); do
          opencode session delete "$sid" >/dev/null 2>&1 && n=$((n + 1))
        done
      done
    done
    rm -rf "$base"
  done < "$DIRS_FILE"
  : > "$DIRS_FILE"
  info "sweep: deleted $n test session(s) and every fixture"
}
if [ "${GRANDMA_LIVE_KEEP:-0}" != 1 ]; then trap sweep EXIT; fi

SCEN=("$@"); [ ${#SCEN[@]} -gt 0 ] || SCEN=(s1 s2 s3 s4 s5 s6 s7 s8 s9 s11 s12 s13 s14 s15)
for s in "${SCEN[@]}"; do
  printf '\n### %s\n' "$s" | tee -a "$RESULTS"
  "$s"
done
echo
echo "live opencode e2e: $FAILS failed check(s) · model $MODEL · results in $RESULTS"
exit "$FAILS"
