#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/update_latest_linux_build.sh [version]

Copies dist/<version>/linux into dist/latest for a stable local launcher path.
If version is omitted, the newest numeric build folder is used.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
version="${1:-}"

if [[ "$version" == "-h" || "$version" == "--help" ]]; then
	usage
	exit 0
fi
if (($# > 1)); then
	usage >&2
	exit 2
fi

if [[ -z "$version" ]]; then
	version="$(
		find "$dist_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
			| grep -E '^[0-9]+(\.[0-9]+)*$' \
			| sort -V \
			| tail -n 1
	)"
fi

if [[ -z "$version" ]]; then
	echo "Could not infer a build version from $dist_dir" >&2
	exit 1
fi

source_dir="$dist_dir/$version/linux"
latest_dir="$dist_dir/latest"
if [[ ! -x "$source_dir/sbue.x86_64" || ! -f "$source_dir/sbue.sh" ]]; then
	echo "Incomplete Linux export in $source_dir" >&2
	exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/latest"
cp -p "$source_dir/sbue.x86_64" "$tmp_dir/latest/sbue.x86_64"
cp -p "$source_dir/sbue.sh" "$tmp_dir/latest/sbue.sh"
chmod +x "$tmp_dir/latest/sbue.x86_64" "$tmp_dir/latest/sbue.sh"

rm -rf "$latest_dir"
mv "$tmp_dir/latest" "$latest_dir"
echo "Updated $latest_dir from $source_dir"
