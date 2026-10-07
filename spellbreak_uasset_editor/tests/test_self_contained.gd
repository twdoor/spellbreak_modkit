extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var failures := ToolchainSmokeCheck.new().run(args[0] if not args.is_empty() else "")
	for failure in failures:
		printerr("FAIL: " + failure)
	if failures.is_empty():
		print("PASS: self-contained toolchain (empty PATH)")
	quit(0 if failures.is_empty() else 1)
