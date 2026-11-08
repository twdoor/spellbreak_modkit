#!/usr/bin/env python3
"""Development adapter for the Modkit request-file backend. Installed users: run modkit or modkit.cmd beside the app."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1] / 'spellbreak_uasset_editor'
SCHEMA_VERSION = 1


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--version', action='version', version='Spellbreak Modkit CLI (schema 1)')
    p.add_argument('--json', action='store_true', help='emit one versioned JSON result on stdout')
    p.add_argument('--godot', default=os.environ.get('GODOT', 'godot'), help='Godot editor executable (or GODOT)')
    p.add_argument('--backend', default=os.environ.get('SPELLBREAK_MODKIT_BACKEND'), help='exported Modkit executable instead of Godot')
    p.add_argument('--timeout', type=float, default=600, help='backend timeout in seconds (default: 600)')
    p.add_argument('--verbose', action='store_true', help='send backend diagnostics to stderr')
    sub = p.add_subparsers(dest='group', required=True)
    sub.add_parser('doctor', help='report profile, settings, and tool paths')
    sub.add_parser('commands', help='machine-readable command and option discovery')
    search = sub.add_parser('search', help='find asset filenames without deserializing packages')
    search.add_argument('root', type=absolute)
    search.add_argument('query', help='case-insensitive substring of relative path')
    search.add_argument('--limit', type=int, default=100)
    asset = sub.add_parser('asset', help='inspect, edit, compare, validate, and clone packages').add_subparsers(dest='action', required=True)
    for name, help_text in [('inspect', 'summary and export/import tables'), ('dump', 'complete serializer JSON'), ('validate', 'parse and check package indices'), ('refs', 'find serialized /Game references with JSON pointers'), ('umg', 'inspect cooked widget hierarchy')]:
        q = asset.add_parser(name, help=help_text)
        q.add_argument('asset', type=absolute)
    q = asset.add_parser('diff', help='semantic differences between two assets')
    q.add_argument('asset', type=absolute)
    q.add_argument('other', type=absolute)
    q = asset.add_parser('patch', help='apply JSON-pointer test/replace operations; stage and reopen before installation')
    q.add_argument('asset', type=absolute)
    q.add_argument('patch', type=absolute, help='JSON array of test/replace operations')
    q.add_argument('--output', type=absolute, required=True, help='destination .uasset (may be input with --overwrite)')
    q.add_argument('--dry-run', action='store_true', help='validate and report changes without saving')
    q.add_argument('--overwrite', action='store_true')
    q = asset.add_parser('clone', help='clone package identity and register it in a mod manifest')
    q.add_argument('asset', type=absolute)
    q.add_argument('--output', type=absolute, required=True)
    q.add_argument('--source-root', type=absolute, required=True)
    q.add_argument('--mod', type=absolute, required=True)
    cosmetic = sub.add_parser('cosmetic', help='clone a cosmetic and its editable dependency graph').add_subparsers(dest='action', required=True)
    q = cosmetic.add_parser('clone')
    q.add_argument('asset', type=absolute)
    q.add_argument('--source-root', type=absolute, required=True)
    q.add_argument('--mod', type=absolute, required=True)
    q.add_argument('--name', required=True, help='new full blueprint name, e.g. BP_Cosmetic_Skin_MySkin')
    q.add_argument('--display-name', default='')
    for group, extension in [('texture', 'PNG'), ('sound', 'OGG')]:
        media = sub.add_parser(group, help=f'{extension} export/import').add_subparsers(dest='action', required=True)
        q = media.add_parser('export')
        q.add_argument('asset', type=absolute)
        q.add_argument('--output', type=absolute, required=True)
        q.add_argument('--overwrite', action='store_true')
        q = media.add_parser('import', help='write a new package with the same filename in an output directory')
        q.add_argument('asset', type=absolute)
        q.add_argument('media', type=absolute)
        q.add_argument('--output-dir', type=absolute, required=True)
        q.add_argument('--overwrite', action='store_true')
    mesh = sub.add_parser('mesh', help='mesh and animation exports').add_subparsers(dest='action', required=True)
    q = mesh.add_parser('export')
    q.add_argument('asset', type=absolute)
    q.add_argument('--output-dir', type=absolute, required=True, help='new output directory for GLB export')
    q = mesh.add_parser('animations', help='find candidate animation packages')
    q.add_argument('asset', type=absolute)
    mod = sub.add_parser('mod', help='workspace validation and registry-aware packing').add_subparsers(dest='action', required=True)
    q = mod.add_parser('create', help='create a new workspace and manifest')
    q.add_argument('mod', type=absolute)
    q = mod.add_parser('validate')
    q.add_argument('mod', type=absolute)
    q = mod.add_parser('pack', help='export selected workspaces, without installing into the game')
    q.add_argument('mods', type=absolute, nargs='+', help='merge order: later workspaces win')
    q.add_argument('--output', type=absolute, required=True)
    q.add_argument('--source-root', type=absolute, help='base source containing g3/AssetRegistry.bin')
    q.add_argument('--game-dir', type=absolute, help='game installation containing a donor .sig')
    q.add_argument('--with-manifest', action='store_true', help='portable registry-free pak plus distribution manifest')
    q.add_argument('--overwrite', action='store_true')
    pak = sub.add_parser('pak', help='list, test, or extract a pak').add_subparsers(dest='action', required=True)
    for name in ('list', 'test', 'extract'):
        q = pak.add_parser(name)
        q.add_argument('pak', type=absolute)
        if name == 'extract':
            q.add_argument('--output-dir', type=absolute, required=True, help='new source directory')
    workflow = sub.add_parser('workflow', help='localization and batch recipes via the existing workflow request format')
    workflow.add_argument('request', type=absolute, help='JSON request; see docs/mod-workflows.md')
    return p


def absolute(value: str) -> str:
    return str(Path(value).expanduser().resolve())


def command_schema(p: argparse.ArgumentParser) -> dict:
    result = {'description': p.description, 'options': [], 'commands': {}}
    for action in p._actions:
        if isinstance(action, argparse._SubParsersAction):
            result['commands'] = {name: command_schema(child) for name, child in action.choices.items()}
        elif action.dest != 'help':
            result['options'].append({'name': action.dest, 'flags': action.option_strings,
                                      'required': action.required, 'help': action.help})
    return result


def envelope(ok: bool, message: str, value=None) -> dict:
    return {'schema_version': SCHEMA_VERSION, 'ok': ok, 'message': message, 'value': value}


def run_process(command, *, capture_output=True, text=True, timeout):
    """Stop backend descendants as well when a long-running command is cancelled."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=text, start_new_session=os.name != 'nt')
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.kill()
        process.communicate()
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_backend(request: dict, args: argparse.Namespace) -> dict:
    executable = args.backend or args.godot
    resolved = shutil.which(executable)
    if not resolved:
        raise ValueError(f'Backend executable not found: {executable}. Set --godot/GODOT or --backend.')
    if not args.backend and not (PROJECT / '.godot/global_script_class_cache.cfg').exists():
        imported = run_process([resolved, '--headless', '--editor', '--path', str(PROJECT), '--quit'],
                                  capture_output=True, text=True, timeout=args.timeout)
        if imported.returncode or 'SCRIPT ERROR' in imported.stderr:
            raise ValueError('Godot project import failed: ' + imported.stderr[-6000:])
    with tempfile.TemporaryDirectory(prefix='sb_cli_') as tmp:
        request_path, result_path = Path(tmp) / 'request.json', Path(tmp) / 'result.json'
        request_path.write_text(json.dumps(request, allow_nan=False), encoding='utf-8')
        if args.backend:
            command = [resolved, '--headless', '--', '--cli-request', str(request_path), str(result_path)]
        else:
            command = [resolved, '--headless', '--path', str(PROJECT), '--script',
                       'res://cli/headless.gd', '--', str(request_path), str(result_path)]
        completed = run_process(command, capture_output=True, text=True, timeout=args.timeout)
        diagnostics = completed.stdout + completed.stderr
        if args.verbose or completed.returncode:
            print(diagnostics, file=sys.stderr, end='')
        if not result_path.is_file():
            raise ValueError('Backend produced no result. ' + diagnostics[-6000:])
        result = json.loads(result_path.read_text(encoding='utf-8'))
        if completed.returncode and result.get('ok'):
            raise ValueError(f'Backend exited with status {completed.returncode}')
        if 'SCRIPT ERROR' in diagnostics:
            raise ValueError('Backend script error: ' + diagnostics[-6000:])
        return result


def execute(args: argparse.Namespace, p: argparse.ArgumentParser) -> dict:
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise ValueError('--timeout must be positive')
    if args.group == 'commands':
        return envelope(True, 'CLI command schema', command_schema(p))
    if args.group == 'search':
        root = Path(args.root)
        if not root.is_dir() or args.limit < 1:
            raise ValueError('Search requires an existing root and a positive --limit')
        matches = []
        truncated = False
        for directory, folders, files in os.walk(root, followlinks=False):
            folders[:] = sorted(f for f in folders if not f.startswith('.'))
            for name in sorted(files):
                path = Path(directory) / name
                relative = path.relative_to(root).as_posix()
                if path.suffix.lower() in ('.uasset', '.umap') and args.query.casefold() in relative.casefold():
                    if len(matches) == args.limit:
                        truncated = True
                        break
                    matches.append({'path': str(path), 'relative': relative, 'source_root': str(root)})
            if truncated:
                break
        return envelope(True, f'Found {len(matches)} assets', {'assets': matches, 'truncated': truncated})
    request = {k: v for k, v in vars(args).items() if k not in ('json', 'godot', 'backend', 'timeout', 'verbose')}
    if args.group == 'asset' and args.action == 'patch':
        request['operations'] = json.loads(Path(args.patch).read_text(encoding='utf-8'))
        validate_patch(request['operations'])
    if args.group == 'workflow':
        request['workflow'] = json.loads(Path(args.request).read_text(encoding='utf-8'))
        if not isinstance(request['workflow'], dict):
            raise ValueError('Workflow request must be an object')
        # Workflow paths are explicit, independent of the backend working directory.
        for key in ('mod', 'source'):
            if key in request['workflow']:
                request['workflow'][key] = absolute(request['workflow'][key])
    return run_backend(request, args)


def validate_patch(operations):
    if not isinstance(operations, list) or not operations:
        raise ValueError('Patch must be a nonempty array of test/replace operations')
    for op in operations:
        if not isinstance(op, dict) or op.get('op') not in ('test', 'replace') or 'value' not in op:
            raise ValueError('Each operation needs op (test or replace), path, and value')
        path = op.get('path')
        if not isinstance(path, str) or not path.startswith('/'):
            raise ValueError('Patch paths must be non-root JSON pointers starting with /')
        # Godot JSON numbers are doubles. Refuse values that would silently lose precision.
        def check(value):
            if isinstance(value, int) and abs(value) > 2**53:
                raise ValueError('Patch integer exceeds exact backend JSON precision (2^53)')
            if isinstance(value, list):
                for child in value:
                    check(child)
            if isinstance(value, dict):
                for child in value.values():
                    check(child)
        check(op['value'])


def main(argv=None) -> int:
    p = parser()
    # Preserve machine-readable errors even for malformed arguments.
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        if exc.code and '--json' in argv:
            print(json.dumps(envelope(False, 'Invalid arguments; consult --help')))
        return int(exc.code)
    try:
        result = execute(args, p)
    except KeyboardInterrupt:
        result = envelope(False, 'Interrupted')
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result = envelope(False, str(exc))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    else:
        print(result.get('message', ''), file=sys.stdout if result.get('ok') else sys.stderr)
        if result.get('value') is not None:
            print(json.dumps(result['value'], indent=2, ensure_ascii=False))
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    raise SystemExit(main())
