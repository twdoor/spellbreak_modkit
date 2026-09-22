#!/usr/bin/env python3
"""Workflow transaction and localization regression tests without game fixtures."""
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'spellbreak_uasset_editor/mod_workflows'))
import locres
import workflows as w


def property_data(name, kind, value, **extra):
    return {'$type': f'UAssetAPI.PropertyTypes.Objects.{kind}, UAssetAPI',
            'Name': name, 'Value': value, **extra}


class FakeConverter:
    def __init__(self, *_args):
        pass

    def read(self, path):
        return json.loads(path.read_text())

    def write(self, data, path):
        path.write_bytes(w.encoded(data))
        path.with_suffix('.uexp').write_bytes(b'new exports')


class WorkflowsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'mod'
        self.base = Path(self.temp.name) / 'base'
        self.rel = 'g3/Content/Example.uasset'
        self.asset = self.root / self.rel
        self.asset.parent.mkdir(parents=True)
        self.data = {'NameMap': [], 'Exports': [{'ObjectName': 'Default__Example_C', 'Data': [
            property_data('Damage', 'IntPropertyData', 10),
            property_data('Enabled', 'BoolPropertyData', True),
            property_data('DisplayName', 'TextPropertyData', 'SharedKey', HistoryType='Base',
                          CultureInvariantString='Damage 10', Namespace='Vanilla', Flags=0),
            property_data('Big', 'Int64PropertyData', 2**60 + 1),
        ]}]}
        self.asset.write_bytes(w.encoded(self.data))
        self.asset.with_suffix('.uexp').write_bytes(b'old exports')
        self.asset.with_suffix('.ubulk').write_bytes(b'untouched bulk data')
        for culture in ('en', 'fr', 'de'):
            p = self.base / w.LOC.format(culture)
            p.parent.mkdir(parents=True)
            p.write_bytes(locres.dumps({('Vanilla', 'SharedKey'): (locres.crc('Damage 10'), 'Original'),
                                       ('Other', 'Keep'): (123, 'Unrelated')}))
        self.converter = FakeConverter()
        self.addCleanup(patch.stopall)
        patch.object(w, 'Converter', FakeConverter).start()

    def request(self, command, **extra):
        return {'command': command, 'mod': str(self.root), 'converter': '', **extra}

    def recipe(self, **extra):
        row = {'asset': self.rel, 'export': 'Default__Example_C', 'property': '/Data/0',
               'expected': 10, 'value': 2, 'operation': 'multiply', **extra}
        return {'version': 1, 'edits': [row]}

    def test_recipe_preview_apply_backup_and_companions(self):
        text = json.dumps(self.recipe())
        result = w.run(self.request('preview_recipe', recipe_text=text))
        self.assertEqual(result['changes'][0]['new'], '20')
        self.assertEqual(self.converter.read(self.asset), self.data)
        done = w.run(self.request('apply_recipe', recipe_text=text, token=result['token']))
        self.assertEqual(self.converter.read(self.asset)['Exports'][0]['Data'][0]['Value'], 20)
        self.assertEqual(self.asset.with_suffix('.ubulk').read_bytes(), b'untouched bulk data')
        self.assertEqual((Path(done['backup']) / self.rel).read_bytes(), w.encoded(self.data))

    def test_changed_companion_invalidates_preview(self):
        text = json.dumps(self.recipe())
        preview = w.run(self.request('preview_recipe', recipe_text=text))
        self.asset.with_suffix('.uexp').write_bytes(b'changed elsewhere')
        with self.assertRaisesRegex(ValueError, 'changed since preview'):
            w.run(self.request('apply_recipe', recipe_text=text, token=preview['token']))
        self.assertEqual(self.converter.read(self.asset), self.data)

    def test_expected_values_duplicate_paths_and_bounds(self):
        for edit in ({'expected': 99}, {'value': 2**31, 'operation': 'set'},
                     {'asset': '../outside.uasset'}, {'value': True}):
            with self.assertRaises(ValueError):
                w.recipe_plan(self.root, self.recipe(**edit), self.converter)
        recipe = self.recipe()
        recipe['edits'] *= 2
        with self.assertRaises(ValueError):
            w.recipe_plan(self.root, recipe, self.converter)

    def test_inspect_preserves_large_integer(self):
        result = w.run(self.request('inspect', asset=self.rel))
        recipe = json.loads(result['recipe_text'])
        self.assertEqual(recipe['edits'][-1]['expected'], 2**60 + 1)

    def test_localization_preserves_base_and_rekeys_only_selected_text(self):
        catalog = w.scan(self.root, self.converter)
        row = catalog['rows'][0]
        row['translations']['fr'] = 'Dégâts 10'
        result = w.localize(self.root, self.base, catalog, ['fr'], self.converter)
        resource = locres.loads((self.root / w.LOC.format('fr')).read_bytes())
        self.assertEqual(resource['Other', 'Keep'], (123, 'Unrelated'))
        self.assertEqual(resource['Vanilla', 'SharedKey'][1], 'Original')
        self.assertEqual(resource[row['namespace'], row['key']], (locres.crc('Damage 10'), 'Dégâts 10'))
        text = self.converter.read(self.asset)['Exports'][0]['Data'][2]
        self.assertEqual(text['Namespace'], row['namespace'])
        self.assertEqual(text['Value'], row['key'])
        w.validate_catalog(self.root, result['catalog'])
        self.assertEqual(w.scan(self.root, self.converter)['rows'][0]['translations']['fr'], 'Dégâts 10')

    def test_scan_drops_stale_translations_after_source_change(self):
        catalog = w.scan(self.root, self.converter)
        catalog['rows'][0]['translations']['fr'] = 'Dégâts 10'
        w.run(self.request('save_catalog', catalog=catalog))
        self.data['Exports'][0]['Data'][2]['CultureInvariantString'] = 'Damage 20'
        self.asset.write_bytes(w.encoded(self.data))
        self.assertEqual(w.scan(self.root, self.converter)['rows'][0]['translations'], {})
        with self.assertRaisesRegex(ValueError, 'changed since'):
            w.localize(self.root, self.base, catalog, ['fr'], self.converter)

    def test_clearing_translation_restores_english(self):
        catalog = w.scan(self.root, self.converter)
        catalog['rows'][0]['translations']['fr'] = 'Dégâts 10'
        done = w.localize(self.root, self.base, catalog, ['fr'], self.converter)
        catalog = done['catalog']
        row = catalog['rows'][0]
        row['translations']['fr'] = ''
        w.localize(self.root, self.base, catalog, [], self.converter)
        rows = locres.loads((self.root / w.LOC.format('fr')).read_bytes())
        self.assertEqual(rows[row['namespace'], row['key']][1], 'Damage 10')

    def test_base_and_calculated_preview_together(self):
        self.data['Exports'][0]['Data'] = [
            property_data('BaseValue', 'FloatPropertyData', 10.0),
            property_data('CalculatedValue', 'FloatPropertyData', 12.0)]
        self.asset.write_bytes(w.encoded(self.data))
        recipe = self.recipe(expected=10.0, value=15.0, operation='set', sync_calculated=True)
        docs, changes, _, _ = w.recipe_plan(self.root, recipe, self.converter)
        self.assertEqual([row['new'] for row in changes], ['15.0', '15.0'])
        self.assertEqual(docs[self.rel]['Exports'][0]['Data'][1]['Value'], 15.0)

    def test_failed_serialization_does_not_modify_mod(self):
        text = json.dumps(self.recipe())
        preview = w.run(self.request('preview_recipe', recipe_text=text))
        with patch.object(FakeConverter, 'write', side_effect=ValueError('conversion failed')):
            with self.assertRaisesRegex(ValueError, 'conversion failed'):
                w.run(self.request('apply_recipe', recipe_text=text, token=preview['token']))
        self.assertEqual(self.asset.read_bytes(), w.encoded(self.data))
        self.assertEqual(self.asset.with_suffix('.uexp').read_bytes(), b'old exports')

    def test_install_failure_rolls_back_package(self):
        import os
        original_replace = os.replace
        calls = []
        def fail_second(src, dst):
            calls.append(dst)
            if len(calls) == 2:
                raise OSError('simulated disk failure')
            original_replace(src, dst)
        with patch.object(w.os, 'replace', side_effect=fail_second):
            with self.assertRaises(OSError):
                w.install(self.root, {self.rel: b'new asset', self.rel[:-7] + '.uexp': b'new exports'}, {})
        self.assertEqual(self.asset.read_bytes(), w.encoded(self.data))
        self.assertEqual(self.asset.with_suffix('.uexp').read_bytes(), b'old exports')

    def test_merge_languages_keeps_both_mod_namespaces(self):
        second = Path(self.temp.name) / 'second'
        for root, ns in [(self.root, 'ModOne'), (second, 'ModTwo')]:
            path = root / w.LOC.format('fr')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(locres.dumps({(ns, 'Key'): (123, ns)}))
        w.run(self.request('merge_localization', mods=[str(self.root), str(second)]))
        rows = locres.loads((self.root / w.LOC.format('fr')).read_bytes())
        self.assertEqual(set(rows), {('ModOne', 'Key'), ('ModTwo', 'Key')})

    def test_locres_unicode_and_invalid_version(self):
        rows = {('N', 'K'): (1, '日本語 😀'), ('N', 'K2'): (2, '日本語 😀'), ('', ''): (0, '')}
        self.assertEqual(locres.loads(locres.dumps(rows)), rows)
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            locres.loads(locres.MAGIC + b'\x03')
        with self.assertRaises(ValueError):
            locres.loads(locres.dumps(rows)[:-3])


if __name__ == '__main__':
    unittest.main()
