#!/usr/bin/env bash
#
# grandma-test — verify grandma's context-integrity invariants. Exit non-zero if any fail.
#
# The core promise: loading scope X injects exactly global/* + X/* (+ the project's own
# CLAUDE.md). No other scope's content, and no scope-specific concept baked into grandma
# core. This suite guards that so a context leak can never ship silently.
#
# Usage: grandma-test [scope]     (no arg = all scopes)
# Run it after adding/editing any scope, project, or core script. Bash (not zsh).

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"   # the user's private memory home
source "$ENGINE/lib/grandma-lib.sh"
ASSEMBLE="$ENGINE/lib/assemble.sh"

# Scope-agnostic runtime files that must NOT contain scope-specific content: the runtime
# scripts, and the generic prompts that run across all scopes.
CORE=(lib/grandma-launch.sh lib/grandma-lib.sh lib/grandma-rehydrate.sh lib/grandma-session-end.sh \
      lib/grandma-save.sh lib/grandma-ingest.sh lib/grandma-review.sh lib/assemble.sh \
      prompts/distiller.md prompts/onboard.md prompts/ingest.md prompts/new-scope.md \
      prompts/capture.md lib/grandma-watch.sh prompts/watch-digest.md prompts/watch-report.md)

fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
skip() { printf '  \033[2mskip\033[0m %s\n' "$1"; }

# Home-dependent checks only run when a memory home exists (fresh installs / CI have none)
HOME_OK=0
[[ -d "$ROOT" && -d "$ROOT/global" ]] && HOME_OK=1

# scopes to check
SCOPES=()
if [[ $# -gt 0 ]]; then SCOPES=("$1")
else while IFS= read -r s; do [[ -n "$s" ]] && SCOPES+=("$s"); done < <(list_scopes); fi

# ---- 1. Isolation: each scope bundle contains only global/ + <scope>/ ----
echo "== 1. isolation (bundle = global + scope only) =="
if [[ "$HOME_OK" == "0" ]]; then skip "no memory home at $ROOT (run grandma init)"; SCOPES=(); fi
for sc in ${SCOPES[@]+"${SCOPES[@]}"}; do
  leaked=""
  for mode in "" "--full" "--writing"; do
    bundle="$("$ASSEMBLE" "$sc" $mode 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      if [[ "$p" != global/* && "$p" != "$sc"/* ]]; then leaked+="$p($mode) "; fi
    done < <(printf '%s\n' "$bundle" | grep -oE '^----- BEGIN [^ ]+' | sed 's/^----- BEGIN //')
  done
  if [[ -n "$leaked" ]]; then bad "scope '$sc' bundle leaks: $leaked"; else pass "scope '$sc' isolated"; fi
done

# ---- 2. Core purity: no scope NAME hardcoded in core logic (comments excluded) ----
echo "== 2. core purity (no scope names in core logic) =="
allscopes=()
while IFS= read -r s; do [[ -n "$s" ]] && allscopes+=("$s"); done < <(list_scopes)
namehit=0
for f in "${CORE[@]}"; do
  [[ -f "$ENGINE/$f" ]] || continue
  # strip full-line comments, then look for any literal scope name as a word
  noncomment="$(grep -vE '^[[:space:]]*#' "$ENGINE/$f")"
  for sc in ${allscopes[@]+"${allscopes[@]}"}; do
    if printf '%s\n' "$noncomment" | grep -iqE "\b${sc}\b"; then
      bad "core '$f' hardcodes scope name '$sc' in logic"; namehit=1
    fi
  done
done
[[ "$namehit" == "0" ]] && pass "no scope names in core logic"

# ---- 3. Core purity: curated scope-jargon denylist absent from core ----
echo "== 3. core purity (no scope-jargon in core) =="
jarghit=0
for den in "$ENGINE/test/core-denylist.txt" "$ROOT/denylist.txt"; do
  [[ -f "$den" ]] || continue
  while IFS= read -r term; do
    [[ -z "$term" || "$term" == \#* ]] && continue
    for f in "${CORE[@]}"; do
      [[ -f "$ENGINE/$f" ]] || continue
      if grep -iqF "$term" "$ENGINE/$f"; then bad "core '$f' contains scope-jargon '$term'"; jarghit=1; fi
    done
  done < "$den"
done
[[ "$jarghit" == "0" ]] && pass "core free of denylisted jargon"

# ---- 4. Secrets: no tokens/keys in tracked memory or config ----
echo "== 4. secrets (none in memory/config) =="
scan_dirs="$ENGINE/prompts $ENGINE/templates $ENGINE/lib"
[[ "$HOME_OK" == "1" ]] && scan_dirs="$scan_dirs $ROOT"
sechit="$(grep -rElED --include='*.md' --include='*.json' \
  'eyJ[A-Za-z0-9_-]{20}|__client=[A-Za-z0-9]|__session=[A-Za-z0-9]|BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._-]{20}' \
  $scan_dirs 2>/dev/null | grep -v '/proposals/' | grep -v '/.git/' || true)"
if [[ -n "$sechit" ]]; then bad "possible secret in: $sechit"; else pass "no secrets in memory/config"; fi

# ---- 5. Frontmatter: scope: tag matches the folder ----
echo "== 5. frontmatter (scope tag matches folder) =="
fmhit=0
check_fm() { # dir, expected-lower
  local d="$1" exp="$2" f tag
  for f in "$ROOT/$d"/*.md; do
    [[ -f "$f" ]] || continue
    tag="$(grep -m1 -E '^scope:' "$f" 2>/dev/null | sed 's/^scope:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [[ -z "$tag" ]] && continue
    if [[ "$tag" != "$exp" ]]; then bad "$d/$(basename "$f") has scope:'$tag' (expected '$exp')"; fmhit=1; fi
  done
}
if [[ "$HOME_OK" == "0" ]]; then skip "no memory home"; fi
[[ "$HOME_OK" == "1" ]] && check_fm global global
[[ "$HOME_OK" == "1" ]] && for sc in ${allscopes[@]+"${allscopes[@]}"}; do check_fm "$sc" "$(printf '%s' "$sc" | tr '[:upper:]' '[:lower:]')"; done
[[ "$fmhit" == "0" ]] && pass "frontmatter scope tags match folders"

# ---- 6. INDEX: referenced files exist (no dangling pointers) ----
echo "== 6. INDEX (no dangling references) =="
idxhit=0
[[ "$HOME_OK" == "0" ]] && skip "no memory home"
if [[ -f "$ROOT/INDEX.md" ]]; then
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ -f "$ROOT/$ref" ]] || { bad "INDEX references missing file: $ref"; idxhit=1; }
  done < <(grep -oE '\[[A-Za-z0-9_./-]+\.md\]' "$ROOT/INDEX.md" | tr -d '[]')
fi
[[ "$idxhit" == "0" ]] && pass "INDEX references all resolve"

# ---- 7. Auto-distill recursion guard present (prevents the SessionEnd cascade) ----
echo "== 7. auto-distill recursion guard =="
rg_ok=1
# The SessionEnd hook must bail when GRANDMA_DISTILLING is set, and must set it when spawning.
grep -q 'GRANDMA_DISTILLING.*==.*1.*exit 0\|GRANDMA_DISTILLING:-0.*==.*1' "$ENGINE/lib/grandma-session-end.sh" 2>/dev/null || { bad "grandma-session-end.sh missing GRANDMA_DISTILLING guard (recursion risk)"; rg_ok=0; }
grep -q 'GRANDMA_DISTILLING=1' "$ENGINE/lib/grandma-session-end.sh" 2>/dev/null || { bad "grandma-session-end.sh does not set GRANDMA_DISTILLING when spawning the distill"; rg_ok=0; }
grep -q 'GRANDMA_DISTILLING=1 claude -p' "$ENGINE/lib/grandma-save.sh" 2>/dev/null || { bad "grandma-save.sh --auto does not guard its claude -p with GRANDMA_DISTILLING"; rg_ok=0; }
[[ "$rg_ok" == "1" ]] && pass "auto-distill recursion guard in place"

# ---- 8. Auto-distill circuit breaker present (airbag: bounds any runaway) ----
echo "== 8. auto-distill circuit breaker =="
if grep -q 'CIRCUIT BREAKER' "$ENGINE/lib/grandma-save.sh" 2>/dev/null && grep -q 'GRANDMA_AUTOSAVE_CAP' "$ENGINE/lib/grandma-save.sh" 2>/dev/null; then
  pass "circuit breaker present"
else
  bad "grandma-save.sh --auto missing circuit breaker (runaway airbag)"
fi

# ---- 9. Distiller transcript is repo-local (sandbox-readable by headless claude -p) ----
echo "== 9. distiller transcript is sandbox-readable =="
if grep -q 'readable="\$ROOT/\.distill' "$ENGINE/lib/grandma-save.sh" 2>/dev/null; then
  pass "distiller readable transcript is repo-local"
else
  bad "grandma-save.sh readable transcript not under \$ROOT/.distill (headless claude -p can't read it)"
fi

# ---- 10. Capture doctrine wired into all three injection points ----
echo "== 10. capture doctrine (passive learning) =="
cap_ok=1
[[ -f "$ENGINE/prompts/capture.md" ]] || { bad "prompts/capture.md missing"; cap_ok=0; }
grep -q 'seven categories' "$ENGINE/prompts/capture.md" 2>/dev/null || { bad "capture.md lacks the category doctrine"; cap_ok=0; }
grep -q 'prompts/capture.md' "$ENGINE/lib/grandma-launch.sh" 2>/dev/null || { bad "launch does not inject capture.md"; cap_ok=0; }
grep -q 'prompts/capture.md' "$ENGINE/lib/grandma-rehydrate.sh" 2>/dev/null || { bad "grandma-rehydrate.sh does not re-inject capture.md after compaction"; cap_ok=0; }
grep -q 'prompts/capture.md' "$ENGINE/lib/grandma-save.sh" 2>/dev/null || { bad "grandma-save.sh sweep does not load capture.md"; cap_ok=0; }
grep -q -- '--add-dir "\$ROOT"' "$ENGINE/lib/grandma-launch.sh" 2>/dev/null || { bad "launch missing --add-dir for the memory repo (captures can't write)"; cap_ok=0; }
[[ "$cap_ok" == "1" ]] && pass "capture doctrine present and wired (launch + rehydrate + sweep + writable repo)"

# ---- 11. Watch machinery is guarded (no runaway LLM, no leaks) ----
echo "== 11. watch machinery guards =="
st_ok=1
[[ -x "$ENGINE/lib/grandma-watch.sh" ]] || { bad "grandma-watch.sh missing or not executable"; st_ok=0; }
grep -q 'GRANDMA_DISTILLING=1' "$ENGINE/lib/grandma-watch.sh" 2>/dev/null || { bad "watch LLM calls not guarded with GRANDMA_DISTILLING"; st_ok=0; }
grep -q 'DIGEST_CAP' "$ENGINE/lib/grandma-watch.sh" 2>/dev/null || { bad "watch digests have no per-tick cap"; st_ok=0; }
grep -q 'tick.lock' "$ENGINE/lib/grandma-watch.sh" 2>/dev/null || { bad "watch tick has no lockfile (concurrent ticks)"; st_ok=0; }
if [[ "$HOME_OK" == "1" ]]; then grep -q '^watches/' "$ROOT/.gitignore" 2>/dev/null || { bad "watches/ not gitignored in memory home"; st_ok=0; }; fi
[[ -f "$ENGINE/prompts/watch-digest.md" && -f "$ENGINE/prompts/watch-report.md" ]] || { bad "watch prompts missing"; st_ok=0; }
grep -q 'grandma-watch.sh" tick' "$ENGINE/lib/grandma-launch.sh" 2>/dev/null || { bad "launch does not tick active watches"; st_ok=0; }
[[ "$st_ok" == "1" ]] && pass "watch machinery guarded (cap, lock, distill-guard, gitignore, wired)"

# ---- 12. Engine purity: no personal data in the public engine ----
echo "== 12. engine contains no personal data =="
pd_ok=1
# pattern assembled from parts so this file never matches itself
pn="an""shu"
hits="$(grep -rniE "$pn" "$ENGINE/lib" "$ENGINE/prompts" "$ENGINE/bin" "$ENGINE/templates" 2>/dev/null | grep -v 'grandma-test.sh' || true)"
[[ -n "$hits" ]] && { bad "personal name in engine: $(echo "$hits" | head -3)"; pd_ok=0; }
up="/Use""rs/"
hits2="$(grep -rn "$up" "$ENGINE/lib" "$ENGINE/prompts" "$ENGINE/bin" "$ENGINE/templates" 2>/dev/null | grep -v 'grandma-test.sh' || true)"
[[ -n "$hits2" ]] && { bad "hardcoded user path in engine: $(echo "$hits2" | head -3)"; pd_ok=0; }
[[ "$pd_ok" == "1" ]] && pass "engine free of personal names and user paths"

echo
if [[ "$fail" == "0" ]]; then echo "grandma-test: ALL PASS"; else echo "grandma-test: FAILURES ABOVE"; fi
exit "$fail"
