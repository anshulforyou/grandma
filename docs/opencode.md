# Running a sweater in OpenCode

`grandma opencode <sweater> [project]` is `grandma <sweater> [project]` with
[OpenCode](https://opencode.ai) instead of Claude Code. Same memory, same doctrines, same review
queue. Grandma installs nothing into OpenCode to do it: no plugin, no config file, no file in your
project. It drives OpenCode through its own CLI and the HTTP API that CLI exposes.

```text
$ grandma opencode acme billing
  ⟳ memory: acme loaded · 5 files · ~1.9k tokens · project billing-api
  ⟳ memory is in the session instructions (1 entry), so compaction keeps it
  ⟳ launching OpenCode — she confirms memory in her first line
```

## Three ways in

```sh
grandma opencode acme                 # this one session
export GRANDMA_CLI=opencode           # every sweater, so plain `grandma acme` opens OpenCode
```

Or let one sweater choose, by adding `cli: opencode` to the frontmatter of any file at its root:

```markdown
---
scope: acme
type: facts
cli: opencode
updated: 2026-10-13
---
```

`GRANDMA_CLI` wins over a sweater's own line, so `GRANDMA_CLI=claude grandma acme` still opens
Claude Code for a sweater that asks for OpenCode. Any other value is refused rather than guessed.

## Commands

```text
grandma opencode <sweater> [project] [task...] [--full] [--writing] [-- opencode flags]
grandma opencode save <sweater> [project] --session <id> [--auto]
grandma opencode review [sweater]
grandma opencode doctor
```

`save` always takes the session id. The claude distiller finds "the newest transcript" in a folder,
which picks the wrong one as soon as two sessions are open; an id cannot. The launcher passes it for
you at exit, and `opencode session list` shows ids if you want to distill one by hand.

## How each job maps onto OpenCode

Grandma does the same jobs whichever CLI runs the session. Here is how each one lands in OpenCode,
measured against opencode 2.0.27.

**Load.** `assemble.sh` builds the bundle exactly as it does for claude, and the launcher wraps it in
the claude launcher's own preamble and capture doctrine. That text goes into the session as
*instruction entries*, through OpenCode's session instructions API. They sit at the system level
beside `AGENTS.md`. They are not conversation, so compaction cannot drop them, and they never touch
the project tree, so no memory-bearing `AGENTS.md` can be committed by accident. OpenCode reads only
`AGENTS.md`, never `CLAUDE.md`, so a registered project's `CLAUDE.md` rides in with the memory too.
That keeps the third tier intact.

**Write.** The session is created with its own permission rule allowing your memory home as an
external directory, the equivalent of the claude launcher's `--add-dir`. It applies to that one
session only.

**Survive compaction.** Nothing needs re-injecting, because instruction entries are not part of
what compaction summarises. OpenCode's own summary keeps the working state (objective, decisions,
work done, next move), which is what grandma's pre-compaction checkpoint exists to protect in
Claude Code. The checkpoint doctrine itself does not run here: OpenCode offers no hook to run it
from without a plugin.

**End.** OpenCode has no session-end signal, and an idle session has not ended, so the launcher wraps
the terminal UI and distills when it returns. Close the window instead and the distill runs detached,
and its proposal is offered at your next launch, the same as with claude.

**Distill.** The whole transcript is read from OpenCode's API, every page, then staged inside your
memory home as the claude distiller stages its own. The model call runs in a throwaway session
whose rules deny every tool, so it can read what it is handed and answer, and nothing else. The
transcript and memory travel as file attachments, and the session is deleted the moment it answers.
The draft lands in `proposals/` in the same format, so `grandma review` and
`grandma opencode review` both see it. The same guards hold as for claude: a recursion guard, a
circuit breaker (`GRANDMA_AUTOSAVE_CAP`), a per-session lock, and a call that failed or timed out is
never retried and never handed to another CLI.

## Models

A session grandma creates starts on `GRANDMA_OPENCODE_MODEL` (`provider/model[#variant]`) when you
set it, otherwise on the model you last used in that folder. Leaving it to OpenCode's default would
be simpler, and wrong whenever that default cannot answer: the first line of a remembered session
would be an error. The distill answers on the model of the session's last turn.

## What does not carry over

- **MCP per sweater.** OpenCode cannot scope MCP servers to one session, so a sweater's `mcp.json`
  is not applied here, and the launch says so.
- **Watch campaigns** read Claude Code transcripts and run their digests with claude.
- **`ingest`** still runs through claude.
- **The first message is visible.** The confirmation request arrives as the session's first user
  message, because a launched UI can only be handed a prompt. The memory itself never appears in the
  conversation.

## Where the memory goes

The instruction entries live in OpenCode's local session store, beside the conversation they belong
to. Nothing is written to your OpenCode configuration, to your project, or anywhere else, and the
throwaway distill session is deleted after use. `opencode session export` includes a session's
instructions, so treat an exported grandma session like your memory repo: keep it private.

## Measured, not assumed

Each of these shaped the design, and each was observed on a real install before anything was built
on it.

- An instruction entry holds at most 256 KiB (`InstructionEntryValueTooLargeError`), and
  `opencode api` takes a request body only on its command line, where Linux caps a single argument
  at 128 KiB. Memory is therefore split into entries whose bodies stay under 96,000 bytes, so a large
  memory home still launches on Linux and macOS alike.
- `opencode api` writing a large response into a pipe stopped at 192 KiB; written to a file it was
  complete. Every response goes through a file.
- The session `context` endpoint returns only what the model currently sees, which after a
  compaction is a summary plus the recent tail. The distill reads the full message history instead.
- A session created without a model started on the configured default model.

## Settings

| Variable | Default | What it does |
| --- | --- | --- |
| `GRANDMA_CLI` | `claude` | `opencode` sends every sweater to OpenCode |
| `GRANDMA_OPENCODE_MODEL` | last model used in the folder | the model for new sessions and the distill |
| `GRANDMA_OPENCODE_BIN` | `opencode` | the opencode executable |
| `GRANDMA_OPENCODE_TIMEOUT` | `30` | seconds allowed for one API call |
| `GRANDMA_DISTILL_TIMEOUT` | `300` | seconds allowed for one distill call |
| `GRANDMA_OPENCODE_BODY_MAX` | `96000` | bytes in one API request body |
| `GRANDMA_OPENCODE_MAX_PAGES` | `500` | transcript pages read for one distill |
| `GRANDMA_AUTOSAVE_CAP` | `10` | proposals allowed in five minutes before the breaker trips |
| `GRANDMA_NO_AUTOSAVE` | unset | `1` skips the distill when you leave |
| `GRANDMA_DRY_RUN` | unset | `1` prints the plan and contacts nothing |

## The adapter, for contributors

The transport lives in `lib/adapters/opencode.sh`; `lib/grandma-opencode.sh` is the command. The
engine still selects memory and owns every doctrine, so the isolation, purity and secrets invariants
cover OpenCode sessions unchanged. Invariant 19 pins what is specific to this path: a guarded,
tool-less distill, and memory that reaches the session through instruction entries and never through
a file in a project tree. `test/cmd_opencode.sh` proves each guard fires against a fake `opencode`
(`make_fake_opencode` in `test/lib/assert.sh`), so CI needs no OpenCode install.

`oc_capabilities` prints the adapter's capability flags in the shape discussed in
[the launcher-adapter design](https://github.com/anshulforyou/grandma/discussions/13). Nothing in the
engine reads them yet; they are there so this adapter can move behind that interface without
changing what it does.
