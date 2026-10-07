class_name ProcessUtils extends RefCounted

## Cross-platform subprocess helpers. Arguments are always passed directly to
## OS.execute; user paths are never interpolated into a shell command.

const _PYTHON_CWD_RUNNER := (
		"import os,runpy,sys; "
		+ "cwd,script=sys.argv[1:3]; args=sys.argv[3:]; "
		+ "os.chdir(cwd); sys.path[0]=os.path.dirname(os.path.abspath(script)); "
		+ "sys.argv=[script,*args]; "
		+ "runpy.run_path(script,run_name='__main__')"
)


static func find_executable(candidates: Array[String]) -> String:
	var finder := "where" if OS.get_name() == "Windows" else "which"
	for candidate in candidates:
		if candidate.is_absolute_path() and FileAccess.file_exists(candidate):
			return candidate
		var output: Array = []
		if OS.execute(finder, [candidate], output, true, false) == 0:
			var resolved := output_text(output, "").split("\n")[0].strip_edges()
			if not resolved.is_empty() and resolved.is_absolute_path() and FileAccess.file_exists(resolved):
				return resolved
			return candidate
	return ""


static func find_python() -> String:
	var bundled := BundledRuntime.executable("python")
	if not bundled.is_empty():
		return bundled
	if not OS.has_feature("editor"):
		return ""
	return find_system_python()


static func find_system_python() -> String:
	# A PATH entry can be a Microsoft Store alias, an old Python, or a broken
	# installation. Verify it can execute our code before selecting it.
	for candidate in ["python3", "python", "py"]:
		var output: Array = []
		var finder := "where" if OS.get_name() == "Windows" else "which"
		var finder_args: Array = [candidate] if OS.get_name() == "Windows" else ["-a", candidate]
		if OS.execute(finder, finder_args, output, true, false) != 0:
			continue
		for path in output_text(output, "").split("\n"):
			var executable := path.strip_edges()
			if not executable.is_absolute_path() or not FileAccess.file_exists(executable):
				continue
			var resolved := _probe_python(executable, candidate == "py")
			if not resolved.is_empty():
				return resolved
	return ""


static func _probe_python(executable: String, launcher: bool = false) -> String:
	var args: Array = ["-3"] if launcher else []
	args.append_array(["-c", "import sys; sys.exit(1) if sys.version_info < (3,10) else print(sys.executable)"])
	var output: Array = []
	if OS.execute(executable, args, output, true, false) != 0:
		return ""
	var resolved := output_text(output, "").strip_edges()
	return resolved if resolved.is_absolute_path() and FileAccess.file_exists(resolved) else ""


static func find_dotnet() -> String:
	var bundled := BundledRuntime.executable("dotnet")
	if not bundled.is_empty():
		return bundled
	return find_executable(["dotnet"]) if OS.has_feature("editor") else ""


static func python_not_found_message() -> String:
	if not OS.has_feature("editor"):
		return "Bundled Python is missing or could not be extracted. Reinstall the complete Modkit release and check that its user-data folder is writable."
	return ("Python 3.10+ was not found or could not run. Install Python 3.10+ and restart the Modkit. "
		+ "On Windows, enable Add Python to PATH or install the Python launcher (py). "
		+ "If Windows opens the Microsoft Store, disable the python.exe/python3.exe shortcuts in "
		+ "Settings > Apps > Advanced app settings > App execution aliases.")


static func run_python_script(python: String, script: String, working_dir: String,
		args: Array, output: Array) -> int:
	if python.is_empty():
		return ERR_FILE_NOT_FOUND
	var python_args: Array = ["-I", "-c", _PYTHON_CWD_RUNNER, working_dir, script]
	python_args.append_array(args)
	return OS.execute(python, python_args, output, true, false)


static func parse_command_line(command: String) -> PackedStringArray:
	var args := PackedStringArray()
	var current := ""
	var in_quotes := false
	var has_token := false
	var i := 0
	while i < command.length():
		var ch := command.substr(i, 1)
		if ch == "\\" and i + 1 < command.length() and command.substr(i + 1, 1) == '"':
			current += '"'
			has_token = true
			i += 2
			continue
		if ch == '"':
			in_quotes = not in_quotes
			has_token = true
		elif (ch == " " or ch == "\t") and not in_quotes:
			if has_token:
				args.append(current)
				current = ""
				has_token = false
		else:
			current += ch
			has_token = true
		i += 1
	if has_token:
		args.append(current)
	return args


static func output_text(output: Array, fallback: String = "no output") -> String:
	if output.is_empty():
		return fallback
	var result := "\n".join(PackedStringArray(output)).strip_edges()
	return result if not result.is_empty() else fallback
