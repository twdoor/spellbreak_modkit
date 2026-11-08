@tool
extends EditorExportPlugin

var _output := ""
var _windows := false

func _get_name() -> String:
	return "Modkit CLI launcher"

func _export_begin(features: PackedStringArray, _is_debug: bool, path: String, _flags: int) -> void:
	_output = path if "linux" in features or "windows" in features or "Linux" in features or "Windows" in features else ""
	_windows = "windows" in features or "Windows" in features

func _export_end() -> void:
	if _output.is_empty() or _output.get_extension() in ["pck", "zip"] or not FileAccess.file_exists(_output):
		return
	var launcher := _output.get_base_dir().path_join("modkit.cmd" if _windows else "modkit")
	var file := FileAccess.open(launcher, FileAccess.WRITE)
	if file == null:
		push_error("Could not create CLI launcher: " + launcher)
		return
	file.store_string(windows_launcher(_output.get_file()) if _windows else linux_launcher(_output.get_file()))
	file.close()
	if not _windows:
		FileAccess.set_unix_permissions(launcher, 493)

static func linux_launcher(executable: String) -> String:
	# Shell builtins only, so this also works with an empty PATH.
	return """#!/bin/sh
SPELLBREAK_MODKIT_CLI_CWD=$(pwd -P) || exit 1
export SPELLBREAK_MODKIT_CLI_CWD
case "$0" in
  */*) modkit_launcher=$0 ;;
  *) modkit_launcher=$(command -v "$0") ;;
esac
modkit_dir=$(CDPATH= cd -P -- "${modkit_launcher%%/*}" && pwd -P) || exit 1
exec "$modkit_dir"/%s --headless --no-header -- cli "$@"
""" % ("'" + executable.replace("'", "'\\''") + "'")

static func windows_launcher(executable: String) -> String:
	var console := executable.get_basename() + ".console.exe"
	return ("@echo off\nsetlocal DisableDelayedExpansion\nset \"SPELLBREAK_MODKIT_CLI_CWD=%%CD%%\"\n"
		+ "if exist \"%%~dp0%s\" (\n  \"%%~dp0%s\" --headless --no-header -- cli %%*\n"
		+ ") else (\n  \"%%~dp0%s\" --headless --no-header -- cli %%*\n)\nexit /b %%errorlevel%%\n") \
		% [console.replace("%", "%%"), console.replace("%", "%%"), executable.replace("%", "%%")]
