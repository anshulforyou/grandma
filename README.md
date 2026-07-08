<p align="center">
  <img src="assets/grandma.gif" width="260" alt="grandma, knitting your memory threads" />
</p>

<h1 align="center">grandma</h1>
<p align="center"><b>The terminal that remembers you.</b></p>

<p align="center">
  <a href="https://github.com/anshulforyou/grandma/actions"><img src="https://github.com/anshulforyou/grandma/actions/workflows/test.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <img src="https://img.shields.io/badge/telemetry-none-blueviolet" alt="no telemetry">
</p>

Your AI forgets everything between sessions. Every morning you re-explain your stack, your conventions, your client, your life. Grandma fixes that. She gives Claude Code a persistent, scoped, git-owned memory: who you are, how you work, and what each of your contexts needs. Loaded automatically. Learned passively while you talk. Reviewable as plain markdown with `git diff`.

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

That is the whole product. She just remembers. Watch it happen:

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
<scope>/            one folder per context: a job, a client, loaded for that scope only
                    a side project, your job hunt
project CLAUDE.md   deep per-project instructions            auto-loaded in that folder
```

- `grandma acme` assembles global + acme memory and launches Claude Code with it.
- `grandma acme billing-api` also drops you into that project so its CLAUDE.md rides along.
- `grandma` alone shows a picker, including "describe a new scope" where you explain a new context in plain words and grandma scaffolds it.

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
| Scope isolation | hard guarantee, tested | one file for everything | opaque | query-dependent |
| Review changes | `git diff` | manual | no | no |
| Learns passively | yes | no | sometimes | app-dependent |
| Survives compaction | yes, self-heals | partially | n/a | n/a |
| Telemetry | none | none | yes | varies |

## Trust

- **12 tested invariants** guard the core promise: loading scope X injects exactly global + X and nothing else, the engine contains no scope jargon and no personal data, no secrets in memory, hooks cannot recurse or run away. The suite gates every commit and runs in CI on macOS and Linux.
- **No telemetry, no server, no accounts.** Your memory never leaves your machine.
- Failure modes are documented, not hidden: [docs/architecture.md](docs/architecture.md) includes the war stories, like the day a hook recursion produced 4,718 files before the circuit breaker existed.

## Commands

```text
grandma                        pick a scope, or describe a new one
grandma <scope> [project]      launch a remembered session
grandma init | doctor          setup and health checks
grandma save <scope> [project] distill a finished session into memory
grandma review [scope]         review what background distills proposed
grandma ingest [scope]         catalog an existing folder of projects
grandma watch ...              analysis campaigns over your sessions
grandma test [scope]           verify the integrity invariants
```

## Roadmap

- Adapters beyond Claude Code (Cursor, Codex CLI, aider)
- Community scope templates (share your best scope setups)
- Team scopes (a shared memory repo your whole team loads)
- Memory rollup (old logs compress instead of growing)

## License

MIT. Built by [@anshulforyou](https://github.com/anshulforyou), with the help of a grandma who never forgets.
