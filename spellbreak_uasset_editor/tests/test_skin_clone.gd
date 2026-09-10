extends SceneTree

var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _init() -> void:
	var bp := "/Game/Blueprints/Cosmetics/Skins/BP_Cosmetic_Skin_Test"
	var data := "/Game/Data/Skins/Test"
	var mesh := "/Game/Characters/Outfit"
	var material := "/Game/Characters/Outfit_ChrMI"
	var colour := "/Game/Characters/Outfit_ChrTBC"
	var normal := "/Game/Characters/Outfit_ChrTN"
	var graph := {bp: [data], data: [mesh], mesh: [material], material: [colour, normal],
		colour: [], normal: []}
	var keep := SkinCloneService.retained_packages(graph, bp)
	check(keep.size() == 5 and not keep.has(normal), "Retain ancestors of colour art, share normals")
	check(SkinCloneService.is_optional_icon("/Game/UI/Textures/assets/cosmetics/skins/fullbody/Missing"), "Missing UI icons are optional")
	check(not SkinCloneService.is_optional_icon(data), "Skin data remains required")
	check(SkinCloneService.is_colour_map(colour + "_1"), "Numbered colour maps are retained")
	check(not SkinCloneService.is_colour_map(normal + "_1"), "Numbered normals remain shared")
	var numbered := UAssetFile._from_dict({"NameMap": [colour], "Imports": [
		{"ObjectName": colour + "_1", "ClassName": "Package"}], "Exports": []}, "")
	check(SkinCloneService.package_refs(numbered, data) == [colour + "_1"], "Follow resolved numbered package references, not NameMap bases")
	var names := {"Outfit": "NewOutfit", mesh: "/Game/Characters/NewOutfit"}
	var input := {"$type": "Outfit", "nested": ["Outfit", mesh, mesh + "Extra"],
		"text": {"$type": "UAssetAPI.TextPropertyData", "Name": "DisplayName",
		"Key": "donor", "Namespace": "donor", "SourceString": "Donor"}}
	var rewritten: Dictionary = SkinCloneService.rewrite(input, names, "NewSkin", "New Skin")
	check(rewritten["$type"] == "Outfit", "Serializer types are preserved")
	check(rewritten.nested == ["NewOutfit", "/Game/Characters/NewOutfit", mesh + "Extra"], "Only exact identities change")
	check(rewritten.text.Key == "NewSkin_DisplayName" and rewritten.text.SourceString == "New Skin", "Clone text has independent identity and display name")
	check(SkinCloneService.clone_leaf("ArcaneTrickster_SKIN_ChrTBC_1", "Arcane_Trickster", "Twdoor") == "Twdoor_SKIN_ChrTBC_1", "Readable texture name preserves numbered suffix")
	check(SkinCloneService.raw_skin_package("Twdoor", "Twdoor") == "/Game/Data/Skins/Twdoor/Twdoor", "Raw skin data stays in the game scan path")
	check(SkinCloneService.clone_leaf("Outfit", "Hollow", "Twdoor") == "Twdoor_Outfit", "Unrelated donor names receive a skin prefix")
	check(SkinCloneService.blueprint_destination("/mods/Test", "BP_Cosmetic_Skin_Twdoor") == "/mods/Test/g3/Content/Blueprints/Cosmetics/Skins/Twdoor/BP_Cosmetic_Skin_Twdoor.uasset", "Skin blueprint is grouped under its own folder")
	_test_upgradeable_skin_validation()
	_test_manifest_batch()
	_test_real_skin_if_configured()
	for failure in failures:
		printerr("FAIL: " + failure)
	if failures.is_empty():
		print("PASS: skin clone regression tests")
	quit(0 if failures.is_empty() else 1)

func _test_manifest_batch() -> void:
	var temp := FileUtils.make_temp_dir("skin_manifest_test")
	check(temp.get("ok", false), "Create manifest test workspace")
	if not temp.get("ok", false):
		return
	var root: String = temp.path
	var mod := ModInfo.new("Test", root)
	mod.path = root
	mod.name = "Test"
	var cfg := ModConfigManager.new()
	DirAccess.make_dir_recursive_absolute(root + "/g3/Content")
	FileUtils.write_bytes_atomic(root + "/g3/Content/One.uasset", PackedByteArray([1]))
	FileUtils.write_bytes_atomic(root + "/g3/Content/Two.uasset", PackedByteArray([2]))
	var first := {"mod": mod, "file": "g3/Content/One.uasset", "source": "/Game/A.A", "target": "/Game/One.One"}
	var second := {"mod": mod, "file": "g3/Content/Two.uasset", "source": "/Game/B.B", "target": "/Game/Two.Two"}
	check(ModManifest.record_unique_clones([first, second], cfg).ok, "Commit two declarations")
	var path := ModManifest.manifest_path(mod)
	var before := FileAccess.get_file_as_bytes(path)
	var manifest: Dictionary = JSON.parse_string(before.get_string_from_utf8())
	check(manifest.custom_assets.size() == 2, "Both declarations survive metadata refresh")
	check(not ModManifest.record_unique_clones([first, {"mod": mod}], cfg).ok, "Reject incomplete batch")
	check(FileAccess.get_file_as_bytes(path) == before, "Failed batch preserves manifest bytes")
	FileUtils.remove_dir_recursive(root)

## Optional integration fixture: an extracted game source, never modified.
func _test_real_skin_if_configured() -> void:
	var source := OS.get_environment("SPELLBREAK_SKIN_TEST_SOURCE")
	if source.is_empty():
		return
	var temp := FileUtils.make_temp_dir("skin_real_test")
	check(temp.get("ok", false), "Create real skin test workspace")
	if not temp.get("ok", false):
		return
	var root: String = temp.path
	var mod_root := root + "/mods/Test"
	DirAccess.make_dir_recursive_absolute(mod_root + "/g3/Content")
	var cfg := ModConfigManager.new()
	cfg.mods_dir = root + "/mods"
	cfg.sources = [{"name": "Fixture", "path": source}]
	var skin := OS.get_environment("SPELLBREAK_SKIN_TEST_NAME")
	if skin.is_empty():
		skin = "Hollow"
	var bp := "g3/Content/Blueprints/Cosmetics/Skins/BP_Cosmetic_Skin_" + skin + ".uasset"
	var destination := SkinCloneService.blueprint_destination(mod_root, "BP_Cosmetic_Skin_KitTest")
	var service := SkinCloneService.new()
	var result := service._build(source.path_join(bp), source, destination, cfg, "Kit Test")
	check(result.ok, "Real skin clone: " + result.message)
	if result.ok:
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			mod_root.path_join(ModManifest.MANIFEST_FILENAME)))
		if skin == "Arcane_Trickster":
			check(result.metadata.get("missing_optional_icons", []).size() == 1, "Report the absent Arcane Trickster fullbody icon")
		var old_packages: Array[String] = []
		for declaration: Dictionary in manifest.custom_assets:
			old_packages.append(str(declaration.source).get_slice(".", 0))
		for declaration: Dictionary in manifest.custom_assets:
			var path := mod_root.path_join(declaration.file)
			if str(declaration.source).begins_with("/Game/Data/Skins/"):
				check(str(declaration.target).begins_with("/Game/Data/Skins/KitTest/"), "Raw skin data remains discoverable")
			else:
				check(FileUtils.is_path_within(path, destination.get_base_dir()), "Artwork and blueprint stay grouped")
			check(str(declaration.get("reference_group", "")) == "/Game/Blueprints/Cosmetics/Skins/KitTest", "Both locations share the skin reference group")
			var clone := UAssetFile.load_file(path)
			check(clone != null, "Reload " + path.get_file())
			if clone == null:
				continue
			for old in old_packages:
				check(not old in clone.name_map, "No stale reference to " + old)
			if clone.is_texture_asset():
				check(clone.exports[0].object_name == path.get_file().get_basename(), "Texture export identity matches its cloned package")
				var original := source.path_join("g3/Content/" + str(declaration.source).get_slice(".", 0).trim_prefix("/Game/") + ".uasset")
				for ext in ["ubulk"]:
					check(FileAccess.get_file_as_bytes(original.get_basename() + "." + ext) == FileAccess.get_file_as_bytes(path.get_basename() + "." + ext), "Texture payload preserved")
		var registry := source.path_join("g3/AssetRegistry.bin")
		if FileAccess.file_exists(registry):
			var patcher := ToolchainRegistry.asset_registry_script()
			var registry_output: Array = []
			var code := ProcessUtils.run_python_script(ProcessUtils.find_python(), patcher,
				patcher.get_base_dir(), [registry, root.path_join("AssetRegistry.bin"),
				"--operations", mod_root.path_join(ModManifest.MANIFEST_FILENAME)], registry_output)
			check(code == 0, "Register relocated skin packages: " + ProcessUtils.output_text(registry_output, ""))
		var before := FileAccess.get_sha256(destination)
		check(not service._build(source.path_join(bp), source, destination, cfg).ok, "Reject existing skin destination")
		check(FileAccess.get_sha256(destination) == before, "Collision leaves existing skin intact")
	FileUtils.remove_dir_recursive(root)

func _test_upgradeable_skin_validation() -> void:
	var raw := {"NameMap": ["GCosmeticSkin", "Skin"],
		"Imports": [{"ObjectName": "GCosmeticSkin", "ClassName": "Class"}],
		"Exports": [{"ObjectName": "Skin", "ClassIndex": -1, "Data": [
			{"$type": "UAssetAPI.PropertyTypes.Objects.EnumPropertyData, UAssetAPI",
			"Name": "Rarity", "EnumType": "EXRarity", "Value": "EXRarity::Upgradeable"}]}]}
	for rarity in ["EXRarity::Upgradeable", "EXRarity::Epic"]:
		raw.Exports[0].Data[0].Value = rarity
		var asset := UAssetFile._from_dict(raw.duplicate(true), "")
		check(asset.validate_for_save().is_empty(), "Allow %s without upgrade-set metadata" % rarity)
		check(asset.exports[0].properties[0].value == rarity, "Preserve selected rarity")
	raw.Exports[0].ClassIndex = -2
	check(not UAssetFile._from_dict(raw, "").validate_for_save().is_empty(), "Rarity support retains package index validation")
