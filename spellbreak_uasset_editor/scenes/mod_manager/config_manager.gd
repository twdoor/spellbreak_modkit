class_name ModConfigManager extends RefCounted

## Loads and saves config.json from the modkit root directory.
## Mirrors the exact format used by mod_manager.py:
##   { "game_dir": "...", "mods_dir": "...", "launch_cmd": "..." }
##
## Config file location is auto-detected at startup and cached in _config_path.

const CONFIG_FILENAME  := "config.json"
const STATE_FILENAME   := ".mod_state.json"

var _config_path: String = ""
var _state_path: String  = ""

var game_dir:   String = ""
var mods_dir:   String = ""
var launch_cmd: String = ""
## Optional override: absolute path to the u4pak/ directory (the folder containing u4pak.py).
## Leave empty to use auto-detection (looks for u4pak/ relative to config.json).
var u4pak_dir:  String = ""
## Reference pak sources. Each entry: { "name": String, "path": String }
## Used to register the base game pak, reference mods, older versions, etc.
var sources: Array = []
## Optional override: absolute path to the UE4-DDS-Tools directory (the folder containing src/main.py).
## Required for texture preview and PNG export/import.
var ue4_dds_tools_dir: String = ""
## Absolute path to the umodel binary.  Required for 3D mesh preview.
var umodel_path: String = ""

signal config_changed


func _init() -> void:
	_config_path = _find_config_path()
	_state_path  = _config_path.get_base_dir().path_join(STATE_FILENAME)
	load_config()


# ── Path detection ─────────────────────────────────────────────────────────────

## Locate the config file.  In dev mode (Godot editor) search upward from the
## project directory.  In exported builds, store config next to the executable.
func _find_config_path() -> String:
	var project_dir := ProjectSettings.globalize_path("res://").rstrip("/")
	if project_dir.is_absolute_path():
		# Dev / editor: walk up looking for the modkit root (contains spellbreak_uasset_editor/)
		var dir := project_dir
		for _i in range(4):
			if DirAccess.dir_exists_absolute(dir.path_join("spellbreak_uasset_editor")):
				return dir.path_join(CONFIG_FILENAME)
			var parent := dir.get_base_dir()
			if parent == dir:
				break
			dir = parent

	# Exported build: config lives next to the executable
	var exe_dir := OS.get_executable_path().get_base_dir()
	return exe_dir.path_join(CONFIG_FILENAME)


func get_config_dir() -> String:
	return _config_path.get_base_dir()


func get_u4pak_path() -> String:
	if not u4pak_dir.is_empty():
		return u4pak_dir.rstrip("/").path_join("u4pak.py")
	return _find_bundled_tool("u4pak", "u4pak.py")


func get_state_path() -> String:
	return _state_path


func is_configured() -> bool:
	return not game_dir.is_empty() and not mods_dir.is_empty()


# ── Load / Save ────────────────────────────────────────────────────────────────

func load_config() -> void:
	if not FileAccess.file_exists(_config_path):
		return
	var file := FileAccess.open(_config_path, FileAccess.READ)
	if not file:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return
	game_dir   = str(parsed.get("game_dir",   ""))
	mods_dir   = str(parsed.get("mods_dir",   ""))
	launch_cmd = str(parsed.get("launch_cmd", ""))
	u4pak_dir  = str(parsed.get("u4pak_dir",  ""))
	ue4_dds_tools_dir = str(parsed.get("ue4_dds_tools_dir", ""))
	umodel_path = str(parsed.get("umodel_path", ""))
	sources    = []
	for entry in parsed.get("sources", []):
		if entry is Dictionary:
			sources.append({"name": str(entry.get("name", "")), "path": str(entry.get("path", ""))})


func save_config() -> void:
	var data: Dictionary = {"game_dir": game_dir, "mods_dir": mods_dir, "launch_cmd": launch_cmd}
	if not u4pak_dir.is_empty():
		data["u4pak_dir"] = u4pak_dir
	if not ue4_dds_tools_dir.is_empty():
		data["ue4_dds_tools_dir"] = ue4_dds_tools_dir
	if not umodel_path.is_empty():
		data["umodel_path"] = umodel_path
	if not sources.is_empty():
		data["sources"] = sources
	var file := FileAccess.open(_config_path, FileAccess.WRITE)
	if not file:
		push_error("ModConfigManager: cannot write config to %s" % _config_path)
		return
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	config_changed.emit()


func get_umodel_path() -> String:
	return umodel_path


func get_paks_dir() -> String:
	return game_dir.path_join("g3/Content/Paks")


func get_dds_tools_main_py() -> String:
	if not ue4_dds_tools_dir.is_empty():
		return ue4_dds_tools_dir.rstrip("/").path_join("main.py")
	return _find_bundled_tool("ue4_dds_tools", "main.py")


func get_dds_tools_dir() -> String:
	if not ue4_dds_tools_dir.is_empty():
		return ue4_dds_tools_dir.rstrip("/")
	var main_py := get_dds_tools_main_py()
	if not main_py.is_empty():
		return main_py.get_base_dir()
	return ""


# ── Bundled tool resolution ───────────────────────────────────────────────────
# Both u4pak/ and ue4_dds_tools/ are packed inside the Godot .pck at export time.
# At runtime the search order mirrors UAssetFile._get_converter_dll():
#   1. Next to the executable  (user manually placed)
#   2. User data dir           (previously extracted from .pck)
#   3. Project source tree     (Godot editor / dev)
#   4. Extract from res://     (exported build, first run)

## All files that need to be extracted for each bundled tool.
const _U4PAK_FILES := ["u4pak.py"]
const _DDS_TOOLS_FILES := [
	"main.py", "util.py", "config.json", "LICENSE",
	"unreal/archive.py", "unreal/city_hash.py", "unreal/crc.py",
	"unreal/data_resource.py", "unreal/file_summary.py",
	"unreal/import_export.py", "unreal/uasset.py", "unreal/umipmap.py",
	"unreal/utexture.py", "unreal/version.py",
	"directx/dds.py", "directx/dxgi_format.py", "directx/texconv.py",
	"directx/libtexconv.so", "directx/texconv.dll",
]


func _find_bundled_tool(tool_dir: String, marker_file: String) -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var user_dir := OS.get_user_data_dir()
	var project_dir := ProjectSettings.globalize_path("res://")

	# 1. Next to executable
	var p := exe_dir.path_join(tool_dir).path_join(marker_file)
	if FileAccess.file_exists(p):
		return p

	# 2. Already extracted to user data
	p = user_dir.path_join(tool_dir).path_join(marker_file)
	if FileAccess.file_exists(p):
		return p

	# 3. Project source tree (editor / dev)
	if project_dir.is_absolute_path():
		p = project_dir.path_join(tool_dir).path_join(marker_file)
		if FileAccess.file_exists(p):
			return p
		# Also check parent dir (modkit root has spellbreak_uasset_editor/ as child)
		p = project_dir.get_base_dir().path_join(tool_dir).path_join(marker_file)
		if FileAccess.file_exists(p):
			return p

	# 4. Packed inside .pck — extract to user data
	if FileAccess.file_exists("res://%s/%s" % [tool_dir, marker_file]):
		var files: Array
		match tool_dir:
			"u4pak":          files = _U4PAK_FILES
			"ue4_dds_tools":  files = _DDS_TOOLS_FILES
			_:                files = [marker_file]
		_extract_tool_to_user_dir(tool_dir, files)
		p = user_dir.path_join(tool_dir).path_join(marker_file)
		if FileAccess.file_exists(p):
			return p

	return ""


static func _extract_tool_to_user_dir(tool_dir: String, files: Array) -> void:
	var user_dir := OS.get_user_data_dir()
	var dst_root := user_dir.path_join(tool_dir)
	for rel_path in files:
		var src := "res://%s/%s" % [tool_dir, rel_path]
		var dst := dst_root.path_join(rel_path)
		# Ensure subdirectory exists
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		if not FileAccess.file_exists(src):
			continue
		var data := FileAccess.get_file_as_bytes(src)
		if data.size() == 0:
			continue
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f:
			f.store_buffer(data)
			f.close()
