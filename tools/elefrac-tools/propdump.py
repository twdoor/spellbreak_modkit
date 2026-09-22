#!/usr/bin/env python3
"""Read and patch numeric properties in cooked UE4.22 assets (tagged property serialisation).

    ./propdump.py dump <pak> <entry-substring> [...]      every property of every export, with offsets
    ./propdump.py grep <pak> <regex-on-path> [<entry-substring>]
                                                         numeric properties whose path matches, across the pak

Paths read `Export.Prop.SubProp[i].Leaf`. Only fixed-size values (float, int, bool, byte) are patched, so a patch
never moves anything: the value is overwritten in place (see patch_value), which is why balance edits need none of
the offset repair CookedAsset.set_text does.

Structs the engine serialises natively (Vector, Rotator, LinearColor, Guid, GameplayTag(Container), ...) are decoded
for the common ones and shown as raw bytes otherwise; every other struct is itself a list of tagged properties.
"""
import json, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import efpak
from efpak import rd_fstr
from uasset import CookedAsset

NATIVE = {
    'Vector': ('<fff', 12), 'Vector2D': ('<ff', 8), 'Vector4': ('<ffff', 16), 'Rotator': ('<fff', 12),
    'Quat': ('<ffff', 16), 'LinearColor': ('<ffff', 16), 'Color': ('<BBBB', 4), 'IntPoint': ('<ii', 8),
    'IntVector': ('<iii', 12), 'Guid': ('<IIII', 16), 'DateTime': ('<q', 8), 'Timespan': ('<q', 8),
    'FrameNumber': ('<i', 4),
}


class Reader:
    def __init__(s, asset):
        s.a = asset
        s.x = asset.x
        s.out = []                     # (path, type, offset, value)

    def name(s, p):
        i, n = struct.unpack_from('<ii', s.x, p)
        nm = s.a.names[i] if 0 <= i < len(s.a.names) else f'?{i}'
        return (nm if n == 0 else f'{nm}_{n - 1}'), p + 8

    def props(s, p, end, path):
        """Tagged properties from p until None (or end). Returns the position after the terminator."""
        while p < end:
            name, p = s.name(p)
            if name == 'None':
                return p
            typ, p = s.name(p)
            size, idx = struct.unpack_from('<ii', s.x, p); p += 8
            extra = {}
            if typ == 'StructProperty':
                extra['struct'], p = s.name(p); p += 16
            elif typ == 'BoolProperty':
                extra['bool_offset'] = p
                extra['bool'] = s.x[p]; p += 1
            elif typ in ('ByteProperty', 'EnumProperty'):
                extra['enum'], p = s.name(p)
            elif typ in ('ArrayProperty', 'SetProperty'):
                extra['inner'], p = s.name(p)
            elif typ == 'MapProperty':
                extra['key'], p = s.name(p); extra['val'], p = s.name(p)
            has_guid = s.x[p]; p += 1
            if has_guid:
                p += 16
            full = f"{path}.{name}" + (f"[{idx}]" if idx else '')
            s.value(typ, p, size, full, extra)
            p += size
        return p

    def emit(s, path, typ, off, val):
        s.out.append((path, typ, off, val))

    def value(s, typ, p, size, path, extra):
        x = s.x
        if typ == 'FloatProperty': s.emit(path, 'float', p, struct.unpack_from('<f', x, p)[0])
        elif typ == 'IntProperty': s.emit(path, 'int', p, struct.unpack_from('<i', x, p)[0])
        elif typ == 'Int64Property': s.emit(path, 'int64', p, struct.unpack_from('<q', x, p)[0])
        elif typ == 'UInt32Property': s.emit(path, 'uint32', p, struct.unpack_from('<I', x, p)[0])
        elif typ == 'BoolProperty': s.emit(path, 'bool', extra['bool_offset'], extra['bool'])
        elif typ == 'ByteProperty':
            if size == 1: s.emit(path, 'byte', p, x[p])
            else: s.emit(path, 'enum', p, s.name(p)[0])
        elif typ == 'EnumProperty': s.emit(path, 'enum', p, s.name(p)[0])
        elif typ == 'NameProperty': s.emit(path, 'name', p, s.name(p)[0])
        elif typ in ('ObjectProperty', 'ClassProperty', 'WeakObjectProperty', 'InterfaceProperty'):
            s.emit(path, 'object', p, s.obj(struct.unpack_from('<i', x, p)[0]))
        elif typ == 'StrProperty': s.emit(path, 'str', p, rd_fstr(x, p)[0])
        elif typ == 'SoftObjectProperty':
            s.emit(path, 'soft', p, s.name(p)[0] + ('' if size <= 12 else ' ' + rd_fstr(x, p + 8)[0]))
        elif typ == 'TextProperty': s.emit(path, 'text', p, x[p:p + size].hex()[:40])
        elif typ == 'StructProperty': s.struct(extra['struct'], p, size, path)
        elif typ in ('ArrayProperty', 'SetProperty'): s.array(extra['inner'], p, size, path, typ == 'SetProperty')
        else: s.emit(path, typ, p, f'<{size} bytes>')

    def obj(s, i):
        """A package index as a readable object name (import or export)."""
        if i == 0: return None
        a = s.a
        try:
            if i > 0:
                return a.exports[i - 1]['name']
            imp_off = s._imports()
            e = imp_off + (-i - 1) * 28
            ni, = struct.unpack_from('<i', a.a, e + 20)
            return a.names[ni] if 0 <= ni < len(a.names) else f'import{i}'
        except Exception:
            return f'obj{i}'

    def _imports(s):
        if not hasattr(s, '_imp'):
            s._imp, = struct.unpack_from('<i', s.a.a, s.a.f + 0x20)
        return s._imp

    def struct(s, sname, p, size, path):
        if sname in NATIVE:
            fmt, n = NATIVE[sname]
            vals = struct.unpack_from(fmt, s.x, p)
            if sname in ('Vector', 'Vector2D', 'Vector4', 'Rotator', 'Quat', 'LinearColor'):
                for comp, v, k in zip('XYZW' if sname != 'Rotator' else ('Pitch', 'Yaw', 'Roll'), vals, range(9)):
                    s.emit(f'{path}.{comp}', 'float', p + 4 * k, v)
            else:
                s.emit(path, sname, p, vals)
            return
        if sname == 'GameplayTag':
            s.emit(path, 'tag', p, s.name(p + 25)[0]); return
        if sname == 'GameplayTagContainer':
            n, = struct.unpack_from('<i', s.x, p)
            s.emit(path, 'tags', p, [s.name(p + 4 + 8 * i)[0] for i in range(n)]); return
        if sname in ('SoftObjectPath', 'SoftClassPath'):
            s.emit(path, 'soft', p, s.name(p)[0]); return
        # generic: nested tagged properties
        try:
            s.props(p, p + size, path)
        except Exception as exc:
            s.emit(path, f'struct:{sname}', p, f'<{size} bytes, {exc}>')

    def array(s, inner, p, size, path, is_set):
        x = s.x
        if is_set:
            p += 4                      # elements to remove
        n, = struct.unpack_from('<i', x, p); p += 4
        if inner == 'StructProperty':
            # one full tag for the inner struct type, then n tagged structs
            _, q = s.name(p); _, q = s.name(q)
            _, _ = struct.unpack_from('<ii', x, q); q += 8
            sname, q = s.name(q); q += 16 + 1
            for i in range(n):
                if sname in NATIVE:
                    s.struct(sname, q, NATIVE[sname][1], f'{path}[{i}]'); q += NATIVE[sname][1]
                else:
                    q = s.props(q, p + size, f'{path}[{i}]')
            return
        widths = {'FloatProperty': 4, 'IntProperty': 4, 'ObjectProperty': 4, 'NameProperty': 8, 'ByteProperty': 1,
                  'BoolProperty': 1, 'EnumProperty': 8, 'SoftObjectProperty': 8}
        w = widths.get(inner)
        if w is None:
            s.emit(path, f'array:{inner}', p, f'<{n} items>'); return
        for i in range(n):
            q = p + i * w
            if inner == 'FloatProperty': s.emit(f'{path}[{i}]', 'float', q, struct.unpack_from('<f', x, q)[0])
            elif inner == 'IntProperty': s.emit(f'{path}[{i}]', 'int', q, struct.unpack_from('<i', x, q)[0])
            elif inner == 'ObjectProperty': s.emit(f'{path}[{i}]', 'object', q, s.obj(struct.unpack_from('<i', x, q)[0]))
            elif inner in ('NameProperty', 'EnumProperty'): s.emit(f'{path}[{i}]', 'name', q, s.name(q)[0])
            else: s.emit(f'{path}[{i}]', inner, q, x[q])


def dump_asset(uasset, uexp):
    a = CookedAsset(uasset, uexp)
    r = Reader(a)
    for i, e in enumerate(a.exports):
        p = e['offset'] - a.hdr
        try:
            r.props(p, p + e['size'], e['name'])
        except Exception as exc:
            r.emit(e['name'], 'error', p, str(exc))
    return a, r.out


def patch_value(a, off, typ, value):
    """Overwrite a fixed-size value in place (the offset comes from a dump of the same bytes)."""
    if typ == 'float': struct.pack_into('<f', a.x, off, float(value))
    elif typ == 'int': struct.pack_into('<i', a.x, off, int(value))
    elif typ == 'object': struct.pack_into('<i', a.x, off, int(value))
    elif typ == 'tag':
        name_idx = a.names.index(value)
        struct.pack_into('<ii', a.x, off + 25, name_idx, 0)
    elif typ == 'bool': a.x[off] = 1 if value else 0
    elif typ == 'byte': a.x[off] = int(value)
    else: raise ValueError(f'cannot patch a {typ} in place')


def entries(pak, sub):
    return [n for n in sorted(pak.entries) if n.endswith('.uasset') and sub.lower() in n.lower()
            and n[:-7] + '.uexp' in pak.entries]


if __name__ == '__main__':
    cmd, pak_path = sys.argv[1], sys.argv[2]
    pak = efpak.Pak(pak_path)
    if cmd == 'dump':
        for sub in sys.argv[3:]:
            for nm in entries(pak, sub):
                _, rows = dump_asset(pak.get(nm), pak.get(nm[:-7] + '.uexp'))
                print(f'== {nm}')
                for path, typ, off, val in rows:
                    print(f'  {path} ({typ} @{off}) = {val}')
    elif cmd == 'grep':
        rx = re.compile(sys.argv[3], re.I)
        sub = sys.argv[4] if len(sys.argv) > 4 else ''
        for nm in entries(pak, sub):
            try:
                _, rows = dump_asset(pak.get(nm), pak.get(nm[:-7] + '.uexp'))
            except Exception:
                continue
            for path, typ, off, val in rows:
                if rx.search(path) and typ in ('float', 'int', 'bool', 'byte'):
                    print(f'{nm.rsplit("/", 1)[1][:-7]:48s} {path} = {val}')
