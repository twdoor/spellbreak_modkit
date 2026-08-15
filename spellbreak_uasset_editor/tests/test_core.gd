extends SceneTree

const AppSettingsRuntime = preload(
	"res://addons/app_settings/app_settings_runtime.gd"
)
const SemanticVersion = preload(
	"res://addons/version_manager/semantic_version.gd"
)
const PrepareReleaseDialog = preload(
	"res://addons/version_manager/prepare_release_dialog.gd"
)
const VersionManagerRuntime = preload(
	"res://addons/version_manager/version_manager_runtime.gd"
)
const AppimagePluginScript = preload(
	"res://addons/appimage_export/appimage_export_plugin.gd"
)

var _failures: Array[String] = []


class WatcherTestPacker:
	extends PackingService

	var pack_calls := 0
	var last_mods: Array = []
	var busy := false

	func pack(enabled_mods: Array) -> void:
		pack_calls += 1
		last_mods = enabled_mods.duplicate(true)

	func is_packing() -> bool:
		return busy


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("PASS: core regression tests")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAIL: " + failure)
		quit(1)


func _run() -> void:
	_test_export_insert()
	_test_export_remove()
	_test_import_insert_remove()
	_test_swap_and_snapshot_restore()
	_test_asset_document_history()
	_test_clipboard_rejects_unsupported_copy()
	_test_clipboard_datatable_row_targets_current_table()
	_test_clipboard_datatable_row_pastes_into_empty_table()
	_test_clipboard_export_cross_file_remaps_imports()
	_test_clipboard_export_group_preserves_internal_refs()
	_test_property_state_restore()
	_test_byte_enum_property_round_trip()
	_test_asset_diff_engine()
	_test_asset_diff_tab_layout()
	_test_linear_color_property_editor()
	_test_vector_property_editor()
	_test_particle_effect_detail_builds_module_stack()
	_test_mesh_preview_materials()
	_test_glb_export()
	_test_md5_animation_loader()
	_test_animation_candidate_discovery()
	_test_mesh_preview_environment()
	_test_mesh_animation_controls_build()
	_test_texture_injection_preserves_companions()
	_test_texture_companion_recovery()
	_test_background_job_shutdown()
	_test_file_watcher_rapid_toggle()
	_test_file_watcher_detects_same_size_save()
	_test_file_watcher_deferred_pack_starts_packer()
	_test_atomic_file_install()
	_test_mod_discovery_models_and_symlinks()
	_test_mod_manifest()
	_test_mod_preflight()
	_test_clone_helpers()
	_test_asset_reuse_copy()
	_test_name_map_fname_sync()
	_test_fname_split_base()
	_test_dummy_fname_save_heuristics()
	_test_uasset_save_validation()
	_test_path_safety()
	_test_process_arguments()
	_test_update_version_compare()
	_test_self_update_metadata()
	_test_release_manager_project_layout()
	_test_appimage_desktop_mime_metadata()
	_test_mod_config_settings_persistence()
	_test_file_association_metadata()
	_test_native_keymap_configuration()
	_test_base_file_explorer_search()
	_test_explorer_add_to_mod_path()
	_test_source_package_companion_discovery()
	_test_base_source_generation()
	_test_packing_transaction()


func _test_export_insert() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	var first_import := asset.imports[0]
	var added := [
		_make_export("AddedA", 2, -2, 3, [2, 3, -2], 3),
		_make_export("AddedB", 2, -2, 3, [2, 3, -2], 3),
	]
	asset.insert_exports(1, added)

	_expect(asset.exports.size() == 5, "bulk export insert changes table size")
	_expect(first.outer_index == 4, "existing export positive metadata shifts by insert count")
	_expect(first.class_index == -2, "export insert leaves import references unchanged")
	_expect(_object_value(first) == 5, "existing ObjectProperty reference shifts")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [4, 5, -2],
		"existing dependency references shift")
	_expect(added[0].outer_index == 4 and _object_value(added[0]) == 5,
		"new exports are remapped from the pre-insert coordinate system")
	_expect(first_import.outer_index == 4, "import outer export reference shifts")


func _test_export_remove() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	asset.imports[0].outer_index = 3
	asset.imports[0].raw["OuterIndex"] = 3
	asset.remove_export_at(1)

	_expect(asset.exports.size() == 2, "export removal changes table size")
	_expect(first.outer_index == 0, "references to a deleted export are cleared")
	_expect(_object_value(first) == 2, "references after a deleted export shift down")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [2, -2],
		"deleted dependencies are removed and later dependencies shift")
	_expect(asset.imports[0].outer_index == 2, "import outer reference shifts after export removal")


func _test_import_insert_remove() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	var added := [
		_make_import("AddedA", -2),
		_make_import("AddedB", -3),
	]
	asset.insert_imports(1, added)

	_expect(first.class_index == -4, "existing import reference shifts by bulk insert count")
	_expect(added[0].outer_index == -4, "new import references use pre-insert coordinates")
	_expect(asset.imports[1].super_index == -2 and asset.imports[2].super_index == -3,
		"display indices are synchronized after import insertion")

	asset = _make_asset()
	first = asset.exports[0]
	first.class_index = -2
	first.template_index = -3
	first.raw["ClassIndex"] = -2
	first.raw["TemplateIndex"] = -3
	first.properties[0].value = -2
	first.properties[0].raw["Value"] = -2
	first.raw["CreateBeforeCreateDependencies"] = [-2, -3, 1]
	asset.remove_import_at(1)

	_expect(first.class_index == 0 and _object_value(first) == 0,
		"references to a deleted import are cleared")
	_expect(first.template_index == -2, "later import references shift toward zero")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [-2, 1],
		"import dependency references are remapped")


func _test_update_version_compare() -> void:
	_expect(SemanticVersion.compare("v0.10.0", "0.9.0") > 0,
		"version manager treats 0.10.0 as newer than 0.9.0")
	_expect(SemanticVersion.compare("v0.9.0", "0.9.0") == 0,
		"version manager treats v-prefixed and plain versions equally")
	_expect(SemanticVersion.compare("0.9.0-beta.2", "0.9.0") < 0,
		"version manager orders prereleases before stable versions")
	_expect(not bool(SemanticVersion.parse("release-1.0.0").valid),
		"version manager rejects release tags that are not semantic versions")
	_expect(VersionManagerRuntime._release_version({"tag_name": "0.11"}) == "0.11.0",
		"version manager supports the repository's historical two-part release tags")
	_expect(VersionManagerRuntime._uses_prerelease_channel("0.12.0-beta.1", false),
		"prerelease builds automatically remain on the prerelease update channel")
	_expect(not VersionManagerRuntime._uses_prerelease_channel("0.12.0", false),
		"stable builds do not opt into prerelease updates by default")


func _test_self_update_metadata() -> void:
	var assets := [
		{"name": "sbue.AppImage", "browser_download_url": "https://github.com/appimage"},
		{"name": "sbue.x86_64", "browser_download_url": "https://github.com/raw-linux"},
		{"name": "sbue.exe", "browser_download_url": "https://github.com/windows-exe"},
		{"name": "linux.zip", "browser_download_url": "https://github.com/linux"},
		{"name": "win.zip", "browser_download_url": "https://github.com/win"},
		{"name": "SHA256SUMS", "browser_download_url": "https://github.com/checksums"},
	]
	_expect(str(VersionManagerRuntime._select_release_asset(
		assets, "Linux", "x86_64", "sbue.AppImage").get("name", "")) == "sbue.AppImage",
		"self updater selects a direct AppImage for AppImage installations")
	_expect(str(VersionManagerRuntime._select_release_asset(
		assets, "Linux", "x86_64", "sbue.x86_64").get("name", "")) == "sbue.x86_64",
		"self updater selects a direct executable for raw Linux installations")
	_expect(str(VersionManagerRuntime._select_release_asset(
		assets, "Windows", "x86_64").get("name", "")) == "sbue.exe",
		"self updater selects the direct Windows executable")
	_expect(str(VersionManagerRuntime._select_checksum_asset(
		assets).get("name", "")) == "SHA256SUMS",
		"self updater locates the release checksum asset")
	var legacy_assets := [
		{"name": "linux.zip", "browser_download_url": "https://github.com/linux"},
		{"name": "win.zip", "browser_download_url": "https://github.com/win"},
	]
	_expect(str(VersionManagerRuntime._select_release_asset(
		legacy_assets, "Linux", "x86_64").get("name", "")) == "linux.zip",
		"self updater retains compatibility with Linux ZIP releases")
	_expect(VersionManagerRuntime._select_release_asset(assets, "macOS").is_empty(),
		"self updater rejects platforms without a published build")
	_expect(VersionManagerRuntime._select_release_asset(
		assets, "Linux", "arm64").is_empty(),
		"self updater rejects architectures without a published build")

	var linux_files := PackedStringArray(["linux/", "linux/sbue.sh", "linux/sbue.x86_64"])
	var windows_files := PackedStringArray(["win/", "win/sbue.exe"])
	_expect(VersionManagerRuntime._select_executable_entry(
		linux_files, "Linux", "renamed.x86_64") == "linux/sbue.x86_64",
		"self updater locates the sole Linux executable in the release archive")
	_expect(VersionManagerRuntime._select_executable_entry(
		windows_files, "Windows", "sbue.exe") == "win/sbue.exe",
		"self updater locates the Windows executable in the release archive")
	_expect("BackupPath" in VersionManagerRuntime._installer_script("Windows")
		and "chmod +x" in VersionManagerRuntime._installer_script("Linux"),
		"self updater generates backup-aware platform installer scripts")

	var root := OS.get_temp_dir().path_join(
		"sb_test_self_update_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var archive_path := root.path_join("linux.zip")
	var packer := ZIPPacker.new()
	var pack_error := packer.open(archive_path)
	if pack_error == OK:
		packer.start_file("linux/sbue.x86_64")
		packer.write_file("new executable".to_utf8_buffer())
		packer.close_file()
		packer.close()
	_expect(pack_error == OK, "self updater test creates a release archive")
	var archive_file := FileAccess.open(archive_path, FileAccess.READ)
	var archive_size := archive_file.get_length() if archive_file != null else 0
	if archive_file != null:
		archive_file.close()
	var runtime := VersionManagerRuntime.new()
	var archive_asset := {
		"size": archive_size,
		"digest": "sha256:" + FileAccess.get_sha256(archive_path),
	}
	_expect(runtime._verify_download(archive_path, archive_asset).is_empty(),
		"self updater verifies release size and SHA-256 digest")
	var checksum_text := "%s  linux/linux.zip\n" % FileAccess.get_sha256(archive_path)
	var checksum_asset := {"name": "linux.zip", "size": archive_size}
	_expect(runtime._verify_download(
		archive_path, checksum_asset, checksum_text).is_empty(),
		"self updater verifies releases through SHA256SUMS when API digests are absent")
	var staged_path := root.path_join("staged-sbue.x86_64")
	var extracted: Dictionary = runtime._extract_update_executable(
		archive_path, staged_path, "sbue.x86_64", "Linux")
	_expect(bool(extracted.get("success", false))
		and FileAccess.get_file_as_string(staged_path) == "new executable",
		"self updater extracts the verified platform executable into staging")
	var appimage_path := root.path_join("sbue.AppImage")
	var appimage_file := FileAccess.open(appimage_path, FileAccess.WRITE)
	if appimage_file != null:
		appimage_file.store_string("direct appimage")
		appimage_file.close()
	var staged_appimage := root.path_join("staged-sbue.AppImage")
	var staged_direct: Dictionary = runtime._stage_update_asset(
		appimage_path, staged_appimage, "sbue.AppImage", "sbue.AppImage", "Linux")
	_expect(bool(staged_direct.get("success", false))
		and FileAccess.get_file_as_string(staged_appimage) == "direct appimage",
		"self updater stages a direct AppImage without requiring a ZIP archive")
	if OS.get_name() == "Linux":
		var previous_appimage := OS.get_environment("APPIMAGE")
		OS.set_environment("APPIMAGE", appimage_path)
		_expect(runtime._update_target_path() == appimage_path,
			"self updater targets the outer AppImage instead of its mounted executable")
		OS.set_environment("APPIMAGE", previous_appimage)

		var install_script_path := root.path_join("install-update.sh")
		var install_script := FileAccess.open(install_script_path, FileAccess.WRITE)
		if install_script != null:
			install_script.store_string(VersionManagerRuntime._installer_script("Linux"))
			install_script.close()
		var install_target := root.path_join("installed.AppImage")
		var install_staged := root.path_join("next.AppImage")
		var old_file := FileAccess.open(install_target, FileAccess.WRITE)
		if old_file != null:
			old_file.store_string("old executable")
			old_file.close()
		var next_file := FileAccess.open(install_staged, FileAccess.WRITE)
		if next_file != null:
			next_file.store_string("#!/bin/sh\nexit 0\n")
			next_file.close()
		var install_output: Array = []
		var install_exit := OS.execute("/bin/sh", PackedStringArray([
			install_script_path,
			install_target,
			install_staged,
			install_target + ".previous",
			"999999999",
		]), install_output, true)
		_expect(install_exit == 0
			and FileAccess.get_file_as_string(install_target).begins_with("#!/bin/sh")
			and FileAccess.get_file_as_string(
				install_target + ".previous") == "old executable",
			"self updater helper backs up, replaces, and launches a Linux executable")
	runtime.free()
	FileUtils.remove_dir_recursive(root)


func _test_release_manager_project_layout() -> void:
	var release_dialog := PrepareReleaseDialog.new()
	_expect(release_dialog._changelog_path() == "res://../CHANGELOG.md"
		and FileAccess.file_exists(release_dialog._changelog_path()),
		"release manager targets the repository changelog")
	var task_plan: Dictionary = release_dialog._plan_release_tasks(
		"res://../dist/9.9.9",
		[{
			"name": "Linux",
			"platform": "Linux",
			"architecture": "x86_64",
			"generates_appimage": true,
			"existing_path": "",
		}]
	)
	var tasks: Array = task_plan.get("tasks", [])
	_expect(bool(task_plan.get("success", false)) and tasks.size() == 1
		and str(tasks[0].output_path).ends_with("/dist/9.9.9/linux/sbue.x86_64"),
		"release manager preserves the existing sbue build layout")
	var additional_outputs: PackedStringArray = tasks[0].get(
		"additional_outputs", PackedStringArray()) if not tasks.is_empty() \
		else PackedStringArray()
	_expect(additional_outputs.size() == 1
		and additional_outputs[0].ends_with("/dist/9.9.9/linux/sbue.AppImage"),
		"release manager requires the AppImage generated by the Linux preset")
	var checksum_root := OS.get_temp_dir().path_join(
		"sb_test_release_checksums_%d" % Time.get_ticks_usec())
	var checksum_linux_dir := checksum_root.path_join("linux")
	DirAccess.make_dir_recursive_absolute(checksum_linux_dir)
	var raw_path := checksum_linux_dir.path_join("sbue.x86_64")
	var appimage_path := checksum_linux_dir.path_join("sbue.AppImage")
	for file_data: Array in [[raw_path, "raw"], [appimage_path, "appimage"]]:
		var artifact := FileAccess.open(str(file_data[0]), FileAccess.WRITE)
		if artifact != null:
			artifact.store_string(str(file_data[1]))
			artifact.close()
	var checksum_error := release_dialog._write_release_checksums(
		[{
			"output_path": raw_path,
			"additional_outputs": PackedStringArray([appimage_path]),
		}],
		checksum_root
	)
	var checksums := FileAccess.get_file_as_string(
		checksum_root.path_join("SHA256SUMS"))
	_expect(checksum_error.is_empty()
		and "linux/sbue.x86_64" in checksums
		and "linux/sbue.AppImage" in checksums,
		"release manager writes checksums for direct update artifacts")
	FileUtils.remove_dir_recursive(checksum_root)
	release_dialog.free()


func _test_appimage_desktop_mime_metadata() -> void:
	var desktop_entry := AppimagePluginScript.desktop_entry(
		"sbue",
		"Spellbreak Modkit",
		"Edit Unreal assets",
		"sbue.x86_64",
		"application/x-unreal-uasset; application/x-extra",
		"%F"
	)
	_expect("Exec=\"sbue.x86_64\" %F" in desktop_entry
		and "MimeType=application/x-unreal-uasset;application/x-extra;" in desktop_entry,
		"AppImage desktop metadata advertises MIME handlers and file arguments")


func _test_mod_config_settings_persistence() -> void:
	var override_variable := str(ProjectSettings.get_setting(
		"app_settings/override_environment_variable",
		"SPELLBREAK_MODKIT_CONFIG_DIR"
	))
	var previous_override := OS.get_environment(override_variable)
	var test_directory := OS.get_temp_dir().path_join(
		"spellbreak-settings-test-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	)
	OS.set_environment(override_variable, test_directory)

	var settings := AppSettingsRuntime.new()
	var config := ModConfigManager.new(settings)
	_expect(not config.keep_pack_backups,
		"automatic pack backups default to disabled")
	config.game_dir = "/test/game"
	config.mods_dir = "/test/mods"
	config.launch_cmd = "updated-launch"
	config.keep_pack_backups = true
	config.sources = [{"name": "Base", "path": "/test/source"}]
	_expect(config.save_config() == OK, "mod config saves through AppSettings")

	var reloaded_settings := AppSettingsRuntime.new()
	var reloaded_config := ModConfigManager.new(reloaded_settings)
	_expect(reloaded_config.game_dir == "/test/game"
		and reloaded_config.mods_dir == "/test/mods"
		and reloaded_config.keep_pack_backups,
		"mod config reloads typed paths through AppSettings")
	_expect(reloaded_config.sources.size() == 1
		and reloaded_config.sources[0].name == "Base",
		"mod config reloads structured source settings")
	_expect(reloaded_settings.get_value(
		ModConfigManager.SETTINGS_SECTION,
		"launch_cmd",
		""
	) == "updated-launch", "AppSettings persists mod config changes")

	settings.free()
	reloaded_settings.free()
	_cleanup_settings_test_directory(test_directory)
	OS.set_environment(override_variable, previous_override)


func _cleanup_settings_test_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for directory_name: String in DirAccess.get_directories_at(path):
		_cleanup_settings_test_directory(path.path_join(directory_name))
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)


func _test_file_association_metadata() -> void:
	var windows_entries := FileAssociationService.windows_registry_entries(
			"C:\\Apps\\Spellbreak Modkit\\sbue.exe",
			"C:\\Icons\\uasset_icon.ico")
	var registry_text := JSON.stringify(windows_entries)
	_expect("SpellbreakModkit.uasset" in registry_text
		and "DefaultIcon" in registry_text
		and "\\\"%1\\\"" in registry_text,
		"Windows association metadata registers the ProgID, icon, and open command")

	var desktop_entry := FileAssociationService.linux_desktop_entry(
			"/opt/Spellbreak Modkit/sbue.AppImage")
	_expect("Exec=\"/opt/Spellbreak Modkit/sbue.AppImage\" %F" in desktop_entry
		and "MimeType=application/x-unreal-uasset;" in desktop_entry,
		"Linux desktop metadata opens .uasset paths with the current executable")
	var mime_package := FileAssociationService.linux_mime_package()
	_expect("application/x-unreal-uasset" in mime_package
		and "*.uasset" in mime_package
		and "application-x-unreal-uasset" in mime_package,
		"Linux MIME metadata assigns the custom .uasset icon")
	var icon_test_root := OS.get_temp_dir().path_join(
			"sb_test_file_icon_%d" % Time.get_ticks_usec())
	var installed_icon := icon_test_root.path_join("uasset.png")
	var association_service := FileAssociationService.new().setup(icon_test_root)
	var icon_error := association_service._write_texture_png(
			FileAssociationService.UASSET_ICON_RESOURCE, installed_icon)
	_expect(icon_error == OK and FileAccess.file_exists(installed_icon)
		and FileAccess.get_file_as_bytes(installed_icon).slice(1, 4) == PackedByteArray([
			0x50, 0x4e, 0x47,
		]), "bundled .uasset SVG installs as a PNG MIME icon")
	FileUtils.remove_dir_recursive(icon_test_root)


func _test_native_keymap_configuration() -> void:
	var defaults := KeymapSettingsTab.default_config()
	var default_open := KeymapSettingsTab.event_from_data(
			(defaults[str(KeymapSettingsTab.ACTION_OPEN)] as Array)[0]) as InputEventKey
	_expect(default_open != null and default_open.keycode == KEY_SPACE
			and default_open.ctrl_pressed,
		"native keymap keeps the default open-file shortcut")

	var modifier := InputEventKey.new()
	modifier.keycode = KEY_CTRL
	modifier.ctrl_pressed = true
	modifier.pressed = true
	var combo := InputEventKey.new()
	combo.keycode = KEY_P
	combo.ctrl_pressed = true
	combo.pressed = true
	var keymap_tab := KeymapSettingsTab.new()
	_expect(not keymap_tab._is_bindable_event(modifier)
			and keymap_tab._is_bindable_event(combo),
		"native keymap waits for the non-modifier key in a key combination")
	keymap_tab.free()

	var custom := InputEventKey.new()
	custom.keycode = KEY_K
	custom.ctrl_pressed = true
	var rebound := KeymapSettingsTab.set_binding(
			defaults, KeymapSettingsTab.ACTION_OPEN, 0, custom)
	var open_event := KeymapSettingsTab.event_from_data(
			(rebound[str(KeymapSettingsTab.ACTION_OPEN)] as Array)[0])
	var compare_event := KeymapSettingsTab.event_from_data(
			(rebound[str(KeymapSettingsTab.ACTION_COMPARE)] as Array)[0])
	_expect(open_event != null and open_event.is_match(custom),
		"native keymap applies a custom binding")
	_expect(compare_event == null,
		"native keymap clears a colliding binding")

	KeymapSettingsTab.apply_config(rebound)
	var active_events := InputMap.action_get_events(KeymapSettingsTab.ACTION_OPEN)
	_expect(active_events.size() == 1 and active_events[0].is_match(custom),
		"native keymap installs bindings into Godot InputMap")
	var encoded: Variant = KeymapSettingsTab.event_to_data(custom)
	var decoded := KeymapSettingsTab.event_from_data(encoded)
	_expect(decoded != null and decoded.is_match(custom),
		"native keymap serializes input events without GUIDE resources")
	KeymapSettingsTab.apply_config(defaults)


func _test_base_file_explorer_search() -> void:
	_expect(BaseFileExplorerTab._is_editor_asset("Example.uasset")
		and not BaseFileExplorerTab._is_editor_asset("Example.json")
		and ExternalFileLauncher.is_text_file("Config/DefaultGame.ini")
		and not ExternalFileLauncher.is_text_file("Example.uasset"),
		"base file explorer routes every non-uasset file through the external launcher")
	var terms := BaseFileExplorerTab._query_terms("  Player  fire ")
	_expect(terms == PackedStringArray(["player", "fire"]),
		"base file explorer normalizes multi-term searches")
	_expect(BaseFileExplorerTab._path_matches_terms(
		"g3/Content/Players/Fire/GE_Burn.uasset", terms),
		"base file explorer matches every search term against the relative path")
	_expect(not BaseFileExplorerTab._path_matches_terms(
		"g3/Content/Players/Ice/GE_Freeze.uasset", terms),
		"base file explorer rejects partial multi-term matches")
	_expect(BaseFileExplorerTab._relative_path(
		"/source/g3/Content/Test.uasset", "/source")
		== "g3/Content/Test.uasset",
		"base file explorer stores searchable source-relative paths")
	var tests_path := ProjectSettings.globalize_path("res://tests")
	var scan := BaseFileExplorerTab._scan_sources([{
		"name": "Tests",
		"path": tests_path,
	}])
	var found_core_test := false
	for entry: Dictionary in scan.get("entries", []):
		if str(entry.get("relative_path", "")) == "test_core.gd":
			found_core_test = true
			break
	_expect(found_core_test and (scan.get("errors", []) as Array).is_empty(),
		"base file explorer recursively indexes a configured source")


func _test_explorer_add_to_mod_path() -> void:
	_expect(ModManagerPanel._source_relative_path(
		"/source/g3/Content/Spells/Fire.uasset", "/source")
		== "g3/Content/Spells/Fire.uasset",
		"explorer add-to-mod preserves the configured source-relative path")
	_expect(ModManagerPanel._source_relative_path(
		"/another/Fire.uasset", "/source").is_empty(),
		"explorer add-to-mod rejects files outside the configured source")


func _test_source_package_companion_discovery() -> void:
	var root := OS.get_temp_dir().path_join(
		"sb_test_source_companions_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var uasset := root.path_join("Fire.uasset")
	var uexp := root.path_join("Fire.uexp")
	var ubulk := root.path_join("Fire.ubulk")
	var unrelated := root.path_join("Ice.uexp")
	var notes := root.path_join("Fire.txt")
	for path in [uasset, uexp, ubulk, unrelated, notes]:
		FileUtils.write_bytes_atomic(path, path.get_file().to_utf8_buffer())

	var from_header := ModManagerPanel._expand_package_files(
		PackedStringArray([uasset]))
	_expect(from_header.size() == 3
		and uasset in from_header and uexp in from_header and ubulk in from_header,
		"source add automatically discovers existing Unreal package companions")
	_expect(unrelated not in from_header and notes not in from_header,
		"source add does not include other basenames or loose files")

	var from_companion := ModManagerPanel._expand_package_files(
		PackedStringArray([uexp, uasset]))
	_expect(from_companion.size() == 3 and uasset in from_companion,
		"source add discovers the package header and deduplicates manual selections")
	var loose := ModManagerPanel._expand_package_files(PackedStringArray([notes]))
	_expect(loose == PackedStringArray([notes]),
		"source add leaves non-package file selections unchanged")
	FileUtils.remove_dir_recursive(root)


func _test_asset_reuse_copy() -> void:
	var asset := _make_asset()
	asset.file_path = "/tmp/GE_Tough.uasset"
	asset.binary_path = asset.file_path
	asset.name_map = PackedStringArray([
		"GE_Tough",
		"GE_Tough_C",
		"Default__GE_Tough_C",
		"/Game/Effects/GE_Tough",
		"UnrelatedName",
	])
	asset.raw = {
		"PackageGuid": "{11111111-2222-3333-4444-555555555555}",
		"Custom": {
			"$type": "GE_Tough.SerializerType",
			"AssetPath": "/Game/Effects/GE_Tough.GE_Tough_C",
		},
	}
	asset.exports[0].object_name = "GE_Tough_C"
	asset.imports[0].package_name = "/Game/Effects/GE_Tough"

	var result := asset.prepare_reuse_copy("/tmp/GE_StoneSkin.uasset", true,
			"/Game/Effects/GE_Tough", "/Game/Cloned/GE_StoneSkin")
	var copy := result.value as UAssetFile
	_expect(result.ok and copy != null,
		"asset reuse prepares an independent in-memory package")
	_expect(copy.name_map.has("GE_StoneSkin")
			and copy.name_map.has("GE_StoneSkin_C")
			and copy.name_map.has("Default__GE_StoneSkin_C")
			and copy.name_map.has("/Game/Cloned/GE_StoneSkin")
			and copy.name_map.has("UnrelatedName"),
		"asset reuse renames base, generated-class, default-object, and path names")
	_expect(copy.exports[0].object_name == "GE_StoneSkin_C"
			and copy.imports[0].package_name == "/Game/Cloned/GE_StoneSkin"
			and copy.raw["Custom"]["AssetPath"]
				== "/Game/Cloned/GE_StoneSkin.GE_StoneSkin_C",
		"asset reuse updates serialized object metadata and references")
	_expect(copy.raw["Custom"]["$type"] == "GE_Tough.SerializerType",
		"asset reuse preserves UAssetAPI serializer type descriptors")
	_expect(copy.package_guid != "{11111111-2222-3333-4444-555555555555}"
			and copy.package_guid.length() == 38
			and asset.name_map[0] == "GE_Tough",
		"unique asset clone generates a package GUID without changing the source asset")
	_expect(not asset.prepare_reuse_copy(asset.binary_path).ok,
		"asset reuse refuses to replace its own source package")

	var overlap := asset.prepare_reuse_copy("/tmp/GE_ToughSkin.uasset", true,
			"/Game/Effects/GE_Tough", "/Game/Cloned/GE_ToughSkin")
	var overlap_copy := overlap.value as UAssetFile
	_expect(overlap.ok
			and overlap_copy.raw["Custom"]["AssetPath"]
				== "/Game/Cloned/GE_ToughSkin.GE_ToughSkin_C"
			and overlap_copy.name_map.has("/Game/Cloned/GE_ToughSkin"),
		"clone with a destination name containing the source name is not corrupted")


func _test_name_map_fname_sync() -> void:
	var asset := UAssetFile.new()
	asset.raw = {}
	asset.file_path = "/tmp/fname_sync.uasset"
	asset.binary_path = asset.file_path
	asset.name_map = PackedStringArray(["OldName", "Unrelated", "OldName_2"])

	var expo := UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
		"ObjectName": "OldName",
		"OuterIndex": 0, "ClassIndex": 0, "SuperIndex": 0, "TemplateIndex": 0,
		"SerialSize": 0, "SerialOffset": 0,
		"CreateBeforeCreateDependencies": [],
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Data": [{
			"$type": "UAssetAPI.PropertyTypes.Objects.StrPropertyData, UAssetAPI",
			"Name": "OldName",
			"ArrayIndex": 0, "IsZero": false,
			"Value": "OldNameSkin",
		}],
	}, asset)
	var imp := UAssetImport.from_dict({
		"$type": "UAssetAPI.Import, UAssetAPI",
		"ObjectName": "OldName",
		"ClassName": "Class",
		"ClassPackage": "/Script/CoreUObject",
		"PackageName": null,
		"OuterIndex": 0,
		"bImportOptional": false,
	}, 0, asset)
	asset.exports = [expo]
	asset.imports = [imp]
	_expect(expo.object_name == "OldName" and imp.object_name == "OldName"
			and expo.properties[0].prop_name == "OldName",
		"asset-backed objects resolve names from the NameMap")

	var stats := asset.rename_name("OldName", "NewName")
	_expect(stats["renames"] >= 4, "rename_name reports NameMap and raw replacements")
	_expect(asset.name_map[0] == "NewName", "rename updates the NameMap entry")
	_expect(expo.object_name == "NewName", "export ObjectName follows the renamed map entry")
	_expect(imp.object_name == "NewName", "import ObjectName follows the renamed map entry")
	_expect(expo.properties[0].prop_name == "NewName",
		"property name follows the renamed map entry")
	_expect(expo.to_dict()["ObjectName"] == "NewName"
			and expo.to_dict()["Data"][0]["Name"] == "NewName",
		"serialized JSON emits the renamed names")
	_expect(expo.raw["ObjectName"] == "NewName"
			and expo.raw["Data"][0]["Name"] == "NewName",
		"raw dict strings are rewritten so saved JSON stays consistent")
	_expect(asset.name_map[2] == "OldName_2"
			and expo.properties[0].value == "OldNameSkin",
		"exact-match rename leaves substring-containing names untouched")

	asset.rename_name("NewName", "OldName")
	_expect(expo.object_name == "OldName" and expo.to_dict()["ObjectName"] == "OldName",
		"rename is invertible")

	# Reverse sync: assigning an object name ensures it in the NameMap.
	expo.object_name = "BrandNew"
	_expect(asset.has_name("BrandNew") and expo.to_dict()["ObjectName"] == "BrandNew",
		"object name assignment syncs the NameMap")
	imp.class_name_str = "NewClass"
	_expect(asset.has_name("NewClass") and imp.to_dict()["ClassName"] == "NewClass",
		"import class name assignment syncs the NameMap")

	# Data table row names live only in raw dicts — rename rewrites them too.
	expo.raw["Table"] = {"Data": [{
		"$type": "UAssetAPI.PropertyTypes.Objects.IntPropertyData, UAssetAPI",
		"Name": "RowOld",
		"ArrayIndex": 0, "IsZero": false,
		"Value": 5,
	}]}
	asset.rename_name("RowOld", "RowNew")
	_expect(expo.raw["Table"]["Data"][0]["Name"] == "RowNew",
		"rename propagates into data table row raw names")

	# Detached objects keep working without an asset (fallback strings).
	var detached := UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
		"ObjectName": "Loose",
		"OuterIndex": 0, "ClassIndex": 0, "SuperIndex": 0, "TemplateIndex": 0,
		"SerialSize": 0, "SerialOffset": 0,
		"CreateBeforeCreateDependencies": [],
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Data": [],
	})
	_expect(detached.object_name == "Loose"
			and detached.to_dict()["ObjectName"] == "Loose",
		"asset-less exports keep plain string names")

	# Attaching an asset adopts existing strings into its NameMap.
	detached.set_asset(asset)
	_expect(detached.object_name == "Loose" and asset.has_name("Loose"),
		"set_asset adopts existing names into the NameMap")
	_expect(asset.index_of_name("Loose", false) == asset.index_of_name("Loose"),
		"index_of_name finds existing entries without appending")
	_expect(asset.index_of_name("DoesNotExist", false) == -1,
		"index_of_name reports missing names without creating them")

	# Inserting map entries shifts index references in lockstep.
	var before_insert := expo.object_name
	var insert_idx := asset.index_of_name("Unrelated")
	asset.insert_names(insert_idx, ["InsertMe", "InsertMe", "InsertMe2"])
	_expect(asset.name_map[insert_idx] == "InsertMe"
			and asset.name_map[insert_idx + 1] == "InsertMe2",
		"insert_names skips duplicates and inserts in order")
	_expect(expo.object_name == before_insert,
		"inserting map entries keeps resolved names stable")
	_expect(asset.index_of_name(before_insert) != asset.index_of_name("InsertMe"),
		"inserted entries do not collide with existing references")

	# Deleting unreferenced entries remaps indices; referenced ones are kept.
	var kept_name := expo.object_name
	var kept_idx := asset.index_of_name(kept_name)
	var plan := asset.plan_name_removal([kept_idx, insert_idx, insert_idx + 1])
	_expect(kept_idx in plan["kept"], "referenced map entries are kept by deletion")
	_expect(insert_idx in plan["deleted"], "unreferenced map entries are deleted")
	var removed_names: Array = plan["removed"]
	asset.remove_names([kept_idx, insert_idx, insert_idx + 1])
	_expect(not asset.has_name("InsertMe") and not asset.has_name("InsertMe2"),
		"remove_names drops unreferenced entries")
	_expect(asset.has_name(kept_name) and expo.object_name == kept_name,
		"remove_names keeps referenced entries and their references intact")
	var after_remove_idx := asset.index_of_name(kept_name)
	_expect(after_remove_idx == kept_idx - 2,
		"remove_names remaps surviving indices past the deleted positions")

	asset.restore_removed_names(removed_names, plan["deleted"])
	_expect(asset.name_map[insert_idx] == "InsertMe"
			and asset.name_map[insert_idx + 1] == "InsertMe2"
			and asset.index_of_name(kept_name) == kept_idx,
		"restore_removed_names restores the map and remaps references back")


func _test_fname_split_base() -> void:
	_expect(UAssetFile._fname_split_base("NewName_0") == "NewName",
		"_fname_split_base splits a single-digit suffix")
	_expect(UAssetFile._fname_split_base("NewName_1") == "NewName",
		"_fname_split_base splits any numeric suffix")
	_expect(UAssetFile._fname_split_base("A_B_10") == "A_B",
		"_fname_split_base splits at the last underscore")
	_expect(UAssetFile._fname_split_base("A_01") == "",
		"_fname_split_base rejects leading-zero suffixes")
	_expect(UAssetFile._fname_split_base("A_00") == "",
		"_fname_split_base rejects all-zero multi-digit suffixes")
	_expect(UAssetFile._fname_split_base("_0") == "",
		"_fname_split_base needs a non-empty base")
	_expect(UAssetFile._fname_split_base("NewName") == "",
		"_fname_split_base leaves unsuffixed names alone")
	_expect(UAssetFile._fname_split_base("Name_") == "",
		"_fname_split_base leaves dangling underscores alone")
	_expect(UAssetFile._fname_split_base("") == "",
		"_fname_split_base handles empty names")
	_expect(UAssetFile._fname_split_base(
			"/Game/Blueprints/Effects/Potion/BP_Effect_Potion_Armor_Tier_0")
			== "/Game/Blueprints/Effects/Potion/BP_Effect_Potion_Armor_Tier",
		"_fname_split_base splits a full package path suffix")


func _test_dummy_fname_save_heuristics() -> void:
	var full := "/Game/Blueprints/Effects/Potion/BP_Effect_Potion_Armor_Tier_0"
	var err_text := "Error: Attempt to serialize dummy FName '%s' - this name was never added to the NameMap." % full
	_expect(UAssetFile._extract_dummy_fname(err_text) == full,
		"_extract_dummy_fname parses the missing name from the converter error")
	_expect(UAssetFile._extract_dummy_fname("Unrelated error text") == "",
		"_extract_dummy_fname returns empty for unrelated errors")

	var asset := UAssetFile.new()
	asset.raw = {}
	asset.file_path = "/tmp/fname_ensure.uasset"
	asset.binary_path = asset.file_path
	asset.name_map = PackedStringArray(["Existing"])
	var data := {
		"NameMap": ["Existing"],
		"Exports": [{
			"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
			"ObjectName": "Existing",
			"Data": [{
				"$type": "UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI",
				"Name": "NewRef",
				"Value": full,
			}],
		}],
	}
	_expect(asset._ensure_all_fnames(data),
		"_ensure_all_fnames reports added names")
	_expect(asset.has_name(full), "full suffixed name is ensured")
	_expect(asset.has_name("/Game/Blueprints/Effects/Potion/BP_Effect_Potion_Armor_Tier"),
		"parsed FName base is ensured (the converter looks up the base)")
	_expect(asset.has_name("NewRef"), "property name is ensured")
	_expect(not asset.has_name("UAssetAPI.ExportTypes.NormalExport, UAssetAPI")
			and not asset.has_name("UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI"),
		"$type serializer names are skipped")
	_expect(not asset._ensure_all_fnames(data),
		"_ensure_all_fnames is idempotent")
	var map_before: Array = asset.name_map
	asset._ensure_all_fnames(data)
	_expect(asset.name_map.size() == map_before.size(),
		"repeated ensure calls never grow the NameMap")


func _test_swap_and_snapshot_restore() -> void:
	var asset := _make_asset()
	var snapshot := asset.capture_package_tables()
	var first := asset.exports[0]
	asset.swap_exports(1, 2)
	_expect(first.outer_index == 3 and _object_value(first) == 2,
		"export swap remaps metadata and ObjectProperty references")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [3, 2, -2],
		"export swap remaps dependencies")

	asset.remove_export_at(1)
	asset.remove_import_at(0)
	asset.restore_package_tables(snapshot)
	_expect(asset.exports.size() == 3 and asset.imports.size() == 3,
		"package table snapshot restores table sizes")
	_expect(asset.exports[0].outer_index == 2 and _object_value(asset.exports[0]) == 3,
		"package table snapshot restores exact references")


func _test_asset_document_history() -> void:
	var asset := _make_asset()
	var document := AssetDocument.new(asset)
	var state := {"value": 1}
	var first := AssetEditCommand.new("Set two",
		func() -> void: state["value"] = 2,
		func() -> void: state["value"] = 1)
	_expect(document.execute(first) and state["value"] == 2, "document executes commands")
	_expect(document.is_dirty() and document.can_undo(), "executed command marks document dirty")
	document.mark_saved()
	_expect(not document.is_dirty(), "mark_saved establishes a clean history position")

	var second := AssetEditCommand.new("Set three",
		func() -> void: state["value"] = 3,
		func() -> void: state["value"] = 2)
	document.execute(second)
	_expect(state["value"] == 3 and document.is_dirty(), "later commands move beyond the save point")
	_expect(document.undo() and state["value"] == 2 and not document.is_dirty(),
		"undo returns to the saved state")
	_expect(document.redo() and state["value"] == 3 and document.is_dirty(), "redo reapplies a command")

	document.undo()
	document.undo()
	var branch := AssetEditCommand.new("Set four",
		func() -> void: state["value"] = 4,
		func() -> void: state["value"] = 1)
	document.execute(branch)
	_expect(state["value"] == 4 and not document.can_redo(), "new edits discard the redo branch")
	_expect(document.is_dirty(), "discarding the saved branch keeps the document dirty")


func _test_clipboard_rejects_unsupported_copy() -> void:
	var asset := _make_asset()
	var copied := ClipboardManager.copy(asset.exports[0], asset, [asset.exports[0]])
	_expect(bool(copied.get("ok", false)), "clipboard accepts a normal export copy")

	var rejected := ClipboardManager.copy([], asset, [])
	_expect(not bool(rejected.get("ok", true)),
		"clipboard rejects unsupported copy targets")
	_expect(ClipboardManager.is_empty(),
		"clipboard clears stale data after an unsupported copy")


func _test_clipboard_datatable_row_targets_current_table() -> void:
	var source := _make_empty_asset("res://source_table.uasset")
	var source_rows := [_make_datatable_row_raw("SourceRow", 11)]
	var source_table := _make_datatable_export("SourceTable", source_rows)
	source.exports = [source_table]

	var target := _make_empty_asset("res://target_table.uasset")
	var target_rows := [_make_datatable_row_raw("TargetRow", 22)]
	var target_table := _make_datatable_export("TargetTable", target_rows)
	target.exports = [target_table]

	var source_row := UAssetProperty.from_dict(source_rows[0])
	var copy_result := ClipboardManager.copy({"dt_row": source_row, "expo": source_table}, source, [])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts data table row copy")

	var target_row := UAssetProperty.from_dict(target_rows[0])
	ClipboardManager.paste(_make_clipboard_context(target),
		{"dt_row": target_row, "expo": target_table}, [], null)

	var copied_target_rows := target_table.get_datatable_rows()
	_expect(source_table.get_datatable_rows().size() == 1,
		"data table row paste leaves the source table unchanged")
	_expect(copied_target_rows.size() == 2
			and str((copied_target_rows[1] as Dictionary).get("Name")) == "SourceRow_Copy",
			"data table row paste inserts into the current target table")


func _test_clipboard_datatable_row_pastes_into_empty_table() -> void:
	var source := _make_empty_asset("res://source_empty_table.uasset")
	var source_rows := [_make_datatable_row_raw("SourceRow", 33)]
	var source_table := _make_datatable_export("SourceTable", source_rows)
	source.exports = [source_table]

	var target := _make_empty_asset("res://target_empty_table.uasset")
	var target_table := _make_datatable_export("TargetTable", [])
	target.exports = [target_table]

	var source_row := UAssetProperty.from_dict(source_rows[0])
	var copy_result := ClipboardManager.copy({"dt_row": source_row, "expo": source_table}, source, [])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts row copy for empty-table paste")

	ClipboardManager.paste(_make_clipboard_context(target), target_table, [], null)
	var target_rows := target_table.get_datatable_rows()
	_expect(target_rows.size() == 1
			and str((target_rows[0] as Dictionary).get("Name")) == "SourceRow_Copy",
		"data table row paste works when the target table starts empty")


func _test_clipboard_export_cross_file_remaps_imports() -> void:
	var source := _make_empty_asset("res://source_refs.uasset")
	source.imports = [_make_import("SourceClass", 0)]
	source.exports = [_make_export("NeedsImport", 0, -1, 0, [-1], -1)]

	var target := _make_empty_asset("res://target_refs.uasset")
	target.imports = [_make_import("OtherClass", 0)]

	var copy_result := ClipboardManager.copy(source.exports[0], source, [source.exports[0]])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts cross-file export copy")
	ClipboardManager.paste(_make_clipboard_context(target), null, [], null)

	_expect(target.imports.size() == 2
			and target.imports[1].object_name == "SourceClass"
			and target.imports[1].package_name.is_empty()
			and target.imports[1].to_dict().get("PackageName") == null,
		"cross-file export paste adds the referenced source import once")
	_expect(target.exports.size() == 1
			and target.exports[0].class_index == -2
			and _object_value(target.exports[0]) == -2,
		"cross-file export paste rewrites copied import references to the target asset")


func _test_clipboard_export_group_preserves_internal_refs() -> void:
	var source := _make_empty_asset("res://source_group.uasset")
	source.exports = [
		_make_export("CopiedA", 0, 0, 0, [], 0),
		_make_export("CopiedB", 0, 0, 0, [1], 1),
	]

	var target := _make_empty_asset("res://target_group.uasset")
	target.exports = [_make_export("Existing", 0, 0, 0, [], 0)]

	var copy_result := ClipboardManager.copy(null, source, source.exports)
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts grouped export copy")
	ClipboardManager.paste(_make_clipboard_context(target), null, [], null)

	_expect(target.exports.size() == 3
			and target.exports[1].object_name == "CopiedA_Copy"
			and target.exports[2].object_name == "CopiedB_Copy",
		"grouped export paste inserts copied exports in order")
	_expect(_object_value(target.exports[2]) == 2
			and target.exports[2].raw["CreateBeforeCreateDependencies"] == [2],
		"grouped export paste preserves references between copied exports")


func _test_property_state_restore() -> void:
	var prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.StructPropertyData, UAssetAPI",
		"Name": "Container",
		"StructType": "TestStruct",
		"Value": [{
			"$type": "UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI",
			"Name": "TagName",
			"Value": "Before",
		}],
	})
	var before := prop.capture_state()
	prop.children[0].set_value("After")
	var after := prop.capture_state()
	prop.restore_state(before)
	_expect(prop.children[0].value == "Before" and prop.to_dict() == before,
		"property restore synchronizes parsed and raw state")
	prop.restore_state(after)
	_expect(prop.children[0].value == "After" and prop.to_dict() == after,
		"property snapshots can be reapplied for redo")


func _test_byte_enum_property_round_trip() -> void:
	var enum_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"ByteType": "FName",
		"EnumType": "EMaterialParameterAssociation",
		"EnumValue": "GlobalParameter",
		"Name": "Association",
		"ArrayIndex": 0,
		"IsZero": false,
	})
	_expect(enum_prop.value == "GlobalParameter",
		"byte enum property reads EnumValue instead of null")
	var enum_dict := enum_prop.to_dict()
	_expect(enum_dict.get("EnumValue") == "GlobalParameter" and not enum_dict.has("Value"),
		"byte enum property serializes without a null Value field")

	enum_prop.set_value("LayerParameter")
	enum_dict = enum_prop.to_dict()
	_expect(enum_dict.get("EnumValue") == "LayerParameter" and not enum_dict.has("Value"),
		"byte enum property edits write back to EnumValue")

	var polluted_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"ByteType": "FName",
		"EnumType": "EMaterialParameterAssociation",
		"EnumValue": "GlobalParameter",
		"Name": "Association",
		"Value": null,
	})
	_expect(polluted_prop.value == "GlobalParameter" and not polluted_prop.to_dict().has("Value"),
		"byte enum property recovers from a stale null Value field")

	var numeric_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"Name": "Channel",
		"Value": 2,
	})
	numeric_prop.set_value(5)
	_expect(numeric_prop.to_dict().get("Value") == 5,
		"numeric byte property still serializes Value")


func _test_asset_diff_engine() -> void:
	var left := {
		"NameMap": PackedStringArray(["One"]),
		"Exports": [{
			"ObjectName": "Export1",
			"Data": [{
				"Name": "Value",
				"Value": 1,
			}],
		}],
		"OnlyLeft": true,
	}
	var right := {
		"NameMap": PackedStringArray(["One", "Two"]),
		"Exports": [{
			"ObjectName": "Export1",
			"Data": [{
				"Name": "Value",
				"Value": 2,
			}],
		}],
		"OnlyRight": true,
	}
	var diffs := AssetDiff.compare_values(left, right)
	var by_path: Dictionary = {}
	for diff in diffs:
		by_path[str(diff["path"])] = diff

	_expect(by_path.has("Exports[0].Data[0].Value"),
		"asset diff detects changed nested values")
	_expect(by_path.has("NameMap[1]")
			and by_path["NameMap[1]"]["status"] == AssetDiff.STATUS_ADDED,
		"asset diff detects added packed-string-array items")
	_expect(by_path.has("OnlyLeft")
			and by_path["OnlyLeft"]["status"] == AssetDiff.STATUS_REMOVED
			and by_path.has("OnlyRight")
			and by_path["OnlyRight"]["status"] == AssetDiff.STATUS_ADDED,
		"asset diff detects removed and added dictionary keys")


func _test_asset_diff_tab_layout() -> void:
	var left := _make_asset()
	var right := _make_asset()
	right.name_map.append("Four")
	var tab := AssetDiffTab.setup(left, right)
	_expect(tab.tab_title == "Diff", "asset diff tab uses a short readable title")
	_expect(tab.get_child_count() >= 3 and tab.diffs.size() > 0,
		"asset diff tab builds a readable change list")
	tab.free()


func _test_linear_color_property_editor() -> void:
	var prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.LinearColorPropertyData, UAssetAPI",
		"Name": "ParameterValue",
		"Value": {
			"$type": "UAssetAPI.UnrealTypes.FLinearColor, UAssetAPI",
			"R": 1.0,
			"G": 0.25,
			"B": 0.5,
			"A": 1.0,
		},
	})
	_expect(PropertyRow.is_color_struct(prop),
		"linear color property data is detected as editable color")

	var row := PropertyRow.create(prop)
	var editor := row.editor_control as HBoxContainer
	_expect(editor != null and editor.get_child(0) is ColorPickerButton,
		"linear color property uses a color picker editor")

	var changes: Array[Dictionary] = []
	row.value_changed.connect(func(_prop: UAssetProperty, _old_value: Variant, _new_value: Variant) -> void:
		changes.append({"old": _old_value, "new": _new_value})
	)
	var picker := editor.get_child(0) as ColorPickerButton
	picker.color_changed.emit(Color(0.1, 0.2, 0.3, 0.4))
	var value := prop.value as Dictionary
	var raw_value := prop.raw["Value"] as Dictionary
	_expect(changes.size() == 1, "linear color picker emits a property change")
	_expect(_approx_float(float(value["G"]), 0.2)
			and _approx_float(float(raw_value["B"]), 0.3),
		"linear color picker writes back to raw FLinearColor values")


func _test_vector_property_editor() -> void:
	var prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.StructPropertyData, UAssetAPI",
		"Name": "Location",
		"StructType": "Vector",
		"Value": [
			_make_float_property_raw("X", 1.0),
			_make_float_property_raw("Y", 2.0),
			_make_float_property_raw("Z", 3.0),
		],
	})
	_expect(PropertyRow.is_vector_struct(prop),
		"vector struct property is detected as editable vector")

	var row := PropertyRow.create(prop)
	var editor := row.editor_control as HBoxContainer
	_expect(editor != null and editor.get_child_count() == 3 and _vector_spin(editor, 0) is SpinBox,
		"vector struct uses numeric component editors")

	var changes: Array[Dictionary] = []
	row.value_changed.connect(func(_prop: UAssetProperty, _old_value: Variant, _new_value: Variant) -> void:
		changes.append({"old": _old_value, "new": _new_value})
	)
	var y_spin := _vector_spin(editor, 1)
	y_spin.value_changed.emit(12.5)
	var child_dicts: Array = prop.to_dict()["Value"]
	_expect(changes.size() == 1, "vector component edit emits a property change")
	_expect(_approx_float(float(prop.find_child("Y").value), 12.5)
			and _approx_float(float((child_dicts[1] as Dictionary).get("Value")), 12.5),
		"vector component edit writes back to child property data")
	row.free()

	var raw_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.VectorPropertyData, UAssetAPI",
		"Name": "Velocity",
		"Value": {
			"$type": "UAssetAPI.UnrealTypes.FVector, UAssetAPI",
			"X": 4.0,
			"Y": "+0",
			"Z": "+0",
		},
	})
	_expect(PropertyRow.is_vector_struct(raw_prop),
		"raw FVector property data with numeric strings is detected as editable vector")
	var raw_row := PropertyRow.create(raw_prop)
	var raw_editor := raw_row.editor_control as HBoxContainer
	_vector_spin(raw_editor, 2).value_changed.emit(-7.25)
	var raw_value := raw_prop.to_dict()["Value"] as Dictionary
	_expect(_approx_float(float(raw_value["Z"]), -7.25)
			and _approx_float(float((raw_prop.raw["Value"] as Dictionary)["Z"]), -7.25)
			and raw_value["Z"] is String,
		"raw FVector component edit writes back to string-backed dictionary data")
	raw_row.free()

	var dict_struct := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.StructPropertyData, UAssetAPI",
		"Name": "Offset",
		"StructType": "Vector",
		"Value": {
			"$type": "UAssetAPI.UnrealTypes.FVector, UAssetAPI",
			"X": 7.0,
			"Y": 8.0,
			"Z": 9.0,
		},
	})
	_expect(PropertyRow.is_vector_struct(dict_struct),
		"dictionary-backed vector struct is detected as editable vector")
	var dict_row := PropertyRow.create(dict_struct)
	var dict_editor := dict_row.editor_control as HBoxContainer
	_vector_spin(dict_editor, 0).value_changed.emit(42.0)
	var dict_value := dict_struct.to_dict()["Value"] as Dictionary
	_expect(_approx_float(float(dict_value["X"]), 42.0),
		"dictionary-backed struct vector keeps dictionary shape on save")
	dict_row.free()


func _test_particle_effect_detail_builds_module_stack() -> void:
	var asset := _make_empty_asset("res://particle_test.uasset")
	asset.imports = [
		_make_import("ParticleSystem", 0),
		_make_import("ParticleSpriteEmitter", 0),
		_make_import("ParticleLODLevel", 0),
		_make_import("ParticleModuleRequired", 0),
		_make_import("ParticleModuleSpawn", 0),
		_make_import("ParticleModuleSize", 0),
		_make_import("ParticleModuleTypeDataMesh", 0),
		_make_import("StaticMesh", 0),
		_make_import("/Game/VFX/Meshes/TestMesh", 0),
		_make_import("MaterialInstanceConstant", 0),
		_make_import("/Game/VFX/Materials/TestMaterial", 0),
		_make_import("DistributionFloatConstant", 0),
	]
	asset.imports[7].object_name = "TestMesh"
	asset.imports[7].class_name_str = "StaticMesh"
	asset.imports[7].outer_index = -9
	asset.imports[9].object_name = "TestMaterial"
	asset.imports[9].class_name_str = "MaterialInstanceConstant"
	asset.imports[9].outer_index = -11
	asset.file_path = "/tmp/game/g3/Content/VFX/Test/Particle.uasset"
	asset.binary_path = asset.file_path
	var system := _make_export("TestParticleSystem", 0, -1, 0, [], 0)
	system.properties = [_make_object_array_property("Emitters", "Object", [2])]
	system.raw["Data"] = [system.properties[0].to_dict()]
	var emitter := _make_export("ParticleSpriteEmitter_0", 1, -2, 0, [], 0)
	emitter.properties = [
		_make_object_array_property("LODLevels", "Object", [3, 8]),
	]
	emitter.raw["Data"] = [emitter.properties[0].to_dict()]
	var lod := _make_export("ParticleLODLevel_0", 2, -3, 0, [], 0)
	lod.properties = [
		_make_object_property("RequiredModule", 4),
		_make_object_property("SpawnModule", 5),
		_make_object_property("TypeDataModule", 7),
		_make_object_array_property("Modules", "Object", [6]),
		_make_int_property("PeakActiveParticles", 4),
	]
	lod.raw["Data"] = [
		lod.properties[0].to_dict(),
		lod.properties[1].to_dict(),
		lod.properties[2].to_dict(),
		lod.properties[3].to_dict(),
		lod.properties[4].to_dict(),
	]
	var required := _make_export("ParticleModuleRequired_0", 3, -4, 0, [], 0)
	required.properties = [
		_make_object_property("Material", -10),
		_make_byte_enum_property("ScreenAlignment", "EParticleScreenAlignment", "PSA_Velocity"),
	]
	required.raw["Data"] = required.properties.map(func(prop: UAssetProperty) -> Dictionary:
		return prop.to_dict())
	var spawn := _make_export("ParticleModuleSpawn_0", 3, -5, 0, [], 0)
	spawn.properties = [UAssetProperty.from_dict(_make_float_property_raw("Rate", 120.0))]
	spawn.raw["Data"] = [spawn.properties[0].to_dict()]
	var module := _make_export("ParticleModuleSize_0", 3, -6, 0, [], 0)
	module.properties = [_make_raw_distribution_vector_property("StartSize")]
	module.raw["Data"] = [module.properties[0].to_dict()]
	var type_data := _make_export("ParticleModuleTypeDataMesh_0", 3, -7, 0, [], 0)
	type_data.properties = [
		_make_object_property("Mesh", -8),
		_make_bool_property("bCameraFacing", true),
	]
	type_data.raw["Data"] = type_data.properties.map(func(prop: UAssetProperty) -> Dictionary:
		return prop.to_dict())
	var lod_alt := _make_export("ParticleLODLevel_1", 2, -3, 0, [], 0)
	lod_alt.properties = [
		_make_object_property("RequiredModule", 9),
		_make_object_property("SpawnModule", 10),
		_make_object_property("TypeDataModule", 7),
		_make_object_array_property("Modules", "Object", [11]),
		_make_int_property("PeakActiveParticles", 9),
	]
	lod_alt.raw["Data"] = [
		lod_alt.properties[0].to_dict(),
		lod_alt.properties[1].to_dict(),
		lod_alt.properties[2].to_dict(),
		lod_alt.properties[3].to_dict(),
		lod_alt.properties[4].to_dict(),
	]
	var required_alt := _make_export("ParticleModuleRequired_1", 8, -4, 0, [], 0)
	required_alt.properties = [_make_object_property("Material", -10)]
	required_alt.raw["Data"] = [required_alt.properties[0].to_dict()]
	var spawn_alt := _make_export("ParticleModuleSpawn_1", 8, -5, 0, [], 0)
	spawn_alt.properties = [UAssetProperty.from_dict(_make_float_property_raw("Rate", 10.0))]
	spawn_alt.raw["Data"] = [spawn_alt.properties[0].to_dict()]
	var module_alt := _make_export("ParticleModuleSize_1", 8, -6, 0, [], 0)
	module_alt.properties = [_make_raw_distribution_vector_property("StartSize")]
	module_alt.raw["Data"] = [module_alt.properties[0].to_dict()]
	var spawn_distribution := _make_export("RequiredDistributionSpawnRate", 10, -12, 0, [], 0)
	asset.exports = [
		system,
		emitter,
		lod,
		required,
		spawn,
		module,
		type_data,
		lod_alt,
		required_alt,
		spawn_alt,
		module_alt,
		spawn_distribution,
	]

	_expect(ParticleEffectDetail.is_particle_export(asset, module),
		"particle module export is detected for VFX detail view")
	var non_particle := _make_export("StaticMeshWithVec", 2, -8, 0, [
		_make_raw_distribution_vector_property("BoundsVec")
	], 0)
	non_particle.properties[0].struct_type = "Vector"
	_expect(not ParticleEffectDetail.is_particle_export(asset, non_particle),
		"plain vector exports do not get routed to the particle detail view")

	var context := _make_clipboard_context(asset)
	var panel := VBoxContainer.new()
	var detail := ParticleEffectDetail.new().init_data(lod).setup(context)
	detail.build_detail(panel)
	_expect(_has_label_text(panel, "Particle/VFX Inspector"),
		"particle detail builds the inspector header")
	_expect(_has_label_text(panel, "VFX PREVIEW"),
		"particle detail builds the VFX preview section")
	var preview_particles := _find_first_cpu_particles(panel)
	_expect(preview_particles != null,
		"particle detail creates a Godot CPUParticles3D preview emitter")
	_expect(preview_particles != null and preview_particles.amount == 4,
		"particle preview respects the emitter PeakActiveParticles count")
	_expect(preview_particles != null and preview_particles.mesh is SphereMesh,
		"mesh particle preview uses a 3D mesh placeholder while the real mesh loads")
	_expect(preview_particles != null
			and str(preview_particles.get_meta("preview_mesh_path", "")).ends_with(
				"/g3/Content/VFX/Meshes/TestMesh.uasset"),
		"mesh particle preview resolves imported mesh package paths")
	_expect(preview_particles != null
			and str(preview_particles.get_meta("preview_material_name", "")).contains("TestMaterial"),
		"mesh particle preview records the referenced material override")
	_expect(preview_particles != null
			and str(preview_particles.get_meta("preview_screen_alignment", "")) == "PSA_Velocity",
		"particle preview records Cascade screen alignment")
	_expect(preview_particles != null
			and bool(preview_particles.get_meta("preview_mesh_billboard", false))
			and bool(preview_particles.get_meta("preview_align_to_velocity", false)),
		"particle preview maps velocity-aligned mesh cards to Godot billboard flags")
	_expect(_count_cpu_particles(panel) == 1,
		"particle preview creates one emitter preview for the selected LOD owner")
	_expect(_has_label_text(panel, "ParticleSpriteEmitter_0"),
		"particle detail groups modules under the real particle emitter")
	_expect(_has_label_text(panel, "StartSize [RawDistributionVector]"),
		"particle detail surfaces raw distribution vectors as readable sections")
	_expect(_has_label_text(panel, "MinValueVec"),
		"particle detail renders vector distribution fields inline")
	panel.free()

	var distribution_panel := VBoxContainer.new()
	var distribution_detail := ParticleEffectDetail.new().init_data(spawn_distribution).setup(context)
	distribution_detail.build_detail(distribution_panel)
	var distribution_preview := _find_first_cpu_particles(distribution_panel)
	_expect(distribution_preview != null and distribution_preview.amount == 9,
		"particle preview resolves distribution exports back to their owning LOD")
	_expect(_has_label_text(distribution_panel, "LODLevel  ParticleLODLevel_1"),
		"particle detail shows the LOD stack that owns the selected distribution")
	distribution_panel.free()


func _test_mesh_preview_materials() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_mesh_material_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	FileUtils.write_bytes_atomic(root.path_join("Body.mat"),
		"Diffuse=BodyColor\nNormal=BodyNormal\n".to_utf8_buffer())
	FileUtils.write_bytes_atomic(root.path_join("Body.props.txt"),
		("BlendMode = BLEND_Masked (1)\n" +
		"TwoSided = true\n").to_utf8_buffer())
	var color_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(0.2, 0.4, 0.8, 1.0))
	color_image.save_png(root.path_join("BodyColor.png"))
	var normal_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	normal_image.fill(Color(0.5, 0.5, 1.0, 1.0))
	normal_image.save_png(root.path_join("BodyNormal.png"))

	var source_material := StandardMaterial3D.new()
	source_material.resource_name = "Body"
	var quad := QuadMesh.new()
	quad.material = source_material
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = quad
	var result := MeshPreviewMaterialLoader.apply_to_scene(mesh_instance, root)
	var material := mesh_instance.get_surface_override_material(0) as StandardMaterial3D
	_expect(result["applied"] == 1 and material != null,
		"mesh preview reconstructs an exported material slot")
	_expect(material.albedo_texture != null and material.normal_texture != null,
		"mesh preview attaches diffuse and normal textures")
	_expect(material.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"mesh preview preserves two-sided material metadata")
	mesh_instance.free()
	FileUtils.remove_dir_recursive(root)


func _test_glb_export() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_glb_export_%d" % Time.get_ticks_usec())
	var out_dir := root.path_join("out")
	DirAccess.make_dir_recursive_absolute(root)
	FileUtils.write_bytes_atomic(root.path_join("Body.mat"),
		"Diffuse=BodyColor\n".to_utf8_buffer())
	var color_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(0.8, 0.2, 0.1, 1.0))
	color_image.save_png(root.path_join("BodyColor.png"))

	var scene := Node3D.new()
	var source_material := StandardMaterial3D.new()
	source_material.resource_name = "Body"
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.material = source_material
	mesh_instance.mesh = mesh
	scene.add_child(mesh_instance)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var error := doc.append_from_scene(scene, state)
	var source_path := root.path_join("SourceMesh.gltf")
	if error == OK:
		error = doc.write_to_filesystem(state, source_path)
	_expect(error == OK and FileAccess.file_exists(source_path),
		"test fixture writes a source glTF")

	var service := MeshService.new()
	var result := service._write_glb_from_gltf(source_path, out_dir)
	var glb_path := str(result.value)
	var bytes := FileAccess.get_file_as_bytes(glb_path) if FileAccess.file_exists(glb_path) else PackedByteArray()
	_expect(result.ok and glb_path.ends_with(".glb") and bytes.size() >= 4
			and bytes.slice(0, 4).get_string_from_ascii() == "glTF",
		"mesh export writes a Blender-compatible GLB")
	_expect(result.message.contains("textured material"),
		"mesh GLB export reports embedded textured materials")

	var read_doc := GLTFDocument.new()
	var read_state := GLTFState.new()
	var read_error := read_doc.append_from_file(glb_path, read_state)
	var read_scene := read_doc.generate_scene(read_state) if read_error == OK else null
	var read_mesh := _find_first_mesh_instance(read_scene) if read_scene != null else null
	var read_material := read_mesh.get_active_material(0) as StandardMaterial3D \
		if read_mesh != null else null
	_expect(read_material != null and read_material.albedo_texture != null,
		"mesh GLB export embeds reconstructed material textures")

	scene.free()
	if read_scene != null:
		read_scene.free()
	FileUtils.remove_dir_recursive(root)


func _test_md5_animation_loader() -> void:
	var md5_text := """
MD5Version 10
numFrames 2
numJoints 2
frameRate 30
numAnimatedComponents 12
hierarchy {
	"root" -1 63 0
	"hand_r" 0 63 6
}
bounds {
	( -1 -1 -1 ) ( 1 1 1 )
	( -1 -1 -1 ) ( 1 1 1 )
}
baseframe {
	( 0 0 0 ) ( 0 0 0 )
	( 0 0 0 ) ( 0 0 0 )
}
frame 0 {
	( 0 0 0 ) ( 0 0 0 )
	( 0 0 0 ) ( 0 0 0 )
}
frame 1 {
	( 100 0 0 ) ( 0 0 0 )
	( 0 50 0 ) ( 0 0 0.70710678 )
}
"""
	var parsed := Md5AnimLoader.parse_text(md5_text, "Synthetic")
	_expect(bool(parsed.get("ok", false)), "MD5 animation parser accepts umodel-style data")
	_expect(int(parsed["num_frames"]) == 2 and int(parsed["num_joints"]) == 2,
		"MD5 animation parser preserves header counts")

	var frames: Array = parsed["frames"]
	var root_frame: Dictionary = frames[1][0]
	var hand_frame: Dictionary = frames[1][1]
	_expect(_approx_vec3(root_frame["position"], Vector3(1.0, 0.0, 0.0)),
		"MD5 animation loader converts positions from centimeters to Godot axes")
	_expect(_approx_vec3(hand_frame["position"], Vector3(0.0, 0.0, -0.5)),
		"MD5 animation loader mirrors Unreal Y into Godot Z")

	var preview_root := Node3D.new()
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	skeleton.add_bone("root")
	skeleton.add_bone("hand_r")
	skeleton.set_bone_parent(1, 0)
	preview_root.add_child(skeleton)

	var built := Md5AnimLoader.build_animation(parsed, skeleton, preview_root, true)
	_expect(bool(built.get("ok", false)), "MD5 animation builder targets matching skeleton bones")
	var animation := built.get("animation") as Animation
	_expect(animation != null and animation.get_track_count() == 4,
		"MD5 animation builder creates position and rotation tracks per matched bone")
	if animation != null:
		_expect(str(animation.track_get_path(0)) == "Rig:root",
			"MD5 animation tracks address skeleton bones relative to the preview root")
		_expect(is_equal_approx(animation.length, 1.0 / 30.0),
			"MD5 animation length reflects frame count and frame rate")
		_expect(animation.loop_mode == Animation.LOOP_LINEAR,
			"MD5 animation builder applies requested loop mode")
	preview_root.free()

	var sparse_text := """
MD5Version 10
numFrames 1
numJoints 1
frameRate 24
numAnimatedComponents 1
hierarchy {
	"root" -1 2 0
}
baseframe {
	( 10 20 30 ) ( 0 0 0 )
}
frame 0 {
	50
}
"""
	var sparse := Md5AnimLoader.parse_text(sparse_text, "Sparse")
	_expect(bool(sparse.get("ok", false)), "MD5 animation parser accepts sparse component frames")
	var sparse_frames: Array = sparse["frames"]
	var sparse_root: Dictionary = sparse_frames[0][0]
	_expect(_approx_vec3(sparse_root["position"], Vector3(0.1, 0.3, -0.5)),
		"MD5 animation parser overlays animated components onto the base frame")

	var flat_root := Node3D.new()
	var flat_skeleton := Skeleton3D.new()
	flat_skeleton.name = "FlatRig"
	flat_skeleton.add_bone("root")
	for index in range(1, 10):
		flat_skeleton.add_bone("bone_%d" % index)
		flat_skeleton.set_bone_parent(index, index - 1)
	var flat_child_rest := Transform3D.IDENTITY
	flat_child_rest.basis = Basis(Quaternion(Vector3.FORWARD, deg_to_rad(90.0)))
	flat_skeleton.set_bone_rest(1, flat_child_rest)
	flat_root.add_child(flat_skeleton)
	var flat_joints: Array = [{"name": "root", "parent": -1, "flags": 63, "start": 0}]
	var flat_frame: Array = [{
		"position": Vector3.ZERO,
		"rotation": Quaternion(Vector3.FORWARD, deg_to_rad(10.0)),
	}]
	for index in range(1, 10):
		flat_joints.append({"name": "bone_%d" % index, "parent": 0, "flags": 63, "start": index * 6})
		flat_frame.append({
			"position": Vector3.ZERO,
			"rotation": Quaternion(Vector3.FORWARD, deg_to_rad(20.0)),
		})
	var flat_parsed := {
		"ok": true,
		"name": "Flattened",
		"num_frames": 1,
		"num_joints": flat_joints.size(),
		"frame_rate": 30.0,
		"joints": flat_joints,
		"frames": [flat_frame],
	}
	var flat_built := Md5AnimLoader.build_animation(flat_parsed, flat_skeleton, flat_root, true)
	_expect(bool(flat_built.get("ok", false)), "MD5 animation builder accepts flattened umodel hierarchy")
	var flat_animation := flat_built.get("animation") as Animation
	_expect(bool(flat_built.get("flattened_hierarchy", false)),
		"MD5 animation builder detects flattened umodel hierarchy")
	_expect(int(flat_built.get("position_bones", -1)) == 0,
		"MD5 animation builder skips child position tracks for flattened hierarchy")
	_expect(str(flat_built.get("rotation_mode", "")) == Md5AnimLoader.FLATTENED_ROTATION_LOCAL,
		"flattened MD5 animation keeps absolute local rotations when frames contain a full pose")
	if flat_animation != null:
		_expect(flat_animation.get_track_count() == flat_joints.size(),
			"flattened MD5 animation emits rotation tracks without collapsing positions")
		var local_rotation := flat_animation.track_get_key_value(1, 0) as Quaternion
		_expect(_approx_quat(local_rotation, Quaternion(Vector3.FORWARD, deg_to_rad(20.0))),
			"flattened MD5 animation preserves absolute local child rotation")

	var delta_frame: Array = [{
		"position": Vector3.ZERO,
		"rotation": Quaternion.IDENTITY,
	}]
	for index in range(1, 10):
		var rotation := Quaternion.IDENTITY
		if index == 1:
			rotation = Quaternion(Vector3.FORWARD, deg_to_rad(10.0))
		delta_frame.append({
			"position": Vector3.ZERO,
			"rotation": rotation,
		})
	var delta_parsed := {
		"ok": true,
		"name": "FlattenedDelta",
		"num_frames": 1,
		"num_joints": flat_joints.size(),
		"frame_rate": 30.0,
		"joints": flat_joints,
		"frames": [delta_frame],
	}
	var delta_built := Md5AnimLoader.build_animation(delta_parsed, flat_skeleton, flat_root, true)
	var delta_animation := delta_built.get("animation") as Animation
	_expect(str(delta_built.get("rotation_mode", "")) == Md5AnimLoader.FLATTENED_ROTATION_DELTA,
		"flattened MD5 animation detects mostly identity pose-delta rotations")
	if delta_animation != null:
		var delta_rotation := delta_animation.track_get_key_value(1, 0) as Quaternion
		var expected_delta_rotation := flat_child_rest.basis.get_rotation_quaternion() * Quaternion(
			Vector3.FORWARD, deg_to_rad(10.0))
		_expect(_approx_quat(delta_rotation, expected_delta_rotation),
			"flattened MD5 animation composes pose-delta rotations with target rest rotation")
	flat_root.free()


func _test_animation_candidate_discovery() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_anim_candidates_%d" % Time.get_ticks_usec())
	var mod_root := root.path_join("Mods/TestMod")
	var source_root := root.path_join("Unchanged")
	var mesh_path := mod_root.path_join("g3/Content/Characters/Human/Hero/HeroBody.uasset")
	var idle_path := source_root.path_join("g3/Content/Characters/Human/Animations/Female_Idle_Breathing.uasset")
	var attack_path := source_root.path_join("g3/Content/Characters/Human/Animations/Combat/FireballAttackToIdleR.uasset")
	var anim_bp_path := source_root.path_join("g3/Content/Characters/Human/Animations/Human_AnimBlueprint.uasset")
	var blueprint_path := source_root.path_join("g3/Content/Characters/Human/Animations/BP_NotAnAnimation.uasset")
	for path in [mesh_path, idle_path, attack_path, anim_bp_path, blueprint_path]:
		FileUtils.write_bytes_atomic(path, "asset".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Base", "path": source_root}]
	var service := MeshService.new().setup(config)
	var candidates := service.find_animation_assets_for_mesh(mesh_path, 20)
	_expect(idle_path in candidates and attack_path in candidates,
		"animation discovery finds likely source animations for a human skeletal mesh")
	_expect(not anim_bp_path in candidates and not blueprint_path in candidates,
		"animation discovery filters animation blueprints and regular blueprints")
	_expect(candidates.find(idle_path) < candidates.find(attack_path),
		"animation discovery ranks idle animations before attack candidates")
	FileUtils.remove_dir_recursive(root)


func _test_texture_injection_preserves_companions() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_tex_install_%d" % Time.get_ticks_usec())
	var original_dir := root.path_join("original")
	var staged_dir := root.path_join("staged")
	var output_dir := root.path_join("output")
	DirAccess.make_dir_recursive_absolute(original_dir)
	DirAccess.make_dir_recursive_absolute(staged_dir)
	DirAccess.make_dir_recursive_absolute(output_dir)

	var original_uasset := original_dir.path_join("Texture.uasset")
	var original_uexp := original_dir.path_join("Texture.uexp")
	var original_ubulk := original_dir.path_join("Texture.ubulk")
	FileUtils.write_bytes_atomic(original_uasset, "old-uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(original_uexp, "old-uexp".to_utf8_buffer())
	FileUtils.write_bytes_atomic(original_ubulk, "old-ubulk".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uasset"), "new-uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uexp"), "new-uexp".to_utf8_buffer())

	var service := TextureService.new()
	var collected := service._collect_injected_texture_files(
		original_uasset, staged_dir, original_dir, "Texture")
	_expect(bool(collected.get("ok", false)),
		"texture injection collects generated files for in-place install")
	var install_error := FileUtils.install_staged_files(collected["files"])
	_expect(install_error == OK, "texture injection staged install succeeds")
	_expect(FileAccess.get_file_as_string(original_uasset) == "new-uasset",
		"texture injection replaces generated uasset")
	_expect(FileAccess.get_file_as_string(original_uexp) == "new-uexp",
		"texture injection replaces generated uexp")
	_expect(FileAccess.get_file_as_string(original_ubulk) == "old-ubulk",
		"texture injection preserves existing ubulk when injector omits it")

	staged_dir = root.path_join("staged_external")
	DirAccess.make_dir_recursive_absolute(staged_dir)
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uasset"), "external-uasset".to_utf8_buffer())
	collected = service._collect_injected_texture_files(original_uasset, staged_dir, output_dir, "Texture")
	_expect(bool(collected.get("ok", false)),
		"texture injection collects preserved companions for alternate output")
	install_error = FileUtils.install_staged_files(collected["files"])
	_expect(install_error == OK, "texture injection alternate output install succeeds")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.uasset")) == "external-uasset",
		"texture injection writes generated uasset to alternate output")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.uexp")) == "new-uexp",
		"texture injection copies original uexp to alternate output when omitted")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.ubulk")) == "old-ubulk",
		"texture injection copies original ubulk to alternate output when omitted")
	FileUtils.remove_dir_recursive(root)


func _test_texture_companion_recovery() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_tex_recover_%d" % Time.get_ticks_usec())
	var mod_dir := root.path_join("Mods/TestMod")
	var source_dir := root.path_join("Unchanged")
	var relative := "g3/Content/Characters/Human/Test/Texture"
	DirAccess.make_dir_recursive_absolute(mod_dir.path_join(relative.get_base_dir()))
	DirAccess.make_dir_recursive_absolute(source_dir.path_join(relative.get_base_dir()))

	var uasset_path := mod_dir.path_join(relative + ".uasset")
	var source_ubulk := source_dir.path_join(relative + ".ubulk")
	var target_ubulk := mod_dir.path_join(relative + ".ubulk")
	FileUtils.write_bytes_atomic(uasset_path, "uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(source_ubulk, "source-ubulk".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Base", "path": source_dir}]
	var service := TextureService.new().setup(config)
	var recovered := service._restore_missing_texture_companions(uasset_path)
	_expect(bool(recovered.get("ok", false)),
		"texture recovery succeeds when a configured source has the missing companion")
	_expect(FileAccess.get_file_as_string(target_ubulk) == "source-ubulk",
		"texture recovery restores missing ubulk before DDS tools read the package")
	FileUtils.remove_dir_recursive(root)


func _test_mesh_animation_controls_build() -> void:
	var detail := MeshDetail.new()
	var container := VBoxContainer.new()
	detail._container = container
	detail._preview_scene = Node3D.new()
	detail._preview_skeleton = Skeleton3D.new()
	detail._preview_skeleton.add_bone("root")
	detail._set_animation_controls_ready(true)
	detail._build_animation_controls()
	detail._set_animation_controls_ready(detail._preview_skeleton != null)
	_expect(container.get_child_count() > 0,
		"mesh animation controls build without runtime property errors")
	_expect(not detail._anim_auto_btn.disabled and not detail._anim_load_btn.disabled,
		"mesh animation controls enable when cached mesh preview already found a skeleton")
	_expect(detail._anim_speed_spin is SpinBox and not detail._anim_speed_spin.editable,
		"mesh animation speed control starts read-only")
	_expect(detail._anim_slider is HSlider and not detail._anim_slider.editable,
		"mesh animation scrub control starts read-only")
	detail._set_animation_loaded(true)
	_expect(detail._anim_speed_spin.editable,
		"mesh animation speed control becomes editable when animation is loaded")
	_expect(detail._anim_slider.editable,
		"mesh animation scrub control becomes editable when animation is loaded")
	detail._set_animation_loaded(false)
	_expect(not detail._anim_speed_spin.editable,
		"mesh animation speed control returns to read-only when animation is cleared")
	_expect(not detail._anim_slider.editable,
		"mesh animation scrub control returns to read-only when animation is cleared")
	detail._preview_skeleton.set_bone_pose_rotation(0, Quaternion(Vector3.FORWARD, deg_to_rad(20.0)))
	detail._reset_preview_skeleton_pose()
	_expect(_approx_quat(detail._preview_skeleton.get_bone_pose_rotation(0), Quaternion.IDENTITY),
		"mesh animation preview resets stale bone poses before loading another animation")
	detail._preview_scene.free()
	container.free()


func _test_mesh_preview_environment() -> void:
	var detail := MeshDetail.new()
	var root := Node3D.new()
	detail._add_preview_environment(root)

	var world_env: WorldEnvironment = null
	var key_light: DirectionalLight3D = null
	var light_count := 0
	for child in root.get_children():
		if child is WorldEnvironment:
			world_env = child
		elif child is DirectionalLight3D:
			light_count += 1
			if key_light == null:
				key_light = child

	var sky_material: ProceduralSkyMaterial = null
	if world_env != null and world_env.environment.sky is Sky:
		sky_material = (world_env.environment.sky as Sky).sky_material as ProceduralSkyMaterial

	_expect(world_env != null
			and world_env.environment.background_mode == Environment.BG_SKY
			and sky_material != null,
		"mesh preview environment uses Godot's preview sky background")
	_expect(world_env != null
			and world_env.environment.tonemap_mode == Environment.TONE_MAPPER_FILMIC
			and not world_env.environment.ssao_enabled
			and not world_env.environment.sdfgi_enabled,
		"mesh preview environment matches Godot's default preview effects")
	_expect(sky_material != null
			and _approx_color(sky_material.sky_top_color, Color(0.385, 0.454, 0.55))
			and _approx_color(sky_material.ground_bottom_color, Color(0.2, 0.169, 0.133)),
		"mesh preview environment uses Godot's default preview sky colors")
	_expect(light_count == 1
			and key_light != null
			and key_light.shadow_enabled
			and key_light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			and _approx_float(key_light.directional_shadow_max_distance, 100.0)
			and _approx_float(key_light.rotation.x, deg_to_rad(-60.0))
			and _approx_float(key_light.rotation.y, deg_to_rad(150.0)),
		"mesh preview environment uses Godot's default preview sun")
	root.free()


func _test_background_job_shutdown() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_job_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var marker := root.path_join("finished.txt")
	var runner := BackgroundJobRunner.new()
	var job_id := runner.run(func() -> bool:
		OS.delay_msec(10)
		return FileUtils.write_bytes_atomic(marker, "done".to_utf8_buffer()) == OK,
		Callable())
	_expect(job_id >= 0, "background runner accepts work")
	runner.wait_to_finish()
	_expect(FileAccess.get_file_as_string(marker) == "done",
		"background runner joins active work during shutdown")
	FileUtils.remove_dir_recursive(root)


func _test_file_watcher_rapid_toggle() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_watch_%d" % Time.get_ticks_usec())
	var mods_dir := root.path_join("Mods")
	var game_dir := root.path_join("Game")
	DirAccess.make_dir_recursive_absolute(mods_dir.path_join("TestMod/g3/Content"))
	DirAccess.make_dir_recursive_absolute(game_dir.path_join("g3/Content/Paks"))

	var config := ModConfigManager.new()
	config.mods_dir = mods_dir
	config.game_dir = game_dir
	var state := ModStateManager.new().setup(root.path_join(".mod_state.json"))
	state.set_enabled("TestMod", true)
	var packer := PackingService.new().setup(config)
	var watcher := ModFileWatcher.new().setup(config, state, packer)

	var started := Time.get_ticks_msec()
	watcher.start()
	watcher.stop()
	watcher.start()
	watcher.stop()
	watcher.wait_to_finish()
	var elapsed := Time.get_ticks_msec() - started

	_expect(not watcher.is_watching(),
		"file watcher stops after rapid start/stop/start/stop")
	_expect(elapsed < 1000,
		"file watcher rapid toggle does not block for the full poll interval")
	FileUtils.remove_dir_recursive(root)


func _test_file_watcher_detects_same_size_save() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_watch_content_%d" % Time.get_ticks_usec())
	var mods_dir := root.path_join("Mods")
	var mod_content := mods_dir.path_join("TestMod/g3/Content")
	DirAccess.make_dir_recursive_absolute(mod_content)
	var asset_path := mod_content.path_join("Effect.uasset")
	FileUtils.write_bytes_atomic(asset_path, "AAAA".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = mods_dir
	var state := ModStateManager.new().setup(root.path_join(".mod_state.json"))
	state.set_enabled("TestMod", true)
	var packer := WatcherTestPacker.new()
	var watcher := ModFileWatcher.new().setup(config, state, packer)

	var before_digest := watcher._file_content_digest(asset_path)
	var before_snapshot := watcher._snapshot()
	FileUtils.write_bytes_atomic(asset_path, "BBBB".to_utf8_buffer())
	var after_digest := watcher._file_content_digest(asset_path)
	var after_snapshot := watcher._snapshot()

	_expect(before_digest != after_digest,
		"file watcher content digest changes for same-size saves")
	_expect(before_snapshot != after_snapshot,
		"file watcher snapshot changes for same-size saved asset content")
	FileUtils.remove_dir_recursive(root)


func _test_file_watcher_deferred_pack_starts_packer() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_watch_pack_%d" % Time.get_ticks_usec())
	var mods_dir := root.path_join("Mods")
	var mod_path := mods_dir.path_join("TestMod")
	DirAccess.make_dir_recursive_absolute(mod_path.path_join("g3/Content"))

	var config := ModConfigManager.new()
	config.mods_dir = mods_dir
	var state := ModStateManager.new().setup(root.path_join(".mod_state.json"))
	var packer := WatcherTestPacker.new()
	var watcher := ModFileWatcher.new().setup(config, state, packer)
	var triggered: Array[int] = []
	watcher.pack_triggered.connect(func(n: int) -> void: triggered.append(n))

	watcher._emit_pack_triggered_and_pack(4, [ModInfo.new("TestMod", mod_path)])

	_expect(triggered == [4], "file watcher emits pack-trigger status before auto-pack")
	_expect(packer.pack_calls == 1
			and packer.last_mods.size() == 1
			and (packer.last_mods[0] as ModInfo).name == "TestMod",
		"file watcher deferred callback starts the packer with enabled mods")
	FileUtils.remove_dir_recursive(root)


func _test_atomic_file_install() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_files_%d" % Time.get_ticks_usec())
	var target_dir := root.path_join("destination")
	var staging_dir := root.path_join("independent-staging")
	DirAccess.make_dir_recursive_absolute(target_dir)
	DirAccess.make_dir_recursive_absolute(staging_dir)
	var target := target_dir.path_join("target.bin")
	var staged := staging_dir.path_join("staged.bin")
	var obsolete := target_dir.path_join("obsolete.bin")
	FileUtils.write_bytes_atomic(target, "old".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged, "new".to_utf8_buffer())
	FileUtils.write_bytes_atomic(obsolete, "stale".to_utf8_buffer())
	var error := FileUtils.install_staged_files(
		[{"source": staged, "target": target}], [obsolete])
	_expect(error == OK, "atomic file install succeeds")
	_expect(FileAccess.get_file_as_string(target) == "new", "atomic file install replaces content")
	_expect(not FileAccess.file_exists(staged), "atomic file install consumes staged file")
	_expect(not FileAccess.file_exists(obsolete), "atomic file install removes obsolete companions")

	staged = staging_dir.path_join("staged-again.bin")
	FileUtils.write_bytes_atomic(staged, "newer".to_utf8_buffer())
	var result := FileUtils.install_staged_files_with_result(
		[{"source": staged, "target": target}], [], true, "restore")
	_expect(int(result.get("error", ERR_BUG)) == OK,
		"atomic file install can keep a persistent restore backup")
	var backups: Array = result.get("backups", [])
	_expect(backups.size() == 1 and FileAccess.file_exists(str(backups[0]["backup"])),
		"persistent restore backup is kept after successful install")
	if backups.size() == 1:
		_expect(FileAccess.get_file_as_string(str(backups[0]["backup"])) == "new",
			"persistent restore backup contains the replaced content")
	_expect(FileAccess.get_file_as_string(target) == "newer",
		"persistent-backup install still replaces content")
	if backups.size() == 1:
		var restore_error := FileUtils.restore_backup(backups[0])
		_expect(restore_error == OK and FileAccess.get_file_as_string(target) == "new",
			"persistent restore backup can restore replaced content")
	FileUtils.remove_dir_recursive(root)


func _test_mod_manifest() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_manifest_%d" % Time.get_ticks_usec())
	var source_root := root.path_join("Source")
	var mod_path := root.path_join("Mods/TestMod")
	var source_file := source_root.path_join("g3/Content/Items/Test.uasset")
	var target_file := mod_path.path_join("g3/Content/Items/Test.uasset")
	var manual_file := mod_path.path_join("g3/Content/Items/Manual.uexp")
	FileUtils.write_bytes_atomic(source_file, "asset".to_utf8_buffer())
	FileUtils.copy_file(source_file, target_file)
	FileUtils.write_bytes_atomic(manual_file, "manual".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Source", "path": source_root}]
	var mod := ModInfo.new("TestMod", mod_path)
	var error := ModManifest.record_copied_files(mod, source_root, [source_file], config)
	_expect(error == OK and FileAccess.file_exists(ModManifest.manifest_path(mod)),
		"mod manifest is written after copied files are recorded")

	var manifest: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(ModManifest.manifest_path(mod)))
	var by_target := {}
	for entry: Dictionary in manifest.get("files", []):
		by_target[str(entry.get("target", ""))] = entry
	_expect(by_target.has("g3/Content/Items/Test.uasset"),
		"mod manifest records copied target path")
	_expect(by_target.has("g3/Content/Items/Manual.uexp"),
		"mod manifest snapshots manually present target path")
	var copied_entry: Dictionary = by_target.get("g3/Content/Items/Test.uasset", {})
	var source_info: Dictionary = copied_entry.get("source", {})
	_expect(str(source_info.get("path", "")) == source_file,
		"mod manifest preserves copied file source path")
	_expect(str(manifest.get("build", {}).get("content_root", "")) == "g3",
		"mod manifest records build content root")

	var clone_file := mod_path.path_join("g3/Content/Items/TestUniqueLongName.uasset")
	FileUtils.write_bytes_atomic(clone_file, "clone".to_utf8_buffer())
	var described := ModManifest.describe_unique_clone(source_file, clone_file, config)
	_expect(described.ok
			and str(described.value.get("source", "")) == "/Game/Items/Test.Test"
			and str(described.value.get("target", ""))
				== "/Game/Items/TestUniqueLongName.TestUniqueLongName",
		"unique clone derives source and target ObjectPaths from workspace paths")
	var recorded := ModManifest.record_unique_clone(described.value, config)
	manifest = JSON.parse_string(
			FileAccess.get_file_as_string(ModManifest.manifest_path(mod)))
	var custom_assets: Array = manifest.get("custom_assets", [])
	_expect(recorded.ok and custom_assets.size() == 1
			and str(custom_assets[0].get("file", ""))
				== "g3/Content/Items/TestUniqueLongName.uasset",
		"unique clone is persisted in the existing workspace manifest")
	_expect(not ModManifest.describe_unique_clone(
			source_file, root.path_join("Outside.uasset"), config).ok,
		"unique clone refuses destinations outside a mod workspace")

	DirAccess.remove_absolute(clone_file)
	var pruned_error := ModManifest.write_workspace_manifest(mod, config)
	manifest = JSON.parse_string(
			FileAccess.get_file_as_string(ModManifest.manifest_path(mod)))
	_expect(pruned_error == OK
			and manifest.get("custom_assets", []).is_empty(),
		"deleting a unique clone's package prunes its registry declaration")
	FileUtils.remove_dir_recursive(root)


func _test_mod_discovery_models_and_symlinks() -> void:
	var root := OS.get_temp_dir().path_join(
			"sb_test_discovery_%d" % Time.get_ticks_usec())
	var mods_dir := root.path_join("Mods")
	var mod_path := mods_dir.path_join("TypedMod")
	var asset_path := mod_path.path_join("g3/Content/Real.uasset")
	var outside_path := root.path_join("Outside/g3/Content/Outside.uasset")
	FileUtils.write_bytes_atomic(asset_path, "asset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(outside_path, "outside".to_utf8_buffer())

	var discovered := ModDiscovery.scan(mods_dir)
	_expect(discovered.size() == 1 and discovered[0] is ModInfo
			and discovered[0].name == "TypedMod",
		"mod discovery returns typed mod metadata")
	var files := ModDiscovery.list_mod_file_entries(mod_path)
	_expect(files.size() == 1 and files[0] is ModFileEntry
			and files[0].relative_path == "g3/Content/Real.uasset",
		"mod discovery returns typed file entries")

	var root_dir := DirAccess.open(root)
	if root_dir != null:
		var mod_link := mods_dir.path_join("LinkedMod")
		var outside_mod := outside_path.get_base_dir().get_base_dir().get_base_dir()
		var mod_link_error := root_dir.create_link(outside_mod, mod_link)
		if mod_link_error == OK:
			_expect(ModDiscovery.scan(mods_dir).size() == 1,
					"mod discovery rejects symlinked mod workspaces")
		var file_link := mod_path.path_join("g3/Content/Linked.uasset")
		var file_link_error := root_dir.create_link(outside_path, file_link)
		if file_link_error == OK:
			_expect(ModDiscovery.list_mod_file_entries(mod_path).size() == 1,
					"mod discovery rejects symlinked files")
	FileUtils.remove_dir_recursive(root)


func _test_clone_helpers() -> void:
	var mod := ModInfo.new("TestMod", "/tmp/clone_mod")
	var destination := ModManagerPanel._clone_destination_path(
			mod, "g3/Content/Items/BP_Thing.uasset", "BP_ThingSkin")
	_expect(destination == "/tmp/clone_mod/g3/Content/Items/BP_ThingSkin.uasset",
		"clone destination mirrors the source directory with the new name")
	_expect(ModManagerPanel._clone_destination_path(mod, "g3/Content/BP_A.uasset", "") == "",
		"clone destination is empty without a clone name")
	_expect(ModManagerPanel._valid_clone_name("BP_ThingSkin", "BP_Thing"),
		"clone name validation accepts a plain identifier")
	_expect(ModManagerPanel._valid_clone_name("BP_Thing_6", "BP_Thing"),
		"clone name validation accepts trailing FName-style numbers")
	_expect(not ModManagerPanel._valid_clone_name("BP_Thing", "BP_Thing"),
		"clone name validation rejects the source name itself")
	_expect(not ModManagerPanel._valid_clone_name("9Lives", "BP_Thing"),
		"clone name validation rejects names starting with a digit")
	_expect(not ModManagerPanel._valid_clone_name("Bad.Name", "BP_Thing"),
		"clone name validation rejects dots")
	_expect(not ModManagerPanel._valid_clone_name("", "BP_Thing"),
		"clone name validation rejects an empty name")


func _test_mod_preflight() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_preflight_%d" % Time.get_ticks_usec())
	var mod_path := root.path_join("Mods/TestMod")
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Good.uasset"),
			"asset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Good.uexp"),
			"companion".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Orphan.uexp"),
			"orphan".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Loose.bin"),
			"loose".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	var issues := ModPreflight.validate_mod_for_pack(ModInfo.new("TestMod", mod_path), config)
	_expect(ModPreflight.error_count(issues) >= 1,
		"mod preflight reports orphan package companion as an error")
	_expect(ModPreflight.warning_count(issues) >= 1,
		"mod preflight reports unusual loose files as warnings")
	FileUtils.remove_dir_recursive(root)


func _test_uasset_save_validation() -> void:
	var asset := _make_asset()
	_expect(asset.validate_for_save().is_empty(),
		"uasset save validation accepts valid package indices")
	asset.exports[0].class_index = -99
	var issues := asset.validate_for_save()
	_expect(not issues.is_empty()
			and "Invalid package index" in str(issues[0].get("message", "")),
		"uasset save validation rejects invalid package indices")


func _test_path_safety() -> void:
	_expect(FileUtils.is_path_within("/mods/example/Content/a.uasset", "/mods/example"),
		"path containment accepts descendants")
	_expect(not FileUtils.is_path_within("/mods/example2/a.uasset", "/mods/example"),
		"path containment rejects prefix collisions")
	_expect(not FileUtils.is_path_within("/mods/example/../outside", "/mods/example"),
		"path containment rejects parent traversal")
	_expect(FileUtils.is_safe_filename("My Mod") and not FileUtils.is_safe_filename("../outside"),
		"folder name validation rejects path components")


func _test_process_arguments() -> void:
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb test's args %d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var script := root.path_join("print_args.py")
	FileUtils.write_bytes_atomic(script,
		"import os, sys\nprint(os.getcwd())\nprint(sys.argv[1])\n".to_utf8_buffer())
	var output: Array = []
	var argument := "value with spaces and 'quotes'"
	var code := ProcessUtils.run_python_script(python, script, root, [argument], output)
	var text := ProcessUtils.output_text(output, "")
	_expect(code == 0, "Python working-directory wrapper succeeds")
	_expect(root.get_file() in text and argument in text,
		"subprocess paths and arguments are passed literally")
	FileUtils.remove_dir_recursive(root)

	var launch := ProcessUtils.parse_command_line(
			"\"C:\\Games\\Spellbreak CE\\Spellbreak.exe\" -log \"value with spaces\"")
	_expect(launch.size() == 3
			and launch[0] == "C:\\Games\\Spellbreak CE\\Spellbreak.exe"
			and launch[1] == "-log"
			and launch[2] == "value with spaces",
			"launch command parser preserves quoted Windows paths and arguments")


func _test_base_source_generation() -> void:
	if ProcessUtils.find_python().is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb_test_base_source_%d" % Time.get_ticks_usec())
	var tool_dir := root.path_join("u4pak")
	var output_dir := root.path_join("source")
	var pak_path := root.path_join("Game.pak")
	DirAccess.make_dir_recursive_absolute(tool_dir)
	FileUtils.write_bytes_atomic(pak_path, "fake pak".to_utf8_buffer())
	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import os, sys\n"
			+ "args = sys.argv[1:]\n"
			+ "if args[0] == 'list':\n"
			+ "    print('g3/Content/TestAsset.uasset')\n"
			+ "    raise SystemExit(0)\n"
			+ "if args[0] == 'unpack' and args[1] == '-C':\n"
			+ "    out = args[2]\n"
			+ "    target = os.path.join(out, 'g3', 'Content', 'TestAsset.uasset')\n"
			+ "    os.makedirs(os.path.dirname(target), exist_ok=True)\n"
			+ "    open(target, 'wb').write(b'data')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(9)\n"
	).to_utf8_buffer())

	var config := ModConfigManager.new()
	config.u4pak_dir = tool_dir
	var service := BaseSourceService.new().setup(config)
	var result := service._do_generate(pak_path, output_dir)
	_expect(result.ok, "base source generation succeeds with u4pak unpack")
	_expect(DirAccess.dir_exists_absolute(output_dir.path_join("g3/Content")),
		"base source generation creates the configured content root")
	_expect(result.metadata.get("source_name") == "Base Game (Game)",
		"base source generation returns a useful source name")
	_expect(result.metadata.get("source_path") == output_dir,
		"base source generation returns the output folder as source path")

	var fallback_dir := root.path_join("fallback_source")
	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import os, sys\n"
			+ "args = sys.argv[1:]\n"
			+ "if args[0] == 'list':\n"
			+ "    if '--ignore-magic' in args and '--force-version=3' in args:\n"
			+ "        print('g3/Content/FallbackAsset.uasset')\n"
			+ "        raise SystemExit(0)\n"
			+ "    print('illegal file magic: 0x00000000')\n"
			+ "    raise SystemExit(1)\n"
			+ "if args[0] == 'unpack':\n"
			+ "    if '--ignore-magic' not in args or '--force-version=3' not in args:\n"
			+ "        raise SystemExit(8)\n"
			+ "    out = args[args.index('-C') + 1]\n"
			+ "    target = os.path.join(out, 'g3', 'Content', 'FallbackAsset.uasset')\n"
			+ "    os.makedirs(os.path.dirname(target), exist_ok=True)\n"
			+ "    open(target, 'wb').write(b'data')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(9)\n"
	).to_utf8_buffer())
	var fallback_result := service._do_generate(pak_path, fallback_dir)
	_expect(fallback_result.ok,
		"base source generation retries pak parsing with profile archive flags")
	_expect(FileAccess.file_exists(fallback_dir.path_join("g3/Content/FallbackAsset.uasset")),
		"base source generation reuses fallback flags for unpack")

	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import sys\n"
			+ "if sys.argv[1] == 'list':\n"
			+ "    print('../Outside.uasset')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(0)\n"
	).to_utf8_buffer())
	var unsafe_result := service._do_generate(pak_path, root.path_join("unsafe_source"))
	_expect(not unsafe_result.ok, "base source generation rejects unsafe pak paths")

	FileUtils.remove_dir_recursive(root)


func _test_packing_transaction() -> void:
	if ProcessUtils.find_python().is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb_test_pack_%d" % Time.get_ticks_usec())
	var game_dir := root.path_join("game")
	var paks_dir := game_dir.path_join("g3/Content/Paks")
	var mod_dir := root.path_join("mods/TestMod")
	DirAccess.make_dir_recursive_absolute(paks_dir)
	FileUtils.write_bytes_atomic(mod_dir.path_join("g3/Content/example.bin"), "payload".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.game_dir = game_dir
	config.mods_dir = root.path_join("mods")
	config.u4pak_dir = ProjectSettings.globalize_path("res://u4pak")
	var packer := PackingService.new().setup(config)
	var mod := ModInfo.new("TestMod", mod_dir)
	var result := packer._do_pack([mod])
	var pak_path := paks_dir.path_join("zzz_mods_P.pak")
	_expect(result.ok and FileAccess.file_exists(pak_path), "u4pak integration produces a pak")
	FileUtils.write_bytes_atomic(paks_dir.path_join("Game.sig"), "sig-template".to_utf8_buffer())

	FileUtils.write_bytes_atomic(mod_dir.path_join("g3/Content/example.bin"), "payload2".to_utf8_buffer())
	var second_result := packer._do_pack([mod])
	_expect(second_result.ok and not "Backup" in second_result.message
		and second_result.backups.is_empty(),
		"repacking does not retain backups by default")

	config.keep_pack_backups = true
	FileUtils.write_bytes_atomic(mod_dir.path_join("g3/Content/example.bin"), "payload3".to_utf8_buffer())
	var backup_result := packer._do_pack([mod])
	_expect(backup_result.ok and "Backup" in backup_result.message
		and backup_result.backups.size() == 2,
		"repacking retains pak and sig backups when enabled")

	var export_path := root.path_join("exports/TestMod.pak")
	var export_result := packer._do_pack_to_path([mod], export_path)
	_expect(export_result.ok
			and FileAccess.file_exists(export_path)
			and FileAccess.file_exists(export_path.get_basename() + ".sig"),
		"middle-click mod export writes chosen pak and sibling sig")
	_expect(FileAccess.get_file_as_string(export_path.get_basename() + ".sig") == "sig-template",
		"middle-click mod export copies the game signature template")

	if FileAccess.file_exists(pak_path):
		var previous := FileAccess.get_file_as_bytes(pak_path)
		var failing_tool_dir := root.path_join("failing_u4pak")
		DirAccess.make_dir_recursive_absolute(failing_tool_dir)
		FileUtils.write_bytes_atomic(failing_tool_dir.path_join("u4pak.py"),
			"raise SystemExit(7)\n".to_utf8_buffer())
		config.u4pak_dir = failing_tool_dir
		var failed_result := packer._do_pack([mod])
		_expect(not failed_result.ok, "packing reports subprocess failure")
		_expect(FileAccess.get_file_as_bytes(pak_path) == previous,
			"failed packing preserves the previously installed pak")

	FileUtils.remove_dir_recursive(root)


func _make_empty_asset(path: String = "") -> UAssetFile:
	var asset := UAssetFile.new()
	asset.raw = {}
	asset.file_path = path
	asset.binary_path = path
	asset.name_map = PackedStringArray()
	asset.imports = []
	asset.exports = []
	return asset


func _make_clipboard_context(asset: UAssetFile, detail_stack: Array = []) -> AssetEditorContext:
	var context := AssetEditorContext.new()
	context.document = AssetDocument.new(asset)
	context.selection = SelectionManager.new()
	context.detail_stack = detail_stack
	context.rebuild_tree = func() -> void: pass
	context.show_detail = func(_data: Variant) -> void: pass
	context.refresh_tree_item = func(_data: Variant) -> void: pass
	context.select_tree_item = func(_data: Variant) -> void: pass
	return context


func _make_asset() -> UAssetFile:
	var asset := UAssetFile.new()
	asset.raw = {}
	asset.name_map = PackedStringArray(["One", "Two", "Three"])
	asset.imports = [
		_make_import("Import1", 2),
		_make_import("Import2", -1),
		_make_import("Import3", -2),
	]
	asset.exports = [
		_make_export("Export1", 2, -2, 0, [2, 3, -2], 3),
		_make_export("Export2", 1, -1, 0, [1], 1),
		_make_export("Export3", 1, -3, 0, [1, -3], 1),
	]
	return asset


func _make_datatable_export(name: String, rows: Array) -> UAssetExport:
	return UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.DataTableExport, UAssetAPI",
		"ObjectName": name,
		"OuterIndex": 0,
		"ClassIndex": 0,
		"SuperIndex": 0,
		"TemplateIndex": 0,
		"SerialSize": 0,
		"SerialOffset": 0,
		"CreateBeforeCreateDependencies": [],
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Table": {"Data": rows},
		"Data": [],
	})


func _make_datatable_row_raw(name: String, value: int) -> Dictionary:
	return {
		"$type": "UAssetAPI.PropertyTypes.Objects.IntPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	}


func _make_float_property_raw(name: String, value: float) -> Dictionary:
	return {
		"$type": "UAssetAPI.PropertyTypes.Objects.FloatPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	}


func _make_int_property(name: String, value: int) -> UAssetProperty:
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.IntPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	})


func _make_bool_property(name: String, value: bool) -> UAssetProperty:
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BoolPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	})


func _make_byte_enum_property(name: String, enum_type: String, enum_value: String) -> UAssetProperty:
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"ByteType": "FName",
		"EnumType": enum_type,
		"EnumValue": enum_value,
	})


func _make_object_property(name: String, value: int) -> UAssetProperty:
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	})


func _make_object_array_property(name: String, array_type: String, refs: Array[int]) -> UAssetProperty:
	var values: Array = []
	for i in refs.size():
		values.append({
			"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
			"Name": "",
			"ArrayIndex": i,
			"IsZero": false,
			"Value": refs[i],
		})
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.ArrayPropertyData, UAssetAPI",
		"Name": name,
		"ArrayType": array_type,
		"Value": values,
	})


func _make_raw_distribution_vector_property(name: String) -> UAssetProperty:
	return UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.StructPropertyData, UAssetAPI",
		"Name": name,
		"StructType": "RawDistributionVector",
		"Value": [
			_make_float_property_raw("MaxValue", 35.0),
			{
				"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
				"Name": "Distribution",
				"ArrayIndex": 0,
				"IsZero": false,
				"Value": 0,
			},
			{
				"$type": "UAssetAPI.PropertyTypes.Objects.VectorPropertyData, UAssetAPI",
				"Name": "MinValueVec",
				"Value": {
					"$type": "UAssetAPI.UnrealTypes.FVector, UAssetAPI",
					"X": 20.0,
					"Y": "+0",
					"Z": "+0",
				},
			},
			{
				"$type": "UAssetAPI.PropertyTypes.Objects.VectorPropertyData, UAssetAPI",
				"Name": "MaxValueVec",
				"Value": {
					"$type": "UAssetAPI.UnrealTypes.FVector, UAssetAPI",
					"X": 35.0,
					"Y": "+0",
					"Z": "+0",
				},
			},
			{
				"$type": "UAssetAPI.PropertyTypes.Objects.ArrayPropertyData, UAssetAPI",
				"Name": "Table",
				"ArrayType": "DistributionLookupTable",
				"Value": [],
			},
		],
	})


func _vector_spin(editor: Control, component_index: int) -> SpinBox:
	if not (editor is HBoxContainer):
		return null
	if component_index < 0 or component_index >= editor.get_child_count():
		return null
	var component_box := editor.get_child(component_index) as HBoxContainer
	if component_box == null or component_box.get_child_count() < 2:
		return null
	return component_box.get_child(1) as SpinBox


func _has_label_text(node: Node, text: String) -> bool:
	if node is Label and (node as Label).text == text:
		return true
	if node is Button and (node as Button).text == text:
		return true
	for child in node.get_children():
		if _has_label_text(child, text):
			return true
	return false


func _make_import(name: String, outer: int) -> UAssetImport:
	return UAssetImport.from_dict({
		"$type": "UAssetAPI.Import, UAssetAPI",
		"ObjectName": name,
		"ClassName": "Class",
		"ClassPackage": "/Script/CoreUObject",
		"PackageName": null,
		"OuterIndex": outer,
		"bImportOptional": false,
	}, 0)


func _make_export(name: String, outer: int, class_index: int, template: int,
		dependencies: Array, object_value: int) -> UAssetExport:
	return UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
		"ObjectName": name,
		"OuterIndex": outer,
		"ClassIndex": class_index,
		"SuperIndex": 0,
		"TemplateIndex": template,
		"SerialSize": 0,
		"SerialOffset": 0,
		"CreateBeforeCreateDependencies": dependencies.duplicate(),
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Data": [{
			"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
			"Name": "ObjectRef",
			"ArrayIndex": 0,
			"IsZero": false,
			"Value": object_value,
		}],
	})


func _object_value(expo: UAssetExport) -> int:
	return int(expo.properties[0].value)


func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_first_mesh_instance(child)
		if found != null:
			return found
	return null


func _find_first_cpu_particles(node: Node) -> CPUParticles3D:
	if node == null:
		return null
	if node is CPUParticles3D:
		return node
	for child in node.get_children():
		var found := _find_first_cpu_particles(child)
		if found != null:
			return found
	return null


func _count_cpu_particles(node: Node) -> int:
	if node == null:
		return 0
	var count := 1 if node is CPUParticles3D else 0
	for child in node.get_children():
		count += _count_cpu_particles(child)
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _approx_float(actual: float, expected: float, epsilon: float = 0.0001) -> bool:
	return abs(actual - expected) <= epsilon


func _approx_color(actual: Color, expected: Color, epsilon: float = 0.0001) -> bool:
	return _approx_float(actual.r, expected.r, epsilon) \
			and _approx_float(actual.g, expected.g, epsilon) \
			and _approx_float(actual.b, expected.b, epsilon) \
			and _approx_float(actual.a, expected.a, epsilon)


func _approx_vec3(actual: Vector3, expected: Vector3, epsilon: float = 0.0001) -> bool:
	return actual.distance_to(expected) <= epsilon


func _approx_quat(actual: Quaternion, expected: Quaternion, epsilon: float = 0.0001) -> bool:
	return abs(actual.normalized().dot(expected.normalized())) >= 1.0 - epsilon
