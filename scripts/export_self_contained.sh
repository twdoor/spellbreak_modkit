#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:?Usage: export_self_contained.sh linux-x64|win-x64 output-file}"
output="${2:?Supply an absolute output filename}"
case "$platform" in
  linux-x64) preset=Linux ;;
  win-x64) preset='Windows Desktop' ;;
  *) echo 'Unsupported platform' >&2; exit 2 ;;
esac
archive="$repo_root/spellbreak_uasset_editor/runtimes/$platform.zip"
if [[ ! -s "$archive" ]]; then
  echo "Missing $archive. Run tools/build_runtime_bundles.py first." >&2
  exit 1
fi
mkdir -p "$(dirname "$output")"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
run_checked() {
  "${GODOT:-godot}" "$@" 2>&1 | tee "$log"
  if grep -Eq 'SCRIPT ERROR|Parse Error|Compile Error|Compilation failed|Failed to load script' "$log"; then
    return 1
  fi
}
run_checked --headless --editor --path "$repo_root/spellbreak_uasset_editor" --quit
run_checked --headless --path "$repo_root/spellbreak_uasset_editor" --export-release "$preset" "$output"
