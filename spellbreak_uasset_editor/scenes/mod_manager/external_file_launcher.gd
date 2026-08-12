class_name ExternalFileLauncher extends RefCounted

## Cross-platform external editor and default-application launching.

static func open(path: String, prefer_text_editor: bool = false) -> Error:
	var result: int = ERR_CANT_OPEN
	if prefer_text_editor:
		result = _open_text_file(path)
	if result < 0:
		result = _open_system_app(path)
	if result < 0:
		result = OS.shell_open(path)
	return result as Error


static func _open_text_file(path: String) -> int:
	var result := _open_editor_from_environment(path)
	if result >= 0:
		return result
	match OS.get_name():
		"Windows":
			return _create_process_if_found(["notepad.exe", "notepad"], [path])
		"macOS":
			return _create_process_if_found(["open", "/usr/bin/open"], ["-t", path])
		_:
			result = _create_process_if_found([
				"zeditor", "zed", "code", "codium", "subl",
				"gedit", "kate", "kwrite", "mousepad", "xed", "pluma", "geany",
			], [path])
			return result if result >= 0 else _open_terminal_editor(path)


static func _open_editor_from_environment(path: String) -> int:
	for env_name in ["VISUAL", "EDITOR"]:
		var command := OS.get_environment(env_name).strip_edges()
		if command.is_empty():
			continue
		var result := _open_editor_command(command, path)
		if result >= 0:
			return result
	return ERR_FILE_NOT_FOUND


static func _open_editor_command(command: String, path: String) -> int:
	var parts := ProcessUtils.parse_command_line(command)
	if parts.is_empty():
		return ERR_INVALID_PARAMETER
	var executable := ProcessUtils.find_executable([parts[0]])
	if executable.is_empty():
		return ERR_FILE_NOT_FOUND
	var args := PackedStringArray()
	for i in range(1, parts.size()):
		args.append(parts[i])
	args.append(path)
	return _open_terminal_command(executable, args) \
			if _is_terminal_editor(executable) else OS.create_process(executable, args)


static func _open_terminal_editor(path: String) -> int:
	var editor := ProcessUtils.find_executable(["nvim", "vim", "nano", "vi"])
	if editor.is_empty():
		return ERR_FILE_NOT_FOUND
	return _open_terminal_command(editor, PackedStringArray([path]))


static func _open_terminal_command(command: String, args: PackedStringArray) -> int:
	var terminal := ProcessUtils.find_executable(
			["xdg-terminal-exec", "/usr/bin/xdg-terminal-exec"])
	if not terminal.is_empty():
		var xdg_terminal_args := PackedStringArray([command])
		xdg_terminal_args.append_array(args)
		return OS.create_process(terminal, xdg_terminal_args)
	terminal = ProcessUtils.find_executable(["ghostty", "alacritty", "kitty", "foot"])
	if terminal.is_empty():
		return ERR_FILE_NOT_FOUND
	var terminal_args := PackedStringArray(["-e", command])
	terminal_args.append_array(args)
	return OS.create_process(terminal, terminal_args)


static func _is_terminal_editor(executable: String) -> bool:
	return executable.get_file().get_basename().to_lower() in [
		"nvim", "vim", "nano", "vi", "emacsclient", "emacs",
	]


static func _open_system_app(path: String) -> int:
	match OS.get_name():
		"Windows":
			return _open_windows_file(path)
		"macOS":
			return _create_process_if_found(["open", "/usr/bin/open"], [path])
		_:
			return _open_unix_file(path)


static func _open_windows_file(path: String) -> int:
	var powershell := ProcessUtils.find_executable(["powershell.exe", "pwsh.exe"])
	if not powershell.is_empty():
		return OS.create_process(powershell, PackedStringArray([
			"-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
			"-Command", "Start-Process -FilePath $args[0]", path,
		]))
	var cmd := ProcessUtils.find_executable(["cmd.exe", "cmd"])
	if cmd.is_empty():
		return ERR_FILE_NOT_FOUND
	return OS.create_process(cmd, PackedStringArray(["/C", "start", "", path]))


static func _open_unix_file(path: String) -> int:
	var result := _create_process_if_found(
			["xdg-open", "/usr/bin/xdg-open", "/bin/xdg-open"], [path])
	if result >= 0:
		return result
	result = _create_process_if_found(["gio", "/usr/bin/gio"], ["open", path])
	if result >= 0:
		return result
	return _create_process_if_found(["kde-open5", "kde-open", "gnome-open"], [path])


static func _create_process_if_found(candidates: Array[String], args: Array) -> int:
	var executable := ProcessUtils.find_executable(candidates)
	if executable.is_empty():
		return ERR_FILE_NOT_FOUND
	return OS.create_process(executable, PackedStringArray(args))
