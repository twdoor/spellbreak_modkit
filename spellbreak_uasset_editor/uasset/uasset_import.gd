class_name UAssetImport
extends RefCounted


var raw: Dictionary

var super_index: int = 0
var outer_index: int = 0
var import_optional: bool = false

## Owning asset (weak) — resolves index-backed name fields against the NameMap.
var _asset_weak: WeakRef

## NameMap indices; -1 means "unlinked" (uses the fallback strings).
var _object_name_index: int = -1
var _class_name_index: int = -1
var _class_package_index: int = -1
var _package_name_index: int = -1
var _object_name_suffix: String = ""
var _class_name_suffix: String = ""
var _class_package_suffix: String = ""
var _package_name_suffix: String = ""

## Fallback strings used when no asset is attached (tests / detached objects).
var _object_name_fallback: String = ""
var _class_name_fallback: String = ""
var _class_package_fallback: String = ""
var _package_name_fallback: String = ""


## ObjectName — NameMap-backed. Assigning syncs the owning asset's NameMap
## and keeps the raw dict's "ObjectName" in sync when present.
var object_name: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_object_name_index) + _object_name_suffix \
				if asset else _object_name_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			var parts := UAssetFile.split_fname(v)
			_object_name_index = asset.index_of_name(parts["base"])
			_object_name_suffix = parts["suffix"]
		_object_name_fallback = v
		if raw.has("ObjectName"):
			raw["ObjectName"] = v


## ClassName — NameMap-backed.
var class_name_str: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_class_name_index) + _class_name_suffix \
				if asset else _class_name_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			var parts := UAssetFile.split_fname(v)
			_class_name_index = asset.index_of_name(parts["base"])
			_class_name_suffix = parts["suffix"]
		_class_name_fallback = v
		if raw.has("ClassName"):
			raw["ClassName"] = v


## ClassPackage — NameMap-backed.
var class_package: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_class_package_index) + _class_package_suffix \
				if asset else _class_package_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			var parts := UAssetFile.split_fname(v)
			_class_package_index = asset.index_of_name(parts["base"])
			_class_package_suffix = parts["suffix"]
		_class_package_fallback = v
		if raw.has("ClassPackage"):
			raw["ClassPackage"] = v


## PackageName — NameMap-backed. Empty names are allowed and stay unlinked.
var package_name: String:
	get:
		var asset := _get_asset()
		return asset.resolve_name(_package_name_index) + _package_name_suffix \
				if asset else _package_name_fallback
	set(v):
		var asset := _get_asset()
		if asset:
			var parts := UAssetFile.split_fname(v)
			_package_name_index = asset.index_of_name(parts["base"])
			_package_name_suffix = parts["suffix"]
		_package_name_fallback = v
		if raw.has("PackageName"):
			raw["PackageName"] = v


## Attach an owning asset. Existing fallback strings are adopted into its
## NameMap, making this import's references index-backed from now on.
func set_asset(asset: UAssetFile) -> void:
	if _asset_weak and _asset_weak.get_ref() == asset:
		return  # already linked
	var obj := object_name
	var cls := class_name_str
	var pkg := class_package
	var pname := package_name
	_asset_weak = weakref(asset)
	_object_name_index = -1
	_class_name_index = -1
	_class_package_index = -1
	_package_name_index = -1
	_object_name_suffix = ""
	_class_name_suffix = ""
	_class_package_suffix = ""
	_package_name_suffix = ""
	if not obj.is_empty():
		object_name = obj
	if not cls.is_empty():
		class_name_str = cls
	if not pkg.is_empty():
		class_package = pkg
	if not pname.is_empty():
		package_name = pname


func _get_asset() -> UAssetFile:
	if _asset_weak:
		var ref = _asset_weak.get_ref()
		return ref as UAssetFile
	return null


## All NameMap indices this import references (for reference counting).
func get_name_indices() -> Array:
	return [_object_name_index, _class_name_index, _class_package_index,
			_package_name_index]


## Remap every NameMap index through a mapper (used when entries are inserted
## or removed). Fallback-backed objects keep -1 indices unchanged.
func remap_name_indices(mapper: Callable) -> void:
	_object_name_index = mapper.call(_object_name_index)
	_class_name_index = mapper.call(_class_name_index)
	_class_package_index = mapper.call(_class_package_index)
	_package_name_index = mapper.call(_package_name_index)


static func from_dict(d: Dictionary, index: int,
		asset: UAssetFile = null) -> UAssetImport:
	var imp := UAssetImport.new()
	imp.raw = d
	imp.super_index = index
	if asset:
		imp.set_asset(asset)
	imp.object_name = str(d.get("ObjectName", ""))
	imp.class_name_str = str(d.get("ClassName", ""))
	imp.class_package = str(d.get("ClassPackage", ""))
	var package_name_value: Variant = d.get("PackageName")
	imp.package_name = "" if package_name_value == null else str(package_name_value)
	imp.outer_index = d.get("OuterIndex", 0) if d.get("OuterIndex") != null else 0
	imp.import_optional = d.get("bImportOptional", false) if d.get("bImportOptional") != null else false
	return imp


func to_dict() -> Dictionary:
	var d := raw.duplicate(true)
	d["ObjectName"] = object_name
	d["ClassName"] = class_name_str
	d["ClassPackage"] = class_package
	if package_name.is_empty():
		d["PackageName"] = null
	else:
		d["PackageName"] = package_name
	d["OuterIndex"] = outer_index
	d["bImportOptional"] = import_optional
	return d


func get_display_name() -> String:
	return "%s (%s)" % [object_name, class_name_str]
