# TODO

Future improvement backlog after the UI consistency pass.

1. Diagnostics panel
   Status: done. Added a Health / Tools view that checks required executables, writable folders, game paths, temp directory access, and version assumptions.

2. Operation log and retry
   Status: done. Added shared copyable operation feedback and retry controls for texture, audio, mesh, source generation, and manual packing/export operations. Watch-mode pack logs are copyable but intentionally do not expose retry.
   Show copyable per-step logs for texture, mesh, sound, source generation, and packing operations, with a retry action when possible.

3. Stronger backup and rollback flow
   Status: done. Destructive texture/audio injection and pak install/export operations now keep persistent sibling restore backups and include their paths in the operation result log. The staged installer still rolls back automatically on failure.
   Snapshot files before destructive writes and expose a clear restore path for replaced assets and generated paks.

4. Mod project manifest
   Status: done. Each mod now gets a root-level spellbreak_mod_manifest.json with profile/build settings, configured source snapshots, target files, file metadata, and source provenance when files are copied from a configured source. Manifests refresh before manual pack/export.
   Save a mod workspace manifest with metadata, source files, target paths, and build settings so mods can be rebuilt reproducibly.

5. Validation before save or build
   Status: done. Manual pack/export now runs preflight checks for missing content roots, orphan package companions, unsafe paths, case collisions, backup-looking files, and unusual loose formats. Asset save now rejects invalid package indices before converter/write.
   Add preflight checks for missing companion files, path casing, unsupported formats, stale generated files, and invalid package references.

6. More destructive-workflow regression tests
   Status: done. Added regression coverage for retained restore backups, backup restoration, manifest generation, build preflight, save validation, and repeated pak replacement backup reporting, alongside existing failed-pack rollback coverage.
   Expand coverage for packing, injection replacement, temp cleanup, path handling, failed subprocess rollback, and backup recovery.
