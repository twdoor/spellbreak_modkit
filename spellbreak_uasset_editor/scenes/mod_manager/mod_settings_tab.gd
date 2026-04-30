class_name ModSettingsTab extends VBoxContainer

## Settings tab for the Mod Manager — lives as a hidden tab, opened by the Settings button.
## Call setup(cfg) before adding to the scene tree.
## Emits close_requested when the user clicks Save or Cancel.

signal close_requested

var _cfg: ModConfigManager
var _sources_container: VBoxContainer
var _profile_dropdown: OptionButton
## All profile entries from GameProfile.list_profiles(), cached for dropdown index mapping.
var _profile_entries: Array = []


func setup(cfg: ModConfigManager) -> ModSettingsTab:
	_cfg = cfg
	return self


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_build_ui()


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

	# ── Game / Version ── (first setting — everything below depends on it)
	content.add_child(_section("Game / Version"))
	content.add_child(_hint("Select the game or UE version you are modding. This sets version strings, content root, and available enums/tags."))
	var profile_row := HBoxContainer.new()
	profile_row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	_profile_dropdown = _build_profile_dropdown()
	_profile_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_row.add_child(_profile_dropdown)
	var add_game_btn := Button.new()
	add_game_btn.text = "+ Add Game"
	add_game_btn.tooltip_text = "Create a custom game profile"
	add_game_btn.pressed.connect(_on_add_game_pressed)
	profile_row.add_child(add_game_btn)
	content.add_child(profile_row)

	# ── Game directory ──
	content.add_child(_section("Game Directory"))
	content.add_child(_hint("The game installation folder — the one that contains %s/." % cr))
	content.add_child(_dir_row(
		func() -> String: return _cfg.game_dir,
		func(v: String) -> void: _cfg.game_dir = v,
		"/path/to/game"
	))

	# ── Mods directory ──
	content.add_child(_section("Mods Directory"))
	content.add_child(_hint("Each subfolder is one mod. Each mod must contain a %s/ folder with your edited assets." % cr))
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
	content.add_child(_hint("Path to the umodel binary. Required for 3D mesh preview. Download from gildor.org/en/projects/umodel"))
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
	content.add_child(add_btn)

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


# ── Game profile dropdown ─────────────────────────────────────────────────────

func _build_profile_dropdown() -> OptionButton:
	_profile_entries = GameProfile.list_profiles()

	var opt := OptionButton.new()
	var selected_idx := 0
	var idx := 0
	var added_ue_sep := false
	var added_custom_sep := false

	# Group 1: built-in game profiles (non-UE-version entries like Spellbreak)
	for entry in _profile_entries:
		if entry["builtin"] and not entry["is_ue_version"]:
			opt.add_item(entry["display_name"], idx)
			if entry["id"] == _cfg.game_profile_id:
				selected_idx = idx
			idx += 1

	# Separator before UE versions
	for entry in _profile_entries:
		if entry["is_ue_version"]:
			if not added_ue_sep:
				opt.add_separator("UE Versions")
				idx += 1
				added_ue_sep = true
			opt.add_item(entry["display_name"], idx)
			if entry["id"] == _cfg.game_profile_id:
				selected_idx = idx
			idx += 1

	# Group 3: user-created profiles
	for entry in _profile_entries:
		if not entry["builtin"] and not entry["is_ue_version"]:
			if not added_custom_sep:
				opt.add_separator("Custom Games")
				idx += 1
				added_custom_sep = true
			opt.add_item(entry["display_name"], idx)
			if entry["id"] == _cfg.game_profile_id:
				selected_idx = idx
			idx += 1

	opt.selected = selected_idx
	opt.item_selected.connect(_on_profile_selected)
	return opt


## Map dropdown visual index → profile entry index in _profile_entries.
## Separators occupy indices but aren't in _profile_entries, so we skip them.
func _get_profile_id_for_dropdown_idx(dropdown_idx: int) -> String:
	# Walk the dropdown items, counting only non-separator items
	#var real_idx := 0
	# Build a flat list matching the order we added items (built-in games, UE versions, custom)
	var ordered_ids: Array[String] = []
	for entry in _profile_entries:
		if entry["builtin"] and not entry["is_ue_version"]:
			ordered_ids.append(entry["id"])
	for entry in _profile_entries:
		if entry["is_ue_version"]:
			ordered_ids.append(entry["id"])
	for entry in _profile_entries:
		if not entry["builtin"] and not entry["is_ue_version"]:
			ordered_ids.append(entry["id"])

	# Walk the dropdown to find which ordered_ids entry this maps to
	var id_cursor := 0
	for i in _profile_dropdown.item_count:
		if _profile_dropdown.is_item_separator(i):
			continue
		if i == dropdown_idx:
			if id_cursor < ordered_ids.size():
				return ordered_ids[id_cursor]
			break
		id_cursor += 1

	return _cfg.game_profile_id  # fallback


func _on_profile_selected(dropdown_idx: int) -> void:
	var pid := _get_profile_id_for_dropdown_idx(dropdown_idx)
	_cfg.set_game_profile_id(pid)
	# Defer so the dropdown's signal finishes before we free it inside refresh()
	refresh.call_deferred()


func _on_add_game_pressed() -> void:
	var dialog := AddGameDialog.new()
	dialog.game_created.connect(func(profile_id: String) -> void:
		_cfg.set_game_profile_id(profile_id)
		_cfg.save_config()
		refresh()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


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
