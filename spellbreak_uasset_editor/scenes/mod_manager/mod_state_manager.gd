class_name ModStateManager extends RefCounted

## Persists which mods are enabled/disabled in .mod_state.json.
## Mirrors the load_state() / save_state() logic in mod_manager.py.
## Format: { "mod_name": true/false, ... }

var _state_path: String = ""
var _state: Dictionary = {}
var _state_mutex := Mutex.new()

signal state_changed(mod_name: String, enabled: bool)


func setup(state_path: String) -> ModStateManager:
	_state_path = state_path
	load_state()
	return self


func load_state() -> void:
	_state_mutex.lock()
	_state.clear()
	_state_mutex.unlock()
	if not FileAccess.file_exists(_state_path):
		return
	var file := FileAccess.open(_state_path, FileAccess.READ)
	if not file:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_state_mutex.lock()
		_state = parsed
		_state_mutex.unlock()


func save() -> void:
	_state_mutex.lock()
	var snapshot := _state.duplicate(true)
	_state_mutex.unlock()
	var error := FileUtils.write_bytes_atomic(_state_path, JSON.stringify(snapshot, "  ").to_utf8_buffer())
	if error != OK:
		push_error("ModStateManager: cannot write to %s" % _state_path)


func is_enabled(mod_name: String) -> bool:
	_state_mutex.lock()
	var result := bool(_state.get(mod_name, false))
	_state_mutex.unlock()
	return result


func set_enabled(mod_name: String, enabled: bool) -> void:
	_state_mutex.lock()
	_state[mod_name] = enabled
	_state_mutex.unlock()
	save()
	state_changed.emit(mod_name, enabled)


func toggle(mod_name: String) -> bool:
	var new_val := not is_enabled(mod_name)
	set_enabled(mod_name, new_val)
	return new_val


## Remove state entries for mods that no longer exist.
func prune(known_names: Array) -> void:
	var to_remove: Array = []
	_state_mutex.lock()
	for k in _state:
		if k not in known_names:
			to_remove.append(k)
	for k in to_remove:
		_state.erase(k)
	_state_mutex.unlock()
	if not to_remove.is_empty():
		save()


func get_enabled_names() -> Array:
	var result: Array = []
	_state_mutex.lock()
	for k in _state:
		if _state[k]:
			result.append(k)
	_state_mutex.unlock()
	return result


func has_any_enabled() -> bool:
	_state_mutex.lock()
	for k in _state:
		if _state[k]:
			_state_mutex.unlock()
			return true
	_state_mutex.unlock()
	return false
