class_name BaseSourceService extends RefCounted

## Extracts a selected game pak into a source directory via bundled u4pak.py.
## Runs in a worker thread so the Settings tab stays responsive.

signal generate_started
signal generate_finished(success: bool, message: String, source_name: String, source_path: String)

var _cfg: ModConfigManager
var _thread: Thread = null
var _generating := false
var _mutex := Mutex.new()


func setup(cfg: ModConfigManager) -> BaseSourceService:
	_cfg = cfg
	return self


func is_generating() -> bool:
	_mutex.lock()
	var result := _generating
	_mutex.unlock()
	return result


func wait_to_finish() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func generate(pak_path: String, output_dir: String) -> void:
	_mutex.lock()
	if _generating:
		_mutex.unlock()
		return
	_generating = true
	_mutex.unlock()

	generate_started.emit()
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_generate_thread.bind(pak_path, output_dir))


func _generate_thread(pak_path: String, output_dir: String) -> void:
	var result := _do_generate(pak_path, output_dir)
	call_deferred("_on_generate_done", result[0], result[1], result[2], result[3])


func _on_generate_done(success: bool, message: String, source_name: String, source_path: String) -> void:
	_mutex.lock()
	_generating = false
	_mutex.unlock()
	if _thread:
		_thread.wait_to_finish()
	generate_finished.emit(success, message, source_name, source_path)


func _do_generate(pak_path: String, output_dir: String) -> Array:
	pak_path = pak_path.strip_edges()
	output_dir = output_dir.strip_edges().rstrip("/")
	if pak_path.is_empty():
		return [false, "Select a game package first", "", ""]
	if output_dir.is_empty():
		return [false, "Select an output folder first", "", ""]
	if not FileAccess.file_exists(pak_path):
		return [false, "Game package not found: %s" % pak_path, "", ""]
	if pak_path.get_extension().to_lower() != "pak":
		return [false, "Game package must be a .pak file", "", ""]

	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		return [false, "Could not create output folder (error %d)" % mkdir_error, "", ""]

	var u4pak_path := _cfg.get_u4pak_path()
	if not FileAccess.file_exists(u4pak_path):
		return [false, "u4pak.py not found: %s" % u4pak_path, "", ""]
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return [false, "Python was not found in PATH", "", ""]

	var path_check := _resolve_archive_args(python, u4pak_path, pak_path)
	if not bool(path_check[0]):
		return [false, str(path_check[1]), "", ""]
	var archive_args: Array = path_check[2]

	var output: Array = []
	var unpack_args: Array = ["unpack"]
	unpack_args.append_array(archive_args)
	unpack_args.append_array(["-C", output_dir, pak_path])
	var code := ProcessUtils.run_python_script(
			python, u4pak_path, u4pak_path.get_base_dir(), unpack_args, output)
	if code != 0:
		var detail := ProcessUtils.output_text(output, "no output")
		return [false, "Unpack failed (exit %d): %s" % [code, detail], "", ""]

	var content_root := _cfg.get_game_profile().content_root
	var source_content := output_dir.path_join(content_root)
	if not DirAccess.dir_exists_absolute(source_content):
		return [
			false,
			"Extracted pak, but output folder does not contain %s/" % content_root,
			"",
			"",
		]

	return [true, "Generated base source from %s" % pak_path.get_file(),
			_default_source_name(pak_path), output_dir]


func _resolve_archive_args(python: String, u4pak_path: String, pak_path: String) -> Array:
	var strict_result := _validate_archive_paths(python, u4pak_path, pak_path, [])
	if bool(strict_result[0]):
		return [true, "", []]

	var profile := _cfg.get_game_profile()
	var fallback_args: Array = [
		"--ignore-magic",
		"--force-version=%d" % profile.pak_archive_version,
	]
	var fallback_result := _validate_archive_paths(python, u4pak_path, pak_path, fallback_args)
	if bool(fallback_result[0]):
		return [true, "", fallback_args]

	return [false, str(strict_result[1]) + "\nFallback also failed: " + str(fallback_result[1]), []]


func _validate_archive_paths(python: String, u4pak_path: String, pak_path: String,
		archive_args: Array) -> Array:
	var output: Array = []
	var list_args: Array = ["list"]
	list_args.append_array(archive_args)
	list_args.append(pak_path)
	var code := ProcessUtils.run_python_script(
			python, u4pak_path, u4pak_path.get_base_dir(), list_args, output)
	if code != 0:
		var detail := ProcessUtils.output_text(output, "no output")
		return [false, "Could not read pak index (exit %d): %s" % [code, detail]]

	var count := 0
	for raw_name in ProcessUtils.output_text(output, "").split("\n", false):
		var name := str(raw_name).strip_edges()
		if name.is_empty():
			continue
		count += 1
		if not _archive_path_is_safe(name):
			return [false, "Pak contains an unsafe path: %s" % name]
	if count == 0:
		return [false, "Pak contains no files"]
	return [true, ""]


func _archive_path_is_safe(name: String) -> bool:
	var normalized := name.replace("\\", "/").simplify_path()
	if normalized.is_empty() or normalized == "." or normalized == "..":
		return false
	if normalized.begins_with("/") or normalized.begins_with("//"):
		return false
	if normalized.length() >= 2 and normalized.substr(1, 1) == ":":
		return false
	if normalized.begins_with("../") or normalized.ends_with("/..") or "/../" in normalized:
		return false
	return true


func _default_source_name(pak_path: String) -> String:
	var base := pak_path.get_file().get_basename()
	return "Base Game" if base.is_empty() else "Base Game (%s)" % base
