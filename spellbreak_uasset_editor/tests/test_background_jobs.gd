extends SceneTree

var _runner := BackgroundJobRunner.new()
var _cancelled_callback_ran := false


func _init() -> void:
	var job_id := _runner.run(func() -> int:
		OS.delay_msec(10)
		return 42,
		_on_first_complete)
	if job_id < 0:
		_fail("runner rejected callback test")
		return
	create_timer(2.0).timeout.connect(func() -> void:
		_fail("background callback test timed out"))


func _on_first_complete(result: Variant) -> void:
	if int(result) != 42:
		_fail("runner returned the wrong result")
		return
	var cancelled_id := _runner.run(func() -> String:
		OS.delay_msec(20)
		return "cancelled",
		func(_value: Variant) -> void: _cancelled_callback_ran = true)
	if cancelled_id < 0:
		_fail("runner rejected cancellation test")
		return
	_runner.cancel(cancelled_id)
	create_timer(0.1).timeout.connect(_finish_cancellation_test)


func _finish_cancellation_test() -> void:
	_runner.wait_to_finish()
	if _cancelled_callback_ran:
		_fail("cancelled background callback still ran")
		return
	print("PASS: background job integration tests")
	quit(0)


func _fail(message: String) -> void:
	_runner.wait_to_finish()
	printerr("FAIL: " + message)
	quit(1)
