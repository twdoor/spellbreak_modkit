class_name FileUtils extends RefCounted

## Pure-static filesystem helpers shared across the mod manager.
## No state, no UI — just file operations.


## Recursively remove a directory and all its contents.
static func remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var full := path.path_join(entry)
		if dir.is_link(entry):
			DirAccess.remove_absolute(full)
		elif dir.current_is_dir():
			remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## Read bytes from src, create parent dirs for dst, write bytes.
## Returns OK on success or an error code on failure.
static func copy_file(src: String, dst: String) -> Error:
	var input := FileAccess.open(src, FileAccess.READ)
	if not input:
		return FileAccess.get_open_error()
	var data := input.get_buffer(input.get_length())
	input.close()
	return write_bytes_atomic(dst, data)


static func is_path_within(path: String, root: String) -> bool:
	var candidate := _normalized_path(path)
	var base := _normalized_path(root).rstrip("/")
	if candidate.is_empty() or base.is_empty():
		return false
	return candidate == base or candidate.begins_with(base + "/")


static func same_path(a: String, b: String) -> bool:
	return _normalized_path(a) == _normalized_path(b)


static func is_safe_filename(name: String) -> bool:
	if name.is_empty() or name in [".", ".."] or name.get_file() != name:
		return false
	for character in ["/", "\\", "<", ">", ":", "\"", "|", "?", "*"]:
		if character in name:
			return false
	return true


## Write a complete file through a sibling temporary file, then replace the target.
static func write_bytes_atomic(path: String, data: PackedByteArray) -> Error:
	var parent_error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if parent_error != OK:
		return parent_error
	var staged := unique_sibling_path(path, "tmp")
	var output := FileAccess.open(staged, FileAccess.WRITE)
	if not output:
		return FileAccess.get_open_error()
	output.store_buffer(data)
	output.close()
	var error := install_staged_files([{"source": staged, "target": path}])
	if error != OK and FileAccess.file_exists(staged):
		DirAccess.remove_absolute(staged)
	return error


## Install staged files and remove obsolete targets as one transaction.
## Each file entry is {"source": absolute_path, "target": absolute_path}.
static func install_staged_files(files: Array, removed_targets: Array = []) -> Error:
	if files.is_empty():
		return ERR_INVALID_PARAMETER
	var install_targets: Dictionary = {}
	for pair: Dictionary in files:
		var source: String = pair.get("source", "")
		var target: String = pair.get("target", "")
		if source.is_empty() or target.is_empty() or not FileAccess.file_exists(source):
			return ERR_FILE_NOT_FOUND
		if install_targets.has(target):
			return ERR_ALREADY_EXISTS
		install_targets[target] = true
		var parent_error := DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		if parent_error != OK:
			return parent_error
	for target: String in removed_targets:
		if target.is_empty():
			return ERR_INVALID_PARAMETER

	var backups: Array = []
	var backup_targets: Array[String] = []
	for pair: Dictionary in files:
		backup_targets.append(pair["target"])
	for target: String in removed_targets:
		if not install_targets.has(target) and target not in backup_targets:
			backup_targets.append(target)
	for target in backup_targets:
		if not FileAccess.file_exists(target):
			continue
		var backup := unique_sibling_path(target, "bak")
		var backup_error := DirAccess.rename_absolute(target, backup)
		if backup_error != OK:
			_restore_backups(backups)
			return backup_error
		backups.append({"backup": backup, "target": target})

	var installed: Array[String] = []
	for pair: Dictionary in files:
		var source: String = pair["source"]
		var target: String = pair["target"]
		var install_error := DirAccess.rename_absolute(source, target)
		if install_error != OK:
			for installed_target in installed:
				if FileAccess.file_exists(installed_target):
					DirAccess.remove_absolute(installed_target)
			_restore_backups(backups)
			return install_error
		installed.append(target)

	for pair: Dictionary in backups:
		DirAccess.remove_absolute(pair["backup"])
	return OK


static func unique_sibling_path(path: String, label: String) -> String:
	var parent := path.get_base_dir()
	var filename := path.get_file()
	var base := parent.path_join(".%s.sb_%s_%d" % [filename, label, OS.get_process_id()])
	var candidate := base
	var suffix := 0
	while FileAccess.file_exists(candidate) or DirAccess.dir_exists_absolute(candidate):
		suffix += 1
		candidate = "%s_%d" % [base, suffix]
	return candidate


static func _restore_backups(backups: Array) -> void:
	for i in range(backups.size() - 1, -1, -1):
		var pair: Dictionary = backups[i]
		var target: String = pair["target"]
		if FileAccess.file_exists(target):
			DirAccess.remove_absolute(target)
		if FileAccess.file_exists(pair["backup"]):
			DirAccess.rename_absolute(pair["backup"], target)


static func _normalized_path(path: String) -> String:
	var result := path.replace("\\", "/").simplify_path().rstrip("/")
	return result.to_lower() if OS.get_name() == "Windows" else result
