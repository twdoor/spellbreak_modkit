class_name ModSettingsTab extends VBoxContainer

## Settings tab for the Mod Manager — lives as a hidden tab, opened by the Settings button.
## Call setup(cfg) before adding to the scene tree.
## Emits close_requested when the user clicks Save or Cancel.

signal close_requested

var _cfg:               ModConfigManager
var _sources_container: VBoxContainer


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
	outer.add_theme_constant_override("margin_left",   20)
	outer.add_theme_constant_override("margin_right",  20)
	outer.add_theme_constant_override("margin_top",    16)
	outer.add_theme_constant_override("margin_bottom", 16)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	outer.add_child(content)
	scroll.add_child(outer)
	add_child(scroll)

	# ── Game directory ──
	content.add_child(_section("Game Directory"))
	content.add_child(_hint("The Spellbreak installation folder — the one that contains g3/."))
	content.add_child(_dir_row(
		func() -> String: return _cfg.game_dir,
		func(v: String) -> void: _cfg.game_dir = v,
		"/path/to/Spellbreak"
	))

	# ── Mods directory ──
	content.add_child(_section("Mods Directory"))
	content.add_child(_hint("Each subfolder is one mod. Each mod must contain a g3/ folder with your edited assets."))
	content.add_child(_dir_row(
		func() -> String: return _cfg.mods_dir,
		func(v: String) -> void: _cfg.mods_dir = v,
		"/path/to/mods"
	))

	# ── Launch command ──
	content.add_child(_section("Launch Command"))
	content.add_child(_hint("Shell command to start the game. Leave blank to disable the Launch button."))
	var launch_edit := _line_edit(_cfg.launch_cmd, "steam steam://rungameid/1399780")
	launch_edit.text_changed.connect(func(v: String) -> void: _cfg.launch_cmd = v)
	content.add_child(launch_edit)

	# ── u4pak directory ──
	content.add_child(_section("u4pak Directory  (optional)"))
	content.add_child(_hint(
		"Path to the folder containing u4pak.py. Leave blank — the tool auto-detects it from the project location."
	))
	content.add_child(_dir_row(
		func() -> String: return _cfg.u4pak_dir,
		func(v: String) -> void: _cfg.u4pak_dir = v,
		_cfg.get_u4pak_path().get_base_dir() + "  (auto-detected)"
	))

	# ── Sources ──
	content.add_child(_section("Sources"))
	content.add_child(_hint(
		"Register exported asset directories for reference — the base game export, older game versions, reference mods, etc. " +
		"Each source has a name and a path to its root folder (the one containing g3/)."
	))

	_sources_container = VBoxContainer.new()
	_sources_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sources_container.add_theme_constant_override("separation", 6)
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
	btn_margin.add_theme_constant_override("margin_left",   20)
	btn_margin.add_theme_constant_override("margin_right",  20)
	btn_margin.add_theme_constant_override("margin_top",     8)
	btn_margin.add_theme_constant_override("margin_bottom",  8)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.add_theme_color_override("font_color", Color(0.4, 0.85, 0.4))
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
	row.add_theme_constant_override("separation", 6)

	# Name — short fixed-width field
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Name"
	name_edit.text = str(entry.get("name", ""))
	name_edit.custom_minimum_size.x = 160
	name_edit.text_changed.connect(func(v: String) -> void: entry["name"] = v)
	row.add_child(name_edit)

	# Path — expands to fill remaining space
	var path_edit := LineEdit.new()
	path_edit.placeholder_text = "/path/to/exported/source  (folder containing g3/)"
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
	remove_btn.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
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
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	return lbl


func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
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
	row.add_theme_constant_override("separation", 6)

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
