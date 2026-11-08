class_name ModkitCli extends Node

## Versioned headless boundary shared by source runs and exported applications.
const EXTENSIONS := ["uasset", "uexp", "ubulk", "uptnl"]
var _completed: OperationResult

func run(request_path: String, result_path: String) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	var result: OperationResult
	if not parsed is Dictionary:
		result = OperationResult.failed("Request must be a JSON object")
	else:
		result = await execute(parsed)
	var response := {"schema_version": 1, "ok": result.ok, "message": result.message,
		"value": result.value, "metadata": result.metadata, "backups": result.backups,
		"logs": Array(result.logs)}
	var error := FileUtils.write_bytes_atomic(result_path, JSON.stringify(response).to_utf8_buffer())
	get_tree().quit(0 if result.ok and error == OK else 1)

func execute(request: Dictionary) -> OperationResult:
	var cfg := ModConfigManager.new()
	if request.get("source_root"):
		cfg.sources = [{"name": "CLI source", "path": request.source_root}]
	if request.get("mod"):
		cfg.mods_dir = str(request.mod).get_base_dir()
	if request.get("game_dir"):
		cfg.game_dir = request.game_dir
	var group := str(request.get("group", ""))
	var action := str(request.get("action", ""))
	if group == "doctor":
		var profile := cfg.get_game_profile()
		return OperationResult.succeeded("Spellbreak CLI environment", {
			"settings": cfg.get_config_path(), "sources": cfg.sources, "mods_dir": cfg.mods_dir,
			"game_dir": cfg.game_dir, "python": ProcessUtils.find_python(),
			"dotnet": ProcessUtils.find_dotnet(), "converter": ToolchainRegistry.converter_dll(),
			"umodel": cfg.get_umodel_path(), "u4pak": cfg.get_u4pak_path(),
			"profile": {"ue_version": profile.ue_version, "dds_tools_version": profile.dds_tools_version,
				"pak_version": profile.pak_archive_version, "mount_point": profile.pak_mount_point}})
	if group == "pak":
		if not FileAccess.file_exists(str(request.pak)):
			return OperationResult.failed("Pak does not exist")
		if action == "extract":
			if DirAccess.dir_exists_absolute(request.output_dir) or FileAccess.file_exists(request.output_dir):
				return OperationResult.failed("Extraction output must be a new directory")
			var service := BaseSourceService.new().setup(cfg)
			service.generate_finished.connect(_receive)
			_completed = null
			service.generate(request.pak, request.output_dir)
			return await _wait(service)
		if action not in ["list", "test"]:
			return OperationResult.failed("Unknown pak command")
		var script := cfg.get_u4pak_path()
		var output: Array = []
		var code := ProcessUtils.run_python_script(ProcessUtils.find_python(), script,
			script.get_base_dir(), [action, request.pak], output)
		return OperationResult.new(code == 0, "Pak " + action, ProcessUtils.output_text(output, ""))
	if group == "workflow":
		var service := ModWorkflowService.new()
		service.finished.connect(_receive)
		_completed = null
		service.run(request.workflow)
		return await _wait(service)
	if group == "mod":
		if action == "create":
			if DirAccess.dir_exists_absolute(request.mod) or FileAccess.file_exists(request.mod):
				return OperationResult.failed("Workspace already exists")
			if DirAccess.make_dir_recursive_absolute(str(request.mod).path_join("g3/Content")) != OK:
				return OperationResult.failed("Could not create workspace")
			if ModManifest.write_workspace_manifest(_mod(request.mod), cfg) != OK:
				FileUtils.remove_dir_recursive(request.mod)
				return OperationResult.failed("Could not write workspace manifest")
			return OperationResult.succeeded("Workspace created", request.mod)
		if action == "validate":
			var issues := ModPreflight.validate_mod_for_pack(_mod(request.mod), cfg)
			return OperationResult.new(ModPreflight.error_count(issues) == 0, "Workspace preflight", issues)
		if action == "pack":
			var output := str(request.output)
			if output.get_extension() != "pak":
				return OperationResult.failed("Output must end in .pak")
			for suffix in [".pak", ".sig", ".manifest.json"]:
				if FileAccess.file_exists(output.get_basename() + suffix) and not request.get("overwrite", false):
					return OperationResult.failed("Output exists; use --overwrite: " + output.get_basename() + suffix)
			var mods: Array = []
			for path in request.mods:
				mods.append(_mod(path))
			var service := PackingService.new().setup(cfg)
			service.pack_finished.connect(_receive)
			_completed = null
			service.export_to_path(mods, output, request.get("with_manifest", false))
			return await _wait(service)
	if not request.has("asset") or not FileAccess.file_exists(str(request.asset)):
		return OperationResult.failed("Input asset does not exist")
	if group == "cosmetic" and action == "clone":
		var destination := CosmeticCloneService.blueprint_destination(request.mod, request.name)
		if destination.is_empty():
			return OperationResult.failed("Invalid cosmetic blueprint name")
		var manifest_path := str(request.mod).path_join(ModManifest.MANIFEST_FILENAME)
		if FileAccess.file_exists(manifest_path) and not JSON.parse_string(FileAccess.get_file_as_string(manifest_path)) is Dictionary:
			return OperationResult.failed("Existing manifest is invalid JSON")
		var service := CosmeticCloneService.new()
		service.finished.connect(_receive)
		_completed = null
		service.clone_cosmetic(request.asset, request.source_root, destination, cfg, request.get("display_name", ""))
		return await _wait(service)
	if group in ["texture", "sound", "mesh"]:
		return await _media(request, cfg)
	if group != "asset":
		return OperationResult.failed("Unknown command")
	var precision := _check_json_precision(request.asset)
	if not precision.ok:
		return precision
	var asset := UAssetFile.load_file(request.asset)
	if asset == null:
		return OperationResult.failed("Could not parse asset: " + str(request.asset))
	asset.game_profile = cfg.get_game_profile()
	match action:
		"inspect":
			var exports: Array = []
			for index in asset.exports.size():
				exports.append({"index": index + 1, "name": asset.exports[index].object_name,
					"class": asset.get_export_class_name(asset.exports[index])})
			return OperationResult.succeeded(asset.get_summary(), {"path": request.asset,
				"exports": exports, "imports": asset.to_dict().get("Imports", []),
				"companions": _package_files(request.asset), "guid": asset.package_guid})
		"dump":
			return OperationResult.succeeded("Serializer JSON", asset.to_dict())
		"validate":
			var issues := asset.validate_for_save()
			return OperationResult.new(issues.is_empty(), "Package index validation (not a runtime/media check)", issues)
		"refs":
			var references: Array = []
			_collect_refs(asset.to_dict(), "", references)
			return OperationResult.succeeded("Serialized game references", references)
		"umg":
			var model := UmgDesignerModel.create(asset)
			return OperationResult.new(not model.roots().is_empty(), "Cooked widget hierarchy",
				{"roots": model.roots(), "nodes": model.nodes})
		"diff":
			var other_precision := _check_json_precision(request.other)
			if not other_precision.ok:
				return other_precision
			var other := UAssetFile.load_file(request.other)
			if other == null:
				return OperationResult.failed("Could not parse comparison asset")
			var changes := AssetDiff.compare_assets(asset, other, 5001)
			return OperationResult.succeeded("Semantic differences", {"changes": changes.slice(0, 5000), "truncated": changes.size() > 5000})
		"patch":
			return _patch(asset, request)
		"clone":
			return _clone(asset, request, cfg)
	return OperationResult.failed("Unknown asset command")

func _mod(path: String) -> ModInfo:
	return ModInfo.new(path.get_file(), path)

func _receive(result: OperationResult) -> void:
	_completed = result

func _wait(service: BackgroundOperationService) -> OperationResult:
	while _completed == null:
		await get_tree().process_frame
	service.wait_to_finish()
	return _completed

func _package_files(path: String) -> Array:
	var files: Array = []
	for extension in EXTENSIONS:
		var companion: String = path.get_basename() + "." + extension
		if FileAccess.file_exists(companion):
			files.append(companion)
	return files

func _check_destination(path: String, overwrite: bool) -> OperationResult:
	if path.get_extension() != "uasset":
		return OperationResult.failed("Package output must end in .uasset")
	if not overwrite and not _package_files(path).is_empty():
		return OperationResult.failed("Destination package exists; use --overwrite: " + path)
	return OperationResult.succeeded()

func _collect_refs(value: Variant, path: String, output: Array) -> void:
	if value is String and "/Game/" in value:
		output.append({"path": path, "reference": value})
	elif value is Dictionary:
		for key in value:
			_collect_refs(value[key], path + "/" + str(key).replace("~", "~0").replace("/", "~1"), output)
	elif value is Array:
		for i in value.size():
			_collect_refs(value[i], path + "/" + str(i), output)

## JSON pointers make repeated property names and DataTable rows unambiguous.
static func apply_patch(data: Dictionary, operations: Array) -> OperationResult:
	var copy := data.duplicate(true)
	var replaced := {}
	for operation in operations:
		if not operation is Dictionary or not operation.get("op") in ["test", "replace"] or not operation.has("value"):
			return OperationResult.failed("Expected test/replace operations with value")
		var pointer := str(operation.get("path", ""))
		if not pointer.begins_with("/"):
			return OperationResult.failed("Expected a non-root JSON pointer")
		if operation.op == "replace":
			if replaced.has(pointer):
				return OperationResult.failed("Duplicate replacement path: " + pointer)
			replaced[pointer] = true
		var tokens := pointer.substr(1).split("/")
		var parent: Variant = copy
		for i in tokens.size():
			var token := tokens[i]
			if RegEx.create_from_string("~(?![01])").search(token) != null:
				return OperationResult.failed("Invalid JSON pointer escape: " + pointer)
			token = token.replace("~1", "/").replace("~0", "~")
			var key: Variant = token
			if parent is Array:
				if RegEx.create_from_string("^(0|[1-9][0-9]*)$").search(token) == null or int(token) >= parent.size():
					return OperationResult.failed("Array index out of range: " + pointer)
				key = int(token)
			elif not parent is Dictionary or not parent.has(token):
				return OperationResult.failed("Unknown patch path: " + pointer)
			if i == tokens.size() - 1:
				if operation.op == "test":
					if parent[key] != operation.value:
						return OperationResult.failed("Patch test failed: " + pointer)
				else:
					parent[key] = operation.value
			else:
				parent = parent[key]
	return OperationResult.succeeded("Patch applied", copy)

func _patch(asset: UAssetFile, request: Dictionary) -> OperationResult:
	var destination := str(request.output)
	var checked := _check_destination(destination, request.get("overwrite", false))
	if not checked.ok:
		return checked
	if asset.binary_path.is_empty():
		return OperationResult.failed("Patch input must be a binary .uasset package")
	if asset.is_texture_asset():
		return OperationResult.failed("Use texture import for texture payloads; generic texture serialization is unsafe")
	var patched := apply_patch(asset.to_dict(), request.operations)
	if not patched.ok:
		return patched
	var temporary := FileUtils.make_temp_dir("sb_cli_patch")
	if not temporary.get("ok", false):
		return OperationResult.failed("Could not create staging directory")
	var stage: String = temporary.path
	var json_path := stage.path_join("edited.json")
	var result := OperationResult.failed("Could not stage patch JSON")
	if FileUtils.write_bytes_atomic(json_path, JSON.stringify(patched.value).to_utf8_buffer()) == OK:
		var edited := UAssetFile.load_file(json_path)
		if edited != null:
			edited.binary_path = asset.binary_path
			var issues := edited.validate_for_save()
			if not issues.is_empty():
				result = OperationResult.new(false, "Patch creates invalid references", issues)
			elif request.get("dry_run", false):
				result = OperationResult.succeeded("Patch preview; no package written", AssetDiff.compare_assets(asset, edited))
			else:
				var staged := stage.path_join(destination.get_file())
				if edited.save_file(staged) != OK:
					result = OperationResult.failed("Could not serialize patch")
				else:
					var reopened := UAssetFile.load_file(staged)
					if reopened == null:
						result = OperationResult.failed("Could not reopen staged package")
					else:
						# Verify every requested final value before touching the destination.
						var verification: Array = []
						for operation in request.operations:
							if operation.op == "replace":
								verification.append({"op": "test", "path": operation.path, "value": operation.value})
						result = apply_patch(reopened.to_dict(), verification)
						if result.ok:
							result = _verify_install(staged, destination)
					if result.ok:
						result.metadata["changes"] = AssetDiff.compare_assets(asset, edited)
	FileUtils.remove_dir_recursive(stage)
	return result

func _verify_install(staged: String, destination: String) -> OperationResult:
	var reopened := UAssetFile.load_file(staged)
	if reopened == null or not reopened.validate_for_save().is_empty():
		return OperationResult.failed("Staged package failed reopen/validation")
	var files: Array = []
	var removed: Array[String] = []
	for extension in EXTENSIONS:
		var source: String = staged.get_basename() + "." + extension
		var target: String = destination.get_basename() + "." + extension
		if FileAccess.file_exists(source):
			files.append({"source": source, "target": target})
		elif FileAccess.file_exists(target):
			removed.append(target)
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		return OperationResult.failed("Could not create destination directory")
	if FileUtils.install_staged_files(files, removed) != OK:
		return OperationResult.failed("Could not install staged package")
	return OperationResult.succeeded("Package written and reopened", {"path": destination, "files": _package_files(destination)})

func _clone(asset: UAssetFile, request: Dictionary, cfg: ModConfigManager) -> OperationResult:
	var checked := _check_destination(request.output, false)
	if not checked.ok:
		return checked
	var description := ModManifest.describe_unique_clone(request.asset, request.output, cfg)
	if not description.ok:
		return description
	var manifest := str(request.mod).path_join(ModManifest.MANIFEST_FILENAME)
	if FileAccess.file_exists(manifest) and not JSON.parse_string(FileAccess.get_file_as_string(manifest)) is Dictionary:
		return OperationResult.failed("Existing manifest is invalid JSON")
	var temporary := FileUtils.make_temp_dir("sb_cli_clone")
	if not temporary.get("ok", false):
		return OperationResult.failed("Could not create staging directory")
	var stage: String = temporary.path
	var staged := stage.path_join(str(request.output).get_file())
	var source_package := str(description.value.source).get_slice(".", 0)
	var target_package := str(description.value.target).get_slice(".", 0)
	var result: OperationResult
	if asset.is_texture_asset():
		var identities := {source_package: target_package,
			str(request.asset).get_file().get_basename(): str(request.output).get_file().get_basename()}
		var map_path := stage.path_join("identities.json")
		FileUtils.write_bytes_atomic(map_path, JSON.stringify(identities).to_utf8_buffer())
		var script := ToolchainRegistry.dds_tools_script().get_base_dir().path_join("clone_texture.py")
		var output: Array = []
		var code := ProcessUtils.run_python_script(ProcessUtils.find_python(), script, script.get_base_dir(),
			[request.asset, staged, map_path], output)
		result = OperationResult.new(code == 0, ProcessUtils.output_text(output, "Texture clone"))
	else:
		result = asset.save_clone_copy(staged, true, source_package, target_package)
	if result.ok:
		result = _verify_install(staged, request.output)
	if result.ok:
		var recorded := ModManifest.record_unique_clone(description.value, cfg)
		if not recorded.ok:
			for path in _package_files(request.output):
				DirAccess.remove_absolute(path)
			result = recorded
		else:
			result.metadata["manifest"] = recorded.value
	FileUtils.remove_dir_recursive(stage)
	return result

func _media(request: Dictionary, cfg: ModConfigManager) -> OperationResult:
	var group := str(request.group)
	var action := str(request.action)
	if group == "mesh":
		var mesh := MeshService.new().setup(cfg)
		if action == "animations":
			return OperationResult.succeeded("Candidate animations", mesh.find_animation_assets_for_mesh(request.asset))
		if DirAccess.dir_exists_absolute(request.output_dir):
			return OperationResult.failed("Mesh output directory must be new")
		mesh.operation_finished.connect(_receive)
		_completed = null
		mesh.export_glb(request.asset, request.output_dir)
		return await _wait(mesh)
	if action == "export":
		if FileAccess.file_exists(request.output) and not request.get("overwrite", false):
			return OperationResult.failed("Output exists; use --overwrite")
		if FileUtils.same_path(request.asset, request.output):
			return OperationResult.failed("Media output must differ from the asset")
		if str(request.output).get_extension().to_lower() != ("png" if group == "texture" else "ogg"):
			return OperationResult.failed("Use a .png or .ogg output matching the media command")
		DirAccess.make_dir_recursive_absolute(str(request.output).get_base_dir())
		_completed = null
		if group == "texture":
			# The GUI repairs missing companions during export. Do that on a copy
			# so a read-only CLI export never modifies an extracted source.
			var export_temporary := FileUtils.make_temp_dir("sb_cli_texture_export")
			if not export_temporary.get("ok", false):
				return OperationResult.failed("Could not stage texture export")
			var export_stage: String = export_temporary.path
			var export_staged := export_stage.path_join(str(request.asset).get_file())
			for path in _package_files(request.asset):
				if FileUtils.copy_file(path, export_stage.path_join(str(path).get_file())) != OK:
					FileUtils.remove_dir_recursive(export_stage)
					return OperationResult.failed("Could not copy texture package")
			var export_service := TextureService.new().setup(cfg)
			export_service.operation_finished.connect(_receive)
			export_service.export_png(export_staged, request.output)
			var export_result := await _wait(export_service)
			FileUtils.remove_dir_recursive(export_stage)
			return export_result
		var service := SoundService.new().setup(cfg)
		service.operation_finished.connect(_receive)
		service.export_ogg(request.asset, request.output)
		return await _wait(service)
	if not FileAccess.file_exists(str(request.media)):
		return OperationResult.failed("Media input does not exist")
	var destination := str(request.output_dir).path_join(str(request.asset).get_file())
	var checked := _check_destination(destination, request.get("overwrite", false))
	if not checked.ok:
		return checked
	var temporary := FileUtils.make_temp_dir("sb_cli_media")
	if not temporary.get("ok", false):
		return OperationResult.failed("Could not create media staging directory")
	var stage: String = temporary.path
	var staged := stage.path_join(str(request.asset).get_file())
	for path in _package_files(request.asset):
		if FileUtils.copy_file(path, stage.path_join(str(path).get_file())) != OK:
			FileUtils.remove_dir_recursive(stage)
			return OperationResult.failed("Could not stage media package")
	_completed = null
	var result: OperationResult
	if group == "texture":
		var service := TextureService.new().setup(cfg)
		service.operation_finished.connect(_receive)
		service.inject_png(staged, request.media, stage)
		result = await _wait(service)
		if result.ok:
			var preview := service.get_preview_result(staged)
			if not preview.ok:
				result = OperationResult.failed("Injected texture could not be decoded: " + preview.message)
	else:
		var service := SoundService.new().setup(cfg)
		service.operation_finished.connect(_receive)
		service.inject_ogg(staged, request.media)
		result = await _wait(service)
		if result.ok and service.get_audio_data(staged) != FileAccess.get_file_as_bytes(request.media):
			result = OperationResult.failed("Injected audio payload did not match input")
	if result.ok:
		result = _verify_install(staged, destination)
	FileUtils.remove_dir_recursive(stage)
	return result

# Godot's JSON parser stores numbers as doubles. Refuse a lossy document rather
# than silently changing unrelated int64 fields. Python batch recipes retain them.
func _check_json_precision(path: String) -> OperationResult:
	if not FileAccess.file_exists(path):
		return OperationResult.failed("Input does not exist: " + path)
	var content: String
	if path.get_extension().to_lower() == "uasset":
		var output: Array = []
		var code := OS.execute(ProcessUtils.find_dotnet(),
			[ToolchainRegistry.converter_dll(), "read", path], output, true)
		if code != 0:
			return OperationResult.failed(ProcessUtils.output_text(output, "Converter failed"))
		content = str(output[0]) if not output.is_empty() else ""
	else:
		content = FileAccess.get_file_as_string(path)
	var precision := json_precision_error(content)
	if not precision.is_empty():
		return OperationResult.failed(precision)
	var json := JSON.new()
	if json.parse(content) != OK or not json.data is Dictionary or not json.data.get("Exports") is Array:
		return OperationResult.failed("Input must be a UAssetAPI JSON object with Exports")
	return OperationResult.succeeded()

static func json_precision_error(content: String) -> String:
	# Match JSON strings first so digits inside names/raw binary strings are skipped.
	var tokens := RegEx.create_from_string('"(?:[^"\\\\]|\\\\.)*"|(-?[0-9]+)(?:[.][0-9]+|[eE][+-]?[0-9]+)?')
	for token in tokens.search_all(content):
		var number: String = token.get_string(1)
		if number.is_empty() or token.get_string() != number:
			continue
		var digits := number.trim_prefix("-")
		if digits.length() > 16 or (digits.length() == 16 and digits > "9007199254740992"):
			return "JSON has integers outside exact Godot precision. Use workflow batch recipes to preserve int64 fields."
	return ""
