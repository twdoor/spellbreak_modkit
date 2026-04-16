class_name UAssetFile
extends RefCounted
## Top-level class representing a UAsset JSON file.
## Load with UAssetFile.load_file(), edit properties, save with save_file().
##
## Usage:
##   var asset := UAssetFile.load_file("path/to/DA_BattleRoyale_Duo.json")
##   if asset:
##       var exp := asset.exports[0]
##       var prop := exp.find_property("MaxSquadCount")
##       prop.value = 20
##       asset.save_file("path/to/DA_BattleRoyale_Duo.json")

## Texture export class names recognized by UE4-DDS-Tools
const TEXTURE_CLASSES := [
	"Texture2D", "TextureCube", "LightMapTexture2D", "ShadowMapTexture2D",
	"Texture2DArray", "TextureCubeArray", "VolumeTexture",
]

## Sound export class names — audio preview via SoundService
const SOUND_CLASSES := ["SoundWave"]

## Mesh export class names — 3D preview via MeshService (umodel)
const MESH_CLASSES := ["StaticMesh", "SkeletalMesh"]

## The raw top-level JSON dict - kept for round-trip fidelity
var raw: Dictionary

## File info
var file_path: String
## Set when loaded from a .uasset binary; save_file() writes back to binary instead of JSON
var binary_path: String = ""
var info: String  # "Serialized with UAssetAPI ..."
var engine_version: String  # "VER_UE4_FIX_WIDE_STRING_CRC"

## NameMap - list of all names referenced in this asset
var name_map: PackedStringArray

## Imports
var imports: Array[UAssetImport] = []

## Exports
var exports: Array[UAssetExport] = []

## Package metadata
var package_guid: String = ""
var package_flags: String = ""
var is_unversioned: bool = false
var folder_name: String = ""

## Signals for UI binding
signal file_loaded(path: String)
signal file_saved(path: String)
signal property_changed(export_idx: int, prop_name: String)


## Path to the UAssetConverter .NET DLL.
## Search order:
##   1. Next to the executable (exported build — manually placed)
##   2. User data dir (extracted from .pck on a previous run)
##   3. converter/ subfolder in project source tree (editor / dev)
##   4. ../uasset_converter/publish/ (legacy Modkit layout)
##   5. Extract from res://converter/ into user data dir (exported, first run)
static var _converter_dll: String = ""

## All files that must travel with UAssetConverter.dll
const _CONVERTER_FILES := [
	"UAssetConverter.dll",
	"UAssetConverter.deps.json",
	"UAssetConverter.runtimeconfig.json",
	"UAssetAPI.dll",
	"Newtonsoft.Json.dll",
	"ZstdSharp.dll",
]

static func _get_converter_dll() -> String:
	if not _converter_dll.is_empty():
		return _converter_dll

	const DLL := "UAssetConverter.dll"
	var exe_dir := OS.get_executable_path().get_base_dir()
	var user_dir := OS.get_user_data_dir()
	var project_dir := ProjectSettings.globalize_path("res://")

	# 1. Next to the executable (user manually placed or post-export copy)
	if FileAccess.file_exists(exe_dir.path_join(DLL)):
		_converter_dll = exe_dir.path_join(DLL)
		return _converter_dll

	# 2. Already extracted to user data on a previous run
	if FileAccess.file_exists(user_dir.path_join(DLL)):
		_converter_dll = user_dir.path_join(DLL)
		return _converter_dll

	# 3. Project source converter/ folder (Godot editor / dev)
	# Only use project_dir when it's an absolute path — in exported builds globalize_path("res://")
	# returns "" which produces a relative path that OS.execute() can't resolve.
	if project_dir.is_absolute_path():
		if FileAccess.file_exists(project_dir.path_join("converter").path_join(DLL)):
			_converter_dll = project_dir.path_join("converter").path_join(DLL)
			return _converter_dll

		# 4. Legacy sibling uasset_converter/publish/ layout
		if FileAccess.file_exists(project_dir.path_join("../uasset_converter/publish").path_join(DLL)):
			_converter_dll = project_dir.path_join("../uasset_converter/publish").path_join(DLL)
			return _converter_dll

	# 5. Packed inside res://converter/ (exported build, first run) — extract to user data
	if FileAccess.file_exists("res://converter/" + DLL):
		_extract_converter_to_user_dir(user_dir)
		if FileAccess.file_exists(user_dir.path_join(DLL)):
			_converter_dll = user_dir.path_join(DLL)
			return _converter_dll

	# Nothing found — return exe-relative path so error messages are meaningful
	_converter_dll = exe_dir.path_join(DLL)
	return _converter_dll


static func _extract_converter_to_user_dir(user_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(user_dir)
	for fname in _CONVERTER_FILES:
		var src: String = "res://converter/" + fname
		var dst: String = user_dir.path_join(fname)
		if not FileAccess.file_exists(src):
			continue
		var data := FileAccess.get_file_as_bytes(src)
		if data.size() == 0:
			continue
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f:
			f.store_buffer(data)
			f.close()


## Load a UAssetAPI JSON or binary .uasset file and parse it into objects.
## If path ends with .uasset, the converter is called to read it in-memory — no .json file is written.
static func load_file(path: String) -> UAssetFile:
	if path.ends_with(".uasset"):
		return _load_binary(path)

	if not FileAccess.file_exists(path):
		push_error("UAssetFile: File not found: " + path)
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("UAssetFile: Cannot open: " + path)
		return null

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("UAssetFile: JSON parse error at line %d: %s" % [json.get_error_line(), json.get_error_message()])
		return null

	var data: Dictionary = json.data
	if not data.has("Exports"):
		push_error("UAssetFile: Not a valid UAssetAPI JSON (no Exports)")
		return null

	return _from_dict(data, path)


## Load directly from a .uasset binary via the converter (no intermediate .json file).
static func _load_binary(path: String) -> UAssetFile:
	var dll := _get_converter_dll()
	if not FileAccess.file_exists(dll):
		push_error("UAssetFile: Converter not found at: " + dll + " — run uasset_tool.py --setup")
		return null
	if not FileAccess.file_exists(path):
		push_error("UAssetFile: File not found: " + path)
		return null

	var output: Array = []
	var exit_code := OS.execute("dotnet", [dll, "read", path], output, true)
	if exit_code != 0:
		push_error("UAssetFile: Converter failed (exit %d): %s" % [exit_code, output[0] if output.size() > 0 else "no output"])
		return null

	var json_text: String = output[0] if output.size() > 0 else ""
	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		push_error("UAssetFile: JSON parse error from converter: " + json.get_error_message())
		return null

	var data: Dictionary = json.data
	if not data.has("Exports"):
		push_error("UAssetFile: Converter output is not valid UAssetAPI JSON (no Exports)")
		return null

	var asset := _from_dict(data, path)
	if asset:
		asset.binary_path = path
	return asset


static func _from_dict(data: Dictionary, path: String) -> UAssetFile:
	var asset := UAssetFile.new()
	asset.raw = data
	asset.file_path = path
	asset.info = str(data.get("Info", ""))
	asset.engine_version = str(data.get("ObjectVersion", ""))
	asset.package_guid = str(data.get("PackageGuid", ""))
	asset.package_flags = str(data.get("PackageFlags", ""))
	asset.is_unversioned = data.get("IsUnversioned", false) if data.get("IsUnversioned") != null else false
	asset.folder_name = str(data.get("FolderName", ""))
	
	# NameMap
	var nm = data.get("NameMap")
	if nm is Array:
		for name in nm:
			asset.name_map.append(str(name))
	
	# Imports
	var imp_arr = data.get("Imports")
	if imp_arr is Array:
		for imp_dict in imp_arr:
			if imp_dict is Dictionary:
				asset.imports.append(UAssetImport.from_dict(imp_dict, -1 * (imp_arr.find(imp_dict) + 1)))
	
	# Exports
	var exp_arr = data.get("Exports")
	if exp_arr is Array:
		for exp_dict in exp_arr:
			if exp_dict is Dictionary:
				asset.exports.append(UAssetExport.from_dict(exp_dict))
	
	asset._ensure_default_properties()
	asset.file_loaded.emit(path)
	return asset


## Resolve the class name for an export via its ClassIndex import.
func get_export_class_name(expo: UAssetExport) -> String:
	if expo.class_index < 0:
		var imp := get_import(expo.class_index)
		if imp:
			return imp.object_name
	return ""


## Returns true if any export in this asset is a texture type.
func is_texture_asset() -> bool:
	for expo in exports:
		if get_export_class_name(expo) in TEXTURE_CLASSES:
			return true
	return false


## After loading, inject missing default properties for known export types.
## UE4 skips serializing properties that equal their class default values, but
## we want them visible and editable in the editor.
const _DEFAULT_PROPERTIES := {
	"XAttributeRequirement": [
		{  # float "Value" — the number the attribute is compared against (defaults to 0)
			"$type": "UAssetAPI.PropertyTypes.Objects.FloatPropertyData, UAssetAPI",
			"Name": "Value",
			"ArrayIndex": 0,
			"IsZero": false,
			"PropertyTagFlags": "None",
			"PropertyTypeName": null,
			"PropertyTagExtensions": "NoExtension",
			"Value": 0.0,
		},
	],
}


func _ensure_default_properties() -> void:
	for expo in exports:
		var cls_name := get_export_class_name(expo)
		if cls_name not in _DEFAULT_PROPERTIES:
			continue
		var defaults: Array = _DEFAULT_PROPERTIES[cls_name]
		for default_raw: Dictionary in defaults:
			var prop_name: String = default_raw["Name"]
			if expo.find_property(prop_name) != null:
				continue  # already present
			# Inject into both the parsed properties and the raw data
			ensure_name(prop_name)
			var prop := UAssetProperty.from_dict(default_raw)
			expo.properties.append(prop)
			var data_arr: Variant = expo.raw.get("Data")
			if data_arr is Array:
				(data_arr as Array).append(default_raw.duplicate(true))


## Save back to disk. If loaded from a .uasset binary, writes binary directly — no .json file.
## Pass a path to save-as; omit to overwrite the original.
func save_file(path: String = "") -> Error:
	# Determine target path
	var target := path
	if target.is_empty():
		target = binary_path if not binary_path.is_empty() else file_path
	if target.is_empty():
		push_error("UAssetFile: No save path specified")
		return ERR_INVALID_PARAMETER

	var data := _to_dict()
	_fix_float_to_int(data)
	var json_string := JSON.stringify(data, "  ")

	# Binary save path: write JSON to a temp file, call converter, delete temp
	if not binary_path.is_empty() and (path.is_empty() or path.ends_with(".uasset")):
		var out_uasset := target if target.ends_with(".uasset") else binary_path
		var tmp_json := OS.get_temp_dir().path_join("sb_edit_%d.json" % Time.get_ticks_msec())
		var dll := _get_converter_dll()

		# Retry loop: if the converter reports a missing FName, add it to the
		# NameMap, regenerate the JSON, and try again.  Any other error is fatal.
		const MAX_NAME_RETRIES := 64
		var retries := 0
		while true:
			var tmp_file := FileAccess.open(tmp_json, FileAccess.WRITE)
			if not tmp_file:
				push_error("UAssetFile: Cannot write temp file: " + tmp_json)
				return ERR_FILE_CANT_WRITE
			tmp_file.store_string(json_string)
			tmp_file.close()

			var output: Array = []
			var exit_code := OS.execute("dotnet", [dll, "fromjson", tmp_json, out_uasset], output, true)

			if exit_code == 0:
				break  # success

			var err_text: String = output[0] if output.size() > 0 else ""
			var missing := _extract_dummy_fname(err_text)

			if missing.is_empty() or retries >= MAX_NAME_RETRIES:
				DirAccess.remove_absolute(tmp_json)
				push_error("UAssetFile: Converter failed (exit %d): %s" % [exit_code, err_text])
				return ERR_FILE_CANT_WRITE

			# Add the missing name and rebuild the JSON for the next attempt
			ensure_name(missing)
			var data2 := _to_dict()
			_fix_float_to_int(data2)
			json_string = JSON.stringify(data2, "  ")
			retries += 1

		DirAccess.remove_absolute(tmp_json)
		binary_path = out_uasset
		file_saved.emit(out_uasset)
		return OK

	# JSON save path
	var file := FileAccess.open(target, FileAccess.WRITE)
	if not file:
		push_error("UAssetFile: Cannot write: " + target)
		return ERR_FILE_CANT_WRITE

	file.store_string(json_string)
	file.close()

	file_path = target
	file_saved.emit(target)
	return OK


## Godot's JSON parser turns all ints into floats (0 → 0.0).
## UAssetAPI rejects floats where it expects ints/enums.
## This recursively converts whole-number floats back to ints.
static func _fix_float_to_int(data: Variant) -> Variant:
	if data is Dictionary:
		for key in data.keys():
			data[key] = _fix_float_to_int(data[key])
	elif data is Array:
		for i in data.size():
			data[i] = _fix_float_to_int(data[i])
	elif data is float:
		if data == floorf(data) and absf(data) < 2147483647.0:
			return int(data)
	return data


func _to_dict() -> Dictionary:
	var data := raw.duplicate(true)
	
	# NameMap
	var nm: Array = []
	for name in name_map:
		nm.append(name)
	data["NameMap"] = nm
	
	# Imports
	var imp_arr: Array = []
	for imp in imports:
		imp_arr.append(imp.to_dict())
	data["Imports"] = imp_arr
	
	# Exports
	var exp_arr: Array = []
	for expo in exports:
		exp_arr.append(expo.to_dict())
	data["Exports"] = exp_arr
	
	return data


# ── Convenience Methods ────────────────────────────────────────

## Get first export (most assets have one)
func get_main_export() -> UAssetExport:
	if exports.is_empty():
		return null
	return exports[0]


## Find export by name
func find_export(export_name: String) -> UAssetExport:
	for expo in exports:
		if expo.object_name == export_name:
			return expo
	return null


## Find a property in the first export by name
func find_property(prop_name: String) -> UAssetProperty:
	var expo := get_main_export()
	if expo:
		return expo.find_property(prop_name)
	return null


## Quick value getter: asset.get_value("MaxSquadCount") -> 10
func get_value(prop_name: String, default = null) -> Variant:
	var prop := find_property(prop_name)
	if prop:
		return prop.value
	return default


## Quick value setter: asset.set_value("MaxSquadCount", 20)
func set_value(prop_name: String, new_value) -> bool:
	var prop := find_property(prop_name)
	if prop:
		prop.value = new_value
		property_changed.emit(0, prop_name)
		return true
	return false


## Parse a "dummy FName 'X'" error message from the converter and return X.
## Returns "" if the message doesn't match the pattern.
static func _extract_dummy_fname(err_text: String) -> String:
	var marker := "dummy FName '"
	var start := err_text.find(marker)
	if start < 0:
		return ""
	start += marker.length()
	var end := err_text.find("'", start)
	if end < 0:
		return ""
	return err_text.substr(start, end - start)


## Check if a name exists in the NameMap
func has_name(name: String) -> bool:
	return name in name_map


## Add a name to the NameMap if not present. Returns the index.
func ensure_name(name: String) -> int:
	var idx := name_map.find(name)
	if idx >= 0:
		return idx
	name_map.append(name)
	return name_map.size() - 1


## Get import by index (handles negative indices from export references)
func get_import(index: int) -> UAssetImport:
	# UAsset uses negative indices for imports: -1 = imports[0], -2 = imports[1], etc
	if index < 0:
		var actual := (-index) - 1
		if actual < imports.size():
			return imports[actual]
	return null


## Find an import index by ObjectName. Returns the negative 1-based index, or 0 if not found.
func find_import_index(object_name: String) -> int:
	for i in imports.size():
		if imports[i].object_name == object_name:
			return -(i + 1)
	return 0


## Ensure an import exists, adding it if missing. Returns its negative 1-based index.
func ensure_import(object_name: String, outer_object_name: String,
		imp_class_package: String, imp_class_name: String) -> int:
	var existing := find_import_index(object_name)
	if existing != 0:
		return existing

	var outer_idx := find_import_index(outer_object_name)
	if outer_idx == 0:
		push_error("UAssetFile.ensure_import: outer '%s' not found" % outer_object_name)
		return 0

	var imp := UAssetImport.new()
	imp.object_name = object_name
	imp.outer_index = outer_idx
	imp.class_package = imp_class_package
	imp.class_name_str = imp_class_name
	imp.package_name = ""
	imp.import_optional = false
	imp.raw = {
		"$type": "UAssetAPI.Import, UAssetAPI",
		"ObjectName": object_name,
		"OuterIndex": outer_idx,
		"ClassPackage": imp_class_package,
		"ClassName": imp_class_name,
		"PackageName": null,  # must be null, not "" — UAssetAPI rejects empty FStrings
		"bImportOptional": false,
	}
	imports.append(imp)
	ensure_name(object_name)
	return -(imports.size())


## Add an instanced CDO subobject and wire up all dependency arrays.
##
## cdo_export_idx  — 0-based index of the CDO export in self.exports
## subobj_class    — ObjectName of the subobject class, e.g. "XGameplayEffectTargetTagRequirements"
## g3_package      — "/Script/g3" or whichever native package owns the class
## array_prop_name — property on the CDO that holds this subobject, e.g. "ActivationRequirements"
## initial_props   — UAssetProperty list to store as the new export's Data
##
## Returns the 1-based export index of the new subobject, or -1 on failure.
func add_instanced_subobject(
		cdo_export_idx: int,
		subobj_class: String,
		g3_package: String,
		array_prop_name: String,
		initial_props: Array[UAssetProperty] = []) -> int:

	# ── 1. Ensure required imports ──────────────────────────────────────────
	var class_idx  := ensure_import(subobj_class,
			g3_package, "/Script/CoreUObject", "Class")
	var default_name := "Default__%s" % subobj_class
	var default_idx := ensure_import(default_name,
			g3_package, g3_package, subobj_class)
	if class_idx == 0 or default_idx == 0:
		return -1

	# GameplayTag ScriptStruct is used in many dependency lists; find if present.
	var tag_struct_idx := find_import_index("GameplayTag")

	# ── 2. Build the new export ─────────────────────────────────────────────
	var cdo_1based := cdo_export_idx + 1   # UE4 export indices are 1-based
	var new_1based := exports.size() + 1   # will become this index after append

	# Unique name: class + "_0", or increment if already taken
	var base_name := subobj_class + "_0"
	var instance_name := base_name
	var counter := 0
	for expo_item in exports:
		if expo_item.object_name == instance_name:
			counter += 1
			instance_name = subobj_class + "_%d" % counter

	var cbsd: Array = [cdo_1based]
	if tag_struct_idx != 0:
		cbsd.append(tag_struct_idx)

	var sub_raw := {
		"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
		"ObjectName": instance_name,
		"ObjectFlags": "RF_Public, RF_Transactional, RF_ArchetypeObject",
		"ClassIndex": class_idx,
		"SuperIndex": 0,
		"TemplateIndex": default_idx,
		"OuterIndex": cdo_1based,
		"PackageGuid": "{00000000-0000-0000-0000-000000000000}",
		"ObjectGuid": null,
		"PackageFlags": "PKG_None",
		"bForcedExport": false,
		"bNotForClient": false,
		"bNotForServer": false,
		"bNotAlwaysLoadedForEditorGame": true,
		"bIsAsset": false,
		"bGeneratePublicHash": false,
		"IsInheritedInstance": false,
		"SerialOffset": 0,
		"SerialSize": 0,
		"GeneratePublicHash": false,
		"HasLeadingFourNullBytes": false,
		"SerializationControl": "NoExtension",
		"Operation": "None",
		"Extras": "",
		"ScriptSerializationStartOffset": 0,
		"ScriptSerializationEndOffset": 0,
		"CreateBeforeCreateDependencies": [cdo_1based],
		"CreateBeforeSerializationDependencies": cbsd,
		"SerializationBeforeCreateDependencies": [class_idx, default_idx],
		"SerializationBeforeSerializationDependencies": [cdo_1based],
		"Data": [],
	}

	var sub_exp := UAssetExport.from_dict(sub_raw)
	sub_exp.properties = initial_props
	# Sync raw Data so to_dict() is correct
	var data_arr: Array = []
	for p in initial_props:
		data_arr.append(p.to_dict())
	sub_exp.raw["Data"] = data_arr

	exports.append(sub_exp)
	ensure_name(instance_name)

	# ── 3. Update CDO dependencies ──────────────────────────────────────────
	var cdo := exports[cdo_export_idx]
	var cdo_raw := cdo.raw
	var cdo_cbsd: Array = cdo_raw.get("CreateBeforeSerializationDependencies", [])
	if new_1based not in cdo_cbsd:
		cdo_cbsd.append(new_1based)
		cdo_raw["CreateBeforeSerializationDependencies"] = cdo_cbsd

	# ── 4. Add or extend the array property on the CDO ─────────────────────
	ensure_name(array_prop_name)
	var arr_prop := cdo.find_property(array_prop_name)
	if arr_prop == null:
		var new_item_raw := {
			"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
			"Name": "0",
			"ArrayIndex": 0,
			"PropertyTagFlags": "None",
			"PropertyTagExtensions": "NoExtension",
			"PropertyTypeName": null,
			"IsZero": false,
			"Value": new_1based,
		}
		var new_item := UAssetProperty.from_dict(new_item_raw)

		var arr_raw := {
			"$type": "UAssetAPI.PropertyTypes.Objects.ArrayPropertyData, UAssetAPI",
			"ArrayType": "ObjectProperty",
			"Name": array_prop_name,
			"ArrayIndex": 0,
			"PropertyTagFlags": "None",
			"PropertyTagExtensions": "NoExtension",
			"PropertyTypeName": null,
			"IsZero": false,
			"Value": [new_item_raw],
		}
		arr_prop = UAssetProperty.from_dict(arr_raw)
		arr_prop.children = [new_item]
		cdo.properties.append(arr_prop)
	else:
		# Array already exists — append a new element
		var next_idx := arr_prop.children.size()
		var new_item_raw := {
			"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
			"Name": str(next_idx),
			"ArrayIndex": 0,
			"PropertyTagFlags": "None",
			"PropertyTagExtensions": "NoExtension",
			"PropertyTypeName": null,
			"IsZero": false,
			"Value": new_1based,
		}
		arr_prop.children.append(UAssetProperty.from_dict(new_item_raw))

	# ── 5. Update class export serialization dependencies ──────────────────
	if exports.size() >= 1:
		var cls_raw := exports[0].raw
		var sbsd: Array = cls_raw.get("SerializationBeforeSerializationDependencies", [])
		if default_idx not in sbsd:
			sbsd.append(default_idx)
			cls_raw["SerializationBeforeSerializationDependencies"] = sbsd

	return new_1based


## Get a summary string
func get_summary() -> String:
	var s := "UAsset: %s\n" % file_path.get_file()
	s += "  Names: %d\n" % name_map.size()
	s += "  Imports: %d\n" % imports.size()
	s += "  Exports: %d\n" % exports.size()
	for i in exports.size():
		var expo := exports[i]
		s += "  Export %d: %s (%d properties)\n" % [i, expo.object_name, expo.properties.size()]
		for prop in expo.properties:
			s += "    %s (%s) = %s\n" % [prop.prop_name, prop.prop_type, prop.get_display_value()]
	return s
