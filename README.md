# grandma 🧶

**The terminal that remembers you.**

Your AI forgets everything between sessions. Grandma gives Claude Code a persistent,
scoped, git-owned memory: who you are, how you work, and what each of your contexts
(jobs, clients, side projects) needs — loaded automatically, learned passively,
reviewable as plain markdown with `git diff`.

> Full README, docs, and demo coming with the public launch. For now:
>
> ```sh
> git clone https://github.com/anshulforyou/grandma && cd grandma
> ./bin/grandma init
> ```
>
> `grandma help` for commands. `grandma doctor` if anything misbehaves.

- Memory is **files you own** in your private `GRANDMA_HOME` — no server, no vector DB, no telemetry.
- **Scope isolation** — client A's context can never leak into client B's session, enforced by a 12-check test suite that gates every commit.
- **Self-healing** — memory survives context compaction; sessions learn durable facts as you talk (`✓ noted`).

MIT. Built by [@anshulforyou](https://github.com/anshulforyou).
