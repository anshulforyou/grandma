# Contributing to grandma

Thanks for helping grandma remember better.

## Setup

```sh
git clone https://github.com/anshulforyou/grandma && cd grandma
git config core.hooksPath hooks     # the integrity gate becomes your pre-commit
./test/run.sh                       # the whole suite: invariants + smoke + onboarding + per-command
```

`./test/run.sh` runs everything: the structural invariants (`grandma test`), the
cold-install smoke, the onboarding e2e, and one behavioral test per command
(`test/cmd_*.sh`). Run a single one directly while iterating, e.g. `./test/cmd_review.sh`.
CI runs the same suite on macOS and Linux, plus `shellcheck -S warning`.

## The rules that will actually get your PR merged

1. **The engine is sweater-agnostic and person-agnostic.** No context-specific
   vocabulary, no personal names, no hardcoded user paths. Check 12 enforces this,
   and CI runs it. If your feature needs context-specific behavior, it belongs in
   memory files or prompts that read from memory, not in code.
2. **Bash 3.2 compatible** (macOS ships it): no associative arrays, no mapfile,
   guard empty-array expansion with `${arr[@]+"${arr[@]}"}`.
3. **Portability**: use the helpers in `lib/grandma-lib.sh` (file_mtime, file_size,
   epoch_date, notify_user) instead of `stat -f` / `date -r` / osascript directly.
4. **Anything that spawns a headless model call needs three things**: a recursion
   guard, a cost cap, and a lockfile or breaker. Read the war stories in
   docs/architecture.md to see why this is not negotiable.
5. **New invariants welcome.** If you fix a bug class, add the check that would have
   caught it to lib/grandma-test.sh.

## Definition of done for a new `lib/grandma-*.sh` command

The onboarding hang, and a dead `ingest` and a wrong-scope `review` that shipped alongside
it, all had the same cause: command paths that no test ever ran. So every new command (or
new sub-path of one) ships with:

1. **A dry-run smoke assertion.** If it ends in `exec claude` / `claude -p`, it MUST honor
   `GRANDMA_DRY_RUN=1` (print a plan, exit 0, no exec). Add a `test/cmd_<name>.sh` that runs
   it against the populated fixture (`test/lib/fixture.sh`) and asserts (a) the exit code and
   (b) that the output contains no `unbound variable`. That one check is what would have
   caught the `ingest`/`review` crash-on-invoke bugs — every command must survive `set -u`.
2. **A correctness assertion for any name/path parsing.** If it derives a scope, project, or
   filename, assert it against the **kebab-case** fixture sweater (`home-ops`), not just a
   one-word name. Splitting on `-` is a bug (that is exactly how `review` truncated
   `home-ops` to `home`).
3. **Shellcheck-clean at warning.** `shellcheck -S warning lib/grandma-<name>.sh` must pass.
   Suppress only genuine false positives with an annotated `# shellcheck disable=...` and a
   one-line reason (SC2154/SC2034 "unbound/unused" are how the shipped var-name bugs would
   have surfaced — do not blanket-ignore them).
4. **Guards proven to FIRE, if it spawns a headless model call.** Beyond rule 4 above, add a
   delta-test with the fake-claude shim (`make_fake_claude` in `test/lib/assert.sh`) that
   shows the recursion guard / circuit breaker actually stops work (with vs without), not
   merely that the string exists in the source.
5. **Registered in the runner.** Drop the file at `test/cmd_<name>.sh`; `test/run.sh` picks
   it up automatically. It must pass on both ubuntu-latest and macos-latest.

Fixture scope names must not appear in any CORE engine file — `grandma test` check 2 is
case-insensitive, so use invented names like `globex` / `home-ops` (never a real example
word from a prompt).

## Good first contributions

Linux polish, new use-case recipes for docs/use-cases.md, locale-safe dates,
adapter experiments for other agent CLIs. Look for `good first issue`.
