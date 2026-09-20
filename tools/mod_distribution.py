#!/usr/bin/env python3
"""Export portable Spellbreak mods and compose their shared registry pak."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile


def dependency(name: str, folder: str) -> Path:
    bundled = Path(__file__).resolve().parents[1] / 'spellbreak_uasset_editor' / folder / name
    if bundled.is_file():
        return bundled
    return Path(__file__).resolve().with_name(name)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(value, dict) or value.get('schema_version') != 1:
        raise ValueError(f'{path}: expected manifest schema_version 1')
    return value


def declarations(manifest: dict) -> list[dict]:
    entries = manifest.get('custom_assets', [])
    if not isinstance(entries, list):
        raise ValueError('custom_assets must be an array')
    result = []
    targets = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('custom asset must be an object')
        for field in ('source', 'target', 'file'):
            if not isinstance(entry.get(field), str) or not entry[field]:
                raise ValueError(f'custom asset requires {field}')
        relative = PurePosixPath(entry['file'])
        if ('\\' in entry['file'] or '..' in relative.parts
                or not entry['file'].startswith('g3/Content/')
                or relative.suffix != '.uasset'):
            raise ValueError(f'invalid custom asset file: {relative}')
        package = '/Game/' + str(relative.relative_to('g3/Content').with_suffix(''))
        if entry['target'] != package + '.' + relative.stem:
            raise ValueError(f'asset target does not match file: {relative}')
        if not entry['source'].startswith('/Game/') or '.' not in entry['source']:
            raise ValueError(f'invalid source ObjectPath: {entry["source"]}')
        if entry['target'].casefold() in targets:
            raise ValueError(f'duplicate target: {entry["target"]}')
        targets.add(entry['target'].casefold())
        cleaned = {key: entry[key] for key in ('source', 'target', 'file')}
        if entry.get('reference_group'):
            if not isinstance(entry['reference_group'], str):
                raise ValueError('reference_group must be a string')
            cleaned['reference_group'] = entry['reference_group']
        result.append(cleaned)
    return result


def pack(staging: Path, output: Path) -> None:
    subprocess.run([sys.executable, str(dependency('u4pak.py', 'u4pak')),
                    'pack', '-z', '--archive-version=3', '--mount-point=../../../',
                    str(output.resolve()), 'g3/'], cwd=staging, check=True)


def export_mod(workspace: Path, output: Path, signature: Path) -> None:
    workspace = workspace.resolve()
    output = output.resolve()
    if output.exists() or output.is_relative_to(workspace):
        raise ValueError('export destination must be new and outside the workspace')
    manifest = read_json(workspace / 'spellbreak_mod_manifest.json')
    if manifest.get('profile', {}).get('content_root', 'g3') != 'g3':
        raise ValueError('only the Spellbreak g3 profile is supported')
    assets = declarations(manifest)
    content = workspace / 'g3' / 'Content'
    if not content.is_dir():
        raise ValueError('workspace has no g3/Content directory')
    files = sorted(p for p in content.rglob('*') if p.is_file())
    if not files:
        raise ValueError('workspace contains no content files')
    if any(p.is_symlink() for p in (workspace / 'g3').rglob('*')):
        raise ValueError('workspace content must not contain symbolic links')
    for entry in assets:
        if not (workspace / entry['file']).is_file():
            raise ValueError(f'missing declared file: {entry["file"]}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        root = Path(temp)
        staging = root / 'stage'
        bundle = root / 'bundle'
        bundle.mkdir()
        shutil.copytree(content, staging / 'g3' / 'Content')
        pak = bundle / (output.name + '_P.pak')
        pack(staging, pak)
        shutil.copyfile(signature, pak.with_suffix('.sig'))
        portable = {
            'schema_version': 1, 'kind': 'spellbreak-distribution',
            'name': manifest.get('mod', {}).get('name', workspace.name),
            'pak': pak.name, 'pak_sha256': digest(pak), 'custom_assets': assets,
        }
        (bundle / 'manifest.json').write_text(json.dumps(portable, indent=2) + '\n', encoding='utf-8')
        bundle.rename(output)
    print(f'Exported {output}')


def compose(base: Path, manifests: list[Path], output: Path, signature: Path) -> None:
    patcher = load_module('distribution_registry', dependency('patch_asset_registry.py', 'asset_registry'))
    u4pak = load_module('distribution_u4pak', dependency('u4pak.py', 'u4pak'))
    operations = []
    targets = {}
    protected = {base.resolve(), signature.resolve()}
    for index, path in enumerate(manifests):
        manifest = read_json(path)
        if manifest.get('kind') != 'spellbreak-distribution':
            raise ValueError(f'{path}: expected an exported distribution manifest')
        name = manifest.get('pak')
        if not isinstance(name, str) or '/' in name or '\\' in name or not name.endswith('.pak'):
            raise ValueError(f'{path}: invalid sibling pak filename')
        pak = path.parent / name
        protected.update((path.resolve(), pak.resolve(), pak.with_suffix('.sig').resolve()))
        if digest(pak) != manifest.get('pak_sha256'):
            raise ValueError(f'{pak}: hash differs from manifest; export the mod again')
        with pak.open('rb') as stream:
            archive = u4pak.read_index(stream, check_integrity=True)
        if archive.mount_point != '../../../':
            raise ValueError(f'{pak}: unexpected mount point')
        filenames = {record.filename for record in archive.records}
        if any(name.casefold() == 'g3/assetregistry.bin' for name in filenames):
            raise ValueError(f'{pak}: content pak must not contain AssetRegistry.bin')
        for entry in declarations(manifest):
            if entry['file'] not in filenames:
                raise ValueError(f'{pak}: declared file absent: {entry["file"]}')
            target = entry['target'].casefold()
            if target in targets:
                raise ValueError(f'duplicate target {entry["target"]}: {targets[target]} and {path}')
            targets[target] = path
            entry['reference_group'] = f'{index}:' + patcher.skin_reference_group(entry)
            operations.append(entry)
    output = output.resolve()
    if output.suffix != '.pak' or not output.stem.endswith('_P'):
        raise ValueError('registry output must end in _P.pak')
    if output in protected or output.with_suffix('.sig') in protected:
        raise ValueError('registry output would overwrite an input')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        root = Path(temp)
        # Also generate a vanilla registry when no packs are selected, clearing stale entries.
        patcher.patch_registry_many(base, root / 'stage/g3/AssetRegistry.bin', operations)
        staged = root / output.name
        pack(root / 'stage', staged)
        staged_sig = staged.with_suffix('.sig')
        shutil.copyfile(signature, staged_sig)
        os.replace(staged_sig, output.with_suffix('.sig'))
        os.replace(staged, output)
    print(f'Composed {output} from {len(manifests)} mod(s)')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export', help='export a workspace as a new portable bundle directory')
    export.add_argument('workspace', type=Path)
    export.add_argument('output', type=Path)
    export.add_argument('--signature', type=Path, required=True)
    combine = commands.add_parser('compose', help='build the registry pak for exactly the supplied mods')
    combine.add_argument('--base-registry', type=Path, required=True)
    combine.add_argument('--output', type=Path, required=True)
    combine.add_argument('--signature', type=Path, required=True)
    combine.add_argument('manifests', type=Path, nargs='*')
    args = parser.parse_args()
    try:
        if args.command == 'export':
            export_mod(args.workspace, args.output, args.signature)
        else:
            compose(args.base_registry, args.manifests, args.output, args.signature)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
