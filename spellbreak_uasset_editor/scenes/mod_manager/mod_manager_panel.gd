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
var _mods:           Array      = []  # from ModDiscovery.scan()
var _collapsed_mods: Dictionary = {}  # mod_name -> bool  (default true = collapsed)
var _collapsed_dirs: Dictionary = {}  # "mod_name::rel_dir" -> bool (true = collapsed)
var _log_lines:      Array      = []
const _MAX_LOG := 80

# File clipboard — independent of the uasset ClipboardManager
var _file_clipboard:    Array = []   # [{mod, rel_path, full_path}, ...]
var _clipboard_is_cut:  bool  = false

# Tree button IDs
const _BTN_ADD := 0
const _BTN_DEL := 0

# ── UI references ──────────────────────────────────────────────────────────────
var _mod_tree:  Tree
var _watch_btn: Button
var _pack_btn:  Button
var _log_label: Label
var _log_scroll: ScrollContainer


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
	toolbar_margin.add_theme_constant_override("margin_left",   8)
	toolbar_margin.add_theme_constant_override("margin_right",  8)
	toolbar_margin.add_theme_constant_override("margin_top",    6)
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

	# Spacer pushes the next buttons to the right
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var new_mod_btn := Button.new()
	new_mod_btn.text = "New Mod"
	new_mod_btn.icon = _icon("FolderCreate")
	new_mod_btn.tooltip_text = "Create a new mod folder"
	new_mod_btn.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))
	new_mod_btn.pressed.connect(_on_new_mod_pressed)
	toolbar.add_child(new_mod_btn)

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

	# ── Mod tree ──
	_mod_tree = Tree.new()
	_mod_tree.hide_root = true
	_mod_tree.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_mod_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mod_tree.select_mode = Tree.SELECT_MULTI
	_mod_tree.allow_rmb_select = true
	_mod_tree.item_activated.connect(_on_tree_item_activated)
	_mod_tree.item_mouse_selected.connect(_on_tree_item_mouse_selected)
	_mod_tree.button_clicked.connect(_on_tree_button_clicked)
	_mod_tree.empty_clicked.connect(func(_pos: Vector2, _btn: int) -> void: clear_selection())
	add_child(_mod_tree)

	add_child(HSeparator.new())

	# ── Log ──
	_log_scroll = ScrollContainer.new()
	_log_scroll.custom_minimum_size.y = 100
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.visible = false

	var log_margin := MarginContainer.new()
	log_margin.add_theme_constant_override("margin_left",   10)
	log_margin.add_theme_constant_override("margin_right",  10)
	log_margin.add_theme_constant_override("margin_top",     2)
	log_margin.add_theme_constant_override("margin_bottom",  6)
	_log_label = Label.new()
	#_log_label.add_theme_font_size_override("font_size", 11)
	_log_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	log_margin.add_child(_log_label)
	_log_scroll.add_child(log_margin)
	add_child(_log_scroll)


## Returns a Godot editor icon by name, or null when EditorIcons aren't in the theme.
func _icon(icon_name: String) -> Texture2D:
	if has_theme_icon(icon_name, &"EditorIcons"):
		return get_theme_icon(icon_name, &"EditorIcons")
	return null


# ── Mod list ───────────────────────────────────────────────────────────────────

func _refresh_mods() -> void:
	_mods = ModDiscovery.scan(_cfg.mods_dir)
	var names := _mods.map(func(m): return m["name"] as String)
	_state.prune(names)
	_rebuild_mod_list()
	_set_status("%d mod(s) found" % _mods.size())


func _rebuild_mod_list() -> void:
	# Persist folder collapse state from the live tree before clearing.
	_save_collapse_state()
	_mod_tree.clear()

	var root := _mod_tree.create_item()  # hidden root

	if _mods.is_empty():
		var item := _mod_tree.create_item(root)
		item.set_text(0, "No mods found" if not _cfg.mods_dir.is_empty()
				else "Configure mods_dir in Settings")
		item.set_custom_color(0, Color(0.45, 0.45, 0.45))
		item.set_selectable(0, false)
		return

	for mod in _mods:
		_build_mod_item(root, mod)


## Walk the live tree and save collapsed state for mod and folder items before a rebuild.
func _save_collapse_state() -> void:
	if not is_instance_valid(_mod_tree) or not _mod_tree.get_root():
		return
	var mod_item := _mod_tree.get_root().get_first_child()
	while mod_item:
		var mod_meta: Dictionary = mod_item.get_metadata(0)
		if mod_meta.get("type") == "mod":
			_collapsed_mods[(mod_meta["mod"] as Dictionary)["name"] as String] = mod_item.collapsed
		var folder_item := mod_item.get_first_child()
		while folder_item:
			var meta: Dictionary = folder_item.get_metadata(0)
			if meta.get("type") == "folder":
				_collapsed_dirs[meta["key"] as String] = folder_item.collapsed
			folder_item = folder_item.get_next()
		mod_item = mod_item.get_next()


func _build_mod_item(root: TreeItem, mod: Dictionary) -> void:
	var mod_name: String = mod["name"]
	var enabled:  bool   = _state.is_enabled(mod_name)

	var item := _mod_tree.create_item(root)
	item.set_text(0, mod_name)
	#item.set_custom_font_size(0, 14)
	item.set_custom_color(0, Color(0.45, 0.9, 0.45) if enabled else Color(0.82, 0.82, 0.82))
	item.set_icon(0, _icon("GuiVisibilityVisible" if enabled else "GuiVisibilityHidden"))
	item.set_tooltip_text(0, "%d files · %s\n%s  (right-click to toggle)" % [
		mod["file_count"],
		ModDiscovery.fmt_size(mod["size_bytes"]),
		"Enabled" if enabled else "Disabled",
	])
	item.set_metadata(0, {"type": "mod", "mod": mod})
	# Default collapsed; remember user-expanded state across rebuilds.
	item.collapsed = _collapsed_mods.get(mod_name, true)

	# Add Files button (icon only, anchored to the item's right side)
	var add_icon := _icon("Add")
	if add_icon:
		item.add_button(0, add_icon, _BTN_ADD, false, "Add files to this mod")

	_build_mod_files(item, mod)


func _build_mod_files(mod_item: TreeItem, mod: Dictionary) -> void:
	var mod_name: String = mod["name"]
	var files := ModDiscovery.list_mod_files(mod["path"])

	# Group files by relative directory, preserving discovery order.
	var dir_order: Array    = []
	var groups:    Dictionary = {}
	for rel_path: String in files:
		var d: String = rel_path.get_base_dir()
		if d not in groups:
			groups[d] = []
			dir_order.append(d)
		(groups[d] as Array).append(rel_path)

	for dir: String in dir_order:
		var dir_key: String = mod_name + "::" + dir

		var dir_item := _mod_tree.create_item(mod_item)
		dir_item.set_text(0, dir + "/")
		#dir_item.set_custom_font_size(0, 12)
		dir_item.set_custom_color(0, Color(0.5, 0.5, 0.58))
		dir_item.set_selectable(0, false)
		dir_item.set_metadata(0, {"type": "folder", "key": dir_key})
		dir_item.collapsed = _collapsed_dirs.get(dir_key, false)

		for rel_path: String in (groups[dir] as Array):
			var full_path: String = (mod["path"] as String).path_join(rel_path)
			var is_uasset := rel_path.ends_with(".uasset")

			var file_item := _mod_tree.create_item(dir_item)
			file_item.set_text(0, rel_path.get_file())
			#file_item.set_custom_font_size(0, 13)
			file_item.set_tooltip_text(0, rel_path)
			file_item.set_custom_color(0,
				Color(0.5, 0.75, 1.0) if is_uasset else Color(0.62, 0.62, 0.62))
			file_item.set_selectable(0, true)
			file_item.set_metadata(0, {
				"type": "file", "mod": mod,
				"rel_path": rel_path, "full_path": full_path
			})

			var del_icon := _icon("Remove")
			if del_icon:
				file_item.add_button(0, del_icon, _BTN_DEL, false, "Remove from mod")


# ── Tree signal handlers ───────────────────────────────────────────────────────

## Double-click a .uasset file → open it in the editor.
## Using activated (double-click) so single-click safely builds multi-selection.
func _on_tree_item_activated() -> void:
	var item := _mod_tree.get_selected()
	if not item:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.get("type") == "file" and (meta["rel_path"] as String).ends_with(".uasset"):
		open_asset_requested.emit(meta["full_path"] as String)


## Left-click a mod item → expand/collapse.  Right-click → toggle enabled/disabled.
func _on_tree_item_mouse_selected(_position: Vector2, mouse_button_index: int) -> void:
	var item := _mod_tree.get_selected()
	if not item:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.get("type") != "mod":
		return
	match mouse_button_index:
		MOUSE_BUTTON_LEFT:
			# Toggle collapse in-place — no rebuild needed.
			item.collapsed = not item.collapsed
		MOUSE_BUTTON_RIGHT:
			_state.toggle((meta["mod"] as Dictionary)["name"] as String)
			# Defer: Tree blocks clear()/create_item() while inside a signal callback.
			_rebuild_mod_list.call_deferred()


## Button clicks: Add (mod items) or Delete (file items).
func _on_tree_button_clicked(item: TreeItem, _column: int, id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var meta: Dictionary = item.get_metadata(0)
	match meta.get("type"):
		"mod":
			if id == _BTN_ADD:
				_on_add_files_pressed(meta["mod"] as Dictionary)
		"file":
			if id == _BTN_DEL:
				# Defer: _rebuild_mod_list calls clear() — blocked inside a Tree signal.
				var mod_ref: Dictionary = meta["mod"]
				var path_ref: String    = meta["full_path"]
				(func() -> void: _remove_mod_file(mod_ref, path_ref)).call_deferred()


# ── Selection helpers ──────────────────────────────────────────────────────────

## Collect all selected file items as metadata snapshots.
func _get_selected_files() -> Array:
	var result: Array = []
	var item := _mod_tree.get_next_selected(null)
	while item:
		var meta: Dictionary = item.get_metadata(0)
		if meta.get("type") == "file":
			result.append({
				"mod":       meta["mod"],
				"rel_path":  meta["rel_path"],
				"full_path": meta["full_path"],
			})
		item = _mod_tree.get_next_selected(item)
	return result


## Walk up the tree from a TreeItem to find the ancestor mod dict.
func _get_mod_for_item(item: TreeItem) -> Variant:
	var meta: Dictionary = item.get_metadata(0)
	if meta.get("type") == "mod":
		return meta["mod"]
	var p := item.get_parent()
	while p and p != _mod_tree.get_root():
		var pm: Dictionary = p.get_metadata(0)
		if pm.get("type") == "mod":
			return pm["mod"]
		p = p.get_parent()
	return null


## Return the mod dict of the first selected item (used as paste / create target).
func _get_selected_mod() -> Variant:
	var item := _mod_tree.get_next_selected(null)
	while item:
		var mod: Variant = _get_mod_for_item(item)
		if mod != null:
			return mod
		item = _mod_tree.get_next_selected(item)
	return null


# ── Public clipboard / action API (called from main.gd) ───────────────────────

func copy_selection() -> void:
	_file_clipboard   = _get_selected_files()
	_clipboard_is_cut = false
	if _file_clipboard.is_empty():
		return
	_set_status("Copied %d file(s)" % _file_clipboard.size())


func cut_selection() -> void:
	_file_clipboard   = _get_selected_files()
	_clipboard_is_cut = true
	if _file_clipboard.is_empty():
		return
	_set_status("Cut %d file(s) — paste to move" % _file_clipboard.size())


func paste_clipboard() -> void:
	if _file_clipboard.is_empty():
		_set_status("Nothing to paste", true)
		return
	var target: Variant = _get_selected_mod()
	if target == null:
		_set_status("Select a mod to paste into", true)
		return
	var target_mod := target as Dictionary
	var dst_root: String = target_mod["path"]

	var copied := 0
	var failed := 0
	for entry: Dictionary in _file_clipboard:
		# Preserve the full relative path so folder structure is maintained.
		var rel: String = entry["rel_path"]
		var dst: String = dst_root.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var data := FileAccess.get_file_as_bytes(entry["full_path"] as String)
		var out  := FileAccess.open(dst, FileAccess.WRITE)
		if out:
			out.store_buffer(data)
			out.close()
			copied += 1
		else:
			failed += 1

	# For cut: delete sources only after all copies succeeded.
	if _clipboard_is_cut and copied > 0:
		for entry: Dictionary in _file_clipboard:
			_delete_file_raw(entry["mod"] as Dictionary, entry["full_path"] as String)
		_file_clipboard.clear()
		_clipboard_is_cut = false

	var msg := "Pasted %d file(s) into %s" % [copied, target_mod["name"]]
	if failed > 0:
		msg += " (%d failed)" % failed
	_set_status(msg, failed > 0 and copied == 0)
	_refresh_mods()


func delete_selection() -> void:
	var files := _get_selected_files()
	if files.is_empty():
		return
	for entry: Dictionary in files:
		_delete_file_raw(entry["mod"] as Dictionary, entry["full_path"] as String)
	_set_status("Deleted %d file(s)" % files.size())
	_refresh_mods()


func clear_selection() -> void:
	_mod_tree.deselect_all()


## Open the Add Files dialog for the selected mod (or the mod owning the selection).
func create_file() -> void:
	var mod: Variant = _get_selected_mod()
	if mod == null:
		_set_status("Select a mod first", true)
		return
	_on_add_files_pressed(mod as Dictionary)


# ── File management ────────────────────────────────────────────────────────────

## Delete a file and prune empty parent dirs up to the mod root.
## Returns OK or an error code. Does NOT emit status or refresh — callers do that.
func _delete_file_raw(mod: Dictionary, full_path: String) -> Error:
	var err := DirAccess.remove_absolute(full_path)
	if err != OK:
		return err
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
	return OK


## Delete one file via the tree ✕ button: reports status and refreshes.
func _remove_mod_file(mod: Dictionary, full_path: String) -> void:
	var err := _delete_file_raw(mod, full_path)
	if err != OK:
		_set_status("Failed to remove: %s" % full_path.get_file(), true)
		return
	_set_status("Removed %s from %s" % [full_path.get_file(), mod["name"]])
	_refresh_mods()


# ── Add Files from source ──────────────────────────────────────────────────────

func _on_add_files_pressed(mod: Dictionary) -> void:
	var sources: Array = _cfg.sources.filter(
		func(s: Dictionary) -> bool: return not (s["path"] as String).is_empty()
	)
	if sources.is_empty():
		_set_status("No sources configured — add sources in Settings", true)
		return
	if sources.size() == 1:
		_open_add_files_dialog(mod, sources[0])
	else:
		_show_source_picker(mod, sources)


## Drop-down source picker anchored to the current mouse position.
func _show_source_picker(mod: Dictionary, sources: Array) -> void:
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
	var mp := DisplayServer.mouse_get_position()
	popup.popup(Rect2i(mp.x, mp.y, 0, 0))


## Open a multi-file browser rooted at source["path"]; copy selections into mod.
func _open_add_files_dialog(mod: Dictionary, source: Dictionary) -> void:
	var source_path: String = (source["path"] as String).rstrip("/")
	if not DirAccess.dir_exists_absolute(source_path):
		_set_status("Source folder not found: %s" % source_path, true)
		return
	var dialog := FileDialog.new()
	dialog.file_mode       = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access          = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.current_dir     = source_path
	dialog.files_selected.connect(func(paths: PackedStringArray) -> void:
		_copy_files_to_mod(mod, source_path, paths)
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


## Mirror each selected file's path (relative to source_root) into mod["path"].
func _copy_files_to_mod(mod: Dictionary, source_root: String, file_paths: PackedStringArray) -> void:
	var mod_path: String = mod["path"]
	var copied := 0
	var failed := 0
	for src_file in file_paths:
		if not src_file.begins_with(source_root):
			_set_status("File is outside source root — skipped: %s" % src_file.get_file(), true)
			failed += 1
			continue
		var rel := src_file.substr(source_root.length()).lstrip("/")
		var dst := mod_path.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var data := FileAccess.get_file_as_bytes(src_file)
		var out  := FileAccess.open(dst, FileAccess.WRITE)
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
		_refresh_mods()


# ── New Mod ────────────────────────────────────────────────────────────────────

func _on_new_mod_pressed() -> void:
	if _cfg.mods_dir.is_empty():
		_set_status("Configure mods_dir in Settings first", true)
		return

	# Build a small input dialog inline.
	var dialog := ConfirmationDialog.new()
	dialog.title = "New Mod"
	dialog.ok_button_text = "Create"
	dialog.min_size = Vector2i(300, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "Mod folder name:"
	var edit := LineEdit.new()
	edit.placeholder_text = "MyModName"
	vbox.add_child(lbl)
	vbox.add_child(edit)
	dialog.add_child(vbox)
	add_child(dialog)

	dialog.confirmed.connect(func() -> void:
		var mod_name := edit.text.strip_edges()
		if mod_name.is_empty():
			dialog.queue_free()
			return
		var mod_path := _cfg.mods_dir.path_join(mod_name)
		if DirAccess.dir_exists_absolute(mod_path):
			_set_status("Mod '%s' already exists" % mod_name, true)
			dialog.queue_free()
			return
		var err := DirAccess.make_dir_recursive_absolute(mod_path.path_join("g3/Content"))
		if err != OK:
			_set_status("Failed to create mod folder", true)
			dialog.queue_free()
			return
		_set_status("Created mod: " + mod_name)
		_refresh_mods()
		dialog.queue_free()
	)

	dialog.popup_centered()
	# Focus the text field after the popup opens.
	edit.grab_focus.call_deferred()


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

	# Pure URL schemes (e.g. "steam://rungameid/...") go through the OS shell.
	# Only triggers when :// appears before any space — "steam steam://..." is
	# an exe + argument and falls through to normal parsing below.
	
	var slash_pos := cmd.find("://")
	if slash_pos != -1 and not " " in cmd.left(slash_pos):
		var err := OS.shell_open(cmd)
		_set_status("Launch failed" if err != OK else "Launched: %s" % cmd, err != OK)
		return

	# Parse exe + args, respecting a quoted exe path for paths with spaces.
	# Accepted forms:
	#   C:\NoSpaces\game.exe -arg1 -arg2
	#   "C:\With Spaces\game.exe" -arg1 -arg2
	var exe: String
	var args: PackedStringArray = []
	if cmd.begins_with('"'):
		var close := cmd.find('"', 1)
		if close == -1:
			exe = cmd.trim_prefix('"')          # unterminated quote — use whole string
		else:
			exe = cmd.substr(1, close - 1)
			var rest := cmd.substr(close + 1).strip_edges()
			if not rest.is_empty():
				args = rest.split(" ", false)
	else:
		var parts := cmd.split(" ", false)
		exe = parts[0]
		for i in range(1, parts.size()):
			args.append(parts[i])

	var error := OS.create_process(exe, args)
	_set_status("Launch failed" if error < 0 else "Launched: %s" % cmd, error < 0)


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
