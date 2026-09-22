#!/usr/bin/env python3
"""Build the shipping pak set from any number of source mod paks.

Three paks go to the client and three to the server, because the two ends need different subsets
of the same content and exactly one of them may own the asset registry:

    ElefracBalance_P.pak   talents, perks, items, weapons, effects, config
    EFCosmetics_P.pak      skins and everything they pull in (meshes, materials, textures, icons)
    EFIndex_P.pak          the merged g3/AssetRegistry.bin and nothing else

Why the split:

  * Classic mode parks the balance pak by renaming it, so anything a player must still be able to
    wear has to live somewhere else -- hence a separate cosmetics pak that is never parked.
  * Two mounted paks that both carry g3/AssetRegistry.bin fight, and the loser's rows vanish.  One
    pak owns the registry; every other pak carries content only.
  * A registry row whose package is not mounted is not inert.  AGCharacter::SetSkinTemplate calls
    UClass::GetDefaultObject on the resolved class with no null check, so a cosmetic row pointing
    at a missing package is an access violation on the client.  Rows are filtered to what ships.

The server needs the cosmetics too.  It resolves the skin the player has equipped and sets the
mesh itself, so a server missing BP_Cosmetic_Skin_Doobs replicates an unloaded character model to
everyone in the match -- regardless of whether that server is running Elefrac Balance or Classic.

Sources are applied in order; a later pak wins any entry path a earlier one also has.  Rows come
from each source's own AssetRegistry.bin, keyed on object path, again last-wins.
"""
import argparse, os, shutil, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efpak, registry

REGISTRY = 'g3/AssetRegistry.bin'

# A cosmetic is a SKIN descriptor or an asset only a skin pulls in.  Everything else is balance --
# including other cosmetic types.  A title is a line of text with no art chain behind it, so a
# server missing one has nothing to fail to load; only skins drive a character mesh, and only skins
# therefore have to survive Classic parking the balance pak.
COSMETIC_PREFIXES = (
    'g3/Content/Blueprints/Cosmetics/Skins/',
    'g3/Content/Data/Skins/',
    'g3/Content/Characters/Human/',
    'g3/Content/UI/Textures/assets/cosmetics/',
)


def is_cosmetic(path):
    return path.startswith(COSMETIC_PREFIXES)


def pkg_to_entry(package_name):
    """/Game/Blueprints/... -> g3/Content/Blueprints/....uasset"""
    if not package_name.startswith('/Game/'):
        return None
    return 'g3/Content/' + package_name[len('/Game/'):] + '.uasset'


def prune_vanilla_cosmetics(files, base_pak):
    """Drop cosmetic entries that overwrite a base-game package.

    The community skins used to ship as recolours of the vanilla textures, so the old paks are full
    of overrides at vanilla paths.  Every one of those skins now owns its own package, so an
    override left in place would only repaint the vanilla skin it was cloned from.  Balance
    overrides are the point of the balance pak and are never pruned."""
    base = set(efpak.Pak(base_pak).entries)
    dropped = sorted(n for n in files if is_cosmetic(n) and n in base)
    for n in dropped:
        del files[n]
    return dropped


def collect(sources):
    """(files, rows) merged across sources, last source winning."""
    files, rows = {}, {}
    for src in sources:
        p = efpak.Pak(src)
        for nm in p.entries:
            if nm == REGISTRY:
                continue
            files[nm] = p.get(nm)
        if REGISTRY in p.entries:
            for r in registry.Registry(p.get(REGISTRY)).rows:
                rows[r.object_path.lower()] = r
    return files, rows


def write_set(out_dir, files, rows, base_pak, sig, label, cosmetics=True):
    os.makedirs(out_dir, exist_ok=True)
    balance = sorted(n for n in files if not is_cosmetic(n))
    cosmetic = sorted(n for n in files if is_cosmetic(n))
    if not cosmetics:
        cosmetic = []

    base = registry.Registry(efpak.Pak(base_pak).get(REGISTRY))
    known = set(base.by_object_path)
    shipped = set(balance) | set(cosmetic)
    extra, dangling = [], []
    for key, r in rows.items():
        if key in known:
            continue                      # the base game already indexes it
        entry = pkg_to_entry(r.package_name)
        (extra if entry in shipped else dangling).append(r)
    extra.sort(key=lambda r: r.object_path)

    out = {}
    out['ElefracBalance_P.pak'] = efpak.write_pak(
        os.path.join(out_dir, 'ElefracBalance_P.pak'), [(n, files[n]) for n in balance])
    if cosmetic:
        out['EFCosmetics_P.pak'] = efpak.write_pak(
            os.path.join(out_dir, 'EFCosmetics_P.pak'), [(n, files[n]) for n in cosmetic])
    def emit_index(name, rows_in):
        tmp = os.path.join(out_dir, '_index.bin')
        registry.Registry(efpak.Pak(base_pak).get(REGISTRY)).save(tmp, rows_in)
        out[name] = efpak.write_pak(os.path.join(out_dir, name), [(REGISTRY, open(tmp, 'rb').read())])
        os.remove(tmp)

    emit_index('EFIndex_P.pak', extra)
    # Classic parks the balance pak, so a Classic mount must not advertise anything that lived in
    # it -- the EF-only perks would show up in the talent list with no package behind them.  Same
    # rows minus those: the cosmetics pak is never parked, so its rows are always safe.
    cosmetic_rows = [r for r in extra if is_cosmetic(pkg_to_entry(r.package_name) or '')]
    emit_index('EFIndexClassic_P.pak', cosmetic_rows)

    for name in out:
        if sig:
            shutil.copyfile(sig, os.path.join(out_dir, name.replace('.pak', '.sig')))

    print(f'== {label}  -> {out_dir}')
    print(f'   ElefracBalance_P.pak  {len(balance):5d} entries  {out["ElefracBalance_P.pak"]/1e6:7.1f} MB')
    if cosmetic:
        print(f'   EFCosmetics_P.pak     {len(cosmetic):5d} entries  {out["EFCosmetics_P.pak"]/1e6:7.1f} MB')
    print(f'   EFIndex_P.pak         {base.count} + {len(extra)} rows  {out["EFIndex_P.pak"]/1e6:7.1f} MB')
    print(f'   EFIndexClassic_P.pak  {base.count} + {len(cosmetic_rows)} rows  {out["EFIndexClassic_P.pak"]/1e6:7.1f} MB')
    if dangling:
        print(f'   dropped {len(dangling)} row(s) with no package in this set:')
        for r in sorted(dangling, key=lambda r: r.object_path)[:20]:
            print(f'     {r.object_path}')
    return extra, dangling


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', action='append', required=True, metavar='PAK',
                    help='source mod pak; repeat, later ones win')
    ap.add_argument('--client-base', required=True, metavar='PAK', help='g3-WindowsNoEditor.pak')
    ap.add_argument('--server-base', metavar='PAK', help='g3-WindowsServer.pak; omit to skip the server set')
    ap.add_argument('--out', required=True, metavar='DIR')
    ap.add_argument('--sig', metavar='FILE', help='.sig to copy alongside each pak')
    ap.add_argument('--keep-vanilla-reskins', action='store_true',
                    help='keep cosmetic entries that overwrite base-game packages')
    a = ap.parse_args()

    files, rows = collect(a.src)
    print(f'{len(files)} entries and {len(rows)} rows from {len(a.src)} source pak(s)')
    if not a.keep_vanilla_reskins:
        dropped = prune_vanilla_cosmetics(files, a.client_base)
        print(f'pruned {len(dropped)} cosmetic override(s) of vanilla packages')
    print()
    write_set(a.out, files, rows, a.client_base, a.sig, 'client')
    if a.server_base:
        write_set(os.path.join(a.out, 'server'), files, rows, a.server_base, a.sig, 'server')


if __name__ == '__main__':
    main()
