#!/usr/bin/env python3
"""Package the standalone mod tools and their documentation for a release."""
import argparse
from pathlib import Path
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='destination .zip file')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    files = {
        'mod_distribution.py': root / 'tools/mod_distribution.py',
        'patch_asset_registry.py': root / 'spellbreak_uasset_editor/asset_registry/patch_asset_registry.py',
        'u4pak.py': root / 'spellbreak_uasset_editor/u4pak/u4pak.py',
        'U4PAK_LICENSE_AND_README.md': root / 'spellbreak_uasset_editor/u4pak/README.md',
        'LICENSE': root / 'LICENSE',
    }
    instructions = (root / 'tools/MOD_DISTRIBUTION.md').read_text(encoding='utf-8')
    instructions = instructions.replace('python tools/mod_distribution.py', 'python3 mod_distribution.py')
    instructions = instructions.split('## Copy into another project')[0]
    instructions += ('## Included scripts\n\nKeep the three Python scripts together. '
                     'On Windows, use `py -3` instead of `python3`. '
                     'No extra Python packages are required.\n')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, path in files.items():
            archive.write(path, 'spellbreak-mod-tools/' + name)
        archive.writestr('spellbreak-mod-tools/README.md', instructions)
    print(args.output)


if __name__ == '__main__':
    main()
