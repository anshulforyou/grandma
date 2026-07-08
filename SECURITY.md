# Security

## Model

- **Your memory never leaves your machine.** The engine makes no network calls of its
  own. Model calls happen through your own Claude Code installation and account.
- **No telemetry.** Nothing is collected, phoned home, or aggregated.
- **Secrets stay out of memory by policy and by test.** The capture doctrine instructs
  sessions to store pointers (where a credential lives), never values, and the
  integrity suite greps memory for token patterns on every run.
- **Hooks execute shell commands** from your project's `.claude/settings.local.json`.
  Grandma only installs hooks pointing at scripts inside this engine, installs are
  idempotent, and every hooked script carries recursion guards and cost breakers.
  Review `lib/grandma-rehydrate.sh` and `lib/grandma-session-end.sh`; they are short.
- **Your memory home is a git repo you control.** Treat it like a diary: keep the
  remote private if you add one.

## Reporting

Open a GitHub security advisory or email the maintainer (see profile). Please do not
open public issues for anything involving leaked personal data.
