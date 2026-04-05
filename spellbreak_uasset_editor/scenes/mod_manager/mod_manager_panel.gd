class_name ModManagerPanel extends VBoxContainer

## Persistent left-side panel: mod list, enable/disable toggles, pack, watch, launch, settings.
## Entirely code-driven — no .tscn needed.
## Wire open_asset_requested to main.gd to open .uasset files in the editor.

signal open_asset_requested(path: String)
signal open_settings_requested
signal status_changed(text: String, is_error: bool)

# ── Services ───────────────────────────────────────────────────────────────────
var _cfg:     ModConfigManager
var _state:   ModStateManager
var _packer:  PackingService
var _watcher: ModFileWatcher

# ── State ──────────────────────────────────────────────────────────────────────
var _mods:          Array = []  # from ModDiscovery.scan()
var _expanded_mod:  String = ""
var _log_lines:     Array  = []
const _MAX_LOG := 80

# ── UI references ──────────────────────────────────────────────────────────────
var _mod_list_container: VBoxContainer
var _watch_btn:          Button
var _pack_btn:           Button
var _log_label:          Label
var _log_scroll:         ScrollContainer


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical   = Control.SIZE_EXPAND_FILL

	_cfg     = ModConfigManager.new()
	_state   = ModStateManager.new().setup(_cfg.get_state_path())
	_packer  = PackingService.new().setup(_cfg)
	_watcher = ModFileWatcher.new().setup(_cfg, _state, _packer)

	# Connect service signals
	_packer.pack_started.connect(_on_pack_started)
	_packer.pack_finished.connect(_on_pack_finished)
	_packer.pack_log.connect(_append_log)
	_watcher.watch_status_changed.connect(_on_watch_status_changed)
	_watcher.pack_triggered.connect(_on_watch_pack_triggered)
	_cfg.config_changed.connect(_on_config_changed)

	_build_ui()
	_refresh_mods()

	# Auto-start watcher if any mods are enabled
	if _state.has_any_enabled() and _cfg.is_configured():
		_watcher.start()


func _exit_tree() -> void:
	_watcher.stop()
	_watcher.wait_to_finish()
	_packer.wait_to_finish()


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 0)

	# ── Toolbar ──
	var toolbar_margin := MarginContainer.new()
	toolbar_margin.add_theme_constant_override("margin_left", 8)
	toolbar_margin.add_theme_constant_override("margin_right", 8)
	toolbar_margin.add_theme_constant_override("margin_top", 6)
	toolbar_margin.add_theme_constant_override("margin_bottom", 4)
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)

	_pack_btn = Button.new()
	_pack_btn.text = "Pack"
	_pack_btn.icon = _icon("AssetLib")
	_pack_btn.tooltip_text = "Pack enabled mods into zzz_mods_P.pak"
	_pack_btn.add_theme_color_override("font_color", Color(0.952, 0.646, 0.564, 1.0))
	_pack_btn.pressed.connect(_on_pack_pressed)
	toolbar.add_child(_pack_btn)

	_watch_btn = Button.new()
	_watch_btn.text = "Watch"
	_watch_btn.icon = _icon("GuiVisibilityVisible")
	_watch_btn.tooltip_text = "Auto-pack on file save (toggle)"
	_watch_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_watch_btn.pressed.connect(_on_watch_pressed)
	toolbar.add_child(_watch_btn)

	var launch_btn := Button.new()
	launch_btn.text = "Launch"
	launch_btn.icon = _icon("Play")
	launch_btn.tooltip_text = "Launch Spellbreak"
	launch_btn.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
	launch_btn.pressed.connect(_on_launch_pressed)
	toolbar.add_child(launch_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.icon = _icon("Tools")
	settings_btn.tooltip_text = "Configure paths"
	settings_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	settings_btn.pressed.connect(func() -> void: open_settings_requested.emit())
	toolbar.add_child(settings_btn)


	toolbar_margin.add_child(toolbar)
	add_child(toolbar_margin)
	add_child(HSeparator.new())

	# ── Mod list (scrollable) ──
	var mod_scroll := ScrollContainer.new()
	mod_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mod_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_mod_list_container = VBoxContainer.new()
	_mod_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mod_list_container.add_theme_constant_override("separation", 2)
	mod_scroll.add_child(_mod_list_container)
	add_child(mod_scroll)

	add_child(HSeparator.new())

	# ── Log ──
	_log_scroll = ScrollContainer.new()
	_log_scroll.custom_minimum_size.y = 100
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.visible = false

	var log_margin := MarginContainer.new()
	log_margin.add_theme_constant_override("margin_left", 10)
	log_margin.add_theme_constant_override("margin_right", 10)
	log_margin.add_theme_constant_override("margin_top", 2)
	log_margin.add_theme_constant_override("margin_bottom", 6)
	_log_label = Label.new()
	_log_label.add_theme_font_size_override("font_size", 11)
	_log_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	log_margin.add_child(_log_label)
	_log_scroll.add_child(log_margin)
	add_child(_log_scroll)



## Returns a Godot editor icon by name, or null when EditorIcons aren't in the theme.
## Works when running embedded inside the editor; silently returns null otherwise.
func _icon(icon_name: String) -> Texture2D:
	if has_theme_icon(icon_name, &"EditorIcons"):
		return get_theme_icon(icon_name, &"EditorIcons")
	return null


func _make_panel(bg: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	pc.add_theme_stylebox_override("panel", style)
	return pc


# ── Mod list ───────────────────────────────────────────────────────────────────

func _refresh_mods() -> void:
	_mods = ModDiscovery.scan(_cfg.mods_dir)
	var names := _mods.map(func(m): return m["name"] as String)
	_state.prune(names)
	_rebuild_mod_list()
	_set_status("%d mod(s) found" % _mods.size())


func _rebuild_mod_list() -> void:
	for child in _mod_list_container.get_children():
		child.queue_free()

	if _mods.is_empty():
		var empty_lbl := Label.new()
		if _cfg.mods_dir.is_empty():
			empty_lbl.text = "Configure mods_dir\nin Settings"
		else:
			empty_lbl.text = "No mods in:\n%s\n\nEach mod = folder with g3/" % _cfg.mods_dir
		empty_lbl.add_theme_font_size_override("font_size", 11)
		empty_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		var pad := MarginContainer.new()
		pad.add_theme_constant_override("margin_left", 10)
		pad.add_theme_constant_override("margin_top", 12)
		pad.add_child(empty_lbl)
		_mod_list_container.add_child(pad)
		return

	for mod in _mods:
		_mod_list_container.add_child(_build_mod_row(mod))
		if _expanded_mod == mod["name"]:
			_mod_list_container.add_child(_build_mod_file_list(mod))


func _build_mod_row(mod: Dictionary) -> Control:
	var mod_name: String = mod["name"]
	var enabled:  bool   = _state.is_enabled(mod_name)
	var expanded: bool   = _expanded_mod == mod_name

	# Background colour: green tint when enabled, subtle highlight when expanded
	var bg_color: Color
	if enabled:
		bg_color = Color(0.08, 0.16, 0.08) if not expanded else Color(0.09, 0.19, 0.09)
	else:
		bg_color = Color(0.11, 0.11, 0.13) if not expanded else Color(0.13, 0.13, 0.16)

	var row_bg := _make_panel(bg_color)
	# Let the panel catch mouse events for click handling
	row_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	row_bg.gui_input.connect(func(event: InputEvent) -> void:
		if not event is InputEventMouseButton or not event.pressed:
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# Left-click: toggle file list expand/collapse
				_expanded_mod = "" if _expanded_mod == mod_name else mod_name
				_rebuild_mod_list()
			MOUSE_BUTTON_RIGHT:
				# Right-click: toggle enabled state
				_state.toggle(mod_name)
				_rebuild_mod_list()
	)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	# Prevent the margin from swallowing clicks before gui_input on the parent panel
	margin.mouse_filter = Control.MOUSE_FILTER_PASS

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS

	# Expand chevron
	var chevron := TextureRect.new()
	chevron.texture = _icon("GuiTreeArrowDown") if expanded else _icon("GuiTreeArrowRight")
	chevron.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	chevron.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.add_child(chevron)

	# Mod name + file count
	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_col.mouse_filter = Control.MOUSE_FILTER_PASS

	var name_lbl := Label.new()
	name_lbl.text = mod_name
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color",
		Color(0.55, 0.95, 0.55) if enabled else Color(0.85, 0.85, 0.85))
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	name_col.add_child(name_lbl)

	var info_lbl := Label.new()
	info_lbl.text = "%d files · %s · %s" % [
		mod["file_count"],
		ModDiscovery.fmt_size(mod["size_bytes"]),
		"on" if enabled else "off"
	]
	info_lbl.add_theme_font_size_override("font_size", 10)
	info_lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	info_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	name_col.add_child(info_lbl)
	hbox.add_child(name_col)

	# "Add Files" button — right-aligned, MOUSE_FILTER_STOP so it doesn't bubble to the panel
	var add_btn := Button.new()
	add_btn.text = "Add Files"
	add_btn.icon = _icon("Add")
	add_btn.tooltip_text = "Copy files from a source into this mod"
	add_btn.flat = true
	add_btn.add_theme_font_size_override("font_size", 11)
	add_btn.add_theme_color_override("font_color", Color(0.5, 0.75, 1.0))
	# MOUSE_FILTER_STOP is the default for Button — click won't reach the panel's gui_input
	add_btn.pressed.connect(func() -> void: _on_add_files_pressed(mod, add_btn))
	hbox.add_child(add_btn)

	margin.add_child(hbox)
	row_bg.add_child(margin)
	return row_bg


func _build_mod_file_list(mod: Dictionary) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 0)

	# Group files by their parent folder (relative to mod_path)
	var files := ModDiscovery.list_mod_files(mod["path"])
	var last_dir := ""

	for rel_path: String in files:
		var file_name: String = rel_path.get_file()
		var file_dir:  String = rel_path.get_base_dir()

		# Show a directory separator when we enter a new folder
		if file_dir != last_dir:
			last_dir = file_dir
			var dir_lbl := Label.new()
			dir_lbl.text = "  " + file_dir + "/"
			dir_lbl.add_theme_font_size_override("font_size", 10)
			dir_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
			dir_lbl.clip_text = true
			container.add_child(dir_lbl)

		var file_row := HBoxContainer.new()
		file_row.add_theme_constant_override("separation", 0)

		var file_btn := Button.new()
		file_btn.text = "    " + file_name       # indent under the dir label
		file_btn.tooltip_text = rel_path          # full relative path on hover
		file_btn.flat = true
		file_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		file_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		file_btn.clip_text = true
		file_btn.add_theme_font_size_override("font_size", 11)

		var full_path: String = (mod["path"] as String).path_join(rel_path)

		if rel_path.ends_with(".uasset"):
			file_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
			file_btn.pressed.connect(func() -> void:
				open_asset_requested.emit(full_path)
			)
		else:
			file_btn.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
			file_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.flat = true
		del_btn.tooltip_text = "Remove this file from the mod"
		del_btn.add_theme_font_size_override("font_size", 10)
		del_btn.add_theme_color_override("font_color", Color(0.6, 0.25, 0.25))
		del_btn.pressed.connect(func() -> void:
			_remove_mod_file(mod, full_path)
		)

		file_row.add_child(file_btn)
		file_row.add_child(del_btn)
		container.add_child(file_row)

	return container


## Delete a single file from the mod folder and prune any empty parent directories.
func _remove_mod_file(mod: Dictionary, full_path: String) -> void:
	var err := DirAccess.remove_absolute(full_path)
	if err != OK:
		_set_status("Failed to remove: %s" % full_path.get_file(), true)
		return
	# Walk up and remove any now-empty directories (stop at the mod root)
	var mod_path: String = mod["path"]
	var dir := full_path.get_base_dir()
	while dir.begins_with(mod_path) and dir != mod_path:
		var da := DirAccess.open(dir)
		if da:
			da.list_dir_begin()
			var has_contents := not da.get_next().is_empty()
			da.list_dir_end()
			if not has_contents:
				DirAccess.remove_absolute(dir)
		dir = dir.get_base_dir()
	_set_status("Removed %s from %s" % [full_path.get_file(), mod["name"]])
	_refresh_mods()


# ── Add Files from source ─────────────────────────────────────────────────────

func _on_add_files_pressed(mod: Dictionary, btn: Button) -> void:
	# Filter out sources with no path set
	var sources: Array = _cfg.sources.filter(
		func(s: Dictionary) -> bool: return not (s["path"] as String).is_empty()
	)
	if sources.is_empty():
		_set_status("No sources configured — add sources in Settings", true)
		return
	if sources.size() == 1:
		_open_add_files_dialog(mod, sources[0])
	else:
		_show_source_picker(mod, sources, btn)


## Drop down a source-picker menu anchored below btn.
func _show_source_picker(mod: Dictionary, sources: Array, btn: Button) -> void:
	var popup := PopupMenu.new()
	popup.name = "SourcePicker"
	for i in sources.size():
		var src: Dictionary = sources[i]
		var label: String = src["name"] if not (src["name"] as String).is_empty() else src["path"]
		popup.add_item(label, i)
	popup.id_pressed.connect(func(id: int) -> void:
		_open_add_files_dialog(mod, sources[id])
		popup.queue_free()
	)
	get_tree().root.add_child(popup)
	# Position the popup flush below the button, left-aligned with it
	var origin := btn.get_screen_position()
	popup.popup(Rect2i(int(origin.x), int(origin.y + btn.size.y), 0, 0))


## Open a multi-file browser rooted at source["path"]; copy selections into mod.
func _open_add_files_dialog(mod: Dictionary, source: Dictionary) -> void:
	var source_path: String = (source["path"] as String).rstrip("/")
	if not DirAccess.dir_exists_absolute(source_path):
		_set_status("Source folder not found: %s" % source_path, true)
		return
	var dialog := FileDialog.new()
	dialog.file_mode  = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access     = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.current_dir = source_path
	dialog.files_selected.connect(func(paths: PackedStringArray) -> void:
		_copy_files_to_mod(mod, source_path, paths)
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


## Mirror each selected file's path (relative to source_root) into mod["path"].
func _copy_files_to_mod(mod: Dictionary, source_root: String, file_paths: PackedStringArray) -> void:
	var mod_path: String = mod["path"]
	var copied  := 0
	var failed  := 0
	for src_file in file_paths:
		# Strip the source root to get the relative path, e.g. "g3/Content/BP/Foo.uasset"
		if not src_file.begins_with(source_root):
			_set_status("File is outside source root — skipped: %s" % src_file.get_file(), true)
			failed += 1
			continue
		var rel := src_file.substr(source_root.length()).lstrip("/")
		var dst := mod_path.path_join(rel)
		# Create any missing directories
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		# Copy bytes
		var data  := FileAccess.get_file_as_bytes(src_file)
		var out   := FileAccess.open(dst, FileAccess.WRITE)
		if out:
			out.store_buffer(data)
			out.close()
			copied += 1
		else:
			_set_status("Could not write: %s" % dst.get_file(), true)
			failed += 1
	if copied > 0:
		var msg := "Copied %d file(s) to %s" % [copied, mod["name"]]
		if failed > 0:
			msg += " (%d failed)" % failed
		_set_status(msg)
		_refresh_mods()   # update file count + expand list if already open


# ── Actions ────────────────────────────────────────────────────────────────────

func _on_pack_pressed() -> void:
	if not _cfg.is_configured():
		_set_status("Configure paths in Settings first", true)
		return
	var enabled_names := _state.get_enabled_names()
	if enabled_names.is_empty():
		_set_status("No mods enabled — right-click a mod to enable", true)
		return
	var enabled_mods := _mods.filter(func(m): return m["name"] in enabled_names)
	_log_lines.clear()
	_log_scroll.visible = true
	_append_log("Packing %d mod(s)..." % enabled_mods.size())
	_packer.pack(enabled_mods)


func _on_watch_pressed() -> void:
	if not _cfg.is_configured():
		_set_status("Configure paths in Settings first", true)
		return
	if _watcher.is_watching():
		_watcher.stop()
	else:
		_watcher.start()


func _on_launch_pressed() -> void:
	var cmd := _cfg.launch_cmd.strip_edges()
	if cmd.is_empty():
		_set_status("No launch command set — configure in Settings", true)
		return
	var parts := cmd.split(" ", false)
	var exe   := parts[0]
	var args: PackedStringArray = []
	for i in range(1, parts.size()):
		args.append(parts[i])
	var err := OS.create_process(exe, args)
	if err < 0:
		_set_status("Launch failed", true)
	else:
		_set_status("Launched: %s" % cmd)


# ── Service signal handlers ────────────────────────────────────────────────────

func _on_pack_started() -> void:
	_pack_btn.disabled = true
	_set_status("Packing...")


func _on_pack_finished(success: bool, message: String) -> void:
	_pack_btn.disabled = false
	_append_log(("✓ " if success else "✗ ") + message)
	_set_status(message, not success)
	await get_tree().process_frame
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


func _on_watch_status_changed(active: bool) -> void:
	if active:
		_watch_btn.text = "Watching"
		_watch_btn.icon = _icon("GuiVisibilityVisible")
		_watch_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
		_set_status("Watching for changes...")
	else:
		_watch_btn.text = "Watch"
		_watch_btn.icon = _icon("GuiVisibilityHidden")
		_watch_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_set_status("Watcher stopped")


func _on_watch_pack_triggered(n: int) -> void:
	_set_status("[watch #%d] Packing..." % n)


func _on_config_changed() -> void:
	_state = ModStateManager.new().setup(_cfg.get_state_path())
	# Stop and FULLY JOIN the old watcher before replacing it.
	# Without wait_to_finish() the old RefCounted watcher is freed while its
	# thread is still sleeping, which produces the ~Thread warning.
	_watcher.stop()
	_watcher.wait_to_finish()
	_watcher = ModFileWatcher.new().setup(_cfg, _state, _packer)
	_watcher.watch_status_changed.connect(_on_watch_status_changed)
	_watcher.pack_triggered.connect(_on_watch_pack_triggered)
	_refresh_mods()


# ── Log ────────────────────────────────────────────────────────────────────────

func _append_log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > _MAX_LOG:
		_log_lines = _log_lines.slice(_log_lines.size() - _MAX_LOG)
	_log_label.text = "\n".join(_log_lines)


func _set_status(text: String, error: bool = false) -> void:
	status_changed.emit(text, error)


## Exposes the shared config so main.gd can pass it to ModSettingsTab.
func get_config() -> ModConfigManager:
	return _cfg
