class_name MeshService extends BackgroundOperationService

## Wraps umodel (UE Viewer) to export UE4 mesh assets to glTF for preview.
## Pattern mirrors TextureService: synchronous helpers called from worker threads,
## results marshalled back to the main thread via call_deferred().
##
## Pipeline:
##   Preview: uasset → glTF (umodel -export -gltf) → GLTFDocument in Godot
##   Export:  umodel glTF → Godot glTF round-trip → Blender-friendly GLB

signal operation_finished(result: OperationResult)

var _cfg: ModConfigManager

const CACHE_DIR := "sb_mesh_cache"
const CACHE_VERSION := 2
const ANIMATION_SCAN_LIMIT := 200
const ANIMATION_SCAN_DEPTH := 4


func setup(cfg: ModConfigManager) -> MeshService:
	_cfg = cfg
	return self


# ── Public API ────────────────────────────────────────────────────────────────


## Check if umodel is configured and available.
func is_configured() -> bool:
	var umodel := _cfg.get_umodel_path()
	return not umodel.is_empty() and FileAccess.file_exists(umodel)


## Synchronous mesh export: extract glTF to cache dir.
## Intended to be called from a worker thread (blocks on subprocess).
func get_preview_mesh(uasset_path: String) -> OperationResult:
	# Check cache first
	var cached := get_cached_mesh(uasset_path)
	if not cached.is_empty():
		return OperationResult.succeeded("Using cached mesh.", cached)

	var cache_dir := _get_cache_dir().path_join(_cache_key(uasset_path))
	return _do_export_gltf(uasset_path, cache_dir)


## Synchronous animation export: extract MD5Anim to cache dir.
func get_preview_animations(uasset_path: String) -> OperationResult:
	var cached := get_cached_animations(uasset_path)
	if not cached.is_empty():
		return OperationResult.succeeded("Using cached animations.", cached)

	var cache_dir := _get_cache_dir().path_join(_animation_cache_key(uasset_path))
	return _do_export_md5anim(uasset_path, cache_dir)


## Find likely AnimSequence assets near a SkeletalMesh and configured sources.
## This is intentionally heuristic: exporting tells us whether a candidate is
## truly usable, but scanning keeps the user out of filesystem picking.
func find_animation_assets_for_mesh(mesh_uasset_path: String,
		max_results: int = ANIMATION_SCAN_LIMIT) -> Array[String]:
	var scan_dirs := _animation_scan_dirs(mesh_uasset_path)
	var found := {}
	for dir_path in scan_dirs:
		if found.size() >= max_results:
			break
		_collect_animation_assets(dir_path, found, max_results, ANIMATION_SCAN_DEPTH)

	var paths: Array[String] = []
	var scores := {}
	for path in found.keys():
		var path_string := str(path)
		paths.append(path_string)
		scores[path_string] = _animation_candidate_score(path_string, mesh_uasset_path)
	paths.sort_custom(func(a: String, b: String) -> bool:
		var score_a := int(scores[a])
		var score_b := int(scores[b])
		if score_a == score_b:
			return a.naturalnocasecmp_to(b) < 0
		return score_a > score_b
	)
	return paths


## Export mesh from a .uasset to a user-chosen output directory as GLB.
## Runs in a background thread. Emits operation_finished when done.
func export_glb(uasset_path: String, output_dir: String) -> void:
	_start_operation(_do_export_glb.bind(uasset_path, output_dir))


# ── Cache ─────────────────────────────────────────────────────────────────────


func _get_cache_dir() -> String:
	return OS.get_temp_dir().path_join(CACHE_DIR)


func _cache_key(uasset_path: String) -> String:
	var mtime := FileAccess.get_modified_time(uasset_path)
	return "v%d_%s_%s" % [CACHE_VERSION, str(uasset_path.hash()), str(mtime)]


func _animation_cache_key(uasset_path: String) -> String:
	var mtime := FileAccess.get_modified_time(uasset_path)
	return "anim_v%d_%s_%s" % [CACHE_VERSION, str(uasset_path.hash()), str(mtime)]


## Return the bundle root containing the glTF, .mat descriptors, and textures.
func get_preview_resource_root(gltf_path: String) -> String:
	var cache_dir := _get_cache_dir().simplify_path()
	var normalized_path := gltf_path.simplify_path()
	var prefix := cache_dir + "/"
	if normalized_path.begins_with(prefix):
		var relative := normalized_path.trim_prefix(prefix)
		var cache_key := relative.get_slice("/", 0)
		return cache_dir.path_join(cache_key)
	return normalized_path.get_base_dir()


## Check if a cached glTF exists for this asset. Returns path or "".
func get_cached_mesh(uasset_path: String) -> String:
	var cache_subdir := _get_cache_dir().path_join(_cache_key(uasset_path))
	if not DirAccess.dir_exists_absolute(cache_subdir):
		return ""
	var gltf := _find_file_recursive(cache_subdir, "gltf")
	if gltf.is_empty():
		gltf = _find_file_recursive(cache_subdir, "glb")
	return gltf


## Remove cached glTF/material/texture exports for this mesh asset.
## Texture edits can change referenced files without changing the mesh .uasset,
## so refresh needs an explicit cache clear.
func clear_cached_mesh(uasset_path: String) -> void:
	var cache_dir := _get_cache_dir()
	var dir := DirAccess.open(cache_dir)
	if not dir:
		return
	var prefix := "v%d_%s_" % [CACHE_VERSION, str(uasset_path.hash())]
	for child_dir in dir.get_directories():
		var name := str(child_dir)
		if name.begins_with(prefix):
			FileUtils.remove_dir_recursive(cache_dir.path_join(name))


## Check if cached MD5Anim files exist for this asset.
func get_cached_animations(uasset_path: String) -> Array[String]:
	var cache_subdir := _get_cache_dir().path_join(_animation_cache_key(uasset_path))
	if not DirAccess.dir_exists_absolute(cache_subdir):
		return []
	return _find_files_recursive(cache_subdir, "md5anim")


# ── Background operations ────────────────────────────────────────────────────


func _start_operation(task: Callable) -> void:
	var error := _start_background(task, _on_operation_done)
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		operation_finished.emit(OperationResult.failed(
				"Could not start mesh operation (error %d)" % error))


func _on_operation_done(result: OperationResult) -> void:
	operation_finished.emit(result)


# ── Core operation ───────────────────────────────────────────────────────────


## Export uasset → glTF via umodel.
func _do_export_gltf(uasset_path: String, output_dir: String) -> OperationResult:
	var umodel := _cfg.get_umodel_path()
	if umodel.is_empty() or not FileAccess.file_exists(umodel):
		return OperationResult.failed("umodel not configured")

	if not FileAccess.file_exists(uasset_path):
		return OperationResult.failed("File not found: %s" % uasset_path)

	var output_dir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if output_dir_error != OK:
		return OperationResult.failed(
				"Could not create export folder (error %d)" % output_dir_error)

	# umodel command: export as glTF using Spellbreak's UE version flag.
	var game_flag := _cfg.get_game_profile().umodel_game_flag
	var output: Array = []
	var code := OS.execute(umodel, [
		"-export", "-gltf", "-game=%s" % game_flag, "-out=%s" % output_dir, uasset_path,
	], output, true, false)

	if code != 0:
		var err_text := ProcessUtils.output_text(output)
		return OperationResult.failed(
				"umodel export failed (exit %d): %s" % [code, err_text])

	# Find the exported glTF file (umodel may place it in a subdirectory)
	var gltf_path := _find_file_recursive(output_dir, "gltf")
	if gltf_path.is_empty():
		gltf_path = _find_file_recursive(output_dir, "glb")
	if gltf_path.is_empty():
		return OperationResult.failed("No glTF file produced by umodel")

	return OperationResult.succeeded("Exported to %s" % gltf_path.get_file(), gltf_path)


## User-facing mesh export: write a normalized .glb that Blender and other
## stricter importers accept more reliably than umodel's raw glTF.
func _do_export_glb(uasset_path: String, output_dir: String) -> OperationResult:
	var tmp_result := FileUtils.make_temp_dir("sb_mesh_export")
	if not bool(tmp_result.get("ok", false)):
		return OperationResult.failed(
				str(tmp_result.get("error", "Could not create temp directory")))
	var staging_dir := str(tmp_result["path"])
	var raw_result := _do_export_gltf(uasset_path, staging_dir)
	if not raw_result.ok:
		FileUtils.remove_dir_recursive(staging_dir)
		return raw_result

	var converted := _write_glb_from_gltf(str(raw_result.value), output_dir)
	FileUtils.remove_dir_recursive(staging_dir)
	return converted


func _write_glb_from_gltf(gltf_path: String, output_dir: String) -> OperationResult:
	if not FileAccess.file_exists(gltf_path):
		return OperationResult.failed("glTF file not found: %s" % gltf_path)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		return OperationResult.failed(
				"Could not create export folder (error %d)" % mkdir_error)

	var input_doc := GLTFDocument.new()
	var input_state := GLTFState.new()
	var error := input_doc.append_from_file(gltf_path, input_state, 0, gltf_path.get_base_dir())
	if error != OK:
		return OperationResult.failed("Could not read exported glTF (error %d)" % error)

	var scene := input_doc.generate_scene(input_state)
	if scene == null:
		return OperationResult.failed("Could not build scene from exported glTF")

	var material_result := MeshPreviewMaterialLoader.apply_to_scene(
		scene, get_preview_resource_root(gltf_path))

	var output_doc := GLTFDocument.new()
	var output_state := GLTFState.new()
	error = output_doc.append_from_scene(scene, output_state)
	scene.free()
	if error != OK:
		return OperationResult.failed(
				"Could not prepare Blender-compatible GLB (error %d)" % error)

	var glb_path := output_dir.path_join("%s.glb" % gltf_path.get_file().get_basename())
	error = output_doc.write_to_filesystem(output_state, glb_path)
	if error != OK:
		return OperationResult.failed("Could not write GLB (error %d)" % error)
	var applied_count := int(material_result.get("applied", 0))
	var texture_count := int(material_result.get("texture_count", 0))
	var message := "Exported GLB: %s" % glb_path.get_file()
	if applied_count > 0:
		message += " (%d textured material(s), %d texture(s))" % [
			applied_count, texture_count]
	return OperationResult.succeeded(message, glb_path)


## Export an animation package to MD5Anim via umodel.
func _do_export_md5anim(uasset_path: String, output_dir: String) -> OperationResult:
	var umodel := _cfg.get_umodel_path()
	if umodel.is_empty() or not FileAccess.file_exists(umodel):
		return OperationResult.failed("umodel not configured")

	if not FileAccess.file_exists(uasset_path):
		return OperationResult.failed("File not found: %s" % uasset_path)

	var output_dir_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if output_dir_error != OK:
		return OperationResult.failed(
				"Could not create animation export folder (error %d)" % output_dir_error)

	var game_flag := _cfg.get_game_profile().umodel_game_flag
	var output: Array = []
	var code := OS.execute(umodel, [
		"-export", "-md5", "-game=%s" % game_flag, "-out=%s" % output_dir, uasset_path,
	], output, true, false)

	if code != 0:
		var err_text := ProcessUtils.output_text(output)
		return OperationResult.failed(
				"umodel animation export failed (exit %d): %s" % [code, err_text])

	var md5_files := _find_files_recursive(output_dir, "md5anim")
	if md5_files.is_empty():
		return OperationResult.failed("No MD5Anim file produced by umodel")
	return OperationResult.succeeded(
			"Exported %d animation(s)" % md5_files.size(), md5_files)


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


func _find_files_recursive(dir_path: String, ext: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if not dir:
		return result

	var files := Array(dir.get_files())
	files.sort()
	for file_name in files:
		if str(file_name).get_extension().to_lower() == ext:
			result.append(dir_path.path_join(str(file_name)))

	var directories := Array(dir.get_directories())
	directories.sort()
	for child_dir in directories:
		if not str(child_dir).begins_with("."):
			result.append_array(_find_files_recursive(dir_path.path_join(str(child_dir)), ext))
	return result


func _animation_scan_dirs(mesh_uasset_path: String) -> Array[String]:
	var dirs: Array[String] = []
	var mesh_dir := mesh_uasset_path.get_base_dir()
	_append_existing_dir(dirs, mesh_dir)
	_append_existing_dir(dirs, mesh_dir.path_join("Animations"))
	_append_existing_dir(dirs, mesh_dir.get_base_dir().path_join("Animations"))

	var relative_path := _game_relative_path(mesh_uasset_path)
	var roots := _reference_roots_for_asset(mesh_uasset_path)
	if relative_path.is_empty():
		return dirs

	var relative_dir := relative_path.get_base_dir()
	var content_dir := _content_dir_relative()
	for root in roots:
		_append_existing_dir(dirs, root.path_join(relative_dir))
		_append_existing_dir(dirs, root.path_join(relative_dir.path_join("Animations")))
		_append_existing_dir(dirs, root.path_join(relative_dir.get_base_dir().path_join("Animations")))
		if relative_path.find("/Characters/Human/") >= 0:
			_append_existing_dir(dirs, root.path_join(content_dir.path_join("Characters/Human/Animations")))
		if relative_path.find("/Characters/") >= 0:
			_append_existing_dir(dirs, root.path_join(content_dir.path_join("Characters/Animations")))
	return dirs


func _collect_animation_assets(dir_path: String, found: Dictionary, max_results: int,
		depth: int) -> void:
	if depth < 0 or found.size() >= max_results or not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if not dir:
		return

	var files := Array(dir.get_files())
	files.sort()
	for file_name in files:
		if found.size() >= max_results:
			return
		var path := dir_path.path_join(str(file_name))
		if str(file_name).get_extension().to_lower() == "uasset" and _looks_like_animation_asset(path):
			found[path] = true

	var directories := Array(dir.get_directories())
	directories.sort()
	for child_dir in directories:
		if found.size() >= max_results:
			return
		var child_name := str(child_dir)
		if child_name.begins_with(".") or not _should_scan_animation_dir(child_name):
			continue
		_collect_animation_assets(dir_path.path_join(child_name), found, max_results, depth - 1)


func _looks_like_animation_asset(path: String) -> bool:
	var lower_path := path.replace("\\", "/").to_lower()
	var file_name := lower_path.get_file()
	for excluded in ["animbp", "animblueprint", "blueprint", "montage"]:
		if excluded in file_name:
			return false
	if file_name.begins_with("bp_"):
		return false
	if "/animations/" in lower_path:
		return true
	for keyword in [
		"anim", "idle", "walk", "run", "jump", "crouch", "attack", "drop",
		"fall", "land", "turn", "emote", "pose", "breath", "recover", "cast",
		"skill", "death", "hit", "roll", "sprint", "strafe", "fly", "hover"
	]:
		if keyword in file_name:
			return true
	return false


func _should_scan_animation_dir(dir_name: String) -> bool:
	var lower_name := dir_name.to_lower()
	return lower_name not in [
		"materials", "material", "textures", "texture", "meshes", "mesh",
		"vfx", "fx", "particles", "sounds", "audio",
	]


func _animation_candidate_score(path: String, mesh_uasset_path: String) -> int:
	var lower_path := path.replace("\\", "/").to_lower()
	var lower_file := lower_path.get_file()
	var score := 0
	if "/animations/" in lower_path:
		score += 100
	if path.get_base_dir() == mesh_uasset_path.get_base_dir():
		score += 30
	for keyword in ["idle", "breath", "pose", "mainmenu"]:
		if keyword in lower_file:
			score += 25
	for keyword in ["walk", "run", "crouch", "jump", "land"]:
		if keyword in lower_file:
			score += 12
	if "anim" in lower_file:
		score += 5
	return score


func _reference_roots_for_asset(asset_path: String) -> Array[String]:
	var roots: Array[String] = []
	var asset_root := _asset_root_for_game_relative(asset_path)
	if not asset_root.is_empty():
		_append_existing_dir(roots, asset_root)
	if _cfg != null:
		for source_entry in _cfg.sources:
			if source_entry is Dictionary:
				_append_existing_dir(roots, str(source_entry.get("path", "")).rstrip("/"))
		var mods_dir := _cfg.mods_dir.rstrip("/")
		if not mods_dir.is_empty():
			var modding_dir := mods_dir.get_base_dir()
			for sibling in ["Unchanged", "BaseGame", "Base", "New"]:
				_append_existing_dir(roots, modding_dir.path_join(sibling))
	return roots


func _asset_root_for_game_relative(path: String) -> String:
	var relative_path := _game_relative_path(path)
	if relative_path.is_empty():
		return ""
	var normalized := path.replace("\\", "/").simplify_path()
	var index := normalized.find("/" + relative_path)
	if index < 0:
		return ""
	return normalized.substr(0, index)


func _game_relative_path(path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path()
	var content_root := ""
	if _cfg != null:
		content_root = _cfg.get_game_profile().content_root.replace("\\", "/").strip_edges()
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


func _content_dir_relative() -> String:
	if _cfg == null:
		return "Content"
	var content_root := _cfg.get_game_profile().content_root.replace("\\", "/").strip_edges()
	content_root = content_root.trim_prefix("/").trim_suffix("/")
	return "Content" if content_root.is_empty() else content_root.path_join("Content")


func _append_existing_dir(dirs: Array[String], path: String) -> void:
	var normalized := path.replace("\\", "/").simplify_path().rstrip("/")
	if normalized.is_empty() or normalized in dirs:
		return
	if DirAccess.dir_exists_absolute(normalized):
		dirs.append(normalized)
