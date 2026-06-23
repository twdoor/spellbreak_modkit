# Changelog

## 0.8.0 - 2026-06-23

- Reworked the editor internals around typed asset documents, reversible edit commands, shared detail-panel helpers, and background jobs.
- Added a stronger Mod Manager workflow with multi-select file operations, source imports, safer packing, file watching, and cross-platform subprocess handling.
- Improved texture and audio tooling, including companion `.uexp` / `.ubulk` preservation, missing companion recovery, PNG texture injection fixes, and in-editor SoundWave playback/import/export.
- Added textured 3D mesh preview, resizable preview area, orbit/pan/zoom controls, glTF export, and SkeletalMesh animation preview with auto-discovery, browsing, playback, looping, speed, and scrubbing.
- Fixed flattened MD5 animation handling for both local-pose and delta-pose exports, including stale skeleton-pose resets between animations.
- Expanded regression coverage and CI checks for parser startup, file transactions, subprocess calls, packing behavior, preview controls, texture companion handling, and animation conversion.
