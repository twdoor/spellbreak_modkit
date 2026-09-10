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
    names = ["Old", "/Game/Items", "Blueprint", "/Game/Items/Old", "GeneratedClass",
             "AssetBundleData", "Data", "/Game/Items/Data", "PrimaryAssetType"]
    record = b"".join(fname(index) for index in [0, 1, 2, 3, 0])
    record += struct.pack("<i", 2) + fname(4)
    record += patcher.encode_fstring("/Game/Items/Old.Old_C")
    record += fname(5) + patcher.encode_fstring(
        '(Bundles=((BundleName="Equipped",BundleAssets=('
        '/Game/Items/Data.Data,/Game/Items/Old_Base.Old_Base))))')
    record += struct.pack("<ii", 0, 0)
    record += b"".join(fname(index) for index in [6, 1, 2, 7, 6])
    record += struct.pack("<i", 1) + fname(8) + patcher.encode_fstring("RawSkin")
    record += struct.pack("<ii", 0, 0)
    dependencies = struct.pack("<i", 0)
    name_offset = 32 + len(record) + len(dependencies)
    header = (patcher.REGISTRY_GUID + struct.pack("<i", 6)
              + struct.pack("<q", name_offset) + struct.pack("<i", 2))
    name_table = struct.pack("<i", len(names)) + b"".join(
        patcher.encode_fstring(name) + patcher.name_hashes(name) for name in names)
    path.write_bytes(header + record + dependencies + name_table)


def read_tags(data, names, record):
    off = record.start
    for _ in range(5):
        _, off = patcher.parse_fname(data, off, record.end, names)
    count = patcher.i32(data, off)
    off += 4
    tags = {}
    for _ in range(count):
        key, off = patcher.parse_fname(data, off, record.end, names)
        value, off = patcher.read_fstring(data, off, record.end)
        tags[key] = value
    return tags


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
        assert len(records) == 5
        assert "/Game/New/LongName.LongName" in paths
        assert "/Game/New/Other_6.Other_6" in paths
        # The target package contains the source asset name as a substring; it
        # must not be rewritten again by the bare-asset pass.
        assert "/Game/Older/Old_New.Old_New" in paths
        assert "/Game/Older/Old_New_New.Old_New" not in paths
        operations = []
        for skin in ["SkinA", "SkinB"]:
            folder = f"/Game/Blueprints/Cosmetics/Skins/{skin}"
            operations += [
                {"source": "/Game/Items/Old.Old", "target": f"{folder}/BP_{skin}.BP_{skin}", "reference_group": folder},
                {"source": "/Game/Items/Data.Data", "target": f"/Game/Data/Skins/{skin}/{skin}.{skin}", "reference_group": folder},
            ]
        patcher.patch_registry_many(source, output, operations)
        data = output.read_bytes()
        offset = struct.unpack_from("<q", data, 20)[0]
        names, _ = patcher.parse_names(data, offset)
        records, _ = patcher.parse_assets(data, names, offset)
        for record in records:
            if "/BP_Skin" not in record.object_path:
                continue
            skin = "SkinA" if "SkinA" in record.object_path else "SkinB"
            tags = read_tags(data, names, record)
            bundle = tags["AssetBundleData"]
            assert f"/Game/Data/Skins/{skin}/{skin}.{skin}" in bundle
            assert "/Game/Items/Data.Data" not in bundle
            assert "/Game/Items/Old_Base.Old_Base" in bundle
            assert ("SkinB" if skin == "SkinA" else "SkinA") not in bundle
        original = next(r for r in records if r.object_path == "/Game/Items/Old.Old")
        assert "/Game/Items/Data.Data" in read_tags(data, names, original)["AssetBundleData"]
        try:
            patcher.patch_registry_many(source, root / "invalid.bin", [{
                "source": "/Game/Items/Data.Data",
                "target": "/Game/Blueprints/Cosmetics/Skins/SkinA/Data/SkinA.SkinA"}])
        except patcher.RegistryError as error:
            assert "scan paths" in str(error)
        else:
            raise AssertionError("RawSkin outside its scan path must be rejected")
        assert not (root / "invalid.bin").exists()
    print("PASS: Asset Registry patcher regression tests")


if __name__ == "__main__":
    main()
