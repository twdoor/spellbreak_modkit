class_name ModManifest extends RefCounted

## Per-mod workspace manifest helpers. The manifest lives at the mod root,
## outside the game content folder, so it documents the workspace without being
## packed into the generated .pak.

const MANIFEST_FILENAME := "spellbreak_mod_manifest.json"
const SCHEMA_VERSION := 1


static func manifest_path(mod: ModInfo) -> String:
	return mod.path.rstrip("/").path_join(MANIFEST_FILENAME)


static func write_workspace_manifest(mod: ModInfo, cfg: ModConfigManager) -> Error:
	var manifest := _load_or_new(mod)
	_refresh_metadata(manifest, mod, cfg)
	_merge_current_files(manifest, mod, cfg)
	return _write_manifest(mod, manifest)


static func record_copied_files(mod: ModInfo, source_root: String,
		file_paths: Array, cfg: ModConfigManager) -> Error:
	var manifest := _load_or_new(mod)
	_refresh_metadata(manifest, mod, cfg)
	var by_target := _files_by_target(manifest)
	var normalized_source_root := source_root.rstrip("/")
	for src_value in file_paths:
		var source_path := str(src_value)
		if not FileUtils.is_path_within(source_path, normalized_source_root):
			continue
		var relative := _relative_path(source_path, normalized_source_root)
		if relative.is_empty():
			continue
		var entry: Dictionary = by_target.get(relative, {"target": relative})
		entry["source"] = {
			"root": normalized_source_root,
			"path": source_path,
			"relative": relative,
		}
		entry["source_recorded_at_unix"] = Time.get_unix_time_from_system()
		by_target[relative] = entry
	_merge_current_files(manifest, mod, cfg, by_target)
	return _write_manifest(mod, manifest)


## Validate and describe a clone that should be registered as a new package.
## Object paths are derived from workspace paths so users never enter them.
static func describe_unique_clone(source_path: String, destination_path: String,
		cfg: ModConfigManager) -> OperationResult:
	if source_path.get_extension().to_lower() != "uasset" \
			or destination_path.get_extension().to_lower() != "uasset":
		return OperationResult.failed("only .uasset packages can be marked unique")

	var source_root := ""
	for source_value in cfg.sources:
		if not source_value is Dictionary:
			continue
		var candidate := str(source_value.get("path", "")).rstrip("/")
		if not candidate.is_empty() and FileUtils.is_path_within(source_path, candidate):
			source_root = candidate
			break
	if source_root.is_empty():
		return OperationResult.failed(
				"unique clones must start from a configured base source")

	var owner: ModInfo = null
	for mod in ModDiscovery.scan(cfg.mods_dir, cfg.get_game_profile().content_root):
		if FileUtils.is_path_within(destination_path, mod.path):
			owner = mod
			break
	if owner == null:
		return OperationResult.failed(
				"unique clones must be saved inside a mod workspace")

	var content_root := cfg.get_game_profile().content_root
	var source_object := _object_path_for_file(source_path, source_root, content_root)
	var target_object := _object_path_for_file(destination_path, owner.path, content_root)
	if source_object.is_empty():
		return OperationResult.failed(
				"source package must be under %s/Content" % content_root)
	if target_object.is_empty():
		return OperationResult.failed(
				"cloned package must be under %s/Content" % content_root)
	if source_object == target_object:
		return OperationResult.failed("unique clone needs a new package path")

	return OperationResult.succeeded("Unique clone is valid", {
		"mod": owner,
		"file": _relative_path(destination_path, owner.path),
		"source": source_object,
		"target": target_object,
	})


## Persist a validated description returned by describe_unique_clone().
static func record_unique_clone(description: Dictionary,
		cfg: ModConfigManager) -> OperationResult:
	var mod := description.get("mod") as ModInfo
	if mod == null:
		return OperationResult.failed("unique clone has no destination mod")
	var file_path := str(description.get("file", ""))
	var source := str(description.get("source", ""))
	var target := str(description.get("target", ""))
	if file_path.is_empty() or source.is_empty() or target.is_empty():
		return OperationResult.failed("unique clone declaration is incomplete")

	var manifest := _load_or_new(mod)
	_refresh_metadata(manifest, mod, cfg)
	_merge_current_files(manifest, mod, cfg)
	var custom_assets: Array = []
	for value in manifest.get("custom_assets", []):
		if value is Dictionary and str(value.get("target", "")) != target:
			custom_assets.append((value as Dictionary).duplicate(true))
	custom_assets.append({
		"file": file_path,
		"source": source,
		"target": target,
	})
	custom_assets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("target", "")) < str(b.get("target", "")))
	manifest["custom_assets"] = custom_assets
	var error := _write_manifest(mod, manifest)
	if error != OK:
		return OperationResult.failed(
				"could not update the mod manifest (error %d)" % error)
	return OperationResult.succeeded("Recorded unique clone", manifest_path(mod))


static func _load_or_new(mod: ModInfo) -> Dictionary:
	var path := manifest_path(mod)
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file:
			var parsed: Variant = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary:
				return (parsed as Dictionary).duplicate(true)
	return {}


static func _refresh_metadata(manifest: Dictionary, mod: ModInfo,
		cfg: ModConfigManager) -> void:
	var profile := cfg.get_game_profile()
	manifest["schema_version"] = SCHEMA_VERSION
	manifest["updated_at_unix"] = Time.get_unix_time_from_system()
	manifest["mod"] = {
		"name": mod.name,
		"folder": mod.path.get_file(),
	}
	manifest["profile"] = {
		"id": profile.profile_id,
		"display_name": profile.display_name,
		"ue_version": profile.ue_version,
		"content_root": profile.content_root,
		"pak_archive_version": profile.pak_archive_version,
		"pak_mount_point": profile.pak_mount_point,
		"pak_output_name": profile.pak_output_name,
		"audio_format": profile.audio_format,
	}
	manifest["build"] = {
		"content_root": profile.content_root,
		"pak_output_name": profile.pak_output_name,
		"pak_archive_version": profile.pak_archive_version,
		"pak_mount_point": profile.pak_mount_point,
	}
	manifest["sources"] = _sources_snapshot(cfg.sources)


static func _merge_current_files(manifest: Dictionary, mod: ModInfo,
		cfg: ModConfigManager, by_target: Dictionary = {}) -> void:
	if by_target.is_empty():
		by_target = _files_by_target(manifest)
	var mod_path := mod.path.rstrip("/")
	var content_root := cfg.get_game_profile().content_root
	var current := {}
	for rel_value in ModDiscovery.list_mod_files(mod_path, content_root):
		var rel := str(rel_value)
		var entry: Dictionary = by_target.get(rel, {"target": rel})
		var full_path := mod_path.path_join(rel)
		entry["target"] = rel
		entry["size_bytes"] = _file_size(full_path)
		entry["modified_time_unix"] = FileAccess.get_modified_time(full_path)
		entry["extension"] = rel.get_extension().to_lower()
		current[rel] = entry
	_set_files_from_map(manifest, current)


static func _files_by_target(manifest: Dictionary) -> Dictionary:
	var result := {}
	for entry in manifest.get("files", []):
		if entry is Dictionary:
			var target := str(entry.get("target", ""))
			if not target.is_empty():
				result[target] = (entry as Dictionary).duplicate(true)
	return result


static func _set_files_from_map(manifest: Dictionary, by_target: Dictionary) -> void:
	var targets := by_target.keys()
	targets.sort()
	var files: Array = []
	for target in targets:
		files.append(by_target[target])
	manifest["files"] = files


static func _sources_snapshot(sources: Array) -> Array:
	var result: Array = []
	for entry in sources:
		if entry is Dictionary:
			result.append({
				"name": str(entry.get("name", "")),
				"path": str(entry.get("path", "")),
			})
	return result


static func _write_manifest(mod: ModInfo, manifest: Dictionary) -> Error:
	var path := manifest_path(mod)
	if path.get_base_dir().is_empty():
		return ERR_INVALID_PARAMETER
	var text := JSON.stringify(manifest, "  ")
	return FileUtils.write_bytes_atomic(path, text.to_utf8_buffer())


static func _relative_path(path: String, root: String) -> String:
	var normalized_path := path.replace("\\", "/").simplify_path()
	var normalized_root := root.replace("\\", "/").simplify_path().rstrip("/")
	if normalized_path == normalized_root:
		return ""
	if not normalized_path.begins_with(normalized_root + "/"):
		return ""
	return normalized_path.substr(normalized_root.length() + 1)


static func _object_path_for_file(path: String, workspace_root: String,
		content_root: String) -> String:
	var relative := _relative_path(path, workspace_root)
	var prefix := content_root.rstrip("/") + "/Content/"
	if not relative.begins_with(prefix):
		return ""
	var package_relative := relative.substr(prefix.length()).get_basename()
	if package_relative.is_empty():
		return ""
	var leaf := package_relative.get_file()
	return "/Game/%s.%s" % [package_relative, leaf]


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return 0
	var size := file.get_length()
	file.close()
	return size
