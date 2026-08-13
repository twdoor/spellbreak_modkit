class_name OperationResult extends RefCounted

## Named result shared by synchronous toolchain work and background services.

var ok: bool
var message: String
var value: Variant
var metadata: Dictionary
var backups: Array
var logs: PackedStringArray


func _init(success: bool, detail: String = "", result_value: Variant = null,
		result_metadata: Dictionary = {}) -> void:
	ok = success
	message = detail
	value = result_value
	metadata = result_metadata
	backups = []
	logs = PackedStringArray()


static func succeeded(detail: String = "", result_value: Variant = null,
		result_metadata: Dictionary = {}) -> OperationResult:
	return OperationResult.new(true, detail, result_value, result_metadata)


static func failed(detail: String, result_metadata: Dictionary = {}) -> OperationResult:
	return OperationResult.new(false, detail, null, result_metadata)


func with_backups(entries: Array) -> OperationResult:
	backups = entries.duplicate(true)
	return self


func with_log(lines: PackedStringArray) -> OperationResult:
	logs = lines.duplicate()
	return self
