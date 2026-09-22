"""UE4 .pak reader/writer + cooked .uasset name-table surgery for Spellbreak.

Covers exactly what the EF cosmetic clone needs:
  - read any of the game's paks (base g3-WindowsNoEditor.pak is v8 with a 1-byte compression
    method index; the _P override paks are v3 with a 4-byte one, zlib compressed, unencrypted)
  - write a v3 zlib pak byte-compatible with ElefracBalance_P.pak (proven to mount at startup)
  - rename a package inside a cooked .uasset by rewriting name-table strings in place

The rename is deliberately restricted to EQUAL-LENGTH tokens: every cross-package reference in
these assets is a plain name-table string, so a same-length swap leaves every offset in the
summary, the export map and the bulk-data pointers untouched. Only the two 16-bit name hashes
have to be recomputed.
"""
import struct, zlib, os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

KEY = bytes([0x1E,0xF7,0x62,0x16,0xB7,0xC1,0xAC,0x26,0x91,0xCE,0x90,0xAF,0x93,0xB3,0x71,0x0F,
             0x85,0x6C,0xC5,0x89,0xD8,0x7A,0x02,0x84,0x9E,0x0F,0x21,0x3E,0xED,0x3C,0x86,0xB5])
MAGIC = 0x5A6F12E1
MOUNT_POINT = '../../../'
BLOCK_SIZE = 65536


def _dec(b):
    c = Cipher(algorithms.AES(KEY), modes.ECB()).decryptor()
    return c.update(b) + c.finalize()


def rd_fstr(b, p):
    l, = struct.unpack_from('<i', b, p); p += 4
    if l >= 0:
        return b[p:p + l - 1].decode('utf8', 'replace'), p + l
    n = -l
    return b[p:p + (n - 1) * 2].decode('utf-16-le', 'replace'), p + n * 2


def wr_fstr(buf, s):
    e = s.encode('utf8')
    buf += struct.pack('<i', len(e) + 1) + e + b'\x00'


# ── name hashes (see project_pak_toolchain) ────────────────────────────────────────────────
def _crc32_utf32(s):
    """FCrc::StrCrc32: standard CRC32 over the string as UTF-32LE, init/xorout 0xFFFFFFFF."""
    return zlib.crc32(s.encode('utf-32-le')) & 0xFFFFFFFF


_STRIHASH_TBL = None


def _strihash(s):
    """FCrc::Strihash_DEPRECATED: legacy non-reflected table, right-shift update, uppercased."""
    global _STRIHASH_TBL
    if _STRIHASH_TBL is None:
        tbl = []
        for i in range(256):
            c = i << 24
            for _ in range(8):
                c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
            tbl.append(c)
        _STRIHASH_TBL = tbl
    h = 0
    for ch in s.upper():
        h = ((h >> 8) & 0x00FFFFFF) ^ _STRIHASH_TBL[(h ^ ord(ch)) & 0xFF]
    return h & 0xFFFFFFFF


def name_hashes(s):
    """(first, second) as they are serialized after a cooked name-table FString."""
    return _strihash(s) & 0xFFFF, _crc32_utf32(s) & 0xFFFF


# ── pak ────────────────────────────────────────────────────────────────────────────────────
class Pak:
    def __init__(s, path):
        s.path = path
        s.f = open(path, 'rb')
        s.f.seek(0, 2); sz = s.f.tell()
        s.f.seek(max(0, sz - 221)); tail = s.f.read(221)
        cand = [o for o in range(len(tail) - 8) if struct.unpack_from('<I', tail, o)[0] == MAGIC]
        if not cand:
            raise ValueError(f'{path}: no pak magic')
        off = cand[-1]
        s.ver, = struct.unpack_from('<I', tail, off + 4)
        s.ioff, s.isz = struct.unpack_from('<QQ', tail, off + 8)
        s.encidx = s.ver >= 4 and tail[off - 1] == 1
        s.cm_u8 = s.ver >= 8          # this game's v8 paks store the method index in one byte
        s.f.seek(s.ioff); idx = s.f.read(s.isz)
        if s.encidx:
            idx = _dec(idx)
        s.entries = {}
        s.mount, p = rd_fstr(idx, 0)
        cnt, = struct.unpack_from('<i', idx, p); p += 4
        for _ in range(cnt):
            nm, p = rd_fstr(idx, p)
            e, p = s._rd_entry(idx, p)
            s.entries[nm] = e

    def _rd_entry(s, b, p):
        o, cs, us = struct.unpack_from('<QQQ', b, p); p += 24
        if s.cm_u8:
            cm = b[p]; p += 1
        else:
            cm, = struct.unpack_from('<I', b, p); p += 4
        p += 20
        blocks = []
        if cm != 0:
            nb, = struct.unpack_from('<i', b, p); p += 4
            for _ in range(nb):
                blocks.append(struct.unpack_from('<QQ', b, p)); p += 16
        encf = b[p]; p += 1
        bsz, = struct.unpack_from('<I', b, p); p += 4
        return (o, cs, us, cm, encf, blocks, bsz), p

    def hdrsize(s, cm, nb):
        n = 24 + (1 if s.cm_u8 else 4) + 20
        if cm != 0:
            n += 4 + 16 * nb
        return n + 1 + 4

    def get(s, nm):
        o, cs, us, cm, encf, blocks, bsz = s.entries[nm]
        if cm == 0:
            s.f.seek(o + s.hdrsize(cm, 0))
            d = s.f.read((cs + 15) // 16 * 16 if encf else cs)
            if encf:
                d = _dec(d)
            return d[:us]
        out = b''
        for bs, be in blocks:
            start = bs if bs >= o else o + bs      # absolute in this game's paks
            n = be - bs
            s.f.seek(start)
            d = s.f.read((n + 15) // 16 * 16 if encf else n)
            if encf:
                d = _dec(d)
            out += zlib.decompress(d[:n])
        return out[:us]

    def raw_record(s, nm):
        """The entry's on-disk bytes (inline header + data), for verbatim repacking."""
        o, cs, us, cm, encf, blocks, bsz = s.entries[nm]
        hs = s.hdrsize(cm, len(blocks))
        end = max(be for _, be in blocks) if blocks else o + hs + cs
        s.f.seek(o)
        return s.f.read(end - o)


def _sha1(data):
    import hashlib
    return hashlib.sha1(data).digest()


def _entry_bytes(offset, cs, us, cm, hsh, blocks, bsz):
    b = bytearray()
    b += struct.pack('<QQQ', offset, cs, us)
    b += struct.pack('<I', cm)
    b += hsh
    if cm != 0:
        b += struct.pack('<i', len(blocks))
        for bs, be in blocks:
            b += struct.pack('<QQ', bs, be)
    b += b'\x00'
    b += struct.pack('<I', bsz)
    return bytes(b)


def write_pak(out_path, files, compress=True):
    """files: list of (internal_path, data). Writes a v3 zlib pak like ElefracBalance_P.pak."""
    body = bytearray()
    index_entries = []
    for internal, data in files:
        us = len(data)
        hsh = _sha1(data)
        if compress:
            chunks = [zlib.compress(data[i:i + BLOCK_SIZE], 9) for i in range(0, us, BLOCK_SIZE)] or [zlib.compress(b'', 9)]
            cs = sum(len(c) for c in chunks)
            rec_off = len(body)
            hdr_len = 24 + 4 + 20 + 4 + 16 * len(chunks) + 1 + 4
            blocks, cur = [], rec_off + hdr_len
            for c in chunks:
                blocks.append((cur, cur + len(c))); cur += len(c)
            hdr = _entry_bytes(rec_off, cs, us, 1, hsh, blocks, BLOCK_SIZE)
            assert len(hdr) == hdr_len, (len(hdr), hdr_len)
            body += hdr
            for c in chunks:
                body += c
            index_entries.append((internal, _entry_bytes(rec_off, cs, us, 1, hsh, blocks, BLOCK_SIZE)))
        else:
            rec_off = len(body)
            hdr = _entry_bytes(rec_off, us, us, 0, hsh, [], us)
            body += hdr + data
            index_entries.append((internal, _entry_bytes(rec_off, us, us, 0, hsh, [], us)))
    index = bytearray()
    wr_fstr(index, MOUNT_POINT)
    index += struct.pack('<i', len(index_entries))
    for internal, eb in index_entries:
        wr_fstr(index, internal)
        index += eb
    idx_off = len(body)
    footer = struct.pack('<IIQQ', MAGIC, 3, idx_off, len(index)) + _sha1(bytes(index))
    with open(out_path, 'wb') as fh:
        fh.write(bytes(body)); fh.write(bytes(index)); fh.write(footer)
    return idx_off + len(index) + len(footer)


def repack(src_pak, out_path, drop=(), add=()):
    """Rebuild a pak, dropping entries by exact internal path and appending (path, data) pairs.

    Existing records are copied verbatim (compression preserved); only the offsets inside the
    inline header, the block list and the index entry are rebased."""
    p = Pak(src_pak)
    drop = set(drop)
    add = list(add)
    # v8 records have a different header layout; encrypted records also cannot
    # be copied into the unencrypted v3 output. Decode and serialize them anew.
    if p.ver != 3 or any(e[4] for e in p.entries.values()):
        try:
            files = {nm: p.get(nm) for nm in p.entries if nm not in drop}
            files.update(add)
            write_pak(out_path, list(files.items()))
            return len(files)
        finally:
            p.f.close()
    body = bytearray()
    index_entries = []
    for nm, e in p.entries.items():
        if nm in drop:
            continue
        o, cs, us, cm, encf, blocks, bsz = e
        rec = bytearray(p.raw_record(nm))
        new_off = len(body)
        delta = new_off - o
        struct.pack_into('<Q', rec, 0, new_off)
        nblocks = []
        if cm != 0:
            bp = 24 + (1 if p.cm_u8 else 4) + 20
            nb, = struct.unpack_from('<i', rec, bp); bp += 4
            for i in range(nb):
                bs, be = struct.unpack_from('<QQ', rec, bp + i * 16)
                bs += delta; be += delta
                struct.pack_into('<QQ', rec, bp + i * 16, bs, be)
                nblocks.append((bs, be))
        body += rec
        index_entries.append((nm, _entry_bytes(new_off, cs, us, cm, b'\x00' * 20, nblocks, bsz)))
        # keep the original hash bytes from the record header
        hs_off = 24 + (1 if p.cm_u8 else 4)
        index_entries[-1] = (nm, index_entries[-1][1][:hs_off] + bytes(rec[hs_off:hs_off + 20]) + index_entries[-1][1][hs_off + 20:])
    for internal, data in add:
        us = len(data)
        hsh = _sha1(data)
        chunks = [zlib.compress(data[i:i + BLOCK_SIZE], 9) for i in range(0, us, BLOCK_SIZE)] or [zlib.compress(b'', 9)]
        cs = sum(len(c) for c in chunks)
        rec_off = len(body)
        hdr_len = 24 + 4 + 20 + 4 + 16 * len(chunks) + 1 + 4
        blocks, cur = [], rec_off + hdr_len
        for c in chunks:
            blocks.append((cur, cur + len(c))); cur += len(c)
        hdr = _entry_bytes(rec_off, cs, us, 1, hsh, blocks, BLOCK_SIZE)
        body += hdr
        for c in chunks:
            body += c
        index_entries.append((internal, hdr))
    index = bytearray()
    wr_fstr(index, p.mount)
    index += struct.pack('<i', len(index_entries))
    for internal, eb in index_entries:
        wr_fstr(index, internal)
        index += eb
    idx_off = len(body)
    footer = struct.pack('<IIQQ', MAGIC, 3, idx_off, len(index)) + _sha1(bytes(index))
    with open(out_path, 'wb') as fh:
        fh.write(bytes(body)); fh.write(bytes(index)); fh.write(footer)
    p.f.close()
    return len(index_entries)


# ── cooked .uasset name table ──────────────────────────────────────────────────────────────
class NameTable:
    """Parsed name table of a cooked .uasset (FileVersionUE4 = 0)."""

    def __init__(s, b):
        s.b = bytearray(b)
        s.count, = struct.unpack_from('<i', s.b, 0x29)
        s.off, = struct.unpack_from('<i', s.b, 0x2d)
        s.names = []          # (index, file_offset, string, total_entry_len)
        p = s.off
        for i in range(s.count):
            start = p
            nm, p = rd_fstr(s.b, p)
            p += 4
            s.names.append((i, start, nm, p - start))

    def replace_token(s, old, new):
        """Swap an equal-length token in every name-table string that contains it."""
        if len(old) != len(new):
            raise ValueError(f'token length differs: {old!r} -> {new!r}')
        hits = 0
        for i, start, nm, ln in s.names:
            if old not in nm:
                continue
            repl = nm.replace(old, new)
            l, = struct.unpack_from('<i', s.b, start)
            if l < 0:
                raise ValueError(f'utf16 name entry not supported: {nm!r}')
            enc = repl.encode('utf8')
            if len(enc) + 1 != l:
                raise ValueError(f'length changed for {nm!r}')
            s.b[start + 4:start + 4 + len(enc)] = enc
            h1, h2 = name_hashes(repl)
            struct.pack_into('<HH', s.b, start + 4 + l, h1, h2)
            hits += 1
        return hits

    def replace_map(s, mapping):
        """Apply {old: new} to every name-table string, longest key first. All pairs must be
        equal-length: this rewrites in place so nothing in the asset moves."""
        for old, new in mapping.items():
            if len(old) != len(new):
                raise ValueError(f'not equal length: {old!r} -> {new!r}')
        hits = 0
        for i, start, nm, ln in s.names:
            out = nm
            for old in sorted(mapping, key=len, reverse=True):
                out = out.replace(old, mapping[old])
            if out == nm:
                continue
            l, = struct.unpack_from('<i', s.b, start)
            enc = out.encode('utf8')
            s.b[start + 4:start + 4 + len(enc)] = enc
            h1, h2 = name_hashes(out)
            struct.pack_into('<HH', s.b, start + 4 + l, h1, h2)
            hits += 1
        return hits

    def data(s):
        return bytes(s.b)
