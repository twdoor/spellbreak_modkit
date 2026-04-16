# Spellbreak Modkit

A visual asset editor and mod manager for **Spellbreak Community Edition**, built with Godot 4.

> Spellbreak runs on Unreal Engine 4.22. All tools target that version.

---

## What's Included

This repo contains one thing: `spellbreak_uasset_editor/` — a Godot 4 desktop app with a built-in mod manager and a full `.uasset` editor.

Everything is bundled inside the single binary:
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) converter (pre-compiled .NET DLLs)
- [u4pak](https://github.com/panzi/u4pak) for packing mods into `.pak` files
- [UE4-DDS-Tools](https://github.com/matyalatte/UE4-DDS-Tools) + [libtexconv](https://github.com/matyalatte/Texconv-Custom-DLL) for texture extraction/injection

---

## Requirements

- **Python 3.10+** — required at runtime for mod packing and texture operations
  > **Windows:** when installing Python, check **"Add Python to PATH"** on the first installer screen — it is unchecked by default.
- **.NET Runtime** — required for UAssetAPI (asset parsing)
- **ImageMagick** — required for texture export/import (DDS/TGA to PNG conversion)
  > Most Linux distros include it. On Windows, install from [imagemagick.org](https://imagemagick.org/script/download.php) and add to PATH.

Optional:
- **[umodel](https://www.gildor.org/en/projects/umodel)** (UE Viewer) — required for 3D mesh preview (StaticMesh / SkeletalMesh assets). Download a prebuilt binary or [build from source](https://github.com/gildor2/UEViewer). Set the path in **Settings > umodel (3D Preview)**.
- **Godot 4.6+** — only if building the editor from source (no .NET support needed)

---

## Setup

### 1. Get the editor

#### Prebuilt editor (recommended)

Go to the [releases](https://github.com/twdoor/spellbreak_modkit/releases) page, click on the latest version and download the file for your platform.

#### OR: Build from source

```bash
git clone https://github.com/twdoor/spellbreak_modkit
cd spellbreak_modkit
```

Open `spellbreak_uasset_editor/` in Godot 4.6+, then **Project > Export > Linux/Windows**. All dependencies (converter, u4pak, ue4_dds_tools) are bundled automatically.

### 2. Configure the editor

Launch the app, click **Settings**, and fill in:

- **Game directory** — the folder containing `g3/` and `Spellbreak.exe`
- **Mods directory** — where your mod folders live
- **Launch command** — optional, used by the Launch button
- **umodel path** — optional, path to the umodel binary for 3D mesh preview
- **Sources** — exported asset directories for reference (base game export, older versions, etc.)

Settings are saved to `config.json` next to the executable.

---

## GUI Editor

### Mod Manager tab

The Mod Manager tab is pinned and always visible. It shows all mod folders found in your configured mods directory as a collapsible tree.

| Action | Result |
|--------|--------|
| **Left-click a mod** | Expand / collapse it |
| **Right-click a mod** | Toggle enabled / disabled |
| **Double-click a `.uasset`** | Open it in the asset editor |
| **Double-click any other file** | Open with system default app |

**Multi-select and clipboard:**

Select files with `Click`, `Ctrl+Click` (toggle), or `Shift+Click` (range).

| Shortcut | Action |
|----------|--------|
| `Ctrl+E` | Import files from sources |
| `Ctrl+C` | Copy selected files |
| `Ctrl+X` | Cut selected files |
| `Ctrl+V` | Paste into target mod (preserves `g3/Content/...` folder structure) |
| `Del / Ctrl+D` | Delete selected files or mods |

**Toolbar:**

| Button | Action |
|--------|--------|
| **New Mod** | Create a new mod folder |
| **Settings** | Open the Settings tab |
| **Pack** | Pack all enabled mods into `zzz_mods_P.pak` |
| **Watch** | Toggle auto-pack on file save |
| **Launch** | Launch Spellbreak |

### Asset editor tabs

Open `.uasset` or `.json` files via `Ctrl+Space`, drag-and-drop, or double-click from the mod list.

**Keyboard shortcuts:**

| Shortcut | Action |
|----------|--------|
| `Ctrl+Space` | Open file |
| `Ctrl+S` | Save |
| `Ctrl+Q` | Close tab |
| `Ctrl+C / V / X` | Copy / Paste / Cut |
| `Del / Ctrl+D` | Delete selected item |
| `Ctrl+Z` | Undo |
| `Ctrl+A / F` | Previous / Next tab |
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

- **3D preview** — interactive viewport with orbit controls (left-drag to rotate, scroll to zoom)
- **Auto-framing** — camera automatically positions to fit the mesh on load
- **Export as glTF** — save the mesh to a glTF file

> Mesh preview requires [umodel](https://www.gildor.org/en/projects/umodel) to be installed and configured in Settings.

---

## How the Pak System Works

UE4 loads `.pak` files alphabetically. Files with the `_P` suffix are treated as **patch paks** that override matching paths in the base pak.

This modkit creates `zzz_mods_P.pak` inside the game's `Paks/` folder:
- `zzz` prefix ensures it loads **last** (after all base paks)
- `_P` suffix marks it as a patch override
- A `.sig` file is copied from an existing game pak (UE4 requires a signature file)
- The base game is **never modified**

Your mod files must mirror the game's internal folder structure:

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
└── spellbreak_uasset_editor/       Godot 4 app
    ├── main.gd / main.tscn         Entry point, tab bar, status bar
    ├── property_row.gd             Inline property editor widget
    ├── converter/                  Bundled UAssetAPI DLLs (pre-compiled)
    ├── u4pak/                      Bundled u4pak (pak packing tool)
    ├── ue4_dds_tools/              Bundled UE4-DDS-Tools + libtexconv
    ├── uasset/                     Asset parsing & serialization
    │   ├── uasset_file.gd
    │   ├── uasset_export.gd
    │   ├── uasset_import.gd
    │   ├── uasset_property.gd
    │   ├── ue4_enums.gd
    │   └── spellbreak_tags.gd
    ├── scenes/
    │   ├── uasset_tab.gd/tscn      Per-file editor tab
    │   ├── detail_panel_builder.gd
    │   ├── tree_manager.gd
    │   ├── selection_manager.gd
    │   ├── clipboard_manager.gd
    │   ├── undo_manager.gd
    │   ├── export_reorderer.gd
    │   ├── texture_service.gd      Texture extraction/injection service
    │   ├── sound_service.gd        Audio extraction/injection service
    │   ├── mesh_service.gd         3D mesh export via umodel
    │   ├── detail_items/           One class per detail-panel view
    │   │   ├── detail_item.gd
    │   │   ├── property_detail.gd
    │   │   ├── export_detail.gd
    │   │   ├── texture_detail.gd   Texture preview & import/export
    │   │   ├── sound_detail.gd     Audio playback & import/export
    │   │   ├── mesh_detail.gd      3D mesh preview & export
    │   │   ├── exports_list_detail.gd
    │   │   ├── import_detail.gd
    │   │   ├── namemap_detail.gd
    │   │   ├── datatable_row_detail.gd
    │   │   └── stringtable_detail.gd
    │   └── mod_manager/
    │       ├── mod_manager_panel.gd
    │       ├── mod_settings_tab.gd
    │       ├── config_manager.gd
    │       ├── mod_state_manager.gd
    │       ├── mod_discovery.gd
    │       ├── file_watcher.gd
    │       ├── file_utils.gd
    │       └── packing_service.gd
    ├── guide/                      GUIDE action resources (remappable keybinds)
    └── addons/                     GUIDE input framework
```

---

## Credits

- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) by atenfyr — UE4 asset serialization (bundled)
- [u4pak](https://github.com/panzi/u4pak) by panzi — UE4 pak archive tool (bundled)
- [UE4-DDS-Tools](https://github.com/matyalatte/UE4-DDS-Tools) by matyalatte — UE4 texture extraction/injection (bundled)
- [Texconv-Custom-DLL](https://github.com/matyalatte/Texconv-Custom-DLL) by matyalatte — Cross-platform texture format converter (bundled as libtexconv)
- [umodel / UE Viewer](https://www.gildor.org/en/projects/umodel) by Gildor — UE4 mesh viewer/exporter (optional, user-installed)
