#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/update_latest_linux_build.sh [version] [--config-from DIR]

Copies spellbreak_uasset_editor/builds/<version>/linux into
spellbreak_uasset_editor/builds/latest for a stable local desktop launcher path.

If version is omitted, the newest numeric build folder is used.
Legacy runtime files from builds/latest are preserved for automatic import by
the application. On the first run, pass --config-from with the old desktop
build folder to make config.json and .mod_state.json available to that importer.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir="$repo_root/spellbreak_uasset_editor"
builds_dir="$project_dir/builds"
version=""
config_from=""

while (($# > 0)); do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		--config-from)
			if (($# < 2)); then
				echo "Missing value for --config-from" >&2
				exit 2
			fi
			config_from="$2"
			shift 2
			;;
		--*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [[ -n "$version" ]]; then
				echo "Unexpected extra argument: $1" >&2
				usage >&2
				exit 2
			fi
			version="$1"
			shift
			;;
	esac
done

if [[ -z "$version" ]]; then
	version="$(
		find "$builds_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
			| grep -E '^[0-9]+(\.[0-9]+)*$' \
			| sort -V \
			| tail -n 1
	)"
fi

if [[ -z "$version" ]]; then
	echo "Could not infer a build version from $builds_dir" >&2
	exit 1
fi

source_dir="$builds_dir/$version/linux"
latest_dir="$builds_dir/latest"

if [[ ! -x "$source_dir/sbue.x86_64" ]]; then
	echo "Missing Linux export: $source_dir/sbue.x86_64" >&2
	exit 1
fi
if [[ ! -f "$source_dir/sbue.sh" ]]; then
	echo "Missing Linux launcher: $source_dir/sbue.sh" >&2
	exit 1
fi

if [[ -n "$config_from" && ! -d "$config_from" ]]; then
	echo "Config source does not exist: $config_from" >&2
	exit 1
fi

tmp_dir="$(mktemp -d)"
runtime_dir="$tmp_dir/runtime"
mkdir -p "$runtime_dir"
trap 'rm -rf "$tmp_dir"' EXIT

copy_runtime_from() {
	local dir="$1"
	local overwrite="$2"
	[[ -d "$dir" ]] || return 0

	local runtime_files=("config.json" ".mod_state.json")
	for name in "${runtime_files[@]}"; do
		local path="$dir/$name"
		[[ -f "$path" ]] || continue
		if [[ "$overwrite" == "yes" || ! -e "$runtime_dir/$name" ]]; then
			cp -p "$path" "$runtime_dir/$name"
		fi
	done
}

copy_runtime_from "$latest_dir" "yes"
if [[ -n "$config_from" ]]; then
	copy_runtime_from "$config_from" "no"
fi
copy_runtime_from "$source_dir" "no"
copy_runtime_from "$repo_root" "no"

rm -rf "$latest_dir"
mkdir -p "$latest_dir"
cp -p "$source_dir/sbue.x86_64" "$latest_dir/sbue.x86_64"
cp -p "$source_dir/sbue.sh" "$latest_dir/sbue.sh"

shopt -s nullglob dotglob
for path in "$runtime_dir"/*; do
	[[ -f "$path" ]] || continue
	cp -p "$path" "$latest_dir/$(basename "$path")"
done
shopt -u nullglob dotglob

chmod +x "$latest_dir/sbue.x86_64" "$latest_dir/sbue.sh"

echo "Updated $latest_dir from $source_dir"
if [[ -f "$latest_dir/config.json" ]]; then
	echo "Preserved config: $latest_dir/config.json"
fi
if [[ -f "$latest_dir/.mod_state.json" ]]; then
	echo "Preserved mod state: $latest_dir/.mod_state.json"
fi
