class_name ModDiscovery extends RefCounted

## Scans a mods directory and returns metadata for each discovered mod.
## A valid mod is any subdirectory that contains a g3/ subfolder.
## Mirrors the discover_mods() logic in mod_manager.py.

const ASSET_EXTENSIONS := [".uasset", ".uexp", ".ubulk", ".umap"]


## Returns an Array of Dictionaries:
##   { "name": String, "path": String, "file_count": int, "size_bytes": int }
## content_root: the top-level folder inside each mod (e.g. "g3" for Spellbreak, "Content" for generic).
static func scan(mods_dir: String, content_root: String = "g3") -> Array:
	var results: Array = []
	if mods_dir.is_empty() or not DirAccess.dir_exists_absolute(mods_dir):
		return results

	var dir := DirAccess.open(mods_dir)
	if not dir:
		return results

	# Collect subdirectory names first, then sort
	var names: Array = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	names.sort()

	for mod_name in names:
		var mod_path := mods_dir.path_join(mod_name)
		var content_path := mod_path.path_join(content_root)
		if not DirAccess.dir_exists_absolute(content_path):
			continue
		var assets := _list_assets(content_path)
		results.append({
			"name":       mod_name,
			"path":       mod_path,
			"file_count": assets.size(),
			"size_bytes": _dir_size(content_path),
		})

	return results


## List all .uasset/.uexp/.ubulk/.umap absolute paths recursively under base_path.
static func list_assets(base_path: String) -> Array:
	return _list_assets(base_path)


## List all file paths relative to mod_path, recursively under its content root folder.
## content_root: the top-level folder inside the mod (e.g. "g3" for Spellbreak).
static func list_mod_files(mod_path: String, content_root: String = "g3") -> Array:
	var root := mod_path.path_join(content_root)
	if not DirAccess.dir_exists_absolute(root):
		return []
	var all_files := _list_all_files(root)
	var result: Array = []
	for f in all_files:
		result.append(f.trim_prefix(mod_path + "/"))
	result.sort()
	return result


static func fmt_size(bytes: int) -> String:
	if bytes < 1024:    return "%d B" % bytes
	if bytes < 1048576: return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


# ── Private ────────────────────────────────────────────────────────────────────

static func _list_assets(base_path: String) -> Array:
	var result: Array = []
	_walk(base_path, func(path: String):
		for ext in ASSET_EXTENSIONS:
			if path.ends_with(ext):
				result.append(path)
				break
	)
	return result


static func _list_all_files(base_path: String) -> Array:
	var result: Array = []
	_walk(base_path, func(path: String): result.append(path))
	return result


static func _walk(path: String, cb: Callable) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	var entries: Array = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		entries.append({"name": entry, "is_dir": dir.current_is_dir()})
		entry = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a, b): return a["name"] < b["name"])

	for e in entries:
		var full := path.path_join(e["name"])
		if e["is_dir"] and not (e["name"] as String).begins_with("."):
			_walk(full, cb)
		elif not e["is_dir"]:
			cb.call(full)


static func _dir_size(path: String) -> int:
	var total := 0
	var files := _list_all_files(path)
	for f in files:
		var fa := FileAccess.open(f, FileAccess.READ)
		if fa:
			total += fa.get_length()
			fa.close()
	return total
