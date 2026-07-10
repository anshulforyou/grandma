# Ingest — build a project catalog for a sweater

You are running inside the `grandma` git repo and can edit files and run git. You are
given a list of project `CLAUDE.md` files (project name -> absolute path) that all
belong to ONE sweater. Your job: distill each into a compact catalog entry so grandma
knows the user's projects in this sweater. The current sweater memory, if any,
is in your system prompt.

## Steps
1. Read each `CLAUDE.md` at the given paths (they live in an `--add-dir`'d folder, so
   you can read them).
2. For each, judge: is this genuinely one of the user's work projects for this sweater, or
   just a third-party repo's `CLAUDE.md` that happens to be in the tree? SKIP unrelated
   third-party ones; list what you skipped and why.
3. For each kept project, write a compact entry into `<sweater>/projects.md`:
   ```
   ## <project-name>
   - role: <how the user works this project, inferred>
   - status: <one line: where things stand>   (only if the doc says so; else "unknown")
   - what: <1-2 lines: what it is + what the user does on it>
   - source: <absolute path to the CLAUDE.md>
   ```
   Also include any extra per-project fields the loaded sweater memory asks for (a sweater may
   define additional catalog fields).
   Keep entries SHORT. This is a roster, not a copy. Deep context stays in the
   project's own `CLAUDE.md` (auto-loaded when the user works in that folder).
4. Order entries alphabetically. If `projects.md` already exists, MERGE: update
   existing entries in place, add new ones, never duplicate. Leave entries for
   projects not in this run untouched.
5. If the sweater is brand new (no `facts.md`), create a minimal `<sweater>/facts.md`
   describing the engagement at a high level, and add the sweater to `INDEX.md`.
6. Ensure `INDEX.md` has a pointer to `<sweater>/projects.md`.
7. Bump the `updated:` frontmatter on any file you change (use the latest date you can
   infer from the docs; do not invent a date).
8. Show a summary: projects ingested, projects skipped (with reason), files changed.
9. **Do not commit.** Tell the user to review `git diff` and commit when satisfied.

## Rules
- Distill, do not dump. No copying whole `CLAUDE.md` content into memory.
- One sweater only. Route nothing to other sweaters.
- `projects.md` frontmatter: `sweater`, `type: catalog`, `updated`.
- No secrets (store the path, never secret values).
- No LLM artifacts (no em-dashes, semicolons, arrows, curly quotes) in what you write.
- Be conservative: if unsure whether something is a real project, ask or skip and note it.
