# Contributing to grandma

Thanks for helping grandma remember better.

## Setup

```sh
git clone https://github.com/anshulforyou/grandma && cd grandma
git config core.hooksPath hooks     # the integrity gate becomes your pre-commit
./bin/grandma test                  # must pass before and after your change
./test/smoke.sh                     # cold-install smoke
```

## The rules that will actually get your PR merged

1. **The engine is scope-agnostic and person-agnostic.** No context-specific
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

## Good first contributions

Linux polish, new use-case recipes for docs/use-cases.md, locale-safe dates,
adapter experiments for other agent CLIs. Look for `good first issue`.
