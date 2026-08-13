class_name ModFileEntry extends RefCounted

## A file in a mod workspace, with both stable relative and absolute paths.

var relative_path: String
var full_path: String


func _init(relative: String, absolute: String) -> void:
	relative_path = relative
	full_path = absolute


func extension() -> String:
	return relative_path.get_extension().to_lower()
