class_name UAssetProperty
extends RefCounted
## Base class for all UAsset properties.
## Handles parsing of UAssetAPI JSON property format.

## The raw dictionary from JSON - kept for round-trip save fidelity
var raw: Dictionary

## Common fields
var prop_type: String  # Short type: "Int", "Float", "Bool", "Name", "Str", "Enum", "Struct", "Array", etc.
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

## Owning asset (weak) — resolves the index-backed prop_name against the NameMap.
var _asset_weak: WeakRef
var _prop_name_index: int = -1
var _prop_name_suffix: String = ""
var _prop_name_fallback: String = ""


## PropName — NameMap-backed. Assigning syncs the owning asset's NameMap
## and keeps the raw dict's "Name" in sync when present.
var prop_name: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_prop_name_index) + _prop_name_suffix \
				if asset else _prop_name_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			var parts := UAssetFile.split_fname(v)
			_prop_name_index = asset.index_of_name(parts["base"])
			_prop_name_suffix = parts["suffix"]
		_prop_name_fallback = v
		if raw.has("Name"):
			raw["Name"] = v


## Attach an owning asset. Existing fallback strings are adopted into its
## NameMap, making this property's prop_name index-backed from now on.
func set_asset(asset: UAssetFile) -> void:
	if _asset_weak and _asset_weak.get_ref() == asset:
		return  # already linked
	var name := prop_name
	_asset_weak = weakref(asset)
	_prop_name_index = -1
	_prop_name_suffix = ""
	if not name.is_empty():
		prop_name = name
	for child in children:
		child.set_asset(asset)


func _get_asset() -> UAssetFile:
	if _asset_weak:
		var ref = _asset_weak.get_ref()
		return ref as UAssetFile
	return null


## All NameMap indices this property references (for reference counting).
func get_name_indices() -> Array:
	var indices: Array = [_prop_name_index]
	for child in children:
		indices.append_array(child.get_name_indices())
	return indices


## Remap every NameMap index through a mapper (used when entries are inserted
## or removed). Fallback-backed objects keep -1 indices unchanged.
func remap_name_indices(mapper: Callable) -> void:
	_prop_name_index = mapper.call(_prop_name_index)
	for child in children:
		child.remap_name_indices(mapper)


static func from_dict(d: Dictionary, asset: UAssetFile = null) -> UAssetProperty:
	var p := UAssetProperty.new()
	p.raw = d
	if asset:
		p.set_asset(asset)
	p.prop_name = str(d.get("Name", ""))
	p.array_index = d.get("ArrayIndex", 0) if d.get("ArrayIndex") != null else 0
	p.is_zero = d.get("IsZero", false) if d.get("IsZero") != null else false
	
	# Parse short type from $type
	var full_type: String = d.get("$type", "")
	p.prop_type_full = full_type
	p.prop_type = _extract_short_type(full_type)
	
	# Type-specific parsing
	match p.prop_type:
		"Int", "Float", "Bool", "Name", "Str":
			p.value = d.get("Value")

		"Byte":
			if d.has("EnumValue") and (not d.has("Value") or d.get("Value") == null):
				p.value = str(d.get("EnumValue", ""))
			elif d.has("Value"):
				p.value = d.get("Value")
			else:
				p.value = null
		
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
						p.children.append(UAssetProperty.from_dict(child_dict, asset))
				p.value = null  # Children hold the data
			else:
				p.value = val
		
		"Array":
			p.array_type = str(d.get("ArrayType", ""))
			var val = d.get("Value")
			if val is Array:
				for child_dict in val:
					if child_dict is Dictionary and child_dict.has("$type"):
						p.children.append(UAssetProperty.from_dict(child_dict, asset))
					elif child_dict is Dictionary:
						# Simple dict element
						p.children.append(_make_raw_child(child_dict, asset))
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
		
		"Map":
			# Value is a list of [key, value] pairs. Each pair is parsed into a
			# "MapPair" child so entries can be edited and round-trip faithfully.
			var val = d.get("Value")
			if val is Array:
				for pair_dict in val:
					if pair_dict is Array and pair_dict.size() >= 2 \
							and pair_dict[0] is Dictionary and pair_dict[1] is Dictionary:
						p.children.append(_make_map_pair(pair_dict, asset))
					else:
						var cp := UAssetProperty.new()
						cp.prop_type = "Raw"
						cp.value = pair_dict
						cp.raw = {}
						p.children.append(cp)
				p.value = null  # Children hold the data
			else:
				p.value = val
		
		"MapPair":
			# Value is a [key, value] pair array (used when a copied entry is re-parsed)
			var val = d.get("Value")
			if val is Array and val.size() >= 2 \
					and val[0] is Dictionary and val[1] is Dictionary:
				p.children.append(UAssetProperty.from_dict(val[0], asset))
				p.children.append(UAssetProperty.from_dict(val[1], asset))
				p.value = null
			else:
				p.value = val
		
		_:
			# Unknown type - store raw value
			p.value = d.get("Value")
	
	return p


func capture_state() -> Dictionary:
	return to_dict().duplicate(true)


func restore_state(state: Dictionary) -> void:
	var restored := UAssetProperty.from_dict(state.duplicate(true), _get_asset())
	raw = restored.raw
	_prop_name_index = restored._prop_name_index
	_prop_name_suffix = restored._prop_name_suffix
	_prop_name_fallback = restored._prop_name_fallback
	prop_type = restored.prop_type
	prop_type_full = restored.prop_type_full
	array_index = restored.array_index
	is_zero = restored.is_zero
	value = restored.value
	struct_type = restored.struct_type
	array_type = restored.array_type
	enum_type = restored.enum_type
	children = restored.children
	flags = restored.flags
	history_type = restored.history_type
	name_space = restored.name_space
	culture_invariant = restored.culture_invariant
	source_string = restored.source_string


func set_value(new_value: Variant) -> void:
	value = new_value.duplicate(true) if new_value is Array or new_value is Dictionary else new_value
	if prop_type == "Byte" and raw.has("EnumValue") and (not raw.has("Value") or value is String):
		raw["EnumValue"] = str(value) if value != null else ""
		raw.erase("Value")
	else:
		raw["Value"] = value


## Convert back to dictionary for JSON serialization.
## Merges edits back into the original raw dict for round-trip fidelity.
func to_dict() -> Dictionary:
	var d := raw.duplicate(true)
	
	# PropName is NameMap-backed — always emit the resolved string so the
	# serialized JSON mirrors the current NameMap, even after a rename.
	if d.has("Name"):
		d["Name"] = prop_name
	
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
			if d.has("EnumValue") and (not raw.has("Value") or value is String):
				d["EnumValue"] = str(value) if value != null else str(d.get("EnumValue", ""))
				d.erase("Value")
			else:
				d["Value"] = int(value) if value != null else 0
		"Struct":
			if children.size() > 0:
				var arr: Array = []
				for child in children:
					arr.append(child.to_dict())
				d["Value"] = arr
			else:
				d["Value"] = value
		"Array":
			var arr: Array = []
			for child in children:
				if child.prop_type == "Raw" and child.raw.is_empty():
					arr.append(child.value)
				else:
					arr.append(child.to_dict())
			d["Value"] = arr
		"Map":
			var pairs: Array = []
			for child in children:
				if child.prop_type == "Raw" and child.raw.is_empty():
					pairs.append(child.value)
				elif child.prop_type == "MapPair":
					pairs.append((child.to_dict() as Dictionary).get("Value", []))
				else:
					pairs.append(child.raw.duplicate(true) if child.raw is Dictionary else child.value)
			d["Value"] = pairs
		"MapPair":
			if children.size() >= 2:
				var pair_val: Array = []
				for child in children:
					pair_val.append(child.to_dict())
				d["Value"] = pair_val
			else:
				d["Value"] = value
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
		"Map":
			return "[map] %d entries" % children.size()
		"MapPair":
			if children.size() >= 1:
				var key := children[0]
				if key.prop_type == "Struct":
					var tag_child := key.find_child("TagName")
					if tag_child:
						return str(tag_child.value) if tag_child.value != null else ""
				return key.get_display_value()
			return "?"
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


static func _make_raw_child(d: Dictionary, asset: UAssetFile = null) -> UAssetProperty:
	var p := UAssetProperty.new()
	p.raw = d
	if asset:
		p.set_asset(asset)
	p.prop_name = d.get("Name", d.get("ObjectName", ""))
	p.prop_type = "Raw"
	p.value = d
	return p


## Wrap a raw [key, value] pair array (UAssetAPI MapPropertyData Value element)
## into a "MapPair" property whose children are the parsed key and value.
static func _make_map_pair(pair_dict: Array, asset: UAssetFile = null) -> UAssetProperty:
	var p := UAssetProperty.new()
	p.raw = {"$type": "MapPair", "Value": pair_dict}
	p.prop_type = "MapPair"
	if asset:
		p.set_asset(asset)
	p.children.append(UAssetProperty.from_dict(pair_dict[0] as Dictionary, asset))
	p.children.append(UAssetProperty.from_dict(pair_dict[1] as Dictionary, asset))
	return p
