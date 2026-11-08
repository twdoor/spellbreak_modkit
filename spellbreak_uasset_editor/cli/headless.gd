extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("Use tools/modkit.py; expected request and result paths")
		quit(2)
		return
	var runner := ModkitCli.new()
	root.add_child(runner)
	runner.run(args[0], args[1])
