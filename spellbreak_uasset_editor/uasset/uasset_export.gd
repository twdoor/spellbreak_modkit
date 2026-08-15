class_name UAssetExport
extends RefCounted
## Represents one export in a UAsset file.
## Contains metadata and a list of editable properties (Data).

var raw: Dictionary

## Metadata
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

## Owning asset (weak) — resolves the index-backed ObjectName against the NameMap.
var _asset_weak: WeakRef
var _object_name_index: int = -1
var _object_name_fallback: String = ""


## ObjectName — NameMap-backed. Assigning syncs the owning asset's NameMap
## and keeps the raw dict's "ObjectName" in sync when present.
var object_name: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_object_name_index) if asset else _object_name_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			_object_name_index = asset.index_of_name(v)
		else:
			_object_name_fallback = v
		if raw.has("ObjectName"):
			raw["ObjectName"] = v


## Attach an owning asset. Existing fallback strings are adopted into its
## NameMap, making this export's ObjectName index-backed from now on.
func set_asset(asset: UAssetFile) -> void:
	if _asset_weak and _asset_weak.get_ref() == asset:
		return  # already linked
	_asset_weak = weakref(asset)
	var obj := _object_name_fallback
	_object_name_index = -1
	if not obj.is_empty():
		object_name = obj
	for prop in properties:
		prop.set_asset(asset)


func _get_asset() -> UAssetFile:
	if _asset_weak:
		var ref = _asset_weak.get_ref()
		return ref as UAssetFile
	return null


## All NameMap indices this export references (for reference counting).
func get_name_indices() -> Array:
	var indices: Array = [_object_name_index]
	for prop in properties:
		indices.append_array(prop.get_name_indices())
	return indices


## Remap every NameMap index through a mapper (used when entries are inserted
## or removed). Fallback-backed objects keep -1 indices unchanged.
func remap_name_indices(mapper: Callable) -> void:
	_object_name_index = mapper.call(_object_name_index)
	for prop in properties:
		prop.remap_name_indices(mapper)


static func from_dict(d: Dictionary, asset: UAssetFile = null) -> UAssetExport:
	var expo := UAssetExport.new()
	expo.raw = d
	
	# Parse export type from $type
	var full_type: String = d.get("$type", "")
	var type_parts := full_type.get_slice(",", 0).split(".")
	expo.export_type = type_parts[type_parts.size() - 1] if not type_parts.is_empty() else ""
	
	if asset:
		expo.set_asset(asset)
	
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
				expo.properties.append(UAssetProperty.from_dict(prop_dict, asset))
	
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


## Return the raw DataTable row array from this export's Table.Data, or [].
func get_datatable_rows() -> Array:
	var table_raw: Variant = raw.get("Table")
	if table_raw is Dictionary:
		var dr: Variant = table_raw.get("Data")
		if dr is Array:
			return dr as Array
	return []
