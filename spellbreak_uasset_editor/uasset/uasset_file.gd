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

## Spellbreak profile data for the property editor.
## Set by main.gd after loading, before creating the editor tab.
var game_profile: SpellbreakProfile = null

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

## Path to the UAssetConverter .NET DLL.
static func _get_converter_dll() -> String:
	return ToolchainRegistry.converter_dll()


## Load a UAssetAPI JSON or binary .uasset file and parse it into objects.
## If path ends with .uasset, the converter is called to read it in-memory — no .json file is written.
static func load_file(path: String) -> UAssetFile:
	if path.get_extension().to_lower() == "uasset":
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
		for i in imp_arr.size():
			var imp_dict: Variant = imp_arr[i]
			if imp_dict is Dictionary:
				asset.imports.append(UAssetImport.from_dict(imp_dict, -(i + 1), asset))
	
	# Exports
	var exp_arr = data.get("Exports")
	if exp_arr is Array:
		for exp_dict in exp_arr:
			if exp_dict is Dictionary:
				asset.exports.append(UAssetExport.from_dict(exp_dict, asset))
	
	asset._ensure_default_properties()
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
			var prop := UAssetProperty.from_dict(default_raw, self)
			expo.properties.append(prop)
			var data_arr: Variant = expo.raw.get("Data")
			if data_arr is Array:
				(data_arr as Array).append(default_raw.duplicate(true))


func validate_for_save() -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	for i in exports.size():
		var expo := exports[i]
		_validate_package_index(expo.class_index, "Export %d ClassIndex" % [i + 1], issues)
		_validate_package_index(expo.super_index, "Export %d SuperIndex" % [i + 1], issues)
		_validate_package_index(expo.outer_index, "Export %d OuterIndex" % [i + 1], issues)
		_validate_package_index(expo.template_index, "Export %d TemplateIndex" % [i + 1], issues)
		for field in _DEPENDENCY_FIELDS:
			var raw_dependencies: Variant = expo.raw.get(field)
			if raw_dependencies is Array:
				for raw_index in raw_dependencies:
					_validate_package_index(int(raw_index),
							"Export %d %s" % [i + 1, field], issues)
		for prop in expo.properties:
			_validate_property_indices(prop, "Export %d property %s" % [i + 1, prop.prop_name],
					issues)
	for i in imports.size():
		var imp := imports[i]
		_validate_package_index(imp.outer_index, "Import %d OuterIndex" % [i + 1], issues)
	return issues


func _validate_package_index(index: int, context: String, issues: Array[Dictionary]) -> void:
	if index == 0:
		return
	if index > 0 and index <= exports.size():
		return
	if index < 0 and -index <= imports.size():
		return
	issues.append({
		"context": context,
		"message": "Invalid package index %d (exports: %d, imports: %d)" % [
			index, exports.size(), imports.size()],
	})


func _validate_property_indices(prop: UAssetProperty, context: String,
		issues: Array[Dictionary]) -> void:
	if prop.prop_type == "Object":
		var value := int(prop.value) if prop.value != null else 0
		_validate_package_index(value, context, issues)
	elif prop.value is Dictionary or prop.value is Array:
		_validate_raw_object_references(prop.value, context, issues)
	for child in prop.children:
		_validate_property_indices(child, "%s.%s" % [context, child.prop_name], issues)


func _validate_raw_object_references(value: Variant, context: String,
		issues: Array[Dictionary]) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var type_name := str(dictionary.get("$type", ""))
		if "ObjectPropertyData" in type_name \
				and (dictionary.get("Value") is int or dictionary.get("Value") is float):
			_validate_package_index(int(dictionary["Value"]), context, issues)
		for key in dictionary:
			var child: Variant = dictionary[key]
			if child is Dictionary or child is Array:
				_validate_raw_object_references(child, "%s.%s" % [context, str(key)], issues)
	elif value is Array:
		for i in value.size():
			var child: Variant = value[i]
			if child is Dictionary or child is Array:
				_validate_raw_object_references(child, "%s[%d]" % [context, i], issues)


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
	# Ensure every name-like string (and its parsed FName base) exists in the
	# NameMap so the converter never hits a "dummy FName" error.
	if _ensure_all_fnames(data):
		data = _to_dict()
		_fix_float_to_int(data)
	var json_string := JSON.stringify(data, "  ")
	var validation_issues := validate_for_save()
	if not validation_issues.is_empty():
		for issue: Dictionary in validation_issues:
			push_error("UAssetFile: %s: %s" % [
				str(issue.get("context", "Asset")),
				str(issue.get("message", "Invalid package reference")),
			])
		return ERR_INVALID_DATA

	# Binary save path: write JSON to a temp file, call converter, delete temp
	if not binary_path.is_empty() and (path.is_empty() or path.ends_with(".uasset")):
		var out_uasset := target if target.ends_with(".uasset") else binary_path
		var tmp_result := FileUtils.make_temp_dir("sb_edit")
		if not bool(tmp_result.get("ok", false)):
			push_error("UAssetFile: " + str(tmp_result.get("error", "Could not create temp directory")))
			return ERR_CANT_CREATE
		var tmp_dir := str(tmp_result["path"])
		var tmp_json := tmp_dir.path_join("asset.json")
		var dll := _get_converter_dll()
		if dll.is_empty() or not FileAccess.file_exists(dll):
			FileUtils.remove_dir_recursive(tmp_dir)
			push_error("UAssetFile: Converter not found")
			return ERR_FILE_NOT_FOUND
		var stage_stem := out_uasset.get_base_dir().path_join(
			".%s.sb_save_%d" % [out_uasset.get_file().get_basename(), Time.get_ticks_usec()])
		var staged_uasset := stage_stem + ".uasset"

		# Retry loop: if the converter reports a missing FName, add it to the
		# NameMap, regenerate the JSON, and try again.  Any other error is fatal.
		const MAX_NAME_RETRIES := 64
		var retries := 0
		while true:
			var tmp_file := FileAccess.open(tmp_json, FileAccess.WRITE)
			if not tmp_file:
				FileUtils.remove_dir_recursive(tmp_dir)
				_remove_staged_asset_files(stage_stem)
				push_error("UAssetFile: Cannot write temp file: " + tmp_json)
				return ERR_FILE_CANT_WRITE
			tmp_file.store_string(json_string)
			tmp_file.close()

			_remove_staged_asset_files(stage_stem)
			var output: Array = []
			var exit_code := OS.execute("dotnet", [dll, "fromjson", tmp_json, staged_uasset], output, true)

			if exit_code == 0:
				break  # success

			var err_text: String = output[0] if output.size() > 0 else ""
			var missing := _extract_dummy_fname(err_text)

			if missing.is_empty() or retries >= MAX_NAME_RETRIES:
				FileUtils.remove_dir_recursive(tmp_dir)
				_remove_staged_asset_files(stage_stem)
				push_error("UAssetFile: Converter failed (exit %d): %s" % [exit_code, err_text])
				return ERR_FILE_CANT_WRITE

			# Add the missing name and rebuild the JSON for the next attempt.
			# The converter resolves "X_N" by looking up the parsed base "X" in
			# the NameMap, so the full string alone never fixes a suffixed name.
			ensure_name(missing)
			var missing_base := _fname_split_base(missing)
			if not missing_base.is_empty() and not has_name(missing_base):
				ensure_name(missing_base)
			var data2 := _to_dict()
			_fix_float_to_int(data2)
			json_string = JSON.stringify(data2, "  ")
			retries += 1

		FileUtils.remove_dir_recursive(tmp_dir)
		var staged_files: Array = []
		var removed_targets: Array[String] = []
		for extension in ["uasset", "uexp", "ubulk", "uptnl"]:
			var source: String = stage_stem + "." + extension
			var companion_target: String = out_uasset.get_basename() + "." + extension
			# UAssetAPI regenerates serialized exports, but external bulk payloads
			# are intentionally not embedded in its JSON representation. Preserve
			# those immutable payloads as part of the same atomic package install.
			if not FileAccess.file_exists(source) and extension in ["ubulk", "uptnl"]:
				var original_companion: String = binary_path.get_basename() + "." + extension
				if FileAccess.file_exists(original_companion):
					var preserve_error := FileUtils.copy_file(original_companion, source)
					if preserve_error != OK:
						_remove_staged_asset_files(stage_stem)
						push_error("UAssetFile: Could not stage .%s companion (error %d)" % [
							extension, preserve_error,
						])
						return preserve_error
			if FileAccess.file_exists(source):
				staged_files.append({
					"source": source,
					"target": companion_target,
				})
			elif extension != "uasset" and FileAccess.file_exists(companion_target):
				removed_targets.append(companion_target)
		if staged_files.is_empty() or not FileAccess.file_exists(staged_uasset):
			_remove_staged_asset_files(stage_stem)
			push_error("UAssetFile: Converter did not produce a .uasset file")
			return ERR_FILE_CANT_WRITE
		var install_error := FileUtils.install_staged_files(staged_files, removed_targets)
		if install_error != OK:
			_remove_staged_asset_files(stage_stem)
			push_error("UAssetFile: Could not install converted asset (error %d)" % install_error)
			return install_error
		binary_path = out_uasset
		file_path = out_uasset
		return OK

	# JSON save path
	var write_error := FileUtils.write_bytes_atomic(target, json_string.to_utf8_buffer())
	if write_error != OK:
		push_error("UAssetFile: Cannot write: " + target)
		return write_error

	file_path = target
	return OK


## Build an independent copy of this binary asset for a new package path.
## The source and destination filename stems define the identity replacement.
## Every serialized content string is updated, except UAssetAPI $type descriptors.
func prepare_reuse_copy(destination_path: String, regenerate_guid: bool = false,
		source_package: String = "", target_package: String = "") -> OperationResult:
	if binary_path.is_empty() or binary_path.get_extension().to_lower() != "uasset":
		return OperationResult.failed("Clone requires an open binary .uasset file")
	if destination_path.get_extension().to_lower() != "uasset":
		return OperationResult.failed("The destination must be a .uasset file")
	if FileUtils.same_path(binary_path, destination_path):
		return OperationResult.failed("Choose a different asset file from the source")

	var source_name := binary_path.get_file().get_basename()
	var destination_name := destination_path.get_file().get_basename()
	if source_name.is_empty() or destination_name.is_empty():
		return OperationResult.failed("The source and destination need valid asset names")
	if source_name == destination_name:
		return OperationResult.failed("The cloned asset needs a different filename")

	var renamed_name_entries := 0
	for name in name_map:
		if source_name in name:
			renamed_name_entries += 1
	if renamed_name_entries == 0:
		return OperationResult.failed(
				"The NameMap does not contain the source asset name '%s'" % source_name)

	var serialized := _to_dict()
	var stats := {"replacements": 0}
	serialized = _replace_reuse_identity(serialized, source_name, destination_name, stats,
			source_package, target_package)
	if regenerate_guid:
		serialized["PackageGuid"] = _generate_package_guid()
	var copy := _from_dict(serialized, binary_path)
	copy.binary_path = binary_path
	copy.file_path = binary_path
	copy.game_profile = game_profile
	return OperationResult.succeeded(
			"Prepared %s from %s" % [destination_name, source_name], copy, {
				"source_name": source_name,
				"destination_name": destination_name,
				"renamed_name_entries": renamed_name_entries,
				"replacement_count": int(stats["replacements"]),
			})


## Save a reused copy without changing this source object. The regular binary
## save transaction regenerates every required companion and restores existing
## destination files if conversion or installation fails.
func save_reuse_copy(destination_path: String) -> OperationResult:
	return save_clone_copy(destination_path)


## Save a cloned package. Unique packages receive a fresh package GUID.
func save_clone_copy(destination_path: String, regenerate_guid: bool = false,
		source_package: String = "", target_package: String = "") -> OperationResult:
	var prepared := prepare_reuse_copy(
			destination_path, regenerate_guid, source_package, target_package)
	if not prepared.ok:
		return prepared
	var copy := prepared.value as UAssetFile
	# The binary save path writes a staged sibling into the destination folder
	# before installing it, so the destination directory must already exist.
	var parent_error := DirAccess.make_dir_recursive_absolute(
			destination_path.get_base_dir())
	if parent_error != OK:
		return OperationResult.failed(
				"Could not create the destination folder (error %d)" % parent_error,
				prepared.metadata)
	var save_error := copy.save_file(destination_path)
	if save_error != OK:
		return OperationResult.failed(
				"Could not create cloned asset (error %d)" % save_error,
				prepared.metadata)
	return OperationResult.succeeded(
			"Created %s" % destination_path.get_file(), copy, prepared.metadata)


static func _generate_package_guid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	# Use conventional UUID version/variant bits while retaining all 128 GUID bits.
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var hex := ""
	for byte in bytes:
		hex += "%02x" % byte
	return "{%s-%s-%s-%s-%s}" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12),
	]


static func _replace_reuse_identity(value: Variant, source_name: String,
		destination_name: String, stats: Dictionary, source_package: String = "",
		target_package: String = "") -> Variant:
	if value is String:
		var text := value as String
		var occurrences := text.count(source_name)
		if not source_package.is_empty() and source_package != target_package:
			occurrences += text.count(source_package)
			# Swap the package path to a sentinel first so the bare-name rewrite
			# below cannot corrupt a target package that contains the source name
			# as a substring (e.g. GE_Stone -> GE_StoneSkin).
			var placeholder := "__REUSE_PKG_%d__" % (randi() % 0x7fffffff)
			text = text.replace(source_package, placeholder)
			text = text.replace(source_name, destination_name)
			text = text.replace(placeholder, target_package)
		else:
			text = text.replace(source_name, destination_name)
		if occurrences > 0:
			stats["replacements"] = int(stats.get("replacements", 0)) + occurrences
		return text
	if value is Dictionary:
		var dictionary := value as Dictionary
		for key in dictionary.keys():
			# These strings identify serializer classes, not objects in the package.
			if str(key) == "$type":
				continue
			dictionary[key] = _replace_reuse_identity(
					dictionary[key], source_name, destination_name, stats,
					source_package, target_package)
		return dictionary
	if value is Array:
		var array := value as Array
		for index in array.size():
			array[index] = _replace_reuse_identity(
					array[index], source_name, destination_name, stats,
					source_package, target_package)
		return array
	if value is PackedStringArray:
		var strings := value as PackedStringArray
		for index in strings.size():
			strings[index] = _replace_reuse_identity(
					strings[index], source_name, destination_name, stats,
					source_package, target_package)
		return strings
	return value


static func _remove_staged_asset_files(stage_stem: String) -> void:
	for extension in ["uasset", "uexp", "ubulk", "uptnl"]:
		var path: String = stage_stem + "." + extension
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


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


func to_dict() -> Dictionary:
	return _to_dict()


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


# ── Package index table mutations ─────────────────────────────────────────────

const _DEPENDENCY_FIELDS := [
	"CreateBeforeCreateDependencies",
	"CreateBeforeSerializationDependencies",
	"SerializationBeforeCreateDependencies",
	"SerializationBeforeSerializationDependencies",
]


## Capture the two package-indexed tables for an exact undo restore.
func capture_package_tables() -> Dictionary:
	var import_data: Array = []
	for imp in imports:
		import_data.append(imp.to_dict())
	var export_data: Array = []
	for expo in exports:
		export_data.append(expo.to_dict())
	return {"imports": import_data, "exports": export_data}


## Restore a snapshot returned by capture_package_tables().
func restore_package_tables(snapshot: Dictionary) -> void:
	imports.clear()
	exports.clear()
	var import_data: Array = snapshot.get("imports", [])
	for i in import_data.size():
		imports.append(UAssetImport.from_dict((import_data[i] as Dictionary).duplicate(true), -(i + 1), self))
	var export_data: Array = snapshot.get("exports", [])
	for raw_export in export_data:
		exports.append(UAssetExport.from_dict((raw_export as Dictionary).duplicate(true), self))


## Insert exports while preserving every positive package index reference.
func insert_exports(at: int, new_exports: Array) -> void:
	if new_exports.is_empty():
		return
	at = clampi(at, 0, exports.size())
	var first_index := at + 1
	var count := new_exports.size()
	var index_mapper := func(value: int) -> int:
		return value + count if value > 0 and value >= first_index else value
	_remap_all_package_indices(index_mapper)
	for expo in new_exports:
		_remap_export(expo, index_mapper)
	for i in new_exports.size():
		exports.insert(at + i, new_exports[i])


func insert_export(at: int, expo: UAssetExport) -> void:
	insert_exports(at, [expo])


## Remove exports and clear references to deleted entries.
func remove_exports(indices: Array) -> void:
	var normalized := _normalized_indices(indices, exports.size())
	if normalized.is_empty():
		return
	var deleted_package_indices: Array[int] = []
	for index in normalized:
		deleted_package_indices.append(index + 1)
	for i in range(normalized.size() - 1, -1, -1):
		exports.remove_at(normalized[i])
	var index_mapper := func(value: int) -> int:
		if value <= 0:
			return value
		if value in deleted_package_indices:
			return 0
		var shift := 0
		for deleted in deleted_package_indices:
			if deleted < value:
				shift += 1
		return value - shift
	_remap_all_package_indices(index_mapper)


func remove_export_at(index: int) -> void:
	remove_exports([index])


## Insert imports while preserving every negative package index reference.
func insert_imports(at: int, new_imports: Array) -> void:
	if new_imports.is_empty():
		return
	at = clampi(at, 0, imports.size())
	var first_absolute_index := at + 1
	var count := new_imports.size()
	var index_mapper := func(value: int) -> int:
		return value - count if value < 0 and -value >= first_absolute_index else value
	_remap_all_package_indices(index_mapper)
	for imp in new_imports:
		_remap_import(imp, index_mapper)
	for i in new_imports.size():
		imports.insert(at + i, new_imports[i])
	_sync_import_indices()


func insert_import(at: int, imp: UAssetImport) -> void:
	insert_imports(at, [imp])


## Remove imports and clear references to deleted entries.
func remove_imports(indices: Array) -> void:
	var normalized := _normalized_indices(indices, imports.size())
	if normalized.is_empty():
		return
	var deleted_package_indices: Array[int] = []
	for index in normalized:
		deleted_package_indices.append(-(index + 1))
	for i in range(normalized.size() - 1, -1, -1):
		imports.remove_at(normalized[i])
	var index_mapper := func(value: int) -> int:
		if value >= 0:
			return value
		if value in deleted_package_indices:
			return 0
		var shift := 0
		for deleted in deleted_package_indices:
			if deleted > value:
				shift += 1
		return value + shift
	_remap_all_package_indices(index_mapper)
	_sync_import_indices()


func remove_import_at(index: int) -> void:
	remove_imports([index])


## Swap exports and remap references to the two positive package indices.
func swap_exports(a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= exports.size() or b >= exports.size() or a == b:
		return
	var index_a := a + 1
	var index_b := b + 1
	var temp := exports[a]
	exports[a] = exports[b]
	exports[b] = temp
	var index_mapper := func(value: int) -> int:
		if value == index_a:
			return index_b
		if value == index_b:
			return index_a
		return value
	_remap_all_package_indices(index_mapper)


func _remap_all_package_indices(index_mapper: Callable) -> void:
	for expo in exports:
		_remap_export(expo, index_mapper)
	for imp in imports:
		_remap_import(imp, index_mapper)


func _remap_export(expo: UAssetExport, index_mapper: Callable) -> void:
	expo.outer_index = index_mapper.call(expo.outer_index)
	expo.class_index = index_mapper.call(expo.class_index)
	expo.super_index = index_mapper.call(expo.super_index)
	expo.template_index = index_mapper.call(expo.template_index)
	expo.raw["OuterIndex"] = expo.outer_index
	expo.raw["ClassIndex"] = expo.class_index
	expo.raw["SuperIndex"] = expo.super_index
	expo.raw["TemplateIndex"] = expo.template_index
	for field in _DEPENDENCY_FIELDS:
		var raw_dependencies: Variant = expo.raw.get(field)
		if raw_dependencies is Array:
			var dependencies: Array = []
			for raw_index in raw_dependencies:
				var new_index: int = index_mapper.call(int(raw_index))
				if new_index != 0:
					dependencies.append(new_index)
			expo.raw[field] = dependencies
	for prop in expo.properties:
		_remap_property_indices(prop, index_mapper)


func _remap_import(imp: UAssetImport, index_mapper: Callable) -> void:
	imp.outer_index = index_mapper.call(imp.outer_index)
	imp.raw["OuterIndex"] = imp.outer_index


func _remap_property_indices(prop: UAssetProperty, index_mapper: Callable) -> void:
	if prop.prop_type == "Object":
		var value := int(prop.value) if prop.value != null else 0
		prop.value = index_mapper.call(value)
		prop.raw["Value"] = prop.value
	elif prop.value is Dictionary or prop.value is Array:
		_remap_raw_object_references(prop.value, index_mapper)
	for child in prop.children:
		_remap_property_indices(child, index_mapper)


func _remap_raw_object_references(value: Variant, index_mapper: Callable) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		var type_name := str(dictionary.get("$type", ""))
		if "ObjectPropertyData" in type_name \
				and (dictionary.get("Value") is int or dictionary.get("Value") is float):
			dictionary["Value"] = index_mapper.call(int(dictionary["Value"]))
		for key in dictionary:
			var child: Variant = dictionary[key]
			if child is Dictionary or child is Array:
				_remap_raw_object_references(child, index_mapper)
	elif value is Array:
		for child in value:
			if child is Dictionary or child is Array:
				_remap_raw_object_references(child, index_mapper)


func _sync_import_indices() -> void:
	for i in imports.size():
		imports[i].super_index = -(i + 1)


static func _normalized_indices(indices: Array, table_size: int) -> Array[int]:
	var unique: Dictionary = {}
	for raw_index in indices:
		var index := int(raw_index)
		if index >= 0 and index < table_size:
			unique[index] = true
	var result: Array[int] = []
	for index in unique:
		result.append(index)
	result.sort()
	return result


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


## Mirror UAssetAPI's FName.FromStringFragments: when a name ends in "_<digits>"
## it represents FName(base, number) whose binary form points at the BASE string
## in the NameMap. Returns the base ("" when no split applies).
static func _fname_split_base(name: String) -> String:
	if name.is_empty():
		return ""
	var last := name[name.length() - 1]
	if last < "0" or last > "9":
		return ""
	var i := name.length() - 1
	while i > 1 and name[i] >= "0" and name[i] <= "9":
		i -= 1
	if name[i] != "_":
		return ""
	var end_segment := name.substr(i + 1)
	if end_segment.length() > 1 and end_segment[0] == "0":
		return ""
	return name.substr(0, i)


## Ensure every string in the JSON data (except "$type" serializer names), plus
## its parsed FName base, exists in the NameMap. Returns true if the map changed.
func _ensure_all_fnames(data: Variant) -> bool:
	var names: Array[String] = []
	_collect_fname_strings(data, names)
	var added := false
	for name in names:
		if not has_name(name):
			ensure_name(name)
			added = true
		var base := _fname_split_base(name)
		if not base.is_empty() and not has_name(base):
			ensure_name(base)
			added = true
	return added


func _collect_fname_strings(value: Variant, out: Array[String]) -> void:
	if value is Dictionary:
		for key: Variant in value:
			if key == "$type":
				continue
			var child: Variant = value[key]
			if child is String:
				if not child.is_empty():
					out.append(child)
			elif child is Dictionary or child is Array:
				_collect_fname_strings(child, out)
	elif value is Array:
		for child: Variant in value:
			if child is String:
				if not child.is_empty():
					out.append(child)
			elif child is Dictionary or child is Array:
				_collect_fname_strings(child, out)


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


## Resolve a NameMap index back to its string. Returns "" when out of range.
func resolve_name(index: int) -> String:
	if index >= 0 and index < name_map.size():
		return name_map[index]
	return ""


## Find a name's index in the NameMap, optionally appending it when missing.
## Returns -1 when not found and create is false (or the name is empty).
func index_of_name(name: String, create: bool = true) -> int:
	var idx := name_map.find(name)
	if idx >= 0:
		return idx
	if create and not name.is_empty():
		name_map.append(name)
		return name_map.size() - 1
	return -1


## Rename a NameMap entry and propagate the exact whole-string replacement
## through every import/export raw dict so serialized JSON stays consistent.
## References in the object model are index-backed and follow automatically.
## Returns stats: {"renames": N}. Exact-match only — safe for substring
## collisions like GE_Stone -> GE_StoneSkin.
func rename_name(old_name: String, new_name: String) -> Dictionary:
	var stats := {"renames": 0}
	if old_name.is_empty() or old_name == new_name:
		return stats
	for i in name_map.size():
		if name_map[i] == old_name:
			name_map[i] = new_name
			stats["renames"] += 1
	for imp in imports:
		stats["renames"] += _rename_raw_strings(imp.raw, old_name, new_name)
	for expo in exports:
		stats["renames"] += _rename_raw_strings(expo.raw, old_name, new_name)
	return stats


static func _rename_raw_strings(value: Variant, old_name: String,
		new_name: String) -> int:
	if value is String:
		return 1 if value == old_name else 0
	var count := 0
	if value is Dictionary:
		var dictionary := value as Dictionary
		for key in dictionary.keys():
			# These strings identify serializer classes, not names in the package.
			if str(key) == "$type":
				continue
			var child: Variant = dictionary[key]
			if child is String:
				if child == old_name:
					dictionary[key] = new_name
					count += 1
			elif child is Dictionary or child is Array or child is PackedStringArray:
				count += _rename_raw_strings(child, old_name, new_name)
		return count
	if value is Array:
		var array := value as Array
		for i in array.size():
			var child: Variant = array[i]
			if child is String:
				if child == old_name:
					array[i] = new_name
					count += 1
			elif child is Dictionary or child is Array or child is PackedStringArray:
				count += _rename_raw_strings(child, old_name, new_name)
		return count
	if value is PackedStringArray:
		var count_psa := 0
		var strings := value as PackedStringArray
		for i in strings.size():
			if strings[i] == old_name:
				strings[i] = new_name
				count_psa += 1
		return count_psa
	return 0


# ── NameMap index maintenance ─────────────────────────────────────────────────
## NameMap entries are append-only and index-backed, so inserting or removing
## entries shifts every index-based name reference. These helpers remap the
## object model in lockstep so the map and the references never diverge.

static func _normalized_name_indices(indices: Array, map_size: int) -> Array[int]:
	var unique: Dictionary = {}
	for raw_index in indices:
		var index := int(raw_index)
		if index >= 0 and index < map_size:
			unique[index] = true
	var result: Array[int] = []
	for index in unique:
		result.append(index)
	result.sort()
	return result


## Insert names into the NameMap at a position, shifting index references.
## Names already present (or empty) are skipped. Returns the inserted names.
func insert_names(at: int, names: Array) -> Array:
	var to_insert: Array = []
	var seen := {}
	for raw_name in names:
		var s := str(raw_name)
		if s.is_empty() or s in name_map or seen.has(s):
			continue
		seen[s] = true
		to_insert.append(s)
	if to_insert.is_empty():
		return []
	var insert_at := clampi(at, 0, name_map.size())
	var count := to_insert.size()
	var forward := func(value: int) -> int:
		return value + count if value >= insert_at else value
	_remap_name_indices(forward)
	var new_map: Array = []
	var inserted := false
	for i in name_map.size():
		if i == insert_at:
			for n in to_insert:
				new_map.append(n)
			inserted = true
		new_map.append(name_map[i])
	if not inserted:
		for n in to_insert:
			new_map.append(n)
	name_map = PackedStringArray(new_map)
	return to_insert


## Plan which NameMap entries may be removed: an entry is removable only when
## no object-model reference (or raw serialized string) points at it.
## Returns {"deleted": [indices], "kept": [indices], "removed": [names]}.
func plan_name_removal(indices: Array) -> Dictionary:
	var sorted := _normalized_name_indices(indices, name_map.size())
	if sorted.is_empty():
		return {"deleted": [], "kept": [], "removed": []}
	var counts := _count_name_references()
	var raw_strings := _collect_raw_strings()
	var deleted: Array[int] = []
	var kept: Array[int] = []
	for idx in sorted:
		if counts.get(idx, 0) > 0 or raw_strings.has(name_map[idx]):
			kept.append(idx)
		else:
			deleted.append(idx)
	return {
		"deleted": deleted,
		"kept": kept,
		"removed": deleted.map(func(d: int) -> String: return name_map[d]),
	}


## Remove unreferenced NameMap entries, remapping every index reference.
## Entries still referenced anywhere are kept. Returns the removal plan.
func remove_names(indices: Array) -> Dictionary:
	var plan := plan_name_removal(indices)
	var deleted: Array = plan["deleted"]
	if deleted.is_empty():
		return plan
	var forward := func(value: int) -> int:
		var shift := 0
		for d in deleted:
			if d < value:
				shift += 1
		return value - shift
	_remap_name_indices(forward)
	var new_map: Array = []
	for i in name_map.size():
		if i not in deleted:
			new_map.append(name_map[i])
	name_map = PackedStringArray(new_map)
	return plan


## Inverse of remove_names: reinsert previously removed entries at their old
## positions and remap every index reference back into the old coordinate space.
func restore_removed_names(removed: Array, indices: Array) -> void:
	if removed.size() != indices.size():
		return
	for i in removed.size():
		name_map.insert(int(indices[i]), str(removed[i]))
	var inverse := func(value: int) -> int:
		var shift := 0
		for d in indices:
			if int(d) <= value:
				shift += 1
		return value + shift
	_remap_name_indices(inverse)


func _remap_name_indices(mapper: Callable) -> void:
	for imp in imports:
		imp.remap_name_indices(mapper)
	for expo in exports:
		expo.remap_name_indices(mapper)


func _count_name_references() -> Dictionary:
	var counts := {}
	for imp in imports:
		for idx in imp.get_name_indices():
			if idx >= 0:
				counts[idx] = int(counts.get(idx, 0)) + 1
	for expo in exports:
		for idx in expo.get_name_indices():
			if idx >= 0:
				counts[idx] = int(counts.get(idx, 0)) + 1
	return counts


## Collect every distinct string currently present in import/export raw dicts.
## Used to guard NameMap deletions against raw-only references (data table
## rows, Name values, asset paths, ...) that the converter still needs.
func _collect_raw_strings() -> Dictionary:
	var set := {}
	for imp in imports:
		_collect_raw_strings_into(imp.raw, set)
	for expo in exports:
		_collect_raw_strings_into(expo.raw, set)
	return set


static func _collect_raw_strings_into(value: Variant, set: Dictionary) -> void:
	if value is String:
		set[value] = true
	elif value is Dictionary:
		var dictionary := value as Dictionary
		for key in dictionary.keys():
			if str(key) == "$type":
				continue
			_collect_raw_strings_into(dictionary[key], set)
	elif value is Array:
		var array := value as Array
		for child in array:
			_collect_raw_strings_into(child, set)
	elif value is PackedStringArray:
		for s in value:
			set[s] = true


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
	imp.set_asset(self)
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

	var sub_exp := UAssetExport.from_dict(sub_raw, self)
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
		var new_item := UAssetProperty.from_dict(new_item_raw, self)

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
		arr_prop = UAssetProperty.from_dict(arr_raw, self)
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
		arr_prop.children.append(UAssetProperty.from_dict(new_item_raw, self))

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
