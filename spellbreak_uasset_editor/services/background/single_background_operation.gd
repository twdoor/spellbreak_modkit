class_name SingleBackgroundOperation extends RefCounted

## Runs at most one BackgroundJobRunner task at a time and reports completion on
## the main thread. Useful for services that expose a simple busy/finished API.

var _runner := BackgroundJobRunner.new()
var _busy_mutex := Mutex.new()
var _busy := false


func is_busy() -> bool:
	_busy_mutex.lock()
	var result := _busy
	_busy_mutex.unlock()
	return result


func start(task: Callable, completed: Callable) -> Error:
	if not task.is_valid():
		return ERR_INVALID_PARAMETER
	_busy_mutex.lock()
	if _busy:
		_busy_mutex.unlock()
		return ERR_ALREADY_IN_USE
	_busy = true
	_busy_mutex.unlock()

	var job_id := _runner.run(task, _on_job_finished.bind(completed))
	if job_id < 0:
		_busy_mutex.lock()
		_busy = false
		_busy_mutex.unlock()
		return FAILED
	return OK


func wait_to_finish() -> void:
	_runner.wait_to_finish()
	_busy_mutex.lock()
	_busy = false
	_busy_mutex.unlock()


func _on_job_finished(result: Variant, completed: Callable) -> void:
	_busy_mutex.lock()
	_busy = false
	_busy_mutex.unlock()
	if completed.is_valid():
		completed.call(result)
