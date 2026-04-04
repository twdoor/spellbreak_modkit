# Spellbreak Modkit

A toolkit for modding **Spellbreak Community Edition**. Includes a terminal mod manager, a visual asset editor, and CLI tools for converting and packing UE4 assets.

> Spellbreak runs on Unreal Engine 4.22. All tools target that version.

---

## What's Included

| Tool | What it does |
|------|-------------|
| `mod_manager.py` | Terminal UI — toggle mods, pack, watch for changes, launch game |
| `spellbreak_uasset_editor/` | Godot 4 GUI editor for `.uasset` files (open, inspect, edit, save) |
| `uasset_tool.py` | CLI to convert `.uasset` ↔ JSON and bulk export/build mod folders |
| `pack_mod.sh` | Shell script to pack a mods folder into a `_P.pak` patch file |
| `unpack_base.sh` | Shell script to extract the base game pak for reference |
| `watch.py` | File watcher — auto-repacks when you save a `.uasset` |
| `uasset_converter/` | .NET 8 CLI wrapper around [UAssetAPI](https://github.com/atenfyr/UAssetAPI) |
| `u4pak/` | Python tool for reading/writing UE4 `.pak` archives |

---

## Requirements

- **Python 3.10+**
- **dotnet SDK 8.0** — required for asset conversion
  ```
  sudo apt install dotnet-sdk-8.0
  ```
- **Spellbreak Community Edition** installed locally

Optional (only if building the GUI editor from source):
- **Godot 4.4+** with .NET support disabled (standard build)

---

## Windows

Everything works on Windows with a few small differences.

### Prerequisites

- **Python 3.10+** — download from [python.org](https://www.python.org/downloads/). During install, check **"Add Python to PATH"**.
- **dotnet SDK 8.0** — install via winget or download from Microsoft:
  ```
  winget install Microsoft.DotNet.SDK.8
  ```
- **windows-curses** — required for the terminal UI tools (`mod_manager.py`, `uasset_editor.py`):
  ```
  pip install windows-curses
  ```

### What's different

**Use `python` instead of `python3`:**
```
python mod_manager.py
python uasset_tool.py --setup
```

**The `.sh` scripts don't work on Windows.** Use the Python tools instead — they cover everything the shell scripts do:
- Pack mods → `P` key in `mod_manager.py`, or `python watch.py`
- Unpack the base game pak → `python uasset_tool.py export <folder>` or use the GUI editor to open `.uasset` files directly

If you need the shell scripts (e.g. for CI), run them inside WSL or Git Bash.

**The GUI editor is the recommended way to edit assets on Windows.** Download the pre-built `.exe` from the releases page. It bundles the dotnet converter — no separate install needed.

**Game path** will be something like `C:\Program Files (x86)\Steam\steamapps\common\Spellbreak`. Enter this when `mod_manager.py` asks for the game directory during setup.

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/yourname/spellbreak-modkit
cd spellbreak-modkit
```

### 2. Build the asset converter

```bash
python3 uasset_tool.py --setup
```

This compiles the .NET converter inside `uasset_converter/` using `dotnet publish`. Takes ~30 seconds on first run.

### 3. Configure paths

```bash
python3 mod_manager.py
```

On first launch, the setup wizard asks for:
- **Game directory** — the folder containing `g3/Content/Paks/` (e.g. `/home/user/games/Spellbreak`)
- **Mods directory** — where your loose mod files live (e.g. `/home/user/spellbreak-mods`)
- **Launch command** — optional, used by the mod manager's launch shortcut

Settings are saved to `config.json` (not tracked by git).

---

## Workflow

### Option A — Terminal UI (recommended)

```bash
python3 mod_manager.py
```

Keys inside the TUI:

| Key | Action |
|-----|--------|
| `↑ ↓` | Navigate mod list |
| `Space` | Toggle mod on/off |
| `P` | Pack enabled mods into the patch pak |
| `W` | Start file watcher (auto-pack on save) |
| `L` | Launch game |
| `Q` | Quit |

### Option B — Direct scripts

```bash
# Pack your mods manually
./pack_mod.sh

# Start the file watcher
python3 watch.py

# Extract base game files for reference
./unpack_base.sh --search BattleRoyale   # search by name
./unpack_base.sh --list                  # list all files
./unpack_base.sh                         # extract everything
```

---

## GUI Asset Editor

`spellbreak_uasset_editor/` is a standalone Godot 4 desktop app for visually editing `.uasset` files. Pre-built binaries are in `spellbreak_uasset_editor/builds/`.

**Opening a file:** `Ctrl+Space` or drag-and-drop a `.uasset` onto the window.

**Keyboard shortcuts:**

| Shortcut | Action |
|----------|--------|
| `Ctrl+Space` | Open file |
| `Ctrl+S` | Save |
| `Ctrl+Q` | Close tab |
| `Ctrl+C / V / X` | Copy / Paste / Cut |
| `Del` | Delete selected item |
| `Ctrl+Z` | Undo |
| `Ctrl+A / F` | Previous / Next tab |
| `Click` | Select item |
| `Ctrl+Click` | Multi-select |
| `Shift+Click` | Range select |
| `Esc` | Clear selection |

**What you can edit:**
- Export properties (structs, arrays, scalars, object references)
- Import table entries
- Name map entries
- DataTable rows (view, edit, copy/paste/delete rows)

### Building from source

Open `spellbreak_uasset_editor/` in Godot 4.4+, then **Project → Export → Linux/Windows**.

The app bundles the .NET converter automatically — no separate install needed for end users.

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
└── g3/
    └── Content/
        └── Blueprints/
            └── GameModes/
                ├── DA_BattleRoyale_Solo.uasset
                └── DA_BattleRoyale_Solo.uexp
```

> Always copy `.uasset` and `.uexp` together — they are a pair. If a `.ubulk` file also exists, copy that too.

---

## CLI Asset Tools

```bash
# Convert a single file to JSON (for manual editing)
python3 uasset_tool.py tojson  <file.uasset>

# Convert JSON back to binary
python3 uasset_tool.py fromjson <file.json>

# Export all uassets in a mod folder to JSON
python3 uasset_tool.py export <mod_folder>

# Convert all JSON files in a mod folder back to uassets
python3 uasset_tool.py build <mod_folder>
```

---

## Project Structure

```
spellbreak-modkit/
├── mod_manager.py          Terminal UI for mod management
├── uasset_tool.py          CLI converter (uasset ↔ json)
├── uasset_editor.py        Additional asset editing utilities
├── watch.py                File watcher for auto-packing
├── pack_mod.sh             Shell packer script
├── unpack_base.sh          Shell unpacker script
├── setup.sh                Interactive first-time setup
├── config.json             User paths (gitignored, generated by setup)
├── u4pak/                  UE4 pak library (Python)
├── uasset_converter/       .NET converter (UAssetAPI wrapper)
│   ├── Program.cs
│   ├── UAssetConverter.csproj
│   ├── publish/            Compiled binaries (output of --setup)
│   └── UAssetAPI/          UAssetAPI submodule (C#)
└── spellbreak_uasset_editor/ Godot 4 GUI editor
    ├── uasset/             Asset parsing & serialization
    ├── scenes/             UI components
    ├── addons/             Third-party Godot addons
    └── converter/          Bundled converter DLLs (for export)
```

---

## Credits

- [UAssetAPI](https://github.com/atenfyr/UAssetAPI) by atenfyr — UE4 asset serialization library
- [u4pak](https://github.com/panzi/u4pak) — UE4 pak archive tool
