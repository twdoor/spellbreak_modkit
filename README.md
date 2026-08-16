# Spellbreak Modkit

A visual `.uasset` editor and mod manager for **Spellbreak Community Edition**, built with Godot 4.

> The editor targets Spellbreak's UE 4.22 asset layout and uses a fixed Spellbreak profile for packing, texture tools, tags, enums, and constants.

---

## What's Included

The main project is `spellbreak_uasset_editor/`, a Godot 4 desktop app with a
built-in mod manager, a full `.uasset` editor, and Spellbreak-specific profile data.
Repository-level scripts run the regression suite locally.

Everything is bundled inside the single binary:
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) converter (pre-compiled .NET DLLs)
- [u4pak](https://github.com/panzi/u4pak) for packing mods into `.pak` files and extracting base-game sources
- [UE4-DDS-Tools](https://github.com/matyalatte/UE4-DDS-Tools) + [libtexconv](https://github.com/matyalatte/Texconv-Custom-DLL) for texture extraction/injection

---

## Requirements

- **Python 3.10+** — required at runtime for mod packing, base-pak source generation, and texture operations
  > **Windows:** when installing Python, check **"Add Python to PATH"** on the first installer screen — it is unchecked by default.
- **.NET Runtime** — required for UAssetAPI (asset parsing)
- **ImageMagick** — required for texture export/import (DDS/TGA to PNG conversion)
  > Most Linux distros include it. On Windows, install from [imagemagick.org](https://imagemagick.org/script/download.php) and add to PATH.

Optional:
- **[umodel](https://www.gildor.org/en/projects/umodel)** (UE Viewer) — required for 3D mesh and animation preview (StaticMesh / SkeletalMesh / AnimSequence assets). Download a prebuilt binary or [build from source](https://github.com/gildor2/UEViewer). Set the path in **Settings > umodel (3D Preview)**.
- **Godot 4.6+** — only if building the editor from source (no .NET support needed)

---

## Setup

### 1. Get the editor

#### Prebuilt editor (recommended)

Go to the [releases](https://github.com/twdoor/spellbreak_modkit/releases) page, click on the latest version and download the file for your platform.

Release artifacts are packaged as `linux.zip` and `win.zip`.

#### OR: Build from source

```bash
git clone https://github.com/twdoor/spellbreak_modkit
cd spellbreak_modkit
```

Open `spellbreak_uasset_editor/` in Godot 4.6+, then **Project > Export > Linux/Windows**. All dependencies (converter, u4pak, ue4_dds_tools) are bundled automatically.

### 2. Configure the editor

Launch the app, click **Settings**, and fill in:

- **Game directory** — the folder used to locate the game executable and pak files. For Spellbreak, this install folder should contain `g3/Content/Paks/`.
- **Mods directory** — the parent folder that contains your mod folders. Each direct child is treated as one mod and should mirror the game structure, for example `Mods/MyMod/g3/Content/...`.
- **Launch command** — optional, used by the Launch button
- **.uasset file association** — optional, registers the editor and its custom asset icon for `.uasset` files. Linux can set it as the default directly; Windows opens Default Apps for the final choice.
- **umodel path** — optional, path to the umodel binary for 3D mesh and animation preview
- **Sources** — extracted asset directories for reference. Use **Generate from Pak** to select a game `.pak`, choose an output folder, unpack it, and add the extracted folder as a source.

Settings are saved atomically to `settings.cfg` in the operating system's
per-user configuration directory (`~/.config/spellbreak-modkit` on Linux,
`%APPDATA%\spellbreak-modkit` on Windows, and
`~/Library/Application Support/spellbreak-modkit` on macOS). The Settings tab
can open the exact folder.

---

## GUI Editor

### Mod Manager tab

The Mod Manager tab is pinned and always visible. It shows all mod folders found in your configured mods directory as a collapsible tree.

| Action | Result |
|--------|--------|
| **Left-click a mod** | Expand / collapse it |
| **Right-click a mod** | Toggle enabled / disabled |
| **Double-click a `.uasset`** | Open it in the asset editor |
| **Double-click any other file** | Open with the configured editor or system default app |
| **Open button on text/config files** | Open `.txt`, `.cfg`, `.json`, `.ini`, `.md`, and similar files externally |

**Multi-select and clipboard:**

Select files with `Click`, `Ctrl+Click` (toggle), or `Shift+Click` (range).

| Shortcut | Action |
|----------|--------|
| `Ctrl+E` | Open the Base Files explorer |
| `Ctrl+C` | Copy selected files |
| `Ctrl+X` | Cut selected files |
| `Ctrl+V` | Paste into target mod (preserves `g3/Content/...` folder structure) |
| `Del / Ctrl+D` | Delete selected files or mods |

**Toolbar:**

| Button | Action |
|--------|--------|
| **New Mod** | Create a new mod folder |
| **Base Files** | Open the Base Files explorer |
| **Settings** | Open the Settings tab |
| **Pack** | Pack all enabled mods into a Spellbreak patch pak |
| **Watch** | Toggle auto-pack on file save |
| **Launch** | Launch the game |

### Sources

Sources are read-only reference folders used when importing files into a mod. They are expected to mirror the game's internal paths, for example:

```
SourceFolder/
└── g3/
    └── Content/
        └── ...
```

In **Settings > Sources**, **Generate from Pak** can build a source directly from a game package:

1. Select the base game `.pak`.
2. Select an output folder for extracted files.
3. The modkit unpacks the pak and adds the output folder to the configured sources.

When importing from sources in the Mod Manager, selecting a folder or file inside a mod opens the matching path inside the chosen source if it exists. If it does not exist, the file dialog falls back to the source root.

### Asset editor tabs

Open `.uasset` or `.json` files via `Ctrl+Space`, drag-and-drop, or double-click from the mod list.

**Keyboard shortcuts:**

| Shortcut | Action |
|----------|--------|
| `Ctrl+Space` | Open file |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Reuse the current binary asset under another asset name |
| `Ctrl+Q` | Close tab |
| `Ctrl+C / V / X` | Copy / Paste / Cut |
| `Del / Ctrl+D` | Delete selected item |
| `Ctrl+Z` | Undo |
| `Ctrl+A / F` | Previous / Next tab |

Use **Reuse As...** on an open binary asset to choose a new or existing
`.uasset` destination. The editor clones the complete package, regenerates its
required companion files, and replaces the old asset identity throughout the
NameMap, object names, generated-class names, and package paths. The source
asset remains unchanged.
| `Esc` | Clear selection / cancel edit |

**What you can edit:**

- **Export properties** — structs, arrays, scalars, enums, text, object references, SoftObject paths
- **Array items** — multi-select with Ctrl/Shift+click; copy/paste/delete supported
- **Import table** — all fields editable inline; multi-select supported
- **Name map** — add, edit, delete entries
- **DataTable rows** — view, edit, copy/paste/delete rows
- **StringTable exports** — namespace and all key/value entries

### Texture support

When opening a texture `.uasset` (Texture2D, TextureCube, etc.), the detail panel shows:

- **Inline preview** — the texture rendered at up to 512px wide with dimensions displayed
- **Export as PNG** — save the texture to a PNG file
- **Import PNG** — inject an edited PNG back into the `.uasset` (automatically handles BC1/BC3/BC5/BC7 format matching)

> Texture operations require Python and ImageMagick to be installed and in PATH.

### Audio support

When opening a SoundWave `.uasset`, the detail panel shows:

- **Inline playback** — play, pause, stop controls with a seek slider and time display
- **Export as OGG** — save the audio stream to an OGG Vorbis file
- **Import OGG** — inject a new OGG file back into the `.uasset` (updates companion `.uexp`/`.ubulk` binary data and FByteBulkData headers)

> Audio extraction and injection are implemented in pure GDScript — no external tools required.

### 3D Mesh support

When opening a StaticMesh or SkeletalMesh `.uasset`, the detail panel shows:

- **3D preview** — interactive viewport with orbit, middle-drag pan, scroll zoom, and a resizable preview area
- **Auto-framing** — camera automatically positions to fit the mesh on load
- **Animation preview** — on SkeletalMesh assets, auto-find likely AnimSequence `.uasset` files or browse manually, then play, pause, loop, change speed, or scrub on the current mesh
- **Export as glTF** — save the mesh to a glTF file

> Mesh and animation preview require [umodel](https://www.gildor.org/en/projects/umodel) to be installed and configured in Settings.

---

## Spellbreak Profile

The editor uses a fixed JSON-backed Spellbreak profile. It tells the toolchain to target UE 4.22, use `g3` as the content root, pack to `g3/Content/Paks`, and load Spellbreak enums, gameplay tags, and numeric constants.

### Numeric Constants

The Spellbreak profile includes named constants for use in Int/Float property fields. Type an expression like `sprint * 5` and it evaluates to the result. An autocomplete popup shows matching constants as you type.

---

## How the Pak System Works

UE4 loads `.pak` files alphabetically. Files with the `_P` suffix are treated as **patch paks** that override matching paths in the base pak.

This modkit creates `zzz_mods_P.pak` inside Spellbreak's `g3/Content/Paks/` folder.
- `zzz` prefix ensures it loads **last** (after all base paks)
- `_P` suffix marks it as a patch override
- A `.sig` file is copied from an existing game pak (UE4 requires a signature file)
- The base game is **never modified**

Your mod files must mirror Spellbreak's internal folder structure:

```
mods/
└── my_mod/
    └── g3/
        └── Content/
            └── Blueprints/
                └── GameModes/
                    ├── DA_BattleRoyale_Solo.uasset
                    └── DA_BattleRoyale_Solo.uexp
```

> Always copy `.uasset` and `.uexp` together — they are a pair. If a `.ubulk` file also exists, copy that too.

---

## Project Structure

```
spellbreak-modkit/
├── README.md
├── LICENSE
├── scripts/test.sh                 Parser check and regression test entry point
├── dist/                           Local exports (ignored, outside Godot project)
└── spellbreak_uasset_editor/       Godot 4 app
    ├── app/                         Application shell and global theme
    │   ├── main.gd / main.tscn     Entry point, tab bar, dialogs, status bar
    │   ├── app_theme.gd            Centralized UI theme constants & helpers
    │   └── main_theme.tres         Shared Godot Theme resource
    ├── core/                        UI-independent editor state and operations
    │   ├── operation_result.gd
    │   └── editor/                 Documents, commands, selection, clipboard, diff
    ├── services/                    Background, media, filesystem and platform work
    │   ├── background/             Worker lifecycle and background jobs
    │   ├── media/                  Texture, sound, mesh and animation services
    │   └── platform/               Processes, files, toolchains and associations
    ├── ui/                          Scene-authored interface and UI controllers
    │   ├── components/             Reusable controls and their scenes
    │   ├── controllers/            Tree and detail-panel coordination
    │   ├── details/                One renderer per asset detail type
    │   └── tabs/                   Asset, diff, explorer, diagnostics and keymap tabs
    ├── features/
    │   └── mod_manager/
    │       ├── models/             Mod metadata
    │       ├── services/           Discovery, packing, watching and configuration
    │       └── ui/                 Mod Manager and Settings scenes
    ├── converter/                  Bundled UAssetAPI DLLs (pre-compiled)
    ├── u4pak/                      Bundled u4pak (pak packing tool)
    ├── ue4_dds_tools/              Bundled UE4-DDS-Tools + libtexconv
    ├── game_profiles/              Spellbreak profile data
    │   └── spellbreak/             Profile, base enums, enums, tags, constants
    ├── uasset/                     Asset parsing & serialization
    │   ├── uasset_file.gd
    │   ├── uasset_export.gd
    │   ├── uasset_import.gd
    │   ├── uasset_property.gd
    │   └── spellbreak_profile.gd   Fixed Spellbreak profile loader
    ├── tests/test_core.gd          Core regression tests
    └── addons/                     App Settings and Version Manager plugins
```

## Development

Run the parser check and regression suite with Godot 4.7.1+:

```bash
./scripts/test.sh
```

The suite covers package-index remapping, undo restoration, transactional file
replacement, subprocess argument handling, and pak creation/failure recovery.

---

## Credits

- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) by atenfyr — UE4 asset serialization (bundled)
- [u4pak](https://github.com/panzi/u4pak) by panzi — UE4 pak archive tool (bundled)
- [UE4-DDS-Tools](https://github.com/matyalatte/UE4-DDS-Tools) by matyalatte — UE4 texture extraction/injection (bundled)
- [Texconv-Custom-DLL](https://github.com/matyalatte/Texconv-Custom-DLL) by matyalatte — Cross-platform texture format converter (bundled as libtexconv)
- [umodel / UE Viewer](https://www.gildor.org/en/projects/umodel) by Gildor — UE4 mesh viewer/exporter (optional, user-installed)
