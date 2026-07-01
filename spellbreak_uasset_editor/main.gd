extends CanvasLayer

@onready var open_file_popup: FileDialog = %OpenFilePopup
@onready var tab_cont: TabContainer = %TabCont

@export_group("Inputs")
@export var mapping: GUIDEMappingContext
@export var open_action: GUIDEAction
@export var close_action: GUIDEAction
@export var save_action: GUIDEAction
@export var previous_tab_action: GUIDEAction
@export var next_tab_action: GUIDEAction
@export var copy: GUIDEAction
@export var paste: GUIDEAction
@export var cut: GUIDEAction
@export var undo: GUIDEAction
@export var delete: GUIDEAction
@export var shift: GUIDEAction
@export var cancel: GUIDEAction
@export var create: GUIDEAction
@export var compare_action: GUIDEAction

var _toast_label: Label
var _toast_panel: PanelContainer
var _toast_timer: SceneTreeTimer
var _toast_tween: Tween

var _close_dialog: ConfirmationDialog
var _tab_pending_close: UassetFileTab
var _tab_close_icon: Texture2D
var _tab_title_scroll_timer: Timer
var _hovered_tab_idx := -1
var _hover_title_offset := 0
var _hover_title_hold_ticks := 0
var _compare_file_popup: FileDialog
var _compare_base_tab: UassetFileTab
var _update_dialog: ConfirmationDialog
var _latest_release_url := ""

var _status_label: Label
var _cfg: ModConfigManager
var _texture_service: TextureService
var _sound_service: SoundService
var _mesh_service: MeshService
var _background_jobs: BackgroundJobRunner
var _update_checker: UpdateChecker
var _keymap_config: GUIDERemappingConfig

const _TOAST_HIDDEN_Y := -8.0   # resting offset_bottom when hidden (just off-screen bottom)
const _TOAST_SHOWN_Y  := -72.0  # offset_bottom when fully visible
const _TAB_CLOSE_GAP := "   "
const _TAB_MAX_WIDTH := 190
const _TAB_TITLE_VISIBLE_CHARS := 24
const _TAB_TITLE_SCROLL_INTERVAL := 0.18
const _TAB_TITLE_SCROLL_HOLD_TICKS := 4
const _TAB_TITLE_SCROLL_GAP := "   "
const _STARTUP_OPEN_EXTENSIONS := ["uasset", "json"]

func _ready() -> void:
	_background_jobs = BackgroundJobRunner.new()
	_configure_shortcut_actions()
	_keymap_config = KeymapSettingsTab.load_saved_config(mapping)
	GUIDE.enable_mapping_context(mapping)
	GUIDE.set_remapping_config(_keymap_config)

	AppTheme.configure_file_dialog(open_file_popup)
	open_file_popup.file_selected.connect(_on_file_selected)
	open_file_popup.files_selected.connect(_on_files_selected)

	_connect_shortcuts()
	_configure_tab_close_controls()

	_build_toast()
	_build_close_dialog()
	_build_compare_dialog()
	_build_status_bar()
	_setup_mod_tab()
	_build_update_dialog()
	_setup_update_checker()
	_open_startup_files.call_deferred()


func _configure_tab_close_controls() -> void:
	var tab_bar := tab_cont.get_tab_bar()
	_tab_close_icon = tab_bar.get_theme_icon("close", "TabBar") if tab_bar else _make_tab_close_icon()
	tab_cont.tab_button_pressed.connect(_on_tab_button_pressed)
	if tab_bar:
		tab_bar.set("max_tab_width", _TAB_MAX_WIDTH)
		tab_bar.set("scrolling_enabled", true)
		tab_bar.tab_rmb_clicked.connect(_on_tab_rmb_clicked)
		if tab_bar.has_signal("tab_hovered"):
			tab_bar.connect("tab_hovered", _on_tab_hovered)
		tab_bar.mouse_exited.connect(_on_tab_bar_mouse_exited)

	_tab_title_scroll_timer = Timer.new()
	_tab_title_scroll_timer.wait_time = _TAB_TITLE_SCROLL_INTERVAL
	_tab_title_scroll_timer.timeout.connect(_advance_hovered_tab_title)
	add_child(_tab_title_scroll_timer)


func _make_tab_close_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var color := Color(0.78, 0.82, 0.86, 0.95)
	for i in range(5, 11):
		img.set_pixel(i, i, color)
		img.set_pixel(i + 1, i, color)
		img.set_pixel(i, 15 - i, color)
		img.set_pixel(i + 1, 15 - i, color)
	return ImageTexture.create_from_image(img)


func _connect_shortcuts() -> void:
	# Command shortcuts are edge-triggered. GUIDEAction.triggered fires every
	# frame while active; just_triggered fires once per press and keeps keyboard
	# behavior consistent while preserving GUIDE-based remapping.
	open_action.just_triggered.connect(_open_file_dialog)
	close_action.just_triggered.connect(_close_current_tab)
	save_action.just_triggered.connect(_save_current_tab)
	previous_tab_action.just_triggered.connect(_select_previous_tab)
	next_tab_action.just_triggered.connect(_select_next_tab)
	copy.just_triggered.connect(_copy_selection)
	paste.just_triggered.connect(_paste_clipboard)
	cut.just_triggered.connect(_cut_selection)
	undo.just_triggered.connect(_undo)
	delete.just_triggered.connect(_delete_selection)
	cancel.just_triggered.connect(_cancel_selection)
	create.just_triggered.connect(_create_file)
	compare_action.just_triggered.connect(_compare_current_tab)


func _configure_shortcut_actions() -> void:
	mapping.display_name = "Editor"
	_configure_action(open_action, &"open_file", "Open File", "File")
	_configure_action(close_action, &"close_tab", "Close Tab", "File")
	_configure_action(save_action, &"save_file", "Save File", "File")
	_configure_action(create, &"add_files_from_sources", "Add Files from Sources", "Mod Manager")
	_configure_action(previous_tab_action, &"previous_tab", "Previous Tab", "Navigation")
	_configure_action(next_tab_action, &"next_tab", "Next Tab", "Navigation")
	_configure_action(copy, &"copy_selection", "Copy", "Edit")
	_configure_action(paste, &"paste_selection", "Paste", "Edit")
	_configure_action(cut, &"cut_selection", "Cut", "Edit")
	_configure_action(undo, &"undo", "Undo", "Edit")
	_configure_action(delete, &"delete_selection", "Delete Selection", "Edit")
	_configure_action(cancel, &"cancel", "Cancel / Clear Selection", "Edit")
	_configure_action(compare_action, &"compare_file", "Compare File", "File")
	_configure_action(shift, &"selection_modifier_shift", "Shift", "Navigation", false)


func _configure_action(action: GUIDEAction, action_name: StringName,
		display_name: String, category: String, remappable: bool = true) -> void:
	if action == null:
		return
	action.name = action_name
	action.display_name = display_name
	action.display_category = category
	action.is_remappable = remappable


func _exit_tree() -> void:
	if _background_jobs:
		_background_jobs.wait_to_finish()
	if _texture_service:
		_texture_service.wait_to_finish()
	if _sound_service:
		_sound_service.wait_to_finish()
	if _mesh_service:
		_mesh_service.wait_to_finish()


func _build_status_bar() -> void:
	var vbox := tab_cont.get_parent()

	vbox.add_child(HSeparator.new())

	var bar := MarginContainer.new()
	bar.add_theme_constant_override("margin_left",   AppTheme.MARGIN_STATUS_H)
	bar.add_theme_constant_override("margin_right",  AppTheme.MARGIN_STATUS_H)
	bar.add_theme_constant_override("margin_top",    AppTheme.MARGIN_STATUS_V)
	bar.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_STATUS_V)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.add_theme_font_size_override("font_size", AppTheme.FONT_STATUS_BAR)
	AppTheme.style_muted(_status_label)
	_status_label.clip_text = true

	bar.add_child(_status_label)
	vbox.add_child(bar)


func _setup_mod_tab() -> void:
	# Tab 0 — Mod Manager (always visible, never closeable)
	var panel := ModManagerPanel.new()
	tab_cont.add_child(panel)
	tab_cont.move_child(panel, 0)
	tab_cont.set_tab_title(0, "Mod Manager")
	panel.open_asset_requested.connect(_on_file_selected)
	panel.status_changed.connect(_on_mod_status_changed)
	_cfg = panel.get_config()
	_texture_service = TextureService.new().setup(_cfg)
	_sound_service = SoundService.new().setup(_cfg)
	_mesh_service = MeshService.new().setup(_cfg)

	# When any UassetFileTab is removed, refresh titles so lone survivors revert to short names.
	tab_cont.child_exiting_tree.connect(func(child: Node) -> void:
		if child is UassetFileTab or child is AssetDiffTab:
			_clear_hovered_tab_title()
			_refresh_tab_titles.call_deferred()
	)

	# Tab 1 — Settings (hidden by default; opened by the Settings button, closed by Save/Cancel)
	var settings := ModSettingsTab.new().setup(panel.get_config())
	tab_cont.add_child(settings)
	tab_cont.move_child(settings, 1)
	tab_cont.set_tab_title(1, "Settings")
	tab_cont.set_tab_hidden(1, true)

	panel.open_settings_requested.connect(func() -> void:
		settings.refresh()
		tab_cont.set_tab_hidden(1, false)
		tab_cont.current_tab = 1
	)

	settings.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(1, true)
		tab_cont.current_tab = 0
	)
	settings.status_changed.connect(_on_mod_status_changed)

	var keymap := KeymapSettingsTab.new().setup(mapping, _keymap_config)
	tab_cont.add_child(keymap)
	tab_cont.move_child(keymap, 2)
	tab_cont.set_tab_title(2, "Key Mappings")
	tab_cont.set_tab_hidden(2, true)

	settings.open_keymap_requested.connect(func() -> void:
		keymap.refresh(_keymap_config)
		tab_cont.set_tab_hidden(2, false)
		tab_cont.current_tab = 2
	)

	keymap.keymap_changed.connect(func(config: GUIDERemappingConfig) -> void:
		_keymap_config = config
		GUIDE.set_remapping_config(_keymap_config)
	)
	keymap.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(2, true)
		tab_cont.current_tab = 1 if not tab_cont.is_tab_hidden(1) else 0
	)
	keymap.status_changed.connect(_on_mod_status_changed)

	var diagnostics := DiagnosticsTab.new().setup(panel.get_config())
	tab_cont.add_child(diagnostics)
	tab_cont.move_child(diagnostics, 3)
	tab_cont.set_tab_title(3, "Diagnostics")
	tab_cont.set_tab_hidden(3, true)

	panel.open_diagnostics_requested.connect(func() -> void:
		diagnostics.refresh()
		tab_cont.set_tab_hidden(3, false)
		tab_cont.current_tab = 3
	)

	diagnostics.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(3, true)
		tab_cont.current_tab = 1 if not tab_cont.is_tab_hidden(1) else 0
	)
	diagnostics.status_changed.connect(_on_mod_status_changed)


func _on_mod_status_changed(text: String, is_error: bool) -> void:
	_status_label.text = text
	AppTheme.style_status(_status_label, is_error)


func _build_toast() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.z_index = 100
	_toast_panel.add_theme_stylebox_override("panel", AppTheme.make_toast_style())

	_toast_label = Label.new()
	_toast_label.add_theme_font_size_override("font_size", AppTheme.FONT_TOAST)
	_toast_label.add_theme_color_override("font_color", AppTheme.TEXT_TOAST)
	_toast_panel.add_child(_toast_label)

	# Anchor bottom-centre, start hidden below the visible area
	_toast_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_toast_panel.anchor_left = 0.5
	_toast_panel.anchor_right = 0.5
	_toast_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_panel.offset_bottom = _TOAST_HIDDEN_Y
	_toast_panel.offset_top = _TOAST_HIDDEN_Y
	_toast_panel.modulate.a = 0.0

	add_child(_toast_panel)


func _show_toast(message: String) -> void:
	_toast_label.text = message

	# Kill previous tween and timer so a rapid second call restarts cleanly
	if _toast_tween:
		_toast_tween.kill()
	if _toast_timer != null:
		_toast_timer.timeout.disconnect(_hide_toast)

	# Slide up + fade in
	_toast_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_toast_tween.tween_property(_toast_panel, "offset_bottom", _TOAST_SHOWN_Y, 0.25)
	_toast_tween.parallel().tween_property(_toast_panel, "offset_top", _TOAST_SHOWN_Y, 0.25)
	_toast_tween.parallel().tween_property(_toast_panel, "modulate:a", 1.0, 0.2)
	await _toast_tween.finished
	await get_tree().create_timer(1.5).timeout
	_hide_toast()


func _hide_toast() -> void:
	if _toast_tween:
		_toast_tween.kill()

	# Slide down + fade out
	_toast_tween = create_tween().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_toast_tween.tween_property(_toast_panel, "offset_bottom", _TOAST_HIDDEN_Y, 0.3)
	_toast_tween.parallel().tween_property(_toast_panel, "offset_top", _TOAST_HIDDEN_Y, 0.3)
	_toast_tween.parallel().tween_property(_toast_panel, "modulate:a", 0.0, 0.25)


func _build_close_dialog() -> void:
	_close_dialog = ConfirmationDialog.new()
	_close_dialog.title = "Unsaved Changes"
	_close_dialog.ok_button_text = "Discard & Close"
	_close_dialog.add_button("Save & Close", false, "save_close")
	_close_dialog.confirmed.connect(_on_discard_and_close)
	_close_dialog.custom_action.connect(_on_save_and_close)
	AppTheme.apply_theme(_close_dialog)
	add_child(_close_dialog)


func _build_compare_dialog() -> void:
	_compare_file_popup = FileDialog.new()
	_compare_file_popup.title = "Compare With"
	_compare_file_popup.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_compare_file_popup.access = FileDialog.ACCESS_FILESYSTEM
	_compare_file_popup.filters = PackedStringArray([
		"*.uasset ; Unreal Asset (binary)",
		"*.json ; UAssetAPI JSON",
	])
	_compare_file_popup.file_selected.connect(_on_compare_file_selected)
	AppTheme.configure_file_dialog(_compare_file_popup)
	add_child(_compare_file_popup)


func _build_update_dialog() -> void:
	_update_dialog = ConfirmationDialog.new()
	_update_dialog.title = "Update Available"
	_update_dialog.ok_button_text = "Open Release"
	_update_dialog.cancel_button_text = "Later"
	_update_dialog.confirmed.connect(_open_latest_release)
	AppTheme.apply_theme(_update_dialog)
	add_child(_update_dialog)


func _setup_update_checker() -> void:
	_update_checker = UpdateChecker.new()
	_update_checker.update_available.connect(_on_update_available)
	add_child(_update_checker)
	call_deferred("_check_for_updates")


func _check_for_updates() -> void:
	if _update_checker:
		_update_checker.check_now()


func _on_update_available(version: String, release_url: String, release_name: String) -> void:
	_latest_release_url = release_url
	var title := release_name if not release_name.is_empty() else "Spellbreak Modkit %s" % version
	_update_dialog.dialog_text = "%s is available.\n\nOpen the GitHub release page?" % title
	_update_dialog.popup_centered()


func _open_latest_release() -> void:
	if _latest_release_url.is_empty():
		_latest_release_url = UpdateChecker.GITHUB_LATEST_RELEASE_PAGE % UpdateChecker.DEFAULT_REPOSITORY
	var error := OS.shell_open(_latest_release_url)
	if error != OK:
		_show_toast("Could not open release page (error %d)" % error)


func _on_discard_and_close() -> void:
	if is_instance_valid(_tab_pending_close):
		_tab_pending_close.queue_free()
	_tab_pending_close = null


func _on_save_and_close(action: StringName) -> void:
	if action != &"save_close":
		return
	if is_instance_valid(_tab_pending_close):
		var error := _tab_pending_close.save_asset()
		if error != OK:
			_show_toast("Save failed (error %d)" % error)
			_close_dialog.hide()
			return
		_show_toast("Saved  " + _tab_pending_close.tab_asset.file_path.get_file())
		_tab_pending_close.queue_free()
	_tab_pending_close = null
	_close_dialog.hide()


func _select_previous_tab() -> void:
	tab_cont.select_previous_available()


func _select_next_tab() -> void:
	tab_cont.select_next_available()


func _open_file_dialog() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		focus.release_focus()
	if open_file_popup.visible:
		return
	open_file_popup.popup_file_dialog()


func _on_file_selected(path: String) -> void:
	# Don't open duplicates — switch to existing tab instead
	for i in tab_cont.get_child_count():
		var tab = tab_cont.get_child(i)
		if tab is UassetFileTab and tab.tab_asset and tab.tab_asset.file_path == path:
			tab_cont.current_tab = tab_cont.get_tab_idx_from_control(tab)
			return

	var asset := UAssetFile.load_file(path)
	if asset == null:
		push_error("Failed to load: " + path)
		_show_toast("Failed to load  " + path.get_file())
		return

	# Attach the Spellbreak profile so property editors can access enums/tags.
	if _cfg:
		asset.game_profile = _cfg.get_game_profile()

	var new_tab := UassetFileTab.setup(asset, _texture_service, _sound_service,
		_mesh_service, _background_jobs)
	new_tab.tab_title_changed.connect(_on_asset_tab_title_changed)
	tab_cont.add_child(new_tab)
	# Refresh all tab titles: duplicates get "ParentFolder/Name", unique ones stay short.
	_refresh_tab_titles()
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(new_tab)


func _on_files_selected(paths: PackedStringArray) -> void:
	for path in paths:
		_on_file_selected(path)


func _open_startup_files() -> void:
	for path in _get_startup_file_paths():
		_on_file_selected(path)


func _get_startup_file_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for raw_arg in OS.get_cmdline_args():
		var path := str(raw_arg).strip_edges()
		if path.is_empty() or path.begins_with("--"):
			continue
		if path.begins_with("file://"):
			path = path.trim_prefix("file://").uri_decode()
		if _STARTUP_OPEN_EXTENSIONS.has(path.get_extension().to_lower()):
			paths.append(path)
	return paths


## Scans all open UassetFileTabs and updates their displayed title:
##   - unique filename  → short form  "FileName"
##   - duplicate filename → long form  "ParentFolder/FileName"
## Also handles the dirty (*) suffix through _update_tab_title.
func _refresh_tab_titles() -> void:
	# Count how many open tabs share each base name.
	var counts: Dictionary = {}
	for i in tab_cont.get_child_count():
		var tab := tab_cont.get_child(i)
		if tab is UassetFileTab:
			var n: String = (tab as UassetFileTab)._base_name
			counts[n] = counts.get(n, 0) + 1

	# Apply short or long form accordingly.
	for i in tab_cont.get_child_count():
		var tab := tab_cont.get_child(i)
		if tab is UassetFileTab:
			var ft := tab as UassetFileTab
			ft._display_base = ft.get_disambig_name() if counts[ft._base_name] > 1 else ft._base_name
			_set_managed_tab_title(i, ft.get_tab_title(), true)
		elif tab is AssetDiffTab:
			var diff_tab := tab as AssetDiffTab
			_set_managed_tab_title(i, diff_tab.get_tab_title(), true)
		else:
			tab_cont.set_tab_button_icon(i, null)


func _on_asset_tab_title_changed(tab: UassetFileTab) -> void:
	if not is_instance_valid(tab) or not tab.is_inside_tree():
		return
	var tab_idx := tab_cont.get_tab_idx_from_control(tab)
	if tab_idx >= 0:
		_set_managed_tab_title(tab_idx, tab.get_tab_title(), true)


func _set_managed_tab_title(tab_idx: int, full_title: String, closeable: bool) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null:
		return
	tab.set_meta("tab_full_title", full_title)
	tab.set_meta("tab_closeable", closeable)
	tab_cont.set_tab_title(tab_idx, _render_tab_title(tab_idx, full_title)
		+ (_TAB_CLOSE_GAP if closeable else ""))
	tab_cont.set_tab_button_icon(tab_idx, _tab_close_icon if closeable else null)
	tab_cont.set_tab_tooltip(tab_idx, full_title)


func _refresh_managed_tab_title(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		return
	_set_managed_tab_title(tab_idx, str(tab.get_meta("tab_full_title")),
		bool(tab.get_meta("tab_closeable", false)))


func _render_tab_title(tab_idx: int, full_title: String) -> String:
	if tab_idx == _hovered_tab_idx and _is_tab_title_long(full_title):
		return _scroll_tab_title(full_title)
	return _truncate_tab_title(full_title)


func _truncate_tab_title(full_title: String) -> String:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	var visible_chars := maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())
	if base.length() <= visible_chars:
		return base + suffix
	return base.left(maxi(4, visible_chars - 3)) + "..." + suffix


func _scroll_tab_title(full_title: String) -> String:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	var visible_chars := maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())
	if base.length() <= visible_chars:
		return base + suffix
	var source := base + _TAB_TITLE_SCROLL_GAP + base
	var cycle_length := base.length() + _TAB_TITLE_SCROLL_GAP.length()
	var start := _hover_title_offset % cycle_length
	return source.substr(start, visible_chars) + suffix


func _split_dirty_suffix(title: String) -> Dictionary:
	if title.ends_with(" *"):
		return {
			"base": title.left(title.length() - 2),
			"suffix": " *",
		}
	return {
		"base": title,
		"suffix": "",
	}


func _is_tab_title_long(full_title: String) -> bool:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	return base.length() > maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())


func _on_tab_hovered(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		_clear_hovered_tab_title()
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		_clear_hovered_tab_title()
		return

	var previous_idx := _hovered_tab_idx
	_hovered_tab_idx = tab_idx
	_hover_title_offset = 0
	_hover_title_hold_ticks = 0
	if previous_idx != tab_idx:
		_refresh_managed_tab_title(previous_idx)
	_refresh_managed_tab_title(tab_idx)

	if _is_tab_title_long(str(tab.get_meta("tab_full_title"))):
		_tab_title_scroll_timer.start()
	else:
		_tab_title_scroll_timer.stop()


func _on_tab_bar_mouse_exited() -> void:
	_clear_hovered_tab_title()


func _clear_hovered_tab_title() -> void:
	var previous_idx := _hovered_tab_idx
	_hovered_tab_idx = -1
	_hover_title_offset = 0
	_hover_title_hold_ticks = 0
	if _tab_title_scroll_timer:
		_tab_title_scroll_timer.stop()
	_refresh_managed_tab_title(previous_idx)


func _advance_hovered_tab_title() -> void:
	if _hovered_tab_idx < 0 or _hovered_tab_idx >= tab_cont.get_tab_count():
		_clear_hovered_tab_title()
		return
	var tab := tab_cont.get_tab_control(_hovered_tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		_clear_hovered_tab_title()
		return
	var full_title := str(tab.get_meta("tab_full_title"))
	if not _is_tab_title_long(full_title):
		_clear_hovered_tab_title()
		return

	if _hover_title_hold_ticks < _TAB_TITLE_SCROLL_HOLD_TICKS:
		_hover_title_hold_ticks += 1
	else:
		_hover_title_offset += 1
	_refresh_managed_tab_title(_hovered_tab_idx)


func _close_current_tab() -> void:
	var tab = tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		_request_close_tab(tab)
	elif tab is AssetDiffTab:
		tab.queue_free()


func _on_tab_button_pressed(tab_idx: int) -> void:
	_close_tab_at_index(tab_idx)


func _on_tab_rmb_clicked(tab_idx: int) -> void:
	_close_tab_at_index(tab_idx)


func _close_tab_at_index(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	tab_cont.current_tab = tab_idx
	if tab is UassetFileTab:
		_request_close_tab(tab)
	elif tab is AssetDiffTab:
		tab.queue_free()


func _request_close_tab(tab: UassetFileTab) -> void:
	if tab._dirty:
		_tab_pending_close = tab
		_close_dialog.dialog_text = '"%s" has unsaved changes.' % tab.tab_asset.file_path.get_file()
		_close_dialog.popup_centered()
		return
	tab.queue_free()


func _save_current_tab() -> void:
	var tab = tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		if not tab.is_dirty():
			_show_toast("No changes to save")
			return
		var error: Error = tab.save_asset()
		if error == OK:
			_show_toast("Saved  " + tab.tab_asset.file_path.get_file())
		else:
			_show_toast("Save failed (error %d)" % error)


func _copy_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.copy_selection()
		_show_toast("Copied  " + tab.get_clipboard_label())
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).copy_selection()


func _cut_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.cut_selection()
		_show_toast("Cut  " + tab.get_clipboard_label())
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).cut_selection()


func _paste_clipboard() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.paste_clipboard()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).paste_clipboard()


func _delete_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.delete_selection()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).delete_selection()


func _create_file() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is ModManagerPanel:
		(tab as ModManagerPanel).create_file()


func _compare_current_tab() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if not tab is UassetFileTab:
		_show_toast("Open an asset before comparing")
		return
	_compare_base_tab = tab
	var path := _compare_base_tab.tab_asset.binary_path
	if path.is_empty():
		path = _compare_base_tab.tab_asset.file_path
	if not path.is_empty():
		_compare_file_popup.current_dir = path.get_base_dir()
	if not _compare_file_popup.visible:
		_compare_file_popup.popup_file_dialog()


func _on_compare_file_selected(path: String) -> void:
	if not is_instance_valid(_compare_base_tab) or _compare_base_tab.tab_asset == null:
		_show_toast("Open an asset before comparing")
		return
	var other_asset := UAssetFile.load_file(path)
	if other_asset == null:
		_show_toast("Failed to load comparison file")
		return
	if _cfg:
		other_asset.game_profile = _cfg.get_game_profile()

	var diff_tab := AssetDiffTab.setup(_compare_base_tab.tab_asset, other_asset)
	tab_cont.add_child(diff_tab)
	_refresh_tab_titles()
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(diff_tab)
	_show_toast("%d difference(s)" % diff_tab.diffs.size())


func _undo() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.undo()


func _cancel_selection() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		focus.release_focus()
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.clear_selection()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).clear_selection()


## Returns true when a text-editing control has keyboard focus.
## In that case, shortcuts like Ctrl+C/V/X/Z should go to the control, not the editor.
func _text_control_focused() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox
