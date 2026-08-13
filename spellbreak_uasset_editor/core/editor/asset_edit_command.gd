class_name AssetEditCommand extends RefCounted

## One reversible asset mutation. Commands own behavior; AssetDocument owns
## ordering, dirty state, undo, and redo.

var description: String
var _apply_action: Callable
var _revert_action: Callable


func _init(label: String, apply_action: Callable, revert_action: Callable) -> void:
	description = label
	_apply_action = apply_action
	_revert_action = revert_action


func is_valid() -> bool:
	return _apply_action.is_valid() and _revert_action.is_valid()


func apply() -> void:
	_apply_action.call()


func revert() -> void:
	_revert_action.call()
