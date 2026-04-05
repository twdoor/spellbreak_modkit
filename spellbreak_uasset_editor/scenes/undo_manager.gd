class_name UndoManager extends RefCounted

## Manages a bounded undo stack for asset editing operations.
## Only stores/retrieves entries — execution of undo actions is handled by UassetFileTab.

const MAX_UNDO := 50
var _stack: Array = []


func push(entry: Dictionary) -> void:
	_stack.append(entry)
	if _stack.size() > MAX_UNDO:
		_stack.pop_front()


func pop() -> Dictionary:
	if _stack.is_empty():
		return {}
	return _stack.pop_back()


func is_empty() -> bool:
	return _stack.is_empty()


func clear() -> void:
	_stack.clear()
