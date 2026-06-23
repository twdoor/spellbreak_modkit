#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir="$repo_root/spellbreak_uasset_editor"
godot_bin="${GODOT:-godot}"
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
