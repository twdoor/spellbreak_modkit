#!/usr/bin/env python3
"""Exercise actual pak export/composition, selection changes, and failed rebuilds."""
import json
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

import mod_distribution as helper
from test_patch_asset_registry import build_registry, patcher


class DistributionTest(unittest.TestCase):
    def test_workflow(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / 'base.bin'
            build_registry(base)
            sig = root / 'base.sig'
            sig.write_bytes(b'test signature')
            manifests = []
            for name in ('Skins', 'Balance'):
                workspace = root / ('workspace_' + name)
                relative = f'g3/Content/Items/{name}.uasset'
                asset = workspace / relative
                asset.parent.mkdir(parents=True)
                asset.write_bytes(b'test asset')
                (workspace / 'g3/AssetRegistry.bin').write_bytes(b'must not be exported')
                (workspace / 'spellbreak_mod_manifest.json').write_text(json.dumps({
                    'schema_version': 1, 'sources': [{'path': '/private/development/path'}],
                    'custom_assets': [{'source': '/Game/Items/Old.Old',
                                       'target': f'/Game/Items/{name}.{name}', 'file': relative,
                                       'native_parent_class': '/Script/g3.GSpawnProjectileEffect'}],
                }))
                helper.export_mod(workspace, root / name, sig)
                manifest = root / name / 'manifest.json'
                self.assertNotIn('private', manifest.read_text())
                self.assertEqual(json.loads(manifest.read_text())['custom_assets'][0]['native_parent_class'],
                                 '/Script/g3.GSpawnProjectileEffect')
                manifests.append(manifest)
            output = root / 'generated_P.pak'
            helper.compose(base, manifests, output, sig)
            def registry_paths():
                with tempfile.TemporaryDirectory() as extract:
                    subprocess.run([sys.executable, str(helper.dependency('u4pak.py', 'u4pak')),
                                    'unpack', str(output)], cwd=extract, check=True, capture_output=True)
                    data = (Path(extract) / 'g3/AssetRegistry.bin').read_bytes()
                import struct
                offset = struct.unpack_from('<q', data, 20)[0]
                names, _ = patcher.parse_names(data, offset)
                records, _ = patcher.parse_assets(data, names, offset)
                from test_patch_asset_registry import read_tags
                for record in records:
                    if record.object_path in {'/Game/Items/Skins.Skins', '/Game/Items/Balance.Balance'}:
                        tags = read_tags(data, names, record)
                        self.assertEqual(tags['ParentClass'], "Class'/Script/g3.GSpawnProjectileEffect'")
                        self.assertEqual(tags['NativeParentClass'], tags['ParentClass'])
                return {record.object_path for record in records}
            self.assertIn('/Game/Items/Balance.Balance', registry_paths())
            helper.compose(base, manifests[:1], output, sig)
            self.assertNotIn('/Game/Items/Balance.Balance', registry_paths())
            self.assertIn('/Game/Items/Skins.Skins', registry_paths())
            previous = output.read_bytes()
            with self.assertRaisesRegex(ValueError, 'duplicate target'):
                helper.compose(base, manifests[:1] * 2, output, sig)
            self.assertEqual(previous, output.read_bytes())
            pak = root / 'Skins/Skins_P.pak'
            pak.write_bytes(pak.read_bytes() + b'changed')
            with self.assertRaisesRegex(ValueError, 'hash differs'):
                helper.compose(base, manifests[:1], output, sig)
            self.assertEqual(previous, output.read_bytes())
            helper.compose(base, [], output, sig)
            self.assertEqual(len(registry_paths()), 2)
            standalone = root / 'standalone'
            standalone.mkdir()
            shutil.copyfile(Path(helper.__file__), standalone / 'mod_distribution.py')
            for name, folder in [('patch_asset_registry.py', 'asset_registry'), ('u4pak.py', 'u4pak')]:
                shutil.copyfile(helper.dependency(name, folder), standalone / name)
            subprocess.run([sys.executable, str(standalone / 'mod_distribution.py'), 'compose',
                            '--base-registry', str(base), '--signature', str(sig),
                            '--output', str(output)], check=True, capture_output=True)
            self.assertEqual(len(registry_paths()), 2)


if __name__ == '__main__':
    unittest.main()
