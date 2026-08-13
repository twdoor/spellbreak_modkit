class_name BackgroundJobRunner extends RefCounted

## Owns short-lived background jobs started by temporary UI renderers. Jobs
## cannot forcibly stop a running subprocess, but cancellation drops callbacks
## immediately and application shutdown joins every worker deterministically.

var _mutex := Mutex.new()
var _next_id := 1
var _threads: Dictionary = {}
var _callbacks: Dictionary = {}
var _cancelled: Dictionary = {}
var _shutting_down := false


func run(task: Callable, completed: Callable) -> int:
	if not task.is_valid():
		return -1
	_mutex.lock()
	if _shutting_down:
		_mutex.unlock()
		return -1
	var job_id := _next_id
	_next_id += 1
	var thread := Thread.new()
	_threads[job_id] = thread
	_callbacks[job_id] = completed
	_mutex.unlock()

	var error := thread.start(_worker.bind(job_id, task))
	if error != OK:
		_mutex.lock()
		_threads.erase(job_id)
		_callbacks.erase(job_id)
		_mutex.unlock()
		return -1
	return job_id


func cancel(job_id: int) -> void:
	if job_id < 0:
		return
	_mutex.lock()
	if _threads.has(job_id):
		_cancelled[job_id] = true
		_callbacks.erase(job_id)
	_mutex.unlock()


func wait_to_finish() -> void:
	_mutex.lock()
	_shutting_down = true
	var threads: Array = _threads.values()
	_callbacks.clear()
	for job_id in _threads:
		_cancelled[job_id] = true
	_mutex.unlock()

	for thread: Thread in threads:
		if thread.is_started():
			thread.wait_to_finish()

	_mutex.lock()
	_threads.clear()
	_cancelled.clear()
	_mutex.unlock()


func _worker(job_id: int, task: Callable) -> void:
	var result: Variant = task.call()
	call_deferred("_finish_job", job_id, result)


func _finish_job(job_id: int, result: Variant) -> void:
	_mutex.lock()
	var thread: Thread = _threads.get(job_id)
	var callback: Callable = _callbacks.get(job_id, Callable())
	var cancelled := _cancelled.has(job_id) or _shutting_down
	_threads.erase(job_id)
	_callbacks.erase(job_id)
	_cancelled.erase(job_id)
	_mutex.unlock()

	if thread and thread.is_started():
		thread.wait_to_finish()
	if not cancelled and callback.is_valid():
		callback.call(result)
