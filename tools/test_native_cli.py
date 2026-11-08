#!/usr/bin/env python3
"""Native app CLI tests. Exported runs intentionally have no external tools in PATH."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1] / 'spellbreak_uasset_editor'
APP = os.environ.get('SPELLBREAK_CLI_APP')
GODOT = os.environ.get('GODOT')


@unittest.skipUnless(APP or GODOT, 'Set SPELLBREAK_CLI_APP or GODOT')
class NativeCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='native cli spaces ')
        cls.root = Path(cls.tmp.name)
        cls.env = {**os.environ, 'SPELLBREAK_MODKIT_CONFIG_DIR': str(cls.root / 'config')}
        if APP:
            cls.env['PATH'] = ''
            # A new user-data root verifies bundled runtime extraction, not existing caches.
            cls.env['XDG_DATA_HOME'] = str(cls.root / 'data')
        cls.command = [str(Path(APP or GODOT).resolve()), '--headless', '--no-header']
        if not APP:
            cls.command += ['--path', str(PROJECT)]
        cls.command += ['--', 'cli']

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def cli(self, *args, code=0):
        p = subprocess.run([*self.command, '--json', *map(str, args)], cwd=self.root,
                           env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(p.returncode, code, p.stdout + p.stderr)
        self.assertNotIn('ERROR:', p.stderr)
        result = json.loads(p.stdout)
        self.assertEqual(result['ok'], code == 0, result)
        return result

    def test_help_and_discovery(self):
        result = self.cli('--help')
        self.assertIn('asset patch', result['message'])
        self.assertIn('asset patch', self.cli('commands')['value'])
        self.assertIn('--output', self.cli('asset', 'patch', '--help')['message'])
        self.cli('--version')

    def test_usage_errors(self):
        self.cli('asset', 'patch', code=2)
        self.cli('doctor', '--unknown', code=2)
        self.cli('search', self.root, 'foo', '--limit', '-1', code=2)
        self.cli('asset', 'dump', code=2)
        self.cli('asset', 'patch', 'x', 'y', '--output', 'z', '--output', 'z', code=2)

    def test_inspect_diff_and_search(self):
        asset = self.root / 'fixture.json'
        asset.write_text(json.dumps({'NameMap': [], 'Imports': [], 'Exports': [], 'ref': '/Game/Test.Test'}))
        self.cli('asset', 'inspect', asset)
        self.assertEqual(self.cli('asset', 'diff', asset, asset)['value']['changes'], [])
        self.assertEqual(self.cli('asset', 'refs', asset)['value'][0]['reference'], '/Game/Test.Test')
        assets = self.root / 'search'
        assets.mkdir(exist_ok=True)
        for name in ('One.uasset', 'OneTwo.umap'):
            (assets / name).touch()
        result = self.cli('search', assets, 'one', '--limit=1')['value']
        self.assertTrue(result['truncated'])
        self.assertEqual(len(result['assets']), 1)

    def test_workspace_creation(self):
        mod = self.root / 'Mods' / 'Native'
        self.cli('mod', 'create', mod)
        self.assertTrue((mod / 'spellbreak_mod_manifest.json').exists())
        self.cli('mod', 'validate', mod)
        self.cli('mod', 'create', mod, code=1)

    def test_doctor_bundled_tools(self):
        result = self.cli('doctor')['value']
        self.assertTrue(Path(result['converter']).is_file())
        if APP:
            for key in ('python', 'dotnet', 'umodel'):
                self.assertTrue(Path(result[key]).is_file(), result)
                self.assertIn(str(self.root / 'data'), result[key])

    @unittest.skipUnless(APP, 'Launcher test requires an exported application')
    def test_launcher_relative_paths_and_json(self):
        launcher = Path(APP).resolve().parent / ('modkit.cmd' if os.name == 'nt' else 'modkit')
        asset = self.root / 'relative.json'
        asset.write_text(json.dumps({'NameMap': [], 'Imports': [], 'Exports': []}))
        p = subprocess.run([str(launcher), 'asset', 'inspect', 'relative.json', '--json'],
                           cwd=self.root, env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertNotIn('ERROR:', p.stderr)
        self.assertEqual(json.loads(p.stdout)['value']['path'], str(asset))

    @unittest.skipUnless(os.environ.get('SPELLBREAK_CLI_TEST_ASSET'), 'Optional real-package roundtrip')
    def test_real_asset(self):
        source = Path(os.environ['SPELLBREAK_CLI_TEST_ASSET'])
        data = self.cli('asset', 'dump', source)['value']
        value = data['Exports'][0]['Data'][0]['Value']
        patch = self.root / 'patch.json'
        patch.write_text(json.dumps([{'op': 'test', 'path': '/Exports/0/Data/0/Value', 'value': value},
                                    {'op': 'replace', 'path': '/Exports/0/Data/0/Value', 'value': value}]))
        output = self.root / 'patched' / source.name
        self.cli('asset', 'patch', source, patch, '--output', output)
        self.cli('asset', 'validate', output)
        self.assertEqual(self.cli('asset', 'dump', output)['value']['Exports'][0]['Data'][0]['Value'], value)


if __name__ == '__main__':
    unittest.main()
