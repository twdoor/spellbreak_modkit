class_name GameProfile extends RefCounted
## Loads game-specific configuration, enums, and tags from a game profile directory.
##
## Profiles live under game_profiles/ and contain:
##   profile.json  — version strings, content root, pak settings, etc.
##   enums.json    — optional enum value map (merged on top of _generic base enums)
##   tags.json     — optional gameplay tag list for autocomplete
##
## Special profile IDs starting with "ue_" (e.g. "ue_4.27") are generated
## programmatically from a template and have no on-disk directory.

var profile_id: String = ""
var display_name: String = ""
var builtin: bool = false
var ue_version: String = "4.27"
var umodel_game_flag: String = "ue4.27"
var dds_tools_version: String = "4.27"
var pak_archive_version: int = 3
var pak_mount_point: String = "../../../"
var content_root: String = "Content"
var paks_subpath: String = "Content/Paks"
var pak_output_name: String = "zzz_mods_P"
var audio_format: String = "ogg_raw"
var has_enums: bool = false
var has_tags: bool = false
var has_constants: bool = false

## Merged enum database: enum_type → Array[String] of values.
var enums: Dictionary = {}
## Gameplay tags for autocomplete.
var tags: Array[String] = []
## Named numeric constants for use in Int/Float expression fields.
var constants: Dictionary = {}


# ── Public API ────────────────────────────────────────────────────────────────

## Returns the list of known values for an enum type, or empty if unknown.
func get_enum_values(enum_type: String) -> PackedStringArray:
	var v: Array = enums.get(enum_type, [])
	var out := PackedStringArray()
	for s in v:
		out.append(str(s))
	return out


## Returns true if we have any values registered for this enum type.
func has_enum(enum_type: String) -> bool:
	return enums.has(enum_type)


## Returns the full path to the paks directory given the game install root.
func get_paks_dir(game_dir: String) -> String:
	return game_dir.path_join(paks_subpath)


# ── Profile loading ──────────────────────────────────────────────────────────

## Load a profile by ID.  Handles three cases:
##   1. "ue_X.Y"       — auto-generated generic UE version profile
##   2. "spellbreak"    — loads from game_profiles/spellbreak/
##   3. any other ID    — loads from game_profiles/<id>/ (user-created)
static func load_profile(pid: String) -> GameProfile:
	if pid.begins_with("ue_"):
		return _make_generic_ue(pid.trim_prefix("ue_"), pid)

	var profile := GameProfile.new()
	profile.profile_id = pid

	# Try to find and load profile.json
	var profile_dir := _find_profile_dir(pid)
	if profile_dir.is_empty():
		push_warning("GameProfile: profile directory not found for '%s', using defaults" % pid)
		profile.display_name = pid
		profile._load_base_enums()
		return profile

	var profile_json: Variant = _read_json(profile_dir.path_join("profile.json"))
	if profile_json is Dictionary:
		profile._apply_dict(profile_json)

	# Load enums: start with generic base, then merge game-specific on top
	profile._load_base_enums()
	if profile.has_enums:
		var game_enums: Variant = _read_json(profile_dir.path_join("enums.json"))
		if game_enums is Dictionary:
			profile.enums.merge(game_enums, true)

	# Load tags
	if profile.has_tags:
		var game_tags: Variant = _read_json(profile_dir.path_join("tags.json"))
		if game_tags is Array:
			profile.tags.clear()
			for tag in game_tags:
				profile.tags.append(str(tag))

	# Load constants
	if profile.has_constants:
		var game_constants: Variant = _read_json(profile_dir.path_join("constants.json"))
		if game_constants is Dictionary:
			for key in game_constants:
				profile.constants[str(key).to_lower()] = float(game_constants[key])

	return profile


## List all available profile IDs: on-disk profiles + generated UE versions.
## Returns an Array of Dictionaries:
##   { "id": String, "display_name": String, "builtin": bool, "is_ue_version": bool }
static func list_profiles() -> Array:
	var result: Array = []

	# 1. Scan on-disk profile directories
	var dirs := _get_all_profile_dirs()
	for dir_path in dirs:
		var dir_name: String = dir_path.get_file()
		if dir_name.begins_with("_"):
			continue  # skip _generic
		var profile_json: Variant = _read_json(dir_path.path_join("profile.json"))
		if profile_json is Dictionary:
			result.append({
				"id": dir_name,
				"display_name": str(profile_json.get("display_name", dir_name)),
				"builtin": bool(profile_json.get("builtin", false)),
				"is_ue_version": false,
			})
		else:
			result.append({
				"id": dir_name,
				"display_name": dir_name,
				"builtin": false,
				"is_ue_version": false,
			})

	# 2. Add generated UE version entries
	for major in [4, 5]:
		var max_minor := 27 if major == 4 else 4
		for minor in range(max_minor + 1):
			var ver := "%d.%d" % [major, minor]
			result.append({
				"id": "ue_%s" % ver,
				"display_name": "UE %s" % ver,
				"builtin": true,
				"is_ue_version": true,
			})

	return result


# ── Internals ────────────────────────────────────────────────────────────────

func _apply_dict(d: Dictionary) -> void:
	display_name = str(d.get("display_name", profile_id))
	builtin = bool(d.get("builtin", false))
	ue_version = str(d.get("ue_version", ue_version))
	umodel_game_flag = str(d.get("umodel_game_flag", umodel_game_flag))
	dds_tools_version = str(d.get("dds_tools_version", dds_tools_version))
	pak_archive_version = int(d.get("pak_archive_version", pak_archive_version))
	pak_mount_point = str(d.get("pak_mount_point", pak_mount_point))
	content_root = str(d.get("content_root", content_root))
	paks_subpath = str(d.get("paks_subpath", paks_subpath))
	pak_output_name = str(d.get("pak_output_name", pak_output_name))
	audio_format = str(d.get("audio_format", audio_format))
	has_enums = bool(d.get("has_enums", has_enums))
	has_tags = bool(d.get("has_tags", has_tags))
	has_constants = bool(d.get("has_constants", has_constants))


func _load_base_enums() -> void:
	var generic_dir := _find_profile_dir("_generic")
	if generic_dir.is_empty():
		return
	var base: Variant = _read_json(generic_dir.path_join("enums.json"))
	if base is Dictionary:
		enums = base.duplicate(true)


static func _make_generic_ue(ver: String, pid: String) -> GameProfile:
	var p := GameProfile.new()
	p.profile_id = pid
	p.display_name = "UE %s" % ver
	p.builtin = true
	p.ue_version = ver
	# umodel wants "ue4.22" or "ue5.0" format
	p.umodel_game_flag = "ue%s" % ver
	p.dds_tools_version = ver
	# UE5 uses pak version 11, UE4 uses version 3
	p.pak_archive_version = 3 if ver < "5.0" else 11
	p.pak_mount_point = "../../../"
	p.content_root = "Content"
	p.paks_subpath = "Content/Paks"
	p.pak_output_name = "zzz_mods_P"
	p.audio_format = "ogg_raw"
	p.has_enums = false
	p.has_tags = false
	# Still load base UE enums
	p._load_base_enums()
	return p


## Search for a profile directory across all search paths.
static func _find_profile_dir(dir_name: String) -> String:
	for base in _get_search_paths():
		var candidate := base.path_join(dir_name)
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""


## Returns all profile directories found across all search paths.
static func _get_all_profile_dirs() -> Array[String]:
	var seen := {}
	var result: Array[String] = []
	for base in _get_search_paths():
		if not DirAccess.dir_exists_absolute(base):
			continue
		var da := DirAccess.open(base)
		if da == null:
			continue
		da.list_dir_begin()
		var entry := da.get_next()
		while not entry.is_empty():
			if da.current_is_dir() and not entry.begins_with("."):
				if not seen.has(entry):
					seen[entry] = true
					result.append(base.path_join(entry))
			entry = da.get_next()
		da.list_dir_end()
	return result


## Search paths for game_profiles/, in priority order.
static func _get_search_paths() -> Array[String]:
	var paths: Array[String] = []
	var exe_dir := OS.get_executable_path().get_base_dir()
	var user_dir := OS.get_user_data_dir()
	var project_dir := ProjectSettings.globalize_path("res://")

	# 1. Next to executable (user-placed)
	paths.append(exe_dir.path_join("game_profiles"))
	# 2. User data dir (extracted from pck or user-created)
	paths.append(user_dir.path_join("game_profiles"))
	# 3. Project source tree (editor/dev)
	if project_dir.is_absolute_path():
		paths.append(project_dir.path_join("game_profiles"))
		# Also check parent dir (modkit root has spellbreak_uasset_editor/ as child)
		paths.append(project_dir.get_base_dir().path_join("game_profiles"))
	return paths


## Returns the first user-writable directory for storing custom profiles.
static func get_user_profiles_dir() -> String:
	return OS.get_user_data_dir().path_join("game_profiles")


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		# Try res:// path as fallback for packed builds
		var res_path := _to_res_path(path)
		if not res_path.is_empty() and FileAccess.file_exists(res_path):
			path = res_path
		else:
			return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)


## Try to convert an absolute path to a res:// path for packed builds.
static func _to_res_path(abs_path: String) -> String:
	var project_dir := ProjectSettings.globalize_path("res://")
	if abs_path.begins_with(project_dir):
		return "res://" + abs_path.substr(project_dir.length())
	return ""
