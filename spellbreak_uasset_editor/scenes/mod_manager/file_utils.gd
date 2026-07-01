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


static func make_temp_dir(prefix: String) -> Dictionary:
	var temp_root := OS.get_temp_dir()
	var base := "%s_%d_%d" % [prefix, OS.get_process_id(), Time.get_ticks_usec()]
	for suffix in range(16):
		var dir_name := base if suffix == 0 else "%s_%d" % [base, suffix]
		var path := temp_root.path_join(dir_name)
		if DirAccess.dir_exists_absolute(path):
			continue
		var error := DirAccess.make_dir_recursive_absolute(path)
		if error == OK:
			return {"ok": true, "path": path}
		if error != ERR_ALREADY_EXISTS:
			return {
				"ok": false,
				"error": "Could not create temp directory %s (error %d)" % [path, error],
			}
	return {
		"ok": false,
		"error": "Could not create a unique temp directory in %s" % temp_root,
	}


## Write a complete file through a sibling temporary file, then replace the target.
static func write_bytes_atomic(path: String, data: PackedByteArray) -> Error:
	var result := write_bytes_atomic_with_result(path, data)
	return result.get("error", ERR_BUG) as Error


static func write_bytes_atomic_with_result(path: String, data: PackedByteArray,
		keep_backup: bool = false, backup_label: String = "bak") -> Dictionary:
	var parent_error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if parent_error != OK:
		return {"error": parent_error, "backups": []}
	var staged := unique_sibling_path(path, "tmp")
	var output := FileAccess.open(staged, FileAccess.WRITE)
	if not output:
		return {"error": FileAccess.get_open_error(), "backups": []}
	output.store_buffer(data)
	output.close()
	var result := install_staged_files_with_result(
			[{"source": staged, "target": path}], [], keep_backup, backup_label)
	var error := int(result.get("error", ERR_BUG))
	if error != OK and FileAccess.file_exists(staged):
		DirAccess.remove_absolute(staged)
	return result


## Install staged files and remove obsolete targets as one transaction.
## Each file entry is {"source": absolute_path, "target": absolute_path}.
static func install_staged_files(files: Array, removed_targets: Array = []) -> Error:
	var result := install_staged_files_with_result(files, removed_targets)
	return result.get("error", ERR_BUG) as Error


## Variant of install_staged_files() that can keep the transaction backups after
## a successful install. Returned backups are {"backup": path, "target": path}.
static func install_staged_files_with_result(files: Array, removed_targets: Array = [],
		keep_backups: bool = false, backup_label: String = "bak") -> Dictionary:
	if files.is_empty():
		return {"error": ERR_INVALID_PARAMETER, "backups": []}
	var install_targets: Dictionary = {}
	for pair: Dictionary in files:
		var source: String = pair.get("source", "")
		var target: String = pair.get("target", "")
		if source.is_empty() or target.is_empty() or not FileAccess.file_exists(source):
			return {"error": ERR_FILE_NOT_FOUND, "backups": []}
		if install_targets.has(target):
			return {"error": ERR_ALREADY_EXISTS, "backups": []}
		install_targets[target] = true
		var parent_error := DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		if parent_error != OK:
			return {"error": parent_error, "backups": []}
	for target: String in removed_targets:
		if target.is_empty():
			return {"error": ERR_INVALID_PARAMETER, "backups": []}

	var backups: Array = []
	var backup_targets: Array[String] = []
	for pair: Dictionary in files:
		backup_targets.append(str(pair["target"]))
	for target: String in removed_targets:
		if not install_targets.has(target) and target not in backup_targets:
			backup_targets.append(target)
	for target in backup_targets:
		if not FileAccess.file_exists(target):
			continue
		var backup := unique_sibling_path(target, backup_label)
		var backup_error := DirAccess.rename_absolute(target, backup)
		if backup_error != OK:
			_restore_backups(backups)
			return {"error": backup_error, "backups": []}
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
			return {"error": install_error, "backups": []}
		installed.append(target)

	if not keep_backups:
		for pair: Dictionary in backups:
			DirAccess.remove_absolute(pair["backup"])
	return {"error": OK, "backups": backups if keep_backups else []}


static func format_backup_summary(backups: Array) -> String:
	if backups.is_empty():
		return ""
	var paths := PackedStringArray()
	for entry: Dictionary in backups:
		var backup_path := str(entry.get("backup", ""))
		if not backup_path.is_empty():
			paths.append(backup_path)
	if paths.is_empty():
		return ""
	var joined := ", ".join(paths)
	if paths.size() == 1:
		return "Backup: %s" % joined
	return "Backups: %s" % joined


static func restore_backup(backup_entry: Dictionary, keep_current_backup: bool = true) -> Error:
	var backup := str(backup_entry.get("backup", ""))
	var target := str(backup_entry.get("target", ""))
	if backup.is_empty() or target.is_empty():
		return ERR_INVALID_PARAMETER
	if not FileAccess.file_exists(backup):
		return ERR_FILE_NOT_FOUND

	var current_backup := ""
	if FileAccess.file_exists(target):
		current_backup = unique_sibling_path(target, "pre-restore")
		var move_error := DirAccess.rename_absolute(target, current_backup)
		if move_error != OK:
			return move_error

	var copy_error := copy_file(backup, target)
	if copy_error != OK:
		if not current_backup.is_empty() and FileAccess.file_exists(current_backup):
			DirAccess.rename_absolute(current_backup, target)
		return copy_error

	if not keep_current_backup and not current_backup.is_empty() and FileAccess.file_exists(current_backup):
		DirAccess.remove_absolute(current_backup)
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
