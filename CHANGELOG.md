# Changelog

## 0.12.0-beta.1 — Editor Preview (Pre-release) — 2026-08-12

- Replaced the editor's legacy update checker with the reusable Version Manager plugin, including semantic-version release selection and export-time repository metadata.
- Added one-click in-app updates for direct AppImage, Linux executable, and Windows executable release assets, with download progress, SHA-256 verification, staged replacement, backup, and restart.
- Simplified the editor around its fixed Spellbreak target: removed legacy settings/profile adapters, centralized bundled tool resolution, and moved local exports outside the Godot project.
- Added cross-filesystem-safe staged installs, typed operation/mod results, a shared background-service lifecycle, symlink-safe discovery, and lighter watcher fingerprints for large assets.
- Consolidated installed and save-as pak creation into one transactional packing pipeline.
- Replaced the bundled GUIDE input framework with native Godot `InputMap` actions and JSON-backed editable key bindings.
- Added a Reuse As workflow for cloning complete binary asset packages, automatically rewriting their internal asset identity and regenerating companion files.

## 0.11.0 - 2026-07-17

- Added a Diagnostics/Health tab and clearer operation feedback panels with expandable logs, retry/copy actions, close controls, and shorter auto-dismiss behavior.
- Improved copy/paste for imports, exports, properties, and cross-file references, including stronger package-index remapping and regression coverage for grouped exports.
- Added editable `FVector` / vector struct fields, including dictionary-backed vector values used by particle distributions.
- Added a Particle/VFX Inspector that presents Cascade-style particle exports as readable module stacks while keeping raw tree navigation available.
- Fixed helper completion popups so they no longer steal focus from text fields while typing.
- Improved keymap remapping reliability across default and user bindings.
- Improved texture injection, sound import/export, mesh export, and GLB preview workflows with safer companion handling and clearer failures.
- Added smooth scrolling to the main detail/settings/diff scroll panels.
- Fixed file dialogs and external file opening so the app remains usable while checking paths or hovering items.
- Hardened watcher auto-pack on save, including same-size asset saves and main-thread pack startup.

## 0.10.0 - 2026-06-30

- Added a Compare File workflow with a default Ctrl+K shortcut, secondary keybind support.
- Added fixed-width editor tabs with hover scrolling for long names, improved tab close icons. gw
- Made `FLinearColor` / color struct values editable with an inline color picker and fixed saving dictionary-backed color values.
- Improved texture export/import reliability on Linux, including better DDS tool handling, companion recovery, and clearer failure messages for unsupported conversions.
- Reworked mesh export around Blender-friendly `.glb` output, embedded reconstructed material textures into exported GLBs, and refreshed mesh preview lighting with a default sky/environment setup.
- Added middle-click mod export to a user-chosen `.pak` path with matching `.sig` output, plus New Mod creation from existing `.pak` files.
- Hardened the Watch workflow against rapid toggle spam and improved file watcher shutdown behavior.
- Added a GitHub release update checker and a helper script for maintaining the stable local Linux `builds/latest` launcher.
- Fixed popup/dialog theme opacity issues and expanded regression coverage for compare, color editing, GLB texture export, packing, file watching, startup opening, and update checks.

## 0.9.0 - 2026-06-29

- Added a Settings keymap manager with editable primary and secondary shortcuts.
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
