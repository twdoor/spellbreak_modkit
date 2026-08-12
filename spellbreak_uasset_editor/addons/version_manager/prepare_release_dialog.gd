@tool
extends Window

const PROJECT_VERSION_SETTING := "application/config/version"
const CHANGELOG_PATH_SETTING := "version_manager/changelog_path"
const BUILDS_PATH_SETTING := "version_manager/builds_path"
const EXPORT_BASENAME_SETTING := "version_manager/export_basename"
const DEFAULT_CHANGELOG_PATH := "res://changelog.md"
const DEFAULT_BUILDS_PATH := "res://builds"
const EXPORT_PRESETS_PATH := "res://export_presets.cfg"
const SemanticVersion = preload("res://addons/version_manager/semantic_version.gd")

@onready var _version_edit: LineEdit = %VersionLineEdit
@onready var _title_edit: LineEdit = %TitleLineEdit
@onready var _changelog_edit: TextEdit = %ChangelogTextEdit
@onready var _pre_release_toggle: CheckBox = %PrereleaseCheckBox
@onready var _exports_menu: MenuButton = %ExportsMenuButton
@onready var _cancel_button: Button = %CancelButton
@onready var _create_button: Button = %CreateButton

var _export_presets: Array[Dictionary] = []
var _export_thread: Thread
var _release_folder := ""

var _progress_dialog: AcceptDialog
var _done_dialog: AcceptDialog
var _error_dialog: AcceptDialog


func _init() -> void:
	visible = false
	transient = true
	exclusive = false
	close_requested.connect(hide)


func _ready() -> void:
	_cancel_button.pressed.connect(hide)
	_create_button.pressed.connect(_create_release)
	var exports_popup := _exports_menu.get_popup()
	exports_popup.hide_on_checkable_item_selection = false
	exports_popup.id_pressed.connect(_on_export_preset_pressed)
	_build_result_dialogs()
	hide()


func apply_editor_theme(editor_theme: Theme) -> void:
	theme = editor_theme
	_progress_dialog.theme = editor_theme
	_done_dialog.theme = editor_theme
	_error_dialog.theme = editor_theme


func open_dialog() -> void:
	if _export_thread != null:
		_progress_dialog.popup_centered(Vector2i(420, 150))
		return

	_version_edit.text = str(ProjectSettings.get_setting(PROJECT_VERSION_SETTING, ""))
	_title_edit.clear()
	_changelog_edit.clear()
	_pre_release_toggle.button_pressed = false
	_refresh_export_presets()
	popup_centered()
	_version_edit.grab_focus()
	_version_edit.select_all()


func shutdown() -> void:
	if _export_thread != null:
		_export_thread.wait_to_finish()
		_export_thread = null


func _build_result_dialogs() -> void:
	_progress_dialog = AcceptDialog.new()
	_progress_dialog.visible = false
	_progress_dialog.title = "Preparing Release"
	_progress_dialog.dialog_text = "Exporting the selected release builds…"
	_progress_dialog.get_ok_button().hide()
	add_child(_progress_dialog)

	_done_dialog = AcceptDialog.new()
	_done_dialog.visible = false
	_done_dialog.title = "Release Ready"
	_done_dialog.ok_button_text = "Close"
	_done_dialog.add_button("Check Release", false, "check_release")
	_done_dialog.custom_action.connect(_on_done_dialog_action)
	add_child(_done_dialog)

	_error_dialog = AcceptDialog.new()
	_error_dialog.visible = false
	_error_dialog.title = "Could Not Prepare Release"
	add_child(_error_dialog)


func _refresh_export_presets() -> void:
	_export_presets = _read_export_presets()
	var popup := _exports_menu.get_popup()
	popup.clear()

	for preset_index: int in _export_presets.size():
		var preset := _export_presets[preset_index]
		var item_text := str(preset.name)
		if not str(preset.platform).is_empty() and preset.platform != preset.name:
			item_text += " — %s" % preset.platform
		popup.add_check_item(item_text, preset_index)
		popup.set_item_checked(popup.get_item_index(preset_index), true)

	if _export_presets.is_empty():
		popup.add_item("No export presets configured", 0)
		popup.set_item_disabled(0, true)
		_exports_menu.disabled = true
	else:
		_exports_menu.disabled = false

	_update_exports_menu_text()


func _read_export_presets() -> Array[Dictionary]:
	var presets: Array[Dictionary] = []
	var config := ConfigFile.new()
	if config.load(EXPORT_PRESETS_PATH) != OK:
		return presets

	for section: String in config.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue

		var platform := str(config.get_value(section, "platform", ""))
		var options_section := "%s.options" % section
		presets.append({
			"section": section,
			"name": str(config.get_value(section, "name", "")),
			"platform": platform,
			"architecture": str(
				config.get_value(options_section, "binary_format/architecture", "")
			),
			"generates_appimage": bool(
				config.get_value(
					options_section, "appimage/generate_an_appimage", false
				)
			),
			"existing_path": str(config.get_value(section, "export_path", "")),
		})

	return presets


func _on_export_preset_pressed(preset_id: int) -> void:
	var popup := _exports_menu.get_popup()
	var item_index := popup.get_item_index(preset_id)
	if item_index < 0:
		return
	popup.set_item_checked(item_index, not popup.is_item_checked(item_index))
	_update_exports_menu_text()


func _update_exports_menu_text() -> void:
	var popup := _exports_menu.get_popup()
	var selected_count := 0
	for preset_id: int in _export_presets.size():
		var item_index := popup.get_item_index(preset_id)
		if item_index >= 0 and popup.is_item_checked(item_index):
			selected_count += 1

	if _export_presets.is_empty():
		_exports_menu.text = "Exports — none configured"
	else:
		_exports_menu.text = "Exports — %d/%d selected" % [
			selected_count,
			_export_presets.size(),
		]


func _selected_export_presets() -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	var popup := _exports_menu.get_popup()
	for preset_id: int in _export_presets.size():
		var item_index := popup.get_item_index(preset_id)
		if item_index >= 0 and popup.is_item_checked(item_index):
			selected.append(_export_presets[preset_id])
	return selected


func _create_release() -> void:
	var entered_version := _version_edit.text.strip_edges()
	var validation_error := _validate_release(entered_version)
	if not validation_error.is_empty():
		_show_error(validation_error)
		return
	var version := str(SemanticVersion.parse(entered_version).normalized)

	var selected_presets := _selected_export_presets()
	if selected_presets.is_empty():
		_show_error("Select at least one export preset.")
		return

	_create_button.disabled = true
	var release_setup := _prepare_release_files(version, selected_presets)
	if not bool(release_setup.success):
		_create_button.disabled = false
		_show_error(str(release_setup.error))
		return

	_release_folder = str(release_setup.release_folder)
	hide()
	_progress_dialog.dialog_text = "Exporting version %s…" % version
	_progress_dialog.popup_centered(Vector2i(420, 150))

	_export_thread = Thread.new()
	var thread_error := _export_thread.start(
		_run_exports.bind(
			release_setup.tasks,
			OS.get_executable_path(),
			_release_folder
		)
	)
	if thread_error != OK:
		_export_thread = null
		_progress_dialog.hide()
		_create_button.disabled = false
		var rollback_failures := _rollback_release_setup(
			release_setup.rollback,
			_release_folder
		)
		_release_folder = ""
		var message := "Could not start the export worker (error %d)." % thread_error
		if not rollback_failures.is_empty():
			message += "\n\nRollback issues:\n%s" % "\n".join(rollback_failures)
		_show_error(message)


func _validate_release(version: String) -> String:
	if version.is_empty():
		return "Enter a version number."

	var parsed_version := SemanticVersion.parse(version)
	if not bool(parsed_version.valid):
		return (
			"Use semantic versioning: major.minor.patch, optionally followed by "
			+ "a prerelease or build identifier (for example, 1.2.3-beta.1)."
		)

	var normalized := str(parsed_version.normalized)
	var release_folder_path := _release_folder_path(normalized)
	var release_folder := ProjectSettings.globalize_path(release_folder_path)
	if (
		DirAccess.dir_exists_absolute(release_folder)
		or FileAccess.file_exists(release_folder)
	):
		return "A release already exists at %s." % release_folder_path

	if _changelog_has_version(normalized):
		return "%s already contains version %s." % [_changelog_path(), normalized]

	return ""


func _prepare_release_files(
	version: String,
	selected_presets: Array[Dictionary]
) -> Dictionary:
	var release_folder := _release_folder_path(version)
	var global_release_folder := ProjectSettings.globalize_path(release_folder)
	if (
		DirAccess.dir_exists_absolute(global_release_folder)
		or FileAccess.file_exists(global_release_folder)
	):
		return _setup_error("A release already exists at %s." % release_folder)

	var task_plan := _plan_release_tasks(release_folder, selected_presets)
	if not bool(task_plan.success):
		return _setup_error(str(task_plan.error))

	var rollback := _capture_release_state()
	var builds_path := _builds_path()
	var global_builds_folder := ProjectSettings.globalize_path(builds_path)
	var builds_error := DirAccess.make_dir_recursive_absolute(global_builds_folder)
	if builds_error != OK:
		return _setup_error(
			"Could not create %s (error %d)." % [builds_path, builds_error]
		)

	var directory_error := DirAccess.make_dir_absolute(global_release_folder)
	if directory_error != OK:
		if not bool(rollback.builds_directory_existed):
			_remove_empty_directory_absolute(global_builds_folder)
		return _setup_error(
			"Could not create %s (error %d)." % [release_folder, directory_error]
		)

	var tasks: Array[Dictionary] = task_plan.tasks
	for task: Dictionary in tasks:
		var target_folder := str(task.output_path).get_base_dir()
		var target_dir_error := DirAccess.make_dir_recursive_absolute(target_folder)
		if target_dir_error != OK:
			return _setup_error_with_rollback(
				"Could not create %s (error %d)." % [
					target_folder,
					target_dir_error,
				],
				rollback,
				global_release_folder
			)

	var selected_preset_names: Array[String] = []
	for preset: Dictionary in selected_presets:
		selected_preset_names.append(str(preset.name))

	var manifest := {
		"version": version,
		"title": _title_edit.text.strip_edges(),
		"changelog": _changelog_edit.text.strip_edges(),
		"prerelease": _pre_release_toggle.button_pressed,
		"created_at": Time.get_datetime_string_from_system(false, true),
		"exports": selected_preset_names,
	}
	var manifest_path := "%s/release.json" % release_folder
	var manifest_file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if manifest_file == null:
		return _setup_error_with_rollback(
			"Could not create release.json (error %d)." % FileAccess.get_open_error(),
			rollback,
			global_release_folder
		)
	manifest_file.store_string(JSON.stringify(manifest, "\t") + "\n")
	var manifest_error := manifest_file.get_error()
	manifest_file = null
	if manifest_error != OK:
		return _setup_error_with_rollback(
			"Could not write release.json (error %d)." % manifest_error,
			rollback,
			global_release_folder
		)

	ProjectSettings.set_setting(PROJECT_VERSION_SETTING, version)
	var settings_error := ProjectSettings.save()
	if settings_error != OK:
		return _setup_error_with_rollback(
			"Could not save the project version (error %d)." % settings_error,
			rollback,
			global_release_folder
		)

	var changelog_error := _update_changelog(
		version,
		_title_edit.text.strip_edges(),
		_changelog_edit.text.strip_edges(),
		_pre_release_toggle.button_pressed
	)
	if changelog_error != OK:
		return _setup_error_with_rollback(
			"Could not update %s (error %d)." % [_changelog_path(), changelog_error],
			rollback,
			global_release_folder
		)

	return {
		"success": true,
		"error": "",
		"release_folder": global_release_folder,
		"tasks": tasks,
		"rollback": rollback,
	}


func _plan_release_tasks(
	release_folder: String,
	selected_presets: Array[Dictionary]
) -> Dictionary:
	var app_name := str(ProjectSettings.get_setting(
		EXPORT_BASENAME_SETTING,
		""
	)).strip_edges().validate_filename()
	if app_name.is_empty():
		app_name = str(
			ProjectSettings.get_setting("application/config/name", "app")
		).to_snake_case().validate_filename()
	if app_name.is_empty():
		app_name = "app"

	var tasks: Array[Dictionary] = []
	var used_folder_names: Dictionary = {}
	for preset: Dictionary in selected_presets:
		var preset_name := str(preset.get("name", "")).strip_edges()
		if preset_name.is_empty():
			return _setup_error("A selected export preset has no name.")

		var preset_folder := _unique_preset_folder_name(preset, used_folder_names)
		used_folder_names[preset_folder] = true
		var target_folder := "%s/%s" % [release_folder, preset_folder]
		var output_path := "%s/%s%s" % [
			target_folder,
			app_name,
			_export_extension(preset),
		]
		var additional_outputs := PackedStringArray()
		if (
			str(preset.platform).to_lower() == "linux"
			and bool(preset.get("generates_appimage", false))
		):
			additional_outputs.append(output_path.get_basename() + ".AppImage")
		tasks.append({
			"target": preset_name,
			"preset": preset_name,
			"output_path": ProjectSettings.globalize_path(output_path),
			"additional_outputs": additional_outputs,
		})

	return {
		"success": true,
		"error": "",
		"tasks": tasks,
	}


func _capture_release_state() -> Dictionary:
	var changelog_path := _changelog_path()
	var changelog_exists := FileAccess.file_exists(changelog_path)
	var changelog_contents := ""
	if changelog_exists:
		changelog_contents = FileAccess.get_file_as_string(changelog_path)

	return {
		"version_setting_existed": ProjectSettings.has_setting(PROJECT_VERSION_SETTING),
		"version": ProjectSettings.get_setting(PROJECT_VERSION_SETTING, ""),
		"changelog_existed": changelog_exists,
		"changelog": changelog_contents,
		"builds_directory_existed": DirAccess.dir_exists_absolute(
			ProjectSettings.globalize_path(_builds_path())
		),
	}


func _setup_error_with_rollback(
	message: String,
	rollback: Dictionary,
	global_release_folder: String
) -> Dictionary:
	var rollback_failures := _rollback_release_setup(
		rollback,
		global_release_folder
	)
	if not rollback_failures.is_empty():
		message += "\n\nRollback issues:\n%s" % "\n".join(rollback_failures)
	return _setup_error(message)


func _rollback_release_setup(
	rollback: Dictionary,
	global_release_folder: String
) -> Array[String]:
	var failures: Array[String] = []

	if bool(rollback.version_setting_existed):
		ProjectSettings.set_setting(PROJECT_VERSION_SETTING, rollback.version)
	else:
		ProjectSettings.set_setting(PROJECT_VERSION_SETTING, null)
	var settings_error := ProjectSettings.save()
	if settings_error != OK:
		failures.append(
			"Could not restore the project version (error %d)." % settings_error
		)

	if bool(rollback.changelog_existed):
		var changelog_path := _changelog_path()
		var changelog_file := FileAccess.open(changelog_path, FileAccess.WRITE)
		if changelog_file == null:
			failures.append(
				"Could not restore changelog.md (error %d)."
				% FileAccess.get_open_error()
			)
		else:
			changelog_file.store_string(str(rollback.changelog))
			var changelog_error := changelog_file.get_error()
			if changelog_error != OK:
				failures.append(
					"Could not restore changelog.md (error %d)." % changelog_error
				)
	elif FileAccess.file_exists(_changelog_path()):
		var remove_changelog_error := DirAccess.remove_absolute(
			ProjectSettings.globalize_path(_changelog_path())
		)
		if remove_changelog_error != OK:
			failures.append(
				"Could not remove the new changelog.md (error %d)."
				% remove_changelog_error
			)

	var cleanup_error := _remove_directory_tree_absolute(global_release_folder)
	if cleanup_error != OK:
		failures.append(
			"Could not remove the incomplete release folder (error %d)."
			% cleanup_error
		)
	if not bool(rollback.builds_directory_existed):
		var builds_cleanup_error := _remove_empty_directory_absolute(
			ProjectSettings.globalize_path(_builds_path())
		)
		if builds_cleanup_error != OK:
			failures.append(
				"Could not remove the new builds folder (error %d)."
				% builds_cleanup_error
			)
	return failures


func _remove_directory_tree_absolute(path: String) -> Error:
	if not DirAccess.dir_exists_absolute(path):
		return OK

	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return DirAccess.get_open_error()

	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var entry_path := path.path_join(entry_name)
			var remove_error := OK
			if directory.current_is_dir():
				remove_error = _remove_directory_tree_absolute(entry_path)
			else:
				remove_error = DirAccess.remove_absolute(entry_path)
			if remove_error != OK:
				directory.list_dir_end()
				return remove_error
		entry_name = directory.get_next()
	directory.list_dir_end()
	directory = null
	return DirAccess.remove_absolute(path)


func _remove_empty_directory_absolute(path: String) -> Error:
	if not DirAccess.dir_exists_absolute(path):
		return OK

	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return DirAccess.get_open_error()
	directory.list_dir_begin()
	var entry_name := directory.get_next()
	while entry_name == "." or entry_name == "..":
		entry_name = directory.get_next()
	directory.list_dir_end()
	directory = null
	if not entry_name.is_empty():
		return OK
	return DirAccess.remove_absolute(path)


func _unique_preset_folder_name(
	preset: Dictionary,
	used_folder_names: Dictionary
) -> String:
	var base_name := str(preset.name).to_snake_case().validate_filename()
	if base_name.is_empty():
		base_name = str(preset.platform).to_snake_case().validate_filename()
	if base_name.is_empty():
		base_name = "export"

	var folder_name := base_name
	var suffix := 2
	while used_folder_names.has(folder_name):
		folder_name = "%s_%d" % [base_name, suffix]
		suffix += 1
	return folder_name


func _export_extension(preset: Dictionary) -> String:
	var platform := str(preset.platform).to_lower()
	var architecture := str(preset.architecture).to_lower()

	match platform:
		"windows desktop", "windows":
			return ".exe"
		"linux":
			if architecture == "arm64":
				return ".arm64"
			if architecture == "arm32":
				return ".arm32"
			if architecture == "x86_32":
				return ".x86_32"
			return ".x86_64"
		"web":
			return ".zip"
		"android":
			return ".apk"
		"macos", "ios":
			return ".zip"

	var existing_extension := str(preset.existing_path).get_extension()
	if not existing_extension.is_empty():
		return ".%s" % existing_extension
	return ""


func _changelog_has_version(version: String) -> bool:
	var changelog_path := _changelog_path()
	if not FileAccess.file_exists(changelog_path):
		return false

	var contents := FileAccess.get_file_as_string(changelog_path)
	for line: String in contents.split("\n"):
		if not line.begins_with("## "):
			continue

		var heading := line.trim_prefix("## ").strip_edges()
		var separator_index := heading.find(" ")
		var heading_version := heading
		if separator_index >= 0:
			heading_version = heading.left(separator_index)
		var parsed_heading := SemanticVersion.parse(heading_version)
		if (
			bool(parsed_heading.valid)
			and str(parsed_heading.normalized) == version
		):
			return true
	return false


func _update_changelog(
	version: String,
	version_title: String,
	changelog: String,
	is_pre_release: bool
) -> Error:
	var heading := "## %s" % version
	if not version_title.is_empty():
		heading += " — %s" % version_title
	if is_pre_release:
		heading += " (Pre-release)"
	heading += " — %s" % Time.get_date_string_from_system()

	var section := heading
	if not changelog.is_empty():
		section += "\n\n%s" % changelog

	var existing := ""
	var changelog_path := _changelog_path()
	if FileAccess.file_exists(changelog_path):
		existing = FileAccess.get_file_as_string(changelog_path).strip_edges()
		if existing.begins_with("# Changelog"):
			existing = existing.trim_prefix("# Changelog").strip_edges()

	var output := "# Changelog\n\n%s" % section
	if not existing.is_empty():
		output += "\n\n%s" % existing
	output += "\n"

	var changelog_file := FileAccess.open(changelog_path, FileAccess.WRITE)
	if changelog_file == null:
		return FileAccess.get_open_error()
	changelog_file.store_string(output)
	return OK


func _changelog_path() -> String:
	return _configured_path(CHANGELOG_PATH_SETTING, DEFAULT_CHANGELOG_PATH)


func _builds_path() -> String:
	return _configured_path(BUILDS_PATH_SETTING, DEFAULT_BUILDS_PATH)


func _release_folder_path(version: String) -> String:
	return _builds_path().path_join(version)


func _configured_path(setting_name: String, default_path: String) -> String:
	var configured := str(ProjectSettings.get_setting(
		setting_name,
		default_path
	)).strip_edges()
	return configured if not configured.is_empty() else default_path


func _setup_error(message: String) -> Dictionary:
	return {
		"success": false,
		"error": message,
	}


func _show_error(message: String) -> void:
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered(Vector2i(520, 180))


func _run_exports(
	tasks: Array[Dictionary],
	godot_executable: String,
	release_folder: String
) -> void:
	var failures: Array[String] = []
	var project_path := ProjectSettings.globalize_path("res://")

	for task: Dictionary in tasks:
		var output: Array = []
		var arguments := PackedStringArray([
			"--headless",
			"--path",
			project_path,
			"--export-release",
			str(task.preset),
			str(task.output_path),
		])
		var exit_code := OS.execute(godot_executable, arguments, output, true)
		var missing_outputs: Array[String] = []
		if not FileAccess.file_exists(str(task.output_path)):
			missing_outputs.append(str(task.output_path))
		for additional_path: String in task.get(
			"additional_outputs", PackedStringArray()
		):
			var global_additional_path := ProjectSettings.globalize_path(additional_path)
			if not FileAccess.file_exists(global_additional_path):
				missing_outputs.append(global_additional_path)
		if exit_code != 0 or not missing_outputs.is_empty():
			var details := ""
			if not output.is_empty():
				details = str(output[0]).strip_edges()
				if details.length() > 500:
					details = details.substr(details.length() - 500)
			if not missing_outputs.is_empty():
				details += " Missing output: %s" % ", ".join(missing_outputs)
			failures.append(
				"%s export failed (exit code %d). %s"
				% [str(task.target), exit_code, details]
			)

	if failures.is_empty():
		var checksum_error := _write_release_checksums(tasks, release_folder)
		if not checksum_error.is_empty():
			failures.append(checksum_error)

	_on_exports_finished.call_deferred(failures)


func _write_release_checksums(
	tasks: Array[Dictionary], release_folder: String
) -> String:
	var artifact_paths: Array[String] = []
	for task: Dictionary in tasks:
		artifact_paths.append(str(task.output_path))
		for additional_path: String in task.get(
			"additional_outputs", PackedStringArray()
		):
			artifact_paths.append(ProjectSettings.globalize_path(additional_path))

	var checksum_lines: Array[String] = []
	for artifact_path: String in artifact_paths:
		if not FileAccess.file_exists(artifact_path):
			return "Could not checksum missing release artifact: %s" % artifact_path
		var relative_path := artifact_path.trim_prefix(release_folder).trim_prefix("/")
		checksum_lines.append(
			"%s  %s" % [FileAccess.get_sha256(artifact_path), relative_path]
		)
	checksum_lines.sort()

	var checksum_path := release_folder.path_join("SHA256SUMS")
	var checksum_file := FileAccess.open(checksum_path, FileAccess.WRITE)
	if checksum_file == null:
		return "Could not write %s (error %d)." % [
			checksum_path, FileAccess.get_open_error()
		]
	checksum_file.store_string("\n".join(checksum_lines) + "\n")
	var checksum_file_error := checksum_file.get_error()
	checksum_file.close()
	if checksum_file_error != OK:
		return "Could not write %s (error %d)." % [
			checksum_path, checksum_file_error
		]
	return ""


func _on_exports_finished(failures: Array[String]) -> void:
	if _export_thread != null:
		_export_thread.wait_to_finish()
		_export_thread = null

	_progress_dialog.hide()
	_create_button.disabled = false

	if failures.is_empty():
		_done_dialog.title = "Release Ready"
		_done_dialog.dialog_text = (
			"Version %s was prepared successfully.\n\n%s"
			% [
				str(ProjectSettings.get_setting(PROJECT_VERSION_SETTING, "")),
				_release_folder,
			]
		)
	else:
		_done_dialog.title = "Release Export Failed"
		_done_dialog.dialog_text = (
			"The release files were prepared, but one or more exports failed:\n\n%s"
			% "\n\n".join(failures)
		)
	_done_dialog.popup_centered(Vector2i(600, 280))


func _on_done_dialog_action(action: StringName) -> void:
	if action == &"check_release" and not _release_folder.is_empty():
		OS.shell_show_in_file_manager(_release_folder, true)
