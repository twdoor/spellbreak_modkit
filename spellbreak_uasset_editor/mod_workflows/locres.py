"""Spellbreak localization resources (legacy, compact, and optimized UE4 formats).

Format reference: https://github.com/akintos/UnrealLocres (LocresLib/LocresFile.cs).
Only v0-v2 are accepted; output is optimized v2, as used by Spellbreak's cook.
"""
import io
import struct
import zlib

MAGIC = bytes.fromhex('0e147475674a03fc4a15909dc3377f1b')


def crc(text):
    return zlib.crc32(text.encode('utf-32-le')) & 0xffffffff


class Reader:
    def __init__(self, data):
        self.f = io.BytesIO(data)

    def read(self, n):
        if n < 0:
            raise ValueError('Negative localization field size')
        data = self.f.read(n)
        if len(data) != n:
            raise ValueError('Truncated localization resource')
        return data

    def number(self, fmt='i'):
        return struct.unpack('<' + fmt, self.read(struct.calcsize('<' + fmt)))[0]

    def count(self):
        count = self.number()
        if not 0 <= count <= 1000000:
            raise ValueError('Invalid localization entry count')
        return count

    def string(self):
        length = self.number()
        if not length:
            return ''
        raw = self.read(abs(length) * (2 if length < 0 else 1))
        end = b'\0\0' if length < 0 else b'\0'
        if not raw.endswith(end):
            raise ValueError('Unterminated localization string')
        return raw[:-len(end)].decode('utf-16-le' if length < 0 else 'utf-8')


def string(text):
    if text.isascii():
        data = text.encode('ascii') + b'\0'
        return struct.pack('<i', len(data)) + data
    data = text.encode('utf-16-le') + b'\0\0'
    return struct.pack('<i', -(len(data) // 2)) + data


def loads(data):
    r = Reader(data)
    version = 0
    if data.startswith(MAGIC):
        r.read(16)
        version = r.number('B')
    if version not in (0, 1, 2):
        raise ValueError(f'Unsupported locres version: {version}')
    strings = []
    if version >= 1:
        offset = r.number('q')
        pos = r.f.tell()
        if not pos <= offset <= len(data) - 4:
            raise ValueError('Invalid localization string table offset')
        r.f.seek(offset)
        for _ in range(r.count()):
            strings.append(r.string())
            if version >= 2:
                r.number()  # reference count
        r.f.seek(pos)
    if version >= 2:
        r.count()  # total entries
    rows = {}
    for _ in range(r.count()):
        if version >= 2:
            r.number('I')  # namespace hash
        namespace = r.string()
        for _ in range(r.count()):
            if version >= 2:
                r.number('I')  # key hash
            key, source_hash = r.string(), r.number('I')
            if version >= 1:
                idx = r.number()
                if not 0 <= idx < len(strings):
                    raise ValueError('Invalid localization string index')
                text = strings[idx]
            else:
                text = r.string()
            if (namespace, key) in rows:
                raise ValueError('Duplicate localization key')
            rows[namespace, key] = (source_hash, text)
    return rows


def dumps(rows):
    groups, texts, indexes, refs = {}, [], {}, []
    for (namespace, key), (source_hash, text) in rows.items():
        groups.setdefault(namespace, []).append((key, source_hash, text))
        if text not in indexes:
            indexes[text] = len(texts)
            texts.append(text)
            refs.append(0)
        refs[indexes[text]] += 1
    body = bytearray(struct.pack('<ii', len(rows), len(groups)))
    for namespace, entries in groups.items():
        body += struct.pack('<I', crc(namespace)) + string(namespace) + struct.pack('<i', len(entries))
        for key, source_hash, text in entries:
            body += struct.pack('<I', crc(key)) + string(key) + struct.pack('<Ii', source_hash, indexes[text])
    table = bytearray(struct.pack('<i', len(texts)))
    for text, count in zip(texts, refs):
        table += string(text) + struct.pack('<i', count)
    return MAGIC + struct.pack('<Bq', 2, 25 + len(body)) + body + table
