class_name AssetDocument extends RefCounted

## Owns one editable asset and its command history. Dirty state is derived from
## the current history position instead of being toggled independently by UI.

signal dirty_changed(is_dirty: bool)

const MAX_HISTORY := 100

var asset: UAssetFile
var _history: Array[AssetEditCommand] = []
var _cursor := 0
var _saved_cursor := 0
var _last_dirty := false


func _init(initial_asset: UAssetFile = null) -> void:
	asset = initial_asset


func replace_asset(new_asset: UAssetFile) -> void:
	asset = new_asset
	_history.clear()
	_cursor = 0
	_saved_cursor = 0
	_last_dirty = false
	dirty_changed.emit(false)


func execute(command: AssetEditCommand) -> bool:
	if command == null or not command.is_valid():
		return false
	command.apply()
	_record(command)
	return true


## Record a command when a widget already applied its new value before emitting.
func record_applied(command: AssetEditCommand) -> bool:
	if command == null or not command.is_valid():
		return false
	_record(command)
	return true


func undo() -> bool:
	if not can_undo():
		return false
	_cursor -= 1
	_history[_cursor].revert()
	_emit_state_changed()
	return true


func redo() -> bool:
	if not can_redo():
		return false
	_history[_cursor].apply()
	_cursor += 1
	_emit_state_changed()
	return true


func can_undo() -> bool:
	return _cursor > 0


func can_redo() -> bool:
	return _cursor < _history.size()


func is_dirty() -> bool:
	return _saved_cursor < 0 or _cursor != _saved_cursor


func mark_saved() -> void:
	_saved_cursor = _cursor
	_emit_dirty_if_changed()


func clear_history() -> void:
	_history.clear()
	_cursor = 0
	_saved_cursor = 0
	_emit_state_changed()


func _record(command: AssetEditCommand) -> void:
	if _cursor < _history.size():
		_history.resize(_cursor)
		if _saved_cursor > _cursor:
			_saved_cursor = -1
	_history.append(command)
	_cursor += 1
	_trim_history()
	_emit_state_changed()


func _trim_history() -> void:
	var overflow := _history.size() - MAX_HISTORY
	if overflow <= 0:
		return
	_history = _history.slice(overflow)
	_cursor -= overflow
	if _saved_cursor >= 0:
		_saved_cursor -= overflow
		if _saved_cursor < 0:
			_saved_cursor = -1


func _emit_state_changed() -> void:
	_emit_dirty_if_changed()


func _emit_dirty_if_changed() -> void:
	var current_dirty := is_dirty()
	if current_dirty == _last_dirty:
		return
	_last_dirty = current_dirty
	dirty_changed.emit(current_dirty)
