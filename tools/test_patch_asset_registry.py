#!/usr/bin/env python3
"""Regression checks for multi-record Asset Registry cloning."""

from __future__ import annotations

import importlib.util
import struct
import sys
import tempfile
from pathlib import Path


SCRIPT = (Path(__file__).resolve().parents[1] / "spellbreak_uasset_editor"
          / "asset_registry" / "patch_asset_registry.py")
spec = importlib.util.spec_from_file_location("registry_patcher", SCRIPT)
assert spec and spec.loader
patcher = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = patcher
spec.loader.exec_module(patcher)


def fname(index: int) -> bytes:
    return struct.pack("<ii", index, 0)


def build_registry(path: Path) -> None:
    names = ["Old", "/Game/Items", "Blueprint", "/Game/Items/Old", "GeneratedClass"]
    record = b"".join(fname(index) for index in [0, 1, 2, 3, 0])
    record += struct.pack("<i", 1) + fname(4)
    record += patcher.encode_fstring("/Game/Items/Old.Old_C")
    record += struct.pack("<ii", 0, 0)
    dependencies = struct.pack("<i", 0)
    name_offset = 32 + len(record) + len(dependencies)
    header = (patcher.REGISTRY_GUID + struct.pack("<i", 6)
              + struct.pack("<q", name_offset) + struct.pack("<i", 1))
    name_table = struct.pack("<i", len(names)) + b"".join(
        patcher.encode_fstring(name) + patcher.name_hashes(name) for name in names)
    path.write_bytes(header + record + dependencies + name_table)


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        source = root / "source.bin"
        output = root / "output.bin"
        build_registry(source)
        operations = [
            {"source": "/Game/Items/Old.Old", "target": "/Game/New/LongName.LongName"},
            {"source": "/Game/Items/Old.Old", "target": "/Game/New/Other_6.Other_6"},
            {"source": "/Game/Items/Old.Old", "target": "/Game/Older/Old_New.Old_New"},
        ]
        patcher.patch_registry_many(source, output, operations)
        data = output.read_bytes()
        offset = struct.unpack_from("<q", data, 20)[0]
        names, _ = patcher.parse_names(data, offset)
        records, _ = patcher.parse_assets(data, names, offset)
        paths = {record.object_path for record in records}
        assert len(records) == 4
        assert "/Game/New/LongName.LongName" in paths
        assert "/Game/New/Other_6.Other_6" in paths
        # The target package contains the source asset name as a substring; it
        # must not be rewritten again by the bare-asset pass.
        assert "/Game/Older/Old_New.Old_New" in paths
        assert "/Game/Older/Old_New_New.Old_New" not in paths
    print("PASS: Asset Registry patcher regression tests")


if __name__ == "__main__":
    main()
