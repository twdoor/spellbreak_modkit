class_name MeshService extends RefCounted

## Wraps umodel (UE Viewer) to export UE4 mesh assets to glTF for preview.
## Pattern mirrors TextureService: synchronous helpers called from worker threads,
## results marshalled back to the main thread via call_deferred().
##
## Pipeline:
##   Preview: uasset → glTF (umodel -export -gltf) → GLTFDocument in Godot
##   Export:  same pipeline, user picks output path

signal operation_finished(success: bool, message: String)

var _cfg: ModConfigManager
var _thread: Thread = null
var _busy: bool = false

const CACHE_DIR := "sb_mesh_cache"


func setup(cfg: ModConfigManager) -> MeshService:
	_cfg = cfg
	return self


func is_busy() -> bool:
	return _busy


## Block until the worker thread has fully exited. Call from _exit_tree().
func wait_to_finish() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


# ── Public API ────────────────────────────────────────────────────────────────


## Check if umodel is configured and available.
func is_configured() -> bool:
	var umodel := _cfg.get_umodel_path()
	return not umodel.is_empty() and FileAccess.file_exists(umodel)


## Synchronous mesh export: extract glTF to cache dir.
## Intended to be called from a worker thread (blocks on subprocess).
## Returns [gltf_path: String, error: String]. gltf_path is empty on failure.
func get_preview_mesh(uasset_path: String) -> Array:
	# Check cache first
	var cached := get_cached_mesh(uasset_path)
	if not cached.is_empty():
		return [cached, ""]

	var cache_dir := _get_cache_dir().path_join(_cache_key(uasset_path))
	var result := _do_export_gltf(uasset_path, cache_dir)
	if not result[0]:
		return ["", result[1]]
	return [result[2], ""]


## Export mesh from a .uasset to a user-chosen output directory.
## Runs in a background thread. Emits operation_finished when done.
func export_gltf(uasset_path: String, output_dir: String) -> void:
	if _busy:
		return
	_busy = true
	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_export_thread.bind(uasset_path, output_dir))


# ── Cache ─────────────────────────────────────────────────────────────────────


func _get_cache_dir() -> String:
	return OS.get_temp_dir().path_join(CACHE_DIR)


func _cache_key(uasset_path: String) -> String:
	var mtime := FileAccess.get_modified_time(uasset_path)
	return str(uasset_path.hash()) + "_" + str(mtime)


## Check if a cached glTF exists for this asset. Returns path or "".
func get_cached_mesh(uasset_path: String) -> String:
	var cache_subdir := _get_cache_dir().path_join(_cache_key(uasset_path))
	if not DirAccess.dir_exists_absolute(cache_subdir):
		return ""
	var gltf := _find_file_in_dir(cache_subdir, "gltf")
	if gltf.is_empty():
		gltf = _find_file_in_dir(cache_subdir, "glb")
	return gltf


# ── Thread entry points ──────────────────────────────────────────────────────


func _export_thread(uasset_path: String, output_dir: String) -> void:
	var result := _do_export_gltf(uasset_path, output_dir)
	call_deferred("_on_operation_done", result[0], result[1])


func _on_operation_done(success: bool, message: String) -> void:
	_busy = false
	if _thread:
		_thread.wait_to_finish()
	operation_finished.emit(success, message)


# ── Core operation ───────────────────────────────────────────────────────────


## Export uasset → glTF via umodel.
## Returns [success: bool, message: String, gltf_path: String].
func _do_export_gltf(uasset_path: String, output_dir: String) -> Array:
	var umodel := _cfg.get_umodel_path()
	if umodel.is_empty() or not FileAccess.file_exists(umodel):
		return [false, "umodel not configured", ""]

	if not FileAccess.file_exists(uasset_path):
		return [false, "File not found: %s" % uasset_path, ""]

	DirAccess.make_dir_recursive_absolute(output_dir)

	# umodel command: export as glTF to the output directory
	# -game=ue4.22 required for Spellbreak's unversioned UE4 4.22 packages
	var cmd_str := "'%s' -export -gltf -game=ue4.22 -out='%s' '%s'" % [umodel, output_dir, uasset_path]
	var output: Array = []
	var code := OS.execute("sh", ["-c", cmd_str], output, true)

	if code != 0:
		var err_text: String = output[0] if output.size() > 0 else "no output"
		return [false, "umodel export failed (exit %d): %s" % [code, err_text], ""]

	# Find the exported glTF file (umodel may place it in a subdirectory)
	var gltf_path := _find_file_recursive(output_dir, "gltf")
	if gltf_path.is_empty():
		gltf_path = _find_file_recursive(output_dir, "glb")
	if gltf_path.is_empty():
		return [false, "No glTF file produced by umodel", ""]

	return [true, "Exported to %s" % gltf_path.get_file(), gltf_path]


# ── Helpers ──────────────────────────────────────────────────────────────────


## Find the first file with a given extension in a directory (non-recursive).
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


## Find the first file with a given extension, searching subdirectories too.
## umodel sometimes creates subdirectories based on the asset's internal path.
func _find_file_recursive(dir_path: String, ext: String) -> String:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return ""
	# Check files in this directory first
	var result := _find_file_in_dir(dir_path, ext)
	if not result.is_empty():
		return result
	# Recurse into subdirectories
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			result = _find_file_recursive(dir_path.path_join(entry), ext)
			if not result.is_empty():
				dir.list_dir_end()
				return result
		entry = dir.get_next()
	dir.list_dir_end()
	return ""
