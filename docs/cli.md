# Spellbreak Modkit CLI

The CLI is part of the installed app. It uses the app's private runtimes and
asset services. **No Python installation, Godot editor, or source checkout is
needed. The GUI does not need to be open.**

## Installing a terminal command

In Settings, find **Command-line interface**, choose a command name (default
`sbue`), and click **Install CLI**. Installation applies immediately. Run
`sbue --help` from a terminal after adding the displayed directory to your user
PATH if it is not already present. Linux/macOS use `~/.local/bin`; Windows uses
`%LOCALAPPDATA%\SpellbreakModkit\bin`. No administrator access is needed.

**Uninstall CLI** removes the recorded launcher. Uninstall before changing the
command name or moving the app, then reinstall from the new location. Existing
files are never overwritten, and modified launchers are not deleted. Installation
is available in exported apps; the GUI need not remain open.

## Running it

Desktop exports include `modkit` (Linux) or `modkit.cmd` (Windows) beside the app.
Keep the launcher and executable together. Add that folder to PATH, or run it
using its full path:

```bash
/path/to/modkit --help
/path/to/modkit doctor
/path/to/modkit --json commands
/path/to/modkit asset inspect /mods/MyMod/g3/Content/Example.uasset
```

On Windows, use `C:\Tools\Spellbreak\modkit.cmd` from Command Prompt or
`& 'C:\Tools\Spellbreak\modkit.cmd' --help` from PowerShell. The launcher
uses the exported console wrapper when available and preserves the exit code.

The executable can also be used directly, including an AppImage:

```bash
./sbue.x86_64 --headless --no-header -- cli --json doctor
./sbue.AppImage --headless --no-header -- cli --help
```

`--headless` avoids opening a window; `--no-header` keeps the engine banner out
of stdout. Arguments after `-- cli` are Modkit commands. A separate invocation
runs the operation using the saved app settings. This is not a connection to a
running GUI's unsaved document state. Close an asset's editor tab before writing
the same file from the CLI.

These commands require a build containing the native CLI; previously published
1.0 binaries do not have it. The CLI adds no server, listening port, or background
daemon. `SPELLBREAK_MODKIT_CONFIG_DIR` can select an isolated settings folder.
The launcher resolves paths relative to the calling terminal's current directory.
Use absolute paths when invoking the executable directly. Overrides
are per invocation and are not saved into GUI settings. `--json` may appear
before or after the command. Use `--` before positional filenames starting with
`-`, and `--output=VALUE` for option values starting with `-`.

For contributors running from source, the equivalent is:

```bash
/path/to/godot --headless --no-header --path spellbreak_uasset_editor -- cli --help
```

Use absolute asset paths in this development invocation. `tools/modkit.py` remains a development
adapter for the earlier request-file protocol, not the installed user CLI.

## Command map

| Command | Purpose |
| --- | --- |
| `doctor` | Profile, configured sources, workspace and tool paths |
| `commands` | Discover commands and options as structured data |
| `search ROOT QUERY [--limit 100]` | Filename search with source provenance; no asset conversion |
| `asset inspect ASSET` | Export classes, imports, identity and companions |
| `asset dump ASSET` | Full serializer document in the result's `value` |
| `asset refs ASSET` | Serialized `/Game/` references and their JSON pointers |
| `asset diff LEFT RIGHT` | Semantic differences, capped at 5,000 with `truncated` flag |
| `asset validate ASSET` | Parse and validate package indices |
| `asset umg ASSET` | Cooked WidgetTree hierarchy |
| `asset patch ASSET PATCH --output FILE` | Test/replace explicit JSON paths; supports `--dry-run` |
| `asset clone ASSET --source-root ROOT --mod MOD --output FILE` | Unique identity, fresh GUID, texture relocation where needed, manifest registration |
| `cosmetic clone ASSET --source-root ROOT --mod MOD --name NAME` | Clone cosmetic and editable dependencies; optional `--display-name` |
| `texture export ASSET --output FILE.png` | Export PNG |
| `texture import ASSET FILE.png --output-dir DIR` | Inject PNG into a staged package and decode it for verification |
| `sound export ASSET --output FILE.ogg` | Export OGG |
| `sound import ASSET FILE.ogg --output-dir DIR` | Inject OGG and verify the extracted payload against the input |
| `mesh export ASSET --output-dir NEW_DIR` | Export GLB |
| `mesh animations ASSET` | Find candidate animation packages (heuristic) |
| `mod create NEW_MOD` | Create `g3/Content` and workspace manifest |
| `mod validate MOD` | Packing preflight, including orphan companions |
| `mod pack MOD... --output FILE.pak` | Merge in argument order and export pak/signature, including registry declarations |
| `pak list FILE.pak` | List archive paths |
| `pak test FILE.pak` | Test archive integrity |
| `pak extract FILE.pak --output-dir NEW_DIR` | Validate archive paths and extract a base source |
| `workflow REQUEST.json` | Localization and numeric/boolean batch recipes |

Use `<command> --help` for its flags. Single-package clones require an existing
mod workspace; create one with `mod create`. Media imports retain the source
filename. Commands refuse existing destinations unless they offer and receive
`--overwrite`. Cosmetic and unique clones always require unused destinations.
An empty directory counts as an existing output for mesh export and pak extraction.

## Editing properties, rows, text, references, and UMG layout

Start with the **current mod's package** when it already contains edits. Use its
matching base source for comparisons. Dump only likely candidates, outside `g3`:

```bash
modkit search /sources/base Treasure
modkit --json asset dump /mods/MyMod/g3/Content/Data/Example.uasset > before.json
```

The dump's `value` is the UAssetAPI document. Patch paths are RFC 6901 JSON
pointers into that document. Array indices are zero-based; `inspect` export
indices are Unreal's one-based package indices. `~1` escapes `/`, and `~0`
escapes `~`. Use the actual path from your dump, since export/property names can
repeat and DataTable structures vary.

```json
[
  {"op": "test", "path": "/Exports/0/Data/2/Value", "value": 10},
  {"op": "replace", "path": "/Exports/0/Data/2/Value", "value": 15}
]
```

```bash
modkit --json asset patch /sources/base/g3/Content/Example.uasset edits.json \
  --output /mods/MyMod/g3/Content/Example.uasset --dry-run
modkit --json asset patch /sources/base/g3/Content/Example.uasset edits.json \
  --output /mods/MyMod/g3/Content/Example.uasset
```

`test` provides a baseline precondition; a mismatch aborts the entire patch.
Only `test` and `replace` are accepted, and replacement paths must be unique.
Patches operate on copies, retain serializer fields, use the editor's FName
repair and package validation, preserve external bulk companions, then reopen
and verify replacements before installing the complete package. A dry run checks
the in-memory edit and reports a diff; it does not prove binary serialization.

Patch existing properties or rows. Reordering/deleting import/export tables by
replacing whole arrays is not a supported structural editing interface: it does
not remap references. Generic texture patching is refused; use texture import
or clone. This tool is a cooked asset editor, not an Unreal cooker or Blueprint
compiler.

Godot represents JSON numbers as doubles. Asset commands refuse documents with
integer tokens outside ±2^53 rather than silently rounding them. Use the Python
batch-recipe workflow for numeric edits requiring int64 fidelity. Cosmetic cloning
retains the existing GUI service's serialization behavior and limitations.

## Unique assets and cosmetics

```bash
modkit mod create /mods/MyMod
modkit asset clone /sources/base/g3/Content/Items/OldItem.uasset \
  --source-root /sources/base --mod /mods/MyMod \
  --output /mods/MyMod/g3/Content/Items/NewItem.uasset
modkit cosmetic clone /sources/base/g3/Content/Blueprints/Cosmetics/Skins/BP_Cosmetic_Skin_Hollow.uasset \
  --source-root /sources/base --mod /mods/MyMod \
  --name BP_Cosmetic_Skin_MySkin --display-name 'My Skin'
```

Use the actual source filename found by `search`. Cosmetic cloning uses the GUI's
dependency selection, localization keys, RawSkin layout, missing-icon handling,
and grouped registry declarations. A unique package clone only clones that package;
its unrelated dependencies remain shared. Both update the existing workspace
manifest rather than replacing its declarations.

## Packing

```bash
modkit mod validate /mods/MyMod
modkit mod pack /mods/MyMod --output /exports/MyMod_P.pak \
  --source-root /sources/base --game-dir /games/Spellbreak
modkit pak list /exports/MyMod_P.pak
modkit pak test /exports/MyMod_P.pak
```

Packing uses UE 4.22's Spellbreak profile: pak version 3, `../../../` mount point,
and `g3` content root. DDS import/export retains version 4.20; texture relocation
retains its separate 4.22 reader. A configured game directory or `--game-dir`
provides the donor `.sig`; sources provide the base registry for custom assets.
Later mod arguments take precedence on overlapping files. Add `--with-manifest`
for the GUI's registry-free distribution pak and sidecar workflow; see
[distribution composition](../tools/MOD_DISTRIBUTION.md) for combining sidecars.

Packing exports to the explicit path. It does not choose the game's installed
patch location or launch the game. Archive/parse/media verification does not
establish in-game compatibility; test custom assets after a full game restart.

## Batch recipes and localization

`workflow` uses the same request format as the GUI's Python workflow service.
The CLI supplies converter/runtime paths. `mod` and `source` resolve relative to
the current shell directory. For example, inspect a mod's properties:

```json
{"command": "inspect", "mod": "/mods/MyMod", "asset": "g3/Content/Example.uasset"}
```

The result's `value.recipe_text` is a JSON string, preserving integer precision.
Edit that recipe, then submit `{"command":"preview_recipe","mod":"/mods/MyMod",
"recipe_text":"..."}`. Apply with `command: "apply_recipe"`, the same recipe text,
and the returned `token`. Changed assets or recipes invalidate the token.

Localization requests use `scan` (returns `catalog`), `save_catalog` (accepts
`catalog`), and `localize` (accepts `source`, `catalog`, and `cultures`). See
[workflow formats and backups](mod-workflows.md). Keep catalogs and recipes outside
packed content. Workflow backups live in the mod's `.modkit/backups` folder.

## Agent contract and verification

`--json` emits exactly one JSON object on stdout:

```json
{"schema_version":1,"ok":true,"message":"...","value":{},"metadata":{},"backups":[],"logs":[]}
```

`schema_version`, `ok`, `message`, and `value` are always present. Backend operations
also include `metadata`, `backups`, and `logs`. Diagnostics and argument usage go to
stderr. Exit codes: **0** success, **1** operation failure, **2** invalid arguments.
Diff returns success when the comparison ran, even if differences exist.
`commands` exposes the command/option schema so agents do not need implementation
paths or function names. The request-file backend transport is internal; use the
public frontend for argument validation and the stable result envelope.

Run `GODOT=/path/to/godot scripts/test.sh`. For an exported build, run
`SPELLBREAK_CLI_APP=/path/to/sbue.x86_64 python3 tools/test_native_cli.py`; this
development test harness clears PATH and uses a fresh runtime cache. Set `SPELLBREAK_CLI_TEST_ASSET` to a
real non-texture asset whose first property has a `Value` field to include a
staged no-op patch roundtrip. Tests use temporary outputs and never overwrite
that source. Concurrent writers to the same destination are not supported;
close that asset's GUI tab before editing it through the CLI.
