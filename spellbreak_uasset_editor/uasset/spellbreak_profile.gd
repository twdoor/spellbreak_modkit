class_name SpellbreakProfile extends RefCounted
## Loads Spellbreak's fixed configuration, enums, tags, and constants.
##
## The Spellbreak profile lives under game_profiles/spellbreak/ and contains:
##   profile.json  — version strings, content root, pak settings, etc.
##   base_enums.json — Unreal enum values observed in Spellbreak assets
##   enums.json      — Spellbreak-specific enum value map
##   tags.json       — gameplay tag list for autocomplete
##   constants.json  — named numeric constants for expression fields

const PROFILE_ID := "spellbreak"
const PROFILE_DIRECTORY := "res://game_profiles/spellbreak"

var profile_id: String = PROFILE_ID
var display_name: String = "Spellbreak"
var ue_version: String = "4.22"
var umodel_game_flag: String = "ue4.22"
var dds_tools_version: String = "4.20"
var pak_archive_version: int = 3
var pak_mount_point: String = "../../../"
var content_root: String = "g3"
var paks_subpath: String = "g3/Content/Paks"
var pak_output_name: String = "zzz_mods_P"
var audio_format: String = "ogg_raw"

## Merged enum database: enum_type → Array[String] of values.
var enums: Dictionary = {}
## Gameplay tags for autocomplete.
var tags: Array[String] = []
## Named numeric constants for use in Int/Float expression fields.
var constants: Dictionary = {}

static var _shared: SpellbreakProfile


# ── Public API ────────────────────────────────────────────────────────────────

## Returns the list of known values for an enum type, or empty if unknown.
func get_enum_values(enum_type: String) -> PackedStringArray:
	var v: Array = enums.get(enum_type, [])
	var out := PackedStringArray()
	for s in v:
		out.append(str(s))
	return out


# ── Profile loading ──────────────────────────────────────────────────────────

static func create() -> SpellbreakProfile:
	var profile := SpellbreakProfile.new()
	var profile_json: Variant = _read_json(PROFILE_DIRECTORY.path_join("profile.json"))
	if profile_json is Dictionary:
		profile._apply_dict(profile_json)
	else:
		push_warning("Spellbreak profile.json was not found; using built-in defaults")
	profile._load_data_files()
	return profile


static func shared() -> SpellbreakProfile:
	if _shared == null:
		_shared = create()
	return _shared


# ── Internals ────────────────────────────────────────────────────────────────

func _apply_dict(d: Dictionary) -> void:
	profile_id = PROFILE_ID
	display_name = str(d.get("display_name", display_name))
	ue_version = str(d.get("ue_version", ue_version))
	umodel_game_flag = str(d.get("umodel_game_flag", umodel_game_flag))
	dds_tools_version = str(d.get("dds_tools_version", dds_tools_version))
	pak_archive_version = int(d.get("pak_archive_version", pak_archive_version))
	pak_mount_point = str(d.get("pak_mount_point", pak_mount_point))
	content_root = str(d.get("content_root", content_root))
	paks_subpath = str(d.get("paks_subpath", paks_subpath))
	pak_output_name = str(d.get("pak_output_name", pak_output_name))
	audio_format = str(d.get("audio_format", audio_format))


func _load_data_files() -> void:
	enums.clear()
	var base: Variant = _read_json(PROFILE_DIRECTORY.path_join("base_enums.json"))
	if base is Dictionary:
		enums = base.duplicate(true)

	var game_enums: Variant = _read_json(PROFILE_DIRECTORY.path_join("enums.json"))
	if game_enums is Dictionary:
		enums.merge(game_enums, true)

	var game_tags: Variant = _read_json(PROFILE_DIRECTORY.path_join("tags.json"))
	if game_tags is Array:
		tags.clear()
		for tag in game_tags:
			tags.append(str(tag))

	var game_constants: Variant = _read_json(PROFILE_DIRECTORY.path_join("constants.json"))
	if game_constants is Dictionary:
		constants.clear()
		for key in game_constants:
			constants[str(key).to_lower()] = float(game_constants[key])


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)
