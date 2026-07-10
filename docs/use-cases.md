# Day to day with grandma

Eight things you can do the week you install her. Every transcript below is the real
shape of the product, with names genericized.

---

## 1. Stop re-explaining your stack every session

You told it yesterday. You are telling it again today. Never a third time:

```text
$ grandma acme
you> quick reminder since you keep getting this wrong: backend is Go on GCP,
     frontend is Next.js, db is Postgres. migrations only through atlas.
grandma> ✓ noted (state-change) -> acme/facts.md: Go/GCP backend, Next.js front,
         Postgres, migrations via atlas only
```

Every future `grandma acme` session starts already knowing this. The fact costs you
one sentence, once.

---

## 2. The correction that sticks forever

Corrections are the highest-value thing an agent can learn, and the first thing a
stateless one forgets:

```text
you> stop. we never use yarn here. pnpm. this is the second time.
grandma> ✓ noted (correction) -> acme/facts.md: pnpm only, yarn is banned
```

Corrections route to memory that loads on every session in that sweater. Project-level
lessons go into that project's own CLAUDE.md, so "never do X again" actually means
never.

---

## 3. Client A and client B, and a wall between them

You do work for two companies. Their stacks, their vocabulary, their secrets policies
must never mix:

```text
$ grandma client-a        # loads global + client-a. Nothing about client-b exists here.
$ grandma client-b        # and vice versa
```

This is not a convention, it is an enforced invariant: `grandma test` verifies that
every sweater's bundle contains only global plus that sweater, and the check gates every
commit to the engine. Sweater isolation is the reason grandma exists.

---

## 4. Onboard a new project in five minutes

```text
$ grandma acme new-billing-service
  ⟳ acme does not know 'new-billing-service' yet — let's set it up...
```

Grandma interviews you (or reads the folder you point her at), writes the project's
CLAUDE.md, registers it in the sweater's catalog, and stops. From then on:

```text
$ grandma acme billing    # fuzzy match works
```

drops you into the project folder with global memory, sweater memory, and the project
playbook all loaded.

---

## 5. Survive a marathon session

Around hour three, Claude Code compacts the conversation and quietly loses its
standing instructions. You notice as it starts suggesting yarn again. With grandma,
compaction triggers a hook that re-injects your entire memory bundle on the spot:

```text
[conversation compacted]
grandma> (memory re-injected: global + acme, 4 files)
```

Hour six behaves like minute one. You do nothing.

---

## 6. End the day, review what she learned

Exit a session with Ctrl+D. A guarded background pass reads the transcript and writes
a proposal, never touching memory directly:

```text
$ grandma acme
  📝 1 pending memory proposal for acme — run: grandma review acme
  🧶 memory has 2 uncommitted changes — review: git -C ~/.grandma diff

$ grandma review acme     # see what she thinks was worth keeping, apply what you agree with
$ git -C ~/.grandma diff  # or read the raw diffs. your memory, your call.
```

Nothing enters memory permanently without passing through your git diff.

---

## 7. Find out why your sessions drag

```text
$ grandma watch start "what am I doing that makes sessions long and expensive?" --weeks 2
```

Grandma measures every session in the window (duration, turns, tokens by type,
compactions, tool calls), reads the substantial ones, and when the window ends you get
a notification and a report: the numbers, the patterns, ranked changes to make. Run
`grandma watch finish <slug>` any time to get the report early.

The first real report on grandma's own development found that seven marathon sessions
consumed 67 percent of all output tokens, and independently rediscovered two bugs the
author had already fixed by hand. It reads receipts, not vibes.

---

## 8. Grandma is not just for work

```text
$ grandma
  grandma — which sweater?
   1) acme
   2) side-project
   n) + describe a new sweater
  > n
  Describe the new sweater
  > my resume is at ~/docs/cv.pdf and I am hunting for staff engineering roles

  Sweater 'job-search' created. Run grandma job-search to start.
```

Job hunt, house move, tax season, wedding planning. Anything you context-switch into
repeatedly deserves a sweater. The resume stays where it is. Grandma stores the pointer,
never the file.

---

## The habit in one line

Start every piece of work with `grandma <sweater>` instead of `claude`, and correct her
freely when she is wrong. Everything else is automatic.
