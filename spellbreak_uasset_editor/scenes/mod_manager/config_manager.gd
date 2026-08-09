class_name ModConfigManager extends RefCounted

## Adapts the mod manager's typed configuration to the AppSettings service.
## Older config.json and .mod_state.json files are imported without deleting
## them, so updating an existing installation preserves its configuration.

const CONFIG_FILENAME := "settings.cfg"
const LEGACY_CONFIG_FILENAME := "config.json"
const STATE_FILENAME := ".mod_state.json"
const SETTINGS_SECTION := "mod_manager"
const MIGRATION_SECTION := "migration"
const LEGACY_CONFIG_MIGRATION_KEY := "legacy_config_imported"
const LEGACY_STATE_MIGRATION_KEY := "legacy_mod_state_imported"
const AppSettingsRuntime = preload(
	"res://addons/app_settings/app_settings_runtime.gd"
)

const _SETTING_KEYS := [
	"game_dir",
	"mods_dir",
	"launch_cmd",
	"u4pak_dir",
	"ue4_dds_tools_dir",
	"umodel_path",
	"sources",
]

var _settings
var _state_path := ""
var _legacy_config_path_override := ""
var last_error := ""

var game_dir:   String = ""
var mods_dir:   String = ""
var launch_cmd: String = ""
## Optional override: absolute path to the u4pak/ directory (the folder containing u4pak.py).
## Leave empty to use the bundled u4pak copy.
var u4pak_dir:  String = ""
## Reference pak sources. Each entry: { "name": String, "path": String }
## Used to register the base game pak, reference mods, older versions, etc.
var sources: Array = []
## Optional override: absolute path to the UE4-DDS-Tools directory (the folder containing src/main.py).
## Required for texture preview and PNG export/import.
var ue4_dds_tools_dir: String = ""
## Absolute path to the umodel binary.  Required for 3D mesh preview.
var umodel_path: String = ""
var _game_profile: GameProfile = null

signal config_changed


func _init(settings_service: Node = null, legacy_config_path := "") -> void:
	_settings = settings_service if settings_service != null else _resolve_settings_service()
	_legacy_config_path_override = legacy_config_path
	_state_path = _settings.get_file_path(STATE_FILENAME)
	_migrate_legacy_files()
	load_config()


func _resolve_settings_service() -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var autoload := (main_loop as SceneTree).root.get_node_or_null("AppSettings")
		if autoload != null:
			return autoload
	return AppSettingsRuntime.new()


# ── Path detection ─────────────────────────────────────────────────────────────

## Locate a configuration file created by versions before AppSettings. In dev
## mode it lived in the modkit root; exported builds kept it by the executable.
func _find_legacy_config_path() -> String:
	if not _legacy_config_path_override.is_empty():
		return _legacy_config_path_override
	if OS.has_feature("editor"):
		var project_dir := ProjectSettings.globalize_path("res://").rstrip("/")
		var dir := project_dir
		for _i in range(4):
			if DirAccess.dir_exists_absolute(dir.path_join("spellbreak_uasset_editor")):
				return dir.path_join(LEGACY_CONFIG_FILENAME)
			var parent := dir.get_base_dir()
			if parent == dir:
				break
			dir = parent

	var exe_dir := OS.get_executable_path().get_base_dir()
	return exe_dir.path_join(LEGACY_CONFIG_FILENAME)


func get_config_dir() -> String:
	return _settings.config_directory_path


func get_config_path() -> String:
	return _settings.settings_file_path


func get_u4pak_path() -> String:
	if not u4pak_dir.is_empty():
		return u4pak_dir.rstrip("/").path_join("u4pak.py")
	return _find_bundled_tool("u4pak", "u4pak.py")


func get_state_path() -> String:
	return _state_path


func is_configured() -> bool:
	return not game_dir.is_empty() and not mods_dir.is_empty()


# ── Load / Save ────────────────────────────────────────────────────────────────

func load_config() -> Error:
	last_error = ""
	var error: Error = _settings.reload()
	if error != OK:
		last_error = _settings.last_error

	game_dir = str(_settings.get_value(SETTINGS_SECTION, "game_dir", ""))
	mods_dir = str(_settings.get_value(SETTINGS_SECTION, "mods_dir", ""))
	launch_cmd = str(_settings.get_value(SETTINGS_SECTION, "launch_cmd", ""))
	u4pak_dir = str(_settings.get_value(SETTINGS_SECTION, "u4pak_dir", ""))
	ue4_dds_tools_dir = str(
		_settings.get_value(SETTINGS_SECTION, "ue4_dds_tools_dir", "")
	)
	umodel_path = str(_settings.get_value(SETTINGS_SECTION, "umodel_path", ""))
	_game_profile = null  # invalidate cache
	sources = []
	var saved_sources: Variant = _settings.get_value(SETTINGS_SECTION, "sources", [])
	if not saved_sources is Array:
		return error
	for entry in saved_sources:
		if entry is Dictionary:
			sources.append({
				"name": str(entry.get("name", "")),
				"path": str(entry.get("path", "")),
			})
	return error


func save_config() -> Error:
	last_error = ""
	_store_current_values()
	var error: Error = _settings.save()
	if error != OK:
		last_error = _settings.last_error
		return error
	config_changed.emit()
	return OK


func _store_current_values() -> void:
	_settings.set_value(SETTINGS_SECTION, "game_dir", game_dir, false)
	_settings.set_value(SETTINGS_SECTION, "mods_dir", mods_dir, false)
	_settings.set_value(SETTINGS_SECTION, "launch_cmd", launch_cmd, false)
	_settings.set_value(SETTINGS_SECTION, "u4pak_dir", u4pak_dir, false)
	_settings.set_value(
		SETTINGS_SECTION,
		"ue4_dds_tools_dir",
		ue4_dds_tools_dir,
		false
	)
	_settings.set_value(SETTINGS_SECTION, "umodel_path", umodel_path, false)
	_settings.set_value(SETTINGS_SECTION, "sources", sources.duplicate(true), false)


func _migrate_legacy_files() -> void:
	var legacy_config_path := _find_legacy_config_path()
	var legacy_directory := legacy_config_path.get_base_dir()
	_migrate_legacy_config(legacy_config_path)
	_migrate_legacy_state(legacy_directory.path_join(STATE_FILENAME))


func _migrate_legacy_config(legacy_path: String) -> void:
	if bool(_settings.get_value(
		MIGRATION_SECTION,
		LEGACY_CONFIG_MIGRATION_KEY,
		false
	)):
		return
	for key: String in _SETTING_KEYS:
		if _settings.has_value(SETTINGS_SECTION, key):
			return
	if not FileAccess.file_exists(legacy_path):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(legacy_path))
	if not parsed is Dictionary:
		push_warning("ModConfigManager: could not import invalid legacy config: %s" % legacy_path)
		return

	game_dir = str(parsed.get("game_dir", ""))
	mods_dir = str(parsed.get("mods_dir", ""))
	launch_cmd = str(parsed.get("launch_cmd", ""))
	u4pak_dir = str(parsed.get("u4pak_dir", ""))
	ue4_dds_tools_dir = str(parsed.get("ue4_dds_tools_dir", ""))
	umodel_path = str(parsed.get("umodel_path", ""))
	sources = []
	for entry: Variant in parsed.get("sources", []):
		if entry is Dictionary:
			sources.append({
				"name": str(entry.get("name", "")),
				"path": str(entry.get("path", "")),
			})

	_store_current_values()
	_settings.set_value(
		MIGRATION_SECTION,
		LEGACY_CONFIG_MIGRATION_KEY,
		true,
		false
	)
	var error: Error = _settings.save()
	if error != OK:
		push_error("ModConfigManager: could not import legacy config: %s" % _settings.last_error)


func _migrate_legacy_state(legacy_path: String) -> void:
	if bool(_settings.get_value(
		MIGRATION_SECTION,
		LEGACY_STATE_MIGRATION_KEY,
		false
	)):
		return
	if FileAccess.file_exists(_state_path) or not FileAccess.file_exists(legacy_path):
		return

	var error := FileUtils.write_bytes_atomic(
		_state_path,
		FileAccess.get_file_as_bytes(legacy_path)
	)
	if error != OK:
		push_error("ModConfigManager: could not import legacy mod state from %s" % legacy_path)
		return
	_settings.set_value(
		MIGRATION_SECTION,
		LEGACY_STATE_MIGRATION_KEY,
		true
	)


func get_umodel_path() -> String:
	return umodel_path


## Returns the cached Spellbreak profile.
func get_game_profile() -> GameProfile:
	if _game_profile == null:
		# Ensure game_profiles are extracted from .pck for exported builds
		_find_bundled_tool("game_profiles", "spellbreak/profile.json")
		_game_profile = GameProfile.load_profile("spellbreak")
	return _game_profile


func get_paks_dir() -> String:
	return game_dir.path_join(get_game_profile().paks_subpath)


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
# At runtime the search order mirrors UAssetFile._get_converter_dll(), but
# bundled tools are refreshed from res:// before using user-data copies. This
# prevents stale extracted scripts from surviving app updates forever.
#   1. Next to the executable  (user manually placed)
#   2. Current bundled res:// copy, extracted/refreshed to user data
#   3. User data dir           (previously extracted fallback)
#   4. Project source tree     (Godot editor / dev fallback)

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
const _GAME_PROFILE_FILES := [
	"spellbreak/profile.json", "spellbreak/base_enums.json", "spellbreak/enums.json",
	"spellbreak/tags.json", "spellbreak/constants.json",
]


func _find_bundled_tool(tool_dir: String, marker_file: String) -> String:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var user_dir := OS.get_user_data_dir()
	var project_dir := ProjectSettings.globalize_path("res://")

	# 1. Next to executable
	var p := exe_dir.path_join(tool_dir).path_join(marker_file)
	if FileAccess.file_exists(p):
		return p

	# 2. Current bundled copy. Refresh user-data files so stale extracted tools
	# from an older app build do not shadow fixed bundled scripts.
	if FileAccess.file_exists("res://%s/%s" % [tool_dir, marker_file]):
		var files: Array
		match tool_dir:
			"u4pak":           files = _U4PAK_FILES
			"ue4_dds_tools":   files = _DDS_TOOLS_FILES
			"game_profiles":   files = _GAME_PROFILE_FILES
			_:                 files = [marker_file]
		_extract_tool_to_user_dir(tool_dir, files)
		p = user_dir.path_join(tool_dir).path_join(marker_file)
		if FileAccess.file_exists(p):
			return p

	# 3. Already extracted to user data
	p = user_dir.path_join(tool_dir).path_join(marker_file)
	if FileAccess.file_exists(p):
		return p

	# 4. Project source tree (editor / dev)
	if project_dir.is_absolute_path():
		p = project_dir.path_join(tool_dir).path_join(marker_file)
		if FileAccess.file_exists(p):
			return p
		# Also check parent dir (modkit root has spellbreak_uasset_editor/ as child)
		p = project_dir.get_base_dir().path_join(tool_dir).path_join(marker_file)
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
		if FileAccess.file_exists(dst) and FileAccess.get_file_as_bytes(dst) == data:
			continue
		FileUtils.write_bytes_atomic(dst, data)
