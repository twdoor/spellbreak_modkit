extends RefCounted

const MARKER := "# Spellbreak Modkit managed CLI"
const STATE := "user://cli_install.cfg"

static func installed_path() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(STATE) == OK:
		return str(cfg.get_value("cli", "path", ""))
	return ""

static func install(command: String) -> String:
	var regex := RegEx.new()
	regex.compile("^[a-zA-Z][a-zA-Z0-9_-]{0,63}$")
	if regex.search(command) == null:
		return "Use a command starting with a letter, followed by letters, digits, - or _."
	if OS.has_feature("editor"):
		return "CLI installation requires an exported app."
	if not installed_path().is_empty():
		return "Uninstall the current command before installing another."
	var windows := OS.get_name() == "Windows"
	if not windows and OS.get_name() not in ["Linux", "macOS"]:
		return "CLI installation is not supported on this platform."
	var directory := OS.get_environment("LOCALAPPDATA").path_join("SpellbreakModkit/bin") if windows else OS.get_environment("HOME").path_join(".local/bin")
	var path := directory.path_join(command + (".cmd" if windows else ""))
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) or DirAccess.open(directory) != null and DirAccess.open(directory).is_link(path):
		return "A file already exists at " + path + ". It was not changed."
	var executable := OS.get_environment("APPIMAGE")
	if executable.is_empty():
		executable = OS.get_executable_path()
	var body: String
	if windows:
		var console := executable.get_basename() + ".console.exe"
		if FileAccess.file_exists(console):
			executable = console
		body = "@echo off\r\nrem " + MARKER + "\r\nsetlocal DisableDelayedExpansion\r\nset \"SPELLBREAK_MODKIT_CLI_CWD=%CD%\"\r\n\"" + executable.replace("%", "%%") + "\" --headless --no-header -- cli %*\r\nexit /b %errorlevel%\r\n"
	else:
		body = "#!/bin/sh\n" + MARKER + "\nSPELLBREAK_MODKIT_CLI_CWD=$(pwd -P) || exit 1\nexport SPELLBREAK_MODKIT_CLI_CWD\nexec '" + executable.replace("'", "'\\''") + "' --headless --no-header -- cli \"$@\"\n"
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return "Cannot create launcher directory: " + error_string(error)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write launcher: " + error_string(FileAccess.get_open_error())
	file.store_string(body)
	file.close()
	if not windows:
		error = FileAccess.set_unix_permissions(path, 493)
		if error != OK:
			DirAccess.remove_absolute(path)
			return "Cannot make launcher executable: " + error_string(error)
	var cfg := ConfigFile.new()
	cfg.set_value("cli", "path", path)
	cfg.set_value("cli", "body", body)
	error = cfg.save(STATE)
	if error != OK:
		DirAccess.remove_absolute(path)
		return "Cannot save installation record: " + error_string(error)
	return "Installed " + path + ". Add " + directory + " to your user PATH if needed, then run " + command + " --help."

static func uninstall() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(STATE) != OK:
		return "No CLI installation recorded."
	var path := str(cfg.get_value("cli", "path", ""))
	if FileAccess.file_exists(path):
		if FileAccess.get_file_as_string(path) != str(cfg.get_value("cli", "body", "")):
			return "Launcher has been modified; refusing to remove " + path
		var error := DirAccess.remove_absolute(path)
		if error != OK:
			return "Cannot remove launcher: " + error_string(error)
	var record_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE))
	return "CLI uninstalled." if record_error == OK else "Launcher removed; cannot clear installation record: " + error_string(record_error)
