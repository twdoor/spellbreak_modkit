extends RefCounted

const VERSION_PATTERN := (
	"^[vV]?(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)"
	+ "(?:-([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?"
	+ "(?:[+]([0-9A-Za-z-]+(?:[.][0-9A-Za-z-]+)*))?$"
)


static func parse(version: String) -> Dictionary:
	var text := version.strip_edges()
	var expression := RegEx.new()
	if expression.compile(VERSION_PATTERN) != OK:
		return _invalid_result()

	var matched := expression.search(text)
	if matched == null:
		return _invalid_result()

	var prerelease := PackedStringArray()
	var prerelease_text := matched.get_string(4)
	if not prerelease_text.is_empty():
		prerelease = prerelease_text.split(".", false)
		for identifier: String in prerelease:
			if (
				identifier.is_valid_int()
				and identifier.length() > 1
				and identifier.begins_with("0")
			):
				return _invalid_result()

	var normalized := text
	if normalized.begins_with("v") or normalized.begins_with("V"):
		normalized = normalized.substr(1)

	return {
		"valid": true,
		"normalized": normalized,
		"major": matched.get_string(1).to_int(),
		"minor": matched.get_string(2).to_int(),
		"patch": matched.get_string(3).to_int(),
		"prerelease": prerelease,
		"build": matched.get_string(5),
	}


static func compare(left_version: String, right_version: String) -> int:
	var left := parse(left_version)
	var right := parse(right_version)
	if not bool(left.valid) or not bool(right.valid):
		push_error("SemanticVersion.compare() received an invalid version.")
		return 0

	for key: String in ["major", "minor", "patch"]:
		var left_number := int(left[key])
		var right_number := int(right[key])
		if left_number < right_number:
			return -1
		if left_number > right_number:
			return 1

	var left_prerelease: PackedStringArray = left.prerelease
	var right_prerelease: PackedStringArray = right.prerelease
	if left_prerelease.is_empty() and right_prerelease.is_empty():
		return 0
	if left_prerelease.is_empty():
		return 1
	if right_prerelease.is_empty():
		return -1

	var shared_length := mini(left_prerelease.size(), right_prerelease.size())
	for index: int in shared_length:
		var left_identifier := left_prerelease[index]
		var right_identifier := right_prerelease[index]
		if left_identifier == right_identifier:
			continue

		var left_is_number := left_identifier.is_valid_int()
		var right_is_number := right_identifier.is_valid_int()
		if left_is_number and right_is_number:
			var left_number := left_identifier.to_int()
			var right_number := right_identifier.to_int()
			if left_number < right_number:
				return -1
			return 1
		if left_is_number:
			return -1
		if right_is_number:
			return 1
		if left_identifier < right_identifier:
			return -1
		return 1

	if left_prerelease.size() < right_prerelease.size():
		return -1
	if left_prerelease.size() > right_prerelease.size():
		return 1
	return 0


static func _invalid_result() -> Dictionary:
	return {
		"valid": false,
		"normalized": "",
		"major": 0,
		"minor": 0,
		"patch": 0,
		"prerelease": PackedStringArray(),
		"build": "",
	}
