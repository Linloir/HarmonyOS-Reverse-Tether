"""Prevent custom builds from changing the default source/distribution identity."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class BuildIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='tether-build-test-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.project = self.directory / 'project'
        (self.project / 'scripts').mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/build-app.py', self.project / 'scripts/build-app.py')
        self.manifest = self.project / 'app/AppScope/app.json5'
        self.manifest.parent.mkdir(parents=True)
        self.original = (ROOT / 'app/AppScope/app.json5').read_bytes()
        self.manifest.write_bytes(self.original)
        self.clt = self.directory / 'tools'
        (self.clt / 'bin').mkdir(parents=True)
        tools = '''#!/usr/bin/env python3
import json, os, sys, zipfile
from pathlib import Path
if Path(sys.argv[0]).name == 'hvigorw':
    with open(os.environ['TETHER_TEST_STAGES'], 'a') as log:
        log.write(str(Path.cwd())+'\\n')
    if os.environ.get('TETHER_TEST_BUILD_FAIL'):
        sys.exit(7)
    output=Path('entry/build/default/outputs/default/entry-default-unsigned.hap')
    output.parent.mkdir(parents=True)
    with zipfile.ZipFile(output, 'w') as hap:
        hap.writestr('module.json', Path('AppScope/app.json5').read_bytes())
'''
        for name in ['ohpm', 'hvigorw']:
            tool = self.clt / 'bin' / name
            tool.write_text(tools)
            tool.chmod(0o755)
        self.stages = self.directory / 'stages'
        self.env = dict(os.environ, HARMONY_CLT_HOME=str(self.clt), TETHER_TEST_STAGES=str(self.stages))
        self.env.pop('HARMONY_BUNDLE_NAME', None)

    def build(self, *args):
        return subprocess.run([sys.executable, str(self.project / 'scripts/build-app.py'), *args],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def bundle(self, hap):
        with zipfile.ZipFile(hap) as archive:
            return json.loads(archive.read('module.json'))['app']['bundleName']

    def test_custom_then_default_build_keeps_source_and_outputs_isolated(self):
        custom = self.directory / 'custom.hap'
        result = self.build('--bundle-name', 'org.example.custom', '--output', str(custom))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bundle(custom), 'org.example.custom')
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        default = self.project / 'build/harmony-reverse-tether-unsigned.hap'
        self.assertEqual(self.bundle(default), json.loads(self.original)['app']['bundleName'])
        self.assertEqual(self.manifest.read_bytes(), self.original)
        self.assertTrue(all(not Path(path).exists() for path in self.stages.read_text().splitlines()))

    def test_failed_build_preserves_previous_hap_and_source(self):
        output = self.directory / 'existing.hap'
        output.write_bytes(b'previous build')
        self.env['TETHER_TEST_BUILD_FAIL'] = '1'
        result = self.build('--output', str(output), '--bundle-name', 'org.example.custom')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), b'previous build')
        self.assertEqual(self.manifest.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
