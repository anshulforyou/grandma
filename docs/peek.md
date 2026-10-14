# Deterministic peek

A project opts in by having `<sweater>/peek/<project>.json` in GRANDMA_HOME.
Its checks load alongside `<sweater>/peek/_sweater.json`. A sweater session with
no project uses `_sweater.json` alone. `GRANDMA_PEEK=off` disables the hooks.
The existing MessageDisplay shadow grader remains separate.

A checks file has `version: 1` and a `checks` array. Every check requires `id`,
`kind`, `cite`, `file`, `instead`, and `mode` (`shadow` or `enforce`). IDs must be
unique across the loaded files. Memory paths are relative to GRANDMA_HOME.
`project:CLAUDE.md` names the hook cwd's memory file, or the project's registered
source during replay. Cites must still appear verbatim in that file.

| Kind | Fields |
| --- | --- |
| `forbid_command` | `match` ERE, optional `allow_if` ERE |
| `forbid_text` | `paths` glob, `match` ERE |
| `require_before` | `gate: {tool, match}`, `needs: {tool, match}`, `window` |
| `recall_on` | `trigger: {tool, match}` |
| `grade_at_stop` | No additional fields, reserved for the Stop grader |

`require_before.window` is `session` or `since_gate`. A gate firing consumes the
previous prerequisite window, even when it was denied. Only successful ledger
entries satisfy prerequisites. `needs.tool` is `Read` (a path glob) or `Bash`
(an ERE). Optional `key: 1` requires exactly one capture group in `gate.match`.
Its captured value must occur in the satisfying ledger target as a whole token, so a key of 7 is not satisfied by a target naming 17.

Regexes are written as ERE, the dialect of grep -E and bash `=~`, and run in Python's engine so a hook call never starts a shell. Inside brackets the POSIX rules hold: classes such as `[[:space:]]` expand, and a leading `]` or a backslash is a plain character. A pattern that does not compile, or names an unknown class, drops its check as malformed. Two differences remain from grep -E: backslash escapes outside brackets take Python's meaning (`\s`, `\d`, `\b`), and an alternation picks the first branch that matches rather than the longest, which only matters for what a `key` captures.
Patterns run against the full input, so anchors refer to the beginning and end of that input, not of each line as with grep -E, and `.` crosses newlines. Use `(^|[;&|] *)yarn` to catch a command after `cd x &&`.
Write and Edit checks see the new text, including all MultiEdit replacements.
The path glob applies to file tools. Bash surface checks examine the whole
command, since arbitrary shell commands do not have one reliable destination.
Old Edit text and tool output are never used as produced text.

The prompt hook starts a turn and clears deny counters. A matching prompt
allows the action with a reminder. A paraphrase does not. Each check can deny
three times in a turn. Recall waits 20 tool calls between injections, carries
less than 1500 characters per check, and less than 9000 characters per call.
Shadow checks only log what they would do.

Session scratch is in `.peek/<session>/`: `ledger.jsonl`, `state.json`,
`checks-cache.json`, `errors.jsonl`, and `decisions.jsonl`. The parsed checks
cache tracks check files and cited memory mtimes and sizes. Decision logs name
matched checks, overrides and releases, and include worker latency in
milliseconds. Invalid checks are skipped and logged. Hook failures allow the
call. Concurrent decision writers fail open under a session lock.

Replay uses the same decision function and treats shadow checks as enforce:

```sh
grandma peek replay transcript.jsonl --scope <sweater> --project <project> --json
grandma peek replay transcript.jsonl --scope <sweater> --checks /path/checks.json
```

The report includes each check's original mode, would-deny count, timestamps,
and the first 120 characters of each offending input. Recorded tool results
build the simulated ledger even when replay would have denied their calls.
No model runs. Replay writes only to its temporary directory.

## Where checks come from

Checks are derived from memory, and none of them runs until you say yes to it.

```sh
grandma peek rules build <sweater> [project]    # one model call proposes candidates
grandma peek rules review <sweater> [project]   # y approves, n rejects, Enter skips, q stops
grandma peek rules <sweater> [project]          # what is approved, and what went stale
grandma peek mode <sweater> [project] <id|all> shadow|enforce
```

A project's checks file is named for the first word of its catalog heading, so `## billing (Q3 rewrite | API)` gives `billing.json`, and `billing` is what the commands take. Two headings that share a first word are refused until one is renamed, since they would share a file.

A project build proposes checks only from the project's CLAUDE.md. The rest of the sweater's memory goes along so the model can tell when a project rule was replaced, and sweater-wide rules come from a build with no project, into `_sweater.json`. The build also sends a digest of the commands and written files from the project's recent sessions, so patterns match how a step really runs (through a wrapper script, say) instead of a guess. Each command is cut to 160 characters with ids folded, names from the project file that appear past the cut are listed after it, and bearer, authorization, token and key values are removed first.

Build asks the model (sonnet by default, `GRANDMA_PEEK_RULES_MODEL` to change it) for checks in the vocabulary above. Before anything is kept, each proposal must have a known kind, a pattern that compiles, an `instead` that names something to do rather than something to wait for, and a cite found word for word in the file it names, and in a project build that file must be the project's own. Whatever passes is stored as candidates under `.peek/candidates/`, which git ignores. A rebuild replaces the candidates and leaves out anything already approved or rejected. Build refuses to run inside another grandma model call, allows six builds an hour (`GRANDMA_PEEK_RULES_CAP`), and holds a lock so two builds never overlap. `GRANDMA_DRY_RUN=1` prints the plan and makes no call.

Review walks the candidates one at a time and shows the rule, the pattern, the alternative, and how many times the check would have fired in the project's last 30 sessions (`GRANDMA_PEEK_REVIEW_SESSIONS`), quoting the calls it would have stopped. Only a typed y writes a check, into `<sweater>/peek/<project>.json`, and it lands in shadow mode. A closed input or a blank line approves nothing. Turning blocking on is a separate `peek mode` step, once the shadow log shows the check is right. The launcher prints one line when candidates are waiting.
