#!/usr/bin/env python3
"""Deterministic peek checks, shared by hooks and offline replay."""
import copy
import fnmatch
import json
import os
from pathlib import Path
import re
import sys
import time

SUFFIX = '. Fix it and carry on, do not mention this check.'


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def write_json(path, value):
    tmp = str(path) + '.tmp'
    Path(tmp).write_text(compact(value))
    os.replace(tmp, path)


def append(path, value):
    with open(path, 'a') as stream:
        stream.write(compact(value) + '\n')


def rows(path):
    try:
        with open(path) as stream:
            for line in stream:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        yield value
                except ValueError:
                    continue
    except OSError:
        return


# POSIX classes, so a pattern written for grep -E keeps working. Values are set contents.
CLASSES = {
    'alpha': 'a-zA-Z', 'digit': '0-9', 'alnum': 'a-zA-Z0-9', 'upper': 'A-Z', 'lower': 'a-z',
    'space': ' \\t\\n\\r\\f\\v', 'blank': ' \\t', 'xdigit': '0-9A-Fa-f',
    'punct': re.escape('!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~'),
    'cntrl': '\\x00-\\x1f\\x7f', 'print': '\\x20-\\x7e', 'graph': '\\x21-\\x7e',
}
COMPILED = {}


def translate(pattern):
    """Python re for an ERE. Inside brackets POSIX rules hold: classes expand, a leading ] and a
    backslash are literal. Outside, `$` ends the whole input as with bash =~. None if invalid."""
    out, i, n = [], 0, len(pattern)
    while i < n:
        char = pattern[i]
        if char == '\\':
            if i + 1 == n:
                return None
            out.append(pattern[i:i + 2])
            i += 2
        elif char == '$':
            out.append('\\Z')
            i += 1
        elif char == '[':
            part, j = ['['], i + 1
            if j < n and pattern[j] == '^':
                part.append('^')
                j += 1
            if j < n and pattern[j] == ']':
                part.append('\\]')
                j += 1
            while j < n and pattern[j] != ']':
                if pattern.startswith('[:', j):
                    end = pattern.find(':]', j + 2)
                    if end < 0 or pattern[j + 2:end] not in CLASSES:
                        return None
                    part.append(CLASSES[pattern[j + 2:end]])
                    j = end + 2
                elif pattern.startswith('[=', j) or pattern.startswith('[.', j):
                    return None
                else:
                    # Escaped so Python reads them as plain members, never as set operators.
                    part.append('\\' + pattern[j] if pattern[j] in '\\[&|~' else pattern[j])
                    j += 1
            if j == n:
                return None
            out.append(''.join(part) + ']')
            i = j + 1
        else:
            out.append(char)
            i += 1
    return ''.join(out)


def compile_ere(pattern):
    if pattern not in COMPILED:
        source = translate(pattern)
        try:
            COMPILED[pattern] = re.compile(source, re.DOTALL) if source is not None else None
        except (re.error, OverflowError, RecursionError):
            COMPILED[pattern] = None
    return COMPILED[pattern]


class Matches:
    """Pattern requests in one batch. Each result is (0 hit, 1 miss, 2 invalid) and group 1."""
    def __init__(self):
        self.requests = {}
        self.results = {}

    def add(self, pattern, text):
        self.requests[(pattern, text)] = None

    def run(self):
        for pattern, text in self.requests:
            rx = compile_ere(pattern)
            found = rx.search(text) if rx is not None else None
            if rx is None:
                self.results[(pattern, text)] = (2, '')
            elif found is None:
                self.results[(pattern, text)] = (1, '')
            else:
                self.results[(pattern, text)] = (0, (found.group(1) or '') if rx.groups else '')

    def hit(self, pattern, text):
        return self.results[(pattern, text)][0] == 0


def has_key(key, target):
    # Bounded on both sides: the key for turn 7 must not be satisfied by a target naming turn 17.
    return bool(key) and re.search(r'(?<![0-9A-Za-z])' + re.escape(key) + r'(?![0-9A-Za-z])', target) is not None


def nonempty(value):
    return isinstance(value, str) and bool(value.strip()) and '\0' not in value


def patterns(check):
    kind = check['kind']
    if kind in ('forbid_command', 'forbid_text'):
        return [check['match']] + ([check['allow_if']] if 'allow_if' in check else [])
    if kind == 'require_before':
        return [check['gate']['match']] + ([check['needs']['match']]
                                          if check['needs']['tool'] == 'Bash' else [])
    if kind == 'recall_on':
        return [check['trigger']['match']]
    return []


def valid(check):
    if not isinstance(check, dict):
        return False
    if not all(nonempty(check.get(k)) for k in ('id', 'kind', 'cite', 'file', 'instead', 'mode')):
        return False
    if check['mode'] not in ('shadow', 'enforce') or '\n' in check['instead']:
        return False
    if check['file'] != 'project:CLAUDE.md' and (
            Path(check['file']).is_absolute() or '..' in Path(check['file']).parts):
        return False
    kind = check['kind']
    if kind == 'forbid_command':
        return nonempty(check.get('match')) and ('allow_if' not in check or nonempty(check['allow_if']))
    if kind == 'forbid_text':
        return nonempty(check.get('match')) and nonempty(check.get('paths'))
    if kind in ('require_before', 'recall_on'):
        for field in (('gate', 'needs') if kind == 'require_before' else ('trigger',)):
            value = check.get(field)
            if not isinstance(value, dict) or not all(nonempty(value.get(k)) for k in ('tool', 'match')):
                return False
        if kind == 'require_before':
            return (check.get('window') in ('session', 'since_gate')
                    and check['needs']['tool'] in ('Read', 'Bash')
                    and ('key' not in check or (type(check['key']) is int and check['key'] == 1
                                               and compile_ere(check['gate']['match']) is not None
                                               and compile_ere(check['gate']['match']).groups == 1)))
        return True
    return kind == 'grade_at_stop'


def signature(path):
    try:
        stat = Path(path).stat()
        return [stat.st_mtime_ns, stat.st_size]
    except OSError:
        return None


def project_file(root, scope, project, cwd):
    # Claude Code gives hooks the session's project root. The hook's cwd follows any cd the model
    # made, so a session working in a subfolder would see every project-cited check go stale.
    if os.environ.get('CLAUDE_PROJECT_DIR'):
        return str(Path(os.environ['CLAUDE_PROJECT_DIR']) / 'CLAUDE.md')
    if cwd:
        return str(Path(cwd) / 'CLAUDE.md')
    registry = root / scope / 'projects.md'
    try:
        name = ''
        for line in registry.read_text().splitlines():
            if line.startswith('## '):
                name = line[3:].strip()
            elif line.startswith('- source:') and name.casefold() == project.casefold():
                return os.path.expanduser(line.split(':', 1)[1].strip())
    except OSError:
        pass
    return str(root / scope / '.missing-project-CLAUDE.md')


def load_checks(root, scope, project, directory, cwd='', external=None):
    active = Path(external) if external else root / scope / 'peek' / (project + '.json' if project else '_sweater.json')
    if not active.is_file():
        return []
    files = [active]
    sweater = root / scope / 'peek' / '_sweater.json'
    if not external and project and sweater.is_file():
        files.append(sweater)
    source = project_file(root, scope, project, cwd)
    base = [str(p) for p in files] + [source, str(root / scope / 'projects.md')]
    cache_path = directory / 'checks-cache.json'
    cache = read_json(cache_path, {})
    if (cache.get('base') == base and cache.get('stamps')
            and all(signature(p) == stamp for p, stamp in cache['stamps'].items())):
        return cache['checks']
    stamps = {p: signature(p) for p in base}
    candidates, checks, seen = [], [], set()
    matcher = Matches()
    for path in files:
        data = read_json(path, None)
        if (not isinstance(data, dict) or type(data.get('version')) is not int
                or data['version'] != 1 or not isinstance(data.get('checks'), list)):
            append(directory / 'errors.jsonl', {'file': str(path), 'error': 'malformed checks file'})
            continue
        for check in data['checks']:
            if not valid(check) or check['id'] in seen:
                append(directory / 'errors.jsonl', {'file': str(path), 'error': 'malformed or duplicate check'})
                continue
            seen.add(check['id'])
            memory = source if check['file'] == 'project:CLAUDE.md' else str(root / check['file'])
            stamps[memory] = signature(memory)
            try:
                fresh = check['cite'] in Path(memory).read_text()
            except (OSError, UnicodeError):
                fresh = False
            if not fresh:
                append(directory / 'errors.jsonl', {'id': check['id'], 'error': 'stale cite'})
                continue
            candidates.append(check)
            for pattern in patterns(check):
                matcher.add(pattern, '')
    matcher.run()
    for check in candidates:
        if any(matcher.results[(p, '')][0] == 2 for p in patterns(check)):
            append(directory / 'errors.jsonl', {'id': check['id'], 'error': 'malformed ERE'})
        else:
            checks.append(check)
    write_json(cache_path, {'base': base, 'stamps': stamps, 'checks': checks})
    return checks


def tool_target(tool, inp):
    if tool == 'Bash':
        return inp.get('command', '')
    if tool in ('Read', 'Edit', 'MultiEdit', 'Write', 'NotebookEdit'):
        return inp.get('file_path', '')
    return next((inp[k] for k in ('file_path', 'command', 'pattern', 'query') if k in inp), '')


def domain(tool, inp):
    if tool == 'Bash':
        return inp.get('command', '')
    if tool == 'Read':
        return inp.get('file_path', '')
    if tool in ('Write', 'Edit', 'MultiEdit'):
        return inp.get('file_path', '') + '\n' + surface(tool, inp)
    return tool + ' ' + compact(inp)


def surface(tool, inp):
    if tool == 'Write':
        return inp.get('content', '')
    if tool == 'Edit':
        return inp.get('new_string', '')
    if tool == 'MultiEdit':
        return '\n'.join(edit.get('new_string', '') for edit in inp.get('edits', []))
    return inp.get('command', '')


def reason(check):
    tail = '" ({}). Instead: {}{}'.format(check['file'], check['instead'].rstrip('.'), SUFFIX)
    # Even pathological source paths and alternatives must leave room for the silence contract.
    if len(tail) > 285:
        tail = '" ({}). Instead: {}{}'.format(check['file'][:80], check['instead'][:100].rstrip('.'), SUFFIX)
    room = 300 - len('grandma: "') - len(tail)
    cite = check['cite'].replace('\n', ' ')
    if len(cite) > room:
        cite = cite[:room - 3] + '...'
    return 'grandma: "' + cite + tail


def decide(checks, tool, inp, ledger, prompt, state):
    """Pure transition. No state files, clocks, environment, or model calls."""
    updated = copy.deepcopy(state)
    call = updated.get('calls', 0) + 1
    updated['calls'] = call
    for field in ('denies', 'recalls', 'gates'):
        updated.setdefault(field, {})
    text = domain(tool, inp)
    matcher, relevant = Matches(), []
    for check in checks:
        kind = check['kind']
        if kind == 'forbid_command' and tool == 'Bash':
            match, value = check['match'], text
            if 'allow_if' in check:
                matcher.add(check['allow_if'], text)
        elif kind == 'forbid_text' and tool in ('Write', 'Edit', 'MultiEdit', 'Bash'):
            if tool != 'Bash' and not fnmatch.fnmatchcase(inp.get('file_path', ''), check['paths']):
                continue
            match, value = check['match'], surface(tool, inp)
        elif kind in ('require_before', 'recall_on'):
            trigger = check['gate'] if kind == 'require_before' else check['trigger']
            if trigger['tool'] != tool:
                continue
            match, value = trigger['match'], text
            if kind == 'require_before' and check['needs']['tool'] == 'Bash':
                for entry in ledger:
                    if entry.get('tool') == 'Bash':
                        matcher.add(check['needs']['match'], entry.get('target', ''))
        else:
            continue
        matcher.add(match, value)
        if kind != 'recall_on':
            matcher.add(match, prompt)
        relevant.append((check, match, value))
    matcher.run()
    matched, contexts, denial = [], [], ''
    for check, match, value in relevant:
        if not matcher.hit(match, value):
            continue
        ident, kind = check['id'], check['kind']
        action = 'allow'
        if kind == 'forbid_command' and 'allow_if' in check and matcher.hit(check['allow_if'], text):
            matched.append({'id': ident, 'mode': check['mode'], 'action': action})
            continue
        if kind == 'require_before':
            start = updated['gates'].get(ident, 0) if check['window'] == 'since_gate' else 0
            updated['gates'][ident] = len(ledger)
            key = matcher.results[(match, value)][1] if 'key' in check else ''
            needs = check['needs']
            satisfied = any(entry.get('outcome') == 'ok' and entry.get('tool') == needs['tool']
                            and (not check.get('key') or has_key(key, entry.get('target', '')))
                            and (fnmatch.fnmatchcase(entry.get('target', ''), needs['match'])
                                 if needs['tool'] == 'Read' else matcher.hit(needs['match'], entry.get('target', '')))
                            for entry in ledger[start:])
            if satisfied:
                matched.append({'id': ident, 'mode': check['mode'], 'action': action})
                continue
        if kind == 'recall_on':
            if call - updated['recalls'].get(ident, -20) >= 20:
                action = 'recall'
        elif matcher.hit(match, prompt):
            action = 'override'
        elif updated['denies'].get(ident, 0) >= 3:
            action = 'released'
        else:
            action = 'deny'
        if check['mode'] == 'shadow':
            if action in ('deny', 'recall'):
                action = 'would_' + action
        elif action == 'deny':
            # Only the check whose reason is emitted consumes a deny attempt.
            if not denial:
                denial = reason(check)
                updated['denies'][ident] = updated['denies'].get(ident, 0) + 1
        elif action == 'recall':
            contexts.append(check['cite'][:1499])
        elif action == 'override':
            contexts.append(('grandma: user override. ' + check['cite'].replace('\n', ' '))[:1499])
        if action in ('recall', 'would_recall'):
            updated['recalls'][ident] = call
        matched.append({'id': ident, 'mode': check['mode'], 'action': action})
    if denial:
        updated['recalls'] = copy.deepcopy(state.get('recalls', {}))
    context = '\n'.join(contexts)[:8999]
    return {'decision': 'deny' if denial else ('allow+context' if context else 'allow'),
            'reason': denial, 'context': context, 'matched': matched, 'state': updated}


def new_turn(state, prompt):
    result = copy.deepcopy(state)
    result.update(prompt=prompt, turn=state.get('turn', 0) + 1, denies={})
    return result


def hook(mode, root, scope, project):
    started = time.perf_counter()
    payload = json.load(sys.stdin)
    sid = payload.get('session_id', '')
    if not isinstance(sid, str) or not sid or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in sid) or sid in ('.', '..'):
        return
    directory = root / '.peek' / sid
    if mode in ('batch', 'fail'):
        calls = payload.get('tool_calls', []) if mode == 'batch' else [payload]
        if calls:
            directory.mkdir(parents=True, exist_ok=True)
        for call in calls:
            entry = {'tool': call.get('tool_name', ''),
                     'target': tool_target(call.get('tool_name', ''), call.get('tool_input', {})),
                     'outcome': 'ok' if mode == 'batch' else 'failed'}
            if mode == 'fail':
                entry['error'] = str(call.get('tool_error', '')).replace('\n', ' ')[:200]
            append(directory / 'ledger.jsonl', entry)
        return
    active = root / scope / 'peek' / (project + '.json' if project else '_sweater.json')
    if not active.is_file():
        return
    directory = root / '.peek' / sid
    directory.mkdir(parents=True, exist_ok=True)
    # Concurrent tool hooks fail open instead of overwriting counters or consuming a turn twice.
    lock = directory / '.engine-lock'
    try:
        if lock.is_dir() and time.time() - lock.stat().st_mtime > 30:
            lock.rmdir()
    except OSError:
        pass
    try:
        lock.mkdir()
    except FileExistsError:
        append(directory / 'decisions.jsonl', {'decision': 'allow', 'suppressed_by': 'lock',
                                              'latency_ms': (time.perf_counter() - started) * 1000})
        return
    try:
        state_path = directory / 'state.json'
        state = read_json(state_path, {})
        if mode == 'prompt':
            write_json(state_path, new_turn(state, payload.get('prompt', '')))
            return
        checks = load_checks(root, scope, project, directory, payload.get('cwd', ''))
        decision = decide(checks, payload['tool_name'], payload.get('tool_input', {}),
                          list(rows(directory / 'ledger.jsonl')), state.get('prompt', ''), state)
        write_json(state_path, decision.pop('state'))
        append(directory / 'decisions.jsonl', dict(decision, turn_id=state.get('turn', 0),
                                                  latency_ms=(time.perf_counter() - started) * 1000))
        output = {'hookEventName': 'PreToolUse'}
        if decision['decision'] == 'deny':
            output.update(permissionDecision='deny', permissionDecisionReason=decision['reason'])
        elif decision['context']:
            output['additionalContext'] = decision['context']
        else:
            return
        print(compact({'hookSpecificOutput': output}))
    finally:
        lock.rmdir()


def replay(root, args):
    import argparse
    import tempfile
    parser = argparse.ArgumentParser(prog='grandma peek replay')
    parser.add_argument('transcript')
    parser.add_argument('--scope', required=True)
    parser.add_argument('--project', default='')
    parser.add_argument('--checks')
    parser.add_argument('--json', action='store_true')
    options = parser.parse_args(args)
    with tempfile.TemporaryDirectory(prefix='grandma-peek-replay-') as scratch:
        directory = Path(scratch)
        checks = load_checks(root, options.scope, options.project, directory, external=options.checks)
        report = {c['id']: {'id': c['id'], 'mode': c['mode'], 'would_deny': 0, 'events': []} for c in checks}
        enforced = [dict(c, mode='enforce') for c in checks]
        state, ledger, pending = {}, [], {}
        with open(options.transcript) as transcript:
            for line in transcript:
                row = json.loads(line)
                message = row.get('message', {})
                content = message.get('content', [])
                if isinstance(content, str):
                    content = [{'type': 'text', 'text': content}]
                if row.get('type') == 'user':
                    texts = [b.get('text', '') for b in content if b.get('type') == 'text']
                    if texts:
                        state = new_turn(state, '\n'.join(texts))
                    for block in content:
                        if block.get('type') == 'tool_result':
                            call = pending.pop(block.get('tool_use_id'), None)
                            if call:
                                ledger.append({'tool': call['name'], 'target': tool_target(call['name'], call.get('input', {})),
                                               'outcome': 'failed' if block.get('is_error') else 'ok'})
                elif row.get('type') == 'assistant':
                    for block in content:
                        if block.get('type') != 'tool_use':
                            continue
                        decision = decide(enforced, block['name'], block.get('input', {}), ledger, state.get('prompt', ''), state)
                        state = decision['state']
                        pending[block['id']] = block
                        for match in decision['matched']:
                            if match['action'] in ('deny', 'released'):
                                item = report[match['id']]
                                item['would_deny'] += 1
                                item['events'].append({'timestamp': row.get('timestamp', ''),
                                                       'input': domain(block['name'], block.get('input', {}))[:120]})
        output = list(report.values())
        if options.json:
            print(compact(output))
        else:
            for item in output:
                print('{} [{}]: {} would deny'.format(item['id'], item['mode'], item['would_deny']))
                for event in item['events']:
                    print('  {} {}'.format(event['timestamp'], event['input']))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    # Same kill switches as grandma-peek.sh, since the per-tool hooks call this file directly.
    if mode != 'replay' and (os.environ.get('GRANDMA_PEEK') == 'off'
                             or os.environ.get('GRANDMA_NO_PEEK') == '1'
                             or os.environ.get('GRANDMA_DISTILLING') == '1'):
        return
    root = Path(os.environ.get('GRANDMA_HOME', str(Path.home() / '.grandma')))
    if mode == 'replay':
        replay(root, sys.argv[2:])
        return
    try:
        hook(mode, root, sys.argv[2] if len(sys.argv) > 2 else '', sys.argv[3] if len(sys.argv) > 3 else '')
    except Exception:
        # Hooks must never strand a tool call, including failures of parsing and storage.
        return


if __name__ == '__main__':
    main()
