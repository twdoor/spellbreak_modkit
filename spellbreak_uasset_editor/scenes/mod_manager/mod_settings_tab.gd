class_name ModSettingsTab extends VBoxContainer

## Settings tab for the Mod Manager — lives as a hidden tab, opened by the Settings button.
## Call setup(cfg) before adding to the scene tree.
## Emits close_requested when the user clicks Save or Cancel.

signal close_requested
signal status_changed(text: String, is_error: bool)

var _cfg: ModConfigManager
var _sources_container: VBoxContainer
var _base_source_service: BaseSourceService
var _base_source_btn: Button
var _base_source_status: Label
var _base_source_status_text := ""
var _base_source_status_error := false


func setup(cfg: ModConfigManager) -> ModSettingsTab:
	_cfg = cfg
	_base_source_service = BaseSourceService.new().setup(_cfg)
	_base_source_service.generate_started.connect(_on_base_source_generate_started)
	_base_source_service.generate_finished.connect(_on_base_source_generate_finished)
	return self


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_build_ui()


func _exit_tree() -> void:
	if _base_source_service:
		_base_source_service.wait_to_finish()


## Rebuild the entire UI to reflect current cfg values.
## Called by main.gd each time the Settings tab is opened.
func refresh() -> void:
	for child in get_children():
		child.free()
	_build_ui()


# ── UI ────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 0)

	# Scrollable content area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("margin_left",   AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_right",  AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_top",    AppTheme.MARGIN_SETTINGS_V)
	outer.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_SETTINGS_V)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", AppTheme.MARGIN_SETTINGS_V)
	outer.add_child(content)
	scroll.add_child(outer)
	add_child(scroll)

	var profile := _cfg.get_game_profile()
	var cr := profile.content_root

	# ── Game directory ──
	content.add_child(_section("Spellbreak Directory"))
	content.add_child(_hint(
		("Select the Spellbreak install folder used to locate the executable and pak files. " +
		"The folder should contain %s/ so paks resolve under %s/Content/Paks/.") % [cr, cr]
	))
	content.add_child(_dir_row(
		func() -> String: return _cfg.game_dir,
		func(v: String) -> void: _cfg.game_dir = v,
		"/path/to/game"
	))

	# ── Mods directory ──
	content.add_child(_section("Mods Directory"))
	content.add_child(_hint(
		("Choose the folder that contains your mod folders. Structure: Mods/MyMod/%s/Content/... " +
		"Each direct child folder is treated as one mod and can be enabled, packed, or watched separately.") % cr
	))
	content.add_child(_dir_row(
		func() -> String: return _cfg.mods_dir,
		func(v: String) -> void: _cfg.mods_dir = v,
		"/path/to/mods"
	))

	# ── Launch command ──
	content.add_child(_section("Launch Command"))
	content.add_child(_hint("Shell command to start the game. Leave blank to disable the Launch button."))
	var launch_edit := _line_edit(_cfg.launch_cmd, "steam steam://rungameid/...")
	launch_edit.text_changed.connect(func(v: String) -> void: _cfg.launch_cmd = v)
	content.add_child(launch_edit)


	# ── umodel (3D Preview) ──
	content.add_child(_section("umodel (3D Preview)"))
	content.add_child(_hint("Path to the umodel binary. Required for 3D mesh and animation preview. Download from gildor.org/en/projects/umodel"))
	var umodel_row := HBoxContainer.new()
	umodel_row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	var umodel_edit := _line_edit(_cfg.umodel_path, "/path/to/umodel")
	umodel_edit.text_changed.connect(func(v: String) -> void: _cfg.umodel_path = v)
	umodel_row.add_child(umodel_edit)
	var umodel_browse := Button.new()
	umodel_browse.text = "Browse..."
	umodel_browse.pressed.connect(func() -> void:
		var dialog := FileDialog.new()
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		dialog.use_native_dialog = true
		dialog.file_selected.connect(func(path: String) -> void:
			umodel_edit.text = path
			_cfg.umodel_path = path
			dialog.queue_free()
		)
		get_tree().root.add_child(dialog)
		dialog.popup_centered(Vector2i(800, 600))
	)
	umodel_row.add_child(umodel_browse)
	content.add_child(umodel_row)

	# ── Sources ──
	content.add_child(_section("Sources"))
	content.add_child(_hint(
		"Register exported asset directories for reference — the base game export, older game versions, reference mods, etc. " +
		"Each source has a name and a path to its root folder (the one containing %s/)." % cr
	))

	_sources_container = VBoxContainer.new()
	_sources_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sources_container.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	content.add_child(_sources_container)
	_rebuild_sources()

	var add_btn := Button.new()
	add_btn.text = "+ Add Source"
	add_btn.pressed.connect(_add_source)
	var generate_btn := Button.new()
	generate_btn.text = "Generate from Pak"
	generate_btn.tooltip_text = "Generate a source by unpacking a game .pak"
	generate_btn.disabled = _base_source_service.is_generating()
	generate_btn.pressed.connect(_on_generate_base_source_pressed)
	_base_source_btn = generate_btn
	var source_actions := HBoxContainer.new()
	source_actions.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	source_actions.add_child(add_btn)
	source_actions.add_child(generate_btn)
	content.add_child(source_actions)

	_base_source_status = _hint(_base_source_status_text)
	_base_source_status.visible = not _base_source_status_text.is_empty()
	AppTheme.style_status(_base_source_status, _base_source_status_error)
	content.add_child(_base_source_status)

	# ── Config file path (read-only info) ──
	content.add_child(_section("Config File"))
	content.add_child(_hint(_cfg.get_config_dir().path_join("config.json")))

	add_child(HSeparator.new())

	# ── Save / Revert buttons ──
	var btn_margin := MarginContainer.new()
	btn_margin.add_theme_constant_override("margin_left",   AppTheme.MARGIN_SETTINGS_H)
	btn_margin.add_theme_constant_override("margin_right",  AppTheme.MARGIN_SETTINGS_H)
	btn_margin.add_theme_constant_override("margin_top",     AppTheme.SPACING_ROW)
	btn_margin.add_theme_constant_override("margin_bottom",  AppTheme.SPACING_ROW)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.add_theme_color_override("font_color", AppTheme.BTN_SAVE)
	save_btn.pressed.connect(_on_save)
	btn_row.add_child(save_btn)

	var revert_btn := Button.new()
	revert_btn.text = "Revert"
	revert_btn.tooltip_text = "Discard unsaved changes"
	revert_btn.pressed.connect(_on_revert)
	btn_row.add_child(revert_btn)

	btn_margin.add_child(btn_row)
	add_child(btn_margin)


# ── Sources list ──────────────────────────────────────────────────────────────

func _add_source() -> void:
	_cfg.sources.append({"name": "", "path": ""})
	_rebuild_sources()


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
	name_edit.text_changed.connect(func(v: String) -> void: entry["name"] = v)
	row.add_child(name_edit)

	# Path — expands to fill remaining space
	var path_edit := LineEdit.new()
	var cr := _cfg.get_game_profile().content_root
	path_edit.placeholder_text = "/path/to/exported/source  (folder containing %s/)" % cr
	path_edit.text = str(entry.get("path", ""))
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.text_changed.connect(func(v: String) -> void: entry["path"] = v)
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
	dialog.use_native_dialog = true
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
	dialog.use_native_dialog = true
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
	_set_base_source_status("Extracting %s..." % pak_path.get_file(), false)
	_base_source_service.generate(pak_path, output_dir)


func _on_base_source_generate_started() -> void:
	if is_instance_valid(_base_source_btn):
		_base_source_btn.disabled = true


func _on_base_source_generate_finished(success: bool, message: String,
		source_name: String, source_path: String) -> void:
	if is_instance_valid(_base_source_btn):
		_base_source_btn.disabled = false
	if success:
		_add_generated_source(source_name, source_path)
		_set_base_source_status("%s. Source added; save settings to keep it." % message, false)
	else:
		_set_base_source_status(message, true)


func _add_generated_source(source_name: String, source_path: String) -> void:
	var normalized_path := source_path.rstrip("/")
	for entry: Dictionary in _cfg.sources:
		if FileUtils.same_path(str(entry.get("path", "")), normalized_path):
			entry["name"] = source_name
			entry["path"] = normalized_path
			_rebuild_sources()
			return
	_cfg.sources.append({"name": _unique_source_name(source_name), "path": normalized_path})
	_rebuild_sources()


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


func _set_base_source_status(text: String, is_error: bool) -> void:
	_base_source_status_text = text
	_base_source_status_error = is_error
	if is_instance_valid(_base_source_status):
		_base_source_status.text = text
		_base_source_status.visible = not text.is_empty()
		AppTheme.style_status(_base_source_status, is_error)
	status_changed.emit(text, is_error)


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


# ── Actions ───────────────────────────────────────────────────────────────────

func _on_save() -> void:
	_cfg.save_config()
	close_requested.emit()


func _on_revert() -> void:
	_cfg.load_config()
	close_requested.emit()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", AppTheme.FONT_HEADER)
	lbl.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	return lbl


func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	AppTheme.style_muted(lbl)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	return lbl


func _line_edit(current: String, placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = current
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return edit


func _dir_row(get_fn: Callable, set_fn: Callable, placeholder: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	var edit := _line_edit(get_fn.call(), placeholder)
	edit.text_changed.connect(func(v: String) -> void: set_fn.call(v))
	row.add_child(edit)

	var btn := Button.new()
	btn.text = "Browse…"
	btn.pressed.connect(func() -> void: _open_dir_dialog(edit, set_fn))
	row.add_child(btn)

	return row


func _open_dir_dialog(line_edit: LineEdit, on_select: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.dir_selected.connect(func(path: String) -> void:
		line_edit.text = path
		on_select.call(path)
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _open_file_dialog(line_edit: LineEdit, on_select: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	dialog.filters   = PackedStringArray(["*.pak ; Unreal Pak", "* ; All Files"])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		line_edit.text = path
		on_select.call(path)
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))
