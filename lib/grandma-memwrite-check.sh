#!/usr/bin/env bash
#
# grandma-memwrite-check — PreToolUse hook on Write/Edit/MultiEdit: keep the always-loaded
# memory files short and free of copies.
#
# Every .md at a sweater's root and global/identity.md + global/preferences.md loads into every
# session. Captures used to append there, so one note landed five times and single lines grew
# past 3,000 chars. This refuses an edit to one of those files when a line it adds is too long,
# or repeats a line already in the file, and says what to do instead (update the existing line,
# or put the detail in notes/ and leave a one-line pointer).
#
# Usage (as a hook): grandma-memwrite-check.sh
# Reads the PreToolUse JSON on stdin. Never fails the tool on its own error: it only denies on a
# finding. GRANDMA_MEMWRITE_MAX sets the line cap (default 400 chars).

set -uo pipefail

ROOT="${GRANDMA_HOME:-$HOME/.grandma}"
command -v python3 >/dev/null 2>&1 || exit 0

# The script itself arrives on python's stdin, so the hook JSON travels in the environment.
GRANDMA_HOOK_INPUT="$(cat 2>/dev/null || true)" python3 - "$ROOT" "${GRANDMA_MEMWRITE_MAX:-400}" <<'PY' || exit 0
import json, os, re, sys

root, cap = os.path.realpath(sys.argv[1]), int(sys.argv[2])
try:
    hook = json.loads(os.environ.get("GRANDMA_HOOK_INPUT") or "")
except ValueError:
    sys.exit(0)
tool, ti = hook.get("tool_name", ""), hook.get("tool_input") or {}
path = ti.get("file_path") or ""
if tool not in ("Write", "Edit", "MultiEdit") or not path.endswith(".md"):
    sys.exit(0)
real = os.path.realpath(os.path.expanduser(path))
rel = os.path.relpath(real, root)
parts = rel.split(os.sep)
# always loaded: <sweater>/<file>.md and global/{identity,preferences}.md
loaded = (not rel.startswith("..") and len(parts) == 2 and not parts[0].startswith(".")
          and (parts[0] != "global" or parts[1] in ("identity.md", "preferences.md")))
if not loaded:
    sys.exit(0)

try:
    with open(real, encoding="utf-8") as f:
        before = f.read()
except OSError:
    before = ""

def apply(text, old, new, every):
    return text.replace(old, new) if every else text.replace(old, new, 1)

if tool == "Write":
    after = ti.get("content") or ""
elif tool == "Edit":
    after = apply(before, ti.get("old_string") or "", ti.get("new_string") or "", ti.get("replace_all"))
else:
    after = before
    for e in ti.get("edits") or []:
        after = apply(after, e.get("old_string") or "", e.get("new_string") or "", e.get("replace_all"))

def key(line):
    # same text once bullets, markup, case and spacing are ignored, judged on its first 80 chars
    return re.sub(r"[\s*_`#>-]+", " ", line).strip().lower()[:80]

old_lines = before.splitlines()
remaining = {}
for line in old_lines:
    remaining[line] = remaining.get(line, 0) + 1
added = []
for line in after.splitlines():
    if remaining.get(line):
        remaining[line] -= 1
    elif line.strip():
        added.append(line)

problems = []
for line in added:
    if len(line) > cap and not line.lstrip().startswith(("|", "```", "    ")):
        problems.append(f"a line of {len(line)} chars (cap {cap}): \"{line[:70]}...\"")
seen = {}
for line in after.splitlines():
    k = key(line)
    if len(k) >= 30:
        seen[k] = seen.get(k, 0) + 1
for line in added:
    k = key(line)
    if len(k) >= 30 and seen.get(k, 0) > 1:
        problems.append(f"a line the file already has: \"{line[:70]}...\"")

if not problems:
    sys.exit(0)
reason = (f"grandma: {rel} loads into every session, so it stays short and has no copies. "
          "This edit adds " + "; ".join(dict.fromkeys(problems)) + ". "
          "Update the existing line in place instead of adding another, keep each entry to one short "
          "rule (no incident story or quotes), and put long detail in "
          f"{parts[0]}/notes/<topic>.md with a one-line pointer here.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "permissionDecision": "deny",
                                         "permissionDecisionReason": reason}}))
PY
exit 0
