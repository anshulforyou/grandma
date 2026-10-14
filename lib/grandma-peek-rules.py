#!/usr/bin/env python3
"""peek rules: validate model-proposed checks, walk the user through approving them, list, set mode.

Called by grandma-peek.sh, which resolves the sweater and project and owns the model call.
  ingest <root> <scope> <project> <project_dir> <model_output_file>
  review <root> <scope> <project> <project_dir>
  list   <root> <scope> <project> <project_dir>
  mode   <root> <scope> <project> <project_dir> <id|all> <shadow|enforce>
  shapes <root> <scope> <project> <project_dir>
An empty project means the sweater-wide file. Nothing reaches a checks file without a typed yes.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode = True   # importing the engine must never leave a cache in the engine dir
_spec = importlib.util.spec_from_file_location('peek_engine', str(Path(__file__).with_name('grandma-peek-engine.py')))
engine = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(engine)

KINDS = ('forbid_command', 'forbid_text', 'require_before', 'recall_on', 'grade_at_stop')
# An alternative must be something the session can do now. Waiting is how a rule gets dodged.
WAITING = re.compile(r'\b(wait|waiting|sleep|pause|slow down|be careful|take (your|more|some) time|'
                     r'spend more time|try again later)\b', re.IGNORECASE)
SESSIONS = int(os.environ.get('GRANDMA_PEEK_REVIEW_SESSIONS', '30'))
# The command digest goes to the model, so it is bounded and scrubbed of anything credential shaped.
SHAPE_WIDTH, SHAPE_COUNT, SHAPE_CHARS, PATH_COUNT = 160, 300, 40000, 100
SECRETS = [
    (re.compile(r'\b(Bearer|Basic)\s+\S+'), r'\1 <redacted>'),
    (re.compile(r'\b(Authorization|Cookie|X-Api-Key)(["\']?\s*:\s*)[^"\'\s]+', re.IGNORECASE), r'\1\2<redacted>'),
    (re.compile(r'\b(\w*(?:token|key|secret|password|cookie)\w*)=[^&\s"\']+', re.IGNORECASE), r'\1=<redacted>'),
    # A long unbroken run with a digit in it is a key, not a word. Slashes split it, so paths survive.
    (re.compile(r'(?=[A-Za-z_\-+=.]*[0-9])[A-Za-z0-9_\-+=.]{40,}'), '<redacted>'),
]
HEX = re.compile(r'[0-9a-f]{12,}')
# Names the project file puts in backticks, such as a script or an endpoint, are what rules are about.
TICKED = re.compile(r'`([^`\s]{3,60})`')
# Where a command really starts: a cd into the project or a scratch variable says nothing about it.
PREAMBLE = re.compile(r'^(cd\s+("[^"]*"|\'[^\']*\'|\S+)\s*(&&|;)\s*|[A-Za-z_]\w*=("[^"]*"|\S*)\s*(&&|;)?\s*)')


class Context:
    def __init__(self, root, scope, project, project_dir):
        self.root, self.scope, self.project = Path(root), scope, project
        self.project_dir = project_dir
        name = (project or '_sweater') + '.json'
        self.checks_file = self.root / scope / 'peek' / name
        self.sweater_file = self.root / scope / 'peek' / '_sweater.json'
        scratch = self.root / '.peek' / 'candidates' / scope
        self.candidates_file = scratch / name
        self.rejected_file = scratch / (name[:-5] + '.rejected.json')

    def memory_path(self, check):
        if check['file'] == 'project:CLAUDE.md':
            return Path(self.project_dir) / 'CLAUDE.md' if self.project_dir else None
        return self.root / check['file']

    def fresh(self, check):
        path = self.memory_path(check)
        try:
            return path is not None and '\n' not in check['cite'] and check['cite'] in path.read_text()
        except (OSError, UnicodeError):
            return False

    def approved(self):
        """Checks already in this project's file and the sweater file. Raises on a corrupt file."""
        found = []
        for path in dict.fromkeys([self.checks_file, self.sweater_file]):
            if path.is_file():
                data = json.loads(path.read_text())
                found.extend(c for c in data.get('checks', []) if isinstance(c, dict))
        return found


def key(check):
    return [check.get('kind', ''), check.get('cite', '')]


def read_list(path):
    value = engine.read_json(path, [])
    return value if isinstance(value, list) else []


def write_pretty(path, value):
    # Approved checks are reviewed memory, committed like any other file, so keep the diff readable.
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    os.replace(str(tmp), str(path))


def first_json(text):
    text = re.sub(r'```[A-Za-z]*', '', text)
    decoder = json.JSONDecoder()
    for start, char in enumerate(text):
        if char in '{[':
            try:
                return decoder.raw_decode(text[start:])[0]
            except ValueError:
                continue
    return None


def slug(value, fallback):
    value = re.sub(r'[^a-z0-9]+', '-', str(value).lower()).strip('-')[:48]
    return value or fallback


def ingest(ctx, output_file):
    data = first_json(Path(output_file).read_text(errors='replace'))
    proposed = data.get('checks') if isinstance(data, dict) else data
    if not isinstance(proposed, list):
        print('peek rules: the model reply held no checks list, nothing written.', file=sys.stderr)
        return 1
    try:
        approved = ctx.approved()
    except ValueError as error:
        print('peek rules: cannot read the existing checks file ({}), nothing written.'.format(error), file=sys.stderr)
        return 1
    known = {json.dumps(key(c)): 'already approved' for c in approved}
    known.update({json.dumps(k): 'rejected before' for k in read_list(ctx.rejected_file)})
    ids = {c.get('id') for c in approved}
    kept, dropped = [], {}

    def drop(reason):
        dropped[reason] = dropped.get(reason, 0) + 1

    for raw in proposed:
        if not isinstance(raw, dict) or raw.get('kind') not in KINDS:
            drop('unknown kind')
            continue
        check = dict(raw, mode='shadow')
        base = slug(check.get('id', ''), check['kind'].replace('_', '-'))
        check['id'], n = base, 2
        while check['id'] in ids:
            check['id'], n = '{}-{}'.format(base, n), n + 1
        if not engine.valid(check):
            drop('malformed')
        elif any(engine.compile_ere(p) is None for p in engine.patterns(check)):
            drop('pattern does not compile')
        elif WAITING.search(check['instead']):
            drop('instead is not an action')
        elif ctx.project and check['file'] != 'project:CLAUDE.md':
            # Sweater and global rules belong in the sweater file, not copied into every project.
            drop('not from the project file')
        elif not ctx.fresh(check):
            drop('cite not verbatim in memory')
        elif json.dumps(key(check)) in known:
            drop(known[json.dumps(key(check))])
        else:
            known[json.dumps(key(check))] = 'duplicate'
            ids.add(check['id'])
            kept.append(check)
    # A rebuild replaces whatever was pending: the newest read of memory wins.
    write_pretty(ctx.candidates_file, kept)
    where = ctx.scope + (' ' + ctx.project if ctx.project else '')
    print('peek rules: {} proposed, {} kept as candidates.'.format(len(proposed), len(kept)))
    for reason, count in sorted(dropped.items()):
        print('  dropped {}: {}'.format(count, reason))
    if kept:
        print('Nothing is enforced yet. Approve them one by one: grandma peek rules review {}'.format(where))
    return 0


def transcripts(ctx):
    """This project's most recent session transcripts, newest first, or None for a sweater."""
    if not ctx.project or not ctx.project_dir:
        return None
    folder = os.environ.get('GRANDMA_PEEK_TRANSCRIPTS') or str(
        Path.home() / '.claude' / 'projects' / re.sub(r'[^A-Za-z0-9]', '-', str(ctx.project_dir)))
    try:
        return sorted(Path(folder).glob('*.jsonl'), key=lambda f: f.stat().st_mtime, reverse=True)[:SESSIONS]
    except OSError:
        return []


def scrub(text):
    for pattern, replacement in SECRETS:
        text = pattern.sub(replacement, text)
    return text


def shape(command, names):
    """One digest line: the command's start, plus any named thing the cut would hide."""
    text = ' '.join(command.split())
    while True:
        trimmed = PREAMBLE.sub('', text, count=1)
        if trimmed == text or not trimmed:
            break
        text = trimmed
    text = HEX.sub('<id>', scrub(text))
    head, rest = text[:SHAPE_WIDTH], text[SHAPE_WIDTH:]
    hidden = [name for name in names if name in rest and name not in head]
    return head + ('  [later in it: {}]'.format(', '.join(hidden[:8])) if hidden else '')


def named(ctx):
    try:
        text = (Path(ctx.project_dir) / 'CLAUDE.md').read_text(errors='replace')
    except OSError:
        return []
    return sorted({HEX.sub('<id>', scrub(m)) for m in TICKED.findall(text)}, key=len, reverse=True)


def shapes(ctx):
    """The commands and written files from recent sessions, so patterns follow how work really runs."""
    files = transcripts(ctx)
    if not files:
        return 0
    commands, written, names = {}, {}, named(ctx)
    for path in files:
        try:
            lines = path.open(errors='replace')
        except OSError:
            continue
        with lines:
            for line in lines:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                message = record.get('message') if isinstance(record, dict) else None
                content = message.get('content') if isinstance(message, dict) else None
                for block in content if isinstance(content, list) else []:
                    if not isinstance(block, dict) or block.get('type') != 'tool_use':
                        continue
                    inp = block.get('input') if isinstance(block.get('input'), dict) else {}
                    if block.get('name') == 'Bash' and isinstance(inp.get('command'), str):
                        text = shape(inp['command'], names)
                        commands[text] = commands.get(text, 0) + 1
                    elif block.get('name') in ('Write', 'Edit', 'MultiEdit') and isinstance(inp.get('file_path'), str):
                        written[scrub(inp['file_path'])] = written.get(scrub(inp['file_path']), 0) + 1
    out, size = [], 0
    for text, count in sorted(commands.items(), key=lambda item: -item[1])[:SHAPE_COUNT]:
        row = '{:>4}x  {}'.format(count, text)
        if size + len(row) > SHAPE_CHARS:
            break
        out.append(row)
        size += len(row) + 1
    print('Commands from the last {} session(s), most frequent first, each cut to {} characters:'.format(
        len(files), SHAPE_WIDTH))
    print('\n'.join(out))
    if written:
        print('\nFiles written with Write or Edit:')
        print('\n'.join('{:>4}x  {}'.format(n, f) for f, n in
                        sorted(written.items(), key=lambda item: -item[1])[:PATH_COUNT]))
    return 0


def history(ctx, candidates):
    """Would-deny counts for each candidate over this project's recent sessions."""
    files = transcripts(ctx)
    if files is None:
        return None, {}
    report = {c['id']: {'would_deny': 0, 'events': []} for c in candidates}
    enforced = [dict(c, mode='enforce') for c in candidates if c['kind'] != 'grade_at_stop']
    for path in files:
        try:
            engine.replay_transcript(enforced, str(path), report)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return len(files), report


def describe(check):
    kind = check['kind']
    if kind == 'forbid_command':
        text = 'Bash command matching  {}'.format(check['match'])
        return text + ('   (allowed if  {})'.format(check['allow_if']) if 'allow_if' in check else '')
    if kind == 'forbid_text':
        return 'text matching  {}   in files  {}'.format(check['match'], check['paths'])
    if kind == 'require_before':
        return '{} matching  {}   needs a prior {}  {}   ({}{})'.format(
            check['gate']['tool'], check['gate']['match'], check['needs']['tool'], check['needs']['match'],
            check['window'], ', key must match' if check.get('key') else '')
    if kind == 'recall_on':
        return 'reminds on {} matching  {}'.format(check['trigger']['tool'], check['trigger']['match'])
    return 'judged at the end of each turn'


def review(ctx):
    candidates = read_list(ctx.candidates_file)
    if not candidates:
        print('No candidate checks waiting for {}. Make some with: grandma peek rules build {}'.format(
            ctx.scope, ctx.scope + (' ' + ctx.project if ctx.project else '')))
        return 0
    try:
        approved = ctx.approved()
        data = engine.read_json(ctx.checks_file, None) if ctx.checks_file.is_file() else {'version': 1, 'checks': []}
        if not isinstance(data, dict) or not isinstance(data.get('checks'), list):
            raise ValueError('not a checks file')
    except ValueError as error:
        print('peek rules: {} is unreadable ({}). Fix it before approving anything.'.format(ctx.checks_file, error),
              file=sys.stderr)
        return 1
    ids = {c.get('id') for c in approved}
    sessions, hits = history(ctx, candidates)
    rejected = read_list(ctx.rejected_file)
    pending = list(candidates)
    total = len(candidates)
    print('{} candidate check(s). Each one you approve starts in shadow mode: it logs, it does not block.'.format(total))
    print('Answer y to approve, n to reject, Enter to skip, q to stop. Skipped ones stay for later.\n')
    for number, check in enumerate(candidates, 1):
        if not ctx.fresh(check):
            print('[{}/{}] {} skipped: its line is no longer in memory.\n'.format(number, total, check['id']))
            pending.remove(check)
            continue
        print('[{}/{}] {}  ({})'.format(number, total, check['id'], check['kind']))
        print('  rule     "{}"  ({})'.format(check['cite'], check['file']))
        print('  checks   {}'.format(describe(check)))
        print('  instead  {}'.format(check['instead']))
        if sessions is None:
            print('  history  none, sweater-wide checks have no single project to replay')
        elif check['kind'] == 'grade_at_stop':
            print('  history  not replayable, this kind is judged by a model')
        else:
            seen = hits.get(check['id'], {'would_deny': 0, 'events': []})
            if check['kind'] == 'recall_on':
                print('  history  would have reminded {} time(s) in the last {} session(s)'.format(
                    seen.get('would_recall', 0), sessions))
            else:
                print('  history  would have blocked {} time(s) in the last {} session(s)'.format(
                    seen['would_deny'], sessions))
            for event in seen['events'][-3:]:
                print('           {}  {}'.format(event['timestamp'][:16], event['input'].replace('\n', ' ')))
        sys.stdout.write('approve? [y/n/q, Enter skips] ')
        sys.stdout.flush()
        answer = sys.stdin.readline()
        if not answer or answer.strip().lower() in ('q', 'quit'):
            print('\nStopped. {} candidate(s) kept for later.'.format(len(pending)))
            break
        answer = answer.strip().lower()
        if answer not in ('y', 'yes', 'n', 'no'):
            print('  skipped, still pending.\n')
            continue
        pending.remove(check)
        if answer in ('y', 'yes'):
            if check['id'] in ids:
                check = dict(check, id='{}-{}'.format(check['id'], int(time.time())))
            ids.add(check['id'])
            data['version'] = 1
            data['checks'].append(dict(check, mode='shadow'))
            write_pretty(ctx.checks_file, data)
            print('  approved, in shadow mode.\n')
        else:
            rejected.append(key(check))
            write_pretty(ctx.rejected_file, rejected)
            print('  rejected.\n')
        write_pretty(ctx.candidates_file, pending)
    write_pretty(ctx.candidates_file, pending)
    print('Checks file: {}'.format(ctx.checks_file))
    print('Turn blocking on when a check has earned it: grandma peek mode {} <id|all> enforce'.format(
        ctx.scope + (' ' + ctx.project if ctx.project else '')))
    return 0


def listing(ctx):
    shown = 0
    for path in dict.fromkeys([ctx.checks_file, ctx.sweater_file]):
        if not path.is_file():
            continue
        data = engine.read_json(path, None)
        if not isinstance(data, dict) or not isinstance(data.get('checks'), list):
            print('{}: unreadable, every check in it is off'.format(path))
            continue
        print('{}'.format(path.relative_to(ctx.root) if ctx.root in path.parents else path))
        for check in data['checks']:
            shown += 1
            if not engine.valid(check) or any(engine.compile_ere(p) is None for p in engine.patterns(check)):
                print('  {:<28} MALFORMED, off'.format(str(check.get('id', '?')) if isinstance(check, dict) else '?'))
                continue
            state = check['mode'] if ctx.fresh(check) else 'STALE, off: its line is gone from memory'
            print('  {:<28} {:<15} {}'.format(check['id'], check['kind'], state))
            print('      "{}"  ({})'.format(check['cite'], check['file']))
    if not shown:
        print('No approved checks for {}.'.format(ctx.scope + (' ' + ctx.project if ctx.project else '')))
    waiting = len(read_list(ctx.candidates_file))
    if waiting:
        print('{} candidate(s) waiting: grandma peek rules review {}'.format(
            waiting, ctx.scope + (' ' + ctx.project if ctx.project else '')))
    return 0


def set_mode(ctx, target, mode):
    if mode not in ('shadow', 'enforce'):
        print('peek mode: the mode is shadow or enforce, not {}'.format(mode), file=sys.stderr)
        return 1
    files = [ctx.checks_file] if target == 'all' else list(dict.fromkeys([ctx.checks_file, ctx.sweater_file]))
    changed = 0
    for path in files:
        data = engine.read_json(path, None) if path.is_file() else None
        if not isinstance(data, dict) or not isinstance(data.get('checks'), list):
            continue
        hit = False
        for check in data['checks']:
            if isinstance(check, dict) and (target == 'all' or check.get('id') == target) and check.get('mode') != mode:
                check['mode'] = mode
                changed += 1
                hit = True
            elif isinstance(check, dict) and check.get('id') == target:
                hit = True
        if hit:
            write_pretty(path, data)
            if target != 'all':
                break
    else:
        if target != 'all' and not changed:
            print('peek mode: no check named {} for {}'.format(target, ctx.scope), file=sys.stderr)
            return 1
    print('{} check(s) set to {}.'.format(changed, mode))
    return 0


def main(argv):
    if len(argv) < 5:
        print(__doc__, file=sys.stderr)
        return 2
    verb, ctx = argv[0], Context(*argv[1:5])
    try:
        if verb == 'ingest' and len(argv) == 6:
            return ingest(ctx, argv[5])
        if verb == 'review':
            return review(ctx)
        if verb == 'shapes':
            return shapes(ctx)
        if verb == 'list':
            return listing(ctx)
        if verb == 'mode' and len(argv) == 7:
            return set_mode(ctx, argv[5], argv[6])
    except KeyboardInterrupt:
        print('\nStopped. Everything answered so far is saved.')
        return 130
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
