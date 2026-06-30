class_name TextureService extends RefCounted

## Wraps UE4-DDS-Tools and ImageMagick to provide texture extraction, injection,
## and preview for UE4 texture assets.  Subprocess pattern mirrors PackingService.
##
## Pipeline (Linux):
##   Export: uasset -> TGA (UE4-DDS-Tools/libtexconv) -> PNG (ImageMagick)
##   Import: PNG -> DDS (ImageMagick) -> inject into uasset (UE4-DDS-Tools)
##   Preview: export to PNG in temp dir, load as Godot Image

signal operation_finished(success: bool, message: String)

var _cfg: ModConfigManager
var _thread: Thread = null
var _busy: bool = false

## Temp directory for preview cache
const CACHE_DIR := "sb_tex_cache"


func setup(cfg: ModConfigManager) -> TextureService:
	_cfg = cfg
	return self


func is_busy() -> bool:
	return _busy


## Block until the worker thread has fully exited. Call from _exit_tree().
func wait_to_finish() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


# ── Public API ────────────────────────────────────────────────────────────────


## Export a texture .uasset to PNG. Runs in a background thread.
## Emits operation_finished when done.
func export_png(uasset_path: String, output_png: String) -> void:
	if _busy:
		return
	_busy = true
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_export_thread.bind(uasset_path, output_png))


## Inject a PNG into a texture .uasset. Runs in a background thread.
## The modified .uasset is written to output_dir (same filename as original).
## Emits operation_finished when done.
func inject_png(uasset_path: String, png_path: String, output_dir: String) -> void:
	if _busy:
		return
	_busy = true
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_inject_thread.bind(uasset_path, png_path, output_dir))


## Synchronous preview: export texture to PNG in temp dir, load as Godot Image.
## Intended to be called from a worker thread (blocks on subprocess).
## Returns null on failure.
func get_preview_image(uasset_path: String) -> Image:
	var result := _do_export_png(uasset_path, "")
	if not result[0]:
		return null
	var png_path: String = result[2]
	if png_path.is_empty() or not FileAccess.file_exists(png_path):
		return null
	var img := Image.load_from_file(png_path)
	return img


# ── Tool availability checks ─────────────────────────────────────────────────


func is_configured() -> bool:
	var main_py := _cfg.get_dds_tools_main_py()
	return not main_py.is_empty() and FileAccess.file_exists(main_py)


func has_magick() -> bool:
	return not _find_magick().is_empty()


# ── Thread entry points ──────────────────────────────────────────────────────


func _export_thread(uasset_path: String, output_png: String) -> void:
	var result := _do_export_png(uasset_path, output_png)
	call_deferred("_on_operation_done", result[0], result[1])


func _inject_thread(uasset_path: String, png_path: String, output_dir: String) -> void:
	var result := _do_inject_png(uasset_path, png_path, output_dir)
	# Invalidate preview cache for this asset
	if result[0]:
		_invalidate_cache(uasset_path)
	call_deferred("_on_operation_done", result[0], result[1])


func _on_operation_done(success: bool, message: String) -> void:
	_busy = false
	if _thread:
		_thread.wait_to_finish()
	operation_finished.emit(success, message)


# ── Core operations ───────────────────────────────────────────────────────────


## Export uasset -> TGA -> PNG.
## If output_png is empty, writes to the preview cache dir.
## Returns [success: bool, message: String, png_path: String].
func _do_export_png(uasset_path: String, output_png: String) -> Array:
	var main_py := _cfg.get_dds_tools_main_py()
	if main_py.is_empty() or not FileAccess.file_exists(main_py):
		return [false, "UE4-DDS-Tools not configured", ""]

	var repaired := _restore_missing_texture_companions(uasset_path)
	if not bool(repaired.get("ok", false)):
		return [false, str(repaired.get("error", "Texture package is missing companion files")), ""]

	var magick := _find_magick()
	if magick.is_empty():
		return [false, "ImageMagick (magick) not found in PATH", ""]

	# Step 1: Export to TGA in temp dir. ImageMagick's DDS reader only supports
	# a subset of DDS/BC formats on Linux, so libtexconv handles DDS decoding.
	var tmp_dir := OS.get_temp_dir().path_join("sb_tex_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(tmp_dir)

	var dds_tools_dir := _cfg.get_dds_tools_dir()
	var python := ProcessUtils.find_python()
	if python.is_empty():
		_remove_dir(tmp_dir)
		return [false, "Python was not found in PATH", ""]

	var dds_ver := _cfg.get_game_profile().dds_tools_version
	var output: Array = []
	var code := ProcessUtils.run_python_script(python, main_py, dds_tools_dir, [
		uasset_path, "--mode", "export", "--export_as", "tga", "--version", dds_ver,
		"--save_folder", tmp_dir, "--skip_non_texture",
	], output)
	if code != 0:
		_remove_dir(tmp_dir)
		var err_text := ProcessUtils.output_text(output)
		return [false, "Texture export failed (exit %d): %s" % [code, err_text], ""]

	# Find the exported image file. HDR textures may be converted to .hdr
	# instead of .tga by UE4-DDS-Tools.
	var intermediate_path := _find_file_in_dir(tmp_dir, "tga")
	if intermediate_path.is_empty():
		intermediate_path = _find_file_in_dir(tmp_dir, "hdr")
	if intermediate_path.is_empty():
		var dds_path := _find_file_in_dir(tmp_dir, "dds")
		_remove_dir(tmp_dir)
		if dds_path.is_empty():
			return [false, "No image file produced by UE4-DDS-Tools", ""]
		return [false, "Texture format could only be exported as DDS, which ImageMagick cannot reliably preview on Linux", ""]

	# Step 2: Convert TGA/HDR -> PNG via ImageMagick
	var target_png := output_png
	if target_png.is_empty():
		# Use cache dir
		var cache_dir := _get_cache_dir()
		DirAccess.make_dir_recursive_absolute(cache_dir)
		target_png = cache_dir.path_join(_cache_key(uasset_path) + ".png")

	var staged_png := tmp_dir.path_join("converted.png")
	var convert_output: Array = []
	var convert_code := OS.execute(magick, [intermediate_path, staged_png], convert_output, true, false)

	if convert_code != 0:
		_remove_dir(tmp_dir)
		var err_text := ProcessUtils.output_text(convert_output)
		return [false, "%s->PNG conversion failed: %s" % [
				intermediate_path.get_extension().to_upper(), err_text], ""]

	if not FileAccess.file_exists(staged_png):
		_remove_dir(tmp_dir)
		return [false, "PNG file was not created", ""]
	var install_error := FileUtils.install_staged_files([{"source": staged_png, "target": target_png}])
	_remove_dir(tmp_dir)
	if install_error != OK:
		return [false, "Could not install PNG (error %d)" % install_error, ""]

	return [true, "Exported to %s" % target_png.get_file(), target_png]


## Inject PNG -> TGA -> uasset.
## Pipeline: ImageMagick converts PNG to TGA (lossless), then UE4-DDS-Tools
## injects the TGA using libtexconv to match the original texture's BC format.
## Returns [success: bool, message: String].
func _do_inject_png(uasset_path: String, png_path: String, output_dir: String) -> Array:
	var main_py := _cfg.get_dds_tools_main_py()
	if main_py.is_empty() or not FileAccess.file_exists(main_py):
		return [false, "UE4-DDS-Tools not configured"]

	if not FileAccess.file_exists(png_path):
		return [false, "PNG file not found: %s" % png_path]

	var repaired := _restore_missing_texture_companions(uasset_path)
	if not bool(repaired.get("ok", false)):
		return [false, str(repaired.get("error", "Texture package is missing companion files"))]

	var magick := _find_magick()
	if magick.is_empty():
		return [false, "ImageMagick (magick) not found in PATH"]

	var tmp_dir := OS.get_temp_dir().path_join("sb_inject_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(tmp_dir)

	# Step 1: Convert PNG to TGA via ImageMagick (lossless, no compression issues)
	# TGA is natively supported by texconv on all platforms (no WIC needed).
	var tga_path := tmp_dir.path_join("texture.tga")
	var convert_output: Array = []
	var convert_code := OS.execute(magick, [png_path, tga_path], convert_output, true, false)

	if convert_code != 0:
		_remove_dir(tmp_dir)
		var err_text := ProcessUtils.output_text(convert_output)
		return [false, "PNG->TGA conversion failed: %s" % err_text]

	# Step 2: Inject TGA into uasset (texconv handles BC format matching)
	DirAccess.make_dir_recursive_absolute(output_dir)
	var dds_tools_dir := _cfg.get_dds_tools_dir()
	var python := ProcessUtils.find_python()
	if python.is_empty():
		_remove_dir(tmp_dir)
		return [false, "Python was not found in PATH"]
	var staged_output := tmp_dir.path_join("output")
	DirAccess.make_dir_recursive_absolute(staged_output)

	var dds_ver := _cfg.get_game_profile().dds_tools_version
	var output: Array = []
	var code := ProcessUtils.run_python_script(python, main_py, dds_tools_dir, [
		uasset_path, tga_path, "--mode", "inject", "--version", dds_ver,
		"--save_folder", staged_output,
	], output)

	if code != 0:
		_remove_dir(tmp_dir)
		var err_text := ProcessUtils.output_text(output)
		return [false, "Injection failed (exit %d): %s" % [code, err_text]]

	var base_name := uasset_path.get_file().get_basename()
	var staged_uasset := staged_output.path_join(base_name + ".uasset")
	if not FileAccess.file_exists(staged_uasset):
		_remove_dir(tmp_dir)
		return [false, "Injection did not produce a .uasset file"]
	var collected := _collect_injected_texture_files(uasset_path, staged_output, output_dir, base_name)
	if not bool(collected.get("ok", false)):
		_remove_dir(tmp_dir)
		return [false, str(collected.get("error", "Could not prepare injected texture files"))]
	var install_error := FileUtils.install_staged_files(collected["files"])
	_remove_dir(tmp_dir)
	if install_error != OK:
		return [false, "Could not install injected texture (error %d)" % install_error]

	return [true, "Injected texture into %s" % uasset_path.get_file()]


# ── Cache ─────────────────────────────────────────────────────────────────────


func _get_cache_dir() -> String:
	return OS.get_temp_dir().path_join(CACHE_DIR)


func _cache_key(uasset_path: String) -> String:
	# Use a hash of the path + file modification time
	var mtime := FileAccess.get_modified_time(uasset_path)
	return str(uasset_path.hash()) + "_" + str(mtime)


## Check if a cached preview PNG exists for this asset.
func get_cached_preview(uasset_path: String) -> String:
	var cache_path := _get_cache_dir().path_join(_cache_key(uasset_path) + ".png")
	if FileAccess.file_exists(cache_path):
		return cache_path
	return ""


func _invalidate_cache(uasset_path: String) -> void:
	# Remove any cached files matching this asset's path hash prefix
	var cache_dir := _get_cache_dir()
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var prefix := str(uasset_path.hash())
	var dir := DirAccess.open(cache_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with(prefix):
			DirAccess.remove_absolute(cache_dir.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


func _collect_injected_texture_files(uasset_path: String, staged_output: String,
		output_dir: String, base_name: String) -> Dictionary:
	var staged_files: Array = []
	var source_dir := uasset_path.get_base_dir()
	for extension_value in ["uasset", "uexp", "ubulk", "uptnl"]:
		var extension := str(extension_value)
		var file_name := base_name + "." + extension
		var generated := staged_output.path_join(file_name)
		var target := output_dir.path_join(file_name)
		if FileAccess.file_exists(generated):
			staged_files.append({
				"source": generated,
				"target": target,
			})
			continue

		# UE4-DDS-Tools may omit a companion file that is still part of the
		# original texture package. Preserve it instead of treating it as stale.
		if extension == "uasset":
			continue
		var original := source_dir.path_join(file_name)
		if not FileAccess.file_exists(original) or FileUtils.same_path(original, target):
			continue
		var preserved := staged_output.path_join("__preserve_" + file_name)
		var copy_error := FileUtils.copy_file(original, preserved)
		if copy_error != OK:
			return {
				"ok": false,
				"error": "Could not preserve %s (error %d)" % [file_name, copy_error],
			}
		staged_files.append({
			"source": preserved,
			"target": target,
		})
	if staged_files.is_empty():
		return {"ok": false, "error": "Injection did not produce installable files"}
	return {"ok": true, "files": staged_files}


func _restore_missing_texture_companions(uasset_path: String) -> Dictionary:
	if _cfg == null:
		return {"ok": true, "restored": []}
	var base_path := uasset_path.get_basename()
	var restored: Array[String] = []
	for extension_value in ["uexp", "ubulk", "uptnl"]:
		var extension := str(extension_value)
		var target := base_path + "." + extension
		if FileAccess.file_exists(target):
			continue
		var source := _find_source_companion(uasset_path, extension)
		if source.is_empty():
			continue
		var copy_error := FileUtils.copy_file(source, target)
		if copy_error != OK:
			return {
				"ok": false,
				"error": "Missing %s and could not restore it from %s (error %d)" % [
					target.get_file(), source, copy_error],
			}
		restored.append(target.get_file())
	return {"ok": true, "restored": restored}


func _find_source_companion(uasset_path: String, extension: String) -> String:
	var relative_path := _game_relative_path(uasset_path)
	if relative_path.is_empty():
		return ""
	relative_path = relative_path.get_basename() + "." + extension
	var roots := _reference_roots()
	for root in roots:
		var candidate := root.path_join(relative_path)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _reference_roots() -> Array[String]:
	var roots: Array[String] = []
	for source_entry in _cfg.sources:
		if source_entry is Dictionary:
			var source_path := str(source_entry.get("path", "")).rstrip("/")
			if not source_path.is_empty() and DirAccess.dir_exists_absolute(source_path):
				roots.append(source_path)

	var mods_dir := _cfg.mods_dir.rstrip("/")
	if not mods_dir.is_empty():
		var modding_dir := mods_dir.get_base_dir()
		for sibling in ["Unchanged", "BaseGame", "Base", "New"]:
			var candidate := modding_dir.path_join(sibling)
			if DirAccess.dir_exists_absolute(candidate) and candidate not in roots:
				roots.append(candidate)
	return roots


func _game_relative_path(path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path()
	var content_root := _cfg.get_game_profile().content_root.replace("\\", "/").strip_edges()
	content_root = content_root.trim_prefix("/").trim_suffix("/")
	var markers: Array[String] = []
	if not content_root.is_empty():
		markers.append("/" + content_root + "/Content/")
		markers.append("/" + content_root + "/")
	markers.append("/Content/")
	for marker in markers:
		var index := normalized.find(marker)
		if index >= 0:
			return normalized.substr(index + 1)
	return ""


# ── Helpers ───────────────────────────────────────────────────────────────────


func _find_magick() -> String:
	var candidates: Array[String] = ["magick"]
	if OS.get_name() != "Windows":
		candidates.append("convert")
	return ProcessUtils.find_executable(candidates)


## Find the first file with a given extension in a directory.
func _find_file_in_dir(dir_path: String, ext: String) -> String:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and entry.get_extension().to_lower() == ext:
			dir.list_dir_end()
			return dir_path.path_join(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


## Remove a temp directory and all its contents.
func _remove_dir(dir_path: String) -> void:
	FileUtils.remove_dir_recursive(dir_path)
