"""Verify public CLI defaults and custom application/HDC selection."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='tether-cli-test-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.log = self.directory / 'commands.jsonl'
        self.hdc = self.directory / 'hdc'
        self.hdc.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TETHER_TEST_COMMANDS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[-3:] == ['list', 'targets', '-v']:
    print('USB-SERIAL USB Connected device')
else:
    print('start ability successfully.')
''')
        self.hdc.chmod(0o755)
        self.env = dict(os.environ, TETHER_TEST_COMMANDS=str(self.log))
        for name in ['HDC', 'HARMONY_BUNDLE_NAME', 'HARMONY_RELAY']:
            self.env.pop(name, None)
        self.env['PATH'] = str(self.directory) + os.pathsep + self.env.get('PATH', '')

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/harmony-tether.py'),
                               'stop', '--serial', 'USB-SERIAL', *args],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_default_uses_path_and_manifest_bundle_without_forcing_server(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        bundle = json.loads((ROOT / 'app/AppScope/app.json5').read_text())['app']['bundleName']
        self.assertEqual(commands[0], ['-t', 'USB-SERIAL', 'list', 'targets', '-v'])
        self.assertEqual(commands[1], ['-t', 'USB-SERIAL', 'shell',
                         f'aa start -b {bundle} -a EntryAbility --ps command stop'])

    def test_custom_binary_server_and_bundle_reach_the_device_command(self):
        custom = self.directory / 'custom hdc'
        self.hdc.rename(custom)
        self.env.update(HDC=str(custom), HARMONY_BUNDLE_NAME='org.example.fromenv')
        result = self.run_cli('--hdc-server', '127.0.0.1:9876', '--bundle', 'org.example.custom')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertEqual(commands[0][:4], ['-s', '127.0.0.1:9876', '-t', 'USB-SERIAL'])
        self.assertEqual(commands[1][-1], 'aa start -b org.example.custom -a EntryAbility --ps command stop')

    def test_environment_bundle_selects_matching_application(self):
        self.env['HARMONY_BUNDLE_NAME'] = 'org.example.custom'
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-b org.example.custom ', self.commands()[1][-1])

    def test_invalid_bundle_is_rejected_before_hdc(self):
        result = self.run_cli('--bundle', 'org.example.app;invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
