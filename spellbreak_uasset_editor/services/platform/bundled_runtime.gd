class_name BundledRuntime extends RefCounted

## A platform-specific archive is embedded in each release. Extract once to a
## content-addressed directory: changing a runtime never reuses stale files.
static var _mutex := Mutex.new()
static var _root := ""
static var _tools: Dictionary = {}


static func executable(tool: String) -> String:
	_mutex.lock()
	if _root.is_empty():
		_extract()
	var relative := str(_tools.get(tool, ""))
	var result := _root.path_join(relative) if not _root.is_empty() and not relative.is_empty() else ""
	_mutex.unlock()
	return result if FileAccess.file_exists(result) else ""


static func platform_id() -> String:
	if Engine.get_architecture_name() != "x86_64":
		return ""
	match OS.get_name():
		"Linux": return "linux-x64"
		"Windows": return "win-x64"
	return ""


static func _extract() -> void:
	var platform := platform_id()
	if platform.is_empty():
		return
	var archive := "res://runtimes/%s.zip" % platform
	if not FileAccess.file_exists(archive):
		return
	var digest := FileAccess.get_sha256(archive)
	var target := OS.get_user_data_dir().path_join("runtimes").path_join(platform + "-" + digest)
	var zip := ZIPReader.new()
	if zip.open(archive) != OK:
		push_error("Could not open bundled runtime archive")
		return
	var manifest: Variant = JSON.parse_string(zip.read_file("manifest.json").get_string_from_utf8())
	if not manifest is Dictionary or not manifest.get("tools") is Dictionary:
		zip.close()
		return
	if FileAccess.file_exists(target.path_join(".complete")) and _tools_exist(target, manifest.tools):
		_tools = manifest.tools
		_root = target
		zip.close()
		return
	var staging := target + ".tmp-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var error := DirAccess.make_dir_recursive_absolute(staging)
	for relative in zip.get_files():
		if error != OK:
			break
		if not _safe_relative(relative):
			error = ERR_INVALID_DATA
			break
		if relative.ends_with("/"):
			continue
		var destination := staging.path_join(relative)
		# The entire directory is staged, so per-file backup/rename transactions
		# would only slow down first launch for thousands of standard-library files.
		error = DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		if error != OK:
			break
		var file := FileAccess.open(destination, FileAccess.WRITE)
		if file == null:
			error = FileAccess.get_open_error()
			break
		file.store_buffer(zip.read_file(relative))
		error = file.get_error()
		file.close()
		if error == OK and OS.get_name() != "Windows":
			var mode := 493 if relative in manifest.get("executables", []) else 420
			error = FileAccess.set_unix_permissions(destination, mode)
	zip.close()
	if error == OK and not _tools_exist(staging, manifest.tools):
		error = ERR_FILE_NOT_FOUND
	if error == OK:
		error = FileUtils.write_bytes_atomic(staging.path_join(".complete"), digest.to_utf8_buffer())
	if error == OK:
		error = DirAccess.rename_absolute(staging, target)
		# Another editor process may have finished the same extraction first.
		if error != OK and FileAccess.file_exists(target.path_join(".complete")) and _tools_exist(target, manifest.tools):
			error = OK
	if DirAccess.dir_exists_absolute(staging):
		FileUtils.remove_dir_recursive(staging)
	if error != OK:
		push_error("Could not extract bundled runtimes (error %d): %s" % [error, target])
		return
	_tools = manifest.tools
	_root = target


static func _safe_relative(path: String) -> bool:
	return not path.is_empty() and not path.is_absolute_path() and not "\\" in path and not ":" in path and not ".." in path.split("/")


static func _tools_exist(root: String, tools: Dictionary) -> bool:
	for relative in tools.values():
		if not _safe_relative(str(relative)) or not FileAccess.file_exists(root.path_join(str(relative))):
			return false
	return true
