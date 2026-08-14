#!/usr/bin/env python3
"""Build a Spellbreak UE4.22 AssetRegistry with cloned asset records."""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


REGISTRY_GUID = bytes.fromhex("e79e7f713a49b0e93291b3880781381b")
SUPPORTED_VERSION = 6


class RegistryError(ValueError):
    pass


def i32(data: bytes, off: int) -> int:
    return struct.unpack_from("<i", data, off)[0]


def read_fstring(data: bytes, off: int, limit: int) -> tuple[str, int]:
    if off + 4 > limit:
        raise RegistryError("truncated FString length")
    length = i32(data, off)
    off += 4
    if length == 0:
        return "", off
    byte_len = length if length > 0 else -length * 2
    if off + byte_len > limit:
        raise RegistryError(f"invalid FString length {length}")
    raw = data[off : off + byte_len]
    if length > 0:
        if raw[-1:] != b"\0":
            raise RegistryError("ANSI FString lacks terminator")
        value = raw[:-1].decode("utf-8")
    else:
        if raw[-2:] != b"\0\0":
            raise RegistryError("UTF-16 FString lacks terminator")
        value = raw[:-2].decode("utf-16-le")
    return value, off + byte_len


def encode_fstring(value: str, wide: bool = False) -> bytes:
    if wide:
        raw = value.encode("utf-16-le") + b"\0\0"
        return struct.pack("<i", -(len(raw) // 2)) + raw
    raw = value.encode("utf-8") + b"\0"
    return struct.pack("<i", len(raw)) + raw


@dataclass
class AssetRecord:
    start: int
    end: int
    object_path: str


def parse_names(data: bytes, name_offset: int) -> tuple[list[str], list[bytes]]:
    count = i32(data, name_offset)
    if count < 0:
        raise RegistryError("negative name count")
    off = name_offset + 4
    names: list[str] = []
    entries: list[bytes] = []
    for _ in range(count):
        start = off
        name, off = read_fstring(data, off, len(data))
        if off + 4 > len(data):
            raise RegistryError("truncated serialized name hashes")
        off += 4
        names.append(name)
        entries.append(data[start:off])
    if off != len(data):
        raise RegistryError(f"unexpected {len(data) - off} bytes after name table")
    return names, entries


def parse_fname(data: bytes, off: int, limit: int, names: list[str]) -> tuple[str, int]:
    if off + 8 > limit:
        raise RegistryError("truncated FName")
    index, number = struct.unpack_from("<ii", data, off)
    if not 0 <= index < len(names) or number < 0:
        raise RegistryError(f"invalid FName ({index}, {number}) at 0x{off:x}")
    suffix = "" if number == 0 else f"_{number - 1}"
    return names[index] + suffix, off + 8


def parse_assets(data: bytes, names: list[str], name_offset: int) -> tuple[list[AssetRecord], int]:
    count = i32(data, 28)
    if count < 0:
        raise RegistryError("negative asset count")
    off = 32
    records: list[AssetRecord] = []
    for _ in range(count):
        start = off
        fields: list[str] = []
        for _field in range(5):
            value, off = parse_fname(data, off, name_offset, names)
            fields.append(value)
        if off + 4 > name_offset:
            raise RegistryError("truncated tag count")
        tag_count = i32(data, off)
        off += 4
        if tag_count < 0 or tag_count > 1_000_000:
            raise RegistryError(f"invalid tag count {tag_count}")
        for _tag in range(tag_count):
            _, off = parse_fname(data, off, name_offset, names)
            _, off = read_fstring(data, off, name_offset)
        if off + 4 > name_offset:
            raise RegistryError("truncated chunk count")
        chunk_count = i32(data, off)
        off += 4
        if chunk_count < 0 or off + chunk_count * 4 + 4 > name_offset:
            raise RegistryError(f"invalid chunk count {chunk_count}")
        off += chunk_count * 4 + 4
        records.append(AssetRecord(start, off, f"{fields[3]}.{fields[4]}"))
    if off + 4 > name_offset or i32(data, off) < 0:
        raise RegistryError("invalid dependency section after asset array")
    return records, off


def make_crc_table() -> list[int]:
    table = []
    for n in range(256):
        crc = n << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
        table.append(crc)
    return table


CRC_TABLE = make_crc_table()


def name_hashes(value: str) -> bytes:
    legacy = 0
    for char in value:
        code = ord(char)
        if 128 <= code < 256:
            code = (code - 256) & 0xFFFF
        if ord("a") <= code <= ord("z"):
            code -= 32
        for byte in chr(code).encode("utf-8"):
            legacy = ((legacy >> 8) & 0x00FFFFFF) ^ CRC_TABLE[(legacy ^ byte) & 0xFF]
    crc = 0xFFFFFFFF
    for byte in value.encode("utf-32-le"):
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return struct.pack("<HH", legacy & 0xFFFF, (~crc) & 0xFFFF)


def rewrite_identity(value: str, old: str, new: str) -> str:
    old_package, old_asset = old.rsplit(".", 1)
    new_package, new_asset = new.rsplit(".", 1)
    old_dir = old_package.rsplit("/", 1)[0]
    new_dir = new_package.rsplit("/", 1)[0]
    if value == old_dir:
        return new_dir
    return value.replace(old_package, new_package).replace(old_asset, new_asset)


def encode_fname(value: str, names: list[str], name_to_index: dict[str, int],
                 added_names: list[str]) -> bytes:
    suffix = re.fullmatch(r"(.*)_([0-9]+)", value)
    base = suffix.group(1) if suffix else value
    number = int(suffix.group(2)) + 1 if suffix else 0
    if base not in name_to_index:
        name_to_index[base] = len(names) + len(added_names)
        added_names.append(base)
    return struct.pack("<ii", name_to_index[base], number)


def clone_record(data: bytes, record: AssetRecord, names: list[str], old: str, new: str,
                 name_to_index: dict[str, int], added_names: list[str]) -> bytes:
    off = record.start
    output = bytearray()
    for _field in range(5):
        value, off = parse_fname(data, off, record.end, names)
        output += encode_fname(rewrite_identity(value, old, new), names,
                               name_to_index, added_names)
    tag_count = i32(data, off)
    output += data[off : off + 4]
    off += 4
    for _tag in range(tag_count):
        key, off = parse_fname(data, off, record.end, names)
        output += encode_fname(rewrite_identity(key, old, new), names,
                               name_to_index, added_names)
        string_start = off
        was_wide = i32(data, off) < 0
        value, off = read_fstring(data, off, record.end)
        rewritten = rewrite_identity(value, old, new)
        output += data[string_start:off] if rewritten == value else encode_fstring(rewritten, was_wide)
    output += data[off : record.end]
    return bytes(output)


def patch_registry_many(source: Path, output: Path,
                        operations: list[dict[str, str]]) -> None:
    data = source.read_bytes()
    if len(data) < 32 or data[:16] != REGISTRY_GUID:
        raise RegistryError("not a Spellbreak AssetRegistry.bin")
    version = i32(data, 16)
    if version != SUPPORTED_VERSION:
        raise RegistryError(f"requires Asset Registry version 6, got {version}")
    name_offset = struct.unpack_from("<q", data, 20)[0]
    if not 32 <= name_offset < len(data):
        raise RegistryError(f"invalid name-table offset 0x{name_offset:x}")
    names, entries = parse_names(data, name_offset)
    records, assets_end = parse_assets(data, names, name_offset)
    by_path = {record.object_path: record for record in records}
    if len(by_path) != len(records):
        raise RegistryError("source registry contains duplicate object paths")
    targets: set[str] = set()
    normalized: list[tuple[str, str]] = []
    for operation in operations:
        old = str(operation.get("source", ""))
        new = str(operation.get("target", ""))
        if not old or not new or "." not in old or "." not in new:
            raise RegistryError("every operation needs source and target ObjectPaths")
        if old not in by_path:
            raise RegistryError(f"source asset was not found: '{old}'")
        if new in by_path:
            raise RegistryError(f"target asset already exists: '{new}'")
        if new in targets:
            raise RegistryError(f"duplicate target asset: '{new}'")
        targets.add(new)
        normalized.append((old, new))

    name_to_index = {name: index for index, name in enumerate(names)}
    added_names: list[str] = []
    clones = b"".join(clone_record(data, by_path[old], names, old, new,
                                   name_to_index, added_names)
                      for old, new in normalized)
    new_entries = b"".join(encode_fstring(name) + name_hashes(name) for name in added_names)
    out = bytearray(data[:assets_end] + clones + data[assets_end:name_offset])
    out += struct.pack("<i", len(names) + len(added_names))
    out += b"".join(entries) + new_entries
    struct.pack_into("<i", out, 28, len(records) + len(normalized))
    struct.pack_into("<q", out, 20, name_offset + len(clones))

    check_offset = struct.unpack_from("<q", out, 20)[0]
    check_names, _ = parse_names(out, check_offset)
    check_records, _ = parse_assets(out, check_names, check_offset)
    check_paths = {record.object_path for record in check_records}
    missing = targets - check_paths
    if missing:
        raise RegistryError(f"internal verification missed targets: {sorted(missing)!r}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(out)
    print(f"Validated {len(records):,} source assets and {len(names):,} names")
    print(f"Cloned {len(normalized)} asset record(s); added {len(added_names)} names")
    print(f"Wrote {output} ({len(out):,} bytes)")


def patch_registry(source: Path, output: Path, old: str, new: str) -> None:
    patch_registry_many(source, output, [{"source": old, "target": new}])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--operations", type=Path)
    parser.add_argument("--old")
    parser.add_argument("--new")
    args = parser.parse_args()
    try:
        if args.operations:
            parsed = json.loads(args.operations.read_text(encoding="utf-8"))
            operations = parsed.get("custom_assets", []) if isinstance(parsed, dict) else parsed
            if not isinstance(operations, list) or not operations:
                raise RegistryError("operations JSON contains no custom assets")
            patch_registry_many(args.source, args.output, operations)
        elif args.old and args.new:
            patch_registry(args.source, args.output, args.old, args.new)
        else:
            parser.error("use --operations or both --old and --new")
    except (OSError, RegistryError, UnicodeError, json.JSONDecodeError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
