class_name ModPreflight extends RefCounted

## Conservative validation before packing a mod. Errors block the build because
## they are platform/path hazards or incomplete package fragments. Warnings are
## logged but do not block because some mods intentionally include loose files.

enum Severity {
	WARNING,
	ERROR,
}

const PACKAGE_EXTENSIONS := ["uasset", "uexp", "ubulk", "umap", "uptnl"]
const COMPANION_EXTENSIONS := ["uexp", "ubulk", "uptnl"]
const TEXT_SIDEcar_EXTENSIONS := ["txt", "json", "ini", "cfg", "csv", "md"]


static func validate_mod_for_pack(mod: ModInfo, cfg: ModConfigManager) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var mod_path := mod.path.rstrip("/")
	var mod_name := mod.name if not mod.name.is_empty() else mod_path.get_file()
	var content_root := cfg.get_game_profile().content_root
	var content_path := mod_path.path_join(content_root)
	if not FileUtils.is_path_within(content_path, mod_path):
		issues.append(_issue(Severity.ERROR, mod_name,
				"Content root escapes the mod folder: %s" % content_root))
		return issues
	if not DirAccess.dir_exists_absolute(content_path):
		issues.append(_issue(Severity.ERROR, mod_name,
				"Missing content root folder: %s" % content_root))
		return issues

	var files := ModDiscovery.list_mod_files(mod_path, content_root)
	var lower_paths := {}
	var package_exts_by_base := {}
	var uasset_bases := {}
	for rel_value in files:
		var rel := str(rel_value).replace("\\", "/")
		var full_path := mod_path.path_join(rel)
		var lower := rel.to_lower()
		if lower_paths.has(lower):
			issues.append(_issue(Severity.ERROR, mod_name,
					"Case-colliding paths: %s and %s" % [str(lower_paths[lower]), rel]))
		else:
			lower_paths[lower] = rel

		if _path_has_unsafe_segment(rel):
			issues.append(_issue(Severity.ERROR, mod_name, "Unsafe relative path: %s" % rel))

		var file_name := rel.get_file()
		if file_name.begins_with(".") or ".sb_" in file_name:
			issues.append(_issue(Severity.WARNING, mod_name,
					"Staged/backup-looking file will be packed: %s" % rel))

		var ext := rel.get_extension().to_lower()
		if ext in PACKAGE_EXTENSIONS:
			var base := rel.get_basename()
			var exts: Array = package_exts_by_base.get(base, [])
			if not ext in exts:
				exts.append(ext)
			package_exts_by_base[base] = exts
			if ext in ["uasset", "umap"]:
				uasset_bases[base] = true
		elif ext not in TEXT_SIDEcar_EXTENSIONS:
			issues.append(_issue(Severity.WARNING, mod_name,
					"Unsupported or unusual loose file type: %s" % rel))

		if not FileAccess.file_exists(full_path):
			issues.append(_issue(Severity.ERROR, mod_name, "Missing file during scan: %s" % rel))

	for base in package_exts_by_base.keys():
		if base in uasset_bases:
			continue
		var exts: Array = package_exts_by_base[base]
		var has_companion := false
		for ext in COMPANION_EXTENSIONS:
			if ext in exts:
				has_companion = true
				break
		if has_companion:
			issues.append(_issue(Severity.ERROR, mod_name,
					"Package companion has no .uasset/.umap header: %s" % base))

	return issues


static func error_count(issues: Array[Dictionary]) -> int:
	var count := 0
	for issue in issues:
		if int(issue.get("severity", Severity.WARNING)) == Severity.ERROR:
			count += 1
	return count


static func warning_count(issues: Array[Dictionary]) -> int:
	var count := 0
	for issue in issues:
		if int(issue.get("severity", Severity.WARNING)) == Severity.WARNING:
			count += 1
	return count


static func severity_text(severity: int) -> String:
	return "ERROR" if severity == Severity.ERROR else "WARN"


static func _issue(severity: int, mod_name: String, message: String) -> Dictionary:
	return {
		"severity": severity,
		"mod": mod_name,
		"message": message,
	}


static func _path_has_unsafe_segment(rel_path: String) -> bool:
	if rel_path.is_empty() or rel_path.begins_with("/") or rel_path.begins_with("\\"):
		return true
	for part in rel_path.replace("\\", "/").split("/"):
		if part.is_empty() or part == "." or part == "..":
			return true
		if part.length() >= 2 and part.substr(1, 1) == ":":
			return true
	return false
