<p align="center">
  <img src="assets/grandma-mascot.gif" width="280" alt="grandma, knitting your memory threads" />
</p>

<h1 align="center">grandma</h1>
<p align="center"><b>The terminal that remembers you.</b></p>

<p align="center">
  <a href="https://github.com/anshulforyou/grandma/actions"><img src="https://github.com/anshulforyou/grandma/actions/workflows/test.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <img src="https://img.shields.io/badge/telemetry-none-blueviolet" alt="no telemetry">
</p>

Your AI forgets everything between sessions. Every morning you re-explain your stack, your conventions, your client, your life. Grandma fixes that. She gives Claude Code a persistent memory that is **yours** (plain markdown in your own git repo), **separated by sweater** (one per part of your life, kept apart), and **learned passively** while you work.

> **A sweater** is a part of your life you keep memory under: a company, a client, a
> platform like reddit, an area like job-search. Under a sweater live your projects.
> Grandma knits each sweater from its own memory, and the threads never cross.

**This is not `/compact`.** Compaction shrinks one conversation. Grandma does three things a single session never can:

- **Keeps your worlds apart.** Client A's memory never leaks into a client B session. Ever. It is a tested guarantee, not a habit.
- **Remembers across all of them, forever.** Tell her once, in any session; every future session in that sweater knows.
- **Analyzes your whole history and acts on it.** She can study weeks of your chats and turn what she finds into memory:

```text
$ grandma "analyse my last 2 weeks of chats, write how I actually write, and make it part of my identity"
grandma> read 1,297 of your messages across 19 sessions.
         ✓ wrote global/style.md (3 registers: how you type, how your work should read, how you write prompts)
         ✓ updated global/identity.md
         review it: git -C ~/.grandma diff
```

No other memory tool reads your own history back to you like that.

Here is the everyday loop. Teach her once, and a brand new session already knows:

```text
# Monday
$ grandma acme
you> we use pnpm here, never yarn. and never push to main directly.
grandma> ✓ noted (preference) -> acme/facts.md: pnpm only, no direct pushes to main
         ...continues your actual task...

# Thursday, brand new session
$ grandma acme
grandma> ▣ memory: acme loaded · 4 files · ~1.9k tokens
you> set up the new billing service
grandma> Scaffolding with pnpm. I'll open a PR rather than pushing to main.
```

Watch it happen:

<p align="center">
  <img src="demo/hero.gif" width="830" alt="teach grandma once on Monday, a fresh Thursday session already knows" />
</p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/anshulforyou/grandma/master/install.sh | bash
```

That clones the engine, creates your private memory home, and offers a two-minute interview where grandma learns who you are. Or manually:

```sh
git clone https://github.com/anshulforyou/grandma && cd grandma && ./bin/grandma init
```

Requirements: [Claude Code](https://claude.com/claude-code), git, jq, python3. macOS or Linux (Windows via WSL). `grandma doctor` checks everything and tells you how to fix what is missing.

## How it works

Three layers of memory, loaded in the right amounts at the right times:

```text
global/             who you are, how you like to work        always loaded
<sweater>/            one folder per context: a job, a client, loaded for that sweater only
                    a side project, your job hunt
project CLAUDE.md   deep per-project instructions            auto-loaded in that folder
```

- `grandma acme` assembles global + acme memory and launches Claude Code with it.
- `grandma acme billing-api` also drops you into that project so its CLAUDE.md rides along.
- `grandma` alone shows a picker, including "describe a new sweater" where you explain a new context in plain words and grandma scaffolds it.

Memory lives in `GRANDMA_HOME` (default `~/.grandma`), a git repo that belongs to you. The engine never stores your data next to its own code.

### She learns while you work

Every session carries a capture doctrine: when something durable comes up (a preference, a correction, a fact that changed, a lesson), grandma writes it to the right memory file mid-conversation and tells you in one line:

```text
✓ noted (correction) -> global/preferences.md: never auto-commit, review diffs first
```

Writes land as uncommitted diffs in your memory repo. `git diff` is your review queue. Nothing is committed behind your back.

### She survives the context window

Long sessions hit Claude Code's compaction and normally lose their instructions. Grandma installs a hook that re-injects your memory the moment compaction happens, so hour six behaves like minute one. When you exit, a guarded background pass distills anything the session learned into a proposal you can review later.

### She watches for your blind spots

```sh
grandma watch start "why are my sessions getting longer?" --weeks 2
```

For two weeks grandma measures every session (duration, turns, tokens, compactions, tool calls) and reads the substantial ones. When the window closes you get a notification and a grounded report: the patterns, the numbers, what to change. It found real bugs in its own development. It will find your habits too.

## Day to day

Eight recipes with real transcripts in [docs/use-cases.md](docs/use-cases.md):

1. Stop re-explaining your stack every session
2. The correction that sticks forever
3. Client A and client B, with contexts that cannot bleed
4. Onboard a new project in five minutes
5. Survive a marathon session
6. End the day, review what she learned
7. Find out why your sessions drag
8. Grandma is not just for work

## Why files, why git

|  | grandma | one big CLAUDE.md | hosted AI memory | vector memory stores |
|---|---|---|---|---|
| Your data lives | your disk, your git repo | your repo | their servers | a database |
| Sweater isolation | hard guarantee, tested | one file for everything | opaque | query-dependent |
| Review changes | `git diff` | manual | no | no |
| Learns passively | yes | no | sometimes | app-dependent |
| Survives compaction | yes, self-heals | partially | n/a | n/a |
| Telemetry | none | none | yes | varies |

## Trust

- **12 tested invariants** guard the core promise: loading sweater X injects exactly global + X and nothing else, the engine contains no sweater jargon and no personal data, no secrets in memory, hooks cannot recurse or run away. The suite gates every commit and runs in CI on macOS and Linux.
- **No telemetry, no server, no accounts.** Your memory never leaves your machine.
- Failure modes are documented, not hidden: [docs/architecture.md](docs/architecture.md) includes the war stories, like the day a hook recursion produced 4,718 files before the circuit breaker existed.

## Commands

```text
grandma                        pick a sweater, or describe a new one
grandma <sweater> [project]      launch a remembered session
grandma init | doctor          setup and health checks
grandma save <sweater> [project] distill a finished session into memory
grandma review [sweater]         review what background distills proposed
grandma ingest [sweater]         catalog an existing folder of projects
grandma watch ...              analysis campaigns over your sessions
grandma test [sweater]           verify the integrity invariants
grandma knit                   coming next: she acts on what she learned (see below)
```

## Known quirks (v0.1)

- **Exit sessions with Ctrl+D**, not `/exit`. Claude Code's `/exit` skips SessionEnd
  hooks (upstream issue), so the end-of-session distill only runs on Ctrl+D. Manual
  fallback always works: `grandma save <sweater>`.
- Sweater names that collide with subcommands (`init`, `save`, `review`, `ingest`,
  `watch`, `test`, `doctor`, `help`) are reserved.
- macOS is the daily-driven platform. Linux is CI-tested but younger: if something
  misbehaves, `grandma doctor` first, then an issue with its output.

## Where this is going: remember, watch, knit

Grandma is being built in three phases, and you are looking at the first two.

1. **Remember** (shipped). Scoped memory: who you are, how you work, what each
   context needs. Loaded every session, learned passively, reviewed via git.
2. **Watch** (shipped). She analyzes how you actually work: `grandma watch` measures
   your sessions, reads the substantial ones, and reports the patterns behind your
   long sessions and wasted tokens.
3. **Knit** (next). The execution phase: she acts on what she learned. You will say
   things like

   ```sh
   grandma knit "based on what you watched, improve my prompt whenever it runs past 500 tokens"
   ```

   and from then on grandma intervenes in the moment: rewriting the oversized prompt
   before it ships, nudging you when a session shows the exact pattern that wasted
   two hours last week, applying the fix her own report recommended. Watch finds the
   patterns. Knit weaves the fix into your daily work. Contributions and design ideas
   for knit are welcome: open an issue with the `knit` label.

## Roadmap

- **grandma knit: the execution phase (see above)**
- Adapters beyond Claude Code (Cursor, Codex CLI, aider)
- Community sweater templates (share your best sweater setups)
- Team sweaters (a shared memory repo your whole team loads)
- Memory rollup (old logs compress instead of growing)

## License

MIT. Built by [@anshulforyou](https://github.com/anshulforyou). Knitted by a grandma who never forgets.
