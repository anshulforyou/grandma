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
                                    ├── .knit/           knit working copies (gitignored)
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
- **Exit distill.** When you launched with grandma, the launcher wraps the session (it
  does not `exec`), so it regains control when you quit and distills the transcript in the
  foreground, then shows the live diffs plus the drafted proposal and asks to review now or
  later. It marks the session with `GRANDMA_DEFER_DISTILL=1` so the SessionEnd hook stands
  down and nothing is distilled twice. A plain `claude` session (grandma not the launcher)
  still gets the distill from the detached, guarded SessionEnd hook, which drops a proposal
  file surfaced at your next launch. Either path applies nothing; `grandma review` is where
  you accept or discard.
- **Manual.** `grandma save <sweater> [project]` runs the distiller interactively with
  you in the loop.

Every route lands as uncommitted changes in your memory repo. Git is the review queue,
the history, and the undo.

## Knit: the path a shared memory takes

`grandma knit share <sweater> <project>` moves exactly one project's memory, and it moves
it through four gates.

1. **Scope.** The payload is built from the project's own `CLAUDE.md` and nothing else. The
   sweater's files and `global/` are never opened for it. That is the whole reason knit is
   per project rather than per sweater.
2. **Strip.** Line by line: out goes anything carrying the user's name (read from
   `global/identity.md`), an address, a credential shape, a term from their `denylist.txt`,
   a `<!-- private -->` marker, or anything inside a `<!-- knit:private -->` block. Absolute
   home paths become `~`. The count of dropped lines is reported, because a silent strip
   teaches nobody what it caught.
3. **Eyes.** The exact payload prints before anything moves, and a share that is not a
   terminal and has no `--yes` refuses outright. Nothing acts outward on its own here
   either.
4. **Transport.** A private repo `grandma-knit-<project>` under the user's own GitHub, one
   file per person under `shares/`, the teammate added as a collaborator. GitHub does the
   emailing. There is no grandma server, no account, and no key to paste, because the
   private repo's access list is the boundary. Nothing is encrypted, and the docs say so
   rather than implying a security level knit does not have. `--file` writes the same
   bundle to disk for anyone off GitHub.

Coming back the other way, an invitation is a notification problem. GitHub has no pollable
inbox for a gist mention (there is no gist search API and gist mentions never reach the
notifications API, which is repo-scoped), but a repository invitation sits in
`GET /user/repository_invitations`, which is exactly a pollable inbox. That single fact is
why the transport is a repo and not the secret gist the design started with.

How you find out about a share depends on how much you want to opt into.

At launch, grandma reads a cache file rather than the network, so a launch never waits on
GitHub. When that cache is stale (`GRANDMA_KNIT_POLL_HOURS`, default 8) it detaches a check
for next time, the same shape as the watch tick. The one exception is the very first check on
a machine: that runs in the foreground under a tight cap, because backgrounding it writes the
cache after the banner has already been read, which makes the launch that matters most to a
new recipient the one that shows nothing.

A check that finds a share it has not seen before also raises a desktop notification, so a
share can reach you without opening grandma at all. It fires once per share, not once per
check, because the check runs often and re-announcing the same pending share would be noise.

`grandma knit install-agent` goes further: an opt-in launchd job that checks every 60 seconds,
which makes arrival effectively instant. That is affordable only because the invitations
endpoint supports conditional requests and GitHub does not bill a `304 Not Modified`, so the
steady state is a free round trip that does no work. There is no push alternative to build
instead: GitHub offers no socket a client can hold open, and webhooks need a public URL, which
means a server. Installing verifies itself by removing the tick's own stamp and waiting for it
to reappear, because a launchd job that loads but cannot read the engine (macOS withholds
`~/Documents` from background agents) would otherwise be reported as installed while failing
every minute.

Whichever path finds it, the check takes a lock so a stalled one cannot spawn siblings, caps
itself with a wall clock, and only overwrites the cache when the call actually succeeded. A
timeout or a logged-out `gh` leaves the previous state alone: a bad network must never read
as "nothing is waiting for you".

A pulled share does not merge. It becomes a proposal in `proposals/`, named
`<scope>-knit-<project>-<stamp>.md` so the existing review flow resolves its sweater, and
the reviewing session is told to lay it against local memory and ask where the two disagree.
A content hash goes in a git-ignored ledger, so pulling twice is a no-op and a teammate's
updated share comes through as a new proposal. The pull then points at that proposal by name
rather than at `grandma review`, because someone else's memory is the thing you want to read
on its own instead of buried among your own pending distills.

Who you share with is remembered locally too. `grandma knit contacts` is a name-to-handle book
under the same git-ignored `.knit/`, so `--to Priyansh` works after the first time. It is
convenience state, never memory: never distilled, never shared. The handle is the part an
invite needs, because GitHub's collaborator API takes a username and cannot accept an address;
an email can be stored beside it, and an address grandma has not seen is looked up on GitHub,
which only matches people who made theirs public.

## Compaction self-healing

Claude Code compacts long conversations, and `--append-system-prompt` content does not
survive it. Grandma's SessionStart hook with the `compact` matcher fires right after
each compaction and re-injects the full bundle plus doctrine. This is why a six-hour
session does not degrade into an agent that forgot who you are.

## The integrity suite

`grandma test` verifies fifteen invariants. The interesting ones:

1. **Isolation.** Every sweater's assembled bundle contains only `global/` and that
   sweater. Nothing else, in any load mode.
2. **Engine purity.** No sweater names in engine logic, no sweater vocabulary (checked
   against your own `denylist.txt`), no personal names, no user paths.
3. **No secrets.** Memory holds pointers to where credentials live, never values. The
   suite greps for token patterns on every run.
4. **Hook safety.** The recursion guard, the circuit breaker, and the sandbox-readable
   transcript path must exist. These three each correspond to a real incident (below).
5. **Knit guards.** Sharing cannot lose its strip, its poll lock, its network cap, or its
   opt-out, and the launch banner has to stay wired to the launcher.

The suite runs as a git pre-commit gate on the engine and in CI on macOS and Linux.

### A known limit in the purity check

Check 2 greps each sweater name as a whole word against the engine's source, and it counts
prompt files as source. Prompt files are prose, full of example words. So a sweater named
after an ordinary word fails it: `work` matches ten files, and `job-search`, `reddit` and
`acme` all match too, which is unfortunate given those are the examples the README and the
new-sweater prompt hand people.

This is a false positive, not a leak. A leak is engine LOGIC branching on a sweater name.
A prompt that says "an area like job-search" is documentation. The real fix is to narrow
check 2 to executable logic, and to purge the example words from prompt prose per the rule
this repo already sets for itself. Until then, naming a sweater after a common word makes
`grandma test` fail with no cure but a rename.

Grandma does NOT try to prevent this by refusing such names. That was tried and reverted:
refusing every word the engine mentions rejected the names the product recommends, which is
worse than the problem. Only structurally impossible names are refused, the subcommands and
the folders grandma owns inside the memory home.

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
