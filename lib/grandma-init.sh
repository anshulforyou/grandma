#!/usr/bin/env bash
#
# grandma-init — first-run setup (`grandma init`) and health checks (`grandma doctor`).
#
# init: creates your private memory home (GRANDMA_HOME, default ~/.grandma) as its own
# git repo, seeds global memory templates, puts `grandma` on your PATH, and offers an
# interview session where grandma learns who you are. Idempotent: safe to re-run.

set -uo pipefail
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
# For grandma_splash / pick_mascot_renderer, so the interview shows the same mascot as a session.
source "$ENGINE/lib/grandma-lib.sh"

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
err()  { printf '  \033[31mmiss\033[0m %s\n' "$1"; }

# ------------------------------------------------------------------ doctor ----
cmd_doctor() {
  local bad=0
  echo "grandma doctor"
  echo "== dependencies =="
  if command -v claude >/dev/null 2>&1; then ok "claude CLI ($(claude --version 2>/dev/null | head -1))"
  else err "claude CLI not found — install Claude Code: https://claude.com/claude-code"; bad=1; fi
  if command -v jq >/dev/null 2>&1; then ok "jq"; else err "jq not found — brew install jq (or apt install jq)"; bad=1; fi
  if command -v python3 >/dev/null 2>&1; then ok "python3"; else err "python3 not found"; bad=1; fi
  if command -v git >/dev/null 2>&1; then ok "git"; else err "git not found"; bad=1; fi

  echo "== memory home ($ROOT) =="
  if [[ -d "$ROOT" ]]; then
    ok "exists"
    [[ -d "$ROOT/.git" ]] && ok "is a git repo (history + review via git diff)" || warn "not a git repo — run: git -C $ROOT init"
    [[ -f "$ROOT/global/identity.md" ]] && ok "global identity present" || warn "no global/identity.md — run: grandma init"
    local dirty; dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${dirty:-0}" -gt 0 ]] && warn "$dirty uncommitted memory change(s) — review: git -C $ROOT diff"
  else
    err "memory home missing — run: grandma init"; bad=1
  fi

  echo "== nice to have =="
  local mren; mren="$(pick_mascot_renderer)"
  if terminal_supports_graphics; then
    [[ -n "$mren" ]] && ok "mascot: GIF via $mren (graphics terminal)" \
                     || warn "graphics terminal but no renderer — 'brew install chafa' for the GIF mascot"
  else
    ok "mascot: wordmark logo (this terminal has no image protocol)"
  fi
  # Desktop notifications: macOS uses osascript (always present); Linux needs notify-send.
  if ! command -v osascript >/dev/null 2>&1; then
    command -v notify-send >/dev/null 2>&1 && ok "notify-send (watch-report desktop notifications)" \
      || warn "no notify-send — watch reports won't notify (apt install libnotify-bin / dnf install libnotify); verify with: grandma watch notify-test"
  fi
  case ":$PATH:" in *":$ENGINE/bin:"*) ok "grandma on PATH" ;; *) warn "engine bin not on PATH — add: export PATH=\"$ENGINE/bin:\$PATH\"" ;; esac

  [[ "$bad" == "0" ]] && echo "doctor: healthy" || { echo "doctor: fix the items above"; return 1; }
}

# -------------------------------------------------------------------- init ----
cmd_init() {
  echo "grandma init — setting up your memory home at $ROOT"
  mkdir -p "$ROOT/global"
  cd "$ROOT" || exit 1
  [[ -d .git ]] || { git init -q; echo "  + git repo (memory history, your review queue)"; }

  # seed templates without overwriting anything that exists
  local t
  for t in identity preferences; do
    if [[ ! -f "global/$t.md" ]]; then
      cp "$ENGINE/templates/$t.md" "global/$t.md"; echo "  + global/$t.md (template — fill or let the interview do it)"
    fi
  done
  [[ -f INDEX.md ]]      || { cp "$ENGINE/templates/INDEX.md" INDEX.md; echo "  + INDEX.md"; }
  [[ -f denylist.txt ]]  || { cp "$ENGINE/templates/denylist.txt" denylist.txt; echo "  + denylist.txt (your sweater-jargon guard list)"; }
  [[ -f .gitignore ]]    || { cp "$ENGINE/templates/home-gitignore" .gitignore; echo "  + .gitignore (proposals/, watches/, .distill/ stay local)"; }
  mkdir -p proposals watches .distill

  # commit the seed so the first doctor run is clean (captures show up as diffs later)
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    git add -A && git -c user.name="${GIT_AUTHOR_NAME:-grandma}" -c user.email="${GIT_AUTHOR_EMAIL:-grandma@local}" commit -qm "grandma init: seed memory home" || true
  fi

  # PATH + GRANDMA_HOME in the shell rc (idempotent)
  local rc=""
  case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc" ;; */bash) rc="$HOME/.bashrc" ;; esac
  if [[ -n "$rc" ]] && ! grep -q 'grandma engine' "$rc" 2>/dev/null; then
    {
      echo ''
      echo '# grandma engine'
      echo "export PATH=\"$ENGINE/bin:\$PATH\""
      [[ "$ROOT" != "$HOME/.grandma" ]] && echo "export GRANDMA_HOME=\"$ROOT\""
    } >> "$rc"
    echo "  + PATH added to $rc (open a new terminal or: source $rc)"
  fi

  echo
  cmd_doctor || true

  echo
  # Only run the interview when stdin is a REAL terminal. Under `curl ... | bash` stdin
  # is a pipe; Claude Code's TUI needs an interactive stdin, and feeding it a redirected
  # /dev/tty renders the UI but never delivers keystrokes — it hangs on the trust prompt.
  # So in the piped case we finish setup and hand off: the interview runs on the first
  # real `grandma`, where stdin is a genuine terminal (grandma-launch first_run_onboard).
  if [ -t 0 ] && command -v claude >/dev/null 2>&1; then
    printf 'Let grandma interview you now, so she knows who you are? [Y/n] '
    local a; read -r a
    if [[ "${a:-y}" =~ ^[Yy]?$ ]]; then
      local SYS; SYS="$(cat "$ENGINE/prompts/init-interview.md")"
      cd "$ROOT" || exit 1
      grandma_splash "grandma"
      exec claude --name "grandma:init" --append-system-prompt "$SYS" \
        "Introduce yourself, explain what a sweater is, interview me, and fill in my identity and preferences per your instructions."
    fi
  fi

  echo
  echo "grandma is set up. One more step, then she gets to know you:"
  echo
  case ":$PATH:" in
    *":$ENGINE/bin:"*) : ;;                                   # already live in this shell
    *) [[ -n "$rc" ]] && echo "  source $rc      # or just open a new terminal" \
                      || echo "  export PATH=\"$ENGINE/bin:\$PATH\"   # add to your shell rc to make it stick" ;;
  esac
  echo "  grandma            grandma introduces herself, interviews you, and knits your first sweater"
  echo "  grandma <sweater>  later: start a session that remembers that part of your life"
}

case "${1:-init}" in
  doctor) cmd_doctor ;;
  init|*) cmd_init ;;
esac
