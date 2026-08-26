class_name ThemeSettingsTab extends VBoxContainer

signal close_requested
signal status_changed(text: String, is_error: bool)

const PREVIEW_DELAY_SECONDS := 0.08
const COLOR_SETTINGS := [
	{"name": "Canvas", "key": "canvas"},
	{"name": "Surfaces and Fields", "key": "surface"},
	{"name": "Hover and Active Surfaces", "key": "interactive"},
	{"name": "Bars and Popups", "key": "bars_and_popups"},
	{"name": "Primary Accent", "key": "accent"},
	{"name": "Secondary Accent", "key": "secondary_accent"},
	{"name": "Primary Text", "key": "primary_text"},
	{"name": "Secondary Text", "key": "secondary_text"},
	{"name": "Links and References", "key": "links"},
	{"name": "Success and Enabled", "key": "success"},
	{"name": "Warnings and Sections", "key": "warning"},
	{"name": "Errors and Destructive Actions", "key": "danger"},
]
const METRIC_SETTINGS := [
	{"name": "Title Text", "key": "title_text"},
	{"name": "Body Text", "key": "body_text"},
	{"name": "Small Text", "key": "small_text"},
	{"name": "Compact Text", "key": "compact_text"},
	{"name": "Tight Gap", "key": "tight_gap"},
	{"name": "Normal Gap", "key": "normal_gap"},
	{"name": "Large Gap", "key": "large_gap"},
	{"name": "Horizontal Padding", "key": "horizontal_padding"},
	{"name": "Vertical Padding", "key": "vertical_padding"},
	{"name": "Roundness", "key": "roundness"},
]

var _manager: Node
var _working_colors: Dictionary = {}
var _working_metrics: Dictionary = {}
var _initial_colors: Dictionary = {}
var _initial_metrics: Dictionary = {}
var _dirty := false
var _syncing := false
var _preview_timer: Timer

@onready var _title_label: Label = %ThemeTitle
@onready var _hint_label: Label = %ThemeHint
@onready var _colors_container: VBoxContainer = %ColorsContainer
@onready var _metrics_container: VBoxContainer = %MetricsContainer
@onready var _status_label: Label = %StatusLabel
@onready var _save_button: Button = %SaveButton
@onready var _defaults_button: Button = %DefaultsButton
@onready var _close_button: Button = %CloseButton


func setup(manager: Node) -> ThemeSettingsTab:
	_manager = manager
	return self


func _ready() -> void:
	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = PREVIEW_DELAY_SECONDS
	_preview_timer.timeout.connect(_apply_preview)
	add_child(_preview_timer)
	_configure_scene_ui()
	refresh()


func refresh() -> void:
	if _manager == null:
		return
	_working_colors = _manager.get_color_values()
	_working_metrics = _manager.get_metric_values()
	_initial_colors = _working_colors.duplicate()
	_initial_metrics = _working_metrics.duplicate()
	_dirty = false
	_set_status("", false)
	_rebuild_controls()
	_update_footer()


func _configure_scene_ui() -> void:
	AppTheme.style_header(_title_label)
	_title_label.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	AppTheme.style_muted(_hint_label)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	AppTheme.style_muted(_status_label)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_save_button.add_theme_color_override("font_color", AppTheme.BTN_SAVE)
	_defaults_button.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
	AppTheme.style_muted_btn(_close_button)


func _rebuild_controls() -> void:
	_syncing = true
	_clear_children(_colors_container)
	_clear_children(_metrics_container)
	_build_color_controls()
	_build_metric_controls()
	_syncing = false


func _build_color_controls() -> void:
	var grid := _settings_grid()
	_colors_container.add_child(grid)
	for setting: Dictionary in COLOR_SETTINGS:
		var key := str(setting.key)
		var label := _setting_label(str(setting.name), key)
		grid.add_child(label)
		var picker := ColorPickerButton.new()
		picker.custom_minimum_size = Vector2(190, 30)
		picker.color = _working_colors[key]
		picker.tooltip_text = "%s — %s" % [key, _color_hex(picker.color)]
		picker.color_changed.connect(_on_color_changed.bind(key, picker))
		grid.add_child(picker)


func _build_metric_controls() -> void:
	var grid := _settings_grid()
	_metrics_container.add_child(grid)
	for setting: Dictionary in METRIC_SETTINGS:
		var key := str(setting.key)
		grid.add_child(_setting_label(str(setting.name), key))
		var input := SpinBox.new()
		input.custom_minimum_size = Vector2(140, 0)
		input.min_value = 0
		input.max_value = 256
		input.step = 1
		input.allow_greater = true
		input.value = _working_metrics[key]
		input.tooltip_text = key
		input.value_changed.connect(_on_metric_changed.bind(key))
		grid.add_child(input)


func _on_color_changed(color: Color, key: String, picker: ColorPickerButton) -> void:
	if _syncing:
		return
	_working_colors[key] = color
	picker.tooltip_text = "%s — %s" % [key, _color_hex(color)]
	_queue_preview()


func _on_metric_changed(value: float, key: String) -> void:
	if _syncing:
		return
	_working_metrics[key] = int(value)
	_queue_preview()


func _queue_preview() -> void:
	_dirty = true
	_update_footer()
	_set_status("Previewing unsaved theme changes", false)
	_preview_timer.start()


func _apply_preview() -> void:
	var error: Error = _manager.preview_values(_working_colors, _working_metrics)
	if error != OK:
		_set_status("Could not preview the theme (error %d)." % error, true)


func _on_save_pressed() -> void:
	_preview_timer.stop()
	_apply_preview()
	var error: Error = _manager.save_values(_working_colors, _working_metrics)
	if error != OK:
		_set_status("Could not save the theme (error %d)." % error, true)
		return
	_initial_colors = _working_colors.duplicate()
	_initial_metrics = _working_metrics.duplicate()
	_dirty = false
	_update_footer()
	_set_status("Theme saved", false)


func _on_defaults_pressed() -> void:
	_working_colors = _manager.get_default_color_values()
	_working_metrics = _manager.get_default_metric_values()
	_dirty = true
	_rebuild_controls()
	_update_footer()
	_apply_preview()
	_set_status("Restored built-in defaults. Save to keep them.", false)


func _on_close_pressed() -> void:
	_preview_timer.stop()
	if _dirty:
		_manager.preview_values(_initial_colors, _initial_metrics)
	close_requested.emit()


func _update_footer() -> void:
	_save_button.disabled = not _dirty
	_close_button.text = "Cancel" if _dirty else "Close"
	_close_button.tooltip_text = (
		"Discard previewed changes" if _dirty else "Close theme settings"
	)


func _set_status(text: String, is_error: bool) -> void:
	_status_label.text = text
	_status_label.visible = not text.is_empty()
	AppTheme.style_status(_status_label, is_error)
	if not text.is_empty():
		status_changed.emit(text, is_error)


func _settings_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", AppTheme.SPACING_ROW)
	grid.add_theme_constant_override("v_separation", AppTheme.SPACING_FIELD)
	return grid


func _setting_label(text: String, key: String) -> Label:
	var label := Label.new()
	label.text = text
	label.tooltip_text = key
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _clear_children(parent: Node) -> void:
	for child: Node in parent.get_children():
		child.free()


func _color_hex(color: Color) -> String:
	return "#" + color.to_html(true)
