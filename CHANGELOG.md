# Changelog

## Unreleased

- New mascot art, rebuilt from a high-resolution transparent source. Same filenames and
  dimensions, so nothing else changes: the README header stays 440x440 flattened on GitHub
  dark, and the terminal splash stays 260x260 on black and the same size on disk, which
  matters because `imgcat` pushes that whole file through the tty on every launch.
- `grandma knit`: the sharing phase, first cut. `knit share <sweater> <project>` packages your
  memory of one project, strips the personal scope out of it, shows you the exact payload, and
  (only after you say yes) pushes it to a private `grandma-knit-<project>` repo under your own
  GitHub, inviting the teammates you name. On their side, the invitation shows up as one line at
  launch, and `grandma knit pull` accepts it and turns the share into a normal memory proposal
  they review with `grandma review`. Nothing merges by itself. No GitHub, or no `gh`? `--file`
  writes the same bundle to disk and `knit pull --file` reads it back. The launch check reads a
  cache refreshed by a detached, lock-guarded, time-capped poll, so it never waits on the
  network and a failed call never reads as "nothing waiting". Opt out with
  `GRANDMA_NO_KNIT_CHECK=1`; tune with `GRANDMA_KNIT_POLL_HOURS`.
- Fixed: only a real sweater can be loaded. Any top-level directory in the memory home used to
  resolve as one, so `grandma proposals` assembled every sweater's pending proposals into a
  single session. Resolution now goes through `list_scopes`, in both the launcher and
  `assemble.sh`.
- Fixed: hook commands are quoted. A project whose registered name contains a space or a
  parenthesis produced a `settings.local.json` command that died with a shell syntax error, so
  that project's end-of-session distill and pre-compaction checkpoint never ran, and never said
  so. Re-launching now also replaces a stale command instead of adding a correct one beside it.
- Fixed: a sweater sees exactly its own proposals. Filenames were built from the scope as typed
  while readers matched case-sensitively (so `grandma Aarc` wrote a proposal `grandma review
  aarc` could not find), and matching was by bare prefix (so reviewing `home` listed `home-ops`
  proposals and `--clear` would have deleted them). Proposals are now matched on the `scope=`
  header the distiller writes inside them, which is exact.
- Fixed: `grandma` refuses to knit a sweater whose name is structurally unusable, meaning a
  subcommand (it would be shadowed and never launch) or a folder grandma owns in your memory
  home (loading it would assemble whatever is inside). A folder that exists but carries no
  `scope:` frontmatter now says so instead of offering to knit over it.
- `grandma watch`: tool-usage lens. Metrics now count calls per tool name, not just the
  total, so `grandma watch status` shows your top tools live and the final report can
  reason about the mix. Mechanical (python over the transcript), no model call.
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
