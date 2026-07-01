extends Node


var _inputs_to_reset:Array[GUIDEInput] = []
var guide:Node

func _enter_tree() -> void:
	# this should run at the end of the frame, so we put in a low priority (= high number)
	process_priority = 10000000

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	for input:GUIDEInput in _inputs_to_reset:
		input._reset()

	var active_guide = guide if is_instance_valid(guide) else get_node_or_null("/root/GUIDE")
	if active_guide != null and active_guide._input_state != null:
		active_guide._input_state._reset()
