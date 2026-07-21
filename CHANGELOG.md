# Changelog

## Unreleased

- `grandma update` / `grandma version`: update the engine in place with a fast-forward pull
  (never forces), and print the running version (the `VERSION` file plus the commit). No server
  and no telemetry: instead of checking anywhere, grandma prints one quiet launch line when your
  engine has gone stale (more than a week since your last update). Silence with
  `GRANDMA_NO_UPDATE_CHECK=1`; tune with `GRANDMA_UPDATE_STALE_DAYS`.
- `grandma search [sweater] <query>`: read-only literal grep across your memory, in
  `file:line:text` form. Uses ripgrep when present and grep otherwise (no new hard
  dependency), and both engines are made to agree. Exit 0/1/2 follows grep's convention.

## v0.1.0

First public cut.

- Scoped memory: global + per-scope files in your private GRANDMA_HOME, assembled and
  injected per session. Scope picker and describe-a-new-scope onboarding.
- Project layer: fuzzy-matched projects, per-project CLAUDE.md auto-loading, guided
  project onboarding.
- Passive learning: capture doctrine (seven categories) injected at launch,
  re-injected after compaction, shared by the exit distiller. Review via git diff.
- Compaction self-healing and guarded exit distills (recursion guard, circuit
  breaker, sandbox-safe transcripts).
- grandma watch: session-analytics campaigns with mechanical metrics, capped
  digests, and a synthesized report.
- 12-invariant integrity suite gating every commit and running in CI (macOS, Linux).
- One-line installer, grandma init interview, grandma doctor.
