class_name AddGameDialog extends ConfirmationDialog

## Dialog for creating a custom game profile.
## Emits game_created(profile_id) on success.

signal game_created(profile_id: String)

var _name_edit: LineEdit
var _ue_version_btn: OptionButton
var _root_edit: LineEdit
var _enums_check: CheckBox
var _tags_check: CheckBox
var _constants_check: CheckBox

## UE version options for the dropdown.
const _UE_VERSIONS: Array[String] = [
	"4.0", "4.1", "4.2", "4.3", "4.4", "4.5", "4.6", "4.7", "4.8", "4.9",
	"4.10", "4.11", "4.12", "4.13", "4.14", "4.15", "4.16", "4.17", "4.18",
	"4.19", "4.20", "4.21", "4.22", "4.23", "4.24", "4.25", "4.26", "4.27",
	"5.0", "5.1", "5.2", "5.3", "5.4",
]


func _init() -> void:
	title = "Add Custom Game"
	ok_button_text = "Create"
	min_size = Vector2i(460, 0)
	AppTheme.apply_theme(self)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	# ── Game Name ──
	var name_label := Label.new()
	name_label.text = "Game Name:"
	vbox.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "My Game"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_name_edit)

	# ── UE Version ──
	var ver_label := Label.new()
	ver_label.text = "UE Version:"
	vbox.add_child(ver_label)
	_ue_version_btn = OptionButton.new()
	for ver in _UE_VERSIONS:
		_ue_version_btn.add_item("UE " + ver)
	# Default to UE 4.27
	_ue_version_btn.selected = _UE_VERSIONS.find("4.27")
	vbox.add_child(_ue_version_btn)

	# ── Project Root ──
	var root_label := Label.new()
	root_label.text = "Project Root:"
	vbox.add_child(root_label)
	_root_edit = LineEdit.new()
	_root_edit.placeholder_text = "ProjectName"
	_root_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_root_edit)
	var root_hint := Label.new()
	root_hint.text = "The top-level folder inside the pak — e.g. \"g3\" for Spellbreak, \"ShooterGame\" for many FPS games, \"Pal\" for Palworld."
	root_hint.add_theme_font_size_override("font_size", AppTheme.FONT_SMALL)
	AppTheme.style_muted(root_hint)
	root_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(root_hint)

	# ── Optional data ──
	_enums_check = CheckBox.new()
	_enums_check.text = "I have enum definitions (JSON)"
	vbox.add_child(_enums_check)

	_tags_check = CheckBox.new()
	_tags_check.text = "I have gameplay tags (JSON)"
	vbox.add_child(_tags_check)

	_constants_check = CheckBox.new()
	_constants_check.text = "I have numeric constants (JSON)"
	vbox.add_child(_constants_check)

	add_child(vbox)
	confirmed.connect(_on_confirmed)


func _on_confirmed() -> void:
	var game_name := _name_edit.text.strip_edges()
	if game_name.is_empty():
		return

	var ver_idx := _ue_version_btn.selected
	var ue_version: String = _UE_VERSIONS[ver_idx] if ver_idx >= 0 and ver_idx < _UE_VERSIONS.size() else "4.27"

	var project_root := _root_edit.text.strip_edges()
	if project_root.is_empty():
		project_root = "Content"

	# Sanitize the profile directory name
	var profile_id := game_name.to_lower().replace(" ", "_")
	for ch in [".", "/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		profile_id = profile_id.replace(ch, "")

	# Create the profile directory
	var profiles_dir := GameProfile.get_user_profiles_dir()
	var profile_dir := profiles_dir.path_join(profile_id)
	DirAccess.make_dir_recursive_absolute(profile_dir)

	# Determine pak archive version based on UE version
	var pak_ver := 3
	if ue_version >= "5.0":
		pak_ver = 11

	# Write profile.json
	var profile_data := {
		"display_name": game_name,
		"builtin": false,
		"ue_version": ue_version,
		"umodel_game_flag": "ue" + ue_version,
		"dds_tools_version": ue_version,
		"pak_archive_version": pak_ver,
		"pak_mount_point": "../../../",
		"content_root": project_root,
		"paks_subpath": project_root + "/Content/Paks",
		"pak_output_name": "zzz_mods_P",
		"audio_format": "ogg_raw",
		"has_enums": _enums_check.button_pressed,
		"has_tags": _tags_check.button_pressed,
		"has_constants": _constants_check.button_pressed,
	}
	var profile_json := JSON.stringify(profile_data, "  ")
	var f := FileAccess.open(profile_dir.path_join("profile.json"), FileAccess.WRITE)
	if f:
		f.store_string(profile_json)
		f.close()

	# Chain file-import dialogs for each checked optional JSON, then emit.
	var _steps: Array[Callable] = []
	if _enums_check.button_pressed:
		_steps.append(func(done: Callable) -> void:
			_import_json_file(profile_dir, "enums.json", "Select enum definitions JSON", done))
	if _tags_check.button_pressed:
		_steps.append(func(done: Callable) -> void:
			_import_json_file(profile_dir, "tags.json", "Select gameplay tags JSON", done))
	if _constants_check.button_pressed:
		_steps.append(func(done: Callable) -> void:
			_import_json_file(profile_dir, "constants.json", "Select numeric constants JSON", done))
	_run_import_chain(_steps, func() -> void: game_created.emit(profile_id))


## Runs an array of import steps sequentially.  Each step is a Callable(done)
## that must call done() when finished.  After all steps, final_done is called.
func _run_import_chain(steps: Array[Callable], final_done: Callable) -> void:
	if steps.is_empty():
		final_done.call()
		return
	var step := steps[0]
	var remaining := steps.slice(1)
	step.call(func() -> void: _run_import_chain(remaining, final_done))


func _import_json_file(profile_dir: String, filename: String, dialog_title: String, on_done: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.title = dialog_title
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.json ; JSON Files"])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		# Copy the selected JSON file into the profile directory
		var data := FileAccess.get_file_as_bytes(path)
		if data.size() > 0:
			var dst := profile_dir.path_join(filename)
			var out := FileAccess.open(dst, FileAccess.WRITE)
			if out:
				out.store_buffer(data)
				out.close()
		dialog.queue_free()
		on_done.call()
	)
	dialog.canceled.connect(func() -> void:
		dialog.queue_free()
		on_done.call()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))
