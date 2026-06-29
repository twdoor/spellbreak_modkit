# Changelog

## 0.9.0 - 2026-06-29

- Added a Settings keymap manager backed by GUIDE mappings, including editable primary and secondary shortcuts.
- Reworked shortcut handling so editor keybinds respond reliably, renamed tab navigation to Previous Tab and Next Tab, and hid Shift as a standalone bind.
- Added source generation from game `.pak` files, including an improved u4pak reader for Spellbreak padded version 8 pak footers.
- Improved Mod Manager source imports with a better source picker, selected-folder matching, fixed Select/Browse behavior, and external opening for text/config files.
- Fixed texture injection persistence so injected textures are not overwritten by later clean saves.
- Refreshed settings descriptions, Save/Revert/Close behavior, and the keymap entry point.
- Removed unused addons and generic game-profile flows, keeping the tool focused on the Spellbreak profile.
- Fixed GDScript reload warnings and expanded regression coverage for shortcuts, source extraction, settings, packing, and file opening.

## 0.8.0 - 2026-06-23

- Reworked the editor internals around typed asset documents, reversible edit commands, shared detail-panel helpers, and background jobs.
- Added a stronger Mod Manager workflow with multi-select file operations, source imports, safer packing, file watching, and cross-platform subprocess handling.
- Improved texture and audio tooling, including companion `.uexp` / `.ubulk` preservation, missing companion recovery, PNG texture injection fixes, and in-editor SoundWave playback/import/export.
- Added textured 3D mesh preview, resizable preview area, orbit/pan/zoom controls, glTF export, and SkeletalMesh animation preview with auto-discovery, browsing, playback, looping, speed, and scrubbing.
- Fixed flattened MD5 animation handling for both local-pose and delta-pose exports, including stale skeleton-pose resets between animations.
- Expanded regression coverage and CI checks for parser startup, file transactions, subprocess calls, packing behavior, preview controls, texture companion handling, and animation conversion.
