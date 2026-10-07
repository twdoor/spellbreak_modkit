#!/usr/bin/env python3
"""Build pinned, platform-specific runtime ZIPs for Godot releases.

Build-time Python only. No downloads or package installation happen in the editor.
UE Viewer directories must contain the executable and its upstream LICENSE.txt.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'tools/runtime-lock.json'


def download(spec, cache):
    algorithm = 'sha256' if 'sha256' in spec else 'sha512'
    expected = spec[algorithm]
    path = cache / (expected[:16] + '-' + spec['url'].rsplit('/', 1)[1])
    if not path.exists():
        print('Downloading', spec['url'], flush=True)
        temporary = path.with_suffix('.partial')
        with urllib.request.urlopen(spec['url'], timeout=120) as response, temporary.open('wb') as out:
            shutil.copyfileobj(response, out)
        temporary.replace(path)
    with path.open('rb') as downloaded:
        actual = hashlib.file_digest(downloaded, algorithm).hexdigest()
    if actual != expected:
        raise ValueError(f'Checksum mismatch: {path}; delete this cached download and retry')
    return path


def unpack(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                target = (destination / name).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise ValueError('Unsafe archive path: ' + name)
            z.extractall(destination)
    else:
        with tarfile.open(archive) as t:
            t.extractall(destination, filter='data')


def build(platform, spec, umodel, output, cache):
    with tempfile.TemporaryDirectory(prefix='sb-runtimes-') as tmp:
        root = Path(tmp)
        unpack(download(spec['python'], cache), root)
        unpack(download(spec['dotnet'], cache), root / 'dotnet')
        windows = platform == 'win-x64'
        python = 'python/python.exe' if windows else 'python/bin/python3.12'
        dotnet = 'dotnet/dotnet.exe' if windows else 'dotnet/dotnet'
        model_name = 'umodel_64.exe' if windows else 'umodel-export'
        tools = {'python': python, 'dotnet': dotnet, 'umodel': 'umodel/' + model_name}
        model = root / 'umodel'
        model.mkdir()
        for name in [model_name, 'LICENSE.txt'] + (['SDL2_64.dll'] if windows else []):
            shutil.copy2(umodel / name, model / name)
        if (umodel / 'readme.txt').exists():
            shutil.copy2(umodel / 'readme.txt', model / 'readme.txt')
        # Preserve upstream notices. Some Windows packages name SDL by bitness;
        # the 64-bit executable may still request SDL2.dll.
        if windows:
            shutil.copy2(model / 'SDL2_64.dll', model / 'SDL2.dll')
        for relative in tools.values():
            if not (root / relative).is_file():
                raise ValueError('Missing runtime executable: ' + relative)
        executables = []
        files = []
        for p in sorted(root.rglob('*')):
            if not p.is_file() or '__pycache__' in p.parts or p.suffix == '.pyc':
                continue
            if p.is_symlink() and not p.resolve().is_relative_to(root):
                raise ValueError('Runtime symlink escapes staging: ' + str(p))
            relative = p.relative_to(root).as_posix()
            files.append((p, relative))
            if p.stat().st_mode & 0o111 or relative in tools.values():
                executables.append(relative)
        manifest = {'platform': platform, 'tools': tools, 'executables': executables,
                    'sources': spec, 'umodel_sha256': hashlib.sha256((model / model_name).read_bytes()).hexdigest()}
        output.mkdir(parents=True, exist_ok=True)
        archive = output / (platform + '.zip')
        temporary = archive.with_suffix('.partial')
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for p, relative in files:
                info = zipfile.ZipInfo(relative, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | (0o755 if relative in executables else 0o644)) << 16
                z.writestr(info, p.read_bytes())  # Dereference in-tree symlinks for ZIPReader.
            z.writestr('manifest.json', json.dumps(manifest, indent=2))
        temporary.replace(archive)
        print(f'Built {archive} ({archive.stat().st_size / 1024**2:.1f} MiB)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux-x64', 'win-x64'], required=True)
    parser.add_argument('--umodel-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'spellbreak_uasset_editor/runtimes')
    parser.add_argument('--cache', type=Path, default=ROOT / 'dist/runtime-downloads')
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    build(args.platform, json.loads(LOCK.read_text())[args.platform], args.umodel_dir, args.output, args.cache)


if __name__ == '__main__':
    main()
