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

var _toast_label: Label
var _toast_panel: PanelContainer
var _toast_timer: SceneTreeTimer
var _toast_tween: Tween

var _close_dialog: ConfirmationDialog
var _tab_pending_close: UassetFileTab

var _status_label: Label
var _cfg: ModConfigManager
var _texture_service: TextureService
var _sound_service: SoundService
var _mesh_service: MeshService
var _background_jobs: BackgroundJobRunner
var _keymap_config: GUIDERemappingConfig

const _TOAST_HIDDEN_Y := -8.0   # resting offset_bottom when hidden (just off-screen bottom)
const _TOAST_SHOWN_Y  := -72.0  # offset_bottom when fully visible

func _ready() -> void:
	_background_jobs = BackgroundJobRunner.new()
	_configure_shortcut_actions()
	_keymap_config = KeymapSettingsTab.load_saved_config()
	GUIDE.enable_mapping_context(mapping)
	GUIDE.set_remapping_config(_keymap_config)

	open_file_popup.file_selected.connect(_on_file_selected)
	open_file_popup.files_selected.connect(_on_files_selected)

	_connect_shortcuts()

	_build_toast()
	_build_close_dialog()
	_build_status_bar()
	_setup_mod_tab()


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
		if child is UassetFileTab:
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
		return

	# Attach the Spellbreak profile so property editors can access enums/tags.
	if _cfg:
		asset.game_profile = _cfg.get_game_profile()

	var new_tab := UassetFileTab.setup(asset, _texture_service, _sound_service,
		_mesh_service, _background_jobs)
	tab_cont.add_child(new_tab)
	# Refresh all tab titles: duplicates get "ParentFolder/Name", unique ones stay short.
	_refresh_tab_titles()
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(new_tab)


func _on_files_selected(paths: PackedStringArray) -> void:
	for path in paths:
		_on_file_selected(path)


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
			ft._update_tab_title()


func _close_current_tab() -> void:
	var tab = tab_cont.get_current_tab_control()
	# ModManagerPanel (tab 0) is pinned — only UassetFileTabs can be closed
	if not tab is UassetFileTab:
		return
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
