#!/usr/bin/env python3
"""Build an x86-64 export-only UE Viewer from a supplied source checkout.

Use Ubuntu 22.04 or an equivalent glibc 2.35 build container for releases.
Requires GCC/G++, make and Perl. No SDL, OpenGL or 32-bit libraries are needed.
The supplied source tree is copied; it is never modified.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='sb-umodel-') as tmp:
        root = Path(tmp) / 'src'
        shutil.copytree(args.source, root, ignore=shutil.ignore_patterns('.git', 'obj'))
        p = root / 'UmodelTool/Build.h'
        s = p.read_text().replace('#define RENDERING\t\t1', '#define RENDERING\t\t0')
        s = s.replace('#define THREADING\t\t1', '#define THREADING\t\t0')
        p.write_text(s)
        p = root / 'common.project'
        s = p.read_text().replace('STDLIBS += GL', '# No OpenGL for export-only builds')
        s = s.replace('USE_SYSTEM_LIBS = 1', 'USE_SYSTEM_LIBS = 0')
        s = s.replace('!include $R/libs/SDL2/SDL2.project', '# No SDL for export-only builds')
        # GCC is used as the linker by genmake; link libstdc++ explicitly statically.
        s = s.replace('STDLIBS   = m stdc++', 'STDLIBS   = m')
        s += '\nLINKFLAGS += -static-libgcc -Wl,-Bstatic -lstdc++ -Wl,-Bdynamic\n'
        p.write_text(s)
        (root / 'obj').mkdir(exist_ok=True)
        with (root / 'obj/umodel.mak').open('w') as out:
            subprocess.run(['perl', 'Tools/genmake', 'UmodelTool/umodel.project',
                            'TARGET=linux64', 'EXE_NAME=umodel-export'], cwd=root, stdout=out, check=True)
        subprocess.run(['make', '-f', 'obj/umodel.mak', '-j4'], cwd=root, check=True)
        args.output.mkdir(parents=True, exist_ok=True)
        for name in ['umodel-export', 'LICENSE.txt', 'readme.txt']:
            shutil.copy2(root / name, args.output / name)


if __name__ == '__main__':
    main()
