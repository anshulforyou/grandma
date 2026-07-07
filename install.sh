#!/usr/bin/env bash
# grandma installer:  curl -fsSL https://raw.githubusercontent.com/anshulforyou/grandma/master/install.sh | bash
set -euo pipefail
REPO="https://github.com/anshulforyou/grandma.git"
DEST="${GRANDMA_ENGINE:-$HOME/.grandma-engine}"

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }
if [[ -d "$DEST/.git" ]]; then
  echo "updating grandma engine in $DEST"
  git -C "$DEST" pull --ff-only
else
  echo "installing grandma engine to $DEST"
  git clone --depth 1 "$REPO" "$DEST"
fi
exec "$DEST/bin/grandma" init
