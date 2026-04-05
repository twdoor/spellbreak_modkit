class_name ModStateManager extends RefCounted

## Persists which mods are enabled/disabled in .mod_state.json.
## Mirrors the load_state() / save_state() logic in mod_manager.py.
## Format: { "mod_name": true/false, ... }

var _state_path: String = ""
var _state: Dictionary = {}

signal state_changed(mod_name: String, enabled: bool)


func setup(state_path: String) -> ModStateManager:
	_state_path = state_path
	load_state()
	return self


func load_state() -> void:
	_state.clear()
	if not FileAccess.file_exists(_state_path):
		return
	var file := FileAccess.open(_state_path, FileAccess.READ)
	if not file:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_state = parsed


func save() -> void:
	var file := FileAccess.open(_state_path, FileAccess.WRITE)
	if not file:
		push_error("ModStateManager: cannot write to %s" % _state_path)
		return
	file.store_string(JSON.stringify(_state, "  "))
	file.close()


func is_enabled(mod_name: String) -> bool:
	return _state.get(mod_name, false)


func set_enabled(mod_name: String, enabled: bool) -> void:
	_state[mod_name] = enabled
	save()
	state_changed.emit(mod_name, enabled)


func toggle(mod_name: String) -> bool:
	var new_val := not is_enabled(mod_name)
	set_enabled(mod_name, new_val)
	return new_val


## Remove state entries for mods that no longer exist.
func prune(known_names: Array) -> void:
	var to_remove: Array = []
	for k in _state:
		if k not in known_names:
			to_remove.append(k)
	for k in to_remove:
		_state.erase(k)
	if not to_remove.is_empty():
		save()


func get_enabled_names() -> Array:
	var result: Array = []
	for k in _state:
		if _state[k]:
			result.append(k)
	return result


func has_any_enabled() -> bool:
	for k in _state:
		if _state[k]:
			return true
	return false
