#!/usr/bin/env python3
"""Build 7.0.0-lev-rc: applies levitation casting, Lev Cancelling fixes, and restores belt armor adjustments.

Preserves 100% of 7.0.0-b1's balance numbers (speeds, gravity, friction, mana costs, delays, talents, etc.)
while applying:
1. Elimination of Lev Cancelling:
   - PlayerCharacter_BP: BufferAttacks Trigger[4] changed from Export 62 (Levitate) to Export 56 (Primary Attack).
   - BP_Action_WeaponUse_Shock_Primary_Finish: Custom Triggers[3] changed from Export 17 (Levitate) to Export 15 (Primary Attack).
2. Firing while levitating without dropping / falling:
   - 19 weapon/sorcery actions: Action.Tags.PreventLevitation swapped to Action.Tags.LevitationAllowed (0-byte shift).
     Frost spell (Ice Primary) remains blocked as a charged ability.
3. Belt Armor Adjustment on Fresh Equip (from Live 6.3.13):
   - All 16 armor belts have EquipEffectsWhenNew restored with BP_Effect_Player_Adjust_Armor_From_Belt_C so equipping
     a fresh belt immediately grants full armor.
   - BP_Item_Belt_Slayer rarity updated to EXRarity::Epic.
   - BP_Item_Belt_Constitution remains EXRarity::Epic (Max Health 50).

Outputs, under EF_RELEASES_DIR (see efpaths):
- release-7.0.0-lev-rc/ElefracTest_P.pak
- release-7.0.0-lev-rc/ElefracTest_P.sig
- release-7.0.0-lev-rc/dev.zip
- release-7.0.0-lev-rc/server-dev.zip
"""

import os
import sys
import shutil
import zipfile
import hashlib
from pathlib import Path

# Add skinkit directory to python path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import efpak
import efpaths
from uasset import CookedAsset
from propdump import dump_asset, patch_value
import balance_test

SRC_700_DIR = efpaths.release('7.0.0-b1')
OUT_DIR = efpaths.release('7.0.0-lev-rc')

SRC_PAK = SRC_700_DIR / 'ElefracTest_P.pak'
SRC_SIG = SRC_700_DIR / 'ElefracTest_P.sig'
SRC_SERVER_ZIP = SRC_700_DIR / 'server-dev.zip'
VANILLA_PAK = efpaths.BASE_PAK
LIVE_PAK = efpaths.BALANCE_PAK

TARGET_PAK = OUT_DIR / 'ElefracTest_P.pak'
TARGET_SIG = OUT_DIR / 'ElefracTest_P.sig'
TARGET_DEV_ZIP = OUT_DIR / 'dev.zip'
TARGET_SERVER_DEV_ZIP = OUT_DIR / 'server-dev.zip'

CHANGES = [
    ('PlayerCharacter_BP', 'Actions.SharedTriggerSets[3].Triggers[4]', 56),
    ('BP_Action_WeaponUse_Shock_Primary_Finish', 'Default__BP_Action_WeaponUse_Shock_Primary_Finish_C.Triggers[3]', 15),
]

NAMES = {act: dict(balance_test.PREVENT_LEVITATION_SWAP) for act in balance_test.ALL_LEVITATION_CAST_ACTIONS}

ARMOR_BELTS = [
    'BP_Item_Belt_Armored',
    'BP_Item_Belt_Baron',
    'BP_Item_Belt_Behemoth',
    'BP_Item_Belt_Berserker',
    'BP_Item_Belt_Earth_Wind',
    'BP_Item_Belt_Fire_Ice',
    'BP_Item_Belt_Lightning_Poison',
    'BP_Item_Belt_Mender',
    'BP_Item_Belt_Regeneration',
    'BP_Item_Belt_Reinforced',
    'BP_Item_Belt_Scribe',
    'BP_Item_Belt_Slaking',
    'BP_Item_Belt_Slayer',
    'BP_Item_Belt_Spellslinger',
    'BP_Item_Belt_Survivor',
    'BP_Item_Belt_Wanderer',
]


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def main():
    print('=== Building 7.0.0-lev-rc ===')
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f'Loading source pak: {SRC_PAK}')
    src = efpak.Pak(str(SRC_PAK))
    print(f'Loading vanilla pak: {VANILLA_PAK}')
    vanilla = efpak.Pak(str(VANILLA_PAK))
    print(f'Loading live pak: {LIVE_PAK}')
    live = efpak.Pak(str(LIVE_PAK))

    paks = [('7.0.0-b1', src), ('vanilla', vanilla)]

    by_leaf = {}
    for leaf, path, val in CHANGES:
        by_leaf.setdefault(leaf, []).append((path, val))
    for leaf in NAMES:
        by_leaf.setdefault(leaf, [])

    print(f'Levitation / mechanic assets to process: {len(by_leaf)}')

    add, drop, bad = [], [], 0
    for leaf, edits in sorted(by_leaf.items()):
        label, pak, nm = balance_test.find(paks, leaf)
        uexp = nm[:-7] + '.uexp'
        a, rows = dump_asset(pak.get(nm), pak.get(uexp))
        index = {path: (typ, off, v) for path, typ, off, v in rows}

        for path, val in edits:
            if path not in index:
                print(f'  !! {leaf}: {path} not found')
                bad += 1
                continue
            typ, off, old = index[path]
            patch_value(a, off, typ, val)
            print(f'  {leaf:45s} [{label}] {path}: {old} -> {val}')

        for old_tag, new_tag in NAMES.get(leaf, {}).items():
            hits = [i for i, n in enumerate(a.names) if n == old_tag]
            if not hits:
                print(f'  !! {leaf}: {old_tag} not found in name table')
                bad += 1
                continue
            for i in hits:
                a.names[i] = new_tag
            print(f'  {leaf:45s} [{label}] name table: {old_tag} -> {new_tag} ({len(hits)} hit(s))')

        ua, ux = a.build()
        chk = CookedAsset(ua, ux)
        for i in range(len(chk.exports)):
            list(chk._walk(i))

        if nm in src.entries:
            drop += [nm, uexp]
        add += [(nm, ua), (uexp, ux)]

    # ── Armor Belts: Restore EquipEffectsWhenNew from Live 6.3.13 ──
    print(f'\nProcessing {len(ARMOR_BELTS)} armor belts from live pak...')
    for leaf in ARMOR_BELTS:
        entry = [k for k in live.entries if k.endswith('/' + leaf + '.uasset')][0]
        uexp = entry[:-7] + '.uexp'
        ua = live.get(entry)
        ux = live.get(uexp)
        a, rows = dump_asset(ua, ux)

        # Update Slayer belt to Epic rarity for 7.0.0
        if leaf == 'BP_Item_Belt_Slayer':
            idx = a.names.index('EXRarity::Rare')
            a.names[idx] = 'EXRarity::Epic'
            print(f'  {leaf:45s} [live] Rarity: EXRarity::Rare -> EXRarity::Epic')

        ua_out, ux_out = a.build()
        chk = CookedAsset(ua_out, ux_out)
        for i in range(len(chk.exports)):
            list(chk._walk(i))

        if entry in src.entries:
            drop += [entry, uexp]
        add += [(entry, ua_out), (uexp, ux_out)]
        print(f'  {leaf:45s} [live] restored BP_Effect_Player_Adjust_Armor_From_Belt_C')

    if bad:
        sys.exit(f'Error: {bad} edit(s) failed')

    print(f'\nRepacking into: {TARGET_PAK}')
    num_entries = efpak.repack(str(SRC_PAK), str(TARGET_PAK), drop=drop, add=add)
    print(f'Wrote {TARGET_PAK} ({TARGET_PAK.stat().st_size / 1e6:.2f} MB, {num_entries} entries)')

    # Copy signature
    print(f'Copying sig: {SRC_SIG} -> {TARGET_SIG}')
    shutil.copy2(SRC_SIG, TARGET_SIG)

    # Build dev.zip
    print(f'Building {TARGET_DEV_ZIP}...')
    with zipfile.ZipFile(TARGET_DEV_ZIP, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(TARGET_PAK, arcname='ElefracTest_P.pak')
        z.write(TARGET_SIG, arcname='ElefracTest_P.sig')
    print(f'Wrote {TARGET_DEV_ZIP} ({TARGET_DEV_ZIP.stat().st_size / 1e6:.2f} MB)')

    # Build server-dev.zip
    print(f'Building {TARGET_SERVER_DEV_ZIP}...')
    with zipfile.ZipFile(TARGET_SERVER_DEV_ZIP, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z_out:
        z_out.write(TARGET_PAK, arcname='ElefracTest_P.pak')
        z_out.write(TARGET_SIG, arcname='ElefracTest_P.sig')
        with zipfile.ZipFile(SRC_SERVER_ZIP, 'r') as z_src:
            for item in ['EFCosmetics_P.pak', 'EFCosmetics_P.sig', 'EFIndex_P.pak', 'EFIndex_P.sig']:
                z_out.writestr(item, z_src.read(item))
    print(f'Wrote {TARGET_SERVER_DEV_ZIP} ({TARGET_SERVER_DEV_ZIP.stat().st_size / 1e6:.2f} MB)')

    print('\n=== Verification Summary ===')
    for p in [TARGET_PAK, TARGET_SIG, TARGET_DEV_ZIP, TARGET_SERVER_DEV_ZIP]:
        print(f'{p.name:22s} {p.stat().st_size:10d} bytes  SHA256: {sha256_file(p)}')

    print('\nDone!')


if __name__ == '__main__':
    main()
