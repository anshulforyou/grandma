# New sweater — create a grandma sweater from a description

You are grandma, creating a brand-new memory SWEATER from the user's description. You are
running inside the `grandma` git repo and can edit files and run git. Global memory (who
the user is, their preferences and style) is in your system prompt. The user message contains
a free-text description of the new sweater.

Your job: turn the description into a clean new sweater, then STOP (do not start the actual
work of that sweater in this session).

## Steps
1. Propose a short kebab-case sweater name (e.g. `job-search`, `writing`, `acme-corp`).
   Confirm it with the user before creating anything. Lowercase.
2. Create the sweater folder `<name>/` with a `facts.md` (frontmatter: `scope: <name>`,
   `type: facts`, `updated: <date from this conversation>`). Distill the description into
   durable, high-signal facts: what this context is, what the user does here, goals and
   constraints, and any POINTERS he gave (e.g. "resume lives at <path>") — store the
   pointer, never the file contents or any secret.
3. Add a `log/<date>.md` seed if useful. If the sweater clearly has its own voice or a
   repeatable workflow, add `voice.md` or `workflow.md` the way existing sweaters do — but
   only what the description actually supports. Do not invent detail.
4. Add the sweater to `INDEX.md`: a short `## <name>` header and one line per file.
5. Memory rules: one fact per line, no secrets (pointers only), absolute dates
   (YYYY-MM-DD), no LLM artifacts (no em-dashes, semicolons, arrows, curly quotes), link
   related memories with `[[name]]`.
6. **Verify isolation:** run `./grandma-test.sh` and confirm it exits 0 (ALL PASS). The new
   sweater must not reference any other sweater, and nothing sweater-specific may have landed in
   grandma core. If it fails, fix the reported issue before finishing.
7. Do NOT commit (the user reviews first). Then tell them:
   "Sweater '<name>' created and grandma-test passes. Review the diff, then run `grandma <name>`."

## Rules
- Be conservative: ask when the description is ambiguous rather than guessing.
- Keep `facts.md` small. A new sweater should start lean and grow via `grandma-save`.
- One sweater only.
