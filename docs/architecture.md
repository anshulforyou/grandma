# How grandma works

For people who want to know what actually happens when they type `grandma acme`.

## The two repos

```text
engine (this repo, public)          GRANDMA_HOME (yours, private, default ~/.grandma)
├── bin/grandma                     ├── global/          identity.md, preferences.md
├── lib/*.sh      the machinery     ├── acme/            facts.md, people.md, projects.md, log/
├── prompts/*.md  the doctrines     ├── side-project/    ...
└── templates/    init scaffolding  ├── proposals/       background distill output (gitignored)
                                    ├── watches/         analysis campaigns (gitignored)
                                    └── denylist.txt     your sweater-jargon guard list
```

The engine is sweater-agnostic by tested invariant: it may not contain a sweater name, a
sweater's vocabulary, a personal name, or a user path. Anything context-specific lives in
memory files, which load only for their own sweater.

## Launch: what `grandma acme billing` does

1. `assemble` builds the bundle: `global/*.md` plus `acme/*.md` (decisions and logs are
   lazy, added with `--full`). Typical bundle: 1.5k to 4k tokens. A manifest prints so
   you see exactly what loaded and what it costs.
2. The project resolver fuzzy-matches `billing` against `acme/projects.md`, finds the
   folder, and the session launches inside it so the project CLAUDE.md auto-loads.
3. The bundle plus the capture doctrine ride in via `--append-system-prompt`.
4. Two hooks install idempotently into the project's `.claude/settings.local.json`:
   a SessionStart(compact) rehydrator and a SessionEnd distiller.
5. Notices print first: pending proposals, uncommitted memory diffs, finished watch
   reports. Then the mascot, then the session.

## The write path: how memory grows

Three routes, one definition of "worth remembering" (`prompts/capture.md`):

- **In-flight capture.** The session itself writes durable facts as they come up and
  announces each one. The doctrine defines seven categories (state-change, decision,
  correction, entity, procedure, preference, thread-state), an anti-list, and a
  precision-over-recall bias: a missed fact self-heals because it will come up again,
  noise does not.
- **Exit distill.** SessionEnd triggers a detached, guarded, headless pass that reads
  the transcript and writes a proposal file. It applies nothing. `grandma review`
  is where you accept or discard.
- **Manual.** `grandma save <sweater> [project]` runs the distiller interactively with
  you in the loop.

Every route lands as uncommitted changes in your memory repo. Git is the review queue,
the history, and the undo.

## Compaction self-healing

Claude Code compacts long conversations, and `--append-system-prompt` content does not
survive it. Grandma's SessionStart hook with the `compact` matcher fires right after
each compaction and re-injects the full bundle plus doctrine. This is why a six-hour
session does not degrade into an agent that forgot who you are.

## The integrity suite

`grandma test` verifies twelve invariants. The interesting ones:

1. **Isolation.** Every sweater's assembled bundle contains only `global/` and that
   sweater. Nothing else, in any load mode.
2. **Engine purity.** No sweater names in engine logic, no sweater vocabulary (checked
   against your own `denylist.txt`), no personal names, no user paths.
3. **No secrets.** Memory holds pointers to where credentials live, never values. The
   suite greps for token patterns on every run.
4. **Hook safety.** The recursion guard, the circuit breaker, and the sandbox-readable
   transcript path must exist. These three each correspond to a real incident (below).

The suite runs as a git pre-commit gate on the engine and in CI on macOS and Linux.

## War stories, kept on purpose

Grandma's guards were not designed in advance. Each one is a scar, and knowing them is
the best argument that the current design holds.

**The context leak.** A sweater-specific review convention was once baked into the
launcher, so every sweater heard about another context's workflow. The fix created the
purity invariants: the engine is sweater-agnostic, sweater rules live in sweater memory, and
a denylist test catches the next attempt. It caught two more leaks the same day it was
written.

**The 4,718-file runaway.** The exit distiller spawns a headless Claude session. That
session's own exit fired the SessionEnd hook again, which spawned another distiller,
forever. One night produced 4,718 proposal files. Three independent guards now exist:
an environment flag stops recursion, the headless pass runs from a directory with no
hooks, and a circuit breaker refuses to add proposals when too many appear in five
minutes. The test suite asserts all three forever.

**The blind distiller.** Fixing the runaway moved the headless pass to a neutral
directory, which put the transcript outside its sandbox. Every proposal politely
reported it could not read anything. Transcripts now stage inside the memory repo,
and a test pins the path.

**The graveyard shift that never ran.** The watch feature originally installed a
launchd agent for daily background analysis. macOS TCC silently blocks launchd from
reading `~/Documents`, so it failed with "Operation not permitted" on the first real
machine. Watches now tick opportunistically at every grandma launch, which needs no
permissions at all, and the launchd path is optional and honestly documented.

## Costs, honestly

- Assembling and loading memory: free (files) plus the bundle's token cost per session,
  visible in the manifest.
- In-flight capture: free. It rides the session you were already having.
- Exit distill: one small headless model call per substantial session, capped and
  breakered. Skippable with `GRANDMA_NO_AUTOSAVE=1`.
- Watch campaigns: metrics are pure python (free). Digests are capped per tick.
  The final report is one model call.
