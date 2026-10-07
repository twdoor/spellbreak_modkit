# Localization and batch recipes

Open **Tools → Localization** or **Tools → Batch Recipes** in the mod manager. Select a mod folder at the top. Work runs in the background; results are written into that mod, never directly into the game install.

## Localization

1. Choose the mod and an **extracted base source** containing `g3/Content/Localization/Game/<culture>/Game.locres`.
2. Click **Scan Text**. Select a text on the left and a language at the top, then enter its translation. The English source is read-only.
3. **Save Translations** stores the catalog in `<mod>/.modkit/localization.json`. Scanning again preserves translations whose English source has not changed. Changed source strings clear their old translations.
4. **Build Language Files** builds English plus all languages with translations (and any languages previously built from this catalog). Empty translations fall back to English. Clearing a previously built translation restores English when rebuilt.
5. Pack or export the mod normally.

The first version handles Base-history FText in cooked `.uasset` files. Other text histories are counted as skipped; this is not a Blueprint compiler or a string-table editor. It does not generate translations automatically. Check numbers, formatting tokens and wording before building.

Translated properties receive independent, stable mod localization keys so an override does not change translations for unrelated vanilla assets sharing their original key. Each output language file contains the base table, any existing mod entries, and the edited translations. Normal multi-mod packing merges language resources by namespace/key; later enabled mods win an exact key conflict. Independently exported paks containing full language files still need to be composed together to avoid file-level overrides.

## Batch recipes

1. **Inspect Asset…** reads an asset already copied into the selected mod and generates a JSON recipe with its numeric and boolean properties.
2. Keep the rows you want. Change `value` and optionally `operation` (`set`, `add`, or `multiply`). Boolean edits support only `set`.
3. **Save Recipe…** makes it reusable; **Load Recipe…** opens an existing recipe.
4. Click **Preview** to see the actual before/after changes. Nothing is written at this stage.
5. Click **Apply**. If the recipe or any affected package/companion changed since preview, preview again.

Example (use Inspect Asset to obtain the actual export name and property pointer):

```json
{
  "version": 1,
  "edits": [
    {
      "asset": "g3/Content/Example.uasset",
      "export": "Default__Example_C",
      "property": "/Data/0",
      "expected": 10.0,
      "operation": "multiply",
      "value": 1.5,
      "sync_calculated": true
    }
  ]
}
```

`property` points to a typed property object within the named export, not to its raw Value field. `expected` must match the current value; recipes intentionally fail on a different baseline. For a `BaseValue` property, optional `sync_calculated: true` sets its `CalculatedValue` sibling to the same result and includes both in the preview. Omit the sibling's separate recipe row in that case. Unchanged rows do not appear in the preview.

Recipes edit existing numeric/boolean properties only. Text, references, name-table changes, and structural edits remain in their dedicated editor workflows. JSON recipes retain 64-bit integers without conversion through Godot's floating-point JSON representation.

## Validation and backups

Close asset tabs for the selected mod before applying/building, so an older open document cannot overwrite the result. Auto-pack watching pauses during content writes. All modified assets are staged through the bundled UAssetConverter and reopened to check properties before installation; `.ubulk` and `.uptnl` payloads are retained. Failed installation rolls back already replaced files.

Backups live under `<mod>/.modkit/backups/<operation-id>/`, outside packed `g3/` content. The status message gives the exact path. `restore.json` lists each target and whether it existed before the operation. To restore manually, close the mod's editor tabs, copy the saved files back to the corresponding mod paths, and remove targets marked `false` in that map. Keep `.uasset` and companions together.

Uses the private Python runtime and .NET converter bundled with the editor. No separate runtime installation is needed in release builds. No additional Python packages are required for these editor workflows. Client/server release composition remains separate and is not implemented by this feature.

## Implementation reference

The locres reader/writer supports legacy, compact and optimized UE4 resources (versions 0–2), writes Spellbreak's optimized v2 format, and rejects newer formats. Format reference: [UnrealLocres](https://github.com/akintos/UnrealLocres/blob/master/LocresLib/LocresFile.cs).
