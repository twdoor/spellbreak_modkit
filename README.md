# Spellbreak Modkit

A visual asset editor and mod manager for **Spellbreak Community Edition**, built with Godot 4.

> Spellbreak runs on Unreal Engine 4.22. All tools target that version.

---

## What's Included

This repo contains one thing: `spellbreak_uasset_editor/` — a Godot 4 desktop app with a built-in mod manager and a full `.uasset` editor.

The [UAssetAPI](https://github.com/atenfyr/UAssetAPI) converter is pre-compiled and bundled inside `spellbreak_uasset_editor/converter/`. No separate build step is needed.

---

## Requirements

- **Python 3.10+** — required at runtime by [u4pak](https://github.com/panzi/u4pak) for packing mods
  > **Windows:** when installing Python, check **"Add Python to PATH"** on the first installer screen — it is unchecked by default. Without this the packer will fail to find Python.
- **u4pak** — not bundled; download from:
  [https://github.com/panzi/u4pak](https://github.com/panzi/u4pak)

  Clone or place the `u4pak/` folder next to this README for auto-detection, or set the path manually in **Settings → u4pak Directory**.

Optional (only if building the editor from source):
- **Godot 4.6+** — standard build (no .NET support needed)

---

## Setup

### 1. Get the editor

#### 1a Prebuild editor (recommended)

Go to [releases](https://github.com/twdoor/spellbreak_modkit/releases) page on github, click on the lastest version and pick the file you need.

### OR:

#### 1b Clone the repo

```bash
git clone https://github.com/yourname/spellbreak-modkit
cd spellbreak-modkit
```

### 2. Get u4pak

```bash
git clone https://github.com/panzi/u4pak
```

Place the cloned `u4pak/` folder next to this README so the editor can auto-detect it, or point to it manually in **Settings → u4pak Directory**.

### 3. Configure the editor

Launch the app (or run from Godot), click **Settings**, and fill in:

- **Game directory** — the folder containing `g3` and `Spellbreak.exe`
- **Mods directory** — where your mod folders live
- **Launch command** — optional, used by the Launch button
- **u4pak Directory** — if u4pak is not next to the project
- **Sources** — exported asset directories for reference (base game export, older versions, reference mods)

Settings are saved to `config.json` next to the executable (not tracked by git).

---

## GUI Editor

### Mod Manager tab

The Mod Manager tab is pinned and cannot be closed. It shows all mod folders found in your configured mods directory as a collapsible tree.

**Mod list tree:**

Each mod appears as a top-level row, collapsed by default. Folders inside the mod are nested below it.

| Action | Result |
|--------|--------|
| **Left-click a mod** | Expand / collapse it |
| **Right-click a mod** | Toggle the mod enabled / disabled |
| **Double-click a file** | Open it in the asset editor |


**Multi-select and clipboard:**

Select files with `Click`, `Ctrl+Click` (toggle), or `Shift+Click` (range). The standard shortcuts then operate on the whole selection:

| Shortcut | Action |
|----------|--------|
| `Ctrl+E` | Imports files from sources|
| `Ctrl+C` | Copy selected files |
| `Ctrl+X` | Cut selected files |
| `Ctrl+V` | Paste into target mod (folder structure is preserved — files land at the same `g3/Content/…` path in the destination mod) |
| `Del / Ctrl+D` | Delete selected files |

**Toolbar:**

| Button | Action |
|--------|--------|
| **New Mod** | Create a new mod folder (prompts for a name, creates `mods/<name>/g3/Content/` automatically) |
| **Settings** | Open the Settings tab |
| **Pack** | Pack all enabled mods into `zzz_mods_P.pak` |
| **Watch** | Toggle auto-pack on file save |
| **Launch** | Launch Spellbreak |

A status bar at the bottom of the window shows the current watcher/pack state on all tabs.

### Asset editor tabs

Open `.uasset` or `.json` files via `Ctrl+Space`, drag-and-drop or open a file from the mod list.

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
| `Click` | Select item |
| `Ctrl+Click` | Add/remove from selection |
| `Shift+Click` | Range select |
| `Esc` | Clear selection |

**What you can edit:**

- **Export properties** — structs, arrays, scalars, enums, text, object references
- **Array items** — click to select, Ctrl+click / Shift+click for multi-select; Ctrl+C / Ctrl+V / Del work identically to the import list
- **Import table** — all fields editable inline; multi-select copy/paste/delete supported
- **Name map** — add, edit, delete entries
- **DataTable rows** — view, edit, copy/paste/delete rows
- **StringTable exports** — namespace and all key/value entries displayed and editable; add/remove entries

### Building from source

Open `spellbreak_uasset_editor/` in Godot 4.6+, then **Project → Export → Linux/Windows**. The converter DLLs in `converter/` are bundled automatically.

---

## How the Pak System Works

UE4 loads `.pak` files alphabetically. Files with the `_P` suffix are treated as **patch paks** that override matching paths in the base pak.

This modkit creates `zzz_mods_P.pak` inside the game's `Paks/` folder:
- `zzz` prefix ensures it loads **last** (after all base paks)
- `_P` suffix marks it as a patch override
- A `.sig` file is copied from an existing game pak (UE4 requires a signature file alongside each pak)
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
    ├── single_instance.gd          Single-window / multi-tab instance manager
    ├── converter/                  Bundled UAssetAPI DLLs (pre-compiled)
    ├── uasset/                     Asset parsing & serialization
    │   ├── uasset_file.gd
    │   ├── uasset_export.gd
    │   ├── uasset_import.gd
    │   ├── uasset_property.gd
    │   └── ue4_enums.gd
    ├── scenes/
    │   ├── uasset_tab.gd/tscn      Per-file editor tab
    │   ├── detail_panel_builder.gd
    │   ├── tree_manager.gd
    │   ├── selection_manager.gd
    │   ├── clipboard_manager.gd
    │   ├── undo_manager.gd
    │   ├── export_reorderer.gd
    │   ├── import_tab.gd
    │   ├── detail_items/           One class per detail-panel view
    │   │   ├── detail_item.gd
    │   │   ├── property_detail.gd
    │   │   ├── export_detail.gd
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
    │       └── packing_service.gd
    ├── guide/                      GUIDE action resources (remappable keybinds)
    └── addons/                     GUIDE input framework
```

---

## Credits

- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) by atenfyr — UE4 asset serialization (bundled as compiled DLLs)
- [u4pak](https://github.com/panzi/u4pak) by panzi — UE4 pak archive tool
