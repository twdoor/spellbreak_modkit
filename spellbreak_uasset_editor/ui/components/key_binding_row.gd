class_name KeyBindingRow extends HBoxContainer

signal binding_action_requested(action: StringName, slot: int, request: int)

enum BindingRequest {
	CAPTURE,
	CLEAR,
	RESET,
}

var action := StringName()
var _display_name := ""
var _binding_labels: Array[String] = []

@onready var _action_label: Label = %ActionLabel
@onready var _primary_button: Button = %PrimaryBindingButton
@onready var _secondary_button: Button = %SecondaryBindingButton


func configure(action_name: StringName, display_name: String,
		binding_labels: Array[String]) -> KeyBindingRow:
	action = action_name
	_display_name = display_name
	_binding_labels = binding_labels
	if is_node_ready():
		_sync_controls()
	return self


func _ready() -> void:
	AppTheme.style_muted_btn(_primary_button)
	AppTheme.style_muted_btn(_secondary_button)
	_sync_controls()


func set_binding_text(slot: int, text: String) -> void:
	if slot == 0:
		_primary_button.text = text
	elif slot == 1:
		_secondary_button.text = text


func _sync_controls() -> void:
	_action_label.text = _display_name
	if _binding_labels.size() > 0:
		_primary_button.text = _binding_labels[0]
	if _binding_labels.size() > 1:
		_secondary_button.text = _binding_labels[1]


func _on_primary_gui_input(event: InputEvent) -> void:
	_handle_binding_input(event, 0, _primary_button)


func _on_secondary_gui_input(event: InputEvent) -> void:
	_handle_binding_input(event, 1, _secondary_button)


func _handle_binding_input(event: InputEvent, slot: int, button: Button) -> void:
	if not event is InputEventMouseButton or not (event as InputEventMouseButton).pressed:
		return
	var request := -1
	match (event as InputEventMouseButton).button_index:
		MOUSE_BUTTON_LEFT: request = BindingRequest.CAPTURE
		MOUSE_BUTTON_MIDDLE: request = BindingRequest.CLEAR
		MOUSE_BUTTON_RIGHT: request = BindingRequest.RESET
		_: return
	binding_action_requested.emit(action, slot, request)
	button.accept_event()
