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
var _new_mod_from_pak_service: BaseSourceService

# ── State ──────────────────────────────────────────────────────────────────────
var _mods:           Array      = []  # from ModDiscovery.scan()
var _collapsed_mods: Dictionary = {}  # mod_name -> bool  (default true = collapsed)
var _collapsed_dirs: Dictionary = {}  # "mod_name::rel_dir" -> bool (true = collapsed)
var _log_lines:      Array      = []
const _MAX_LOG := 80
const _WATCH_TOGGLE_COOLDOWN_SEC := 0.25
const _TEXT_FILE_EXTENSIONS := [
	"txt", "cfg", "conf", "config", "ini", "json", "jsonc",
	"yaml", "yml", "toml", "xml", "csv", "tsv", "md", "markdown",
	"log", "properties", "props", "manifest", "bat", "cmd", "ps1",
	"sh", "py", "gd", "lua", "js", "ts", "css", "html", "htm"
]
const _TEXT_FILE_NAMES := [
	"readme", "license", "changelog", "credits", "config", "settings"
]

# File clipboard — independent of the uasset ClipboardManager
var _file_clipboard:    Array = []   # [{mod, rel_path, full_path}, ...]
var _clipboard_is_cut:  bool  = false
var _watch_toggle_locked := false
var _pending_new_mod_from_pak := ""
var _pending_new_mod_from_pak_path := ""

# Tree button IDs
const _BTN_ADD := 0
const _BTN_DEL := 0
const _BTN_OPEN_EXTERNAL := 1

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
	_new_mod_from_pak_service = BaseSourceService.new().setup(_cfg)

	# Connect service signals
	_packer.pack_started.connect(_on_pack_started)
	_packer.pack_finished.connect(_on_pack_finished)
	_packer.pack_log.connect(_append_log)
	_watcher.watch_status_changed.connect(_on_watch_status_changed)
	_watcher.pack_triggered.connect(_on_watch_pack_triggered)
	_new_mod_from_pak_service.generate_started.connect(_on_new_mod_from_pak_started)
	_new_mod_from_pak_service.generate_finished.connect(_on_new_mod_from_pak_finished)
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
	_new_mod_from_pak_service.wait_to_finish()


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 0)

	# ── Toolbar ──
	var toolbar_margin := MarginContainer.new()
	toolbar_margin.add_theme_constant_override("margin_left",   AppTheme.MARGIN_TOOLBAR_H)
	toolbar_margin.add_theme_constant_override("margin_right",  AppTheme.MARGIN_TOOLBAR_H)
	toolbar_margin.add_theme_constant_override("margin_top",    AppTheme.MARGIN_TOOLBAR_TOP)
	toolbar_margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_TOOLBAR_BOTTOM)
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	_pack_btn = Button.new()
	_pack_btn.text = "Pack"
	_pack_btn.icon = _icon("AssetLib")
	_pack_btn.tooltip_text = "Pack enabled mods into a .pak file"
	_pack_btn.add_theme_color_override("font_color", AppTheme.BTN_PACK)
	_pack_btn.pressed.connect(_on_pack_pressed)
	toolbar.add_child(_pack_btn)

	_watch_btn = Button.new()
	_watch_btn.text = "Watch"
	_watch_btn.icon = _icon("GuiVisibilityVisible")
	_watch_btn.tooltip_text = "Auto-pack on file save (toggle)"
	AppTheme.style_muted_btn(_watch_btn)
	_watch_btn.pressed.connect(_on_watch_pressed)
	toolbar.add_child(_watch_btn)

	var launch_btn := Button.new()
	launch_btn.text = "Launch"
	launch_btn.icon = _icon("Play")
	launch_btn.tooltip_text = "Launch game"
	launch_btn.add_theme_color_override("font_color", AppTheme.BTN_LAUNCH)
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
	new_mod_btn.add_theme_color_override("font_color", AppTheme.BTN_NEW_MOD)
	new_mod_btn.pressed.connect(_on_new_mod_pressed)
	toolbar.add_child(new_mod_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.icon = _icon("Tools")
	settings_btn.tooltip_text = "Configure paths"
	AppTheme.style_muted_btn(settings_btn)
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
	_mod_tree.gui_input.connect(_on_mod_tree_gui_input)
	_mod_tree.empty_clicked.connect(func(_pos: Vector2, _btn: int) -> void: clear_selection())
	add_child(_mod_tree)

	add_child(HSeparator.new())

	# ── Log ──
	_log_scroll = ScrollContainer.new()
	_log_scroll.custom_minimum_size.y = 100
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_log_scroll.visible = false

	var log_margin := MarginContainer.new()
	log_margin.add_theme_constant_override("margin_left",   AppTheme.MARGIN_LOG_H)
	log_margin.add_theme_constant_override("margin_right",  AppTheme.MARGIN_LOG_H)
	log_margin.add_theme_constant_override("margin_top",    AppTheme.MARGIN_LOG_TOP)
	log_margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_LOG_BOTTOM)
	_log_label = Label.new()
	AppTheme.style_muted(_log_label)
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	log_margin.add_child(_log_label)
	_log_scroll.add_child(log_margin)
	add_child(_log_scroll)


## Returns a Godot editor icon by name, or null when EditorIcons aren't in the theme.
func _icon(icon_name: String) -> Texture2D:
	if has_theme_icon(icon_name, &"EditorIcons"):
		return get_theme_icon(icon_name, &"EditorIcons")
	return null


func _is_text_file_path(path: String) -> bool:
	var file_name := path.get_file().to_lower()
	for ext in [".uasset", ".uexp", ".ubulk", ".umap"]:
		if file_name.ends_with(ext):
			return false
	if file_name.get_extension() in _TEXT_FILE_EXTENSIONS:
		return true
	return file_name in _TEXT_FILE_NAMES


func _open_external_file(path: String) -> void:
	var full_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(full_path):
		_set_status("File not found: %s" % full_path.get_file(), true)
		return
	var result: int = ERR_CANT_OPEN
	if _is_text_file_path(full_path):
		result = _open_text_file(full_path)
	if result < 0:
		result = _open_file_with_system_app(full_path)
	if result < 0 and OS.shell_open(full_path) != OK:
		_set_status("Could not open file: %s" % full_path.get_file(), true)
		return
	_set_status("Opening %s" % full_path.get_file())


func _open_text_file(path: String) -> int:
	var result := _open_editor_from_environment(path)
	if result >= 0:
		return result
	match OS.get_name():
		"Windows":
			return _create_process_if_found(["notepad.exe", "notepad"], [path])
		"macOS":
			return _create_process_if_found(["open", "/usr/bin/open"], ["-t", path])
		_:
			result = _create_process_if_found([
				"zeditor", "zed", "code", "codium", "subl",
				"gedit", "kate", "kwrite", "mousepad", "xed", "pluma", "geany"
			], [path])
			if result >= 0:
				return result
			return _open_terminal_editor(path)


func _open_editor_from_environment(path: String) -> int:
	for env_name in ["VISUAL", "EDITOR"]:
		var command := OS.get_environment(env_name).strip_edges()
		if command.is_empty():
			continue
		var result := _open_editor_command(command, path)
		if result >= 0:
			return result
	return ERR_FILE_NOT_FOUND


func _open_editor_command(command: String, path: String) -> int:
	var parts := ProcessUtils.parse_command_line(command)
	if parts.is_empty():
		return ERR_INVALID_PARAMETER
	var executable := ProcessUtils.find_executable([parts[0]])
	if executable.is_empty():
		return ERR_FILE_NOT_FOUND
	var args := PackedStringArray()
	for i in range(1, parts.size()):
		args.append(parts[i])
	args.append(path)
	if _is_terminal_editor(executable):
		return _open_terminal_command(executable, args)
	return OS.create_process(executable, args)


func _open_terminal_editor(path: String) -> int:
	var editor := ProcessUtils.find_executable(["nvim", "vim", "nano", "vi"])
	if editor.is_empty():
		return ERR_FILE_NOT_FOUND
	return _open_terminal_command(editor, PackedStringArray([path]))


func _open_terminal_command(command: String, args: PackedStringArray) -> int:
	var terminal := ProcessUtils.find_executable(["xdg-terminal-exec", "/usr/bin/xdg-terminal-exec"])
	if not terminal.is_empty():
		var xdg_terminal_args := PackedStringArray([command])
		xdg_terminal_args.append_array(args)
		return OS.create_process(terminal, xdg_terminal_args)

	terminal = ProcessUtils.find_executable(["ghostty", "alacritty", "kitty", "foot"])
	if terminal.is_empty():
		return ERR_FILE_NOT_FOUND
	var terminal_args := PackedStringArray(["-e", command])
	terminal_args.append_array(args)
	return OS.create_process(terminal, terminal_args)


func _is_terminal_editor(executable: String) -> bool:
	var editor_name := executable.get_file().get_basename().to_lower()
	return editor_name in ["nvim", "vim", "nano", "vi", "emacsclient", "emacs"]


func _open_file_with_system_app(path: String) -> int:
	match OS.get_name():
		"Windows":
			return _open_windows_file(path)
		"macOS":
			return _create_process_if_found(["open", "/usr/bin/open"], [path])
		_:
			return _open_unix_file(path)


func _open_windows_file(path: String) -> int:
	var powershell := ProcessUtils.find_executable(["powershell.exe", "pwsh.exe"])
	if not powershell.is_empty():
		return OS.create_process(powershell, PackedStringArray([
			"-NoProfile",
			"-WindowStyle", "Hidden",
			"-ExecutionPolicy", "Bypass",
			"-Command", "Start-Process -FilePath $args[0]",
			path
		]))
	var cmd := ProcessUtils.find_executable(["cmd.exe", "cmd"])
	if cmd.is_empty():
		return ERR_FILE_NOT_FOUND
	return OS.create_process(cmd, PackedStringArray(["/C", "start", "", path]))


func _open_unix_file(path: String) -> int:
	var result := _create_process_if_found(
		["xdg-open", "/usr/bin/xdg-open", "/bin/xdg-open"],
		[path]
	)
	if result >= 0:
		return result
	result = _create_process_if_found(["gio", "/usr/bin/gio"], ["open", path])
	if result >= 0:
		return result
	result = _create_process_if_found(["kde-open5", "kde-open", "gnome-open"], [path])
	return result


func _create_process_if_found(candidates: Array[String], args: Array) -> int:
	var executable := ProcessUtils.find_executable(candidates)
	if executable.is_empty():
		return ERR_FILE_NOT_FOUND
	return OS.create_process(executable, PackedStringArray(args))


# ── Mod list ───────────────────────────────────────────────────────────────────

func _refresh_mods() -> void:
	var content_root := _cfg.get_game_profile().content_root
	_mods = ModDiscovery.scan(_cfg.mods_dir, content_root)
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
		item.set_custom_color(0, AppTheme.MOD_PLACEHOLDER)
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
	item.set_custom_color(0, AppTheme.MOD_ENABLED if enabled else AppTheme.MOD_DISABLED)
	item.set_icon(0, _icon("GuiVisibilityVisible" if enabled else "GuiVisibilityHidden"))
	item.set_tooltip_text(0, "%d files · %s\n%s  (right-click to toggle, middle-click to export as .pak)" % [
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
	var content_root := _cfg.get_game_profile().content_root
	var files := ModDiscovery.list_mod_files(mod["path"], content_root)

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
		dir_item.set_custom_color(0, AppTheme.MOD_DIR)
		dir_item.set_selectable(0, true)
		dir_item.set_metadata(0, {
			"type": "folder", "key": dir_key,
			"mod": mod, "rel_dir": dir
		})
		dir_item.collapsed = _collapsed_dirs.get(dir_key, false)

		for rel_path: String in (groups[dir] as Array):
			var full_path: String = (mod["path"] as String).path_join(rel_path)
			var is_uasset := rel_path.ends_with(".uasset")

			var file_item := _mod_tree.create_item(dir_item)
			file_item.set_text(0, rel_path.get_file())
			#file_item.set_custom_font_size(0, 13)
			file_item.set_tooltip_text(0, rel_path)
			file_item.set_custom_color(0,
				AppTheme.MOD_FILE_UASSET if is_uasset else AppTheme.MOD_FILE_OTHER)
			file_item.set_selectable(0, true)
			file_item.set_metadata(0, {
				"type": "file", "mod": mod,
				"rel_path": rel_path, "full_path": full_path
			})

			if _is_text_file_path(rel_path):
				var open_icon := _icon("Edit")
				if not open_icon:
					open_icon = _icon("File")
				if open_icon:
					file_item.add_button(0, open_icon, _BTN_OPEN_EXTERNAL, false,
						"Open with system default app")

			var del_icon := _icon("Remove")
			if del_icon:
				file_item.add_button(0, del_icon, _BTN_DEL, false, "Remove from mod")


# ── Tree signal handlers ───────────────────────────────────────────────────────

## Double-click a file → open .uasset in the editor, everything else with the OS default app.
## Using activated (double-click) so single-click safely builds multi-selection.
func _on_tree_item_activated() -> void:
	var item := _mod_tree.get_selected()
	if not item:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.get("type") != "file":
		return
	var path: String = meta["full_path"]
	if path.to_lower().ends_with(".uasset"):
		open_asset_requested.emit(path)
	else:
		_open_external_file(path)


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


func _on_mod_tree_gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_MIDDLE:
		return
	var item := _mod_tree.get_item_at_position(mouse_event.position)
	if item == null:
		return
	var mod: Variant = _get_mod_for_item(item)
	if mod == null:
		return
	_mod_tree.accept_event()
	_open_export_mod_dialog(mod as Dictionary)


## Button clicks: Add (mod items), open/delete (file items).
func _on_tree_button_clicked(item: TreeItem, _column: int, id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var meta: Dictionary = item.get_metadata(0)
	match meta.get("type"):
		"mod":
			if id == _BTN_ADD:
				_on_add_files_pressed(meta["mod"] as Dictionary)
		"file":
			if id == _BTN_OPEN_EXTERNAL:
				_open_external_file(meta["full_path"] as String)
			elif id == _BTN_DEL:
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


## Collect all selected mod-level items as mod dicts (deduplicated).
func _get_selected_mods() -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	var item := _mod_tree.get_next_selected(null)
	while item:
		var meta: Dictionary = item.get_metadata(0)
		if meta.get("type") == "mod":
			var mod_name: String = (meta["mod"] as Dictionary)["name"]
			if mod_name not in seen:
				seen[mod_name] = true
				result.append(meta["mod"])
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


## Return a source-relative folder from the first selected folder/file item.
func _get_selected_source_dir() -> String:
	var item := _mod_tree.get_next_selected(null)
	while item:
		var meta: Dictionary = item.get_metadata(0)
		match meta.get("type"):
			"folder":
				return meta.get("rel_dir", "") as String
			"file":
				return (meta.get("rel_path", "") as String).get_base_dir()
		item = _mod_tree.get_next_selected(item)
	return ""


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
	var successful_moves: Array = []
	var remaining_clipboard: Array = []
	for entry: Dictionary in _file_clipboard:
		# Preserve the full relative path so folder structure is maintained.
		var rel: String = entry["rel_path"]
		var dst: String = dst_root.path_join(rel)
		var src: String = entry["full_path"]
		if not FileUtils.is_path_within(dst, dst_root):
			failed += 1
			remaining_clipboard.append(entry)
			continue
		if FileUtils.same_path(src, dst):
			copied += 1
		elif FileUtils.copy_file(src, dst) == OK:
			copied += 1
			successful_moves.append(entry)
		else:
			failed += 1
			remaining_clipboard.append(entry)

	# For cut, only delete sources whose copy succeeded.
	if _clipboard_is_cut:
		for entry: Dictionary in successful_moves:
			var delete_error := _delete_file_raw(
				entry["mod"] as Dictionary, entry["full_path"] as String)
			if delete_error != OK:
				failed += 1
				remaining_clipboard.append(entry)
		_file_clipboard = remaining_clipboard
		_clipboard_is_cut = not _file_clipboard.is_empty()

	var msg := "Pasted %d file(s) into %s" % [copied, target_mod["name"]]
	if failed > 0:
		msg += " (%d failed)" % failed
	_set_status(msg, failed > 0 and copied == 0)
	_refresh_mods()


func delete_selection() -> void:
	var mods  := _get_selected_mods()
	var files := _get_selected_files()

	if mods.is_empty() and files.is_empty():
		return

	# If entire mods are selected, confirm before deleting.
	if not mods.is_empty():
		var names: PackedStringArray = []
		for m: Dictionary in mods:
			names.append(m["name"] as String)
		var dialog := ConfirmationDialog.new()
		dialog.title = "Delete Mod(s)"
		dialog.dialog_text = "Permanently delete %d mod(s)?\n\n%s" % [
			mods.size(), "\n".join(names)]
		dialog.ok_button_text = "Delete"
		AppTheme.apply_theme(dialog)
		add_child(dialog)
		dialog.confirmed.connect(func() -> void:
			for m: Dictionary in mods:
				FileUtils.remove_dir_recursive(m["path"] as String)
			# Also delete any selected files that aren't part of a deleted mod.
			var deleted_mod_paths: Dictionary = {}
			for m: Dictionary in mods:
				deleted_mod_paths[m["path"] as String] = true
			for entry: Dictionary in files:
				var mod_path: String = (entry["mod"] as Dictionary)["path"]
				if mod_path not in deleted_mod_paths:
					_delete_file_raw(entry["mod"] as Dictionary, entry["full_path"] as String)
			_set_status("Deleted %d mod(s)" % mods.size()
				+ (", %d file(s)" % files.size() if not files.is_empty() else ""))
			_refresh_mods()
			dialog.queue_free()
		)
		dialog.canceled.connect(dialog.queue_free)
		dialog.popup_centered()
		return

	# Files only — no confirmation needed.
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
	_on_add_files_pressed(mod as Dictionary, _get_selected_source_dir())


# ── File management ────────────────────────────────────────────────────────────

## Delete a file and prune empty parent dirs up to the mod root.
## Returns OK or an error code. Does NOT emit status or refresh — callers do that.
func _delete_file_raw(mod: Dictionary, full_path: String) -> Error:
	var mod_path: String = mod["path"]
	if not FileUtils.is_path_within(full_path, mod_path) or FileUtils.same_path(full_path, mod_path):
		return ERR_INVALID_PARAMETER
	var err := DirAccess.remove_absolute(full_path)
	if err != OK:
		return err
	var dir := full_path.get_base_dir()
	while FileUtils.is_path_within(dir, mod_path) and not FileUtils.same_path(dir, mod_path):
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

func _on_add_files_pressed(mod: Dictionary, preferred_rel_dir: String = "") -> void:
	var sources: Array = _cfg.sources.filter(
		func(s: Dictionary) -> bool: return not (s["path"] as String).is_empty()
	)
	if sources.is_empty():
		_set_status("No sources configured — add sources in Settings", true)
		return
	if sources.size() == 1:
		_open_add_files_dialog(mod, sources[0], preferred_rel_dir)
	else:
		_show_source_picker(mod, sources, preferred_rel_dir)


## Modal source picker. Keeps the source choice visible and gives invalid paths room to explain themselves.
func _show_source_picker(mod: Dictionary, sources: Array, preferred_rel_dir: String = "") -> void:
	var first_valid := -1
	for i in sources.size():
		var src: Dictionary = sources[i]
		if DirAccess.dir_exists_absolute(_source_path(src)):
			first_valid = i
			break

	if first_valid < 0:
		_set_status("No configured source folders were found", true)
		return

	var popup := PopupPanel.new()
	popup.name = "AddFilesFromSourcePopup"
	popup.min_size = Vector2i(560, 360)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", AppTheme.SPACING_ROW * 2)
	margin.add_theme_constant_override("margin_right", AppTheme.SPACING_ROW * 2)
	margin.add_theme_constant_override("margin_top", AppTheme.SPACING_ROW + AppTheme.SPACING_TIGHT)
	margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_ROW + AppTheme.SPACING_TIGHT)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	var title_label := Label.new()
	title_label.text = "Add Files from Source"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_header(title_label)
	header.add_child(title_label)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.tooltip_text = "Close"
	close_btn.custom_minimum_size = Vector2(28, 28)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	AppTheme.style_muted_btn(close_btn)
	close_btn.pressed.connect(func() -> void: popup.queue_free())
	header.add_child(close_btn)
	content.add_child(header)

	var target_label := Label.new()
	target_label.text = "Target mod: %s" % (mod["name"] as String)
	content.add_child(target_label)

	var destination_label := Label.new()
	var destination := preferred_rel_dir.rstrip("/")
	destination_label.text = "Destination: %s" % (destination if not destination.is_empty() else "(mod root)")
	AppTheme.style_muted(destination_label)
	content.add_child(destination_label)

	var source_list := ItemList.new()
	source_list.custom_minimum_size = Vector2(0, 150)
	source_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source_list.allow_reselect = true
	for i in sources.size():
		var src: Dictionary = sources[i]
		var path := _source_path(src)
		var exists := DirAccess.dir_exists_absolute(path)
		var label := _source_label(src)
		if not exists:
			label += "  (missing)"
		source_list.add_item(label)
		source_list.set_item_metadata(i, i)
		source_list.set_item_tooltip(i, path)
		if not exists:
			source_list.set_item_disabled(i, true)
			source_list.set_item_custom_fg_color(i, AppTheme.STATUS_ERROR)
	content.add_child(source_list)

	var details_label := Label.new()
	AppTheme.style_muted(details_label)
	details_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	content.add_child(details_label)

	var update_details := func(index: int) -> void:
		var source_index := _source_index_from_list(source_list, index)
		if source_index < 0:
			return
		var src: Dictionary = sources[source_index]
		var source_path := _source_path(src)
		var initial_dir := _resolve_source_initial_dir(source_path, preferred_rel_dir)
		details_label.text = "Source: %s\nStarts in: %s" % [source_path, initial_dir]

	var open_source_at_list_index := func(list_index: int) -> void:
		var source_index := _source_index_from_list(source_list, list_index)
		if source_index < 0 or source_index >= sources.size():
			return
		var source: Dictionary = sources[source_index]
		popup.queue_free()
		_open_add_files_dialog(mod, source, preferred_rel_dir)

	var open_selected := func() -> void:
		var selected := source_list.get_selected_items()
		if selected.is_empty():
			return
		open_source_at_list_index.call(selected[0])

	source_list.item_selected.connect(func(index: int) -> void:
		update_details.call(index)
	)
	source_list.item_activated.connect(func(index: int) -> void:
		update_details.call(index)
		open_source_at_list_index.call(index)
	)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var footer_spacer := Control.new()
	footer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(footer_spacer)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	AppTheme.style_muted_btn(cancel_btn)
	cancel_btn.pressed.connect(func() -> void: popup.queue_free())
	footer.add_child(cancel_btn)

	var browse_btn := Button.new()
	browse_btn.text = "Browse"
	AppTheme.style_add_btn(browse_btn)
	browse_btn.pressed.connect(open_selected)
	footer.add_child(browse_btn)
	content.add_child(footer)

	popup.popup_hide.connect(func() -> void:
		if is_instance_valid(popup) and not popup.is_queued_for_deletion():
			popup.queue_free()
	)
	popup.add_child(margin)
	AppTheme.apply_theme(popup)
	add_child(popup)
	source_list.select(first_valid)
	update_details.call(first_valid)
	popup.popup_centered(Vector2i(600, 380))
	source_list.grab_focus.call_deferred()


func _source_label(source: Dictionary) -> String:
	var source_name := str(source.get("name", "")).strip_edges()
	if not source_name.is_empty():
		return source_name
	var path := _source_path(source)
	return path.get_file() if not path.get_file().is_empty() else path


func _source_index_from_list(source_list: ItemList, list_index: int) -> int:
	if list_index < 0 or list_index >= source_list.item_count:
		return -1
	if source_list.is_item_disabled(list_index):
		return -1
	return int(source_list.get_item_metadata(list_index))


func _source_path(source: Dictionary) -> String:
	return str(source.get("path", "")).rstrip("/")


func _resolve_source_initial_dir(source_path: String, preferred_rel_dir: String) -> String:
	var initial_dir := source_path
	if not preferred_rel_dir.is_empty():
		var candidate := source_path.path_join(preferred_rel_dir)
		if FileUtils.is_path_within(candidate, source_path) and DirAccess.dir_exists_absolute(candidate):
			initial_dir = candidate
	return initial_dir


## Open a multi-file browser rooted at source["path"]; copy selections into mod.
func _open_add_files_dialog(mod: Dictionary, source: Dictionary, preferred_rel_dir: String = "") -> void:
	var source_path := _source_path(source)
	if not DirAccess.dir_exists_absolute(source_path):
		_set_status("Source folder not found: %s" % source_path, true)
		return
	var initial_dir := _resolve_source_initial_dir(source_path, preferred_rel_dir)
	var dialog := FileDialog.new()
	dialog.file_mode       = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access          = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.current_dir     = initial_dir
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
		if not FileUtils.is_path_within(src_file, source_root):
			_set_status("File is outside source root — skipped: %s" % src_file.get_file(), true)
			failed += 1
			continue
		var rel := src_file.replace("\\", "/").substr(
			source_root.replace("\\", "/").rstrip("/").length()).lstrip("/")
		var dst := mod_path.path_join(rel)
		if not FileUtils.is_path_within(dst, mod_path):
			failed += 1
			continue
		if FileUtils.copy_file(src_file, dst) == OK:
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
	dialog.add_button("From .pak...", false, "from_pak")
	dialog.min_size = Vector2i(300, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	var lbl := Label.new()
	lbl.text = "Mod folder name:"
	var edit := LineEdit.new()
	edit.placeholder_text = "MyModName"
	vbox.add_child(lbl)
	vbox.add_child(edit)
	dialog.add_child(vbox)
	AppTheme.apply_theme(dialog)
	add_child(dialog)

	dialog.confirmed.connect(func() -> void:
		var mod_name := edit.text.strip_edges()
		var error := _validate_new_mod_name(mod_name)
		if not error.is_empty():
			_set_status(error, true)
			edit.grab_focus()
			return
		var err := _create_empty_mod(mod_name)
		if err != OK:
			_set_status("Failed to create mod folder", true)
			dialog.queue_free()
			return
		_set_status("Created mod: " + mod_name)
		_refresh_mods()
		dialog.queue_free()
	)
	dialog.custom_action.connect(func(action: StringName) -> void:
		if action != &"from_pak":
			return
		var mod_name := edit.text.strip_edges()
		var error := _validate_new_mod_name(mod_name)
		if not error.is_empty():
			_set_status(error, true)
			edit.grab_focus()
			return
		dialog.queue_free()
		_open_new_mod_pak_dialog(mod_name)
	)

	dialog.popup_centered()
	# Focus the text field after the popup opens.
	edit.grab_focus.call_deferred()


func _validate_new_mod_name(mod_name: String) -> String:
	if not FileUtils.is_safe_filename(mod_name):
		return "Mod name must be a single folder name"
	var mod_path := _cfg.mods_dir.path_join(mod_name)
	if DirAccess.dir_exists_absolute(mod_path):
		return "Mod '%s' already exists" % mod_name
	var cr := _cfg.get_game_profile().content_root
	var content_path := mod_path.path_join(cr + "/Content")
	if not FileUtils.is_path_within(content_path, mod_path):
		return "Spellbreak profile has an invalid content root"
	return ""


func _create_empty_mod(mod_name: String) -> Error:
	var mod_path := _cfg.mods_dir.path_join(mod_name)
	var cr := _cfg.get_game_profile().content_root
	return DirAccess.make_dir_recursive_absolute(mod_path.path_join(cr + "/Content"))


func _open_new_mod_pak_dialog(mod_name: String) -> void:
	if _new_mod_from_pak_service.is_generating():
		_set_status("Already creating a mod from pak", true)
		return
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
		_start_new_mod_from_pak(mod_name, path)
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


func _start_new_mod_from_pak(mod_name: String, pak_path: String) -> void:
	var error := _validate_new_mod_name(mod_name)
	if not error.is_empty():
		_set_status(error, true)
		return
	_pending_new_mod_from_pak = mod_name
	var mod_path := _cfg.mods_dir.path_join(mod_name)
	_pending_new_mod_from_pak_path = mod_path
	_set_status("Creating %s from %s..." % [mod_name, pak_path.get_file()])
	_new_mod_from_pak_service.generate(pak_path, mod_path)


func _on_new_mod_from_pak_started() -> void:
	pass


func _on_new_mod_from_pak_finished(success: bool, message: String,
		_source_name: String, source_path: String) -> void:
	var mod_name := _pending_new_mod_from_pak
	var mod_path := _pending_new_mod_from_pak_path
	_pending_new_mod_from_pak = ""
	_pending_new_mod_from_pak_path = ""
	if success:
		_set_status("Created mod from pak: %s" % mod_name)
		_refresh_mods()
		return
	var cleanup_path := source_path if not source_path.is_empty() else mod_path
	if not cleanup_path.is_empty() and FileUtils.is_path_within(cleanup_path, _cfg.mods_dir):
		FileUtils.remove_dir_recursive(cleanup_path)
	_set_status(message, true)


# ── Actions ────────────────────────────────────────────────────────────────────

func _on_pack_pressed() -> void:
	var enabled_names := _state.get_enabled_names()
	var enabled_mods := _mods.filter(func(m): return m["name"] in enabled_names)
	_pack_mods(enabled_mods, "No mods enabled - right-click a mod to enable")


func _pack_mods(mods: Array, empty_message: String) -> void:
	if not _cfg.is_configured():
		_set_status("Configure paths in Settings first", true)
		return
	if mods.is_empty():
		_set_status(empty_message, true)
		return
	if _packer.is_packing():
		_set_status("Already packing", true)
		return
	_log_lines.clear()
	_log_scroll.visible = true
	_append_log("Packing %d mod(s)..." % mods.size())
	_packer.pack(mods)


func _open_export_mod_dialog(mod: Dictionary) -> void:
	if not _cfg.is_configured():
		_set_status("Configure paths in Settings first", true)
		return
	if _packer.is_packing():
		_set_status("Already packing", true)
		return

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.pak ; Unreal Pak"])
	dialog.use_native_dialog = true
	dialog.current_file = "%s.pak" % _safe_export_basename(mod["name"] as String)
	var paks_dir := _cfg.get_paks_dir()
	if DirAccess.dir_exists_absolute(paks_dir):
		dialog.current_dir = paks_dir
	elif DirAccess.dir_exists_absolute(_cfg.mods_dir):
		dialog.current_dir = _cfg.mods_dir
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_export_mod_to_path(mod, path)
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


func _export_mod_to_path(mod: Dictionary, pak_path: String) -> void:
	var mod_name := mod["name"] as String
	_log_lines.clear()
	_log_scroll.visible = true
	_append_log("Exporting %s..." % mod_name)
	_set_status("Exporting %s..." % mod_name)
	_packer.export_to_path([mod], pak_path)


func _safe_export_basename(mod_name: String) -> String:
	if FileUtils.is_safe_filename(mod_name):
		return mod_name
	var result := ""
	for i in range(mod_name.length()):
		var character := mod_name.substr(i, 1)
		result += character if FileUtils.is_safe_filename(character) else "_"
	result = result.strip_edges().trim_suffix(".")
	return result if not result.is_empty() else "mod"


func _on_watch_pressed() -> void:
	if _watch_toggle_locked:
		return
	if not _cfg.is_configured():
		_set_status("Configure paths in Settings first", true)
		return
	_watch_toggle_locked = true
	_watch_btn.disabled = true
	if _watcher.is_watching():
		_set_status("Stopping watcher...")
		_watcher.stop()
	else:
		_set_status("Starting watcher...")
		_watcher.start()
	_release_watch_toggle.call_deferred()


func _release_watch_toggle() -> void:
	if not is_inside_tree():
		_watch_toggle_locked = false
		return
	await get_tree().create_timer(_WATCH_TOGGLE_COOLDOWN_SEC).timeout
	_watch_toggle_locked = false
	if is_instance_valid(_watch_btn):
		_watch_btn.disabled = false


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

	var parts := ProcessUtils.parse_command_line(cmd)
	if parts.is_empty():
		_set_status("Launch command is empty", true)
		return

	var exe := parts[0]
	var args: PackedStringArray = []
	for i in range(1, parts.size()):
		args.append(parts[i])

	var error := _launch_process(exe, args)
	_set_status("Launch failed" if error < 0 else "Launched: %s" % cmd, error < 0)


func _launch_process(exe: String, args: PackedStringArray) -> int:
	if OS.get_name() == "Windows" and FileAccess.file_exists(exe) and exe.get_base_dir() != "":
		return _launch_windows_file(exe, args)
	return OS.create_process(exe, args)


func _launch_windows_file(exe: String, args: PackedStringArray) -> int:
	if args.is_empty():
		return OK if OS.shell_open(exe) == OK else ERR_CANT_OPEN

	var powershell := ProcessUtils.find_executable(["powershell.exe", "pwsh.exe"])
	if powershell.is_empty():
		return OS.create_process(exe, args)

	var script := (
			"$file=$args[0];$workdir=$args[1];"
			+ "$procArgs=@();"
			+ "if($args.Count -gt 2){$procArgs=$args[2..($args.Count-1)]};"
			+ "Start-Process -FilePath $file -WorkingDirectory $workdir -ArgumentList $procArgs"
	)
	var ps_args := PackedStringArray([
		"-NoProfile",
		"-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-Command", script,
		exe,
		exe.get_base_dir(),
	])
	for arg in args:
		ps_args.append(arg)
	return OS.create_process(powershell, ps_args)


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
		_watch_btn.add_theme_color_override("font_color", AppTheme.STATUS_ACTIVE)
		_set_status("Watching for changes...")
	else:
		_watch_btn.text = "Watch"
		_watch_btn.icon = _icon("GuiVisibilityHidden")
		_watch_btn.add_theme_color_override("font_color", AppTheme.BTN_MUTED)
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
