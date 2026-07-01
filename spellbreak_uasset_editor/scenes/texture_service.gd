class_name TextureService extends RefCounted

## Wraps UE4-DDS-Tools and ImageMagick to provide texture extraction, injection,
## and preview for UE4 texture assets.  Subprocess pattern mirrors PackingService.
##
## Pipeline:
##   Export: uasset -> TGA (UE4-DDS-Tools/libtexconv) -> PNG (ImageMagick)
##   Import: PNG -> TGA (ImageMagick) -> inject into uasset (UE4-DDS-Tools)
##   Preview: export to PNG in temp dir, load as Godot Image

signal operation_finished(success: bool, message: String)

var _cfg: ModConfigManager
var _operation := SingleBackgroundOperation.new()

## Temp directory for preview cache
const CACHE_DIR := "sb_tex_cache"
const TEXTURE_PACKAGE_EXTENSIONS := ["uasset", "uexp", "ubulk", "uptnl"]
const TEXTURE_COMPANION_EXTENSIONS := ["uexp", "ubulk", "uptnl"]


func setup(cfg: ModConfigManager) -> TextureService:
	_cfg = cfg
	return self


func is_busy() -> bool:
	return _operation.is_busy()


## Block until the worker thread has fully exited. Call from _exit_tree().
func wait_to_finish() -> void:
	_operation.wait_to_finish()


# ── Public API ────────────────────────────────────────────────────────────────


## Export a texture .uasset to PNG. Runs in a background thread.
## Emits operation_finished when done.
func export_png(uasset_path: String, output_png: String) -> void:
	_start_operation(_do_export_png.bind(uasset_path, output_png))


## Inject a PNG into a texture .uasset. Runs in a background thread.
## The modified .uasset is written to output_dir (same filename as original).
## Emits operation_finished when done.
func inject_png(uasset_path: String, png_path: String, output_dir: String) -> void:
	_start_operation(_do_inject_png.bind(uasset_path, png_path, output_dir),
			_invalidate_cache.bind(uasset_path))


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
	if _cfg == null:
		return false
	var main_py := _cfg.get_dds_tools_main_py()
	return not main_py.is_empty() and FileAccess.file_exists(main_py)


func has_magick() -> bool:
	return not _find_magick().is_empty()


# ── Background operations ────────────────────────────────────────────────────


func _start_operation(task: Callable, success_callback: Callable = Callable()) -> void:
	var error := _operation.start(task, _on_operation_done.bind(success_callback))
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		operation_finished.emit(false, "Could not start texture operation (error %d)" % error)


func _on_operation_done(result: Variant, success_callback: Callable) -> void:
	if not result is Array or result.size() < 2:
		operation_finished.emit(false, "Texture operation returned an invalid result")
		return
	var success := bool(result[0])
	if success and success_callback.is_valid():
		success_callback.call()
	var message := str(result[1])
	operation_finished.emit(success, message)


# ── Core operations ───────────────────────────────────────────────────────────


## Export uasset -> TGA -> PNG.
## If output_png is empty, writes to the preview cache dir.
## Returns [success: bool, message: String, png_path: String].
func _do_export_png(uasset_path: String, output_png: String) -> Array:
	var tools := _get_texture_toolchain()
	if not bool(tools.get("ok", false)):
		return _export_error(str(tools.get("error", "Texture toolchain is not configured")))

	var repaired := _restore_missing_texture_companions(uasset_path)
	if not bool(repaired.get("ok", false)):
		return _export_error(str(repaired.get("error", "Texture package is missing companion files")))

	# Step 1: Export to TGA in temp dir. ImageMagick's DDS reader support
	# varies by platform, so libtexconv handles DDS decoding.
	var tmp_result := FileUtils.make_temp_dir("sb_tex")
	if not bool(tmp_result.get("ok", false)):
		return _export_error(str(tmp_result.get("error", "Could not create temp directory")))
	var tmp_dir := str(tmp_result["path"])

	var output: Array = []
	var code := ProcessUtils.run_python_script(str(tools["python"]), str(tools["main_py"]),
			str(tools["dds_tools_dir"]), [
		uasset_path, "--mode", "export", "--export_as", "tga", "--version", str(tools["dds_ver"]),
		"--save_folder", tmp_dir, "--skip_non_texture",
	], output)
	if code != 0:
		var err_text := ProcessUtils.output_text(output)
		return _export_error("Texture export failed (exit %d): %s" % [code, err_text], tmp_dir)

	# Find the exported image file. HDR textures may be converted to .hdr
	# instead of .tga by UE4-DDS-Tools.
	var intermediate_path := _find_first_file_in_dir(tmp_dir, ["tga", "hdr"])
	if intermediate_path.is_empty():
		var dds_path := _find_first_file_in_dir(tmp_dir, ["dds"])
		if not dds_path.is_empty():
			return _export_error("Texture format could only be exported as DDS, which ImageMagick cannot reliably preview on Linux", tmp_dir)
		return _export_error("No image file produced by UE4-DDS-Tools", tmp_dir)

	# Step 2: Convert TGA/HDR -> PNG via ImageMagick
	var target_png := output_png
	if target_png.is_empty():
		# Use cache dir
		var cache_dir := _get_cache_dir()
		DirAccess.make_dir_recursive_absolute(cache_dir)
		target_png = cache_dir.path_join(_cache_key(uasset_path) + ".png")

	var staged_png := tmp_dir.path_join("converted.png")
	var convert_output: Array = []
	var convert_code := OS.execute(str(tools["magick"]), [intermediate_path, staged_png],
			convert_output, true, false)

	if convert_code != 0:
		var err_text := ProcessUtils.output_text(convert_output)
		return _export_error("%s->PNG conversion failed: %s" % [
				intermediate_path.get_extension().to_upper(), err_text], tmp_dir)

	if not FileAccess.file_exists(staged_png):
		return _export_error("PNG file was not created", tmp_dir)
	var install_error := FileUtils.install_staged_files([{"source": staged_png, "target": target_png}])
	_remove_dir(tmp_dir)
	if install_error != OK:
		return _export_error("Could not install PNG (error %d)" % install_error)

	return [true, "Exported to %s" % target_png.get_file(), target_png]


## Inject PNG -> TGA -> uasset.
## Pipeline: ImageMagick converts PNG to TGA (lossless), then UE4-DDS-Tools
## injects the TGA using libtexconv to match the original texture's BC format.
## Returns [success: bool, message: String].
func _do_inject_png(uasset_path: String, png_path: String, output_dir: String) -> Array:
	if not FileAccess.file_exists(png_path):
		return _inject_error("PNG file not found: %s" % png_path)

	var tools := _get_texture_toolchain()
	if not bool(tools.get("ok", false)):
		return _inject_error(str(tools.get("error", "Texture toolchain is not configured")))

	var repaired := _restore_missing_texture_companions(uasset_path)
	if not bool(repaired.get("ok", false)):
		return _inject_error(str(repaired.get("error", "Texture package is missing companion files")))

	var tmp_result := FileUtils.make_temp_dir("sb_inject")
	if not bool(tmp_result.get("ok", false)):
		return _inject_error(str(tmp_result.get("error", "Could not create temp directory")))
	var tmp_dir := str(tmp_result["path"])

	# Step 1: Convert PNG to TGA via ImageMagick (lossless, no compression issues)
	# TGA is natively supported by texconv on all platforms (no WIC needed).
	var tga_path := tmp_dir.path_join("texture.tga")
	var convert_output: Array = []
	var convert_code := OS.execute(str(tools["magick"]), [png_path, tga_path],
			convert_output, true, false)

	if convert_code != 0:
		var err_text := ProcessUtils.output_text(convert_output)
		return _inject_error("PNG->TGA conversion failed: %s" % err_text, tmp_dir)
	if not FileAccess.file_exists(tga_path):
		return _inject_error("TGA file was not created", tmp_dir)

	# Step 2: Inject TGA into uasset (texconv handles BC format matching)
	var output_dir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if output_dir_error != OK:
		return _inject_error("Could not create output directory (error %d)" % output_dir_error, tmp_dir)
	var staged_output := tmp_dir.path_join("output")
	var staged_error := DirAccess.make_dir_recursive_absolute(staged_output)
	if staged_error != OK:
		return _inject_error("Could not create staging directory (error %d)" % staged_error, tmp_dir)

	var output: Array = []
	var code := ProcessUtils.run_python_script(str(tools["python"]), str(tools["main_py"]),
			str(tools["dds_tools_dir"]), [
		uasset_path, tga_path, "--mode", "inject", "--version", str(tools["dds_ver"]),
		"--save_folder", staged_output,
	], output)

	if code != 0:
		var err_text := ProcessUtils.output_text(output)
		return _inject_error("Injection failed (exit %d): %s" % [code, err_text], tmp_dir)

	var base_name := uasset_path.get_file().get_basename()
	var staged_uasset := staged_output.path_join(base_name + ".uasset")
	if not FileAccess.file_exists(staged_uasset):
		return _inject_error("Injection did not produce a .uasset file", tmp_dir)
	var collected := _collect_injected_texture_files(uasset_path, staged_output, output_dir, base_name)
	if not bool(collected.get("ok", false)):
		return _inject_error(str(collected.get("error", "Could not prepare injected texture files")), tmp_dir)
	var install_result := FileUtils.install_staged_files_with_result(
			collected["files"], [], true, "texture-backup")
	_remove_dir(tmp_dir)
	var install_error := int(install_result.get("error", ERR_BUG))
	if install_error != OK:
		return _inject_error("Could not install injected texture (error %d)" % install_error)

	var message := "Injected texture into %s" % uasset_path.get_file()
	var backup_summary := FileUtils.format_backup_summary(install_result.get("backups", []))
	if not backup_summary.is_empty():
		message += ". " + backup_summary
	return [true, message]


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
	for extension_value in TEXTURE_PACKAGE_EXTENSIONS:
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
	for extension_value in TEXTURE_COMPANION_EXTENSIONS:
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


func _get_texture_toolchain() -> Dictionary:
	if _cfg == null:
		return {"ok": false, "error": "UE4-DDS-Tools not configured"}
	var main_py := _cfg.get_dds_tools_main_py()
	if main_py.is_empty() or not FileAccess.file_exists(main_py):
		return {"ok": false, "error": "UE4-DDS-Tools not configured"}
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return {"ok": false, "error": "Python was not found in PATH"}
	var magick := _find_magick()
	if magick.is_empty():
		return {"ok": false, "error": "ImageMagick (magick) not found in PATH"}
	return {
		"ok": true,
		"main_py": main_py,
		"dds_tools_dir": _cfg.get_dds_tools_dir(),
		"dds_ver": _cfg.get_game_profile().dds_tools_version,
		"python": python,
		"magick": magick,
	}


func _export_error(message: String, tmp_dir: String = "") -> Array:
	if not tmp_dir.is_empty():
		_remove_dir(tmp_dir)
	return [false, message, ""]


func _inject_error(message: String, tmp_dir: String = "") -> Array:
	if not tmp_dir.is_empty():
		_remove_dir(tmp_dir)
	return [false, message]


func _find_magick() -> String:
	var candidates: Array[String] = ["magick"]
	if OS.get_name() != "Windows":
		candidates.append("convert")
	return ProcessUtils.find_executable(candidates)


## Find the first file with one of the given extensions in a directory.
func _find_first_file_in_dir(dir_path: String, extensions: Array) -> String:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return ""
	var extension_lookup := {}
	for extension_value in extensions:
		extension_lookup[str(extension_value).to_lower()] = true
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and extension_lookup.has(entry.get_extension().to_lower()):
			dir.list_dir_end()
			return dir_path.path_join(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return ""


## Remove a temp directory and all its contents.
func _remove_dir(dir_path: String) -> void:
	FileUtils.remove_dir_recursive(dir_path)
