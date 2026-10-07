"""Mod-folder localization and reviewed property recipes using UAssetConverter.

All content writes are staged, reopened, then installed with rollback and retained
backups outside g3. No game installation or pak/server composition happens here.
"""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

import locres

EXTENSIONS = ('.uasset', '.uexp', '.ubulk', '.uptnl')
CULTURES = ('en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'ru', 'zh-Hans')
CATALOG = '.modkit/localization.json'
LOC = 'g3/Content/Localization/Game/{}/Game.locres'
NUMERIC = {'FloatPropertyData', 'DoublePropertyData', 'IntPropertyData', 'Int64PropertyData',
           'UInt32PropertyData', 'UInt64PropertyData', 'Int16PropertyData', 'UInt16PropertyData',
           'Int8PropertyData', 'BytePropertyData'}
INTEGER_RANGES = {'IntPropertyData': (-2**31, 2**31-1), 'Int64PropertyData': (-2**63, 2**63-1),
                  'UInt32PropertyData': (0, 2**32-1), 'UInt64PropertyData': (0, 2**64-1),
                  'Int16PropertyData': (-2**15, 2**15-1), 'UInt16PropertyData': (0, 2**16-1),
                  'Int8PropertyData': (-128, 127), 'BytePropertyData': (0, 255)}


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def encoded(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def safe(root, relative):
    relative = str(relative)
    if '\\' in relative or ':' in relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise ValueError(f'Invalid relative path: {relative}')
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()) or path == root.resolve():
        raise ValueError(f'Path escapes mod: {relative}')
    return path


def prop_type(prop):
    return prop.get('$type', '').split(',')[0].split('.')[-1]


def properties(value, pointer=''):
    if isinstance(value, dict):
        if prop_type(value).endswith('PropertyData'):
            yield pointer, value
        for key, child in value.items():
            yield from properties(child, pointer + '/' + key.replace('~', '~0').replace('/', '~1'))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from properties(child, pointer + '/' + str(index))


def at(value, pointer):
    if not isinstance(pointer, str) or not pointer.startswith('/'):
        raise ValueError('Property must be a JSON pointer from Inspect recipe properties')
    for segment in pointer[1:].split('/'):
        segment = segment.replace('~1', '/').replace('~0', '~')
        if isinstance(value, list):
            if not segment.isdigit():
                raise ValueError('Invalid property array index')
            value = value[int(segment)]
        else:
            value = value[segment]
    return value


def export_named(data, name):
    matches = [e for e in data['Exports'] if e.get('ObjectName') == name]
    if len(matches) != 1:
        raise ValueError(f'Export must resolve exactly once: {name}')
    return matches[0]


class Converter:
    def __init__(self, dll, dotnet="dotnet"):
        self.dll = str(Path(dll).resolve())
        self.dotnet = dotnet

    def run(self, *args):
        result = subprocess.run([self.dotnet, self.dll, *map(str, args)], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(result.stderr.strip() or result.stdout.strip() or 'Asset conversion failed')
        return result.stdout

    def read(self, path):
        return json.loads(self.run('read', path))

    def write(self, data, path):
        source = path.with_suffix('.json')
        source.write_bytes(encoded(data))
        self.run('fromjson', source, path)
        source.unlink()


def fingerprint(root, paths):
    return {str(p.relative_to(root)): digest(p) for p in sorted(set(paths))}


def package_paths(path):
    return [path.with_suffix(ext) for ext in EXTENSIONS]


def check_snapshot(root, snapshot):
    for relative, expected in snapshot.items():
        if digest(safe(root, relative)) != expected:
            raise ValueError(f'{relative} changed since preview/scan. Refresh before applying.')


def install(root, outputs, snapshot):
    """Rollback on error. Backups and a restoration map stay outside packed content."""
    check_snapshot(root, snapshot)
    backup = safe(root, '.modkit/backups/' + uuid.uuid4().hex)
    backup.mkdir(parents=True)
    previous, installed = {}, []
    try:
        for relative in outputs:
            target = safe(root, relative)
            previous[relative] = target.exists()
            if target.exists():
                dest = backup / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, dest)
        (backup / 'restore.json').write_bytes(encoded(previous))
        check_snapshot(root, snapshot)
        for relative, data in outputs.items():
            target = safe(root, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            temp = target.with_name('.' + target.name + '.' + uuid.uuid4().hex)
            try:
                temp.write_bytes(data)
                os.replace(temp, target)
            finally:
                temp.unlink(missing_ok=True)
            installed.append(relative)
    except Exception:
        for relative in reversed(installed):
            target = safe(root, relative)
            if previous[relative]:
                shutil.copy2(backup / relative, target)
            else:
                target.unlink(missing_ok=True)
        raise
    return str(backup)


def stage_assets(root, documents, converter, folder):
    outputs = {}
    for relative, data in documents.items():
        original = safe(root, relative)
        staged = folder / relative
        staged.parent.mkdir(parents=True, exist_ok=True)
        converter.write(data, staged)
        # Compare serialized properties and identities, ignoring converter offset bookkeeping.
        actual = converter.read(staged)
        if len(actual['Exports']) != len(data['Exports']):
            raise ValueError(f'{relative}: export count changed during serialization')
        for wanted, found in zip(data['Exports'], actual['Exports']):
            if wanted.get('ObjectName') != found.get('ObjectName') or wanted.get('Data') != found.get('Data'):
                raise ValueError(f'{relative}: properties changed unexpectedly during serialization')
        for ext in EXTENSIONS:
            generated = staged.with_suffix(ext)
            existing = original.with_suffix(ext)
            if generated.exists():
                outputs[str(existing.relative_to(root))] = generated.read_bytes()
            elif existing.exists() and ext in ('.ubulk', '.uptnl'):
                outputs[str(existing.relative_to(root))] = existing.read_bytes()
            elif existing.exists():
                raise ValueError(f'{relative}: serializer omitted companion {ext}')
    return outputs


def text_fields(prop):
    # This bundled UAssetAPI stores the Base key in Value and source in CultureInvariantString.
    # Accommodate explicit Key/SourceString fields when provided by other converter versions.
    return ('Key', 'SourceString') if 'SourceString' in prop else ('Value', 'CultureInvariantString')


def scan(root, converter):
    old = read_json(root / CATALOG) if (root / CATALOG).exists() else {}
    namespace = old.get('namespace') or 'SpellbreakModkit.' + uuid.uuid4().hex
    previous = {r['id']: r for r in old.get('rows', [])}
    rows, snapshot, skipped = [], {}, 0
    for path in sorted((root / 'g3').rglob('*.uasset')):
        relative = str(path.relative_to(root))
        safe(root, relative)
        snapshot.update(fingerprint(root, package_paths(path)))
        data = converter.read(path)
        for export in data['Exports']:
            for pointer, prop in properties(export.get('Data', []), '/Data'):
                if prop_type(prop) != 'TextPropertyData':
                    continue
                if prop.get('HistoryType') != 'Base':
                    skipped += 1
                    continue
                key_field, source_field = text_fields(prop)
                source = prop.get(source_field)
                if not isinstance(source, str) or not source.strip():
                    continue
                identity = relative + ':' + str(export['ObjectName']) + ':' + pointer
                row_id = hashlib.sha256(identity.encode()).hexdigest()
                prev = previous.get(row_id, {})
                # Give every edited text a mod-specific key; never modify vanilla translations
                # for other assets that happen to share its original localization key.
                rows.append({'id': row_id, 'asset': relative, 'export': export['ObjectName'],
                             'property': pointer, 'label': prop.get('Name', ''), 'source': source,
                             'namespace': namespace, 'key': row_id,
                             'localized': prop.get('Namespace') == namespace and prop.get(key_field) == row_id,
                             'translations': prev.get('translations', {}) if prev.get('source') == source else {}})
    check_snapshot(root, snapshot)
    return {'version': 1, 'namespace': namespace, 'rows': rows,
            'snapshot': snapshot, 'skipped': skipped, 'cultures': old.get('cultures', [])}


def validate_catalog(root, catalog):
    if catalog.get('version') != 1:
        raise ValueError('Unsupported localization catalog version')
    check_snapshot(root, catalog['snapshot'])
    seen = set()
    for row in catalog['rows']:
        if row['id'] in seen:
            raise ValueError('Duplicate localization row')
        seen.add(row['id'])
        if not row['namespace'] or not row['key']:
            raise ValueError('Empty localization identity')
        if any(c not in CULTURES or not isinstance(t, str) for c, t in row['translations'].items()):
            raise ValueError('Invalid translation culture or text')


def localize(root, source_root, catalog, cultures, converter):
    validate_catalog(root, catalog)
    cultures = list(dict.fromkeys([*catalog.get('cultures', []), *cultures]))
    if not cultures or any(c not in CULTURES for c in cultures):
        raise ValueError('Choose a supported language')
    cultures = list(dict.fromkeys(['en', *cultures]))
    # Only translated rows are rewritten. Untranslated mod texts keep their original behavior.
    rows = [r for r in catalog['rows'] if r.get('localized') or any(r['translations'].get(c, '').strip() for c in cultures if c != 'en')]
    if not rows:
        raise ValueError('Enter at least one translation for the selected language')
    documents, snapshot, resource_rows = {}, dict(catalog['snapshot']), {}
    for row in rows:
        relative = row['asset']
        if relative not in documents:
            documents[relative] = converter.read(safe(root, relative))
        prop = at(export_named(documents[relative], row['export']), row['property'])
        key_field, source_field = text_fields(prop)
        if prop_type(prop) != 'TextPropertyData' or prop.get('HistoryType') != 'Base' or prop.get(source_field) != row['source']:
            raise ValueError(f'{relative}: text changed since scan')
        prop['Namespace'], prop[key_field] = row['namespace'], row['key']
        prop['Flags'] = 0  # localized Base text
        for culture in cultures:
            text = row['source'] if culture == 'en' else row['translations'].get(culture, '').strip()
            if not text:
                text = row['source']  # explicit English fallback, no stale prior translation
            identity = (row['namespace'], row['key'])
            value = (locres.crc(row['source']), text)
            prior = resource_rows.setdefault(culture, {}).get(identity)
            if prior is not None and prior != value:
                raise ValueError('Conflicting localization identities')
            resource_rows[culture][identity] = value
    outputs = {}
    base_snapshot = {}
    for culture in cultures:
        relative = LOC.format(culture)
        base_path = safe(source_root, relative)
        if not base_path.is_file():
            raise ValueError(f'Extracted source is missing {relative}')
        base_snapshot[relative] = digest(base_path)
        merged = locres.loads(base_path.read_bytes())
        target = safe(root, relative)
        snapshot[relative] = digest(target)
        if target.exists():
            merged.update(locres.loads(target.read_bytes()))
        merged.update(resource_rows[culture])
        outputs[relative] = locres.dumps(merged)
        if locres.loads(outputs[relative]) != merged:
            raise ValueError('Localization resource failed read-back validation')
    with tempfile.TemporaryDirectory(prefix='sb-localize-') as folder:
        outputs.update(stage_assets(root, documents, converter, Path(folder)))
    check_snapshot(source_root, base_snapshot)
    updated = copy.deepcopy(catalog)
    updated['cultures'] = cultures
    localized_ids = {row['id'] for row in rows}
    for row in updated['rows']:
        row['localized'] = row['id'] in localized_ids
    for relative, data in outputs.items():
        if relative in updated['snapshot']:
            updated['snapshot'][relative] = hashlib.sha256(data).hexdigest()
    outputs[CATALOG] = encoded(updated)
    snapshot[CATALOG] = digest(root / CATALOG)
    backup = install(root, outputs, snapshot)
    return {'message': f'Built {len(rows)} translated texts for {", ".join(cultures)}. Pack the mod normally.',
            'catalog': updated, 'backup': backup}


def recipe_plan(root, recipe, converter):
    if recipe.get('version') != 1 or not isinstance(recipe.get('edits'), list) or not recipe['edits']:
        raise ValueError('Recipe needs version 1 and a nonempty edits array')
    docs, changes, snapshot, seen = {}, [], {}, set()
    for edit in recipe['edits']:
        relative = edit['asset']
        path = safe(root, relative)
        if not relative.startswith('g3/') or path.suffix != '.uasset':
            raise ValueError('Recipes can only edit .uasset files already inside this mod’s g3 folder')
        if relative not in docs:
            snapshot.update(fingerprint(root, package_paths(path)))
            docs[relative] = converter.read(path)
        target = (relative, edit['export'], edit['property'])
        if target in seen:
            raise ValueError('Recipe targets the same property twice')
        seen.add(target)
        prop = at(export_named(docs[relative], edit['export']), edit['property'])
        typ = prop_type(prop)
        if typ not in NUMERIC | {'BoolPropertyData'}:
            raise ValueError(f'Unsupported recipe property type: {typ}. Use the regular editor for structural edits.')
        old = prop['Value']
        if 'expected' not in edit or type(edit['expected']) != type(old) or edit['expected'] != old:
            # JSON may represent an integral floating-point value without a decimal.
            if not (type(old) is float and type(edit.get('expected')) in (float, int) and edit['expected'] == old):
                raise ValueError(f'{relative} / {prop.get("Name")}: expected value does not match {old!r}')
        value, operation = edit['value'], edit.get('operation', 'set')
        if typ == 'BoolPropertyData':
            if operation != 'set' or type(value) is not bool:
                raise ValueError('Boolean recipes require set and a boolean value')
            new = value
        else:
            if type(value) not in (int, float) or type(old) not in (int, float):
                raise ValueError('Numeric recipes require numeric values')
            if operation not in ('set', 'add', 'multiply'):
                raise ValueError(f'Unsupported operation: {operation}')
            new = value if operation == 'set' else old + value if operation == 'add' else old * value
            if not math.isfinite(new):
                raise ValueError('Recipe result must be finite')
            if typ in INTEGER_RANGES:
                lo, hi = INTEGER_RANGES[typ]
                if int(new) != new or not lo <= new <= hi:
                    raise ValueError(f'Recipe result exceeds {typ} range')
                new = int(new)
            elif typ == 'FloatPropertyData' and abs(new) > 3.402823466e38:
                raise ValueError('Recipe result exceeds float32 range')
        prop['Value'] = new
        if new != old:
            changes.append({'asset': relative, 'export': edit['export'], 'property': edit['property'],
                            'label': prop.get('Name', ''), 'old': str(old), 'new': str(new)})
        if edit.get('sync_calculated', False):
            if prop.get('Name') != 'BaseValue':
                raise ValueError('sync_calculated is only supported on BaseValue properties')
            parent = edit['property'].rsplit('/', 1)[0]
            siblings = at(export_named(docs[relative], edit['export']), parent)
            twins = [(i, item) for i, item in enumerate(siblings)
                     if isinstance(item, dict) and item.get('Name') == 'CalculatedValue']
            if len(twins) != 1 or prop_type(twins[0][1]) != typ:
                raise ValueError('Could not resolve a matching CalculatedValue sibling')
            index, twin = twins[0]
            twin_pointer = parent + '/' + str(index)
            twin_target = (relative, edit['export'], twin_pointer)
            if twin_target in seen:
                raise ValueError('CalculatedValue is already targeted by this recipe')
            seen.add(twin_target)
            if twin['Value'] != new:
                changes.append({'asset': relative, 'export': edit['export'], 'property': twin_pointer,
                                'label': 'CalculatedValue', 'old': str(twin['Value']), 'new': str(new)})
            twin['Value'] = new
    if not changes:
        raise ValueError('The recipe makes no changes. Edit its values before previewing.')
    changed_assets = {change['asset'] for change in changes}
    docs = {relative: data for relative, data in docs.items() if relative in changed_assets}
    check_snapshot(root, snapshot)
    token = hashlib.sha256(encoded({'recipe': recipe, 'snapshot': snapshot})).hexdigest()
    return docs, changes, snapshot, token


def run(request):
    root = Path(request['mod']).resolve()
    if not (root / 'g3').is_dir():
        raise ValueError('Choose a mod folder containing g3')
    converter = Converter(request['converter'], request.get('dotnet', 'dotnet'))
    command = request['command']
    if command == 'merge_localization':
        merged_count = 0
        for culture in CULTURES:
            relative = LOC.format(culture)
            inputs = [safe(Path(mod).resolve(), relative) for mod in request['mods']]
            inputs = [path for path in inputs if path.is_file()]
            if len(inputs) < 2:
                continue
            rows = {}
            for path in inputs:
                rows.update(locres.loads(path.read_bytes()))
            safe(root, relative).write_bytes(locres.dumps(rows))
            merged_count += 1
        return {'message': f'Merged {merged_count} shared language resources.'}
    if command == 'scan':
        catalog = scan(root, converter)
        return {'catalog': catalog, 'message': f'Found {len(catalog["rows"])} editable texts; skipped {catalog["skipped"]} non-Base texts.'}
    if command == 'save_catalog':
        catalog = request['catalog']
        validate_catalog(root, catalog)
        backup = install(root, {CATALOG: encoded(catalog)}, {CATALOG: digest(root / CATALOG)})
        return {'message': 'Translations saved.', 'backup': backup}
    if command == 'localize':
        return localize(root, Path(request['source']).resolve(), request['catalog'], request['cultures'], converter)
    if command == 'inspect':
        relative = request['asset']
        path = safe(root, relative)
        if not relative.startswith('g3/') or path.suffix != '.uasset':
            raise ValueError('Choose an asset inside the mod')
        data = converter.read(path)
        edits = []
        for export in data['Exports']:
            for pointer, prop in properties(export.get('Data', []), '/Data'):
                if prop_type(prop) in NUMERIC | {'BoolPropertyData'} and type(prop.get('Value')) in (bool, int, float):
                    edits.append({'asset': relative, 'export': export['ObjectName'], 'property': pointer,
                                  'expected': prop['Value'], 'value': prop['Value'], 'operation': 'set'})
        # Return JSON as text so the UI never rounds 64-bit integers through its JSON number type.
        return {'recipe_text': encoded({'version': 1, 'edits': edits}).decode(),
                'message': f'Generated {len(edits)} property edits. Keep the rows you want and change their values.'}
    if command in ('preview_recipe', 'apply_recipe'):
        recipe = json.loads(request['recipe_text'])
        docs, changes, snapshot, token = recipe_plan(root, recipe, converter)
        if command == 'preview_recipe':
            return {'changes': changes, 'token': token, 'message': f'{len(changes)} changes ready for review.'}
        if token != request.get('token'):
            raise ValueError('Recipe or asset files changed since preview. Preview again.')
        with tempfile.TemporaryDirectory(prefix='sb-recipe-') as folder:
            outputs = stage_assets(root, docs, converter, Path(folder))
        backup = install(root, outputs, snapshot)
        return {'message': f'Applied {len(changes)} property edits.', 'backup': backup}
    raise ValueError('Unknown workflow command')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('request', help='JSON request file')
    parser.add_argument('result', help='JSON result file')
    args = parser.parse_args()
    try:
        result = {'ok': True, **run(read_json(args.request))}
    except Exception as exc:
        result = {'ok': False, 'message': str(exc)}
    Path(args.result).write_bytes(encoded(result))
    raise SystemExit(0 if result['ok'] else 1)
