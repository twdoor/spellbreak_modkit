extends SceneTree

var failures: Array[String] = []

const FIXTURES := {
	"Title": "Audience_Adoration", "Badge": "Adept", "Card": "Armory_Of_Ancients",
	"Emote": "Aerobics", "Triumph": "Are_You_Chicken", "Artifact": "Ancestors_Blade",
	"Cloudburst": "Accursed_Fall", "Afterglow": "Abyssal_Escape",
}

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("FAIL: " + message)

func _initialize() -> void:
	call_deferred("_run")

func sample(class_name_text: String, references: Array = []) -> UAssetFile:
	var imports: Array = [{"ObjectName": class_name_text, "ClassName": "Class"}]
	for reference: String in references:
		imports.append({"ObjectName": reference, "ClassName": "Package"})
	return UAssetFile._from_dict({"NameMap": [], "Imports": imports,
		"Exports": [{"ObjectName": "Example", "ClassIndex": -1, "Data": []}]}, "")

func _run() -> void:
	for kind: String in CosmeticCloneService.TYPES:
		var name := "BP_Cosmetic_" + kind + "_KitTest"
		var destination := CosmeticCloneService.blueprint_destination("/mods/Test", name)
		check(CosmeticCloneService.cosmetic_type(destination) == kind, "Recognize " + kind)
		check(destination.contains("/" + str(CosmeticCloneService.TYPES[kind].folder) + "/KitTest/"), "Preserve category scan folder: " + kind)
	check(not CosmeticCloneService.is_cosmetic("/Game/Blueprints/Cosmetics/Artifacts/BP_Cosmetic_Artifact_Test_Asset.uasset"), "Do not select a raw artifact actor as a cosmetic descriptor")
	check(not CosmeticCloneService.is_cosmetic("/Game/Blueprints/Cosmetics/Titles/BP_Cosmetic_Skin_Test.uasset"), "Reject type/folder mismatch")
	var montage := "/Game/Characters/Human/Animations/Cosmetics/Test_Montage"
	var sequence := "/Game/Characters/Human/Animations/Cosmetics/Test"
	var skeleton := "/Game/Characters/Human/Human_Female_Skeleton"
	var icon := "/Game/UI/Textures/assets/cosmetics/emote/Test_UIT"
	var bp := "/Game/Blueprints/Cosmetics/Emotes/BP_Cosmetic_Emote_Test"
	var assets := {bp: sample("GCosmeticEmote", [montage, icon]),
		montage: sample("AnimMontage", [sequence, skeleton]), sequence: sample("AnimSequence"),
		skeleton: sample("Skeleton"), icon: sample("Texture2D")}
	var graph := {bp: [montage, icon], montage: [sequence, skeleton], sequence: [], skeleton: [], icon: []}
	var retained := CosmeticCloneService.retained_packages(graph, bp, assets, "Emote")
	check(retained.size() == 3 and retained.has(montage) and retained.has(icon), "Clone montages and icons, share sequences and skeletons")
	check(CosmeticCloneService.package_refs(assets[bp], bp, "Emote") == [montage, icon], "Follow emote art and animation references")
	check(CosmeticCloneService.package_refs(assets[sequence], sequence, "Emote").is_empty(), "Stop traversal at shared animation sequences")
	check(CosmeticCloneService.editable_dependency(sample("ParticleSystem"), "/Game/VFX/Test"), "Particle effects are editable clone dependencies")
	check(not CosmeticCloneService.editable_dependency(sample("Material"), "/Game/VFX/BaseMaterial"), "Base shaders remain shared")
	var text := {"$type": "UAssetAPI.PropertyTypes.Objects.TextPropertyData, UAssetAPI", "Name": "TitleDisplayText",
		"Value": "OriginalKey", "Namespace": "Original", "HistoryType": "Base", "CultureInvariantString": "Original title"}
	var rewritten: Dictionary = CosmeticCloneService.rewrite(text, {}, "BP_Cosmetic_Title_KitTest", "Kit Title")
	check(rewritten.Value == "BP_Cosmetic_Title_KitTest_TitleDisplayText", "Rewrite the actual converter localization key")
	check(rewritten.CultureInvariantString == "Kit Title", "Apply title display text")
	check(not rewritten.has("Key") and not rewritten.has("SourceString"), "Do not add unused text fields")
	_test_real_if_configured()
	if failures.is_empty():
		print("PASS: cosmetic clone regression tests")
	quit(0 if failures.is_empty() else 1)

func _test_real_if_configured() -> void:
	var source := OS.get_environment("SPELLBREAK_COSMETIC_TEST_SOURCE")
	if source.is_empty():
		return
	var selected := OS.get_environment("SPELLBREAK_COSMETIC_TEST_TYPE")
	var temp := FileUtils.make_temp_dir("cosmetic_real_test")
	check(temp.get("ok", false), "Create fixture workspace")
	if not temp.get("ok", false):
		return
	var root: String = temp.path
	var mod_root := root + "/mods/Test"
	DirAccess.make_dir_recursive_absolute(mod_root + "/g3/Content")
	var cfg := ModConfigManager.new()
	cfg.mods_dir = root + "/mods"
	cfg.sources = [{"name": "Fixture", "path": source}]
	for kind: String in FIXTURES:
		if not selected.is_empty() and selected != kind:
			continue
		var donor := "BP_Cosmetic_" + kind + "_" + str(FIXTURES[kind])
		var relative := "g3/Content/Blueprints/Cosmetics/" + str(CosmeticCloneService.TYPES[kind].folder) + "/" + donor + ".uasset"
		var clone_name := "BP_Cosmetic_" + kind + "_KitTest"
		var destination := CosmeticCloneService.blueprint_destination(mod_root, clone_name)
		var service := CosmeticCloneService.new()
		var result := service._build(source.path_join(relative), source, destination, cfg, "Kit " + kind)
		check(result.ok, kind + " clone: " + result.message)
		if not result.ok:
			continue
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(mod_root.path_join(ModManifest.MANIFEST_FILENAME)))
		var clone := UAssetFile.load_file(destination)
		check(clone != null, "Reload cosmetic " + kind)
		if clone != null:
			for exported in clone.exports:
				for property in exported.properties:
					if property.prop_name in ["DisplayName", "TitleDisplayText"]:
						var data := property.to_dict()
						check(str(data.get("CultureInvariantString", "")) == "Kit " + kind, "Round-trip display text: " + kind)
						check(str(data.get("Value", "")).begins_with(clone_name), "Independent text key: " + kind)
		var animation_found := false
		for entry: Dictionary in manifest.custom_assets:
			if str(entry.reference_group) != "/Game/Blueprints/Cosmetics/" + str(CosmeticCloneService.TYPES[kind].folder) + "/KitTest":
				continue
			if str(entry.source).contains("_Montage"):
				animation_found = true
				check(str(entry.target).begins_with(CosmeticCloneService.ANIMATION_ROOT), "Montage stays discoverable")
			var path := mod_root.path_join(entry.file)
			check(FileAccess.file_exists(path), "Manifest asset exists")
			var original := source.path_join("g3/Content/" + str(entry.source).get_slice(".", 0).trim_prefix("/Game/") + ".uasset")
			if FileAccess.file_exists(original.get_basename() + ".ubulk"):
				check(FileAccess.get_file_as_bytes(original.get_basename() + ".ubulk") == FileAccess.get_file_as_bytes(path.get_basename() + ".ubulk"), "Preserve bulk payload")
		if kind in ["Emote", "Triumph"]:
			check(animation_found, kind + " includes animation montages")
		var hash_before := FileAccess.get_sha256(destination)
		check(not service._build(source.path_join(relative), source, destination, cfg).ok, "Reject clone collision")
		check(FileAccess.get_sha256(destination) == hash_before, "Collision preserves clone")
		print("REAL FIXTURE: ", kind, " — ", result.message)
	if FileAccess.file_exists(mod_root.path_join(ModManifest.MANIFEST_FILENAME)):
		var output: Array = []
		var patcher := ToolchainRegistry.asset_registry_script()
		var code := ProcessUtils.run_python_script(ProcessUtils.find_python(), patcher, patcher.get_base_dir(),
			[source.path_join("g3/AssetRegistry.bin"), root.path_join("AssetRegistry.bin"),
			"--operations", mod_root.path_join(ModManifest.MANIFEST_FILENAME)], output)
		check(code == 0, "Register all cloned cosmetic packages: " + ProcessUtils.output_text(output))
	FileUtils.remove_dir_recursive(root)
