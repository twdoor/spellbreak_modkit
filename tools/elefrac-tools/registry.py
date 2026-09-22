"""Read and rewrite the cooked g3/AssetRegistry.bin.

UAssetManager::ScanPathsForPrimaryAssets only ever asks IAssetRegistry::GetAssets (verified by
disassembly at 0x213F7A0 — it never touches the filesystem), so this file is the sole authority on
which cosmetics exist. Assets added by a _P pak are invisible until they have a row here.

Format (FAssetRegistryVersion 6, an FNameTableArchive):

    [0x00] FGuid                       version guid
    [0x10] int32                       version (6)
    [0x14] int64                       offset of the name table
    [0x1c] int32                       asset count, then that many records
           ...                         dependency nodes + package data, copied through untouched
    [name table]  int32 count, then count * (FString + uint16 case-preserving hash + uint16 legacy hash)

A record is five FNames (ObjectPath, PackagePath, AssetClass, PackageName, AssetName), an int32 tag
count and that many (FName key, FString value) pairs, an int32 chunk count and that many int32s, and
a uint32 of package flags. An FName is a pair of int32s: an index into the name table and a number
(0 means "no numeric suffix").

Note the cooked registry keeps the EDITOR shape of a blueprint row: AssetClass is "Blueprint",
ObjectPath has no _C, and the generated class lives in a GeneratedClass tag. UAssetManager appends
the _C itself in GetAssetPathForData.

Dependency nodes index each other, not the asset array, so appending records is safe.
"""
import struct, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from efpak import name_hashes, rd_fstr


class Row:
    __slots__ = ('object_path', 'package_path', 'asset_class', 'package_name', 'asset_name',
                 'tags', 'chunks', 'flags')

    def __init__(s, **kw):
        for k in s.__slots__:
            setattr(s, k, kw.get(k))

    NAME_TAGS = ('PrimaryAssetName', 'BlueprintPath')

    def remap(s, new_package, pkg_map):
        """This row rewritten for a clone at `new_package`.

        Identity fields are rebuilt rather than substituted. Tag values get whole-path replacements
        only (longest first), plus a bare-name swap in the handful of tags that hold a bare asset name
        -- a bare substitution everywhere would corrupt the path of any SHARED asset that happens to
        sit in a folder named after a cloned one."""
        new_leaf = new_package.rsplit('/', 1)[1]
        paths = {}
        for old, new in pkg_map.items():
            o_leaf, n_leaf = old.rsplit('/', 1)[1], new.rsplit('/', 1)[1]
            paths[f'{old}.{o_leaf}_C'] = f'{new}.{n_leaf}_C'
            paths[f'{old}.{o_leaf}'] = f'{new}.{n_leaf}'
            paths[old] = new
        leaves = {old.rsplit('/', 1)[1]: new.rsplit('/', 1)[1] for old, new in pkg_map.items()}

        def sub(key, v):
            for old in sorted(paths, key=len, reverse=True):
                v = v.replace(old, paths[old])
            if key in s.NAME_TAGS:
                v = leaves.get(v, v)
            return v

        return Row(object_path=f'{new_package}.{new_leaf}', package_path=new_package.rsplit('/', 1)[0],
                   asset_class=s.asset_class, package_name=new_package, asset_name=new_leaf,
                   tags=[(k, sub(k, v)) for k, v in s.tags], chunks=list(s.chunks), flags=s.flags)

    def clone(s, old, new):
        """A copy with `old` swapped for `new` everywhere: paths, names and tag values alike.

        The same token swap the asset clone itself uses, so the row lands on the cloned packages:
        GeneratedClass, BlueprintPath, PrimaryAssetName and every path inside AssetBundleData all
        follow along, while NativeParentClass and the like are untouched because they never mention
        the skin."""
        sub = lambda v: v.replace(old, new)
        return Row(object_path=sub(s.object_path), package_path=sub(s.package_path),
                   asset_class=s.asset_class, package_name=sub(s.package_name),
                   asset_name=sub(s.asset_name),
                   tags=[(k, sub(v)) for k, v in s.tags], chunks=list(s.chunks), flags=s.flags)

    def __repr__(s):
        return f'<Row {s.object_path} class={s.asset_class} tags={len(s.tags)}>'


class Registry:
    def __init__(s, path_or_bytes):
        b = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else open(path_or_bytes, 'rb').read()
        s.b = bytes(b)
        s.version, = struct.unpack_from('<i', s.b, 0x10)
        s.name_off, = struct.unpack_from('<q', s.b, 0x14)
        # name table
        s.names = []
        p = s.name_off
        n, = struct.unpack_from('<i', s.b, p); p += 4
        for _ in range(n):
            nm, p = rd_fstr(s.b, p)
            p += 4
            s.names.append(nm)
        s.name_index = {nm.lower(): i for i, nm in enumerate(s.names)}
        # records
        s.count, = struct.unpack_from('<i', s.b, 0x1c)
        s.records_start = 0x20
        s.rows = []
        p = s.records_start
        for _ in range(s.count):
            row, p = s._read_row(p)
            s.rows.append(row)
        s.records_end = p
        s.tail = s.b[p:s.name_off]          # dependency nodes + package data, copied verbatim
        s.by_object_path = {r.object_path.lower(): r for r in s.rows}

    # ── read ──
    def _name(s, p):
        i, num = struct.unpack_from('<ii', s.b, p)
        nm = s.names[i] if 0 <= i < len(s.names) else f'<{i}>'
        return (nm if num == 0 else f'{nm}_{num - 1}'), p + 8

    def _read_row(s, p):
        f = []
        for _ in range(5):
            v, p = s._name(p); f.append(v)
        ntags, = struct.unpack_from('<i', s.b, p); p += 4
        tags = []
        for _ in range(ntags):
            k, p = s._name(p)
            v, p = rd_fstr(s.b, p)
            tags.append((k, v))
        nchunk, = struct.unpack_from('<i', s.b, p); p += 4
        chunks = list(struct.unpack_from(f'<{nchunk}i', s.b, p)) if nchunk else []
        p += nchunk * 4
        flags, = struct.unpack_from('<I', s.b, p); p += 4
        return Row(object_path=f[0], package_path=f[1], asset_class=f[2], package_name=f[3],
                   asset_name=f[4], tags=tags, chunks=chunks, flags=flags), p

    # ── write ──
    def _intern(s, nm):
        i = s.name_index.get(nm.lower())
        if i is None:
            i = len(s.names)
            s.names.append(nm)
            s.name_index[nm.lower()] = i
        return i

    def _emit_name(s, out, nm):
        out += struct.pack('<ii', s._intern(nm), 0)

    def _emit_row(s, out, r):
        for v in (r.object_path, r.package_path, r.asset_class, r.package_name, r.asset_name):
            s._emit_name(out, v)
        out += struct.pack('<i', len(r.tags))
        for k, v in r.tags:
            s._emit_name(out, k)
            e = v.encode('utf8')
            out += struct.pack('<i', len(e) + 1) + e + b'\x00'
        out += struct.pack('<i', len(r.chunks))
        for c in r.chunks:
            out += struct.pack('<i', c)
        out += struct.pack('<I', r.flags)

    def save(s, out_path, extra_rows):
        """Rewrite the file with `extra_rows` appended to the asset array."""
        body = bytearray()
        body += struct.pack('<i', s.count + len(extra_rows))
        body += s.b[s.records_start:s.records_end]      # existing rows, byte for byte
        for r in extra_rows:
            s._emit_row(body, r)                        # may intern new names
        body += s.tail
        names = bytearray()
        names += struct.pack('<i', len(s.names))
        for nm in s.names:
            e = nm.encode('utf8')
            names += struct.pack('<i', len(e) + 1) + e + b'\x00'
            h1, h2 = name_hashes(nm)
            names += struct.pack('<HH', h1, h2)
        head = bytearray(s.b[:0x1c])
        struct.pack_into('<q', head, 0x14, 0x1c + len(body))
        with open(out_path, 'wb') as fh:
            fh.write(bytes(head)); fh.write(bytes(body)); fh.write(bytes(names))
        return 0x1c + len(body) + len(names)


if __name__ == '__main__':
    r = Registry(sys.argv[1])
    print(f'version={r.version} assets={r.count} names={len(r.names)} tail={len(r.tail)} B')
    for pat in sys.argv[2:]:
        for row in r.rows:
            if pat.lower() in row.object_path.lower():
                print(row)
                for k, v in row.tags:
                    print(f'    {k} = {v[:150]}')
