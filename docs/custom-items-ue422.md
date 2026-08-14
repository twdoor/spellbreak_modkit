# Custom Spellbreak Items on UE 4.22

## Status

On 2026-08-14 we successfully loaded and spawned a genuinely new cooked item
package in Spellbreak Community Edition:

```text
/Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.BP_Item_Boots_Tier_6_C
```

This proves that Spellbreak is not limited to replacing existing `.uasset`
files. New cooked packages work when the package files and a matching startup
Asset Registry are installed together.

The successful test item was based on the stock Tier 5 boots and renamed to
Tier 6. It also changed its display text, rarity, movement values, and related
Blueprint export names.

## Confirmed requirements

A new non-texture item needs all of the following:

1. A UE4.22-compatible cooked `.uasset`.
2. Its sidecar `.uexp` and any other required sidecars, such as `.ubulk`.
3. An entry for the new package in `g3/AssetRegistry.bin`.
4. A PAK mounted during engine startup, not mounted later by a DLL.
5. The correct internal package layout and mount point.
6. A valid sibling `.sig` file.
7. A complete game restart after installation.

The working PAK layout is:

```text
g3/AssetRegistry.bin
g3/Content/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.uasset
g3/Content/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.uexp
```

It was packed with:

```text
PAK archive version: 3
Mount point: ../../../
```

The successful installed filename was:

```text
g3/Content/Paks/zzzz_new_items_registry_P.pak
g3/Content/Paks/zzzz_new_items_registry_P.sig
```

The late-sorting `zzzz_` name ensures that this PAK's `AssetRegistry.bin`
overrides the original registry during startup.

## Why the earlier attempts failed

### Runtime PAK mounting was too late

Asset Buddy successfully mounted the PAK from `Mods/contents`, but by then the
engine had already loaded its startup Asset Registry. Mounting a replacement
`AssetRegistry.bin` afterward does not retroactively replace that state.

The decisive fix was installing the PAK directly in `g3/Content/Paks` so the
engine mounted it before loading the registry.

### Runtime Asset Registry scans were insufficient

The following UE calls were tested after mounting:

- `ScanPathsSynchronous`
- `ScanFilesSynchronous`
- primary-asset scanning through `UAssetManager`

They did not make the absent Blueprint package loadable. They could find or
register data already represented in the loaded registry, but did not solve the
missing startup record for this new cooked Blueprint.

### Primary-asset registration did not load the class

Asset Buddy reported registered primary assets, but `SpawnBoot` still failed
with `Failed to find class`. Primary-asset registration and package/class
loading are separate steps. Registering an asset ID does not make an unopened
package magically available.

### The direct-load diagnostic was inconclusive

The reflected `UKismetSystemLibrary::LoadAsset_Blocking` diagnostic returned
null even for the known-good stock Tier 5 item. It therefore could not reliably
distinguish a bad custom package from a problem in the diagnostic invocation.

### A missing `.sig` crashes at startup

Putting a PAK in the startup PAK directory without a corresponding `.sig`
produced a fatal error similar to:

```text
Couldn't find pak signature file ...new_items_mod_P.sig
```

Always install the PAK and SIG as a pair.

## Asset Registry format

Spellbreak's extracted registry is:

```text
Modding/base/g3/AssetRegistry.bin
```

Observed properties:

```text
Asset Registry GUID: e79e7f713a49b0e93291b3880781381b
Asset Registry version: 6 (AddedCookedMD5Hash)
Original asset count: 49,327
Original name count: 126,746
```

Version 6 uses the legacy shared FName table. The relevant high-level layout is:

```text
Header
  GUID[16]
  Version int32
  NameTableOffset int64
AssetData array
Dependency data
Package data
Shared FName table
```

Each old-format asset record contains:

```text
OldObjectPath FName
PackagePath FName
AssetClass FName
PackageName FName
AssetName FName
TagsAndValues
ChunkIDs
PackageFlags
```

An important UE detail is that names ending in `_N` are normally represented
as an FName base plus an internal number of `N + 1`. For example, Tier 5 was
stored as base `BP_Item_Boots_Tier` with FName number `6`. The initial patcher
prototype missed this; changing that number to `7` correctly produced Tier 6.

Serialized FName entries also carry two 16-bit hashes. The patcher reproduces
UE4's legacy case-insensitive hash and case-preserving CRC. Its implementation
was checked against 1,000 stock entries with zero mismatches.

## Registry patching tool

The development entry point is:

```text
spellbreak_modkit/tools/patch_asset_registry.py
```

The editor bundles the implementation from
`spellbreak_uasset_editor/asset_registry/patch_asset_registry.py`. It
deliberately supports only the confirmed Spellbreak format. Before writing
anything it:

- validates the registry GUID and version;
- parses the complete shared name table;
- parses every existing asset record and validates its FName references;
- requires every source asset to exist and every target to be new and unique;
- clones each source record and rewrites its package/object identity;
- updates FName suffix numbers and tag strings;
- generates any new serialized names and hashes;
- updates the asset count and name-table offset;
- reparses the complete output and confirms every target record exists.

Example:

```bash
python3 tools/patch_asset_registry.py \
  /path/to/Modding/base/g3/AssetRegistry.bin \
  /path/to/MyMod/g3/AssetRegistry.bin \
  --old '/Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_5.BP_Item_Boots_Tier_5' \
  --new '/Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.BP_Item_Boots_Tier_6'
```

The tool can clone several existing records into one registry build, supports
different-length package names, and rejects duplicate targets. It does not yet
extract arbitrary metadata directly from a new package.

## Packing and installation

From the root of a staged mod containing `g3/`:

```bash
python3 /path/to/spellbreak_modkit/spellbreak_uasset_editor/u4pak/u4pak.py \
  pack -z --archive-version=3 --mount-point=../../../ \
  /path/to/zzzz_new_items_registry_P.pak g3/
```

Verify the result:

```bash
python3 /path/to/u4pak.py test --force-version=3 \
  /path/to/zzzz_new_items_registry_P.pak

python3 /path/to/u4pak.py list --force-version=3 \
  /path/to/zzzz_new_items_registry_P.pak
```

Copy the PAK to the game's `g3/Content/Paks` directory and copy a known-good
Spellbreak `.sig` beside it using the exact same basename. Restart the game
fully; returning to the lobby is not sufficient.

Test the class directly:

```text
summon /Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.BP_Item_Boots_Tier_6_C
```

Then test the Spellbreak item path:

```text
SpawnBoot Loot:BP_Item_Boots_Tier_6 1
```

## Current development artifacts

On the development machine used for the successful test:

```text
Source registry:
/home/twdoor/Projects/spellbreak/Modding/base/g3/AssetRegistry.bin

Tier 6 source files:
/home/twdoor/Projects/spellbreak/Modding/Mods/new_items_mod/g3/Content/Blueprints/Items/v3/Wearables/Boots/

Staged patched registry:
/home/twdoor/Projects/spellbreak/Modding/Mods/new_items_mod/g3/AssetRegistry.bin

Working startup PAK:
/home/twdoor/Projects/spellbreak/g3/Content/Paks/zzzz_new_items_registry_P.pak
/home/twdoor/Projects/spellbreak/g3/Content/Paks/zzzz_new_items_registry_P.sig

Asset Buddy source:
/home/twdoor/Projects/modding-toolkit/local/mods/client/asset_buddy/src/lib.rs

Asset Buddy configuration:
/home/twdoor/Projects/modding-toolkit/new_items.txt
```

## Limitations and risks

The current proof of concept ships a complete replacement
`g3/AssetRegistry.bin`. Therefore two custom-item PAKs that each contain their
own independently generated full registry will conflict: only the winning PAK's
registry will be loaded.

This must not become the final distribution model. A proper tool should build
one merged registry from all enabled mods immediately before packing. It should
also make an atomic backup before replacing an installed PAK and SIG.

Package dependencies still matter. A new item cloned from a stock item works
because its referenced classes and assets already exist. Truly new meshes,
materials, textures, sounds, or Blueprint dependencies must also be cooked,
included under the correct paths, and represented consistently.

Using a duplicate package GUID did not prevent this test from loading, but a
production asset-creation flow should generate a unique GUID for each genuinely
new package.

## Recommended production design

The proper modkit system should use this pipeline:

```text
Enabled mods
    -> discover new cooked packages and sidecars
    -> read per-mod custom-item declarations
    -> validate package paths and class exports
    -> start from the clean stock AssetRegistry.bin
    -> add every enabled mod's records to one in-memory registry
    -> detect duplicate package names and conflicting asset IDs
    -> write one merged g3/AssetRegistry.bin
    -> merge all mod content into one staging directory
    -> build one late-sorting startup PAK and matching SIG
    -> atomically install both into g3/Content/Paks
```

A simple first manifest extension could be:

```json
{
  "custom_assets": [
    {
      "file": "g3/Content/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.uasset",
      "source": "/Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_5.BP_Item_Boots_Tier_5",
      "target": "/Game/Blueprints/Items/v3/Wearables/Boots/BP_Item_Boots_Tier_6.BP_Item_Boots_Tier_6"
    }
  ]
}
```

The packing service now invokes the Python patcher. Later, the parser
can be ported to GDScript or exposed as a small native helper if shipping Python
is undesirable. Keeping the parser as a separately tested library is preferable
to embedding binary-offset edits directly in UI code.

## Next iteration checklist

- Inspect the target package exports and confirm the expected generated class.
- Validate `.uasset`/`.uexp` sidecar completeness.
- Remove or simplify Asset Buddy's unsuccessful runtime-registry experiments
  once the startup build pipeline is established.

## Final conclusion

Spellbreak Community Edition can load genuinely new item packages. The missing
piece was not DLL-based primary-asset registration by itself; it was making the
new package part of the Asset Registry that UE4.22 loads during startup. The
successful proof of concept gives us a clear path toward a proper multi-mod
custom-item build system.
