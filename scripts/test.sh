#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir="$repo_root/spellbreak_uasset_editor"
godot_bin="${GODOT:-godot}"
python_bin="${PYTHON:-python3}"
logs=()
trap 'rm -f "${logs[@]}"' EXIT

run_godot_checked() {
	local log
	log="$(mktemp)"
	logs+=("$log")
	set +e
	"$godot_bin" "$@" 2>&1 | tee "$log"
	local status="${PIPESTATUS[0]}"
	set -e
	if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' "$log"; then
		return 1
	fi
	return "$status"
}

run_godot_checked --headless --editor --path "$project_dir" --quit
run_godot_checked --headless --path "$project_dir" --script res://tests/test_core.gd
run_godot_checked --headless --path "$project_dir" --script res://tests/test_background_jobs.gd

pak_test_dir="$(mktemp -d)"
trap 'rm -f "${logs[@]}"; rm -rf "$pak_test_dir"' EXIT
"$python_bin" - <<'PY' "$pak_test_dir/version8-padded.pak"
import hashlib
import struct
import sys

pak_path = sys.argv[1]

def pack_path(path: str) -> bytes:
    encoded = path.encode("utf-8") + b"\0"
    return struct.pack("<i", len(encoded)) + encoded

payload = b"version8 payload\n"
sha1 = hashlib.sha1(payload).digest()
record = struct.pack("<QQQB", 0, len(payload), len(payload), 0) + sha1 + struct.pack("<BI", 0, 0)
index_offset = len(record) + len(payload)
index = (
    pack_path("../../../")
    + struct.pack("<I", 1)
    + pack_path("g3/Content/TestAsset.uasset")
    + struct.pack("<QQQB", 0, len(payload), len(payload), 0)
    + sha1
    + struct.pack("<BI", 0, 0)
)
footer = struct.pack(
    "<IIQQ20s",
    0x5A6F12E1,
    8,
    index_offset,
    len(index),
    hashlib.sha1(index).digest(),
)
with open(pak_path, "wb") as pak:
    pak.write(record)
    pak.write(payload)
    pak.write(index)
    pak.write(footer)
    pak.write(b"\0" * 128)
PY
"$python_bin" "$project_dir/u4pak/u4pak.py" list "$pak_test_dir/version8-padded.pak" \
	| grep -qx 'g3/Content/TestAsset.uasset'
"$python_bin" "$project_dir/u4pak/u4pak.py" unpack -C "$pak_test_dir/out" \
	"$pak_test_dir/version8-padded.pak" g3/Content/TestAsset.uasset
cmp "$pak_test_dir/out/g3/Content/TestAsset.uasset" <(printf 'version8 payload\n')
