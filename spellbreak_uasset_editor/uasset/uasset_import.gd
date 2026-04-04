class_name UAssetImport
extends RefCounted


var raw: Dictionary

var super_index: int = 0
var object_name: String
var class_name_str: String
var class_package: String
var package_name: String
var outer_index: int = 0
var import_optional: bool = false


static func from_dict(d: Dictionary, index: int) -> UAssetImport:
	var imp := UAssetImport.new()
	imp.raw = d
	imp.super_index = index
	imp.object_name = str(d.get("ObjectName", ""))
	imp.class_name_str = str(d.get("ClassName", ""))
	imp.class_package = str(d.get("ClassPackage", ""))
	imp.package_name = str(d.get("PackageName", ""))
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
