# Patch build tools

The tools that build and inspect the Elemental Fracture **balance pak**, carried with the patch they
belong to. They work one level below the Modkit: the Modkit packs the assets under `g3/` into a mod
pak, and these read and write *cooked* paks, which is what the shipped `ElefracBalance_P.pak` and the
PTB `ElefracTest_P.pak` are.

Use them to: read the real numbers out of an asset, apply a table of numeric or text edits over a
built pak, put EF's changed text into every language, and lay out the pak set that actually ships to
clients and servers.

```bash
./propdump.py <pak> <asset>        # every tagged property in a cooked asset, with its value
./balance_test.py --dry            # the test pass (ElefracTest_P), printing every change
./balance_test.py --live --dry     # the live pass (ElefracBalance_P)
./balance_loc.py extract           # refresh the translation tables after a balance change
./paksets.py --src ... --out ...   # the shipping pak set for client and server
```

Nothing here writes to the game install. Builds land under `out/` or under the releases directory.

## Where the files come from

`efpaths.py` holds the three machine paths, each overridable so a fresh checkout works anywhere:

| variable | what it is | default |
|---|---|---|
| `EF_GAME_DIR` | the Spellbreak install, read only | `~/Games/Spellbreak` |
| `EF_PAK_DIR` | that install's `Content/Paks` | `$EF_GAME_DIR/g3/Content/Paks` |
| `EF_BUILDS_DIR` | archived paks and zips a build reads | `~/Games/spellbreak-builds` |
| `EF_RELEASES_DIR` | where a build writes its output | `$EF_BUILDS_DIR/releases` |

## The balance pass: `balance_test.py`

One file holds the whole pass, as four tables read top to bottom:

| table | what it does |
|---|---|
| `CHANGES` | numeric property edits, as `(asset, property path, value or lambda)` |
| `DROP` | overrides removed outright, so the base game's asset applies again |
| `NAMES` | name-table swaps, e.g. disabling `Action.Tags.PreventLevitation` on an action |
| `TEXTS` | the description a player reads, rewritten to match the numbers |

`--live` switches to the `LIVE_*` tables and the shipping pak. The two passes are kept apart on
purpose: nothing in the test tables has ever been through a live match, and a stray row in the wrong
table is a balance change nobody asked for. `--dry` prints every edit and writes nothing; run it
first, always, and read the old value in each line.

A property path is what `propdump.py` prints. A `.BaseValue` edit also takes the `.CalculatedValue`
beside it, because the cooked asset carries both and the game reads the second one.

`build_700_lev_rc.py` is a worked example of a full release build on top of that engine: it takes a
previous release's pak, applies its own changes, and writes a complete release folder with the pak,
its `.sig` and the zips.

## Shipping: `paksets.py`

`skinkit.py build` makes a pak of clones. `paksets.py` takes that pak and any others and lays out
what actually ships, because one mounted pak per side may own the asset registry and Classic mode
parks the balance pak by renaming it:

| pak | contents | parked in Classic |
|---|---|---|
| `ElefracBalance_P.pak` | talents, perks, items, weapons, effects, config | yes |
| `EFCosmetics_P.pak` | skins and everything they pull in | **no** |
| `EFIndex_P.pak` | the merged `g3/AssetRegistry.bin`, nothing else | no |
| `EFIndexClassic_P.pak` | the same registry minus the rows for balance-pak assets | (replaces the above) |

```
./paksets.py --src OLD_BALANCE.pak --src EFCommunitySkins_P.pak --src OTHER_MOD.pak \
             --client-base .../g3-WindowsNoEditor.pak \
             --server-base .../BaseServer/g3/Content/Paks/g3-WindowsServer.pak \
             --sig .../EFCrouch_P.sig --out ~/Downloads/ef-paks
```

Sources are applied in order and a later one wins any path an earlier one also has, so a new
balance drop goes last and older EF changes it does not mention survive. Rows come from each
source's own registry, keyed on object path. Feed it only what is meant to ship: an unreleased
balance drop or a local test pak passed as a `--src` lands in the bundle.

Two things it does that are easy to get wrong by hand:

- **Titles and other non-skin cosmetics stay in the balance pak.** A title is a line of text with
  no art chain, so nothing fails to load without it; only skins drive a character mesh and only
  skins have to survive Classic.
- **Cosmetic overrides of vanilla packages are pruned.** The community skins used to ship as
  recolours at the vanilla paths; every one of them owns its own package now, so an override left
  behind would only repaint the vanilla skin it was cloned from. Balance overrides are the point of
  the balance pak and are never pruned. `--keep-vanilla-reskins` turns this off.
- **Rows with no package in the set are dropped**, and the client and server get *different* index
  paks built on their own base registry. The server cook ships far fewer packages than the client
  one, so mounting the client registry on a server would advertise thousands of missing packages —
  and a dangling cosmetic row is not inert: `AGCharacter::SetSkinTemplate` calls
  `UClass::GetDefaultObject` on the resolved class with no null check.

### The server needs the cosmetics too

Not just the client. The dedicated server resolves the cosmetic each player has equipped and sets
the character mesh itself, so a server without `EFCosmetics_P.pak` replicates an **unloaded
character model** to everyone in the match the moment somebody wears a community skin. This is true
of Classic servers as well — "Classic" is a statement about balance, not about cosmetics.

Servers fetch their paks at boot (`docker-entrypoint.sh`), from their own CDN object rather than the
client's `latest.zip`, because of the per-platform registry above:

| `PATCH_ENV` | object | result |
|---|---|---|
| `prod` | `patch/server.zip` (`SERVER_PATCH_URL`) | balance + cosmetics + full index |
| `dev` | `patch/server-dev.zip` (`SERVER_PATCH_TEST_URL`) | same, PTB build |
| `vanilla` | `patch/server.zip` | balance pak deleted, cosmetics kept, Classic index swapped in |

Zip `client/` into `patch/latest.zip` and `server/` into `patch/server.zip`. If the server object is
missing the entrypoint falls back to `latest.zip` so a server still boots.

## Localising the balance pak

`./balance_loc.py` puts EF's changed text into every language the game ships (de, en, es, fr, it, ja, ko,
pt-BR, ru, zh-Hans), inside `ElefracBalance_P.pak` itself. `build` runs it automatically when
`balance_i18n/strings.json` exists. Needs `pip install pylocres cryptography`.

The game shows a translation only when the text has a key AND the English it was translated from still
matches the asset's English. The balance pak breaks that for three kinds of text, all listed by `extract`:
items EF brought back carry inline English with no key (`unkeyed`), rebalanced talents keep their vanilla
key but not their English (`changed`), and new texts have a key no table knows (`missing`).

```bash
./balance_loc.py extract    # after ANY balance pak change: rewrite balance_i18n/strings.json
# translate the new/changed rows into balance_i18n/<culture>.json (English -> translation);
# 'changed' rows carry the game's official translation of the old text as the model
./balance_loc.py check      # every culture covers every string, and keeps every number
./skinkit.py build          # or: ./balance_loc.py build <in.pak> <out.pak>
```

Unkeyed texts get `EF_Balance/<Asset>_<Property>`; each `Game.locres` ships whole (vanilla table plus
EF entries), because a file in a `_P` pak replaces the vanilla one. English typo fixes go in
`balance_i18n/en_fixes.json` (as authored -> as shown) and are written into the assets too.

## Files

| file | purpose |
|---|---|
| `balance_test.py` | the balance pass: numeric, drop, name-table and text edits over a built pak |
| `build_700_lev_rc.py` | a full release build on top of that engine, start to finished zips |
| `balance_loc.py` | EF's changed text in all ten shipped languages, inside the balance pak |
| `balance_i18n/` | the translation tables that feeds |
| `paksets.py` | lays the shipping pak set out for client and server: balance / cosmetics / index |
| `propdump.py` | read and patch numeric properties in cooked UE4.22 assets |
| `uasset.py` | cooked asset surgery: free-length renames and FText rewrites, with offset repair |
| `registry.py` | `AssetRegistry.bin` reader/writer (round-trips byte-identically) |
| `efpak.py` | pak reader/writer (v3 and v8) and cooked name-table surgery |
| `efpaths.py` | the three machine paths above |

The cosmetics half of the kit (skin cloning, texture work, the cosmetics pak) lives in
[elefrac-patches-cosmetics](https://github.com/ElementalFracture/elefrac-patches-cosmetics) under the
same `tools/` name. `paksets.py` is what brings the two back together into one shipping set.

Requires `pip install cryptography` (pak decryption), plus `pylocres` for `balance_loc.py`.
