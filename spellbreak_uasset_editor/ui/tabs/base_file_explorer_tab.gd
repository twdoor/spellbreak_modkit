class_name BaseFileExplorerTab extends VBoxContainer

## Browses the reference sources configured in Mod Manager settings. Folder
## expansion is lazy, while recursive search indexing runs on a worker thread.

signal open_asset_requested(path: String)
signal add_to_mod_requested(path: String, source_root: String)
signal clone_unique_requested(path: String, source_root: String)
signal open_settings_requested
signal status_changed(text: String, is_error: bool)

const LAZY_PLACEHOLDER := "__base_explorer_lazy__"
const MAX_SEARCH_RESULTS := 2500
const CONTEXT_ADD_TO_MOD := 1
const CONTEXT_CLONE_UNIQUE := 2

var _cfg: ModConfigManager
var _background_jobs: BackgroundJobRunner
var _source_menu: MenuButton
var _checked_source_paths: Dictionary = {}
var _search_edit: LineEdit
var _refresh_btn: Button
var _tree: Tree
var _status_label: Label
var _search_timer: Timer
var _context_menu: PopupMenu
var _context_file: Dictionary = {}
var _lazy_directories: Dictionary = {}
var _index_cache: Dictionary = {}
var _scan_job_id := -1
var _scan_generation := 0
var _scan_cache_key := ""


func setup(cfg: ModConfigManager, background_jobs: BackgroundJobRunner) -> BaseFileExplorerTab:
	_cfg = cfg
	_background_jobs = background_jobs
	if not _cfg.config_changed.is_connected(_on_config_changed):
		_cfg.config_changed.connect(_on_config_changed)
	return self


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)
	_build_ui()
	refresh_sources()


func _exit_tree() -> void:
	_cancel_scan()


func _build_ui() -> void:
	var toolbar_margin := MarginContainer.new()
	toolbar_margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_TOOLBAR_H)
	toolbar_margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_TOOLBAR_H)
	toolbar_margin.add_theme_constant_override("margin_top", AppTheme.MARGIN_TOOLBAR_TOP)
	toolbar_margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_TOOLBAR_BOTTOM)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	_source_menu = MenuButton.new()
	_source_menu.custom_minimum_size.x = 210
	_source_menu.tooltip_text = "Show or hide base file sources"
	var source_popup := _source_menu.get_popup()
	source_popup.hide_on_checkable_item_selection = false
	source_popup.id_pressed.connect(_on_source_toggled)
	AppTheme.apply_theme(source_popup)
	toolbar.add_child(_source_menu)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search file names or paths…"
	_search_edit.clear_button_enabled = true
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.tooltip_text = "Use spaces to match multiple parts of a path"
	_search_edit.text_changed.connect(_on_search_text_changed)
	toolbar.add_child(_search_edit)

	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.tooltip_text = "Reload folders and rebuild the search index"
	_refresh_btn.pressed.connect(refresh_sources)
	toolbar.add_child(_refresh_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Sources…"
	settings_btn.tooltip_text = "Add or edit base file sources"
	AppTheme.style_muted_btn(settings_btn)
	settings_btn.pressed.connect(func() -> void: open_settings_requested.emit())
	toolbar.add_child(settings_btn)

	toolbar_margin.add_child(toolbar)
	add_child(toolbar_margin)
	add_child(HSeparator.new())

	_tree = Tree.new()
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.columns = 2
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "Name")
	_tree.set_column_title(1, "Location")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, true)
	_tree.set_column_custom_minimum_width(0, 300)
	_tree.set_column_custom_minimum_width(1, 420)
	_tree.allow_rmb_select = true
	_tree.item_collapsed.connect(_on_item_collapsed)
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_mouse_selected.connect(_on_item_mouse_selected)
	add_child(_tree)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("Add to Mod…", CONTEXT_ADD_TO_MOD)
	_context_menu.add_item("Clone Unique to Mod…", CONTEXT_CLONE_UNIQUE)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	AppTheme.apply_theme(_context_menu)
	add_child(_context_menu)

	add_child(HSeparator.new())
	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_STATUS_H)
	status_margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_STATUS_H)
	status_margin.add_theme_constant_override("margin_top", AppTheme.MARGIN_STATUS_V)
	status_margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_STATUS_V)
	_status_label = AppTheme.make_status_label("", AppTheme.StatusKind.IDLE,
		AppTheme.FONT_STATUS_BAR)
	_status_label.clip_text = true
	status_margin.add_child(_status_label)
	add_child(status_margin)

	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.2
	_search_timer.timeout.connect(_apply_search)
	add_child(_search_timer)


func refresh_sources() -> void:
	if not is_instance_valid(_source_menu):
		return
	_cancel_scan()
	_index_cache.clear()

	var sources := _valid_sources()
	var popup := _source_menu.get_popup()
	popup.clear()

	var checked_state: Dictionary = {}
	for source in sources:
		var path := str(source["path"])
		checked_state[path] = _checked_source_paths.get(path, true)
		var index := popup.item_count
		popup.add_check_item(str(source["name"]), index)
		popup.set_item_metadata(index, path)
		popup.set_item_checked(index, checked_state[path])
	_checked_source_paths = checked_state

	if sources.is_empty():
		_source_menu.disabled = true
		_source_menu.text = "No sources"
		_build_browse_tree()
		return

	_source_menu.disabled = false
	_update_source_menu_text()
	_update_view()


func _on_config_changed() -> void:
	refresh_sources()


func _on_source_toggled(id: int) -> void:
	var popup := _source_menu.get_popup()
	var index := popup.get_item_index(id)
	if index < 0:
		return
	popup.set_item_checked(index, not popup.is_item_checked(index))
	var path := str(popup.get_item_metadata(index))
	_checked_source_paths[path] = popup.is_item_checked(index)
	_update_source_menu_text()
	_cancel_scan()
	_update_view()


func _update_source_menu_text() -> void:
	var popup := _source_menu.get_popup()
	var checked_count := 0
	for index in popup.item_count:
		if popup.is_item_checked(index):
			checked_count += 1
	if checked_count == popup.item_count:
		_source_menu.text = "All sources"
	else:
		_source_menu.text = "Sources — %d/%d" % [checked_count, popup.item_count]


func _on_search_text_changed(_text: String) -> void:
	_search_timer.start()


func _update_view() -> void:
	if _search_edit.text.strip_edges().is_empty():
		_build_browse_tree()
	else:
		_apply_search()


func _build_browse_tree() -> void:
	_tree.clear()
	_lazy_directories.clear()
	var root := _tree.create_item()
	var sources := _selected_sources()
	if sources.is_empty():
		if _valid_sources().is_empty():
			_add_message_item(root, "No base sources configured", "Add one with Sources…")
			_set_status("Add a base source in Settings to browse its files.",
				AppTheme.StatusKind.WARNING)
		else:
			_add_message_item(root, "No sources selected",
				"Tick the sources you want to browse")
			_set_status("Tick at least one source in the source menu.",
				AppTheme.StatusKind.WARNING)
		return

	var show_source_roots := sources.size() > 1
	var available_count := 0
	for source in sources:
		var path := str(source["path"])
		if not DirAccess.dir_exists_absolute(path):
			var missing := _tree.create_item(root)
			missing.set_text(0, str(source["name"]))
			missing.set_text(1, "Folder not found: %s" % path)
			missing.set_custom_color(0, AppTheme.STATUS_ERROR)
			missing.set_custom_color(1, AppTheme.STATUS_ERROR)
			missing.set_selectable(0, false)
			continue
		available_count += 1
		if show_source_roots:
			var source_item := _tree.create_item(root)
			source_item.set_text(0, str(source["name"]))
			source_item.set_text(1, path)
			source_item.set_tooltip_text(0, path)
			source_item.set_custom_color(0, AppTheme.TEXT_SECTION)
			_set_directory_metadata(source_item, source, path, "")
			source_item.collapsed = true
			_add_lazy_placeholder(source_item)
		else:
			_populate_directory(root, source, path, "")

	_set_status("Browsing %d source%s. Expand folders or search all paths." % [
		available_count, "" if available_count == 1 else "s"],
		AppTheme.StatusKind.IDLE)


func _set_directory_metadata(item: TreeItem, source: Dictionary, path: String,
		relative_path: String) -> void:
	item.set_metadata(0, {
		"type": "directory",
		"source": source.duplicate(true),
		"path": path,
		"relative_path": relative_path,
	})
	_lazy_directories[item] = true


func _add_lazy_placeholder(parent: TreeItem) -> void:
	var placeholder := _tree.create_item(parent)
	placeholder.set_metadata(0, LAZY_PLACEHOLDER)
	placeholder.set_selectable(0, false)


func _on_item_collapsed(item: TreeItem) -> void:
	if item.collapsed or not _lazy_directories.has(item):
		return
	_populate_directory_item.call_deferred(item)


func _populate_directory_item(item: TreeItem) -> void:
	if not is_instance_valid(_tree) or not _lazy_directories.has(item):
		return
	var metadata: Variant = item.get_metadata(0)
	if not metadata is Dictionary:
		_lazy_directories.erase(item)
		return
	_lazy_directories.erase(item)
	var child := item.get_first_child()
	if child != null and child.get_metadata(0) == LAZY_PLACEHOLDER:
		child.free()
	_populate_directory(item, metadata["source"], str(metadata["path"]),
		str(metadata["relative_path"]))


func _populate_directory(parent: TreeItem, source: Dictionary, path: String,
		relative_path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		var error_item := _tree.create_item(parent)
		error_item.set_text(0, "Could not read folder")
		error_item.set_text(1, path)
		error_item.set_custom_color(0, AppTheme.STATUS_ERROR)
		error_item.set_selectable(0, false)
		return

	var directories := DirAccess.get_directories_at(path)
	directories.sort()
	for directory_name in directories:
		var child_path := path.path_join(directory_name)
		var child_relative := relative_path.path_join(directory_name)
		var directory_item := _tree.create_item(parent)
		directory_item.set_text(0, directory_name)
		directory_item.set_text(1, child_relative)
		directory_item.set_tooltip_text(0, child_path)
		directory_item.collapsed = true
		_set_directory_metadata(directory_item, source, child_path, child_relative)
		_add_lazy_placeholder(directory_item)

	var files := DirAccess.get_files_at(path)
	files.sort()
	for file_name in files:
		var file_path := path.path_join(file_name)
		var file_relative := relative_path.path_join(file_name)
		_add_file_item(parent, source, file_path, file_relative)


func _add_file_item(parent: TreeItem, source: Dictionary, path: String,
		relative_path: String) -> void:
	var item := _tree.create_item(parent)
	item.set_text(0, path.get_file())
	item.set_text(1, _result_location(str(source["name"]), relative_path))
	item.set_tooltip_text(0, path)
	item.set_tooltip_text(1, path)
	item.set_custom_color(0, AppTheme.MOD_FILE_UASSET
		if _is_editor_asset(path) else AppTheme.MOD_FILE_OTHER)
	item.set_metadata(0, {
		"type": "file",
		"path": path,
		"relative_path": relative_path,
		"source_name": str(source["name"]),
		"source_path": str(source.get("path", "")),
	})


func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(0)
	if not metadata is Dictionary:
		return
	if str(metadata.get("type", "")) == "directory":
		item.collapsed = not item.collapsed
		return
	if str(metadata.get("type", "")) != "file":
		return
	var path := str(metadata.get("path", ""))
	if not FileAccess.file_exists(path):
		_set_status("File no longer exists: %s" % path, AppTheme.StatusKind.ERROR)
		status_changed.emit("File no longer exists: %s" % path, true)
		return
	if not _is_editor_asset(path):
		var result := ExternalFileLauncher.open(
				path, ExternalFileLauncher.is_text_file(path))
		if result != OK:
			_set_status("Could not open file: %s" % path.get_file(),
					AppTheme.StatusKind.ERROR)
			status_changed.emit("Could not open file: %s" % path.get_file(), true)
			return
		_set_status("Opening %s" % path.get_file(), AppTheme.StatusKind.IDLE)
		return
	open_asset_requested.emit(path)


func _on_item_mouse_selected(_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(0)
	if not metadata is Dictionary or str(metadata.get("type", "")) != "file":
		return
	_context_file = (metadata as Dictionary).duplicate(true)
	var file_name := str(metadata.get("path", "")).get_file()
	var file_is_asset := _is_editor_asset(str(metadata.get("path", "")))
	_context_menu.set_item_text(
		_context_menu.get_item_index(CONTEXT_ADD_TO_MOD),
		"Add %s to Mod…" % file_name)
	var clone_index := _context_menu.get_item_index(CONTEXT_CLONE_UNIQUE)
	_context_menu.set_item_text(clone_index,
		"Clone %s Unique to Mod…" % file_name)
	_context_menu.set_item_disabled(clone_index, not file_is_asset)
	var popup_position := Vector2i(_tree.get_global_mouse_position())
	_context_menu.popup(Rect2i(popup_position, Vector2i.ZERO))


func _on_context_menu_id_pressed(id: int) -> void:
	if _context_file.is_empty():
		return
	var path := str(_context_file.get("path", ""))
	var source_root := str(_context_file.get("source_path", ""))
	if path.is_empty() or source_root.is_empty():
		_set_status("The selected file is not associated with a configured source.",
			AppTheme.StatusKind.ERROR)
		return
	if id == CONTEXT_ADD_TO_MOD:
		add_to_mod_requested.emit(path, source_root)
	elif id == CONTEXT_CLONE_UNIQUE:
		if not _is_editor_asset(path):
			return
		clone_unique_requested.emit(path, source_root)


func _apply_search() -> void:
	var query := _search_edit.text.strip_edges()
	if query.is_empty():
		_cancel_scan()
		_build_browse_tree()
		return
	var sources := _selected_sources()
	if sources.is_empty():
		_build_browse_tree()
		return
	var cache_key := _sources_cache_key(sources)
	if _index_cache.has(cache_key):
		_show_search_results(_index_cache[cache_key], query)
		return
	# The index does not depend on the query. Keep the current scan alive while
	# the user continues typing and apply the latest text when it completes.
	if _scan_job_id >= 0 and _scan_cache_key == cache_key:
		return
	_start_indexing(sources, cache_key)


func _start_indexing(sources: Array[Dictionary], cache_key: String) -> void:
	_cancel_scan()
	_scan_generation += 1
	var generation := _scan_generation
	_scan_cache_key = cache_key
	_refresh_btn.disabled = true
	_tree.clear()
	var root := _tree.create_item()
	_add_message_item(root, "Indexing source files…", "Search will appear when indexing finishes")
	_set_status("Indexing %d source%s in the background…" % [
		sources.size(), "" if sources.size() == 1 else "s"], AppTheme.StatusKind.WORKING)
	var snapshot: Array[Dictionary] = []
	for source in sources:
		snapshot.append(source.duplicate(true))
	_scan_job_id = _background_jobs.run(
		_scan_sources.bind(snapshot),
		_on_index_ready.bind(generation, cache_key))
	if _scan_job_id < 0:
		_scan_cache_key = ""
		_refresh_btn.disabled = false
		_set_status("Could not start the source indexer.", AppTheme.StatusKind.ERROR)
		status_changed.emit("Could not start the source indexer.", true)


func _cancel_scan() -> void:
	if _scan_job_id >= 0 and _background_jobs != null:
		_background_jobs.cancel(_scan_job_id)
	_scan_job_id = -1
	_scan_cache_key = ""
	_scan_generation += 1
	if is_instance_valid(_refresh_btn):
		_refresh_btn.disabled = false


func _on_index_ready(result: Dictionary, generation: int, cache_key: String) -> void:
	if generation != _scan_generation:
		return
	_scan_job_id = -1
	_scan_cache_key = ""
	_refresh_btn.disabled = false
	var entries: Array = result.get("entries", [])
	_index_cache[cache_key] = entries
	var errors: Array = result.get("errors", [])
	if not errors.is_empty():
		status_changed.emit(str(errors[0]), true)
	_show_search_results(entries, _search_edit.text.strip_edges(), errors.size())


func _show_search_results(entries: Array, query: String, error_count: int = 0) -> void:
	if query.is_empty():
		_build_browse_tree()
		return
	_tree.clear()
	_lazy_directories.clear()
	var root := _tree.create_item()
	var terms := _query_terms(query)
	var match_count := 0
	for entry_value in entries:
		if not entry_value is Dictionary:
			continue
		var entry := entry_value as Dictionary
		if not _path_matches_terms(str(entry.get("relative_path", "")), terms):
			continue
		match_count += 1
		if match_count <= MAX_SEARCH_RESULTS:
			_add_file_item(root, {
				"name": str(entry.get("source_name", "Source")),
				"path": str(entry.get("source_path", "")),
			}, str(entry.get("path", "")), str(entry.get("relative_path", "")))

	if match_count == 0:
		_add_message_item(root, "No files match “%s”" % query, "Try fewer or shorter terms")
	var limited := match_count > MAX_SEARCH_RESULTS
	var message := "%d matching file%s" % [match_count, "" if match_count == 1 else "s"]
	if limited:
		message += " — showing the first %d" % MAX_SEARCH_RESULTS
	if error_count > 0:
		message += " — %d source%s could not be read" % [
			error_count, "" if error_count == 1 else "s"]
	_set_status(message, AppTheme.StatusKind.WARNING
		if limited or error_count > 0 else AppTheme.StatusKind.IDLE)


func _add_message_item(parent: TreeItem, title: String, detail: String) -> void:
	var item := _tree.create_item(parent)
	item.set_text(0, title)
	item.set_text(1, detail)
	item.set_custom_color(0, AppTheme.TEXT_MUTED)
	item.set_custom_color(1, AppTheme.TEXT_MUTED)
	item.set_selectable(0, false)


func _set_status(text: String, kind: int) -> void:
	AppTheme.set_status_label(_status_label, text, kind)


func _selected_sources() -> Array[Dictionary]:
	if not is_instance_valid(_source_menu):
		return []
	var popup := _source_menu.get_popup()
	if popup.item_count == 0:
		return []
	var sources := _valid_sources()
	var selected: Array[Dictionary] = []
	for index in popup.item_count:
		if not popup.is_item_checked(index):
			continue
		var path := str(popup.get_item_metadata(index))
		for source in sources:
			if str(source["path"]) == path:
				selected.append(source)
				break
	return selected


func _valid_sources() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _cfg == null:
		return result
	var used_names: Dictionary = {}
	for index in _cfg.sources.size():
		var raw: Variant = _cfg.sources[index]
		if not raw is Dictionary:
			continue
		var path := str(raw.get("path", "")).strip_edges().rstrip("/")
		if path.is_empty():
			continue
		var base_name := str(raw.get("name", "")).strip_edges()
		if base_name.is_empty():
			base_name = path.get_file()
		if base_name.is_empty():
			base_name = "Source %d" % (index + 1)
		var display_name := base_name
		var suffix := 2
		while used_names.has(display_name):
			display_name = "%s %d" % [base_name, suffix]
			suffix += 1
		used_names[display_name] = true
		result.append({"name": display_name, "path": path})
	return result


static func _scan_sources(sources: Array[Dictionary]) -> Dictionary:
	var entries: Array[Dictionary] = []
	var errors: Array[String] = []
	for source in sources:
		var root := str(source.get("path", "")).rstrip("/")
		if not DirAccess.dir_exists_absolute(root):
			errors.append("Source folder not found: %s" % root)
			continue
		var pending: Array[String] = [root]
		while not pending.is_empty():
			var directory_path: String = pending.pop_back()
			var directory := DirAccess.open(directory_path)
			if directory == null:
				errors.append("Could not read source folder: %s" % directory_path)
				continue
			directory.list_dir_begin()
			var entry_name := directory.get_next()
			while not entry_name.is_empty():
				var full_path: String = directory_path.path_join(entry_name)
				if directory.current_is_dir():
					if not directory.is_link(entry_name):
						pending.append(full_path)
				else:
					entries.append({
						"path": full_path,
						"relative_path": _relative_path(full_path, root),
						"source_name": str(source.get("name", "Source")),
						"source_path": root,
					})
				entry_name = directory.get_next()
			directory.list_dir_end()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s/%s" % [a.get("source_name", ""), a.get("relative_path", "")]
		var b_key := "%s/%s" % [b.get("source_name", ""), b.get("relative_path", "")]
		return a_key.naturalnocasecmp_to(b_key) < 0)
	return {"entries": entries, "errors": errors}


static func _relative_path(path: String, root: String) -> String:
	var normalized_root := root.rstrip("/")
	if path == normalized_root:
		return path.get_file()
	if path.begins_with(normalized_root + "/"):
		return path.substr(normalized_root.length() + 1)
	return path


static func _query_terms(query: String) -> PackedStringArray:
	var terms := PackedStringArray()
	for raw_term in query.to_lower().split(" ", false):
		var term := raw_term.strip_edges()
		if not term.is_empty():
			terms.append(term)
	return terms


static func _path_matches_terms(path: String, terms: PackedStringArray) -> bool:
	var normalized := path.replace("\\", "/").to_lower()
	for term in terms:
		if term not in normalized:
			return false
	return true


static func _sources_cache_key(sources: Array[Dictionary]) -> String:
	var paths := PackedStringArray()
	for source in sources:
		paths.append(str(source.get("path", "")))
	return "\n".join(paths)


static func _result_location(source_name: String, relative_path: String) -> String:
	var parent := relative_path.get_base_dir()
	if parent == ".":
		parent = ""
	return source_name if parent.is_empty() else "%s  •  %s" % [source_name, parent]


static func _is_editor_asset(path: String) -> bool:
	return path.get_extension().to_lower() == "uasset"
