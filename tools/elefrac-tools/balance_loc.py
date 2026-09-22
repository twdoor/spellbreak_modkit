#!/usr/bin/env python3
"""Localise the text EF changed in ElefracBalance_P.pak, inside that same pak.

    ./balance_loc.py extract [balance.pak]   write balance_i18n/strings.json (what needs translating, with context)
    ./balance_loc.py check                   every balance_i18n/<culture>.json covers strings.json
    ./balance_loc.py build [in.pak] [out.pak]
                                             give unkeyed texts a key, add every EF text to all 10 Game.locres,
                                             and write the balance pak with both (default: out/ElefracBalance_P.pak
                                             in place, or the installed one when out/ has none)

Why this is needed. The game translates a text by (namespace, key) through Content/Localization/Game/<culture>/
Game.locres, and only when the English the translation was made from still matches the asset's English (each
locres entry carries FCrc::StrCrc32 of its source). The balance pak breaks that three ways:

  - UNKEYED: items EF brought back (the Vandal, Thinker's, Icy Refraction ... amulets, the belts, Slowfall Boots)
    carry inline English with an empty namespace and key, which no culture can look up;
  - CHANGED: rebalanced talents and items keep their vanilla key but not their vanilla English, so every culture
    falls back to English (the old translation is stale, never shown);
  - MISSING: new keyed texts (Feather Cloak, Blood Armor ...) that no Game.locres has at all.

The fix, all in the one pak: unkeyed texts get namespace EF_Balance and key <Asset>_<Property>; each of the ten
Game.locres files is shipped whole (a file in a _P pak replaces the vanilla one outright), i.e. the vanilla table
plus an entry for every EF text, hashed against the EF English. A culture with no translation for a text simply
omits it and shows the English.

Translations live in balance_i18n/<culture>.json (English -> translation), English fixes in balance_i18n/
en_fixes.json (English as authored -> English as shown).
"""
import json, os, struct, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efpak
import efpaths
from efpak import rd_fstr, _crc32_utf32
from uasset import CookedAsset

HERE = os.path.dirname(os.path.abspath(__file__))
I18N = os.path.join(HERE, 'balance_i18n')
# SPELLBREAK_PAKS is the older name for the same thing; EF_PAK_DIR is what the rest of the kit reads.
PAKS = os.path.expanduser(os.environ.get('SPELLBREAK_PAKS') or str(efpaths.PAK_DIR))
BASE = os.path.join(PAKS, 'g3-WindowsNoEditor.pak')
CULTURES = ['en', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'ru', 'zh-Hans']
LOCRES = 'g3/Content/Localization/Game/{}/Game.locres'
EF_NAMESPACE = 'EF_Balance'


def _locres_module():
    try:
        from pylocres import LocresFile, Entry, Namespace   # pip install pylocres
    except ImportError:
        sys.exit('pylocres is required: pip install pylocres')
    return LocresFile, Entry, Namespace


def load_locres(pak, culture):
    LocresFile, _, _ = _locres_module()
    with tempfile.NamedTemporaryFile(suffix='.locres', delete=False) as fh:
        fh.write(pak.get(LOCRES.format(culture)))
        path = fh.name
    lf = LocresFile(); lf.read(path); os.unlink(path)
    return lf


def texts_in(pak):
    """Every Base-history FText property in the pak's assets: (entry, export, prop, ns, key, source)."""
    out = []
    for nm in sorted(pak.entries):
        if not nm.endswith('.uasset'):
            continue
        uexp = nm[:-7] + '.uexp'
        if uexp not in pak.entries:
            continue
        a = CookedAsset(pak.get(nm), pak.get(uexp))
        for i in range(len(a.exports)):
            for name, typ, _, vs, _ in a._walk(i):
                if typ != 'TextProperty' or a.x[vs + 4] != 0:     # Base history only
                    continue
                q = vs + 5
                ns, q = rd_fstr(a.x, q); key, q = rd_fstr(a.x, q); src, q = rd_fstr(a.x, q)
                out.append({'entry': nm, 'export': i, 'export_name': a.exports[i]['name'], 'prop': name,
                            'ns': ns, 'key': key, 'src': src})
    return out


def assigned_key(t):
    """<Asset>_<Property>, the same shape as the game's own string-table keys (BP_Item_Amulet_Vandal_DisplayName).
    Export indices are left out: they are not stable across a rebuild of the balance pak."""
    leaf = t['entry'].rsplit('/', 1)[1][:-7]
    return EF_NAMESPACE, f"{leaf}_{t['prop']}"


def plan(texts, base, fixes):
    """What every EF text becomes: [(text, ns, key, src)] for the texts to (re)write or translate, and the rows
    for strings.json. A text keeps its key unless it has none (-> EF_Balance/<Asset>_<Property>) or its key is
    already taken in this pak by a DIFFERENT English text (one asset can carry two, e.g. a stale CDO copy), in which
    case the second gets <Asset>_<Property>_<CRC of its pak path> (same-named assets live in different folders)."""
    en = {(n.name, e.key): e.translation for n in load_locres(base, 'en') for e in n}
    olds = {c: {(n.name, e.key): e.translation for n in load_locres(base, c) for e in n} for c in CULTURES[1:]}
    owner, targets, rows = {}, [], []
    for t in texts:
        if not t['src'].strip():
            continue
        src = fixes.get(t['src'], t['src'])
        leaf = t['entry'].rsplit('/', 1)[1][:-7]
        if not t['key']:
            ns, key = assigned_key(t); kind = 'unkeyed'
        else:
            ns, key = t['ns'], t['key']
            if (ns, key) not in en: kind = 'missing'
            elif en[(ns, key)] != src: kind = 'changed'
            else: kind = None                     # vanilla text, vanilla translations still apply
        if (ns, key) in owner and owner[(ns, key)] != src:
            ns, key, kind = EF_NAMESPACE, f"{leaf}_{t['prop']}_{zlib.crc32(t['entry'].encode()):08X}", 'rekeyed'
        if kind is None:
            continue
        rewrite = (ns, key, src) != (t['ns'], t['key'], t['src'])
        targets.append((t, ns, key, src, rewrite))
        if (ns, key) in owner:
            continue
        owner[(ns, key)] = src
        row = {'ns': ns, 'key': key, 'src': src, 'kind': kind, 'asset': leaf}
        if kind == 'changed':
            row['old_en'] = en[(ns, key)]
            row['old'] = {c: olds[c].get((ns, key)) for c in CULTURES[1:] if olds[c].get((ns, key))}
        rows.append(row)
    return targets, rows


def en_fixes():
    p = os.path.join(I18N, 'en_fixes.json')
    return json.load(open(p, encoding='utf-8')) if os.path.exists(p) else {}


def cmd_extract(pak_path):
    pak, base = efpak.Pak(pak_path), efpak.Pak(BASE)
    if LOCRES.format('en') in pak.entries:
        sys.exit(f'{pak_path} is already localised (it carries Game.locres): extract from the balance pak as the '
                 'pipeline ships it, before balance_loc build')
    _, rows = plan(texts_in(pak), base, en_fixes())
    os.makedirs(I18N, exist_ok=True)
    json.dump(rows, open(os.path.join(I18N, 'strings.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    kinds = {k: sum(1 for r in rows if r['kind'] == k) for k in ('unkeyed', 'changed', 'missing', 'rekeyed')}
    print(f"{len(rows)} EF texts ({kinds}), {len({r['src'] for r in rows})} distinct English strings "
          f"-> {os.path.relpath(os.path.join(I18N, 'strings.json'), HERE)}")


def translations(culture):
    p = os.path.join(I18N, f'{culture}.json')
    return json.load(open(p, encoding='utf-8')) if os.path.exists(p) else {}


def cmd_check():
    with open(os.path.join(I18N, 'strings.json'), encoding='utf-8') as stream:
        rows = json.load(stream)
    srcs = {r['src'] for r in rows}
    bad = 0
    for c in CULTURES[1:]:
        tr = translations(c)
        missing = [s for s in srcs if not tr.get(s)]
        # numbers must survive translation (values are the whole point of a balance text)
        import re
        wrong = [s for s in srcs if tr.get(s) and sorted(re.findall(r'\d+', s)) != sorted(re.findall(r'\d+', tr[s]))]
        print(f"{c:8s} {len(srcs) - len(missing)}/{len(srcs)} translated, {len(wrong)} with different numbers")
        for s in wrong[:5]:
            print('   numbers:', repr(s[:60]), '->', repr(tr[s][:60]))
        bad += len(missing) + len(wrong)
    return bad


def cmd_build(in_path, out_path):
    LocresFile, Entry, Namespace = _locres_module()
    rows = json.load(open(os.path.join(I18N, 'strings.json'), encoding='utf-8'))
    fixes = en_fixes()
    pak, base = efpak.Pak(in_path), efpak.Pak(BASE)
    texts = texts_in(pak)

    # 1. rewrite the texts whose key or English changes (unkeyed, re-keyed, English fixes) in their assets
    targets, plan_rows = plan(texts, base, fixes)
    assert [(r['ns'], r['key'], r['src']) for r in plan_rows] == [(r['ns'], r['key'], r['src']) for r in rows], \
        'strings.json is stale for this pak: run extract again'
    edits = {}
    for t, ns, key, src, rewrite in targets:
        if rewrite:
            edits.setdefault(t['entry'], []).append((t['export'], t['prop'], ns, key, src))
    add, drop = [], []
    for nm, changes in sorted(edits.items()):
        uexp = nm[:-7] + '.uexp'
        a = CookedAsset(pak.get(nm), pak.get(uexp))
        for export, prop, ns, key, src in changes:
            a.set_text(export, prop, namespace=ns, key=key, source=src)
        ua, ux = a.build()
        # the rewrite must read back exactly, and the rest of every export must still parse
        chk = CookedAsset(ua, ux)
        for export, prop, ns, key, src in changes:
            assert chk.get_text(export, prop) == (ns, key, src), f'{nm}: {prop} did not round-trip'
        for i in range(len(chk.exports)):
            list(chk._walk(i))
        drop += [nm, uexp]; add += [(nm, ua), (uexp, ux)]
    print(f'{len(edits)} asset(s) rewritten ({sum(len(v) for v in edits.values())} text(s) keyed or fixed)')

    # 2. the ten Game.locres: vanilla table + every EF text, hashed against the EF English
    for c in CULTURES:
        lf = load_locres(base, c)
        tr = translations(c)
        byns = {n.name: n for n in lf}
        added = 0
        for r in rows:
            text = r['src'] if c == 'en' else tr.get(r['src'])
            ns = byns.get(r['ns'])
            if ns is None:
                ns = Namespace(r['ns']); lf.add(ns); byns[r['ns']] = ns
            if text:
                ns.add(Entry(r['key'], text, _crc32_utf32(r['src'])))
                added += 1
            elif r['key'] in ns:
                ns.remove(r['key'])               # a stale vanilla translation would never show anyway
        with tempfile.NamedTemporaryFile(suffix='.locres', delete=False) as fh:
            path = fh.name
        lf.write(path)
        data = open(path, 'rb').read(); os.unlink(path)
        name = LOCRES.format(c)
        if name in pak.entries:
            drop.append(name)
        add.append((name, data))
        print(f'  {c:8s} Game.locres: {added}/{len(rows)} EF entries')

    n = efpak.repack(in_path, out_path, drop=drop, add=add)
    print(f'wrote {out_path} ({os.path.getsize(out_path) / 1e6:.1f} MB, {n} entries)')


def default_in():
    """The balance pak as the pipeline ships it: skinkit's out/ copy, else the installed one if not yet localised."""
    built = os.path.join(HERE, 'out', 'ElefracBalance_P.pak')
    return built if os.path.exists(built) else os.path.join(PAKS, 'ElefracBalance_P.pak')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'extract'
    if cmd == 'extract':
        cmd_extract(sys.argv[2] if len(sys.argv) > 2 else default_in())
    elif cmd == 'check':
        sys.exit(1 if cmd_check() else 0)
    elif cmd == 'build':
        src = sys.argv[2] if len(sys.argv) > 2 else default_in()
        dst = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, 'out', 'ElefracBalance_P.localized.pak')
        cmd_build(src, dst)
    else:
        sys.exit(__doc__)
