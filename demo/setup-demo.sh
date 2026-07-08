#!/usr/bin/env bash
# Prepare a throwaway memory home for recording the hero demo.
# Nothing personal appears on screen: fake persona, fake client, temp dir.
set -euo pipefail
DEMO="${1:-/tmp/grandma-demo-home}"
rm -rf "$DEMO" && mkdir -p "$DEMO/global" "$DEMO/demo-acme"

cat > "$DEMO/global/identity.md" <<'ID'
---
scope: global
type: identity
updated: 2026-07-01
---

# Identity

- Name: Alex
- Role: senior software engineer, consulting for a few clients
- Core expertise: TypeScript, Node, cloud infra
ID

cat > "$DEMO/global/preferences.md" <<'PR'
---
scope: global
type: preferences
updated: 2026-07-01
---

# Preferences

- Be terse and direct. Lead with the answer.
- Ask before anything hard to reverse.
PR

cat > "$DEMO/demo-acme/facts.md" <<'FA'
---
scope: demo-acme
type: facts
updated: 2026-07-01
---

# Acme — facts

- Acme: a client. TypeScript services in a monorepo.
FA

cat > "$DEMO/INDEX.md" <<'IX'
# INDEX
- [global/identity.md] — who Alex is
- [global/preferences.md] — how Alex works
- [demo-acme/facts.md] — the Acme client
IX

git -C "$DEMO" init -q && git -C "$DEMO" add -A && git -C "$DEMO" -c user.name=demo -c user.email=demo@example.com commit -qm seed

echo "demo home ready: $DEMO"
echo "record with:"
echo "  export GRANDMA_HOME=$DEMO"
echo "  grandma demo-acme"
