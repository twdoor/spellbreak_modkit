class_name PackingService extends BackgroundOperationService

## Merges enabled mods and invokes u4pak.py to create zzz_mods_P.pak + .sig.
## Mirrors the pack_mods() function in mod_manager.py exactly.
##
## Packing is run in a thread so the UI stays responsive.
## Signals are emitted on the main thread via call_deferred().

signal pack_started
signal pack_finished(result: OperationResult)
signal pack_log(line: String)

var _cfg: ModConfigManager


func setup(cfg: ModConfigManager) -> PackingService:
	_cfg = cfg
	return self


func is_packing() -> bool:
	return is_busy()


## Pack all enabled mods discovered by ModDiscovery.
## Runs in a background thread; emits pack_started / pack_log / pack_finished.
func pack(enabled_mods: Array) -> void:
	if enabled_mods.is_empty():
		pack_finished.emit(OperationResult.failed("No mods enabled"))
		return
	_start_pack_operation(_do_pack.bind(enabled_mods.duplicate()))


## Export the selected mod(s) to an explicit .pak path plus a sibling .sig.
## This is used by Mod Manager middle-click export and does not install into the game folder.
func export_to_path(mods: Array, output_pak_path: String) -> void:
	if mods.is_empty():
		pack_finished.emit(OperationResult.failed("No mod selected"))
		return
	_start_pack_operation(_do_pack_to_path.bind(mods.duplicate(), output_pak_path))


func _start_pack_operation(task: Callable) -> void:
	var error := _start_background(task, _on_pack_done)
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		pack_finished.emit(OperationResult.failed(
				"Could not start packing operation (error %d)" % error))
		return
	pack_started.emit()


func _on_pack_done(result: OperationResult) -> void:
	pack_finished.emit(result)


## Core packing logic (runs in worker thread).
func _do_pack(enabled_mods: Array) -> OperationResult:
	var paks_dir := _cfg.get_paks_dir()
	if not FileUtils.is_path_within(paks_dir, _cfg.game_dir):
		return OperationResult.failed("Paks path escapes the configured game directory")
	if not DirAccess.dir_exists_absolute(paks_dir):
		return OperationResult.failed("Paks dir missing: %s" % paks_dir)
	var profile := _cfg.get_game_profile()
	var pak_name := profile.pak_output_name
	if not FileUtils.is_safe_filename(pak_name):
		return OperationResult.failed("Invalid pak output name in Spellbreak profile")
	var pak_path := paks_dir.path_join(pak_name + ".pak")
	return _pack_mods_to_target(enabled_mods, pak_path, "Packed")


## Core export logic for explicit save-as packing.
func _do_pack_to_path(mods: Array, output_pak_path: String) -> OperationResult:
	var pak_path := _normalized_pak_output_path(output_pak_path)
	if pak_path.is_empty():
		return OperationResult.failed("Select an output .pak path")
	var output_dir := pak_path.get_base_dir()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		return OperationResult.failed(
				"Could not create export folder (error %d)" % mkdir_error)
	return _pack_mods_to_target(mods, pak_path, "Exported")


func _pack_mods_to_target(mods: Array, pak_path: String, verb: String) -> OperationResult:
	var u4pak_path := _cfg.get_u4pak_path()
	if not FileAccess.file_exists(u4pak_path):
		return OperationResult.failed("u4pak.py not found: %s" % u4pak_path)
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return OperationResult.failed("Python was not found in PATH")

	var tmp_result := FileUtils.make_temp_dir("sb_pack")
	if not bool(tmp_result.get("ok", false)):
		return OperationResult.failed(
				str(tmp_result.get("error", "Could not create temp directory")))
	var tmp_dir := str(tmp_result["path"])
	var merged := tmp_dir.path_join("merged")
	var merge_dir_error := DirAccess.make_dir_recursive_absolute(merged)
	if merge_dir_error != OK:
		FileUtils.remove_dir_recursive(tmp_dir)
		return OperationResult.failed(
				"Could not create merge directory (error %d)" % merge_dir_error)

	var merge_result := _merge_mods_to_dir(mods, merged)
	if not merge_result.ok:
		FileUtils.remove_dir_recursive(tmp_dir)
		return merge_result
	var registry_result := _stage_custom_asset_registry(mods, merged, tmp_dir, python)
	if not registry_result.ok:
		FileUtils.remove_dir_recursive(tmp_dir)
		return registry_result

	_emit_log("")
	_emit_log("Packing...")
	var staged_pak := FileUtils.unique_sibling_path(pak_path, "pack")
	var exit_code := _run_u4pak(python, u4pak_path, staged_pak, merged)
	FileUtils.remove_dir_recursive(tmp_dir)
	if exit_code != 0:
		_remove_staged_file(staged_pak)
		return OperationResult.failed("Pack failed (exit %d)" % exit_code)
	if not _staged_pak_is_valid(staged_pak):
		_remove_staged_file(staged_pak)
		return OperationResult.failed("Pack completed without producing a valid pak")

	var sig_path := pak_path.get_basename() + ".sig"
	var staged_sig := FileUtils.unique_sibling_path(sig_path, "sig")
	var sig_error := _stage_sig_file(staged_sig)
	if sig_error != OK:
		_remove_staged_file(staged_pak)
		return OperationResult.failed(
				"Could not stage signature file (error %d)" % sig_error)

	var install_result := FileUtils.install_staged_files_with_result([
		{"source": staged_pak, "target": pak_path},
		{"source": staged_sig, "target": sig_path},
	], [], _cfg.keep_pack_backups, "pak-backup")
	var install_error := int(install_result.get("error", ERR_BUG))
	if install_error != OK:
		for staged in [staged_pak, staged_sig]:
			_remove_staged_file(staged)
		return OperationResult.failed(
				"Could not install packed files (error %d)" % install_error)

	var pak_size := 0
	var fa := FileAccess.open(pak_path, FileAccess.READ)
	if fa:
		pak_size = fa.get_length()
		fa.close()
	var message := "%s %s + %s (%s)" % [verb,
		pak_path.get_file(), sig_path.get_file(), ModDiscovery.fmt_size(pak_size)
	]
	var backups: Array = install_result.get("backups", [])
	var backup_summary := FileUtils.format_backup_summary(backups)
	if not backup_summary.is_empty():
		message += ". " + backup_summary
	return OperationResult.succeeded(message, pak_path, {
		"pak_path": pak_path,
		"sig_path": sig_path,
	}).with_backups(backups)


func _merge_mods_to_dir(mods: Array, merged: String) -> OperationResult:
	var profile := _cfg.get_game_profile()
	var content_root := profile.content_root
	_emit_log("Merging %d mod(s):" % mods.size())
	for mod_value in mods:
		var mod := mod_value as ModInfo
		if mod == null:
			return OperationResult.failed("Packing received invalid mod metadata")
		_emit_log("  -> %s" % mod.name)
		var mod_content := mod.path.path_join(content_root)
		if not FileUtils.is_path_within(mod_content, mod.path):
			return OperationResult.failed("Content root escapes mod '%s'" % mod.name)
		if not DirAccess.dir_exists_absolute(mod_content):
			continue
		var copy_error := _copy_dir_recursive(mod_content, merged.path_join(content_root))
		if copy_error != OK:
			return OperationResult.failed(
					"Could not merge mod '%s' (error %d)" % [mod.name, copy_error])
	return OperationResult.succeeded()


func _stage_custom_asset_registry(mods: Array, merged: String, tmp_dir: String,
		python: String) -> OperationResult:
	var declarations: Array = []
	var targets := {}
	for mod_value in mods:
		var mod := mod_value as ModInfo
		if mod == null:
			continue
		var manifest_path := ModManifest.manifest_path(mod)
		if not FileAccess.file_exists(manifest_path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if not parsed is Dictionary:
			return OperationResult.failed("Invalid manifest JSON for '%s'" % mod.name)
		for value in parsed.get("custom_assets", []):
			if not value is Dictionary:
				return OperationResult.failed(
						"Invalid unique asset declaration in '%s'" % mod.name)
			var declaration := value as Dictionary
			var source := str(declaration.get("source", ""))
			var target := str(declaration.get("target", ""))
			var relative_file := str(declaration.get("file", ""))
			if source.is_empty() or target.is_empty() or relative_file.is_empty():
				return OperationResult.failed(
						"Incomplete unique asset declaration in '%s'" % mod.name)
			if targets.has(target):
				return OperationResult.failed(
						"Duplicate unique asset target '%s' in '%s' and '%s'" % [
							target, str(targets[target]), mod.name])
			var package_file := mod.path.path_join(relative_file)
			if not FileUtils.is_path_within(package_file, mod.path) \
					or not FileAccess.file_exists(package_file):
				return OperationResult.failed(
						"Unique asset file is missing in '%s': %s" % [mod.name, relative_file])
			targets[target] = mod.name
			declarations.append({"source": source, "target": target})
	if declarations.is_empty():
		return OperationResult.succeeded()

	var base_registry := _find_base_asset_registry()
	if base_registry.is_empty():
		return OperationResult.failed(
				"Unique assets require g3/AssetRegistry.bin in a configured source")
	var patcher := ToolchainRegistry.asset_registry_script()
	if patcher.is_empty() or not FileAccess.file_exists(patcher):
		return OperationResult.failed("Asset Registry patcher was not found")
	var operations_path := tmp_dir.path_join("custom_assets.json")
	var operations_error := FileUtils.write_bytes_atomic(
			operations_path, JSON.stringify(declarations, "  ").to_utf8_buffer())
	if operations_error != OK:
		return OperationResult.failed(
				"Could not stage unique asset declarations (error %d)" % operations_error)
	var output_registry := merged.path_join(
			_cfg.get_game_profile().content_root).path_join("AssetRegistry.bin")
	var output: Array = []
	var code := ProcessUtils.run_python_script(python, patcher, tmp_dir, [
		base_registry, output_registry, "--operations", operations_path,
	], output)
	for line in ProcessUtils.output_text(output, "").split("\n"):
		if not line.strip_edges().is_empty():
			_emit_log("Registry: " + line.strip_edges())
	if code != 0:
		return OperationResult.failed(
				"Asset Registry generation failed (exit %d): %s" % [
					code, ProcessUtils.output_text(output)])
	_emit_log("Registry: merged %d unique asset(s)" % declarations.size())
	return OperationResult.succeeded()


func _find_base_asset_registry() -> String:
	var content_root := _cfg.get_game_profile().content_root
	for source_value in _cfg.sources:
		if not source_value is Dictionary:
			continue
		var root := str(source_value.get("path", "")).rstrip("/")
		var candidate := root.path_join(content_root).path_join("AssetRegistry.bin")
		if not root.is_empty() and FileUtils.is_path_within(candidate, root) \
				and FileAccess.file_exists(candidate):
			return candidate
	return ""


func _remove_staged_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _normalized_pak_output_path(path: String) -> String:
	path = path.strip_edges()
	if path.is_empty():
		return ""
	if path.get_extension().to_lower() == "pak":
		return path
	if path.get_extension().is_empty():
		return path + ".pak"
	return path.get_basename() + ".pak"


func _staged_pak_is_valid(staged_pak: String) -> bool:
	var staged_fa := FileAccess.open(staged_pak, FileAccess.READ)
	if not staged_fa:
		return false
	var valid := staged_fa.get_length() > 0
	staged_fa.close()
	return valid


func _stage_sig_file(staged_sig: String) -> Error:
	var src_sig := ""
	var paks_dir := _cfg.get_paks_dir()
	if DirAccess.dir_exists_absolute(paks_dir):
		src_sig = _find_sig(paks_dir)
	if not src_sig.is_empty():
		var sig_error := FileUtils.copy_file(src_sig, staged_sig)
		if sig_error == OK:
			_emit_log("Sig: %s" % src_sig.get_file())
		return sig_error
	_emit_log("Sig: empty (no template found)")
	return FileUtils.write_bytes_atomic(staged_sig, PackedByteArray())


func _run_u4pak(python: String, u4pak_path: String, pak_path: String, merged_dir: String) -> int:
	var profile := _cfg.get_game_profile()
	var archive_ver := str(profile.pak_archive_version)
	var mount_point := profile.pak_mount_point
	var content_root := profile.content_root + "/"
	var output: Array = []
	var code := ProcessUtils.run_python_script(python, u4pak_path, merged_dir, [
		"pack", "-z", "--archive-version=%s" % archive_ver,
		"--mount-point=%s" % mount_point, pak_path, content_root,
	], output)
	if not output.is_empty():
		for line in str(output[0]).split("\n"):
			if not line.strip_edges().is_empty():
				_emit_log("  " + line.strip_edges())
	return code


func _find_sig(paks_dir: String) -> String:
	var pak_name := _cfg.get_game_profile().pak_output_name
	var dir := DirAccess.open(paks_dir)
	if not dir:
		return ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.ends_with(".sig") and not entry.begins_with(pak_name) and not entry.begins_with("."):
			dir.list_dir_end()
			return paks_dir.path_join(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


func _copy_dir_recursive(src: String, dst: String) -> Error:
	var mkdir_error := DirAccess.make_dir_recursive_absolute(dst)
	if mkdir_error != OK:
		return mkdir_error
	var dir := DirAccess.open(src)
	if not dir:
		return ERR_CANT_OPEN
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var src_full := src.path_join(entry)
		var dst_full := dst.path_join(entry)
		if dir.is_link(entry):
			dir.list_dir_end()
			return ERR_INVALID_DATA
		elif dir.current_is_dir() and not entry.begins_with("."):
			var copy_error := _copy_dir_recursive(src_full, dst_full)
			if copy_error != OK:
				dir.list_dir_end()
				return copy_error
		elif not dir.current_is_dir():
			if not entry.ends_with(".json"):  # exclude JSON sidecars
				var copy_error := FileUtils.copy_file(src_full, dst_full)
				if copy_error != OK:
					dir.list_dir_end()
					return copy_error
		entry = dir.get_next()
	dir.list_dir_end()
	return OK


func _emit_log(line: String) -> void:
	call_deferred("_deferred_log", line)


func _deferred_log(line: String) -> void:
	pack_log.emit(line)


## Remove the mod pak and .sig from the paks directory.
func remove_pak() -> OperationResult:
	var paks_dir := _cfg.get_paks_dir()
	if not FileUtils.is_path_within(paks_dir, _cfg.game_dir):
		return OperationResult.failed("Paks path escapes the configured game directory")
	var pak_name := _cfg.get_game_profile().pak_output_name
	if not FileUtils.is_safe_filename(pak_name):
		return OperationResult.failed("Invalid pak output name in Spellbreak profile")
	var removed: Array = []
	for ext in [".pak", ".sig"]:
		var f := paks_dir.path_join(pak_name + ext)
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
			removed.append(ext)
	if not removed.is_empty():
		return OperationResult.succeeded(
				"Removed %s (%s)" % [pak_name, ", ".join(PackedStringArray(removed))])
	return OperationResult.failed("No mod pak to remove")
