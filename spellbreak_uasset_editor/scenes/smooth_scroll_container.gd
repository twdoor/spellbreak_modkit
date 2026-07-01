class_name SmoothScrollContainer extends ScrollContainer

const DEFAULT_WHEEL_STEP := 96.0
const DEFAULT_SMOOTH_TIME := 0.12
const DEFAULT_PAN_MULTIPLIER := 1.0

@export var smooth_scroll_enabled := true
@export var wheel_step := DEFAULT_WHEEL_STEP
@export var smooth_time := DEFAULT_SMOOTH_TIME
@export var pan_multiplier := DEFAULT_PAN_MULTIPLIER

var _target_scroll := Vector2.ZERO
var _animated_scroll := Vector2.ZERO
var _is_smoothing := false


func _ready() -> void:
	_sync_scroll_state()
	set_process(false)


func _gui_input(event: InputEvent) -> void:
	if not smooth_scroll_enabled:
		return

	if event is InputEventMouseButton:
		if _handle_mouse_wheel(event as InputEventMouseButton):
			return
	elif event is InputEventPanGesture:
		var pan := event as InputEventPanGesture
		if pan.delta != Vector2.ZERO:
			_queue_scroll(pan.delta * pan_multiplier)
			accept_event()
			return


func _process(delta: float) -> void:
	_target_scroll.x = _clamp_horizontal(_target_scroll.x)
	_target_scroll.y = _clamp_vertical(_target_scroll.y)

	var t := 1.0
	if smooth_time > 0.0:
		t = 1.0 - pow(0.001, delta / smooth_time)
	_animated_scroll = _animated_scroll.lerp(_target_scroll, t)
	scroll_horizontal = int(round(_animated_scroll.x))
	scroll_vertical = int(round(_animated_scroll.y))

	if _animated_scroll.distance_to(_target_scroll) <= 0.5:
		scroll_horizontal = int(round(_target_scroll.x))
		scroll_vertical = int(round(_target_scroll.y))
		_sync_scroll_state()
		_is_smoothing = false
		set_process(false)


func _handle_mouse_wheel(event: InputEventMouseButton) -> bool:
	if not event.pressed:
		return false

	var amount := wheel_step * maxf(event.factor, 0.25)
	var delta := Vector2.ZERO
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.shift_pressed:
				delta.x = -amount
			else:
				delta.y = -amount
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.shift_pressed:
				delta.x = amount
			else:
				delta.y = amount
		MOUSE_BUTTON_WHEEL_LEFT:
			delta.x = -amount
		MOUSE_BUTTON_WHEEL_RIGHT:
			delta.x = amount
		_:
			return false

	_queue_scroll(delta)
	accept_event()
	return true


func _queue_scroll(delta: Vector2) -> void:
	if not _is_smoothing:
		_sync_scroll_state()
		_is_smoothing = true
	_target_scroll.x = _clamp_horizontal(_target_scroll.x + delta.x)
	_target_scroll.y = _clamp_vertical(_target_scroll.y + delta.y)
	set_process(true)


func _sync_scroll_state() -> void:
	_animated_scroll = Vector2(scroll_horizontal, scroll_vertical)
	_target_scroll = _animated_scroll


func _clamp_horizontal(value: float) -> float:
	var bar := get_h_scroll_bar()
	return clampf(value, 0.0, maxf(0.0, bar.max_value - bar.page))


func _clamp_vertical(value: float) -> float:
	var bar := get_v_scroll_bar()
	return clampf(value, 0.0, maxf(0.0, bar.max_value - bar.page))
