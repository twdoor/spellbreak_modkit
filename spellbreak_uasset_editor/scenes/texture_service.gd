class_name TextureService extends RefCounted

## Wraps UE4-DDS-Tools and ImageMagick to provide texture extraction, injection,
## and preview for UE4 texture assets.  Subprocess pattern mirrors PackingService.
##
## Pipeline (Linux):
##   Export: uasset -> DDS (UE4-DDS-Tools) -> PNG (ImageMagick)
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


## Export uasset -> DDS -> PNG.
## If output_png is empty, writes to the preview cache dir.
## Returns [success: bool, message: String, png_path: String].
func _do_export_png(uasset_path: String, output_png: String) -> Array:
	var main_py := _cfg.get_dds_tools_main_py()
	if main_py.is_empty() or not FileAccess.file_exists(main_py):
		return [false, "UE4-DDS-Tools not configured", ""]

	var magick := _find_magick()
	if magick.is_empty():
		return [false, "ImageMagick (magick) not found in PATH", ""]

	# Step 1: Export to DDS in temp dir
	var tmp_dir := OS.get_temp_dir().path_join("sb_tex_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(tmp_dir)

	var dds_tools_dir := _cfg.get_dds_tools_dir()
	var python := _find_python()

	var dds_ver := _cfg.get_game_profile().dds_tools_version
	var cmd_str := "cd '%s' && '%s' '%s' '%s' --mode export --export_as dds --version %s --save_folder '%s' --skip_non_texture" \
		% [dds_tools_dir, python, main_py, uasset_path, dds_ver, tmp_dir]

	var output: Array = []
	var code := OS.execute("sh", ["-c", cmd_str], output, true)
	if code != 0:
		_remove_dir(tmp_dir)
		var err_text: String = output[0] if output.size() > 0 else "no output"
		return [false, "DDS export failed (exit %d): %s" % [code, err_text], ""]

	# Find the exported DDS file
	var dds_path := _find_file_in_dir(tmp_dir, "dds")
	if dds_path.is_empty():
		_remove_dir(tmp_dir)
		return [false, "No DDS file produced by UE4-DDS-Tools", ""]

	# Step 2: Convert DDS -> PNG via ImageMagick
	var target_png := output_png
	if target_png.is_empty():
		# Use cache dir
		var cache_dir := _get_cache_dir()
		DirAccess.make_dir_recursive_absolute(cache_dir)
		target_png = cache_dir.path_join(_cache_key(uasset_path) + ".png")

	var convert_cmd := "'%s' '%s' '%s'" % [magick, dds_path, target_png]
	var convert_output: Array = []
	var convert_code := OS.execute("sh", ["-c", convert_cmd], convert_output, true)

	# Clean up temp DDS
	_remove_dir(tmp_dir)

	if convert_code != 0:
		var err_text: String = convert_output[0] if convert_output.size() > 0 else "no output"
		return [false, "DDS->PNG conversion failed: %s" % err_text, ""]

	if not FileAccess.file_exists(target_png):
		return [false, "PNG file was not created", ""]

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

	var magick := _find_magick()
	if magick.is_empty():
		return [false, "ImageMagick (magick) not found in PATH"]

	var tmp_dir := OS.get_temp_dir().path_join("sb_inject_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(tmp_dir)

	# Step 1: Convert PNG to TGA via ImageMagick (lossless, no compression issues)
	# TGA is natively supported by texconv on all platforms (no WIC needed).
	var tga_path := tmp_dir.path_join("texture.tga")
	var convert_cmd := "'%s' '%s' '%s'" % [magick, png_path, tga_path]
	var convert_output: Array = []
	var convert_code := OS.execute("sh", ["-c", convert_cmd], convert_output, true)

	if convert_code != 0:
		_remove_dir(tmp_dir)
		var err_text: String = convert_output[0] if convert_output.size() > 0 else "no output"
		return [false, "PNG->TGA conversion failed: %s" % err_text]

	# Step 2: Inject TGA into uasset (texconv handles BC format matching)
	DirAccess.make_dir_recursive_absolute(output_dir)
	var dds_tools_dir := _cfg.get_dds_tools_dir()
	var python := _find_python()

	var dds_ver := _cfg.get_game_profile().dds_tools_version
	var cmd_str := "cd '%s' && '%s' '%s' '%s' '%s' --mode inject --version %s --save_folder '%s'" \
		% [dds_tools_dir, python, main_py, uasset_path, tga_path, dds_ver, output_dir]

	var output: Array = []
	var code := OS.execute("sh", ["-c", cmd_str], output, true)

	_remove_dir(tmp_dir)

	if code != 0:
		var err_text: String = output[0] if output.size() > 0 else "no output"
		return [false, "Injection failed (exit %d): %s" % [code, err_text]]

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


# ── Helpers ───────────────────────────────────────────────────────────────────


func _find_python() -> String:
	for py in ["python3", "python"]:
		var out: Array = []
		if OS.execute("which" if OS.get_name() != "Windows" else "where", [py], out, true, false) == 0:
			return py
	return "python3"


func _find_magick() -> String:
	for cmd in ["magick", "convert"]:
		var out: Array = []
		if OS.execute("which" if OS.get_name() != "Windows" else "where", [cmd], out, true, false) == 0:
			return cmd
	return ""


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
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir():
			DirAccess.remove_absolute(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)
