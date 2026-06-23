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
			return candidate
	return ""


static func find_python() -> String:
	return find_executable(["python3", "python"])


static func run_python_script(python: String, script: String, working_dir: String,
		args: Array, output: Array) -> int:
	if python.is_empty():
		return ERR_FILE_NOT_FOUND
	var python_args: Array = ["-c", _PYTHON_CWD_RUNNER, working_dir, script]
	python_args.append_array(args)
	return OS.execute(python, python_args, output, true, false)


static func output_text(output: Array, fallback: String = "no output") -> String:
	if output.is_empty():
		return fallback
	var result := "\n".join(PackedStringArray(output)).strip_edges()
	return result if not result.is_empty() else fallback
