class_name PackingService extends RefCounted

## Merges enabled mods and invokes u4pak.py to create zzz_mods_P.pak + .sig.
## Mirrors the pack_mods() function in mod_manager.py exactly.
##
## Packing is run in a thread so the UI stays responsive.
## Signals are emitted on the main thread via call_deferred().

signal pack_started
signal pack_finished(success: bool, message: String)
signal pack_log(line: String)

var _cfg: ModConfigManager
var _operation := SingleBackgroundOperation.new()


func setup(cfg: ModConfigManager) -> PackingService:
	_cfg = cfg
	return self


func is_packing() -> bool:
	return _operation.is_busy()


## Block until the pack thread has fully exited. Call from _exit_tree().
func wait_to_finish() -> void:
	_operation.wait_to_finish()


## Pack all enabled mods. enabled_mods: Array of dicts from ModDiscovery.scan().
## Runs in a background thread; emits pack_started / pack_log / pack_finished.
func pack(enabled_mods: Array) -> void:
	if enabled_mods.is_empty():
		pack_finished.emit(false, "No mods enabled")
		return
	_start_pack_operation(_do_pack.bind(enabled_mods.duplicate()))


## Export the selected mod(s) to an explicit .pak path plus a sibling .sig.
## This is used by Mod Manager middle-click export and does not install into the game folder.
func export_to_path(mods: Array, output_pak_path: String) -> void:
	if mods.is_empty():
		pack_finished.emit(false, "No mod selected")
		return
	_start_pack_operation(_do_pack_to_path.bind(mods.duplicate(), output_pak_path))


func _start_pack_operation(task: Callable) -> void:
	var error := _operation.start(task, _on_pack_done)
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		pack_finished.emit(false, "Could not start packing operation (error %d)" % error)
		return
	pack_started.emit()


func _on_pack_done(result: Variant) -> void:
	if not result is Array or result.size() < 2:
		pack_finished.emit(false, "Packing operation returned an invalid result")
		return
	pack_finished.emit(bool(result[0]), str(result[1]))


## Core packing logic (runs in worker thread).
func _do_pack(enabled_mods: Array) -> Array:
	var paks_dir    := _cfg.get_paks_dir()
	var u4pak_path  := _cfg.get_u4pak_path()

	if not FileUtils.is_path_within(paks_dir, _cfg.game_dir):
		return [false, "Paks path escapes the configured game directory"]
	if not DirAccess.dir_exists_absolute(paks_dir):
		return [false, "Paks dir missing: %s" % paks_dir]
	if not FileAccess.file_exists(u4pak_path):
		return [false, "u4pak.py not found: %s" % u4pak_path]
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return [false, "Python was not found in PATH"]

	var tmp_result := FileUtils.make_temp_dir("sb_pack")
	if not bool(tmp_result.get("ok", false)):
		return [false, str(tmp_result.get("error", "Could not create temp directory"))]
	var tmp_dir := str(tmp_result["path"])
	var merged  := tmp_dir.path_join("merged")
	var merge_dir_error := DirAccess.make_dir_recursive_absolute(merged)
	if merge_dir_error != OK:
		FileUtils.remove_dir_recursive(tmp_dir)
		return [false, "Could not create merge directory (error %d)" % merge_dir_error]

	var profile := _cfg.get_game_profile()
	var content_root := profile.content_root

	_emit_log("Merging %d mod(s):" % enabled_mods.size())
	for mod in enabled_mods:
		_emit_log("  → %s" % mod["name"])
		var mod_content := (mod["path"] as String).path_join(content_root)
		if not FileUtils.is_path_within(mod_content, mod["path"]):
			FileUtils.remove_dir_recursive(tmp_dir)
			return [false, "Content root escapes mod '%s'" % mod["name"]]
		if not DirAccess.dir_exists_absolute(mod_content):
			continue
		var copy_error := _copy_dir_recursive(mod_content, merged.path_join(content_root))
		if copy_error != OK:
			FileUtils.remove_dir_recursive(tmp_dir)
			return [false, "Could not merge mod '%s' (error %d)" % [mod["name"], copy_error]]

	_emit_log("")
	_emit_log("Packing...")

	var pak_name := profile.pak_output_name
	if not FileUtils.is_safe_filename(pak_name):
		FileUtils.remove_dir_recursive(tmp_dir)
		return [false, "Invalid pak output name in Spellbreak profile"]
	var pak_path := paks_dir.path_join(pak_name + ".pak")
	var staged_pak := paks_dir.path_join(".%s.sb_pack_%d.pak" % [pak_name, Time.get_ticks_usec()])

	# Build beside the installed pak. The old working pak remains untouched until
	# both staged output files have been produced successfully.
	var exit_code := _run_u4pak(python, u4pak_path, staged_pak, merged)

	# Clean up temp dir
	FileUtils.remove_dir_recursive(tmp_dir)

	if exit_code != 0:
		if FileAccess.file_exists(staged_pak):
			DirAccess.remove_absolute(staged_pak)
		return [false, "Pack failed (exit %d)" % exit_code]
	var staged_fa := FileAccess.open(staged_pak, FileAccess.READ)
	if not staged_fa or staged_fa.get_length() == 0:
		if staged_fa:
			staged_fa.close()
		if FileAccess.file_exists(staged_pak):
			DirAccess.remove_absolute(staged_pak)
		return [false, "Pack completed without producing a valid pak"]
	staged_fa.close()

	# Copy / create .sig file
	var sig_path := pak_path.get_basename() + ".sig"
	var staged_sig := paks_dir.path_join(".%s.sb_pack_%d.sig" % [pak_name, Time.get_ticks_usec()])
	var src_sig := _find_sig(paks_dir)
	if not src_sig.is_empty():
		var sig_error := FileUtils.copy_file(src_sig, staged_sig)
		if sig_error != OK:
			DirAccess.remove_absolute(staged_pak)
			return [false, "Could not stage signature file (error %d)" % sig_error]
		_emit_log("Sig: %s" % src_sig.get_file())
	else:
		var sig_error := FileUtils.write_bytes_atomic(staged_sig, PackedByteArray())
		if sig_error != OK:
			DirAccess.remove_absolute(staged_pak)
			return [false, "Could not stage signature file (error %d)" % sig_error]
		_emit_log("Sig: empty (no template found)")

	var install_result := FileUtils.install_staged_files_with_result([
		{"source": staged_pak, "target": pak_path},
		{"source": staged_sig, "target": sig_path},
	], [], true, "pak-backup")
	var install_error := int(install_result.get("error", ERR_BUG))
	if install_error != OK:
		if FileAccess.file_exists(staged_pak):
			DirAccess.remove_absolute(staged_pak)
		if FileAccess.file_exists(staged_sig):
			DirAccess.remove_absolute(staged_sig)
		return [false, "Could not install packed files (error %d)" % install_error]

	var pak_size := 0
	var fa := FileAccess.open(pak_path, FileAccess.READ)
	if fa:
		pak_size = fa.get_length()
		fa.close()
	var message := "Packed %s.pak + .sig (%s)" % [pak_name, ModDiscovery.fmt_size(pak_size)]
	var backup_summary := FileUtils.format_backup_summary(install_result.get("backups", []))
	if not backup_summary.is_empty():
		message += ". " + backup_summary
	return [true, message]


## Core export logic for explicit save-as packing.
func _do_pack_to_path(mods: Array, output_pak_path: String) -> Array:
	var u4pak_path := _cfg.get_u4pak_path()
	if not FileAccess.file_exists(u4pak_path):
		return [false, "u4pak.py not found: %s" % u4pak_path]
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return [false, "Python was not found in PATH"]

	var pak_path := _normalized_pak_output_path(output_pak_path)
	if pak_path.is_empty():
		return [false, "Select an output .pak path"]
	var output_dir := pak_path.get_base_dir()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		return [false, "Could not create export folder (error %d)" % mkdir_error]

	var tmp_result := FileUtils.make_temp_dir("sb_pack_export")
	if not bool(tmp_result.get("ok", false)):
		return [false, str(tmp_result.get("error", "Could not create temp directory"))]
	var tmp_dir := str(tmp_result["path"])
	var merged := tmp_dir.path_join("merged")
	var merge_dir_error := DirAccess.make_dir_recursive_absolute(merged)
	if merge_dir_error != OK:
		FileUtils.remove_dir_recursive(tmp_dir)
		return [false, "Could not create merge directory (error %d)" % merge_dir_error]

	var merge_result := _merge_mods_to_dir(mods, merged)
	if not bool(merge_result[0]):
		FileUtils.remove_dir_recursive(tmp_dir)
		return [false, str(merge_result[1])]

	_emit_log("")
	_emit_log("Packing export...")
	var staged_pak := FileUtils.unique_sibling_path(pak_path, "pack")
	var exit_code := _run_u4pak(python, u4pak_path, staged_pak, merged)
	FileUtils.remove_dir_recursive(tmp_dir)
	if exit_code != 0:
		if FileAccess.file_exists(staged_pak):
			DirAccess.remove_absolute(staged_pak)
		return [false, "Export failed (exit %d)" % exit_code]
	if not _staged_pak_is_valid(staged_pak):
		if FileAccess.file_exists(staged_pak):
			DirAccess.remove_absolute(staged_pak)
		return [false, "Export completed without producing a valid pak"]

	var sig_path := pak_path.get_basename() + ".sig"
	var staged_sig := FileUtils.unique_sibling_path(sig_path, "sig")
	var sig_error := _stage_sig_file(staged_sig)
	if sig_error != OK:
		DirAccess.remove_absolute(staged_pak)
		return [false, "Could not stage signature file (error %d)" % sig_error]

	var install_result := FileUtils.install_staged_files_with_result([
		{"source": staged_pak, "target": pak_path},
		{"source": staged_sig, "target": sig_path},
	], [], true, "pak-backup")
	var install_error := int(install_result.get("error", ERR_BUG))
	if install_error != OK:
		for staged in [staged_pak, staged_sig]:
			if FileAccess.file_exists(staged):
				DirAccess.remove_absolute(staged)
		return [false, "Could not write exported files (error %d)" % install_error]

	var pak_size := 0
	var fa := FileAccess.open(pak_path, FileAccess.READ)
	if fa:
		pak_size = fa.get_length()
		fa.close()
	var message := "Exported %s + %s (%s)" % [
		pak_path.get_file(), sig_path.get_file(), ModDiscovery.fmt_size(pak_size)
	]
	var backup_summary := FileUtils.format_backup_summary(install_result.get("backups", []))
	if not backup_summary.is_empty():
		message += ". " + backup_summary
	return [true, message]


func _merge_mods_to_dir(mods: Array, merged: String) -> Array:
	var profile := _cfg.get_game_profile()
	var content_root := profile.content_root
	_emit_log("Merging %d mod(s):" % mods.size())
	for mod in mods:
		_emit_log("  -> %s" % mod["name"])
		var mod_content := (mod["path"] as String).path_join(content_root)
		if not FileUtils.is_path_within(mod_content, mod["path"]):
			return [false, "Content root escapes mod '%s'" % mod["name"]]
		if not DirAccess.dir_exists_absolute(mod_content):
			continue
		var copy_error := _copy_dir_recursive(mod_content, merged.path_join(content_root))
		if copy_error != OK:
			return [false, "Could not merge mod '%s' (error %d)" % [mod["name"], copy_error]]
	return [true, ""]


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
func remove_pak() -> Array:
	var paks_dir := _cfg.get_paks_dir()
	if not FileUtils.is_path_within(paks_dir, _cfg.game_dir):
		return [false, "Paks path escapes the configured game directory"]
	var pak_name := _cfg.get_game_profile().pak_output_name
	if not FileUtils.is_safe_filename(pak_name):
		return [false, "Invalid pak output name in Spellbreak profile"]
	var removed: Array = []
	for ext in [".pak", ".sig"]:
		var f := paks_dir.path_join(pak_name + ext)
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
			removed.append(ext)
	if not removed.is_empty():
		return [true, "Removed %s (%s)" % [pak_name, ", ".join(PackedStringArray(removed))]]
	return [false, "No mod pak to remove"]
