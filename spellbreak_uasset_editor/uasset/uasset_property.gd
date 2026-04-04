class_name UAssetProperty
extends RefCounted
## Base class for all UAsset properties.
## Handles parsing of UAssetAPI JSON property format.

## The raw dictionary from JSON - kept for round-trip save fidelity
var raw: Dictionary

## Common fields
var prop_name: String
var prop_type: String  # Short type: "Int", "Text", "Enum", "Struct", "Array", etc.
var prop_type_full: String  # Full $type string
var array_index: int = 0
var is_zero: bool = false

## The value - type depends on prop_type
## Simple: String, int, float, bool
## Struct: Array[UAssetProperty]
## Array: Array[UAssetProperty]
## SoftObject: Dictionary with AssetPath info
## null for empty/none
var value  # Variant

## For struct properties
var struct_type: String = ""

## For array properties
var array_type: String = ""

## For enum properties
var enum_type: String = ""

## Child properties (for Struct and Array types)
var children: Array[UAssetProperty] = []

## Extra metadata fields worth exposing
var flags: String = ""
var history_type: int = -1  # TextProperty
var name_space: String = ""  # TextProperty
var culture_invariant: String = ""  # TextProperty (HistoryType = -1)
var source_string: String = ""      # TextProperty (HistoryType = 0, localized base)


static func from_dict(d: Dictionary) -> UAssetProperty:
	var p := UAssetProperty.new()
	p.raw = d
	p.prop_name = str(d.get("Name", ""))
	p.array_index = d.get("ArrayIndex", 0) if d.get("ArrayIndex") != null else 0
	p.is_zero = d.get("IsZero", false) if d.get("IsZero") != null else false
	
	# Parse short type from $type
	var full_type: String = d.get("$type", "")
	p.prop_type_full = full_type
	p.prop_type = _extract_short_type(full_type)
	
	# Type-specific parsing
	match p.prop_type:
		"Int", "Float", "Bool", "Name", "Str", "Byte":
			p.value = d.get("Value")
		
		"Text":
			p.value = d.get("Value")
			p.flags = str(d.get("Flags", ""))
			p.history_type = d.get("HistoryType", -1) if d.get("HistoryType") != null else -1
			p.name_space = str(d.get("Namespace", ""))
			p.culture_invariant = str(d.get("CultureInvariantString", ""))
			p.source_string = str(d.get("SourceString", ""))
		
		"Enum":
			p.value = d.get("Value", "")
			p.enum_type = str(d.get("EnumType", ""))
		
		"Struct":
			p.struct_type = str(d.get("StructType", ""))
			var val = d.get("Value")
			if val is Array:
				for child_dict in val:
					if child_dict is Dictionary:
						p.children.append(UAssetProperty.from_dict(child_dict))
			p.value = null  # Children hold the data
		
		"Array":
			p.array_type = str(d.get("ArrayType", ""))
			var val = d.get("Value")
			if val is Array:
				for child_dict in val:
					if child_dict is Dictionary and child_dict.has("$type"):
						p.children.append(UAssetProperty.from_dict(child_dict))
					elif child_dict is Dictionary:
						# Simple dict element
						p.children.append(_make_raw_child(child_dict))
					else:
						# Primitive array element
						var cp := UAssetProperty.new()
						cp.prop_name = ""
						cp.prop_type = "Raw"
						cp.value = child_dict
						cp.raw = {}
						p.children.append(cp)
			p.value = null
		
		"SoftObject":
			# Value is an FSoftObjectPath dict
			p.value = d.get("Value")
		
		"Object":
			p.value = d.get("Value")
		
		_:
			# Unknown type - store raw value
			p.value = d.get("Value")
	
	return p


## Convert back to dictionary for JSON serialization.
## Merges edits back into the original raw dict for round-trip fidelity.
func to_dict() -> Dictionary:
	var d := raw.duplicate(true)
	
	match prop_type:
		"Int":
			d["Value"] = int(value) if value != null else 0
		"Float":
			d["Value"] = float(value) if value != null else 0.0
		"Bool":
			d["Value"] = bool(value) if value != null else false
		"Name", "Str", "Text", "Enum":
			d["Value"] = str(value) if value != null else ""
		"Byte":
			d["Value"] = value
		"Struct":
			var arr: Array = []
			for child in children:
				arr.append(child.to_dict())
			d["Value"] = arr
		"Array":
			var arr: Array = []
			for child in children:
				if child.prop_type == "Raw" and child.raw.is_empty():
					arr.append(child.value)
				else:
					arr.append(child.to_dict())
			d["Value"] = arr
		"SoftObject":
			d["Value"] = value
		_:
			d["Value"] = value
	
	# Write back editable text fields
	if prop_type == "Text":
		d["Namespace"] = name_space
		if not culture_invariant.is_empty():
			d["CultureInvariantString"] = culture_invariant
		if not source_string.is_empty():
			d["SourceString"] = source_string
		# Flags and HistoryType are numeric enums in UAssetAPI — don't overwrite
		# from our string fields. The raw dict + float-to-int fixer handles them.
	elif prop_type == "Enum":
		d["EnumType"] = enum_type
	elif prop_type == "Struct":
		d["StructType"] = struct_type
	elif prop_type == "Array":
		d["ArrayType"] = array_type
	
	return d


## Get a human-readable display string for this property
func get_display_value() -> String:
	match prop_type:
		"Struct":
			return "[%s] %d children" % [struct_type, children.size()]
		"Array":
			return "[%s] %d items" % [array_type, children.size()]
		"SoftObject":
			if value is Dictionary:
				var ap = value.get("AssetPath", {})
				if ap is Dictionary:
					var asset_name = ap.get("AssetName", "")
					var pkg = ap.get("PackageName", "")
					if asset_name:
						return str(asset_name)
					elif pkg:
						return str(pkg)
			return str(value)
		"Text":
			return str(value) if value else "(empty)"
		"Enum":
			return str(value)
		_:
			return str(value) if value != null else "null"


## Find a child property by name (for Struct types)
func find_child(child_name: String) -> UAssetProperty:
	for child in children:
		if child.prop_name == child_name:
			return child
	return null


## Short type extraction from full $type string
static func _extract_short_type(full_type: String) -> String:
	# "UAssetAPI.PropertyTypes.Objects.IntPropertyData, UAssetAPI" -> "Int"
	var before_comma := full_type.get_slice(",", 0)  # strip ", UAssetAPI"
	var parts := before_comma.split(".")
	var class_name_part: String = parts[parts.size() - 1] if not parts.is_empty() else ""
	return class_name_part.replace("PropertyData", "")


static func _make_raw_child(d: Dictionary) -> UAssetProperty:
	var p := UAssetProperty.new()
	p.raw = d
	p.prop_name = d.get("Name", d.get("ObjectName", ""))
	p.prop_type = "Raw"
	p.value = d
	return p
