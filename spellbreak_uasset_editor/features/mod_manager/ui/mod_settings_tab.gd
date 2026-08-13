class_name ModSettingsTab extends VBoxContainer

## Settings tab for the Mod Manager — lives as a hidden tab, opened by the Settings button.
## Call setup(cfg) before adding to the scene tree.
## Emits close_requested when the user clicks Save or Cancel.

signal close_requested
signal open_keymap_requested
signal status_changed(text: String, is_error: bool)

var _cfg: ModConfigManager
var _base_source_service: BaseSourceService
var _base_source_feedback: OperationFeedback
var _base_source_status_text := ""
var _base_source_status_error := false
var _base_source_status_kind: int = AppTheme.StatusKind.IDLE
var _last_base_source_operation: Callable
var _initial_snapshot: Dictionary = {}
var _file_association_service: FileAssociationService
var _syncing_controls := false

@onready var _game_directory_hint: Label = %GameDirectoryHint
@onready var _game_directory_edit: LineEdit = %GameDirectoryEdit
@onready var _mods_directory_hint: Label = %ModsDirectoryHint
@onready var _mods_directory_edit: LineEdit = %ModsDirectoryEdit
@onready var _launch_command_edit: LineEdit = %LaunchCommandEdit
@onready var _backup_toggle: Button = %BackupToggle
@onready var _file_association_button: Button = %FileAssociationButton
@onready var _umodel_edit: LineEdit = %UmodelEdit
@onready var _sources_hint: Label = %SourcesHint
@onready var _sources_container: VBoxContainer = %SourcesContainer
@onready var _base_source_btn: Button = %GenerateSourceButton
@onready var _base_source_feedback_mount: VBoxContainer = %BaseSourceFeedbackMount
@onready var _config_path_hint: Label = %ConfigPathHint
@onready var _save_btn: Button = %SaveButton
@onready var _close_or_revert_btn: Button = %CloseOrRevertButton


func setup(cfg: ModConfigManager) -> ModSettingsTab:
	_cfg = cfg
	_base_source_service = BaseSourceService.new().setup(_cfg)
	_file_association_service = FileAssociationService.new().setup(_cfg.get_config_dir())
	_base_source_service.generate_started.connect(_on_base_source_generate_started)
	_base_source_service.generate_finished.connect(_on_base_source_generate_finished)
	return self


func _ready() -> void:
	_initial_snapshot = _snapshot_config()
	_configure_scene_ui()
	_sync_controls()


func _exit_tree() -> void:
	if _base_source_service:
		_base_source_service.wait_to_finish()


## Refresh the scene controls to reflect current cfg values.
## Called by main.gd each time the Settings tab is opened.
func refresh() -> void:
	_initial_snapshot = _snapshot_config()
	_sync_controls()


func _configure_scene_ui() -> void:
	for node in find_children("*Title", "Label", true, false):
		var label := node as Label
		AppTheme.style_header(label)
		label.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	for node in find_children("*Hint", "Label", true, false):
		var label := node as Label
		AppTheme.style_muted(label)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_save_btn.add_theme_color_override("font_color", AppTheme.BTN_SAVE)

	_base_source_feedback = OperationFeedback.new().setup(_retry_base_source_generation)
	_base_source_feedback_mount.add_child(_base_source_feedback)


func _sync_controls() -> void:
	var profile := _cfg.get_game_profile()
	var cr := profile.content_root
	_game_directory_hint.text = (
		"Select the Spellbreak install folder used to locate the executable and pak files. "
		+ "The folder should contain %s/ so paks resolve under %s/Content/Paks/." % [cr, cr])
	_mods_directory_hint.text = (
		("Choose the folder that contains your mod folders. Structure: Mods/MyMod/%s/Content/... "
		+ "Each direct child folder is treated as one mod and can be enabled, packed, or watched separately.") % cr)
	_sources_hint.text = (
		"Register exported asset directories for reference — the base game export, older game versions, "
		+ "reference mods, etc. Each source has a name and a path to its root folder "
		+ "(the one containing %s/)." % cr)

	_syncing_controls = true
	_game_directory_edit.text = _cfg.game_dir
	_mods_directory_edit.text = _cfg.mods_dir
	_launch_command_edit.text = _cfg.launch_cmd
	_backup_toggle.button_pressed = _cfg.keep_pack_backups
	_update_toggle_button_text(_backup_toggle, _cfg.keep_pack_backups)
	_umodel_edit.text = _cfg.umodel_path
	_config_path_hint.text = _cfg.get_config_path()
	_syncing_controls = false

	_file_association_button.text = _file_association_service.action_label()
	_file_association_button.disabled = not _file_association_service.is_available_in_current_build()
	if not _file_association_service.is_supported():
		_file_association_button.tooltip_text = "File association is supported on Windows and Linux."
	elif OS.has_feature("editor"):
		_file_association_button.tooltip_text = "Run an exported build to register its executable."
	else:
		_file_association_button.tooltip_text = "Register this build as a .uasset handler."

	_rebuild_sources()
	_base_source_btn.disabled = _base_source_service.is_generating()
	_base_source_feedback.clear_log()
	_base_source_feedback.set_status(_base_source_status_text, _base_source_status_kind)
	_base_source_feedback.visible = not _base_source_status_text.is_empty()
	if not _base_source_status_text.is_empty():
		_base_source_feedback.add_line(_base_source_status_text)
		_base_source_feedback.set_retry_enabled(
				_base_source_status_error and _last_base_source_operation.is_valid())
	_update_footer_state()


func _on_game_directory_changed(path: String) -> void:
	if _syncing_controls:
		return
	_cfg.game_dir = path
	_update_footer_state()


func _on_game_directory_browse_pressed() -> void:
	_open_dir_dialog(_game_directory_edit, func(path: String) -> void: _cfg.game_dir = path)


func _on_mods_directory_changed(path: String) -> void:
	if _syncing_controls:
		return
	_cfg.mods_dir = path
	_update_footer_state()


func _on_mods_directory_browse_pressed() -> void:
	_open_dir_dialog(_mods_directory_edit, func(path: String) -> void: _cfg.mods_dir = path)


func _on_launch_command_changed(command: String) -> void:
	if _syncing_controls:
		return
	_cfg.launch_cmd = command
	_update_footer_state()


func _on_backup_toggled(enabled: bool) -> void:
	if _syncing_controls:
		return
	_cfg.keep_pack_backups = enabled
	_update_toggle_button_text(_backup_toggle, enabled)
	_update_footer_state()


func _on_umodel_path_changed(path: String) -> void:
	if _syncing_controls:
		return
	_cfg.umodel_path = path
	_update_footer_state()


func _on_umodel_browse_pressed() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	AppTheme.configure_file_dialog(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		_umodel_edit.text = path
		_cfg.umodel_path = path
		_update_footer_state()
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _on_edit_keymap_pressed() -> void:
	open_keymap_requested.emit()


# ── Sources list ──────────────────────────────────────────────────────────────

func _add_source() -> void:
	_cfg.sources.append({"name": "", "path": ""})
	_rebuild_sources()
	_update_footer_state()


func _rebuild_sources() -> void:
	# Use free() (not queue_free()) so nodes are removed immediately before we re-add.
	while _sources_container.get_child_count() > 0:
		_sources_container.get_child(0).free()
	for entry: Dictionary in _cfg.sources:
		_sources_container.add_child(_build_source_row(entry))


func _build_source_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	# Name — short fixed-width field
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Name"
	name_edit.text = str(entry.get("name", ""))
	name_edit.custom_minimum_size.x = 160
	name_edit.text_changed.connect(func(v: String) -> void:
		entry["name"] = v
		_update_footer_state()
	)
	row.add_child(name_edit)

	# Path — expands to fill remaining space
	var path_edit := LineEdit.new()
	var cr := _cfg.get_game_profile().content_root
	path_edit.placeholder_text = "/path/to/exported/source  (folder containing %s/)" % cr
	path_edit.text = str(entry.get("path", ""))
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.text_changed.connect(func(v: String) -> void:
		entry["path"] = v
		_update_footer_state()
	)
	row.add_child(path_edit)

	# Browse for the source root directory
	var browse_btn := Button.new()
	browse_btn.text = "Browse…"
	browse_btn.pressed.connect(func() -> void:
		_open_dir_dialog(path_edit, func(p: String) -> void: entry["path"] = p)
	)
	row.add_child(browse_btn)

	# Remove this source — defer so the button's pressed signal finishes before the row is freed
	var remove_btn := Button.new()
	remove_btn.text = "✕"
	remove_btn.tooltip_text = "Remove this source"
	remove_btn.flat = true
	remove_btn.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
	remove_btn.pressed.connect(func() -> void:
		_cfg.sources.erase(entry)
		_rebuild_sources.call_deferred()
		_update_footer_state.call_deferred()
	)
	row.add_child(remove_btn)

	return row


# ── Base source generation ───────────────────────────────────────────────────

func _on_generate_base_source_pressed() -> void:
	if _base_source_service.is_generating():
		return
	_open_base_pak_dialog()


func _open_base_pak_dialog() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.pak ; Unreal Pak", "* ; All Files"])
	AppTheme.configure_file_dialog(dialog)
	var paks_dir := _cfg.get_paks_dir()
	if DirAccess.dir_exists_absolute(paks_dir):
		dialog.current_dir = paks_dir
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_open_base_source_output_dialog(path)
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


func _open_base_source_output_dialog(pak_path: String) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	AppTheme.configure_file_dialog(dialog)
	dialog.dir_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_confirm_or_generate_base_source(pak_path, path)
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


func _confirm_or_generate_base_source(pak_path: String, output_dir: String) -> void:
	if _dir_has_entries(output_dir):
		var dialog := ConfirmationDialog.new()
		dialog.title = "Generate from Pak"
		dialog.dialog_text = "The selected folder is not empty. Existing matching files may be overwritten."
		dialog.ok_button_text = "Extract"
		AppTheme.apply_theme(dialog)
		add_child(dialog)
		dialog.confirmed.connect(func() -> void:
			dialog.queue_free()
			_start_base_source_generation(pak_path, output_dir)
		)
		dialog.canceled.connect(dialog.queue_free)
		dialog.popup_centered()
		return
	_start_base_source_generation(pak_path, output_dir)


func _start_base_source_generation(pak_path: String, output_dir: String) -> void:
	_last_base_source_operation = func() -> void:
		_confirm_or_generate_base_source(pak_path, output_dir)
	_show_base_source_feedback("Extracting %s..." % pak_path.get_file())
	_append_base_source_log("Source generation")
	_append_base_source_log("Package: %s" % pak_path)
	_append_base_source_log("Output folder: %s" % output_dir)
	_base_source_service.generate(pak_path, output_dir)


func _on_base_source_generate_started() -> void:
	if is_instance_valid(_base_source_btn):
		_base_source_btn.disabled = true


func _on_base_source_generate_finished(result: OperationResult) -> void:
	if is_instance_valid(_base_source_btn):
		_base_source_btn.disabled = false
	if result.ok:
		_add_generated_source(str(result.metadata.get("source_name", "Base Game")),
				str(result.metadata.get("source_path", result.value)))
		var success_message := "%s. Source added; save settings to keep it." % result.message
		_append_base_source_log("OK: %s" % success_message)
		_set_base_source_status(success_message, false, AppTheme.StatusKind.SUCCESS)
	else:
		_append_base_source_log("ERROR: %s" % result.message)
		_set_base_source_status(result.message, true, AppTheme.StatusKind.ERROR)
	if is_instance_valid(_base_source_feedback):
		_base_source_feedback.set_retry_enabled(
				not result.ok and _last_base_source_operation.is_valid())


func _add_generated_source(source_name: String, source_path: String) -> void:
	var normalized_path := source_path.rstrip("/")
	for entry: Dictionary in _cfg.sources:
		if FileUtils.same_path(str(entry.get("path", "")), normalized_path):
			entry["name"] = source_name
			entry["path"] = normalized_path
			_rebuild_sources()
			_update_footer_state()
			return
	_cfg.sources.append({"name": _unique_source_name(source_name), "path": normalized_path})
	_rebuild_sources()
	_update_footer_state()


func _unique_source_name(base_name: String) -> String:
	var used := {}
	for entry: Dictionary in _cfg.sources:
		var source_name_candidate := str(entry.get("name", "")).strip_edges()
		if not source_name_candidate.is_empty():
			used[source_name_candidate] = true
	if not used.has(base_name):
		return base_name
	var idx := 2
	while used.has("%s %d" % [base_name, idx]):
		idx += 1
	return "%s %d" % [base_name, idx]


func _set_base_source_status(text: String, is_error: bool,
		kind: int = AppTheme.StatusKind.IDLE) -> void:
	_base_source_status_text = text
	_base_source_status_error = is_error
	_base_source_status_kind = kind
	if is_instance_valid(_base_source_feedback):
		_base_source_feedback.visible = not text.is_empty()
		_base_source_feedback.set_status(text, kind)
	status_changed.emit(text, is_error)


func _show_base_source_feedback(status_text: String) -> void:
	_set_base_source_status(status_text, false, AppTheme.StatusKind.WORKING)
	if is_instance_valid(_base_source_feedback):
		_base_source_feedback.clear_log()
		_base_source_feedback.set_retry_enabled(false)


func _append_base_source_log(line: String) -> void:
	if is_instance_valid(_base_source_feedback):
		_base_source_feedback.add_line(line)


func _retry_base_source_generation() -> void:
	if _last_base_source_operation.is_valid():
		_last_base_source_operation.call()


func _dir_has_entries(path: String) -> bool:
	var dir := DirAccess.open(path)
	if not dir:
		return false
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			dir.list_dir_end()
			return true
		entry = dir.get_next()
	dir.list_dir_end()
	return false


func _snapshot_config() -> Dictionary:
	var source_snapshot: Array = []
	for entry: Dictionary in _cfg.sources:
		source_snapshot.append({
			"name": str(entry.get("name", "")),
			"path": str(entry.get("path", "")),
		})
	return {
		"game_dir": _cfg.game_dir,
		"mods_dir": _cfg.mods_dir,
		"launch_cmd": _cfg.launch_cmd,
		"keep_pack_backups": _cfg.keep_pack_backups,
		"u4pak_dir": _cfg.u4pak_dir,
		"ue4_dds_tools_dir": _cfg.ue4_dds_tools_dir,
		"umodel_path": _cfg.umodel_path,
		"sources": source_snapshot,
	}


func _is_dirty() -> bool:
	return _snapshot_config() != _initial_snapshot


func _update_footer_state() -> void:
	var dirty := _is_dirty()
	if is_instance_valid(_save_btn):
		_save_btn.disabled = not dirty
	if is_instance_valid(_close_or_revert_btn):
		_close_or_revert_btn.text = "Revert" if dirty else "Close"
		_close_or_revert_btn.tooltip_text = (
			"Discard unsaved changes" if dirty else "Close settings"
		)
		if dirty:
			_close_or_revert_btn.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
		else:
			AppTheme.style_muted_btn(_close_or_revert_btn)


# ── Actions ───────────────────────────────────────────────────────────────────

func _on_save() -> void:
	var error := _cfg.save_config()
	if error != OK:
		var message := _cfg.last_error
		if message.is_empty():
			message = "Could not save settings (error %d)." % error
		status_changed.emit(message, true)
		return
	_initial_snapshot = _snapshot_config()
	_update_footer_state()
	status_changed.emit("Settings saved to %s" % _cfg.get_config_path(), false)
	close_requested.emit()


func _on_register_file_association() -> void:
	var result := _file_association_service.register()
	_file_association_button.text = _file_association_service.action_label()
	status_changed.emit(result.message, not result.ok)


func _on_close_or_revert() -> void:
	if _is_dirty():
		var error := _cfg.load_config()
		if error != OK:
			status_changed.emit(_cfg.last_error, true)
			return
		_initial_snapshot = _snapshot_config()
	close_requested.emit()


func _open_config_folder() -> void:
	var app_settings := get_node_or_null("/root/AppSettings")
	if app_settings == null:
		status_changed.emit("The AppSettings service is unavailable.", true)
		return
	var error: Error = app_settings.open_config_directory()
	if error != OK:
		status_changed.emit(app_settings.last_error, true)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _update_toggle_button_text(button: Button, enabled: bool) -> void:
	button.text = "On" if enabled else "Off"
	button.tooltip_text = (
		"Automatic pack backups are enabled."
		if enabled else
		"Automatic pack backups are disabled."
	)


func _open_dir_dialog(line_edit: LineEdit, on_select: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	AppTheme.configure_file_dialog(dialog)
	dialog.dir_selected.connect(func(path: String) -> void:
		line_edit.text = path
		on_select.call(path)
		_update_footer_state()
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))
