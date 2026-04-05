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
var _thread: Thread = null
var _packing: bool = false


func setup(cfg: ModConfigManager) -> PackingService:
	_cfg = cfg
	return self


func is_packing() -> bool:
	return _packing


## Block until the pack thread has fully exited. Call from _exit_tree().
func wait_to_finish() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


## Pack all enabled mods. enabled_mods: Array of dicts from ModDiscovery.scan().
## Runs in a background thread; emits pack_started / pack_log / pack_finished.
func pack(enabled_mods: Array) -> void:
	if _packing:
		return
	if enabled_mods.is_empty():
		pack_finished.emit(false, "No mods enabled")
		return
	_packing = true
	pack_started.emit()
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_pack_thread.bind(enabled_mods.duplicate()))


func _pack_thread(enabled_mods: Array) -> void:
	var result := _do_pack(enabled_mods)
	call_deferred("_on_pack_done", result[0], result[1])


func _on_pack_done(success: bool, message: String) -> void:
	_packing = false
	if _thread:
		_thread.wait_to_finish()
	pack_finished.emit(success, message)


## Core packing logic (runs in worker thread).
func _do_pack(enabled_mods: Array) -> Array:
	var paks_dir    := _cfg.get_paks_dir()
	var u4pak_path  := _cfg.get_u4pak_path()

	if not DirAccess.dir_exists_absolute(paks_dir):
		return [false, "Paks dir missing: %s" % paks_dir]
	if not FileAccess.file_exists(u4pak_path):
		return [false, "u4pak.py not found: %s" % u4pak_path]

	# Create temp merge directory
	var tmp_dir := OS.get_temp_dir().path_join("sb_pack_%d" % Time.get_ticks_msec())
	var merged  := tmp_dir.path_join("merged")
	DirAccess.make_dir_recursive_absolute(merged)

	_emit_log("Merging %d mod(s):" % enabled_mods.size())
	for mod in enabled_mods:
		_emit_log("  → %s" % mod["name"])
		var g3 := (mod["path"] as String).path_join("g3")
		if not DirAccess.dir_exists_absolute(g3):
			continue
		_copy_dir_recursive(g3, merged.path_join("g3"), mod["path"])

	_emit_log("")
	_emit_log("Packing...")

	var pak_path := paks_dir.path_join("zzz_mods_P.pak")
	# Remove old pak
	if FileAccess.file_exists(pak_path):
		DirAccess.remove_absolute(pak_path)

	# Invoke u4pak.py via a shell wrapper so we can set CWD to merged_dir
	# (Godot 4's OS.execute doesn't support setting working directory directly)
	var exit_code := _run_u4pak(u4pak_path, pak_path, merged)

	# Clean up temp dir
	_remove_dir_recursive(tmp_dir)

	if exit_code != 0:
		return [false, "Pack failed (exit %d)" % exit_code]

	# Copy / create .sig file
	var sig_path := pak_path.get_basename() + ".sig"
	if FileAccess.file_exists(sig_path):
		DirAccess.remove_absolute(sig_path)
	var src_sig := _find_sig(paks_dir)
	if not src_sig.is_empty():
		var bytes := FileAccess.get_file_as_bytes(src_sig)
		var sig_file := FileAccess.open(sig_path, FileAccess.WRITE)
		if sig_file:
			sig_file.store_buffer(bytes)
			sig_file.close()
		_emit_log("Sig: %s" % src_sig.get_file())
	else:
		var sig_file := FileAccess.open(sig_path, FileAccess.WRITE)
		if sig_file:
			sig_file.close()
		_emit_log("Sig: empty (no template found)")

	var pak_size := 0
	var fa := FileAccess.open(pak_path, FileAccess.READ)
	if fa:
		pak_size = fa.get_length()
		fa.close()
	return [true, "Packed zzz_mods_P.pak + .sig (%s)" % ModDiscovery.fmt_size(pak_size)]


func _run_u4pak(u4pak_path: String, pak_path: String, merged_dir: String) -> int:
	# Build platform-appropriate command that runs u4pak from merged_dir as CWD
	var python := _find_python()
	var cmd: String
	var args: Array
	if OS.get_name() == "Windows":
		cmd = "cmd"
		args = ["/c", "cd /d \"%s\" && \"%s\" \"%s\" pack --archive-version=3 --mount-point=../../../  \"%s\" g3/" \
			% [merged_dir, python, u4pak_path, pak_path]]
	else:
		cmd = "sh"
		args = ["-c", "cd '%s' && '%s' '%s' pack --archive-version=3 --mount-point=../../../  '%s' g3/" \
			% [merged_dir, python, u4pak_path, pak_path]]
	var output: Array = []
	var code := OS.execute(cmd, args, output, true, false)
	if not output.is_empty():
		for line in str(output[0]).split("\n"):
			if not line.strip_edges().is_empty():
				_emit_log("  " + line.strip_edges())
	return code


func _find_python() -> String:
	# Try common python binary names
	for py in ["python3", "python"]:
		var out: Array = []
		if OS.execute("which" if OS.get_name() != "Windows" else "where", [py], out, true, false) == 0:
			return py
	return "python3"


func _find_sig(paks_dir: String) -> String:
	var dir := DirAccess.open(paks_dir)
	if not dir:
		return ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.ends_with(".sig") and not entry.begins_with("zzz_mods"):
			dir.list_dir_end()
			return paks_dir.path_join(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


func _copy_dir_recursive(src: String, dst: String, mod_root: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var src_full := src.path_join(entry)
		var dst_full := dst.path_join(entry)
		if dir.current_is_dir() and not entry.begins_with("."):
			_copy_dir_recursive(src_full, dst_full, mod_root)
		elif not dir.current_is_dir():
			if not entry.ends_with(".json"):  # exclude JSON sidecars
				var bytes := FileAccess.get_file_as_bytes(src_full)
				var fa := FileAccess.open(dst_full, FileAccess.WRITE)
				if fa:
					fa.store_buffer(bytes)
					fa.close()
		entry = dir.get_next()
	dir.list_dir_end()


func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var full := path.path_join(entry)
		if dir.current_is_dir() and not entry.begins_with("."):
			_remove_dir_recursive(full)
		elif not dir.current_is_dir():
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _emit_log(line: String) -> void:
	call_deferred("_deferred_log", line)


func _deferred_log(line: String) -> void:
	pack_log.emit(line)


## Remove zzz_mods_P.pak and .sig from the paks directory.
func remove_pak() -> Array:
	var paks_dir := _cfg.get_paks_dir()
	var removed: Array = []
	for ext in [".pak", ".sig"]:
		var f := paks_dir.path_join("zzz_mods_P" + ext)
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
			removed.append(ext)
	if not removed.is_empty():
		return [true, "Removed zzz_mods_P (%s)" % ", ".join(PackedStringArray(removed))]
	return [false, "No mod pak to remove"]
