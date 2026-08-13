class_name BaseSourceService extends BackgroundOperationService

## Extracts a selected game pak into a source directory via bundled u4pak.py.
## Runs in a worker thread so the Settings tab stays responsive.

signal generate_started
signal generate_finished(result: OperationResult)

var _cfg: ModConfigManager


func setup(cfg: ModConfigManager) -> BaseSourceService:
	_cfg = cfg
	return self


func is_generating() -> bool:
	return is_busy()


func generate(pak_path: String, output_dir: String) -> void:
	var error := _start_background(_do_generate.bind(pak_path, output_dir), _on_generate_done)
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		generate_finished.emit(OperationResult.failed(
				"Could not start source generation (error %d)" % error))
		return
	generate_started.emit()


func _on_generate_done(result: OperationResult) -> void:
	generate_finished.emit(result)


func _do_generate(pak_path: String, output_dir: String) -> OperationResult:
	pak_path = pak_path.strip_edges()
	output_dir = output_dir.strip_edges().rstrip("/")
	if pak_path.is_empty():
		return OperationResult.failed("Select a game package first")
	if output_dir.is_empty():
		return OperationResult.failed("Select an output folder first")
	if not FileAccess.file_exists(pak_path):
		return OperationResult.failed("Game package not found: %s" % pak_path)
	if pak_path.get_extension().to_lower() != "pak":
		return OperationResult.failed("Game package must be a .pak file")

	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		return OperationResult.failed(
				"Could not create output folder (error %d)" % mkdir_error)

	var u4pak_path := _cfg.get_u4pak_path()
	if not FileAccess.file_exists(u4pak_path):
		return OperationResult.failed("u4pak.py not found: %s" % u4pak_path)
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return OperationResult.failed("Python was not found in PATH")

	var path_check := _resolve_archive_args(python, u4pak_path, pak_path)
	if not path_check.ok:
		return path_check
	var archive_args: Array = path_check.value

	var output: Array = []
	var unpack_args: Array = ["unpack"]
	unpack_args.append_array(archive_args)
	unpack_args.append_array(["-C", output_dir, pak_path])
	var code := ProcessUtils.run_python_script(
			python, u4pak_path, u4pak_path.get_base_dir(), unpack_args, output)
	if code != 0:
		var detail := ProcessUtils.output_text(output, "no output")
		return OperationResult.failed("Unpack failed (exit %d): %s" % [code, detail])

	var content_root := _cfg.get_game_profile().content_root
	var source_content := output_dir.path_join(content_root)
	if not DirAccess.dir_exists_absolute(source_content):
		return OperationResult.failed(
				"Extracted pak, but output folder does not contain %s/" % content_root)

	return OperationResult.succeeded(
			"Generated base source from %s" % pak_path.get_file(), output_dir, {
				"source_name": _default_source_name(pak_path),
				"source_path": output_dir,
			})


func _resolve_archive_args(python: String, u4pak_path: String,
		pak_path: String) -> OperationResult:
	var strict_result := _validate_archive_paths(python, u4pak_path, pak_path, [])
	if strict_result.ok:
		return OperationResult.succeeded("", [])

	var profile := _cfg.get_game_profile()
	var fallback_args: Array = [
		"--ignore-magic",
		"--force-version=%d" % profile.pak_archive_version,
	]
	var fallback_result := _validate_archive_paths(python, u4pak_path, pak_path, fallback_args)
	if fallback_result.ok:
		return OperationResult.succeeded("", fallback_args)

	return OperationResult.failed(strict_result.message
			+ "\nFallback also failed: " + fallback_result.message)


func _validate_archive_paths(python: String, u4pak_path: String, pak_path: String,
		archive_args: Array) -> OperationResult:
	var output: Array = []
	var list_args: Array = ["list"]
	list_args.append_array(archive_args)
	list_args.append(pak_path)
	var code := ProcessUtils.run_python_script(
			python, u4pak_path, u4pak_path.get_base_dir(), list_args, output)
	if code != 0:
		var detail := ProcessUtils.output_text(output, "no output")
		return OperationResult.failed(
				"Could not read pak index (exit %d): %s" % [code, detail])

	var count := 0
	for raw_name in ProcessUtils.output_text(output, "").split("\n", false):
		var name := str(raw_name).strip_edges()
		if name.is_empty():
			continue
		count += 1
		if not _archive_path_is_safe(name):
			return OperationResult.failed("Pak contains an unsafe path: %s" % name)
	if count == 0:
		return OperationResult.failed("Pak contains no files")
	return OperationResult.succeeded()


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
