"""Behavioral fixtures for deterministic peek, invoked by cmd_peek.sh."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True

ENGINE = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ['GRANDMA_HOME'])
CHECKS = ROOT / 'home-ops/peek/yard.json'
MEMORY = ROOT / 'home-ops/facts.md'
PK = ENGINE / 'lib/grandma-peek.sh'
BASE = {'id': 'command', 'kind': 'forbid_command', 'cite': 'pnpm only, never yarn',
        'file': 'home-ops/facts.md', 'instead': 'Run pnpm', 'mode': 'enforce', 'match': 'yarn'}


class PeekEngine(unittest.TestCase):
    def setUp(self):
        self.sid = self._testMethodName
        CHECKS.parent.mkdir(parents=True, exist_ok=True)
        MEMORY.write_text('pnpm only, never yarn\nRead before changing.\n')
        (CHECKS.parent / '_sweater.json').unlink(missing_ok=True)
        self.checks([BASE])

    def checks(self, checks):
        CHECKS.write_text(json.dumps({'version': 1, 'checks': checks}))

    def check(self, **fields):
        result = dict(BASE)
        result.update(fields)
        return result

    def run_hook(self, mode='pre', tool='Bash', inp=None, env=None, raw=None, sid=None):
        payload = {'session_id': sid or self.sid, 'tool_name': tool,
                   'tool_input': inp if inp is not None else {'command': 'yarn install'},
                   'cwd': str(ROOT / 'projects/yard')}
        if raw is not None:
            payload.update(raw)
        result = subprocess.run(['bash', '-u', str(PK), mode, 'home-ops', 'yard'],
                                input=json.dumps(payload), text=True, capture_output=True,
                                env=dict(os.environ, **(env or {})))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout)['hookSpecificOutput'] if result.stdout else {}

    def deny(self, output):
        self.assertEqual(output.get('hookEventName'), 'PreToolUse')
        self.assertEqual(output.get('permissionDecision'), 'deny')
        self.assertIsInstance(output.get('permissionDecisionReason'), str)
        self.assertEqual(set(output), {'hookEventName', 'permissionDecision', 'permissionDecisionReason'})

    def allow(self, output):
        self.assertEqual(output, {})

    def events(self):
        return [json.loads(line) for line in (ROOT / '.peek' / self.sid / 'decisions.jsonl').read_text().splitlines()]

    def batch(self, tool, inp, failure=False):
        raw = {'tool_calls': [{'tool_name': tool, 'tool_input': inp}]}
        self.run_hook('fail' if failure else 'batch', tool, inp, raw=raw)

    def need(self, **fields):
        return self.check(kind='require_before', gate={'tool': 'Bash', 'match': 'PATCH turn ([0-9]+)'},
                          needs={'tool': 'Read', 'match': '*/turn-*'}, window='session', **fields)

    def test_command_allow_and_deny(self):
        self.allow(self.run_hook(inp={'command': 'pnpm install'}))
        self.deny(self.run_hook())
        self.checks([self.check(allow_if='logged-override')])
        self.allow(self.run_hook(inp={'command': 'yarn install # logged-override'}))

    def test_text_tools_and_paths(self):
        self.checks([self.check(kind='forbid_text', paths='*.md', match='badword')])
        for tool, field in [('Write', 'content'), ('Edit', 'new_string')]:
            self.allow(self.run_hook(tool=tool, inp={'file_path': 'a.md', field: 'clean'}))
            self.deny(self.run_hook(tool=tool, inp={'file_path': 'a.md', field: 'first\nbadword\nlast'}, sid=tool))
            self.allow(self.run_hook(tool=tool, inp={'file_path': 'a.txt', field: 'badword'}))
        self.deny(self.run_hook(tool='MultiEdit', inp={'file_path': 'a.md', 'edits': [{'new_string': 'clean'}, {'new_string': 'badword'}]}))
        self.deny(self.run_hook(inp={'command': 'cat > a.md <<EOF\nbadword\nEOF'}))
        self.allow(self.run_hook(tool='Read', inp={'file_path': 'badword.md'}))
        self.allow(self.run_hook(tool='Edit', inp={'file_path': 'a.md', 'old_string': 'badword', 'new_string': 'clean'}))

    def test_large_multiline_and_ere(self):
        self.checks([self.check(kind='forbid_text', paths='*', match='[[:upper:]]{3}[[:digit:]]+')])
        self.deny(self.run_hook(tool='Write', inp={'file_path': 'a.md', 'content': 'a\n' * 150000 + 'ABC123'}))
        self.allow(self.run_hook(tool='Write', inp={'file_path': 'a.md', 'content': 'a\n' * 150000}))
        self.checks([self.check(match='literal[$](touch nope)')])
        self.allow(self.run_hook())

    def test_posix_rules_inside_brackets(self):
        # Python reads these differently unless translated: [[:space:]] as a set holding [ : s p a c e,
        # [a|b] as a set operator, a leading ] as an empty set, $ as matching before a final newline.
        cases = [('x[[:space:]]+y', 'x \t\n y', True), ('[[:space:]]', 'paces', False),
                 ('[a|b]c', '|c', True), ('[]x]', ']', True), ('[\\]q', '\\q', True),
                 ('probe 7$', 'probe 7\n', False), ('a.b', 'a\nb', True)]
        for n, (match, command, hit) in enumerate(cases):
            self.checks([self.check(match=match)])
            (self.deny if hit else self.allow)(self.run_hook(inp={'command': command}, sid='ok%d' % n))
        for n, match in enumerate(['(', '[abc', '[[:nope:]]', 'trailing\\']):
            self.checks([self.check(match=match)])
            self.allow(self.run_hook(inp={'command': 'trailing\\ ( [abc'}, sid='bad%d' % n))

    def test_require_before_and_failed_ledger(self):
        self.checks([self.need()])
        self.allow(self.run_hook(inp={'command': 'GET turn 7'}))
        self.deny(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.batch('Read', {'file_path': '/tmp/turn-7'}, failure=True)
        self.deny(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.batch('Read', {'file_path': '/tmp/turn-7'})
        self.allow(self.run_hook(inp={'command': 'PATCH turn 7'}))

    def test_key_capture(self):
        self.checks([self.need(key=1)])
        self.batch('Read', {'file_path': '/tmp/turn-5'})
        self.deny(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.batch('Read', {'file_path': '/tmp/turn-17'})
        self.deny(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.batch('Read', {'file_path': '/tmp/turn-7'})
        self.allow(self.run_hook(inp={'command': 'PATCH turn 7'}))

    def test_since_gate(self):
        check = self.need()
        check.update(window='since_gate', needs={'tool': 'Bash', 'match': 'probe [0-9]+'})
        self.checks([check])
        self.batch('Bash', {'command': 'probe 7'})
        self.allow(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.deny(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.batch('Bash', {'command': 'probe 8'})
        self.allow(self.run_hook(inp={'command': 'PATCH turn 8'}))

    def test_full_ledger_targets(self):
        check = self.need()
        check['needs'] = {'tool': 'Bash', 'match': 'probe 7$'}
        self.checks([check])
        self.batch('Bash', {'command': '#' * 150000 + '\nprobe 7'})
        self.allow(self.run_hook(inp={'command': 'PATCH turn 7'}))
        self.assertEqual(self.events()[-1]['matched'][0]['action'], 'allow')

    def test_shadow_no_output(self):
        self.checks([self.check(mode='shadow'), self.check(id='recall', kind='recall_on', mode='shadow', trigger={'tool': 'Bash', 'match': 'yarn'})])
        self.allow(self.run_hook())
        self.assertEqual([m['action'] for m in self.events()[-1]['matched']], ['would_deny', 'would_recall'])
        self.run_hook('prompt', raw={'prompt': 'yarn'})
        self.allow(self.run_hook())

    def test_unapproved_and_off(self):
        CHECKS.unlink()
        (CHECKS.parent / '_sweater.json').write_text(json.dumps({'version': 1, 'checks': [BASE]}))
        self.allow(self.run_hook())
        self.assertFalse((ROOT / '.peek' / self.sid).exists())
        self.checks([BASE])
        for env in ({'GRANDMA_PEEK': 'off'}, {'GRANDMA_DISTILLING': '1'}, {'GRANDMA_NO_PEEK': '1'}):
            self.allow(self.run_hook(env=env))
        self.assertFalse((ROOT / '.peek' / self.sid).exists())

    def test_sweater_checks(self):
        self.checks([])
        (CHECKS.parent / '_sweater.json').write_text(json.dumps({'version': 1, 'checks': [BASE]}))
        self.deny(self.run_hook())

    def test_stale_and_cache(self):
        self.deny(self.run_hook())
        cache = ROOT / '.peek' / self.sid / 'checks-cache.json'
        before = cache.stat().st_mtime_ns
        self.deny(self.run_hook())
        self.assertEqual(cache.stat().st_mtime_ns, before)
        MEMORY.write_text('retired\n')
        self.allow(self.run_hook())
        errors = ROOT / '.peek' / self.sid / 'errors.jsonl'
        self.assertIn('stale cite', errors.read_text())
        before = errors.read_text()
        self.allow(self.run_hook())
        self.assertEqual(errors.read_text(), before)
        MEMORY.write_text(BASE['cite'])
        self.deny(self.run_hook())

    def test_project_citation(self):
        memory = ROOT / 'projects/yard/CLAUDE.md'
        memory.write_text('Read before changing.\n')
        self.checks([self.check(file='project:CLAUDE.md', cite='Read before changing.')])
        self.deny(self.run_hook())
        memory.write_text('retired\n')
        self.allow(self.run_hook())

    def test_project_dir_beats_a_wandering_cwd(self):
        memory = ROOT / 'projects/yard/CLAUDE.md'
        memory.write_text('Read before changing.\n')
        (ROOT / 'projects/yard/sub').mkdir(parents=True, exist_ok=True)
        self.checks([self.check(file='project:CLAUDE.md', cite='Read before changing.')])
        self.deny(self.run_hook(raw={'cwd': str(ROOT / 'projects/yard/sub')},
                                env={'CLAUDE_PROJECT_DIR': str(ROOT / 'projects/yard')}))

    def test_malformed_fails_open(self):
        CHECKS.write_text('{bad')
        self.allow(self.run_hook())
        self.assertIn('malformed checks file', (ROOT / '.peek' / self.sid / 'errors.jsonl').read_text())
        self.checks([{'id': 'broken'}, self.check(id='bad-regex', match='['), BASE])
        self.deny(self.run_hook())
        errors = (ROOT / '.peek' / self.sid / 'errors.jsonl').read_text()
        self.assertIn('malformed', errors)
        self.checks([self.check(mode='unapproved')])
        self.allow(self.run_hook())

    def test_override_and_paraphrase(self):
        self.run_hook('prompt', raw={'prompt': 'use the other package manager'})
        self.deny(self.run_hook())
        self.run_hook('prompt', raw={'prompt': 'please use yarn'})
        output = self.run_hook()
        self.assertIn('additionalContext', output)
        self.assertNotIn('permissionDecision', output)
        self.assertNotIn('\n', output['additionalContext'])

    def test_release_and_turn_reset(self):
        for _ in range(3):
            self.deny(self.run_hook())
        self.allow(self.run_hook())
        self.assertEqual(self.events()[-1]['matched'][0]['action'], 'released')
        self.run_hook('prompt', raw={'prompt': 'continue'})
        self.deny(self.run_hook())

    def test_recall_after_deny(self):
        self.checks([BASE, self.check(id='recall', kind='recall_on', trigger={'tool': 'Bash', 'match': 'install'})])
        self.deny(self.run_hook())
        self.assertIn('additionalContext', self.run_hook(inp={'command': 'pnpm install'}))

    def test_recall_cooldown(self):
        self.checks([self.check(kind='recall_on', trigger={'tool': 'Read', 'match': 'style'})])
        self.allow(self.run_hook(tool='Read', inp={'file_path': 'unrelated'}))
        self.assertIn('additionalContext', self.run_hook(tool='Read', inp={'file_path': 'style.md'}))
        self.run_hook('prompt', raw={'prompt': 'continue'})
        for _ in range(19):
            self.allow(self.run_hook(tool='Read', inp={'file_path': 'style.md'}))
        self.assertIn('additionalContext', self.run_hook(tool='Read', inp={'file_path': 'style.md'}))

    def test_context_caps_and_other_tool(self):
        cite = 'rule ' * 600
        MEMORY.write_text(cite)
        self.checks([self.check(id=str(i), kind='recall_on', cite=cite, trigger={'tool': 'mcp__fetch', 'match': 'mcp__fetch .*target'}) for i in range(8)])
        context = self.run_hook(tool='mcp__fetch', inp={'query': 'target'})['additionalContext']
        self.assertLess(len(context), 9000)
        self.assertTrue(all(len(line) < 1500 for line in context.splitlines()))
        self.assertGreater(len(context), 8000)

    def test_reason_cap(self):
        cite = 'long citation ' * 60
        MEMORY.write_text(cite)
        self.checks([self.check(cite=cite)])
        reason = self.run_hook()['permissionDecisionReason']
        self.assertLessEqual(len(reason), 300)
        self.assertIn('...', reason)
        self.assertTrue(reason.startswith('grandma: "'))
        self.assertTrue(reason.endswith('Fix it and carry on, do not mention this check.'))
        self.assertIn('(home-ops/facts.md). Instead: Run pnpm.', reason)

    def test_grade_unused_and_latency(self):
        self.checks([self.check(kind='grade_at_stop')])
        self.allow(self.run_hook())
        self.assertEqual(self.events()[-1]['matched'], [])
        self.assertGreaterEqual(self.events()[-1]['latency_ms'], 0)

    def test_invalid_hook_and_lock(self):
        result = subprocess.run(['bash', '-u', str(PK), 'pre', 'home-ops', 'yard'], input='{bad', text=True, capture_output=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
        self.allow(self.run_hook(sid='..'))
        directory = ROOT / '.peek' / self.sid
        directory.mkdir(parents=True, exist_ok=True)
        (directory / '.engine-lock').mkdir()
        self.allow(self.run_hook())
        self.assertEqual(self.events()[-1]['suppressed_by'], 'lock')
        # a lock left by a killed hook goes stale instead of disabling peek for the session
        stale = time.time() - 120
        os.utime(directory / '.engine-lock', (stale, stale))
        self.deny(self.run_hook())
        self.assertFalse((directory / '.engine-lock').exists())

    def test_pure_transition(self):
        spec = importlib.util.spec_from_file_location('peek', ENGINE / 'lib/grandma-peek-engine.py')
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        args = ([BASE], 'Bash', {'command': 'yarn'}, [], '', {'denies': {}})
        before = copy.deepcopy(args)
        first = engine.decide(*args)
        self.assertEqual(args, before)
        self.assertEqual(first, engine.decide(*args))
        self.assertEqual(first['decision'], 'deny')

    def test_installed_hooks_and_help(self):
        directory = ROOT / 'projects/yard'
        # Extract only the installer so the test never launches a session.
        launcher = (ENGINE / 'lib/grandma-launch.sh').read_text()
        start = launcher.index('install_peek_hooks() {')
        end = launcher.index('\n}', start) + 2
        script = 'set -u\nROOT="$GRANDMA_HOME"\nsource "$1/lib/grandma-lib.sh"\n' + launcher[start:end]
        script += '\ninstall_peek_hooks "$2" home-ops yard\ninstall_peek_hooks "$2" home-ops yard\n'
        script += 'install_peek_hooks "$3" home-ops shed\n'
        bare = ROOT / 'projects/shed'
        result = subprocess.run(['bash', '-c', script, 'peek-test', str(ENGINE), str(directory), str(bare)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        hooks = json.loads((directory / '.claude/settings.local.json').read_text())['hooks']
        for event, mode in [('PreToolUse', 'pre'), ('UserPromptSubmit', 'prompt'), ('MessageDisplay', 'display'),
                            ('PostToolBatch', 'batch'), ('PostToolUseFailure', 'fail')]:
            self.assertEqual(len(hooks[event]), 1)
            command = hooks[event][0]['hooks'][0]['command']
            engine = '\"${GRANDMA_ENGINE:-$HOME/.grandma-engine}\"/lib/'
            if mode == 'display':
                self.assertEqual(command, engine + 'grandma-peek.sh display home-ops yard')
            else:
                self.assertEqual(command, 'python3 -S ' + engine + 'grandma-peek-engine.py ' + mode
                                 + ' home-ops yard 2>/dev/null || true')
        # a project with no approved checks gets no hooks at all, so it pays nothing per tool call
        self.assertFalse((bare / '.claude/settings.local.json').exists())
        command = hooks['PreToolUse'][0]['hooks'][0]['command']
        payload = json.dumps({'session_id': self.sid, 'tool_name': 'Bash', 'tool_input': {'command': 'yarn'}})
        output = subprocess.run(['sh', '-c', command], input=payload, text=True, capture_output=True,
                                env=dict(os.environ, GRANDMA_ENGINE=str(ENGINE)))
        self.deny(json.loads(output.stdout)['hookSpecificOutput'])
        help_text = subprocess.check_output([str(ENGINE / 'bin/grandma'), 'help'], text=True)
        self.assertIn('peek replay', help_text)
        self.assertIn('grandma help', help_text)
        self.assertIn('Memory lives in GRANDMA_HOME', help_text)
        for shell in ('bash', 'zsh', 'fish'):
            completion = subprocess.check_output([str(ENGINE / 'bin/grandma'), 'completions', shell], text=True)
            self.assertIn('__peek_commands', completion)
        candidates = subprocess.check_output([str(ENGINE / 'bin/grandma'), 'completions', '__peek_commands'], text=True)
        self.assertIn('replay', candidates)

    def test_replay(self):
        check = self.need(key=1)
        check['mode'] = 'shadow'
        self.checks([check])
        transcript = ROOT / 'synthetic.jsonl'
        records = []
        def message(kind, content, stamp):
            records.append({'type': kind, 'timestamp': stamp, 'message': {'content': content}})
        def call(ident, name, inp, stamp):
            message('assistant', [{'type': 'tool_use', 'id': ident, 'name': name, 'input': inp}], stamp)
        def result(ident, error=False):
            message('user', [{'type': 'tool_result', 'tool_use_id': ident, 'is_error': error}], 'result')
        message('user', 'do the work', 'start')
        call('read5', 'Read', {'file_path': '/tmp/turn-5'}, 'read5')
        result('read5')
        call('bad', 'Bash', {'command': 'PATCH turn 7'}, 'deny1')
        result('bad', True)
        call('read7', 'Read', {'file_path': '/tmp/turn-7'}, 'read7')
        call('early', 'Bash', {'command': 'PATCH turn 7'}, 'deny2')
        result('read7')
        call('good', 'Bash', {'command': 'PATCH turn 7'}, 'allow')
        message('user', 'PATCH turn 8 please', 'override')
        call('override', 'Bash', {'command': 'PATCH turn 8'}, 'allow2')
        transcript.write_text('\n'.join(json.dumps(r) for r in records))
        before = {str(p): p.read_bytes() for p in ROOT.rglob('*') if p.is_file()}
        external = ROOT.parent / 'external-checks.json'
        external.write_bytes(CHECKS.read_bytes())
        command = [str(ENGINE / 'bin/grandma'), 'peek', 'replay', str(transcript), '--scope', 'home-ops', '--project', 'yard', '--checks', str(external), '--json']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report[0]['mode'], 'shadow')
        self.assertEqual(report[0]['would_deny'], 2)
        self.assertEqual([e['timestamp'] for e in report[0]['events']], ['deny1', 'deny2'])
        self.assertEqual(report[0]['events'][0]['input'], 'PATCH turn 7')
        self.assertEqual({str(p): p.read_bytes() for p in ROOT.rglob('*') if p.is_file()}, before)

    def test_replay_counts_past_the_release_valve(self):
        # An autonomous turn that submits five times without the prerequisite broke the rule five
        # times. The live valve lets the fourth through, replay must still count it.
        self.checks([self.need()])
        records = [{'type': 'user', 'message': {'content': 'go'}}]
        for n in range(5):
            records.append({'type': 'assistant', 'timestamp': 's%d' % n, 'message': {'content': [
                {'type': 'tool_use', 'id': 'c%d' % n, 'name': 'Bash', 'input': {'command': 'PATCH turn 7'}}]}})
        transcript = ROOT / 'burst.jsonl'
        transcript.write_text('\n'.join(json.dumps(r) for r in records))
        result = subprocess.run([str(ENGINE / 'bin/grandma'), 'peek', 'replay', str(transcript), '--scope', 'home-ops',
                                 '--project', 'yard', '--json'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]['would_deny'], 5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
