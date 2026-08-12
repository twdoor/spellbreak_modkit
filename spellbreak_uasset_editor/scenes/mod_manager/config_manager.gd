class_name ModConfigManager extends RefCounted

## Adapts the mod manager's typed configuration to the AppSettings service.

const STATE_FILENAME := ".mod_state.json"
const SETTINGS_SECTION := "mod_manager"
const AppSettingsRuntime = preload(
	"res://addons/app_settings/app_settings_runtime.gd"
)

var _settings
var _state_path := ""
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
var _game_profile: SpellbreakProfile = null

signal config_changed


func _init(settings_service: Node = null) -> void:
	_settings = settings_service if settings_service != null else _resolve_settings_service()
	_state_path = _settings.get_file_path(STATE_FILENAME)
	load_config()


func _resolve_settings_service() -> Node:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var autoload := (main_loop as SceneTree).root.get_node_or_null("AppSettings")
		if autoload != null:
			return autoload
	return AppSettingsRuntime.new()


func get_config_dir() -> String:
	return _settings.config_directory_path


func get_config_path() -> String:
	return _settings.settings_file_path


func get_u4pak_path() -> String:
	return ToolchainRegistry.u4pak_script(u4pak_dir)


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


func get_umodel_path() -> String:
	return umodel_path


## Returns the cached Spellbreak profile.
func get_game_profile() -> SpellbreakProfile:
	if _game_profile == null:
		_game_profile = SpellbreakProfile.shared()
	return _game_profile


func get_paks_dir() -> String:
	return game_dir.path_join(get_game_profile().paks_subpath)


func get_dds_tools_main_py() -> String:
	return ToolchainRegistry.dds_tools_script(ue4_dds_tools_dir)


func get_dds_tools_dir() -> String:
	if not ue4_dds_tools_dir.is_empty():
		return ue4_dds_tools_dir.rstrip("/")
	var main_py := get_dds_tools_main_py()
	if not main_py.is_empty():
		return main_py.get_base_dir()
	return ""
