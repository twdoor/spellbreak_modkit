"""Cooked .uasset/.uexp surgery: rename packages and rewrite FText properties.

Two levels, because they carry very different risk:

  - `NameTable.replace_map` (in efpak) swaps EQUAL-LENGTH names in place. Nothing moves, so it is safe
    on any asset including textures with a .ubulk. Used for the whole art chain.
  - `CookedAsset` here allows names and text of ANY length, and repairs every offset the change
    invalidates. Used only for the cosmetic blueprint, which has no bulk data, so the one field whose
    semantics are unclear for separate-file payloads (BulkDataStartOffset) cannot matter.

Cooked summary layout (FileVersionUE4 = 0), all offsets counted from the start of the .uasset:

    0x18 i32 TotalHeaderSize      0x1c FString FolderName ("None"), then:
    +0x00 i32 PackageFlags        +0x04 i32 NameCount     +0x08 i32 NameOffset
    +0x0c i32 GatherableCount     +0x10 i32 GatherableOffset
    +0x14 i32 ExportCount         +0x18 i32 ExportOffset
    +0x1c i32 ImportCount         +0x20 i32 ImportOffset
    +0x24 i32 DependsOffset       +0x28 i32 SoftPackageRefCount  +0x2c i32 SoftPackageRefOffset
    +0x30 i32 SearchableNamesOffset  +0x34 i32 ThumbnailTableOffset  +0x38 FGuid
    then generations, two FEngineVersions, compression fields, PackageSource,
    i32 AssetRegistryDataOffset, i64 BulkDataStartOffset, i32 WorldTileInfoOffset,
    chunk ids, i32 PreloadDependencyCount, i32 PreloadDependencyOffset

Everything after the name table shifts by the name-table delta; export payloads live in the .uexp, so
an export whose serialised size changes shifts every LATER export's SerialOffset. A property is
{FName name, FName type, i32 size, i32 arrayIndex, <type extra>, u8 hasGuid, value[size]}, and an FText
value is {u32 flags, i8 historyType, FString namespace, FString key, FString source}.
"""
import struct

from efpak import name_hashes, rd_fstr


def _wr_fstr(s):
    e = s.encode('utf8')
    return struct.pack('<i', len(e) + 1) + e + b'\x00'


class CookedAsset:
    def __init__(s, uasset, uexp):
        s.a = bytearray(uasset)
        s.x = bytearray(uexp)
        s.hdr, = struct.unpack_from('<i', s.a, 0x18)
        _, p = rd_fstr(s.a, 0x1c)
        s.f = p                                  # start of the count/offset block
        s.name_count, s.name_off = struct.unpack_from('<ii', s.a, p + 4)
        s.export_count, s.export_off = struct.unpack_from('<ii', s.a, p + 0x14)
        # The tail of the summary is variable-width (generations, two FEngineVersions with a branch
        # FString each, two count-prefixed arrays), so walk it instead of assuming field positions.
        s.shift_i32 = [p + r for r in (0x10, 0x18, 0x20, 0x24, 0x2c, 0x30, 0x34)]   # offsets before the guid
        q = p + 0x38 + 16                                  # past FGuid
        gens, = struct.unpack_from('<i', s.a, q); q += 4 + gens * 8
        for _ in range(2):                                 # SavedBy / CompatibleWith engine version
            _, q = rd_fstr(s.a, q + 10)
        q += 4                                             # CompressionFlags
        nchunks, = struct.unpack_from('<i', s.a, q); q += 4
        assert nchunks == 0, 'compressed chunks in the summary are not supported'
        q += 4                                             # PackageSource
        nextra, = struct.unpack_from('<i', s.a, q); q += 4
        for _ in range(nextra):
            _, q = rd_fstr(s.a, q)
        s.off_assetregistry = q; q += 4
        s.off_bulkstart = q; q += 8
        s.off_worldtile = q; q += 4
        nchunkids, = struct.unpack_from('<i', s.a, q); q += 4 + nchunkids * 4
        q += 4                                             # PreloadDependencyCount
        s.off_preload = q
        s.shift_i32 += [s.off_assetregistry, s.off_worldtile, s.off_preload]
        s.names = []
        q = s.name_off
        for _ in range(s.name_count):
            nm, q = rd_fstr(s.a, q)
            q += 4
            s.names.append(nm)
        s.name_end = q
        s.exports = []
        for i in range(s.export_count):
            e = s.export_off + i * 104
            size, off = struct.unpack_from('<qq', s.a, e + 0x1c)
            s.exports.append({'entry': e, 'size': size, 'offset': off,
                              'name': s.names[struct.unpack_from('<i', s.a, e + 0x10)[0]]})

    # ── names ──
    def rename(s, pkg_map, leaf_map):
        """Retarget name-table strings STRUCTURALLY: whole package paths, `<package>.<object>` pairs,
        and bare object names. Never a substring swap -- a folder can share its name with an asset
        (Characters/Human/DiscipleoftheElements/DiscipleoftheElements), and a textual replace would
        rewrite the folder in the paths of assets that are not being cloned."""
        for i, nm in enumerate(s.names):
            if nm in pkg_map:
                s.names[i] = pkg_map[nm]
            elif '.' in nm and nm.split('.', 1)[0] in pkg_map:
                pkg, obj = nm.split('.', 1)
                s.names[i] = pkg_map[pkg] + '.' + s._obj(obj, leaf_map)
            else:
                s.names[i] = s._obj(nm, leaf_map)

    @staticmethod
    def _obj(nm, leaf_map):
        """A bare object name, including the generated-class and CDO spellings."""
        if nm in leaf_map:
            return leaf_map[nm]
        if nm.endswith('_C') and nm[:-2] in leaf_map:
            return leaf_map[nm[:-2]] + '_C'
        if nm.startswith('Default__') and nm.endswith('_C') and nm[9:-2] in leaf_map:
            return 'Default__' + leaf_map[nm[9:-2]] + '_C'
        return nm

    # ── properties ──
    def _walk(s, export_i):
        """Yield (prop_name, type_name, header_start, value_start, size) for one export."""
        e = s.exports[export_i]
        p = e['offset'] - s.hdr
        end = p + e['size']
        while p < end:
            start = p
            ni, _ = struct.unpack_from('<ii', s.x, p); p += 8
            name = s.names[ni] if 0 <= ni < len(s.names) else '?'
            if name == 'None':
                return
            ti, _ = struct.unpack_from('<ii', s.x, p); p += 8
            typ = s.names[ti] if 0 <= ti < len(s.names) else '?'
            size, _ = struct.unpack_from('<ii', s.x, p); p += 8
            if typ == 'StructProperty': p += 8 + 16
            elif typ in ('ArrayProperty', 'SetProperty'): p += 8
            elif typ == 'MapProperty': p += 16
            elif typ in ('ByteProperty', 'EnumProperty'): p += 8
            elif typ == 'BoolProperty': p += 1
            p += 1                                     # hasPropertyGuid
            yield name, typ, start, p, size
            p += size

    def get_text(s, export_i, prop_name):
        """(namespace, key, source) of an FText property, or None."""
        for name, typ, hstart, vstart, size in s._walk(export_i):
            if name == prop_name and typ == 'TextProperty':
                q = vstart + 5                       # u32 flags, i8 history type
                ns, q = rd_fstr(s.x, q)
                key, q = rd_fstr(s.x, q)
                src, q = rd_fstr(s.x, q)
                return ns, key, src
        return None

    def set_text(s, export_i, prop_name, namespace=None, key=None, source=None):
        """Rewrite an FText property's namespace/key/source. Returns the size delta (may be non-zero)."""
        for name, typ, hstart, vstart, size in list(s._walk(export_i)):
            if name != prop_name or typ != 'TextProperty':
                continue
            flags, = struct.unpack_from('<I', s.x, vstart)
            hist = s.x[vstart + 4]
            q = vstart + 5
            ns, q = rd_fstr(s.x, q)
            k, q = rd_fstr(s.x, q)
            src, q = rd_fstr(s.x, q)
            new = (struct.pack('<I', flags) + bytes([hist]) + _wr_fstr(namespace if namespace is not None else ns)
                   + _wr_fstr(key if key is not None else k) + _wr_fstr(source if source is not None else src))
            delta = len(new) - size
            s.x[vstart:vstart + size] = new
            struct.pack_into('<i', s.x, vstart - 9, len(new))   # the property's size field
            if delta:
                e = s.exports[export_i]
                e['size'] += delta
                struct.pack_into('<q', s.a, e['entry'] + 0x1c, e['size'])
                for other in s.exports:
                    if other['offset'] > e['offset']:
                        other['offset'] += delta
                        struct.pack_into('<q', s.a, other['entry'] + 0x24, other['offset'])
                bulk, = struct.unpack_from('<q', s.a, s.off_bulkstart)
                struct.pack_into('<q', s.a, s.off_bulkstart, bulk + delta)
            return delta
        raise KeyError(f'{prop_name} is not an FText on export {export_i}')

    def get_enum(s, export_i, prop_name):
        """The FName an EnumProperty currently points at."""
        for name, typ, hstart, vstart, size in s._walk(export_i):
            if name == prop_name and typ == 'EnumProperty':
                i, = struct.unpack_from('<i', s.x, vstart)
                return s.names[i] if 0 <= i < len(s.names) else f'<{i}>'
        return None

    def set_enum(s, export_i, prop_name, value):
        """Point an EnumProperty at `value` (e.g. EXRarity::Quest), adding the name if the asset does
        not already carry it. The value is an FName pair, so the property's size never changes."""
        for name, typ, hstart, vstart, size in list(s._walk(export_i)):
            if name == prop_name and typ == 'EnumProperty':
                if value not in s.names:
                    s.names.append(value)
                struct.pack_into('<ii', s.x, vstart, s.names.index(value), 0)
                return
        raise KeyError(f'{prop_name} is not an EnumProperty on export {export_i}')

    # ── emit ──
    def build(s):
        table = bytearray()
        for nm in s.names:
            table += _wr_fstr(nm)
            h1, h2 = name_hashes(nm)
            table += struct.pack('<HH', h1, h2)
        delta = len(table) - (s.name_end - s.name_off)
        out = bytearray(s.a[:s.name_off]) + table + s.a[s.name_end:]
        struct.pack_into('<i', out, s.f + 4, len(s.names))   # NameCount: set_enum may have added one
        if delta:
            struct.pack_into('<i', out, 0x18, s.hdr + delta)
            # every i32 offset that points past the name table, plus the i64 bulk start
            for pos in s.shift_i32:
                v, = struct.unpack_from('<i', out, pos)
                if v:
                    struct.pack_into('<i', out, pos, v + delta)
            bulk, = struct.unpack_from('<q', out, s.off_bulkstart)
            struct.pack_into('<q', out, s.off_bulkstart, bulk + delta)
            # the export table sits AFTER the name table, so its entries have moved by delta too
            for e in s.exports:
                struct.pack_into('<q', out, e['entry'] + delta + 0x24, e['offset'] + delta)
        return bytes(out), bytes(s.x)
