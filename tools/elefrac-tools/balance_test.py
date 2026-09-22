#!/usr/bin/env python3
"""Balance test pass: numeric and text edits applied over the dev/PTB balance pak (ElefracTest_P).

    ./balance_test.py [--in ElefracTest_P.pak] [--out out/ElefracTest_P.pak] [--dry]

Each row of CHANGES names an asset (by file leaf), a property path exactly as `propdump.py dump` prints it, and the
new value. A BaseValue edit also writes its CalculatedValue twin, since both are serialised. An asset the input pak
does not carry is taken from the live balance pak, else the base game pak, so an edit to a vanilla-only asset (the
legendary wind gauntlet, say) ships the whole asset with just that value changed.

TEXTS rewrites descriptions whose numbers the edits change; the text stays keyed the way it was (balance_loc
re-keys and translates on the prod pak).
"""
import argparse, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efpak
import efpaths
from uasset import CookedAsset
from propdump import dump_asset, patch_value

HERE = os.path.dirname(os.path.abspath(__file__))
TEST_IN = str(efpaths.build('elefractest-20260816', 'ElefracTest_P.pak'))  # the dev.zip of 2026-08-16 (archive blob 63b418b4)
LIVE = str(efpaths.build('elefracbalance-live-preloc.pak'))
BASE = str(efpaths.BASE_PAK)

D = lambda leaf: f'Default__{leaf}_C.'
W = 'GWearableItem_GEN_VARIABLE.'


def boots(leaf, fwd_i, fwd, strafe):
    return [(leaf, f'{W}EquipEffects[{fwd_i}].Scale', fwd), (leaf, f'{W}EquipEffects[{fwd_i + 1}].Scale', strafe)]


CHANGES = [
    # ── movement: Classic strafe speeds, heavier gravity (jump apex kept about the same) ──
    ('PlayerCharacter_Base_BP', D('PlayerCharacter_Base_BP') + 'MaxWalkStrafeSpeed.BaseValue', 350),       # 400
    ('PlayerCharacter_Base_BP', D('PlayerCharacter_Base_BP') + 'MaxSprintStrafeSpeed.BaseValue', 525),     # 550
    ('PlayerCharacter_BP', 'CharMoveComp.GravityScale', 1.65),                                            # 1.5
    ('PlayerCharacter_BP', 'CharMoveComp.JumpZVelocity', 805),                                            # 775
    # ── levitation, Chapter 2 (hotfix.13669) mapped onto the final velocity model. Ch2 levitation was force-based
    # (LevitationForce 2062.5 vs gravity 1.2375, rising to a 900 cap); the final exe dropped those properties, so the
    # rise speed stays at 700 (about the average of that climb) and the rest takes the Ch2 values: 550 to activate,
    # 40 mana/s, 1.5 s regen delay, 0.66 s minimum tap (the ~35% minimum spend from the Ch2 release notes). ──
    ('PlayerCharacter_BP', D('PlayerCharacter_BP') + 'LevitationManaCostPerSecond.BaseValue', 24),          # 27.5
    # The minimum is what prices a tap. Chapter 2's 0.66 charged a third of a second however briefly space was
    # held, so a tap and a real lift cost the same and reached different heights; zero charged a single frame,
    # which let a mashed spacebar hover for almost nothing (each tap re-arrests the fall and adds a frame of
    # force, and a frame of mana is 0.6). 0.2 prices a tap at a tap: mashing now costs what holding costs, and
    # the window where two presses feel different is a fifth of a second instead of two thirds.
    ('PlayerCharacter_BP', D('PlayerCharacter_BP') + 'MinLevitationTime', 0.1),                           # 0.25
    ('PlayerCharacter_BP', D('PlayerCharacter_BP') + 'MinTapLevitationTime', 0.1),                        # 0.25
    ('PlayerCharacter_BP', D('PlayerCharacter_BP') + 'LevitationManaRechargeDelay', 1.5),                 # 0.8
    # ── Lev Cancelling fix ──
    # Replace Export 62 (Levitate -> BP_Action_Levitate_C) with Export 56 (Primary Attack) in BufferAttacks.
    # Starting/holding levitation will not abort attacks or shorten/bypass attack recovery.
    ('PlayerCharacter_BP', 'Actions.SharedTriggerSets[3].Triggers[4]', 56),
    # Shock Primary Finish custom triggers: replace Export 17 (Levitate) with Export 15 (Primary Attack).
    ('BP_Action_WeaponUse_Shock_Primary_Finish', 'Default__BP_Action_WeaponUse_Shock_Primary_Finish_C.Triggers[3]', 15),
    # ── boots: about -12%, halfway back to vanilla on the tiered ones ──
    *boots('BP_Item_Boots_Tier_1', 0, 45, 36),        # 60/48
    *boots('BP_Item_Boots_Tier_2', 0, 75, 60),        # 90/72
    *boots('BP_Item_Boots_Tier_3', 0, 105, 85),       # 125/100
    *boots('BP_Item_Boots_Tier_4', 0, 135, 110),      # 155/126
    *boots('BP_Item_Boots_Tier_5', 0, 180, 145),      # 210/170
    *boots('BP_Item_Boots_Cat', 1, 165, 145),         # 185/165
    *boots('BP_Item_Boots_Slowfall', 2, 165, 140),    # 185/160
    *boots('BP_Item_Boots_Wanderer', 1, 165, 125),    # 185/140
    *boots('BP_Item_Boots_Rubber', 1, 135, 110),      # 155/126
    *boots('BP_Item_Boots_Mender', 1, 135, 105),      # 155/117
    *boots('BP_Item_Boots_Behemoth', 2, 135, 105),    # 155/117
    *boots('BP_Item_Boots_Slayer', 2, 135, 110),      # 155/126
    *boots('BP_Item_Boots_Scribe', 1, 130, 95),       # 150/110
    *boots('BP_Item_Boots_Berserker', 2, 110, 85),    # 125/95
    *boots('BP_Item_Boots_Baron', 0, 110, 110),       # 125/125
    *boots('BP_Item_Boots_Mouse', 1, 105, 85),        # 120/96
    *boots('BP_Item_Boots_Grounding', 1, 80, 64),     # 90/72
    *boots('BP_Item_Boots_Shoes_Padded', 1, 80, 64),  # 90/72
    # ── movement runes and scrolls ──
    ('BP_Effect_Scroll_Frostborn_Frozen_Alacrity_Acceleration',
     D('BP_Effect_Scroll_Frostborn_Frozen_Alacrity_Acceleration') + 'ApplicationAttributeMods[1].Mod.Amount', 800),  # 925 (live 1200)
    ('BP_Skill_Wolfsblood_Base', D('BP_Skill_Wolfsblood_Base') + 'CharacterEffects[1].Scale', 140),       # live 180, vanilla 120
    ('BP_Skill_Agile', D('BP_Skill_Agile') + 'MaxCharges.BaseValue', 1),                                  # 3 (Blink)
    # ── talents ──
    *[('BP_Perk_Escapist', D('BP_Perk_Escapist') + f'LevelData[{i}].Effects[1].Scale', 32) for i in range(4)],   # 95
    *[('BP_Perk_Escapist', D('BP_Perk_Escapist') + f'LevelData[{i}].Effects[2].Scale', 26) for i in range(4)],   # 77
    ('BP_Perk_Escapist', D('BP_Perk_Escapist') + 'LevelData[3].Effects[0].Scale', 120),                  # 150
    *[('BP_Perk_Dexterity', D('BP_Perk_Dexterity') + f'LevelData[{i}].Effects[1].Scale', 60) for i in range(4)],  # 90
    *[('BP_Perk_Dexterity', D('BP_Perk_Dexterity') + f'LevelData[{i}].Effects[2].Scale', 49) for i in range(4)],  # 73
    ('BP_Perk_Dexterity', D('BP_Perk_Dexterity') + 'LevelData[3].Effects[0].Scale', 0.75),               # 0.70
    # ── stone: narrower shockwave, damage unchanged ──
    ('BP_Projectile_Earth_Shockwave', 'DamageBox.BoxExtent.Y', 80),                                       # 110 (vanilla 60)
    # ── wind shear: legendary lands at 8, tiers scaled under it ──
    ('BP_WeaponActor_Wind_Tier_1', D('BP_WeaponActor_Wind_Tier_1') + 'ProjectileBaseDamage[0].BaseValue', 5),    # 6
    ('BP_WeaponActor_Wind_Tier_2', D('BP_WeaponActor_Wind_Tier_2') + 'ProjectileBaseDamage[0].BaseValue', 6),    # 7
    ('BP_WeaponActor_Wind_Tier_2', D('BP_WeaponActor_Wind_Tier_2') + 'MinDamage[0].BaseValue', 3),               # 4 (Ch2 3)
    ('BP_WeaponActor_Wind_Tier_3', D('BP_WeaponActor_Wind_Tier_3') + 'ProjectileBaseDamage[0].BaseValue', 6.5),  # 8
    ('BP_WeaponActor_Wind_Tier_4', D('BP_WeaponActor_Wind_Tier_4') + 'ProjectileBaseDamage[0].BaseValue', 7.5),  # 10
    ('BP_WeaponActor_Wind_Tier_4', D('BP_WeaponActor_Wind_Tier_4') + 'MinDamage[0].BaseValue', 4),               # 7 (Ch2 4)
    ('BP_WeaponActor_Wind_Tier_5', D('BP_WeaponActor_Wind_Tier_5') + 'ProjectileBaseDamage[0].BaseValue', 8),    # 12
    ('BP_WeaponActor_Wind_Tier_5', D('BP_WeaponActor_Wind_Tier_5') + 'MinDamage[0].BaseValue', 4.5),             # 8
    # ── toxic: -10% spray, -20% more up close, smaller clouds; Outbreak back near its original buff ──
    ('BP_WeaponActor_Poison', D('BP_WeaponActor_Poison') + 'ProjectileShortRangeDamageScale[0].BaseValue', 0.8),  # 1
    ('BP_WeaponActor_Poison', D('BP_WeaponActor_Poison') + 'PoisonVolumeSizeScale[1].BaseValue', 1.1),            # 1.3
    ('BP_Effect_Scroll_Toxicologist_Outbreak', D('BP_Effect_Scroll_Toxicologist_Outbreak') + 'ApplicationAttributeMods[0].Mod.Amount', 0.7),  # 0.4 (live 0.5, vanilla 0.75)
    # ── sorcery hitboxes: tornado -15% ──
    ('BP_Whirlwind_Base', 'DamageCapsule.CapsuleRadius', 110),                                            # 128.4
    ('BP_Whirlwind_Base', 'EffectSphere.SphereRadius', 340),                                              # 400
    # ── chip damage: -25% on every lingering tick ──
    ('BP_Effect_Fire_Damage', D('BP_Effect_Fire_Damage') + 'PeriodicDamagePerSecond', 9),                 # 12 (vanilla 18)
    ('BP_Effect_Fire_Wall_Damage', D('BP_Effect_Fire_Wall_Damage') + 'PeriodicDamagePerSecond', 9),       # 12
    ('BP_Effect_Poison_Cloud_Damage', D('BP_Effect_Poison_Cloud_Damage') + 'PeriodicDamagePerSecond', 9), # 12
    ('BP_Effect_Poison_Damage', D('BP_Effect_Poison_Damage') + 'PeriodicDamagePerSecond', 9),             # 12
    ('BP_Effect_Whirlwind_Damage', D('BP_Effect_Whirlwind_Damage') + 'PeriodicDamagePerSecond', 8),       # 10
    ('BP_Effect_Scroll_Toxicologist_Corrosion_Target',
     D('BP_Effect_Scroll_Toxicologist_Corrosion_Target') + 'PeriodicDamagePerSecond', 2),                 # 3
]

# Toxic spray per tier: -10%.
for t in range(1, 6):
    CHANGES.append((f'BP_WeaponActor_Poison_Tier_{t}', D(f'BP_WeaponActor_Poison_Tier_{t}') + 'ProjectileBaseDamage[0].BaseValue',
                    lambda v: round(v * 0.9 * 2) / 2))

# Test-pak overrides dropped outright, so the base game's asset applies again.
DROP = [
    # The 2026-08-16 test pak grants the tags 'pizza' and '0' here instead of Status.Immunity.Freeze /
    # FreezeSlow, so a Frozen Alacrity Frostborn freezes in their own frozen mist (live ships no override).
    'BP_Effect_Scroll_Frostborn_Frozen_Alacrity_Immunity',
    # Levitating granted Status.PreventFire, which is what CanFire() checks: you could not cast while
    # levitating. Chapter 2 levitation is meant to be fought in, and a lift you cannot shoot from is a lift
    # nobody uses. The base game asset grants Status.Levitating and silences nothing, so dropping the
    # override restores casting mid-air. Live keeps its own copy; this is the test pak only.
    'BP_Effect_Player_Levitating',
]

# ── Allow casting while levitating for all gauntlet spells, sorceries, and abilities ──
# Renaming Action.Tags.PreventLevitation in the asset's name table disables the tag in both
# Tags (GameplayTagContainer) and TaggedPeriods without shifting asset offsets (equal 29-char length).
PREVENT_LEVITATION_SWAP = {'Action.Tags.PreventLevitation': 'Action.Tags.LevitationAllowed'}
ALL_LEVITATION_CAST_ACTIONS = [
    # Fire
    'BP_Action_WeaponUse_Fire_Primary',
    'BP_Action_WeaponUse_Fire_Secondary',
    # Ice (Sorcery only; the Frost primary is a charged beam and stays blocked while levitating)
    'BP_Action_WeaponUse_Ice_Secondary',
    # Wind
    'BP_Action_WeaponUse_Wind_Primary_Fire',
    'BP_Action_WeaponUse_Wind_Primary_Fire_02',
    'BP_Action_WeaponUse_Wind_Primary_Fire_03',
    # Shock
    'BP_Action_WeaponUse_Shock_Primary',
    'BP_Action_WeaponUse_Shock_Primary_Finish',
    'BP_Action_WeaponUse_Shock_Secondary',
    # Toxic
    'BP_Action_WeaponUse_Poison_Primary',
    'BP_Action_WeaponUse_Poison_Secondary',
    # Earth is left out on purpose: both stone attacks stay blocked while levitating, same as the
    # Frost primary. Casting them mid-lift let a player hang in the air on the spell (6.3.16 hotfix).
    # Default & Warden
    'BP_Action_WeaponUse_Default_Primary',
    'BP_Action_WeaponUse_Warden_Primary',
    # Runes
    'BP_Action_SkillUse_Wolf',
    'BP_Action_SkillUse_Stealth',
]
NAMES: dict[str, dict[str, str]] = {act: dict(PREVENT_LEVITATION_SWAP) for act in ALL_LEVITATION_CAST_ACTIONS}

TEXTS = {
    'BP_Perk_Escapist': 'Run Speed: +1\nOn Damage Taken: Run Speed +1/2/3/4 (5s)',
    'BP_Perk_Dexterity': 'Run Speed +2\nLevitation Mana Cost: -15/18/20/25%',
    'BP_Scroll_Toxicologist_Outbreak': 'While Invisible: +70% Toxic Spray Damage',
    'BP_Item_Rune_Blink': 'Instantly teleport forward a short distance. Has 1 charge.',
    'BP_Item_Boots_Tier_1': 'Run Speed: +1.5',
    'BP_Item_Boots_Tier_2': 'Run Speed: +2.5',
    'BP_Item_Boots_Tier_3': 'Run Speed: +3.5',
    'BP_Item_Boots_Tier_4': 'Run Speed: +4.5',
    'BP_Item_Boots_Tier_5': 'Run Speed: +6',
    'BP_Item_Boots_Cat': 'Increases your jump velocity by 40%\r\nRun Speed: +5.5',
    'BP_Item_Boots_Slowfall': 'Decreases the effects of gravity by 50%\r\nRun Speed: +5.5',
    'BP_Item_Boots_Wanderer': 'Invisibility (5s) every 10s\nRun Speed: +5.5',
    'BP_Item_Boots_Rubber': 'Poison Puddles do no damage to you.\r\nRun Speed: +4.5',
    'BP_Item_Boots_Mender': 'After Running for 5s: Regenerate 4 Health / 2 Seconds\nRun Speed: +4.5',
    'BP_Item_Boots_Behemoth': 'Immune: Shock, Toxic Puddles\nRun Speed: +4.5',
    'BP_Item_Boots_Slayer': 'Levitation Mana Cost -10%\nMax Jump: +10%\r\nRun Speed: +4.5',
    'BP_Item_Boots_Scribe': 'On Rune Use: Run Speed: +3 (5s)\nRun Speed: +3.5',
    'BP_Item_Boots_Berserker': 'Immune: Shock\nOn Lightning Damage Taken: Run Speed +4 (5s)\nRun Speed: +3.5',
    'BP_Item_Boots_Baron': 'On Full Health: Run Speed +4\nRun Speed: +3.5',
    'BP_Item_Boots_Mouse': 'While Emoting: Become Invisible\r\nRun Speed: +3.5',
    'BP_Item_Boots_Grounding': 'Being on the ground for more than 2s: Gain +5 Speed\r\nRun Speed: +2.5',
    'BP_Item_Boots_Shoes_Padded': 'Falling from height, creates a shockwave that damages enemies on landing.\r\nRun Speed: +2.5',
    **{f'BP_Item_Rune_Wolfsblood_Tier_{t}': 'See other players through walls and terrain and increases your run speed by 14.'
       for t in range(1, 6)},
}


def find(paks, leaf):
    for label, p in paks:
        for nm in p.entries:
            if nm.endswith('/' + leaf + '.uasset') and nm[:-7] + '.uexp' in p.entries:
                return label, p, nm
    raise KeyError(f'{leaf}: in none of the paks')


# ── The live balance pak ───────────────────────────────────────────────────────────────────────────────────────
# The same engine, a different input and a different table: --live reads the shipping ElefracBalance_P and writes
# one. Kept apart from the test pass on purpose -- nothing above this line has ever been through a live match, and
# a stray row in the wrong table is a balance change nobody asked for.

LIVE_CHANGES: list = [
    # ── Lev Cancelling fix ──
    # Replace Export 62 (Levitate -> BP_Action_Levitate_C) with Export 56 (Primary Attack) in BufferAttacks.
    # Starting/holding levitation will not abort attacks or shorten/bypass attack recovery.
    ('PlayerCharacter_BP', 'Actions.SharedTriggerSets[3].Triggers[4]', 56),
    # Shock Primary Finish custom triggers: replace Export 17 (Levitate) with Export 15 (Primary Attack).
    ('BP_Action_WeaponUse_Shock_Primary_Finish', 'Default__BP_Action_WeaponUse_Shock_Primary_Finish_C.Triggers[3]', 15),
]

LIVE_DROP = [
    # Casting while levitating. The pak's own BP_Effect_Player_Levitating grants Status.PreventFire, and CanFire()
    # is exactly !HasGameplayTag(PreventFireTag), so lifting off silenced the gauntlets, the sorcery and the rune.
    # The base game asset grants Status.Levitating and silences nothing, so the override goes and the base applies.
    'BP_Effect_Player_Levitating',
]

LIVE_NAMES: dict = {act: dict(PREVENT_LEVITATION_SWAP) for act in ALL_LEVITATION_CAST_ACTIONS}

LIVE_TEXTS: dict = {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--live', action='store_true',
                    help='build the shipping ElefracBalance_P from LIVE_* instead of the test pak')
    ap.add_argument('--in', dest='inp', default=None)
    ap.add_argument('--out', default=None)
    ap.add_argument('--dry', action='store_true')
    args = ap.parse_args()
    changes, drop_list, names, texts = (LIVE_CHANGES, LIVE_DROP, LIVE_NAMES, LIVE_TEXTS) if args.live \
        else (CHANGES, DROP, NAMES, TEXTS)
    args.inp = args.inp or (LIVE if args.live else TEST_IN)
    args.out = args.out or os.path.join(HERE, 'out', 'ElefracBalance_P.pak' if args.live else 'ElefracTest_P.pak')
    print(f'{"live balance" if args.live else "test"} pak: {args.inp} -> {args.out}')
    src = efpak.Pak(args.inp)
    paks = [('test', src), ('live', efpak.Pak(LIVE)), ('vanilla', efpak.Pak(BASE))]

    by_leaf = {}
    for leaf, path, val in changes:
        by_leaf.setdefault(leaf, []).append((path, val))
    for leaf in texts:
        by_leaf.setdefault(leaf, [])
    for leaf in names:
        by_leaf.setdefault(leaf, [])

    add, drop, bad = [], [], 0
    for leaf, edits in sorted(by_leaf.items()):
        label, pak, nm = find(paks, leaf)
        uexp = nm[:-7] + '.uexp'
        a, rows = dump_asset(pak.get(nm), pak.get(uexp))
        index = {path: (typ, off, v) for path, typ, off, v in rows}
        for path, val in edits:
            targets = [path] + ([path.replace('.BaseValue', '.CalculatedValue')] if path.endswith('.BaseValue') else [])
            for tp in targets:
                if tp not in index:
                    if tp == path:
                        print(f'  !! {leaf}: {tp} not found'); bad += 1
                    continue
                typ, off, old = index[tp]
                new = val(old) if callable(val) else val
                patch_value(a, off, typ, new)
                if tp == path:
                    fmt = (lambda v: f'{v:g}') if isinstance(old, (int, float)) and isinstance(new, (int, float)) else str
                    print(f'  {leaf:52s} {path.split(".", 1)[1] if path.startswith("Default__") else path}: {fmt(old)} -> {fmt(new)}'
                          + ('' if label == 'test' else f'   [from {label}]'))
        for old_tag, new_tag in names.get(leaf, {}).items():
            hits = [i for i, nm in enumerate(a.names) if nm == old_tag]
            if not hits:
                print(f'  !! {leaf}: name {old_tag} not in the table'); bad += 1
                continue
            for i in hits:
                a.names[i] = new_tag
            print(f'  {leaf:52s} attribute: {old_tag} -> {new_tag}')
        if leaf in texts:
            for i in range(len(a.exports)):
                got = a.get_text(i, 'Description')
                if got is None:
                    continue
                ns, key, old = got
                a.set_text(i, 'Description', namespace=ns, key=key, source=texts[leaf])
                print(f'  {leaf:52s} Description: {old!r} -> {texts[leaf]!r}')
                break
            else:
                print(f'  !! {leaf}: no Description'); bad += 1
        ua, ux = a.build()
        chk = CookedAsset(ua, ux)
        for i in range(len(chk.exports)):
            list(chk._walk(i))
        if nm in src.entries:
            drop += [nm, uexp]
        add += [(nm, ua), (uexp, ux)]
    for leaf in drop_list:
        hits = [n for n in src.entries if n.rsplit('/', 1)[1].rsplit('.', 1)[0] == leaf]
        if not hits:
            print(f'  !! {leaf}: not in the input pak'); bad += 1
        drop += hits
        print(f'  {leaf:52s} dropped ({len(hits)} files), base game asset applies')
    if bad:
        sys.exit(f'{bad} edit(s) did not resolve')
    if args.dry:
        return
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    n = efpak.repack(args.inp, args.out, drop=drop, add=add)
    print(f'wrote {args.out} ({os.path.getsize(args.out) / 1e6:.1f} MB, {n} entries, {len(add) // 2} assets edited)')


if __name__ == '__main__':
    main()
