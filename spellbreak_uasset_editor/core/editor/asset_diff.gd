class_name AssetDiff
extends RefCounted

const STATUS_ADDED := "added"
const STATUS_REMOVED := "removed"
const STATUS_CHANGED := "changed"
const DEFAULT_LIMIT := 5000


static func compare_assets(left: UAssetFile, right: UAssetFile,
		limit: int = DEFAULT_LIMIT) -> Array[Dictionary]:
	return compare_values(left.to_dict(), right.to_dict(), limit)


static func compare_values(left: Variant, right: Variant,
		limit: int = DEFAULT_LIMIT) -> Array[Dictionary]:
	var diffs: Array[Dictionary] = []
	_compare_recursive(left, right, "", diffs, limit)
	return diffs


static func format_value(value: Variant, max_length: int = 160) -> String:
	var text := ""
	if value == null:
		text = "null"
	elif value is Dictionary:
		var dict := value as Dictionary
		var type_name := _short_type_name(str(dict.get("$type", "")))
		if not type_name.is_empty():
			text = "{%s, %d fields}" % [type_name, dict.size()]
		else:
			text = "{%d fields}" % dict.size()
	elif value is Array:
		text = "[%d items]" % (value as Array).size()
	elif value is PackedStringArray:
		text = "[%d names]" % (value as PackedStringArray).size()
	elif value is String:
		text = "\"%s\"" % value
	else:
		text = str(value)
	text = text.replace("\n", "\\n").replace("\t", "\\t")
	if text.length() > max_length:
		text = text.left(max_length - 1) + "..."
	return text


static func _compare_recursive(left: Variant, right: Variant, path: String,
		diffs: Array[Dictionary], limit: int) -> void:
	if diffs.size() >= limit:
		return
	if _values_equal(left, right):
		return

	if left is Dictionary and right is Dictionary:
		_compare_dictionaries(left, right, path, diffs, limit)
		return
	if left is Array and right is Array:
		_compare_arrays(left, right, path, diffs, limit)
		return
	if left is PackedStringArray and right is PackedStringArray:
		_compare_arrays(_packed_string_array_to_array(left),
			_packed_string_array_to_array(right), path, diffs, limit)
		return

	_add_diff(diffs, path, STATUS_CHANGED, left, right, limit)


static func _compare_dictionaries(left: Dictionary, right: Dictionary, path: String,
		diffs: Array[Dictionary], limit: int) -> void:
	var keys: Array[String] = []
	var seen: Dictionary = {}
	for key in left.keys():
		var key_text := str(key)
		keys.append(key_text)
		seen[key_text] = key
	for key in right.keys():
		var key_text := str(key)
		if not seen.has(key_text):
			keys.append(key_text)
	keys.sort()

	for key_text in keys:
		if diffs.size() >= limit:
			return
		var child_path := _join_key(path, key_text)
		if not left.has(key_text):
			_add_diff(diffs, child_path, STATUS_ADDED, null, right[key_text], limit)
		elif not right.has(key_text):
			_add_diff(diffs, child_path, STATUS_REMOVED, left[key_text], null, limit)
		else:
			_compare_recursive(left[key_text], right[key_text], child_path, diffs, limit)


static func _compare_arrays(left: Array, right: Array, path: String,
		diffs: Array[Dictionary], limit: int) -> void:
	var shared_count = mini(left.size(), right.size())
	for i in range(shared_count):
		if diffs.size() >= limit:
			return
		_compare_recursive(left[i], right[i], _join_index(path, i), diffs, limit)
	for i in range(shared_count, left.size()):
		if diffs.size() >= limit:
			return
		_add_diff(diffs, _join_index(path, i), STATUS_REMOVED, left[i], null, limit)
	for i in range(shared_count, right.size()):
		if diffs.size() >= limit:
			return
		_add_diff(diffs, _join_index(path, i), STATUS_ADDED, null, right[i], limit)


static func _add_diff(diffs: Array[Dictionary], path: String, status: String,
		left: Variant, right: Variant, limit: int) -> void:
	if diffs.size() >= limit:
		return
	diffs.append({
		"path": path if not path.is_empty() else "(root)",
		"status": status,
		"left": left,
		"right": right,
	})


static func _values_equal(left: Variant, right: Variant) -> bool:
	if typeof(left) != typeof(right):
		return false
	return left == right


static func _packed_string_array_to_array(values: PackedStringArray) -> Array:
	var result: Array = []
	for value in values:
		result.append(value)
	return result


static func _join_key(path: String, key: String) -> String:
	if path.is_empty():
		return key
	return "%s.%s" % [path, key]


static func _join_index(path: String, index: int) -> String:
	return "%s[%d]" % [path, index]


static func _short_type_name(type_text: String) -> String:
	if type_text.is_empty():
		return ""
	var before_comma := type_text.get_slice(",", 0)
	var parts := before_comma.split(".")
	return parts[parts.size() - 1] if not parts.is_empty() else before_comma
