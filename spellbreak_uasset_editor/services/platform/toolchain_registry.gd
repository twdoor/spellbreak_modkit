class_name ToolchainRegistry extends RefCounted

## Resolves bundled subprocess toolchains from one deterministic location.
## Source-tree files are used directly in development. Exported resources are
## refreshed into an application-versioned user-data directory before launch.

const UASSET_CONVERTER_FILES := [
	"UAssetConverter.dll",
	"UAssetConverter.deps.json",
	"UAssetConverter.runtimeconfig.json",
	"UAssetAPI.dll",
	"Newtonsoft.Json.dll",
	"ZstdSharp.dll",
]

const U4PAK_FILES := ["u4pak.py"]
const ASSET_REGISTRY_FILES := ["patch_asset_registry.py"]

const DDS_TOOLS_FILES := [
	"main.py", "util.py", "config.json", "LICENSE",
	"unreal/archive.py", "unreal/city_hash.py", "unreal/crc.py",
	"unreal/data_resource.py", "unreal/file_summary.py",
	"unreal/import_export.py", "unreal/uasset.py", "unreal/umipmap.py",
	"unreal/utexture.py", "unreal/version.py",
	"directx/dds.py", "directx/dxgi_format.py", "directx/texconv.py",
	"directx/libtexconv.so", "directx/texconv.dll",
]

static var _resolved: Dictionary = {}


static func converter_dll() -> String:
	return _resolve_bundled_file(
			"converter", "UAssetConverter.dll", UASSET_CONVERTER_FILES)


static func u4pak_script(override_directory: String = "") -> String:
	return _resolve_with_override(
			override_directory, "u4pak", "u4pak.py", U4PAK_FILES)


static func asset_registry_script() -> String:
	return _resolve_bundled_file(
			"asset_registry", "patch_asset_registry.py", ASSET_REGISTRY_FILES)


static func dds_tools_script(override_directory: String = "") -> String:
	return _resolve_with_override(
			override_directory, "ue4_dds_tools", "main.py", DDS_TOOLS_FILES)


static func _resolve_with_override(override_directory: String, tool_directory: String,
		marker_file: String, files: Array) -> String:
	if not override_directory.is_empty():
		return override_directory.rstrip("/").path_join(marker_file)
	return _resolve_bundled_file(tool_directory, marker_file, files)


static func _resolve_bundled_file(tool_directory: String, marker_file: String,
		files: Array) -> String:
	var cache_key := tool_directory + "/" + marker_file
	var cached := str(_resolved.get(cache_key, ""))
	if not cached.is_empty() and FileAccess.file_exists(cached):
		return cached

	var project_path := ProjectSettings.globalize_path(
			"res://%s/%s" % [tool_directory, marker_file])
	if project_path.is_absolute_path() and FileAccess.file_exists(project_path):
		_resolved[cache_key] = project_path
		return project_path

	var resource_marker := "res://%s/%s" % [tool_directory, marker_file]
	if not FileAccess.file_exists(resource_marker):
		return ""

	var target_root := _versioned_toolchain_root().path_join(tool_directory)
	for relative_path in files:
		var source := "res://%s/%s" % [tool_directory, relative_path]
		if not FileAccess.file_exists(source):
			continue
		var target := target_root.path_join(str(relative_path))
		var data := FileAccess.get_file_as_bytes(source)
		if FileAccess.file_exists(target) \
				and FileAccess.get_file_as_bytes(target) == data:
			continue
		var error := FileUtils.write_bytes_atomic(target, data)
		if error != OK:
			push_error("Could not extract bundled tool %s (error %d)" % [target, error])
			return ""

	var resolved := target_root.path_join(marker_file)
	if FileAccess.file_exists(resolved):
		_resolved[cache_key] = resolved
		return resolved
	return ""


static func _versioned_toolchain_root() -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", "dev"))
	for character in ["/", "\\", ":", " "]:
		version = version.replace(character, "_")
	return OS.get_user_data_dir().path_join("toolchains").path_join(version)
