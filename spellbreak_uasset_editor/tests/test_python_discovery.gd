extends SceneTree

var _failures: Array[String] = []


func _init() -> void:
	var python := ProcessUtils.find_system_python()
	check(not python.is_empty(), "Find a working Python installation")
	if not python.is_empty():
		check(ProcessUtils._probe_python(python) == python, "Probe resolves the actual interpreter")
		if OS.get_name() == "Linux":
			_test_path_fallbacks(python)
	var service := TextureService.new()
	var result := service.get_preview_result("missing.uasset")
	check(not result.ok and result.message == "UE4-DDS-Tools not configured",
		"Preview preserves the toolchain error")
	check(service.get_preview_image("missing.uasset") == null,
		"Existing image-only preview callers still receive null on failure")
	for failure in _failures:
		printerr("FAIL: " + failure)
	if _failures.is_empty():
		print("PASS: Python discovery and preview errors")
	quit(0 if _failures.is_empty() else 1)


func _test_path_fallbacks(python: String) -> void:
	var original_path := OS.get_environment("PATH")
	var root := OS.get_temp_dir().path_join("sb python discovery %d" % Time.get_ticks_usec())
	var first := root.path_join("first")
	var second := root.path_join("second")
	DirAccess.make_dir_recursive_absolute(first)
	DirAccess.make_dir_recursive_absolute(second)
	DirAccess.open(root).create_link(ProcessUtils.find_executable(["which"]), first.path_join("which"))
	_write_executable(first.path_join("python3"), "#!/bin/sh\necho 'Python was not found' >&2\nexit 49\n")
	DirAccess.open(root).create_link(python, second.path_join("python3"))
	OS.set_environment("PATH", first + ":" + second)
	check(not ProcessUtils.find_system_python().is_empty(), "Skip broken alias and try later PATH entries")
	DirAccess.remove_absolute(second.path_join("python3"))
	DirAccess.open(root).create_link(python, second.path_join("python"))
	check(not ProcessUtils.find_system_python().is_empty(), "Fall back from python3 alias to python")
	DirAccess.remove_absolute(second.path_join("python"))
	_write_executable(first.path_join("python"), "#!/bin/sh\nexit 1\n")
	DirAccess.open(root).create_link(python, second.path_join("runtime"))
	_write_executable(first.path_join("py"),
		"#!/bin/sh\n[ \"$1\" = '-3' ] || exit 1\nshift\nexec runtime \"$@\"\n")
	check(not ProcessUtils.find_system_python().is_empty(), "Launcher fallback requests Python 3")
	DirAccess.remove_absolute(first.path_join("py"))
	check(ProcessUtils.find_system_python().is_empty(), "Only unusable installations reports missing Python")
	OS.set_environment("PATH", original_path)
	FileUtils.remove_dir_recursive(root)


func _write_executable(path: String, contents: String) -> void:
	FileUtils.write_bytes_atomic(path, contents.to_utf8_buffer())
	OS.execute("/bin/chmod", ["+x", path])


func check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
