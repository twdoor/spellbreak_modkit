class_name GameProfile extends RefCounted
## Loads the fixed Spellbreak configuration, enums, tags, and constants.
##
## The Spellbreak profile lives under game_profiles/spellbreak/ and contains:
##   profile.json  — version strings, content root, pak settings, etc.
##   base_enums.json — Unreal enum values observed in Spellbreak assets
##   enums.json      — Spellbreak-specific enum value map
##   tags.json       — gameplay tag list for autocomplete
##   constants.json  — named numeric constants for expression fields

const SPELLBREAK_PROFILE_ID := "spellbreak"

var profile_id: String = SPELLBREAK_PROFILE_ID
var display_name: String = "Spellbreak"
var builtin: bool = true
var ue_version: String = "4.22"
var umodel_game_flag: String = "ue4.22"
var dds_tools_version: String = "4.20"
var pak_archive_version: int = 3
var pak_mount_point: String = "../../../"
var content_root: String = "g3"
var paks_subpath: String = "g3/Content/Paks"
var pak_output_name: String = "zzz_mods_P"
var audio_format: String = "ogg_raw"
var has_enums: bool = true
var has_tags: bool = true
var has_constants: bool = true

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

## Load the Spellbreak profile. The argument remains for old configs and legacy
## callers, but non-Spellbreak IDs are migrated back to Spellbreak.
static func load_profile(pid: String = SPELLBREAK_PROFILE_ID) -> GameProfile:
	var profile := GameProfile.new()
	profile.profile_id = SPELLBREAK_PROFILE_ID

	if not pid.is_empty() and pid != SPELLBREAK_PROFILE_ID:
		push_warning("GameProfile: '%s' is no longer supported; using Spellbreak" % pid)

	var profile_dir := _find_profile_dir()
	if profile_dir.is_empty():
		push_warning("GameProfile: Spellbreak profile directory not found, using defaults")
		return profile

	var profile_json: Variant = _read_json(profile_dir.path_join("profile.json"))
	if profile_json is Dictionary:
		profile._apply_dict(profile_json)

	profile._load_data_files(profile_dir)

	return profile


# ── Internals ────────────────────────────────────────────────────────────────

func _apply_dict(d: Dictionary) -> void:
	profile_id = SPELLBREAK_PROFILE_ID
	display_name = str(d.get("display_name", display_name))
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


func _load_data_files(profile_dir: String) -> void:
	enums.clear()
	var base: Variant = _read_json(profile_dir.path_join("base_enums.json"))
	if base is Dictionary:
		enums = base.duplicate(true)

	if has_enums:
		var game_enums: Variant = _read_json(profile_dir.path_join("enums.json"))
		if game_enums is Dictionary:
			enums.merge(game_enums, true)

	if has_tags:
		var game_tags: Variant = _read_json(profile_dir.path_join("tags.json"))
		if game_tags is Array:
			tags.clear()
			for tag in game_tags:
				tags.append(str(tag))

	if has_constants:
		var game_constants: Variant = _read_json(profile_dir.path_join("constants.json"))
		if game_constants is Dictionary:
			constants.clear()
			for key in game_constants:
				constants[str(key).to_lower()] = float(game_constants[key])


## Search for a profile directory across all search paths.
static func _find_profile_dir() -> String:
	for base in _get_search_paths():
		var candidate := base.path_join(SPELLBREAK_PROFILE_ID)
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""


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
