class_name UAssetExport
extends RefCounted
## Represents one export in a UAsset file.
## Contains metadata and a list of editable properties (Data).

var raw: Dictionary

## Metadata
var object_name: String
var outer_index: int = 0
var class_index: int = 0
var super_index: int = 0
var template_index: int = 0
var object_flags: String = ""
var object_guid: Variant  # String or null
var serial_size: int = 0
var serial_offset: int = 0
var export_type: String  # "NormalExport", "RawExport", etc.

## Properties (the editable data)
var properties: Array[UAssetProperty] = []


static func from_dict(d: Dictionary) -> UAssetExport:
	var expo := UAssetExport.new()
	expo.raw = d
	
	# Parse export type from $type
	var full_type: String = d.get("$type", "")
	var type_parts := full_type.get_slice(",", 0).split(".")
	expo.export_type = type_parts[type_parts.size() - 1] if not type_parts.is_empty() else ""
	
	# Metadata
	expo.object_name = str(d.get("ObjectName", ""))
	expo.outer_index = d.get("OuterIndex", 0) if d.get("OuterIndex") != null else 0
	expo.class_index = d.get("ClassIndex", 0) if d.get("ClassIndex") != null else 0
	expo.super_index = d.get("SuperIndex", 0) if d.get("SuperIndex") != null else 0
	expo.template_index = d.get("TemplateIndex", 0) if d.get("TemplateIndex") != null else 0
	expo.object_flags = str(d.get("ObjectFlags", ""))
	expo.object_guid = d.get("ObjectGuid")
	expo.serial_size = d.get("SerialSize", 0) if d.get("SerialSize") != null else 0
	expo.serial_offset = d.get("SerialOffset", 0) if d.get("SerialOffset") != null else 0
	
	# Parse properties
	var data_arr = d.get("Data")
	if data_arr is Array:
		for prop_dict in data_arr:
			if prop_dict is Dictionary:
				expo.properties.append(UAssetProperty.from_dict(prop_dict))
	
	return expo


func to_dict() -> Dictionary:
	var d := raw.duplicate(true)
	d["ObjectName"] = object_name
	d["OuterIndex"] = outer_index
	d["ClassIndex"] = class_index
	d["SuperIndex"] = super_index
	d["TemplateIndex"] = template_index
	d["ObjectFlags"] = object_flags
	d["ObjectGuid"] = object_guid
	d["SerialSize"] = serial_size
	d["SerialOffset"] = serial_offset
	
	# Serialize properties back
	var data_arr: Array = []
	for prop in properties:
		data_arr.append(prop.to_dict())
	d["Data"] = data_arr
	
	return d


## Find a property by name
func find_property(prop_name: String) -> UAssetProperty:
	for prop in properties:
		if prop.prop_name == prop_name:
			return prop
	return null


## Get all property names
func get_property_names() -> PackedStringArray:
	var names := PackedStringArray()
	for prop in properties:
		names.append(prop.prop_name)
	return names


func get_display_name() -> String:
	return "%s (%s)" % [object_name, export_type]
