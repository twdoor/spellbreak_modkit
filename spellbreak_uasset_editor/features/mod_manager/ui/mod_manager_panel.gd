class_name ModManagerPanel extends VBoxContainer

## Persistent left-side panel: mod list, enable/disable toggles, pack, watch, launch, settings.
## The stable control hierarchy lives in mod_manager_panel.tscn; TreeItems remain data-driven.
## Wire open_asset_requested to main.gd to open .uasset files in the editor.

signal open_asset_requested(path: String)
signal open_settings_requested
signal open_diagnostics_requested
signal open_explorer_requested
signal status_changed(text: String, is_error: bool)
signal clone_created(path: String)

# ── Services ───────────────────────────────────────────────────────────────────
var _cfg:     ModConfigManager
var _state:   ModStateManager
var _packer:  PackingService
var _watcher: ModFileWatcher
var _new_mod_from_pak_service: BaseSourceService

# ── State ──────────────────────────────────────────────────────────────────────
var _mods:           Array[ModInfo] = []
var _collapsed_mods: Dictionary = {}  # mod_name -> bool  (default true = collapsed)
var _collapsed_dirs: Dictionary = {}  # "mod_name::rel_dir" -> bool (true = collapsed)
var _log_lines:      Array      = []
var _last_pack_operation: Callable
const _MAX_LOG := 80
const _WATCH_TOGGLE_COOLDOWN_SEC := 0.25
const _PACKAGE_FILE_EXTENSIONS := ["uasset", "umap", "uexp", "ubulk", "uptnl"]

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
@onready var _mod_tree: Tree = %ModTree
@onready var _watch_btn: Button = %WatchButton
@onready var _pack_btn: Button = %PackButton
@onready var _launch_btn: Button = %LaunchButton
@onready var _new_mod_btn: Button = %NewModButton
@onready var _diagnostics_btn: Button = %DiagnosticsButton
@onready var _base_files_btn: Button = %BaseFilesButton
@onready var _settings_btn: Button = %SettingsButton
@onready var _operation_feedback_wrapper: MarginContainer = %OperationFeedbackWrapper

var _operation_feedback: OperationFeedback


func _ready() -> void:
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

	_configure_scene_ui()
	_refresh_mods()

	# Auto-start watcher if any mods are enabled
	if _state.has_any_enabled() and _cfg.is_configured():
		_watcher.start()


func _exit_tree() -> void:
	_watcher.stop()
	_watcher.wait_to_finish()
	_packer.wait_to_finish()
	_new_mod_from_pak_service.wait_to_finish()


func _configure_scene_ui() -> void:
	_pack_btn.icon = _icon("AssetLib")
	_pack_btn.add_theme_color_override("font_color", AppTheme.BTN_PACK)
	_watch_btn.icon = _icon("GuiVisibilityVisible")
	AppTheme.style_muted_btn(_watch_btn)
	_launch_btn.icon = _icon("Play")
	_launch_btn.add_theme_color_override("font_color", AppTheme.BTN_LAUNCH)
	_new_mod_btn.icon = _icon("FolderCreate")
	_new_mod_btn.add_theme_color_override("font_color", AppTheme.BTN_NEW_MOD)
	_diagnostics_btn.icon = _icon("StatusWarning")
	AppTheme.style_muted_btn(_diagnostics_btn)
	_base_files_btn.icon = _icon("FileTree")
	AppTheme.style_muted_btn(_base_files_btn)
	_settings_btn.icon = _icon("Tools")
	AppTheme.style_muted_btn(_settings_btn)

	_operation_feedback = OperationFeedback.new().setup(_retry_last_pack_operation, true)
	_operation_feedback.set_auto_dismiss_seconds(8.0)
	_operation_feedback.dismiss_requested.connect(
		func() -> void: _operation_feedback_wrapper.visible = false)
	_operation_feedback_wrapper.add_child(_operation_feedback)


func _on_diagnostics_pressed() -> void:
	open_diagnostics_requested.emit()


func _on_settings_pressed() -> void:
	open_settings_requested.emit()


func _on_base_files_pressed() -> void:
	open_explorer_requested.emit()


func _on_tree_empty_clicked(_position: Vector2, _mouse_button_index: int) -> void:
	clear_selection()


## Returns a Godot editor icon by name, or null when EditorIcons aren't in the theme.
func _icon(icon_name: String) -> Texture2D:
	if has_theme_icon(icon_name, &"EditorIcons"):
		return get_theme_icon(icon_name, &"EditorIcons")
	return null


func _is_text_file_path(path: String) -> bool:
	return ExternalFileLauncher.is_text_file(path)


func _open_external_file(path: String) -> void:
	var full_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(full_path):
		_set_status("File not found: %s" % full_path.get_file(), true)
		return
	var result := ExternalFileLauncher.open(full_path, _is_text_file_path(full_path))
	if result != OK:
		_set_status("Could not open file: %s" % full_path.get_file(), true)
		return
	_set_status("Opening %s" % full_path.get_file())


# ── Mod list ───────────────────────────────────────────────────────────────────

func _refresh_mods() -> void:
	var content_root := _cfg.get_game_profile().content_root
	_mods = ModDiscovery.scan(_cfg.mods_dir, content_root)
	var names := _mods.map(func(m: ModInfo): return m.name)
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

	for mod: ModInfo in _mods:
		_build_mod_item(root, mod)


## Walk the live tree and save collapsed state for mod and folder items before a rebuild.
func _save_collapse_state() -> void:
	if not is_instance_valid(_mod_tree) or not _mod_tree.get_root():
		return
	var mod_item := _mod_tree.get_root().get_first_child()
	while mod_item:
		var mod_meta: Dictionary = mod_item.get_metadata(0)
		if mod_meta.get("type") == "mod":
			_collapsed_mods[(mod_meta["mod"] as ModInfo).name] = mod_item.collapsed
			_save_folder_collapse_state(mod_item)
		mod_item = mod_item.get_next()


func _save_folder_collapse_state(item: TreeItem) -> void:
	var child := item.get_first_child()
	while child:
		var meta: Dictionary = child.get_metadata(0)
		if meta.get("type") == "folder":
			_collapsed_dirs[meta["key"] as String] = child.collapsed
			_save_folder_collapse_state(child)
		child = child.get_next()


func _build_mod_item(root: TreeItem, mod: ModInfo) -> void:
	var mod_name := mod.name
	var enabled:  bool   = _state.is_enabled(mod_name)

	var item := _mod_tree.create_item(root)
	item.set_text(0, mod_name)
	#item.set_custom_font_size(0, 14)
	item.set_custom_color(0, AppTheme.MOD_ENABLED if enabled else AppTheme.MOD_DISABLED)
	item.set_icon(0, _icon("GuiVisibilityVisible" if enabled else "GuiVisibilityHidden"))
	item.set_tooltip_text(0, "%d files · %s\n%s  (right-click to toggle, middle-click to export as .pak)" % [
		mod.file_count,
		ModDiscovery.fmt_size(mod.size_bytes),
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


func _build_mod_files(mod_item: TreeItem, mod: ModInfo) -> void:
	var mod_name := mod.name
	var content_root := _cfg.get_game_profile().content_root
	var files := ModDiscovery.list_mod_file_entries(mod.path, content_root)

	# Build a nested folder segment tree that mirrors the game's real folder
	# structure, then create folder items (subfolders first, then files) like
	# the Base Files explorer.
	var root_node := {"folders": {}, "files": []}
	var rel_to_node := {"": root_node}
	for file_entry: ModFileEntry in files:
		var node := _ensure_folder_node(root_node, rel_to_node,
				file_entry.relative_path.get_base_dir())
		(node["files"] as Array).append(file_entry)

	_populate_mod_folder(mod_item, root_node, mod, "", mod_name)


func _ensure_folder_node(root_node: Dictionary, rel_to_node: Dictionary,
		rel_dir: String) -> Dictionary:
	if rel_to_node.has(rel_dir):
		return rel_to_node[rel_dir]
	var node := {"folders": {}, "files": []}
	rel_to_node[rel_dir] = node
	var parent_dir := rel_dir.get_base_dir()
	var segment := rel_dir.get_file()
	if parent_dir == ".":
		parent_dir = ""
	var parent := _ensure_folder_node(root_node, rel_to_node, parent_dir)
	(parent["folders"] as Dictionary)[segment] = node
	return node


func _populate_mod_folder(parent: TreeItem, node: Dictionary, mod: ModInfo,
		rel_dir: String, mod_name: String) -> void:
	var folders := node["folders"] as Dictionary
	var folder_names := folders.keys()
	folder_names.sort()
	for folder_name: String in folder_names:
		var child_rel_dir := folder_name if rel_dir.is_empty() \
				else rel_dir.path_join(folder_name)
		var dir_key: String = mod_name + "::" + child_rel_dir

		var dir_item := _mod_tree.create_item(parent)
		dir_item.set_text(0, folder_name)
		dir_item.set_custom_color(0, AppTheme.MOD_DIR)
		dir_item.set_tooltip_text(0, child_rel_dir + "/")
		dir_item.set_selectable(0, true)
		dir_item.set_metadata(0, {
			"type": "folder", "key": dir_key,
			"mod": mod, "rel_dir": child_rel_dir
		})
		dir_item.collapsed = _collapsed_dirs.get(dir_key, true)
		_populate_mod_folder(dir_item, folders[folder_name], mod,
				child_rel_dir, mod_name)

	for file_entry: ModFileEntry in node["files"]:
		var rel_path := file_entry.relative_path
		var full_path: String = file_entry.full_path
		var is_uasset := rel_path.ends_with(".uasset")

		var file_item := _mod_tree.create_item(parent)
		file_item.set_text(0, rel_path.get_file())
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
			_state.toggle((meta["mod"] as ModInfo).name)
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
	_open_export_mod_dialog(mod as ModInfo)


## Button clicks: Add (mod items), open/delete (file items).
func _on_tree_button_clicked(item: TreeItem, _column: int, id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var meta: Dictionary = item.get_metadata(0)
	match meta.get("type"):
		"mod":
			if id == _BTN_ADD:
				_on_add_files_pressed(meta["mod"] as ModInfo)
		"file":
			if id == _BTN_OPEN_EXTERNAL:
				_open_external_file(meta["full_path"] as String)
			elif id == _BTN_DEL:
				# Defer: _rebuild_mod_list calls clear() — blocked inside a Tree signal.
				var mod_ref := meta["mod"] as ModInfo
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


## Collect all selected mod-level items as typed metadata (deduplicated).
func _get_selected_mods() -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	var item := _mod_tree.get_next_selected(null)
	while item:
		var meta: Dictionary = item.get_metadata(0)
		if meta.get("type") == "mod":
			var mod_name := (meta["mod"] as ModInfo).name
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
	var target_mod := target as ModInfo
	var dst_root := target_mod.path

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
				entry["mod"] as ModInfo, entry["full_path"] as String)
			if delete_error != OK:
				failed += 1
				remaining_clipboard.append(entry)
			else:
				ModManifest.write_workspace_manifest(entry["mod"], _cfg)
		_file_clipboard = remaining_clipboard
		_clipboard_is_cut = not _file_clipboard.is_empty()

	var msg := "Pasted %d file(s) into %s" % [copied, target_mod.name]
	if copied > 0 and ModManifest.write_workspace_manifest(target_mod, _cfg) != OK:
		msg += " (manifest update failed)"
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
		for m: ModInfo in mods:
			names.append(m.name)
		var dialog := ConfirmationDialog.new()
		dialog.title = "Delete Mod(s)"
		dialog.dialog_text = "Permanently delete %d mod(s)?\n\n%s" % [
			mods.size(), "\n".join(names)]
		dialog.ok_button_text = "Delete"
		AppTheme.apply_theme(dialog)
		add_child(dialog)
		dialog.confirmed.connect(func() -> void:
			for m: ModInfo in mods:
				FileUtils.remove_dir_recursive(m.path)
			# Also delete any selected files that aren't part of a deleted mod.
			var deleted_mod_paths: Dictionary = {}
			for m: ModInfo in mods:
				deleted_mod_paths[m.path] = true
			for entry: Dictionary in files:
				var mod_path := (entry["mod"] as ModInfo).path
				if mod_path not in deleted_mod_paths:
					var owner_mod := entry["mod"] as ModInfo
					if _delete_file_raw(owner_mod, entry["full_path"] as String) == OK:
						ModManifest.write_workspace_manifest(owner_mod, _cfg)
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
		var mod := entry["mod"] as ModInfo
		if _delete_file_raw(mod, entry["full_path"] as String) == OK:
			ModManifest.write_workspace_manifest(mod, _cfg)
	_set_status("Deleted %d file(s)" % files.size())
	_refresh_mods()


func clear_selection() -> void:
	_mod_tree.deselect_all()


# ── File management ────────────────────────────────────────────────────────────

## Delete a file and prune empty parent dirs up to the mod root.
## Returns OK or an error code. Does NOT emit status or refresh — callers do that.
func _delete_file_raw(mod: ModInfo, full_path: String) -> Error:
	var mod_path := mod.path
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
func _remove_mod_file(mod: ModInfo, full_path: String) -> void:
	var err := _delete_file_raw(mod, full_path)
	if err != OK:
		_set_status("Failed to remove: %s" % full_path.get_file(), true)
		return
	ModManifest.write_workspace_manifest(mod, _cfg)
	_set_status("Removed %s from %s" % [full_path.get_file(), mod.name])
	_refresh_mods()


# ── Add Files from source ──────────────────────────────────────────────────────

## Open a target picker for one file selected in the Base Files explorer.
## The actual copy is delegated to the same path-preserving workflow used by
## the regular multi-file source dialog.
func add_source_file_to_mod(source_path: String, source_root: String) -> void:
	source_path = source_path.strip_edges()
	source_root = source_root.strip_edges().rstrip("/")
	if not FileAccess.file_exists(source_path):
		_set_status("Source file not found: %s" % source_path, true)
		return
	if not DirAccess.dir_exists_absolute(source_root) \
			or not FileUtils.is_path_within(source_path, source_root):
		_set_status("File is outside its configured source: %s" % source_path, true)
		return
	var relative_path := _source_relative_path(source_path, source_root)
	if relative_path.is_empty():
		_set_status("Could not resolve the file's source-relative path", true)
		return

	# Pick up mod folders created outside the app since the last manager refresh.
	var content_root := _cfg.get_game_profile().content_root
	_mods = ModDiscovery.scan(_cfg.mods_dir, content_root)
	_rebuild_mod_list()
	if _mods.is_empty():
		_set_status("No mods found — create a mod before adding files", true)
		return
	_show_source_file_mod_picker(source_path, source_root, relative_path)


func _show_source_file_mod_picker(source_path: String, source_root: String,
		relative_path: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Add File to Mod"
	dialog.ok_button_text = "Add File"
	dialog.cancel_button_text = "Cancel"
	dialog.min_size = Vector2i(580, 380)
	AppTheme.apply_theme(dialog)
	add_child(dialog)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var file_label := Label.new()
	file_label.text = "Source file"
	AppTheme.style_section(file_label)
	content.add_child(file_label)

	var relative_label := Label.new()
	relative_label.text = relative_path
	relative_label.tooltip_text = source_path
	relative_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	content.add_child(relative_label)

	if _is_package_file(source_path):
		var companion_hint := Label.new()
		companion_hint.text = (
			"Existing package companions (.uasset/.umap, .uexp, .ubulk, .uptnl) "
			+ "with the same name will be included automatically."
		)
		companion_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		AppTheme.style_muted(companion_hint)
		content.add_child(companion_hint)

	var prompt := Label.new()
	prompt.text = "Choose a target mod"
	AppTheme.style_section(prompt)
	content.add_child(prompt)

	var mod_list := ItemList.new()
	mod_list.custom_minimum_size = Vector2(0, 180)
	mod_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mod_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mod_list.allow_reselect = true
	for mod: ModInfo in _mods:
		var index := mod_list.item_count
		mod_list.add_item(mod.name)
		mod_list.set_item_metadata(index, mod)
		mod_list.set_item_tooltip(index, mod.path)
	content.add_child(mod_list)

	var destination_label := AppTheme.make_status_label("", AppTheme.StatusKind.IDLE,
		AppTheme.FONT_SMALL)
	content.add_child(destination_label)
	dialog.add_child(content)

	var update_destination := func(index: int) -> void:
		if index < 0 or index >= mod_list.item_count:
			return
		var mod := mod_list.get_item_metadata(index) as ModInfo
		if mod == null:
			return
		var destination := mod.path.path_join(relative_path)
		var suffix := "  (existing file will be replaced)" \
			if FileAccess.file_exists(destination) else ""
		AppTheme.set_status_label(destination_label,
			"Destination: %s%s" % [destination, suffix],
			AppTheme.StatusKind.WARNING if not suffix.is_empty() else AppTheme.StatusKind.IDLE)

	var add_selected := func() -> void:
		var selected := mod_list.get_selected_items()
		if selected.is_empty():
			return
		var mod := mod_list.get_item_metadata(selected[0]) as ModInfo
		if mod == null:
			return
		_copy_files_to_mod(mod, source_root, PackedStringArray([source_path]))
		dialog.queue_free()

	mod_list.item_selected.connect(update_destination)
	mod_list.item_activated.connect(func(_index: int) -> void: add_selected.call())
	dialog.confirmed.connect(add_selected)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(580, 420))
	mod_list.select(0)
	update_destination.call(0)
	mod_list.grab_focus.call_deferred()

# ── Clone unique asset from source ─────────────────────────────────────────────

## Open a picker for one .uasset in the Base Files explorer, asking which mod
## owns the clone and what it should be named. The destination directory mirrors
## the source's relative path and is created automatically.
func clone_source_file_to_mod(source_path: String, source_root: String) -> void:
	source_path = source_path.strip_edges()
	source_root = source_root.strip_edges().rstrip("/")
	if not FileAccess.file_exists(source_path) \
			or source_path.get_extension().to_lower() != "uasset":
		_set_status("Choose a binary .uasset file to clone", true)
		return
	if not DirAccess.dir_exists_absolute(source_root) \
			or not FileUtils.is_path_within(source_path, source_root):
		_set_status("File is outside its configured source: %s" % source_path, true)
		return
	var relative_path := _source_relative_path(source_path, source_root)
	if relative_path.is_empty():
		_set_status("Could not resolve the file's source-relative path", true)
		return

	var content_root := _cfg.get_game_profile().content_root
	_mods = ModDiscovery.scan(_cfg.mods_dir, content_root)
	_rebuild_mod_list()
	if _mods.is_empty():
		_set_status("No mods found — create a mod before cloning", true)
		return
	_show_clone_unique_mod_picker(source_path, source_root, relative_path)


func _show_clone_unique_mod_picker(source_path: String, source_root: String,
		relative_path: String) -> void:
	var source_name := source_path.get_file().get_basename()
	var dialog := ConfirmationDialog.new()
	dialog.title = "Clone Unique Asset"
	dialog.ok_button_text = "Clone"
	dialog.cancel_button_text = "Cancel"
	dialog.min_size = Vector2i(580, 460)
	AppTheme.apply_theme(dialog)
	add_child(dialog)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var source_label := Label.new()
	source_label.text = "Source file"
	AppTheme.style_section(source_label)
	content.add_child(source_label)

	var relative_label := Label.new()
	relative_label.text = relative_path
	relative_label.tooltip_text = source_path
	relative_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	content.add_child(relative_label)

	var prompt := Label.new()
	prompt.text = "Choose a target mod"
	AppTheme.style_section(prompt)
	content.add_child(prompt)

	var mod_list := ItemList.new()
	mod_list.custom_minimum_size = Vector2(0, 160)
	mod_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mod_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mod_list.allow_reselect = true
	for mod: ModInfo in _mods:
		var index := mod_list.item_count
		mod_list.add_item(mod.name)
		mod_list.set_item_metadata(index, mod)
		mod_list.set_item_tooltip(index, mod.path)
	content.add_child(mod_list)

	var name_prompt := Label.new()
	name_prompt.text = "Clone name"
	AppTheme.style_section(name_prompt)
	content.add_child(name_prompt)

	var name_edit := LineEdit.new()
	name_edit.text = source_name
	name_edit.select(0, source_name.length())
	name_edit.tooltip_text = "Unreal object name: letters, digits, and underscore; cannot start with a digit"
	content.add_child(name_edit)

	var destination_label := AppTheme.make_status_label("", AppTheme.StatusKind.IDLE,
		AppTheme.FONT_SMALL)
	content.add_child(destination_label)
	dialog.add_child(content)

	var update_destination := func() -> void:
		if mod_list.get_selected_items().is_empty():
			return
		var mod := mod_list.get_item_metadata(mod_list.get_selected_items()[0]) as ModInfo
		if mod == null:
			return
		var clone_name := name_edit.text.strip_edges()
		var valid_name := ModManagerPanel._valid_clone_name(clone_name, source_name)
		var destination := ModManagerPanel._clone_destination_path(mod, relative_path, clone_name)
		if destination.is_empty():
			AppTheme.set_status_label(destination_label,
				"Destination: —", AppTheme.StatusKind.ERROR)
		elif not valid_name:
			var reason := "invalid name" if clone_name.is_empty() \
					else "must differ from the source name"
			AppTheme.set_status_label(destination_label,
				"Destination: %s (%s)" % [destination, reason],
				AppTheme.StatusKind.ERROR)
		elif FileAccess.file_exists(destination):
			AppTheme.set_status_label(destination_label,
				"Destination: %s (already exists)" % destination,
				AppTheme.StatusKind.ERROR)
		else:
			AppTheme.set_status_label(destination_label,
				"Destination: %s" % destination, AppTheme.StatusKind.IDLE)

	var clone_selected := func() -> void:
		if mod_list.get_selected_items().is_empty():
			return
		var mod := mod_list.get_item_metadata(mod_list.get_selected_items()[0]) as ModInfo
		if mod == null:
			return
		var clone_name := name_edit.text.strip_edges()
		if not ModManagerPanel._valid_clone_name(clone_name, source_name):
			return
		var destination := ModManagerPanel._clone_destination_path(mod, relative_path, clone_name)
		if destination.is_empty() or FileAccess.file_exists(destination):
			return
		dialog.queue_free()
		_perform_unique_clone(source_path, source_root, mod, destination)

	mod_list.item_selected.connect(func(_index: int) -> void: update_destination.call())
	mod_list.item_activated.connect(func(_index: int) -> void: clone_selected.call())
	name_edit.text_changed.connect(func(_text: String) -> void: update_destination.call())
	dialog.confirmed.connect(clone_selected)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(580, 500))
	mod_list.select(0)
	update_destination.call()
	name_edit.grab_focus.call_deferred()


func _perform_unique_clone(source_path: String, _source_root: String,
		mod: ModInfo, destination_path: String) -> void:
	var described := ModManifest.describe_unique_clone(source_path, destination_path, _cfg)
	if not described.ok:
		_set_status(described.message, true)
		return
	var source_package := str(described.value.get("source", "")).rsplit(".", true, 1)[0]
	var target_package := str(described.value.get("target", "")).rsplit(".", true, 1)[0]
	var source_asset := UAssetFile.load_file(source_path)
	if source_asset == null:
		_set_status("Could not load the source asset: %s" % source_path.get_file(), true)
		return
	var result := source_asset.save_clone_copy(
			destination_path, true, source_package, target_package)
	if not result.ok:
		_set_status(result.message, true)
		return
	var manifest_result := ModManifest.record_unique_clone(described.value, _cfg)
	if not manifest_result.ok:
		_set_status("Cloned %s, but %s" % [destination_path.get_file(),
				manifest_result.message], true)
	else:
		_set_status("Cloned %s as a unique asset in %s (%d names updated)" % [
			destination_path.get_file(), mod.name,
			int(result.metadata.get("renamed_name_entries", 0))])
	_refresh_mods()
	clone_created.emit(destination_path)


static func _clone_destination_path(mod: ModInfo, relative_path: String,
		clone_name: String) -> String:
	if clone_name.is_empty():
		return ""
	return mod.path.path_join(relative_path.get_base_dir()).path_join(clone_name + ".uasset")


static func _valid_clone_name(clone_name: String, source_name: String) -> bool:
	clone_name = clone_name.strip_edges()
	if clone_name.is_empty() or clone_name == source_name:
		return false
	if not _is_ascii_letter_or_underscore(clone_name.substr(0, 1)):
		return false
	for i in clone_name.length():
		var ch := clone_name.substr(i, 1)
		if not (_is_ascii_letter_or_underscore(ch) or _is_ascii_digit(ch)):
			return false
	return true


static func _is_ascii_letter_or_underscore(ch: String) -> bool:
	return ch == "_" \
			or ch >= "A" and ch <= "Z" \
			or ch >= "a" and ch <= "z"


static func _is_ascii_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"


func _on_add_files_pressed(mod: ModInfo, preferred_rel_dir: String = "") -> void:
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


## Separate source-picker window. Keeps the source choice visible while allowing the
## user to move and resize it like the file browser that follows.
func _show_source_picker(mod: ModInfo, sources: Array, preferred_rel_dir: String = "") -> void:
	var first_valid := -1
	for i in sources.size():
		var src: Dictionary = sources[i]
		if DirAccess.dir_exists_absolute(_source_path(src)):
			first_valid = i
			break

	if first_valid < 0:
		_set_status("No configured source folders were found", true)
		return

	var window := Window.new()
	window.name = "AddFilesFromSourceWindow"
	window.title = "Add Files from Source"
	window.visible = false
	window.min_size = Vector2i(560, 360)
	window.size = Vector2i(680, 460)
	window.transient = false
	window.exclusive = false
	window.always_on_top = false
	window.close_requested.connect(window.queue_free)

	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", AppTheme.SPACING_ROW * 2)
	margin.add_theme_constant_override("margin_right", AppTheme.SPACING_ROW * 2)
	margin.add_theme_constant_override("margin_top", AppTheme.SPACING_ROW + AppTheme.SPACING_TIGHT)
	margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_ROW + AppTheme.SPACING_TIGHT)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	margin.add_child(content)

	var target_label := Label.new()
	target_label.text = "Target mod: %s" % mod.name
	AppTheme.style_header(target_label)
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
		window.queue_free()
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
	cancel_btn.pressed.connect(func() -> void: window.queue_free())
	footer.add_child(cancel_btn)

	var browse_btn := Button.new()
	browse_btn.text = "Browse"
	AppTheme.style_add_btn(browse_btn)
	browse_btn.pressed.connect(open_selected)
	footer.add_child(browse_btn)
	content.add_child(footer)

	background.add_child(margin)
	window.add_child(background)
	AppTheme.apply_theme(window)
	add_child(window)
	source_list.select(first_valid)
	update_details.call(first_valid)
	window.popup_centered(Vector2i(680, 460))
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
func _open_add_files_dialog(mod: ModInfo, source: Dictionary, preferred_rel_dir: String = "") -> void:
	var source_path := _source_path(source)
	if not DirAccess.dir_exists_absolute(source_path):
		_set_status("Source folder not found: %s" % source_path, true)
		return
	var initial_dir := _resolve_source_initial_dir(source_path, preferred_rel_dir)
	var dialog := FileDialog.new()
	dialog.title = "Add Files from Source — package companions are included automatically"
	dialog.file_mode       = FileDialog.FILE_MODE_OPEN_FILES
	dialog.access          = FileDialog.ACCESS_FILESYSTEM
	AppTheme.configure_file_dialog(dialog)
	dialog.current_dir     = initial_dir
	dialog.files_selected.connect(func(paths: PackedStringArray) -> void:
		_copy_files_to_mod(mod, source_path, paths)
		dialog.queue_free()
	)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


## Mirror each selected file's path (relative to source_root) into the mod workspace.
func _copy_files_to_mod(mod: ModInfo, source_root: String, file_paths: PackedStringArray) -> void:
	var mod_path := mod.path
	var copied := 0
	var failed := 0
	var copied_sources: Array = []
	var files_to_copy := _expand_package_files(file_paths)
	for src_file in files_to_copy:
		if not FileUtils.is_path_within(src_file, source_root):
			_set_status("File is outside source root — skipped: %s" % src_file.get_file(), true)
			failed += 1
			continue
		var rel := _source_relative_path(src_file, source_root)
		if rel.is_empty():
			failed += 1
			continue
		var dst := mod_path.path_join(rel)
		if not FileUtils.is_path_within(dst, mod_path):
			failed += 1
			continue
		if FileUtils.copy_file(src_file, dst) == OK:
			copied += 1
			copied_sources.append(src_file)
		else:
			_set_status("Could not write: %s" % dst.get_file(), true)
			failed += 1
	if copied > 0:
		var msg := "Copied %d file(s) to %s" % [copied, mod.name]
		if ModManifest.record_copied_files(mod, source_root, copied_sources, _cfg) != OK:
			msg += " (manifest update failed)"
		if failed > 0:
			msg += " (%d failed)" % failed
		_refresh_mods()
		_set_status(msg)


static func _source_relative_path(source_path: String, source_root: String) -> String:
	var normalized_path := source_path.replace("\\", "/").simplify_path()
	var normalized_root := source_root.replace("\\", "/").simplify_path().rstrip("/")
	if normalized_path == normalized_root \
			or not normalized_path.begins_with(normalized_root + "/"):
		return ""
	return normalized_path.substr(normalized_root.length() + 1)


## Expand selected Unreal package files to all existing same-basename package
## members. This lets either the file dialog or explorer select just one member
## without producing an incomplete mod package.
static func _expand_package_files(file_paths: PackedStringArray) -> PackedStringArray:
	var expanded := PackedStringArray()
	var seen: Dictionary = {}
	for selected_path in file_paths:
		_append_unique_path(expanded, seen, selected_path)
		if not _is_package_file(selected_path):
			continue
		var selected_base := selected_path.get_file().get_basename().to_lower()
		var directory_path := selected_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(directory_path):
			continue
		var sibling_names := DirAccess.get_files_at(directory_path)
		sibling_names.sort()
		for sibling_name in sibling_names:
			if sibling_name.get_basename().to_lower() != selected_base:
				continue
			if sibling_name.get_extension().to_lower() not in _PACKAGE_FILE_EXTENSIONS:
				continue
			_append_unique_path(expanded, seen, directory_path.path_join(sibling_name))
	return expanded


static func _append_unique_path(paths: PackedStringArray, seen: Dictionary,
		path: String) -> void:
	var normalized := path.replace("\\", "/").simplify_path()
	var key := normalized.to_lower() if OS.get_name() == "Windows" else normalized
	if seen.has(key):
		return
	seen[key] = true
	paths.append(path)


static func _is_package_file(path: String) -> bool:
	return path.get_extension().to_lower() in _PACKAGE_FILE_EXTENSIONS


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
	var create_error := DirAccess.make_dir_recursive_absolute(mod_path.path_join(cr + "/Content"))
	if create_error != OK:
		return create_error
	return ModManifest.write_workspace_manifest(ModInfo.new(mod_name, mod_path), _cfg)


func _open_new_mod_pak_dialog(mod_name: String) -> void:
	if _new_mod_from_pak_service.is_generating():
		_set_status("Already creating a mod from pak", true)
		return
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


func _on_new_mod_from_pak_finished(result: OperationResult) -> void:
	var mod_name := _pending_new_mod_from_pak
	var mod_path := _pending_new_mod_from_pak_path
	_pending_new_mod_from_pak = ""
	_pending_new_mod_from_pak_path = ""
	if result.ok:
		var manifest_error := ModManifest.write_workspace_manifest(
				ModInfo.new(mod_name, mod_path), _cfg)
		var status := "Created mod from pak: %s" % mod_name
		if manifest_error != OK:
			status += " (manifest update failed)"
		_set_status(status)
		_refresh_mods()
		return
	var source_path := str(result.metadata.get("source_path", result.value))
	var cleanup_path := source_path if not source_path.is_empty() else mod_path
	if not cleanup_path.is_empty() and FileUtils.is_path_within(cleanup_path, _cfg.mods_dir):
		FileUtils.remove_dir_recursive(cleanup_path)
	_set_status(result.message, true)


# ── Actions ────────────────────────────────────────────────────────────────────

func _on_pack_pressed() -> void:
	var enabled_names := _state.get_enabled_names()
	var enabled_mods := _mods.filter(func(m: ModInfo): return m.name in enabled_names)
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
	_last_pack_operation = func() -> void: _pack_mods(mods, empty_message)
	_show_operation_feedback("Packing %d mod(s)..." % mods.size())
	_append_log("Packing %d mod(s)..." % mods.size())
	_update_manifests_for_mods(mods)
	if not _run_build_preflight(mods):
		return
	_packer.pack(mods)


func _open_export_mod_dialog(mod: ModInfo) -> void:
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
	AppTheme.configure_file_dialog(dialog)
	dialog.current_file = "%s.pak" % _safe_export_basename(mod.name)
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


func _export_mod_to_path(mod: ModInfo, pak_path: String) -> void:
	var mod_name := mod.name
	_last_pack_operation = func() -> void: _export_mod_to_path(mod, pak_path)
	_show_operation_feedback("Exporting %s..." % mod_name)
	_append_log("Exporting %s..." % mod_name)
	_append_log("Output: %s" % pak_path)
	_update_manifests_for_mods([mod])
	if not _run_build_preflight([mod]):
		return
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


func _on_pack_finished(result: OperationResult) -> void:
	_pack_btn.disabled = false
	_append_log(("OK: " if result.ok else "ERROR: ") + result.message)
	if is_instance_valid(_operation_feedback):
		_operation_feedback.set_result(result.ok, result.message)
		_operation_feedback.set_retry_enabled(
				not result.ok and _last_pack_operation.is_valid())
	_set_status(result.message, not result.ok)


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
	_last_pack_operation = Callable()
	_show_operation_feedback("[watch #%d] Packing..." % n)
	_append_log("[watch #%d] Packing..." % n)
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


func _update_manifests_for_mods(mods: Array) -> void:
	for mod_value in mods:
		var mod := mod_value as ModInfo
		if mod == null:
			_append_log("Manifest skipped invalid mod metadata")
			continue
		var error := ModManifest.write_workspace_manifest(mod, _cfg)
		if error == OK:
			_append_log("Manifest: %s" % ModManifest.manifest_path(mod))
		else:
			_append_log("Manifest failed for %s (error %d)" % [mod.name, error])


func _run_build_preflight(mods: Array) -> bool:
	var issues: Array[Dictionary] = []
	for mod_value in mods:
		var mod := mod_value as ModInfo
		if mod == null:
			issues.append({
				"severity": ModPreflight.Severity.ERROR,
				"mod": "mod",
				"message": "Invalid mod metadata",
			})
			continue
		issues.append_array(ModPreflight.validate_mod_for_pack(mod, _cfg))
	var errors := ModPreflight.error_count(issues)
	var warnings := ModPreflight.warning_count(issues)
	for issue in issues:
		_append_log("Preflight %s [%s]: %s" % [
			ModPreflight.severity_text(int(issue.get("severity", ModPreflight.Severity.WARNING))),
			str(issue.get("mod", "mod")),
			str(issue.get("message", "")),
		])
	if errors > 0:
		var message := "Preflight failed: %d error(s), %d warning(s)" % [errors, warnings]
		if is_instance_valid(_operation_feedback):
			_operation_feedback.set_result(false, message)
		_set_status(message, true)
		return false
	if warnings > 0:
		_append_log("Preflight: %d warning(s), continuing" % warnings)
	else:
		_append_log("Preflight: OK")
	return true


# ── Log ────────────────────────────────────────────────────────────────────────

func _append_log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > _MAX_LOG:
		_log_lines = _log_lines.slice(_log_lines.size() - _MAX_LOG)
		if is_instance_valid(_operation_feedback):
			_operation_feedback.clear_log()
			for existing_line in _log_lines:
				_operation_feedback.add_line(str(existing_line))
		return
	if is_instance_valid(_operation_feedback):
		_operation_feedback.add_line(line)


func _show_operation_feedback(status_text: String) -> void:
	_log_lines.clear()
	if is_instance_valid(_operation_feedback_wrapper):
		_operation_feedback_wrapper.visible = true
	if is_instance_valid(_operation_feedback):
		_operation_feedback.clear_log()
		_operation_feedback.set_expanded(false)
		_operation_feedback.set_busy(status_text)
		_operation_feedback.set_retry_enabled(false)


func _retry_last_pack_operation() -> void:
	if _last_pack_operation.is_valid():
		_last_pack_operation.call()


func _set_status(text: String, error: bool = false) -> void:
	status_changed.emit(text, error)


## Exposes the shared config so main.gd can pass it to ModSettingsTab.
func get_config() -> ModConfigManager:
	return _cfg


## Refresh after another editor workflow creates files in a mod workspace.
func refresh_mods() -> void:
	_refresh_mods()
