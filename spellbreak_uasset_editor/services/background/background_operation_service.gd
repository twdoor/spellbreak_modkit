class_name BackgroundOperationService extends RefCounted

## Shared lifecycle for services that permit one background operation at a time.

var _background_operation := SingleBackgroundOperation.new()


func is_busy() -> bool:
	return _background_operation.is_busy()


func wait_to_finish() -> void:
	_background_operation.wait_to_finish()


func _start_background(task: Callable, completed: Callable) -> Error:
	return _background_operation.start(task, func(raw_result: Variant) -> void:
		var result := raw_result as OperationResult
		if result == null:
			result = OperationResult.failed("Background operation returned an invalid result")
		if completed.is_valid():
			completed.call(result)
	)
