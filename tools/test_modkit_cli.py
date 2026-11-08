#!/usr/bin/env python3
"""Public CLI contract tests; optional real-package roundtrip via SPELLBREAK_CLI_TEST_ASSET."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import modkit


class CliTests(unittest.TestCase):
    def test_discovery_without_backend(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = modkit.main(['--json', 'commands'])
        result = json.loads(out.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(result['schema_version'], 1)
        self.assertIn('patch', result['value']['commands']['asset']['commands'])
        self.assertIn('extract', result['value']['commands']['pak']['commands'])

    def test_invalid_arguments_have_json_error_and_usage_exit(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = modkit.main(['--json', 'asset', 'patch'])
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(out.getvalue())['ok'])

    def test_search_limit_and_paths_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='cli spaces ') as tmp:
            for name in ['Foo.uasset', 'foo2.umap', 'foo3.uasset', 'foo.txt']:
                (Path(tmp) / name).touch()
            args = modkit.parser().parse_args(['search', tmp, 'FOO', '--limit', '2'])
            result = modkit.execute(args, modkit.parser())['value']
            self.assertEqual(len(result['assets']), 2)
            self.assertTrue(result['truncated'])
            self.assertEqual(result['assets'][0]['source_root'], tmp)

    def test_patch_rejects_unsafe_inputs(self):
        for operations in ({}, [], [{'op': 'remove', 'path': '/x'}],
                           [{'op': 'replace', 'path': '/x', 'value': 2**63 - 1}]):
            with self.subTest(operations=operations), self.assertRaises(ValueError):
                modkit.validate_patch(operations)

    def test_backend_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            modkit.run_process([sys.executable, '-c', 'import time; time.sleep(60)'], timeout=0.1)

    def test_missing_backend_is_structured(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = modkit.main(['--json', '--godot', '/missing/backend', 'doctor'])
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(out.getvalue())['ok'])


@unittest.skipUnless(os.environ.get('GODOT'), 'Set GODOT for backend integration tests')
class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sb cli integration ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, 'SPELLBREAK_MODKIT_CONFIG_DIR': str(self.root / 'config')}

    def cli(self, *args, ok=True):
        completed = subprocess.run([sys.executable, str(Path(modkit.__file__)), '--json', '--timeout', '45', *map(str, args)],
                                   capture_output=True, text=True, env=self.env, timeout=60)
        result = json.loads(completed.stdout)
        self.assertEqual(result['ok'], ok, result)
        self.assertEqual(completed.returncode, 0 if ok else 1, completed.stderr)
        self.assertNotIn('SCRIPT ERROR', completed.stderr)
        return result

    def test_inspect_refs_validation_and_precision(self):
        asset = self.root / 'fixture.json'
        data = {'NameMap': ['Test'], 'Imports': [], 'Exports': [], 'extra': '/Game/Test.Test'}
        asset.write_text(json.dumps(data))
        self.cli('asset', 'inspect', asset)
        refs = self.cli('asset', 'refs', asset)['value']
        self.assertEqual(refs, [{'path': '/extra', 'reference': '/Game/Test.Test'}])
        self.cli('asset', 'validate', asset)
        data['large'] = 2**63 - 1
        asset.write_text(json.dumps(data))
        result = self.cli('asset', 'inspect', asset, ok=False)
        self.assertIn('precision', result['message'])
        # Digit strings must not be mistaken for integer tokens.
        data['large'] = '9223372036854775807'
        asset.write_text(json.dumps(data))
        self.cli('asset', 'inspect', asset)

    def test_application_cli_entry(self):
        request, result = self.root / 'request.json', self.root / 'result.json'
        request.write_text(json.dumps({'group': 'doctor'}))
        completed = subprocess.run([os.environ['GODOT'], '--headless', '--path', str(modkit.PROJECT),
                                    '--', '--cli-request', str(request), str(result)],
                                   capture_output=True, text=True, env=self.env, timeout=45)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(json.loads(result.read_text())['ok'])
        self.assertNotIn('ERROR:', completed.stderr)

    def test_invalid_json_is_failure(self):
        asset = self.root / 'invalid.json'
        for content in ('null', '[]', '{broken', '{}'):
            asset.write_text(content)
            self.cli('asset', 'inspect', asset, ok=False)

    def test_preflight_orphan_companion(self):
        mod = self.root / 'Mod'
        (mod / 'g3/Content').mkdir(parents=True)
        (mod / 'g3/Content/Missing.uexp').write_bytes(b'fragment')
        result = self.cli('mod', 'validate', mod, ok=False)
        self.assertIn('companion', str(result['value']))

    @unittest.skipUnless(os.environ.get('SPELLBREAK_CLI_TEST_ASSET'), 'Set a real asset for staged patch roundtrip')
    def test_real_package_roundtrip(self):
        source = Path(os.environ['SPELLBREAK_CLI_TEST_ASSET']).resolve()
        original = {p: p.read_bytes() for p in source.parent.glob(source.stem + '.*')}
        data = self.cli('asset', 'dump', source)['value']
        # No-op property replacement still exercises serialization and verification.
        old = data['Exports'][0]['Data'][0]['Value']
        pointer = '/Exports/0/Data/0/Value'
        patch = self.root / 'patch.json'
        patch.write_text(json.dumps([{'op': 'test', 'path': pointer, 'value': old},
                                    {'op': 'replace', 'path': pointer, 'value': old}]))
        output = self.root / 'output' / source.name
        self.cli('asset', 'patch', source, patch, '--output', output, '--dry-run')
        self.assertFalse(output.exists())
        self.cli('asset', 'patch', source, patch, '--output', output)
        self.cli('asset', 'validate', output)
        if source.with_suffix('.uexp').exists():
            self.assertTrue(output.with_suffix('.uexp').exists())
        for extension in ('.ubulk', '.uptnl'):
            if source.with_suffix(extension).exists():
                self.assertEqual(output.with_suffix(extension).read_bytes(), source.with_suffix(extension).read_bytes())
        self.cli('asset', 'patch', source, patch, '--output', output, ok=False)
        for path, content in original.items():
            self.assertEqual(path.read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
