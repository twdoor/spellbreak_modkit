extends CanvasLayer

@onready var open_file_popup: FileDialog = %OpenFilePopup
@onready var tab_cont: TabContainer = %TabCont

@export_group("Inputs")
@export var mapping: GUIDEMappingContext
@export var open_action: GUIDEAction
@export var close_action: GUIDEAction
@export var save_action: GUIDEAction
@export var switch_tab_action: GUIDEAction
@export var copy: GUIDEAction
@export var paste: GUIDEAction
@export var cut: GUIDEAction
@export var undo: GUIDEAction
@export var delete: GUIDEAction
@export var shift: GUIDEAction
@export var cancel: GUIDEAction

var _toast_label: Label
var _toast_panel: PanelContainer
var _toast_timer: SceneTreeTimer
var _toast_tween: Tween

var _close_dialog: ConfirmationDialog
var _tab_pending_close: UassetFileTab

var _status_label: Label

const _TOAST_HIDDEN_Y := -8.0   # resting offset_bottom when hidden (just off-screen bottom)
const _TOAST_SHOWN_Y  := -72.0  # offset_bottom when fully visible

func _ready() -> void:
	GUIDE.enable_mapping_context(mapping)

	# SingleInstance autoload handles command line args + second-instance files
	SingleInstance.file_received.connect(_on_file_selected)

	open_file_popup.file_selected.connect(_on_file_selected)
	open_file_popup.files_selected.connect(_on_files_selected)

	# All shortcuts go through GUIDE so they stay remappable via the mapping resource.
	open_action.triggered.connect(func() -> void: open_file_popup.popup_file_dialog())
	close_action.triggered.connect(_close_current_tab)
	save_action.triggered.connect(_save_current_tab)
	switch_tab_action.triggered.connect(_switch_tab)
	copy.triggered.connect(_copy_selection)
	paste.triggered.connect(_paste_clipboard)
	cut.triggered.connect(_cut_selection)
	undo.triggered.connect(_undo)
	delete.triggered.connect(_delete_selection)
	cancel.triggered.connect(_cancel_selection)

	_build_toast()
	_build_close_dialog()
	_build_status_bar()
	_setup_mod_tab()


func _build_status_bar() -> void:
	var vbox := tab_cont.get_parent()

	vbox.add_child(HSeparator.new())

	var bar := MarginContainer.new()
	bar.add_theme_constant_override("margin_left",   10)
	bar.add_theme_constant_override("margin_right",  10)
	bar.add_theme_constant_override("margin_top",     3)
	bar.add_theme_constant_override("margin_bottom",  3)

	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
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


func _on_mod_status_changed(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color",
		Color(0.9, 0.4, 0.4) if is_error else Color(0.5, 0.5, 0.5))


func _build_toast() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.z_index = 100

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.93)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_toast_panel.add_theme_stylebox_override("panel", style)

	_toast_label = Label.new()
	_toast_label.add_theme_font_size_override("font_size", 15)
	_toast_label.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
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
	add_child(_close_dialog)


func _on_discard_and_close() -> void:
	if is_instance_valid(_tab_pending_close):
		_tab_pending_close.queue_free()
	_tab_pending_close = null


func _on_save_and_close(action: StringName) -> void:
	if action != &"save_close":
		return
	if is_instance_valid(_tab_pending_close):
		_tab_pending_close.save_asset()
		_show_toast("Saved  " + _tab_pending_close.tab_asset.file_path.get_file())
		_tab_pending_close.queue_free()
	_tab_pending_close = null
	_close_dialog.hide()


func _switch_tab() -> void:
	# switch_tab_action is a 1D axis: positive = next tab, negative = previous.
	if switch_tab_action.value_axis_1d >= 0.0:
		tab_cont.select_next_available()
	else:
		tab_cont.select_previous_available()


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

	var new_tab := UassetFileTab.setup(asset)
	tab_cont.add_child(new_tab)
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(new_tab)


func _on_files_selected(paths: PackedStringArray) -> void:
	for path in paths:
		_on_file_selected(path)


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
		tab.save_asset()
		_show_toast("Saved  " + tab.tab_asset.file_path.get_file())


func _copy_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.copy_selection()
		_show_toast("Copied  " + tab.get_clipboard_label())


func _cut_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.cut_selection()
		_show_toast("Cut  " + tab.get_clipboard_label())


func _paste_clipboard() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.paste_clipboard()


func _delete_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.delete_selection()


func _undo() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.undo()


func _cancel_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		tab.clear_selection()


## Returns true when a text-editing control has keyboard focus.
## In that case, shortcuts like Ctrl+C/V/X/Z should go to the control, not the editor.
func _text_control_focused() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox
