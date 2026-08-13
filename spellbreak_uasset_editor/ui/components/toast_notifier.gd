class_name ToastNotifier extends Control

const HIDDEN_Y := -8.0
const SHOWN_Y := -72.0

@onready var _label: Label = %ToastLabel
@onready var _panel: PanelContainer = %ToastPanel
var _tween: Tween
var _message_generation := 0


func _ready() -> void:
	_panel.add_theme_stylebox_override("panel", AppTheme.make_toast_style())
	_label.add_theme_font_size_override("font_size", AppTheme.FONT_TOAST)
	_label.add_theme_color_override("font_color", AppTheme.TEXT_TOAST)


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
