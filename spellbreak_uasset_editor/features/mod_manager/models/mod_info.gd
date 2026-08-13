class_name ModInfo extends RefCounted

## Typed metadata for a discovered mod workspace.

var name: String
var path: String
var file_count: int
var size_bytes: int


func _init(mod_name: String, mod_path: String, asset_count: int = 0,
		total_size: int = 0) -> void:
	name = mod_name
	path = mod_path
	file_count = asset_count
	size_bytes = total_size


func to_dictionary() -> Dictionary:
	return {
		"name": name,
		"path": path,
		"file_count": file_count,
		"size_bytes": size_bytes,
	}
