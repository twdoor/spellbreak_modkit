class_name SkinCloneService extends BackgroundOperationService

## Discover the skin reference graph and clone only the paths to editable art.
## Uses extracted sources and the normal converter/registry pipeline.
signal finished(result: OperationResult)

const COSMETICS := "/Game/Blueprints/Cosmetics/Skins/"
const ROOTS := ["/Game/Characters/", "/Game/Data/Skins/",
	"/Game/UI/Textures/assets/cosmetics/skins/"]
const EXTS := ["uasset", "uexp", "ubulk", "uptnl"]

func clone_skin(source_path: String, source_root: String, destination: String,
		cfg: ModConfigManager, display_name: String = "") -> void:
	var error := _start_background(_build.bind(source_path, source_root, destination, cfg, display_name),
		func(result: OperationResult) -> void: finished.emit(result))
	if error != OK:
		finished.emit(OperationResult.failed("Could not start skin cloning"))

static func is_skin(path: String) -> bool:
	return path.replace("\\", "/").contains("/Blueprints/Cosmetics/Skins/BP_Cosmetic_Skin_") \
		and path.ends_with(".uasset")

static func blueprint_destination(mod_root: String, blueprint_name: String) -> String:
	var skin_name := blueprint_name.trim_prefix("BP_Cosmetic_Skin_")
	return mod_root.path_join("g3/Content/Blueprints/Cosmetics/Skins").path_join(skin_name).path_join(blueprint_name + ".uasset")

static func raw_skin_package(skin_name: String, leaf: String) -> String:
	# XCharacterSkin is a PrimaryAssetType scanned only in these game paths.
	return "/Game/Data/Skins/" + skin_name + "/" + leaf

static func clone_leaf(leaf: String, donor_name: String, skin_name: String) -> String:
	var renamed := leaf.replace(donor_name, skin_name)
	if renamed == leaf:
		renamed = leaf.replace(donor_name.replace("_", ""), skin_name)
	return renamed if renamed != leaf else skin_name + "_" + leaf

static func asset_folder(package: String, asset: UAssetFile) -> String:
	if is_optional_icon(package):
		return "Icons"
	if asset.is_texture_asset():
		return "Textures"
	if package.begins_with("/Game/Data/Skins/"):
		return "Data"
	for export in asset.exports:
		if asset.get_export_class_name(export) in ["SkeletalMesh", "StaticMesh"]:
			return "Meshes"
	return "Materials"

static func _collect_reference_strings(value: Variant, strings: Array[String]) -> void:
	if value is String:
		if value.begins_with("/Game/") and not value in strings:
			strings.append(value)
	elif value is Dictionary:
		for key in value:
			if key != "$type":
				_collect_reference_strings(value[key], strings)
	elif value is Array:
		for child in value:
			_collect_reference_strings(child, strings)

static func package_refs(asset: UAssetFile, own_package: String) -> Array[String]:
	var refs: Array[String] = []
	var follow := own_package.begins_with(COSMETICS) or own_package.begins_with("/Game/Data/Skins/")
	for export in asset.exports:
		if asset.get_export_class_name(export) in ["SkeletalMesh", "StaticMesh", "MaterialInstanceConstant"]:
			follow = true
	if not follow:
		return refs
	# Resolve actual serialized references, not NameMap bases: an FName can
	# combine the base Foo with a number to reference the package Foo_1.
	var serialized := asset.to_dict()
	var strings: Array[String] = []
	_collect_reference_strings(serialized.get("Imports", []), strings)
	_collect_reference_strings(serialized.get("Exports", []), strings)
	for name in strings:
		var pkg := name.get_slice(".", 0)
		if pkg == own_package or pkg in refs or ".." in pkg:
			continue
		for root in ROOTS:
			if pkg.begins_with(root):
				refs.append(pkg)
				break
	return refs

static func is_optional_icon(package: String) -> bool:
	return package.begins_with("/Game/UI/Textures/assets/cosmetics/skins/")

static func is_colour_map(package: String) -> bool:
	return RegEx.create_from_string("_ChrTBC(?:_[0-9]+)?$").search(package) != null

static func retained_packages(graph: Dictionary, blueprint: String) -> Dictionary:
	var keep := {blueprint: true}
	for pkg: String in graph:
		if pkg.begins_with("/Game/Data/Skins/") or is_colour_map(pkg) \
				or "/headshot/" in pkg or "/fullbody/" in pkg:
			keep[pkg] = true
	var changed := true
	while changed:
		changed = false
		for pkg: String in graph:
			for child: String in graph[pkg]:
				if keep.has(child) and not keep.has(pkg):
					keep[pkg] = true
					changed = true
	return keep

## Simultaneous exact replacements avoid collisions and accidental substring edits.
static func rewrite(value: Variant, identities: Dictionary, text_key: String = "", display_name: String = "") -> Variant:
	if value is String:
		return identities.get(value, value)
	if value is Dictionary:
		for key in value:
			if key != "$type":
				value[key] = rewrite(value[key], identities, text_key, display_name)
		if not text_key.is_empty() and "TextPropertyData" in str(value.get("$type", "")) \
				and str(value.get("Name", "")) in ["DisplayName", "Description"]:
			value["Namespace"] = "SpellbreakModkit." + text_key
			value["Key"] = text_key + "_" + str(value["Name"])
			if value["Name"] == "DisplayName" and not display_name.is_empty():
				value["SourceString"] = display_name
				if value.get("CultureInvariantString") != null:
					value["CultureInvariantString"] = display_name
	elif value is Array:
		for i in value.size():
			value[i] = rewrite(value[i], identities, text_key, display_name)
	return value

func _build(source_path: String, source_root: String, destination: String,
		cfg: ModConfigManager, display_name: String = "") -> OperationResult:
	if not is_skin(source_path) or not destination.get_file().begins_with("BP_Cosmetic_Skin_"):
		return OperationResult.failed("Skin names must start with BP_Cosmetic_Skin_")
	var description := ModManifest.describe_unique_clone(source_path, destination, cfg)
	if not description.ok:
		return description
	var mod: ModInfo = description.value.mod
	for existing: String in ModDiscovery.list_mod_files(mod.path, "g3"):
		if existing.get_file() == destination.get_file():
			return OperationResult.failed("This mod already contains a skin with that name: " + existing + ". Choose another name or a new mod.")
	var bp: String = str(description.value.source).get_slice(".", 0)
	var target_bp: String = str(description.value.target).get_slice(".", 0)
	var prefix := destination.get_file().get_basename().trim_prefix("BP_Cosmetic_Skin_")
	var identifier := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*$")
	if identifier.search(prefix) == null:
		return OperationResult.failed("Enter a valid skin name after BP_Cosmetic_Skin_")
	var content := source_root.path_join("g3/Content")
	var assets := {}
	var graph := {}
	var missing_icons: Array[String] = []
	var pending: Array[String] = [bp]
	while not pending.is_empty():
		var pkg: String = pending.pop_front()
		if assets.has(pkg) or pkg in missing_icons:
			continue
		if assets.size() >= 256:
			return OperationResult.failed("Skin graph exceeds 256 packages; inspect the source references")
		var path := content.path_join(pkg.trim_prefix("/Game/") + ".uasset")
		if not FileAccess.file_exists(path):
			if is_optional_icon(pkg):
				missing_icons.append(pkg)
				continue
			return OperationResult.failed("Missing required skin dependency: " + path)
		var asset := UAssetFile.load_file(path)
		if asset == null:
			return OperationResult.failed("Could not read skin dependency: " + path)
		assets[pkg] = asset
		graph[pkg] = package_refs(asset, pkg)
		pending.append_array(graph[pkg])
	var keep := retained_packages(graph, bp)
	var renames := {}
	var identities := {}
	var declarations: Array = []
	var targets := {}
	for pkg: String in keep:
		var donor: UAssetFile = assets[pkg]
		var donor_name := bp.get_file().trim_prefix("BP_Cosmetic_Skin_")
		var target := target_bp if pkg == bp else target_bp.get_base_dir().path_join(
			asset_folder(pkg, donor)).path_join(clone_leaf(pkg.get_file(), donor_name, prefix))
		if pkg.begins_with("/Game/Data/Skins/"):
			target = raw_skin_package(prefix, clone_leaf(pkg.get_file(), donor_name, prefix))
		renames[pkg] = target
		for suffix in ["", "_C", "Default__"]:
			var old: String = suffix + pkg.get_file() if suffix == "Default__" else pkg.get_file() + suffix
			var new: String = suffix + target.get_file() if suffix == "Default__" else target.get_file() + suffix
			if identities.has(old) and identities[old] != new:
				return OperationResult.failed("Ambiguous asset name in skin graph: " + old)
			identities[old] = new
		identities["Default__" + pkg.get_file() + "_C"] = "Default__" + target.get_file() + "_C"
		identities[pkg] = target
		identities[pkg + "." + pkg.get_file()] = target + "." + target.get_file()
		identities[pkg + "." + pkg.get_file() + "_C"] = target + "." + target.get_file() + "_C"
		var relative := "g3/Content/" + target.trim_prefix("/Game/")
		for ext in EXTS:
			var rel: String = relative + "." + ext
			if targets.has(rel) or FileAccess.file_exists(mod.path.path_join(rel)) \
					or FileAccess.file_exists(source_root.path_join(rel)):
				return OperationResult.failed("Skin destination already exists: " + rel)
			targets[rel] = true
		declarations.append({"mod": mod, "file": relative + ".uasset",
			"source": pkg + "." + pkg.get_file(), "target": target + "." + target.get_file(),
			"reference_group": target_bp.get_base_dir()})
	# NameMap entries omit numbered FName suffixes; rewrite their bases too.
	for old: String in identities.keys():
		var old_parts := UAssetFile.split_fname(old)
		var new_parts := UAssetFile.split_fname(str(identities[old]))
		if not str(old_parts.suffix).is_empty() and old_parts.suffix == new_parts.suffix:
			if identities.has(old_parts.base) and identities[old_parts.base] != new_parts.base:
				return OperationResult.failed("Ambiguous numbered asset name: " + old)
			identities[old_parts.base] = new_parts.base
	var temp := FileUtils.make_temp_dir("skin_clone")
	if not temp.get("ok", false):
		return OperationResult.failed("Could not create skin staging directory")
	var stage: String = temp.path
	var result := _stage_and_install(assets, renames, identities, declarations, stage, mod, cfg, bp, display_name)
	FileUtils.remove_dir_recursive(stage)
	if result.ok and not missing_icons.is_empty():
		result.message += " Skipped %d missing optional icon(s); their original references are unchanged." % missing_icons.size()
		result.metadata["missing_optional_icons"] = missing_icons
	return result

func _stage_and_install(assets: Dictionary, renames: Dictionary, identities: Dictionary,
		declarations: Array, stage: String, mod: ModInfo, cfg: ModConfigManager,
		blueprint: String, display_name: String) -> OperationResult:
	var files: Array[String] = []
	var python := ProcessUtils.find_python()
	var texture_script := ToolchainRegistry.dds_tools_script().get_base_dir().path_join("clone_texture.py")
	if python.is_empty() or not FileAccess.file_exists(texture_script):
		return OperationResult.failed("Skin cloning requires Python and the bundled texture cloning tool")
	var map_path := stage.path_join("identities.json")
	if FileUtils.write_bytes_atomic(map_path, JSON.stringify(identities).to_utf8_buffer()) != OK:
		return OperationResult.failed("Could not stage skin reference map")
	for declaration: Dictionary in declarations:
		var pkg: String = str(declaration.source).get_slice(".", 0)
		var source: UAssetFile = assets[pkg]
		var path := stage.path_join(declaration.file)
		if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
			return OperationResult.failed("Could not create skin staging folder")
		if source.is_texture_asset():
			var output: Array = []
			var code := ProcessUtils.run_python_script(python, texture_script, texture_script.get_base_dir(),
				[source.binary_path, path, map_path], output)
			if code != 0:
				return OperationResult.failed("Could not relocate texture %s: %s" % [pkg, ProcessUtils.output_text(output, "no output")])
		else:
			if FileAccess.file_exists(source.binary_path.get_basename() + ".ubulk"):
				return OperationResult.failed("Non-texture bulk package is not supported: " + pkg)
			var data: Dictionary = rewrite(source.to_dict(), identities,
				str(renames[pkg]).get_file() if pkg == blueprint else "", display_name)
			data["PackageGuid"] = UAssetFile._generate_package_guid()
			var copy := UAssetFile._from_dict(data, source.binary_path)
			copy.binary_path = source.binary_path
			copy.game_profile = source.game_profile
			if copy.save_file(path) != OK:
				return OperationResult.failed("Could not serialize skin package: " + pkg)

		for ext in EXTS:
			var rel: String = str(declaration.file).get_basename() + "." + ext
			if FileAccess.file_exists(stage.path_join(rel)):
				files.append(rel)
	var installed: Array[String] = []
	var staged_files: Array = []
	for rel in files:
		var target := mod.path.path_join(rel)
		if FileAccess.file_exists(target) or DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
			return OperationResult.failed("Skin destination already exists or is unwritable: " + rel)
		staged_files.append({"source": stage.path_join(rel), "target": target})
		installed.append(target)
	var install_error := FileUtils.install_staged_files(staged_files)
	if install_error != OK:
		return OperationResult.failed("Could not install skin files (error %d)" % install_error)
	var recorded := ModManifest.record_unique_clones(declarations, cfg)
	if not recorded.ok:
		_rollback(installed)
		return recorded
	return OperationResult.succeeded("Cloned skin with %d packages. Open its textures to import PNG artwork." % declarations.size(),
		mod.path.path_join(declarations.filter(func(d: Dictionary) -> bool:
			return str(d.source).get_slice(".", 0) == blueprint)[0].file))

func _rollback(paths: Array[String]) -> void:
	for path in paths:
		if DirAccess.remove_absolute(path) != OK:
			push_error("Could not roll back skin file: " + path)
