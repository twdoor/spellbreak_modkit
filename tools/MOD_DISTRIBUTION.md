# Standalone mod distribution

`mod_distribution.py` provides a Python 3.10+ command-line workflow for a separate
launcher. It does not require Godot, editor settings, or development source paths.
In the editor, middle-click a mod and choose **Package + manifest** in the built-in
export browser. This produces `<name>.pak`, `<name>.sig`, and `<name>.manifest.json`;
pass that sidecar to `compose`. **Complete package** retains the standalone export
behavior with an embedded registry when needed. The CLI export below is an
alternative for automation.

## Export from a development workspace

Save the mod in the editor so its `spellbreak_mod_manifest.json` is current, then:

```sh
python tools/mod_distribution.py export /path/to/mod_workspace /path/to/releases/skins \
  --signature /path/to/game/g3/Content/Paks/existing.sig
```

The output directory must not already exist and must be outside the workspace.
It contains `skins_P.pak`, `skins_P.sig`, and `manifest.json`. Distribute all three
together. Export copies the workspace's `g3/Content` tree; it excludes the
workspace registry and does not modify the workspace. As in the editor, the sig
is copied from the supplied game signature; this helper does not create signatures.

The portable manifest contains a format version, display name, sibling pak filename,
pak SHA-256, and custom-asset declarations (`source`, `target`, `file`, and optional
`reference_group`). It omits local source paths and workspace file provenance.
Re-export after modifying content; do not pair a manifest with another build's pak.
Mods with no custom assets are supported with an empty `custom_assets` array.

## Compose before launching

Keep a clean, extracted vanilla `g3/AssetRegistry.bin` for the matching game build.
Pass exactly the manifests of enabled packs:

```sh
python tools/mod_distribution.py compose \
  --base-registry /path/to/vanilla/g3/AssetRegistry.bin \
  --signature /path/to/game/g3/Content/Paks/existing.sig \
  --output /path/to/game/g3/Content/Paks/zzzz_registry_P.pak \
  /path/to/releases/skins/manifest.json /path/to/releases/balance/manifest.json
```

For vanilla gameplay with skins, omit the balance manifest. With no manifests the
helper writes a vanilla registry override, removing registrations from the previous
selection. Each invocation rebuilds from the supplied base, never from the previous
output. Skin reference groups are isolated per pack so unrelated packs cannot
accidentally remap one another's bundles.

The launcher is responsible for installing/enabling the matching content paks and
signatures, disabling unselected content paks, and arranging for the shared registry
pak to override the vanilla registry. Do this while the game is stopped. Existing
packs containing their own registry must be re-exported for this workflow. The
helper does not install content packs, launch the game, or resolve conflicting
replacements of ordinary assets; that remains the launcher's pack-priority policy.

Only launch after exit code 0. Manifest/pak mismatches, missing declared files,
conflicting custom targets, invalid registry sources, and embedded registries in
content packs abort composition. Pak output is staged and replaced only after a
successful build. The signature and pak use separate file replacements, so callers
must not launch during publication. This workflow requires all custom declarations
to refer to donor records in the supplied vanilla registry, like the editor patcher.

## Copy into another project

Place these three files together in the launcher's helper directory:

- `tools/mod_distribution.py`
- `spellbreak_uasset_editor/asset_registry/patch_asset_registry.py`
- `spellbreak_uasset_editor/u4pak/u4pak.py`

Use the actual bundled registry patcher above, **not** the development wrapper at
`tools/patch_asset_registry.py`. Include `spellbreak_uasset_editor/u4pak/README.md`
with your distribution to preserve u4pak's BSD license notice. Invoke the helper
using an argument array rather than constructing a shell command from paths.
No pip dependencies are needed for export/compose.

## Validation

```sh
python tools/test_mod_distribution.py
python tools/test_patch_asset_registry.py
```

The integration test exports real paks using synthetic assets and a synthetic
registry, composes both packs, disables one, clears all, and checks rejected
rebuilds preserve the previous pak. An in-game smoke test with real content is still
needed before deploying this workflow to players.
