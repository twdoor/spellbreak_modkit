@tool
## Helper node for detecting inputs. Detects the next input matching a specification and 
## emits a signal with the detected input. 
class_name GUIDEInputDetector
extends Node

## The device type for which the input should be filtered.
const DeviceType = GUIDEInput.DeviceType

## Which joy index should be used for detected joy events
enum JoyIndex {
	# Use -1, so the detected input will match any joystick
	ANY = 0,
	# Use the actual index of the detected joystick.
	DETECTED = 1
}

enum DetectionState {
	# The detector is currently idle.
	IDLE = 0,
	# The detector is currently counting down before starting the detection.
	COUNTDOWN = 3,
	# The detector waits for all abort inputs to be released before starting the detection.
	INPUT_PRE_CLEAR = 4,
	# The detector is currently detecting input.
	DETECTING = 1,
	# The detector has finished detecting but is waiting for input to be released after the detection.
	INPUT_POST_CLEAR = 2,
}

## A countdown between initiating a dection and the actual start of the 
## detection. This is useful because when the user clicks a button to
## start a detection, we want to make sure that the player is actually
## ready (and not accidentally moves anything). If set to 0, no countdown
## will be started.
@export_range(0, 2, 0.1, "or_greater") var detection_countdown_seconds:float = 0.5

## Minimum amplitude to detect any axis. 
@export_range(0, 1, 0.1, "or_greater") var minimum_axis_amplitude:float = 0.2

## If any of these inputs is encountered, the detector will 
## treat this as "abort detection". 
@export var abort_detection_on:Array[GUIDEInput] = []

## Which joy index should be returned for detected joy events.
@export var use_joy_index:JoyIndex = JoyIndex.ANY

## Whether trigger buttons on controllers should be detected when 
## then action value type is limited to boolean.
@export var allow_triggers_for_boolean_actions:bool = true

## Emitted when the detection has started (e.g. countdown has elapsed).
## Can be used to signal this to the player.
signal detection_started()

## Emitted when the input detector detects an input of the given type.
## If detection was aborted the given input is null.
signal input_detected(input:GUIDEInput)

# The timer for the detection countdown.
var _timer:Timer

# The current state of the detection.
var _status:DetectionState = DetectionState.IDLE
# Mapping contexts that were active when the detection started. We need to restore these once the detection is
# finished or aborted.
var _saved_mapping_contexts:Array[GUIDEMappingContext] = []

# The last detected input.
var _last_detected_input:GUIDEInput = null
# Abort inputs currently subscribed to GUIDE state.
var _abort_inputs_in_use:Array[GUIDEInput] = []
# Inputs that must return to neutral before disabled mapping contexts are restored.
var _post_clear_inputs:Array[GUIDEInput] = []

func _ready():
	# don't run the process function if we are not detecting to not waste resources
	set_process(false)
	_timer = Timer.new()
	_timer.one_shot = true
	add_child(_timer, false, Node.INTERNAL_MODE_FRONT)
	_timer.timeout.connect(_begin_detection)
	

## Whether the input detector is currently detecting input.
var is_detecting:bool:
	get: return _status != DetectionState.IDLE

var _value_type:GUIDEAction.GUIDEActionValueType
var _device_types:Array[DeviceType] = []

## Detects a boolean input type.
func detect_bool(device_types:Array[DeviceType] = []) -> void:
	detect(GUIDEAction.GUIDEActionValueType.BOOL, device_types)


## Detects a 1D axis input type.
func detect_axis_1d(device_types:Array[DeviceType] = []) -> void:
	detect(GUIDEAction.GUIDEActionValueType.AXIS_1D, device_types)

	
## Detects a 2D axis input type.
func detect_axis_2d(device_types:Array[DeviceType] = []) -> void:
	detect(GUIDEAction.GUIDEActionValueType.AXIS_2D, device_types)


## Detects a 3D axis input type.
func detect_axis_3d(device_types:Array[DeviceType] = []) -> void:
	detect(GUIDEAction.GUIDEActionValueType.AXIS_3D, device_types)


## Detects the given input type. If device types are given
## will only detect inputs from the given device types. 
## Otherwise will detect inputs from all supported device types.
func detect(value_type:GUIDEAction.GUIDEActionValueType,
		device_types:Array[DeviceType] = []) -> void:
	if device_types == null:
		push_error("Device types must not be null. Supply an empty array if you want to detect input from all devices.")
		return
		
	if device_types.has(DeviceType.TOUCH):
		push_error("Detecting touch events is not supported.")
	

	# If we are already detecting, abort this.
	if _status == DetectionState.DETECTING or _status == DetectionState.INPUT_PRE_CLEAR or _status == DetectionState.INPUT_POST_CLEAR:
		_clear_abort_inputs()
	
	# and start a new detection.
	_status = DetectionState.COUNTDOWN
	_clear_abort_inputs()
	_clear_post_clear_inputs()
	
	_value_type = value_type
	_device_types = device_types
	_timer.stop()
	
	if detection_countdown_seconds > 0:
		_timer.start(detection_countdown_seconds)
	else:
		_begin_detection.call_deferred()
		
## This is called by the timer when the countdown has elapsed.
func _begin_detection():
	# when we begin we want to make sure that any abort input is
	# currently not actuated, otherwise we'd get wrong results.
	# therefore we now run a pre-clear phase where we ensure that 
	# abort input is not pressed.
	
	_status = DetectionState.INPUT_PRE_CLEAR

	var guide: Variant = _get_guide()
	# enable all abort detection inputs
	if guide != null:
		for input in abort_detection_on:
			input._state = guide._input_state
			input._begin_usage()
			_abort_inputs_in_use.append(input)

	# we also use this inside the editor where the GUIDE
	# singleton is not active. Here we don't need to enable
	# and disable the mapping contexts.		
	if not Engine.is_editor_hint() and guide != null:
		# save currently active mapping contexts
		_saved_mapping_contexts = guide.get_enabled_mapping_contexts()
		
		# disable all mapping contexts
		for context in _saved_mapping_contexts:
			guide.disable_mapping_context(context)
			
	# enable _process so we can start the pre-clear phase
	# once the _process function has determined that no abort input
	# is currently pressed, it will switch to detection phase
	set_process(true)

## Aborts a running detection. If no detection currently runs
## does nothing.
func abort_detection() -> void:
	_timer.stop()
	_clear_post_clear_inputs()
	if _status == DetectionState.IDLE:
		_clear_abort_inputs()
		return
	if _status == DetectionState.COUNTDOWN:
		_clear_abort_inputs()
		_status = DetectionState.IDLE
		input_detected.emit(null)
		return
	# Delivering null runs the same post-clear and context-restore path as a
	# finished detection.
	if _status == DetectionState.INPUT_PRE_CLEAR \
			or _status == DetectionState.DETECTING \
			or _status == DetectionState.INPUT_POST_CLEAR:
		_deliver(null)

## This is called while we are waiting for input to be released.
func _process(delta: float) -> void:
	# if we are not waiting for input clear, we don't need to do anything
	if _status != DetectionState.INPUT_PRE_CLEAR and _status != DetectionState.INPUT_POST_CLEAR:
		set_process(false)
		return

	# check if the input is still actuated. We do this to avoid the problem
	# of this input accidentally triggering something in the mapping contexts
	# when we enable them again.
	for input in _abort_inputs_in_use:
		if input._value.is_finite() and input._value.length() > 0:
			# we still have input, so we are still waiting
			# retry next frame
			return
	for input in _post_clear_inputs:
		if input._value.is_finite() and input._value.length() > 0:
			return
			
	# if we are here, the input is no longer actuated
	
	if _status == DetectionState.INPUT_PRE_CLEAR:
		# pre-clear phase is finished, we can now start the actual
		# detection
		# print("pre-clear done, detecting now")
		_status = DetectionState.DETECTING
		set_process(false)
		detection_started.emit()
		return
	
	# otherwise, this was post-clear, so we can tear down the whole
	# thing.
	
	_clear_abort_inputs()
	_clear_post_clear_inputs()
	
	# restore the mapping contexts
	# but only when not running in the editor
	var guide: Variant = _get_guide()
	if not Engine.is_editor_hint() and guide != null:
		for context in _saved_mapping_contexts:
			guide.enable_mapping_context(context)
		
	# set status to idle
	_status = DetectionState.IDLE
	# and deliver the detected input
	input_detected.emit(_last_detected_input)

## This is called in any state when input is received.
func _input(event:InputEvent) -> void:
	if _status == DetectionState.IDLE:
		return
		
	# print(event)

	# while detecting, we're the only ones consuming input and we eat this input
	# to not accidentally trigger built-in Godot mappings (e.g. UI stuff)
	get_viewport().set_input_as_handled()
	# but we still feed it into GUIDE's global state so this state stays 
	# up to date. This should have no effect because we disabled all mapping
	# contexts.
	if not Engine.is_editor_hint():
		var guide: Variant = _get_guide()
		if guide != null:
			guide.inject_input(event)

	if _status == DetectionState.DETECTING:
		# check if any abort input will trigger
		for input in abort_detection_on:
			# if it triggers, we abort
			if input._value.is_finite() and input._value.length() > 0:
				# print("abort")
				abort_detection()
				return	
			
		# check if the event matches the device type we are
		# looking for	
		if not _matches_device_types(event):
			return
		
		# then check if it can be mapped to the desired 
		# value type	
		match _value_type:
			GUIDEAction.GUIDEActionValueType.BOOL:
				_try_detect_bool(event)
			GUIDEAction.GUIDEActionValueType.AXIS_1D:
				_try_detect_axis_1d(event)
			GUIDEAction.GUIDEActionValueType.AXIS_2D:
				_try_detect_axis_2d(event)
			GUIDEAction.GUIDEActionValueType.AXIS_3D:
				_try_detect_axis_3d(event)


func _matches_device_types(event:InputEvent) -> bool:
	if _device_types.is_empty():
		return true
	
	if event is InputEventKey:
		return _device_types.has(DeviceType.KEYBOARD)
		
	if event is InputEventMouse:
		return _device_types.has(DeviceType.MOUSE)
		
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return _device_types.has(DeviceType.JOY)	

	return false

			
func _try_detect_bool(event:InputEvent) -> void:
	# we always detect key input on release to avoid
	# edge cases with multiple key invocations and modifier keys.
	
	if event is InputEventKey and event.is_released():
		var result := GUIDEInputKey.new()
		result.key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		if result.key == KEY_NONE:
			return
		result.shift = event.shift_pressed
		result.control = event.ctrl_pressed
		result.meta = event.meta_pressed
		result.alt = event.alt_pressed
		_deliver(result)
		return
		
	if event is InputEventMouseButton and event.is_released():
		var result := GUIDEInputMouseButton.new()
		result.button = event.button_index
		_deliver(result)
		return
		
	if event is InputEventJoypadButton and event.is_released():
		var result := GUIDEInputJoyButton.new()
		result.button = event.button_index
		result.joy_index = _find_joy_index(event.device)
		_deliver(result)
		
	if allow_triggers_for_boolean_actions:
		# only allow joypad trigger buttons
		if not (event is InputEventJoypadMotion):
			return
		if event.axis != JOY_AXIS_TRIGGER_LEFT and \
				event.axis != JOY_AXIS_TRIGGER_RIGHT:
			return
			
		var result := GUIDEInputJoyAxis1D.new()
		result.axis = event.axis
		result.joy_index =  _find_joy_index(event.device)
		_deliver(result)
					
		
		
func _try_detect_axis_1d(event:InputEvent) -> void:
	# we sometimes get motion events where no relative movement happened, we are only
	# interested in the ones where it does
	if event is InputEventMouseMotion and event.relative.length_squared() > 0:
		var result := GUIDEInputMouseAxis1D.new()
		# Pick the direction in which the mouse was moved more.
		if abs(event.relative.x) > abs(event.relative.y):
			result.axis	= GUIDEInputMouseAxis1D.GUIDEInputMouseAxis.X 
		else:
			result.axis	= GUIDEInputMouseAxis1D.GUIDEInputMouseAxis.Y
		_deliver(result)
		return

	if event is InputEventJoypadMotion:
		if abs(event.axis_value) < minimum_axis_amplitude:
			return
			
		var result := GUIDEInputJoyAxis1D.new()
		result.axis = event.axis
		result.joy_index = _find_joy_index(event.device)
		_deliver(result)
		
			
func _try_detect_axis_2d(event:InputEvent) -> void:
	if event is InputEventMouseMotion:
		var result := GUIDEInputMouseAxis2D.new()
		_deliver(result)
		return
		
	if event is InputEventJoypadMotion:
		if event.axis_value < minimum_axis_amplitude:
			return

		var result := GUIDEInputJoyAxis2D.new()
		match event.axis:
			JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y:
				result.x = JOY_AXIS_LEFT_X
				result.y = JOY_AXIS_LEFT_Y
			JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y:
				result.x = JOY_AXIS_RIGHT_X
				result.y = JOY_AXIS_RIGHT_Y
			_:
				# not supported for detection
				return
		result.joy_index = _find_joy_index(event.device)
		_deliver(result)
		return
			

func _try_detect_axis_3d(event:InputEvent) -> void:
	# currently no input for 3D
	pass		


func _find_joy_index(device_id:int) -> int:
	if use_joy_index == JoyIndex.ANY:
		return -1
	
	var pads := Input.get_connected_joypads()
	for i in pads.size():
		if pads[i] == device_id:
			return i
			
	return -1

func _deliver(input:GUIDEInput) -> void:
	# print("deliver" , input)
	_clear_post_clear_inputs()
	_last_detected_input = input
	var guide: Variant = _get_guide()
	if input != null and not Engine.is_editor_hint() and guide != null:
		input._state = guide._input_state
		input._begin_usage()
		_post_clear_inputs.append(input)
	_status = DetectionState.INPUT_POST_CLEAR
	# enable processing so we can check if the input is released before we re-enable GUIDE's mapping contexts
	set_process(true)


func _clear_post_clear_inputs() -> void:
	for input in _post_clear_inputs:
		if is_instance_valid(input):
			input._end_usage()
			input._state = null
	_post_clear_inputs.clear()


func _clear_abort_inputs() -> void:
	for input in _abort_inputs_in_use:
		if is_instance_valid(input):
			input._end_usage()
			input._state = null
	_abort_inputs_in_use.clear()


func _get_guide():
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("GUIDE")
