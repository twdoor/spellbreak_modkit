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

signal config_changed


func _init() -> void:
	_config_path = _find_config_path()
	_state_path  = _config_path.get_base_dir().path_join(STATE_FILENAME)
	load_config()


# ── Path detection ─────────────────────────────────────────────────────────────

## Walk up from known locations to find the modkit root (contains u4pak/u4pak.py).
func _find_config_path() -> String:
	# Search upward from the project directory (res://).
	# Strip any trailing slash first — get_base_dir() on a path ending in "/"
	# strips the slash instead of going up a level, which breaks detection.
	var project_dir := ProjectSettings.globalize_path("res://").rstrip("/")
	for _i in range(4):  # check up to 4 levels up from the project
		if FileAccess.file_exists(project_dir.path_join("u4pak/u4pak.py")):
			return project_dir.path_join(CONFIG_FILENAME)
		var parent := project_dir.get_base_dir()
		if parent == project_dir:
			break  # reached filesystem root
		project_dir = parent

	# Exported binary: walk up from the executable's directory
	var exe_dir := OS.get_executable_path().get_base_dir().rstrip("/")
	for _i in range(4):
		if FileAccess.file_exists(exe_dir.path_join("u4pak/u4pak.py")):
			return exe_dir.path_join(CONFIG_FILENAME)
		var parent := exe_dir.get_base_dir()
		if parent == exe_dir:
			break
		exe_dir = parent

	# Fallback: store config next to the executable (user will need to set paths manually)
	return OS.get_executable_path().get_base_dir().path_join(CONFIG_FILENAME)


func get_config_dir() -> String:
	return _config_path.get_base_dir()


func get_u4pak_path() -> String:
	if not u4pak_dir.is_empty():
		return u4pak_dir.rstrip("/").path_join("u4pak.py")
	return get_config_dir().path_join("u4pak/u4pak.py")


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
	sources    = []
	for entry in parsed.get("sources", []):
		if entry is Dictionary:
			sources.append({"name": str(entry.get("name", "")), "path": str(entry.get("path", ""))})


func save_config() -> void:
	var data: Dictionary = {"game_dir": game_dir, "mods_dir": mods_dir, "launch_cmd": launch_cmd}
	if not u4pak_dir.is_empty():
		data["u4pak_dir"] = u4pak_dir
	if not sources.is_empty():
		data["sources"] = sources
	var file := FileAccess.open(_config_path, FileAccess.WRITE)
	if not file:
		push_error("ModConfigManager: cannot write config to %s" % _config_path)
		return
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	config_changed.emit()


func get_paks_dir() -> String:
	return game_dir.path_join("g3/Content/Paks")
