class_name ToastNotifier extends Control

const HIDDEN_Y := -8.0
const SHOWN_Y := -72.0

var _label: Label
var _panel: PanelContainer
var _tween: Tween
var _message_generation := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.z_index = 100
	_panel.add_theme_stylebox_override("panel", AppTheme.make_toast_style())
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", AppTheme.FONT_TOAST)
	_label.add_theme_color_override("font_color", AppTheme.TEXT_TOAST)
	_panel.add_child(_label)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_bottom = HIDDEN_Y
	_panel.offset_top = HIDDEN_Y
	_panel.modulate.a = 0.0
	add_child(_panel)


func show_message(message: String) -> void:
	_message_generation += 1
	var generation := _message_generation
	_label.text = message
	_kill_tween()
	_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel, "offset_bottom", SHOWN_Y, 0.25)
	_tween.parallel().tween_property(_panel, "offset_top", SHOWN_Y, 0.25)
	_tween.parallel().tween_property(_panel, "modulate:a", 1.0, 0.2)
	await _tween.finished
	await get_tree().create_timer(1.5).timeout
	if generation == _message_generation:
		hide_message()


func hide_message() -> void:
	_kill_tween()
	_tween = create_tween().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel, "offset_bottom", HIDDEN_Y, 0.3)
	_tween.parallel().tween_property(_panel, "offset_top", HIDDEN_Y, 0.3)
	_tween.parallel().tween_property(_panel, "modulate:a", 0.0, 0.25)


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
