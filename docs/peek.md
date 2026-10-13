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

Regexes use Bash ERE semantics, including POSIX character classes. They run
against the full input, so anchors refer to the beginning and end of that input,
not of each line as with grep -E. Use `(^|[;&|] *)yarn` to catch a command after `cd x &&`.
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
