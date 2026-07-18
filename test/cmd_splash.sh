#!/usr/bin/env bash
# Behavioral tests for the splash renderer (lib/grandma-lib.sh).
# The mascot GIF is rendered ONLY on graphics-capable terminals (iTerm2/kitty/WezTerm/sixel);
# every other terminal (Apple Terminal, plain xterm) gets hand-crafted ANSI art. Pins that
# split so the "blocky GIF in Apple Terminal" regression cannot return.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/chafa" "$TMP/imgcat" "$TMP/both" "$TMP/none"
printf '#!/bin/sh\nexit 0\n' > "$TMP/chafa/chafa";   chmod +x "$TMP/chafa/chafa"
printf '#!/bin/sh\nexit 0\n' > "$TMP/imgcat/imgcat"; chmod +x "$TMP/imgcat/imgcat"
cp "$TMP/chafa/chafa" "$TMP/both/chafa"; cp "$TMP/imgcat/imgcat" "$TMP/both/imgcat"

# pick <bindir> <TERM_PROGRAM> <TERM> — run pick_mascot_renderer in a controlled environment.
pick() {
  capture env -i "PATH=$1:/usr/bin:/bin" "TERM_PROGRAM=$2" "TERM=$3" \
    bash -c '. "'"$ENGINE"'/lib/grandma-lib.sh"; pick_mascot_renderer'
}

section "splash — Apple Terminal never renders the GIF (uses ANSI art), even with tools present"
pick "$TMP/both" "Apple_Terminal" "xterm-256color"
assert_rc 0 "runs on Apple Terminal"
assert_not_contains "chafa"  "chafa NOT used on Apple Terminal (blocky-GIF bug stays fixed)"
assert_not_contains "imgcat" "imgcat NOT used on Apple Terminal"

section "splash — iTerm2 renders the GIF: imgcat preferred, chafa as backup"
pick "$TMP/imgcat" "iTerm.app" "xterm-256color"
assert_contains "imgcat" "imgcat used in iTerm2"
pick "$TMP/chafa" "iTerm.app" "xterm-256color"
assert_contains "chafa" "chafa used in iTerm2 when imgcat is absent"
pick "$TMP/both" "iTerm.app" "xterm-256color"
assert_contains "imgcat" "imgcat preferred over chafa in iTerm2"

section "splash — kitty (a graphics terminal) renders the GIF via chafa"
pick "$TMP/chafa" "" "xterm-kitty"
assert_contains "chafa" "chafa used in kitty"

section "splash — graphics terminal but no renderer installed -> ANSI art"
pick "$TMP/none" "iTerm.app" "xterm-256color"
assert_not_contains "chafa"  "no tool -> no GIF"
assert_not_contains "imgcat" "no tool -> no GIF"

section "splash — grandma_splash draws the typographic wordmark when no GIF renders"
capture env -i "PATH=/usr/bin:/bin" "TERM_PROGRAM=Apple_Terminal" "TERM=xterm-256color" \
  "GRANDMA_SPLASH_SECS=0" "ENGINE=$ENGINE" \
  bash -c '. "'"$ENGINE"'/lib/grandma-lib.sh"; grandma_splash "acme"'
assert_rc 0 "grandma_splash runs from the shared lib"
assert_contains '/____/' "draws the pre-rendered grandma wordmark"
assert_contains "she remembers everything" "knits the tagline"
assert_contains "fetching acme memory" "shows what is loading"

echo
if [ "$FAILS" -eq 0 ]; then echo "cmd_splash: PASS"; else echo "cmd_splash: $FAILS FAILURE(S)"; exit 1; fi
