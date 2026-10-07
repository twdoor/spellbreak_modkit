class_name ModWorkflowService extends BackgroundOperationService

signal finished(result: OperationResult)

func run(request: Dictionary) -> void:
	# Resolve bundled resources on the main thread before starting a subprocess.
	var script := ToolchainRegistry.mod_workflows_script()
	request = request.duplicate(true)
	request["converter"] = ToolchainRegistry.converter_dll()
	request["dotnet"] = ProcessUtils.find_dotnet()
	var error := _start_background(_run.bind(request, script),
		func(result: OperationResult) -> void: finished.emit(result))
	if error != OK:
		finished.emit(OperationResult.failed("Could not start mod workflow"))

func _run(request: Dictionary, script: String) -> OperationResult:
	var python := ProcessUtils.find_python()
	if python.is_empty() or script.is_empty():
		return OperationResult.failed("Python 3 and the bundled mod workflow tools are required")
	var temp := FileUtils.make_temp_dir("sb_workflow")
	if not temp.get("ok", false):
		return OperationResult.failed("Could not create temporary workspace")
	var folder: String = temp.path
	var request_path := folder.path_join("request.json")
	var result_path := folder.path_join("result.json")
	var error := FileUtils.write_bytes_atomic(request_path, JSON.stringify(request).to_utf8_buffer())
	if error != OK:
		FileUtils.remove_dir_recursive(folder)
		return OperationResult.failed("Could not write workflow request")
	var output: Array = []
	ProcessUtils.run_python_script(python, script, folder, [request_path, result_path], output)
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(result_path)) \
		if FileAccess.file_exists(result_path) else null
	FileUtils.remove_dir_recursive(folder)
	if not result is Dictionary:
		return OperationResult.failed(ProcessUtils.output_text(output, "Workflow returned no result"))
	return OperationResult.new(bool(result.get("ok", false)), str(result.get("message", "")), result)
