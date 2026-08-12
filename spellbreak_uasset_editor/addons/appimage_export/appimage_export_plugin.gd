@tool
class_name AppimageExportPlugin
extends EditorExportPlugin

const CATEGORY := "AppImage"
const APPIMAGETOOL_PATH_SETTING := "appimage_export/appimagetool_path"
const EXECUTABLE_PERMISSIONS := 493 # 0755
const EXECUTE_PERMISSION_MASK := 73 # 0111
const TOOL_NAMES := [
	"appimagetool",
	"appimagetool.AppImage",
	"appimagetool.appimage",
	"appimagetool-x86_64.AppImage",
	"appimagetool-aarch64.AppImage",
]

var _executable_path := ""


func _get_name() -> String:
	return "AppImage"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform.get_os_name() == "Linux"


func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
	if not _supports_platform(platform):
		return []
	return [
		{
			"option": {
				"name": "appimage/generate_an_appimage",
				"type": TYPE_BOOL,
			},
			"default_value": false,
			"update_visibility": true,
		},
		{
			"option": {
				"name": "appimage/app_name",
				"type": TYPE_STRING,
			},
			"default_value": str(
				ProjectSettings.get_setting("application/config/name", "Application")
			),
		},
		{
			"option": {
				"name": "appimage/app_description",
				"type": TYPE_STRING,
			},
			"default_value": "",
		},
		{
			"option": {
				"name": "appimage/icon",
				"type": TYPE_STRING,
				"hint": PROPERTY_HINT_FILE,
				"hint_string": "*.png,*.svg",
			},
			"default_value": str(
				ProjectSettings.get_setting("application/config/icon", "")
			),
		},
	]


func _get_export_option_visibility(
	platform: EditorExportPlatform,
	option: String
) -> bool:
	if not _supports_platform(platform):
		return false
	if option == "appimage/generate_an_appimage":
		return true
	return bool(get_option("appimage/generate_an_appimage"))


func _get_export_option_warning(
	platform: EditorExportPlatform,
	option: String
) -> String:
	if not _supports_platform(platform):
		return ""
	if not bool(get_option("appimage/generate_an_appimage")):
		return ""
	if option == "appimage/generate_an_appimage":
		return _appimagetool_warning()
	if option == "appimage/app_name":
		if str(get_option(option)).strip_edges().is_empty():
			return "An application name is required."
	if option == "appimage/icon":
		var icon_path := _resolve_file_path(str(get_option(option)))
		if icon_path.is_empty() or not FileAccess.file_exists(icon_path):
			return "Choose an existing PNG or SVG icon."
		if icon_path.get_extension().to_lower() not in ["png", "svg"]:
			return "The AppImage icon must be a PNG or SVG file."
	return ""


func _export_begin(
	_features: PackedStringArray,
	_is_debug: bool,
	path: String,
	_flags: int
) -> void:
	_executable_path = path


func _export_end() -> void:
	if not _supports_platform(get_export_platform()):
		_executable_path = ""
		return
	if not bool(get_option("appimage/generate_an_appimage")):
		_executable_path = ""
		return
	if _executable_path.ends_with(".pck"):
		_executable_path = ""
		return

	var result := _build_appimage()
	if bool(result.success):
		get_export_platform().add_message(
			EditorExportPlatform.EXPORT_MESSAGE_INFO,
			CATEGORY,
			"Created %s" % str(result.output_path)
		)
	else:
		get_export_platform().add_message(
			EditorExportPlatform.EXPORT_MESSAGE_ERROR,
			CATEGORY,
			str(result.error)
		)
	_executable_path = ""


func _build_appimage() -> Dictionary:
	if _executable_path.is_empty() or not FileAccess.file_exists(_executable_path):
		return _failure("The exported Linux executable was not found.")

	var app_name := str(get_option("appimage/app_name")).strip_edges()
	if app_name.is_empty():
		return _failure("An AppImage application name is required.")

	var icon_path := _resolve_file_path(str(get_option("appimage/icon")))
	if icon_path.is_empty() or not FileAccess.file_exists(icon_path):
		return _failure("The configured AppImage icon does not exist.")
	var icon_extension := icon_path.get_extension().to_lower()
	if icon_extension not in ["png", "svg"]:
		return _failure("The AppImage icon must be a PNG or SVG file.")

	var appimagetool_path := _find_appimagetool(
		str(ProjectSettings.get_setting(APPIMAGETOOL_PATH_SETTING, ""))
	)
	if appimagetool_path.is_empty():
		return _failure(
			"appimagetool was not found. Select it in Project Settings > "
			+ "AppImage Export > Appimagetool Path, or add it to PATH."
		)

	var temp_dir_handle := DirAccess.create_temp("godot-appimage-", true)
	if temp_dir_handle == null:
		return _failure("Could not create a temporary AppDir.")
	var appdir_path := temp_dir_handle.get_current_dir()
	# Close the directory handle so the staging directory itself can be removed.
	temp_dir_handle = null
	var output_path := _executable_path.get_basename() + ".AppImage"
	var setup_result := _populate_appdir(
		appdir_path,
		app_name,
		str(get_option("appimage/app_description")),
		icon_path,
		icon_extension
	)
	if not bool(setup_result.success):
		_remove_directory_recursive(appdir_path)
		return setup_result

	if FileAccess.file_exists(output_path):
		var remove_error := DirAccess.remove_absolute(output_path)
		if remove_error != OK:
			_remove_directory_recursive(appdir_path)
			return _failure(
				"Could not replace %s: %s"
				% [output_path, error_string(remove_error)]
			)

	var tool_output: Array = []
	var exit_code := OS.execute(
		appimagetool_path,
		[appdir_path, output_path],
		tool_output,
		true,
		true
	)
	_remove_directory_recursive(appdir_path)
	if exit_code != 0 or not FileAccess.file_exists(output_path):
		var details := "\n".join(PackedStringArray(tool_output)).strip_edges()
		if details.is_empty():
			details = "appimagetool exited with code %d." % exit_code
		return _failure("Could not create the AppImage:\n%s" % details)

	var permission_error := FileAccess.set_unix_permissions(
		output_path,
		EXECUTABLE_PERMISSIONS
	)
	if permission_error != OK:
		return _failure(
			"The AppImage was created, but it could not be made executable: %s"
			% error_string(permission_error)
		)
	return {
		"success": true,
		"output_path": output_path,
	}


func _populate_appdir(
	appdir_path: String,
	app_name: String,
	app_description: String,
	icon_path: String,
	icon_extension: String
) -> Dictionary:
	var bin_dir := appdir_path.path_join("usr/bin")
	var mkdir_error := DirAccess.make_dir_recursive_absolute(bin_dir)
	if mkdir_error != OK:
		return _failure(
			"Could not create the AppDir: %s" % error_string(mkdir_error)
		)

	var executable_name := _executable_path.get_file()
	var bundled_executable := bin_dir.path_join(executable_name)
	var copy_error := DirAccess.copy_absolute(
		_executable_path,
		bundled_executable
	)
	if copy_error != OK:
		return _failure(
			"Could not copy the Linux executable into the AppDir: %s"
			% error_string(copy_error)
		)
	var permission_error := FileAccess.set_unix_permissions(
		bundled_executable,
		EXECUTABLE_PERMISSIONS
	)
	if permission_error != OK:
		return _failure(
			"Could not make the bundled executable runnable: %s"
			% error_string(permission_error)
		)

	if not bool(get_option("binary_format/embed_pck")):
		var pck_path := _executable_path.get_basename() + ".pck"
		if not FileAccess.file_exists(pck_path):
			return _failure("The separate export PCK was not found: %s" % pck_path)
		copy_error = DirAccess.copy_absolute(
			pck_path,
			bin_dir.path_join(pck_path.get_file())
		)
		if copy_error != OK:
			return _failure(
				"Could not copy the export PCK into the AppDir: %s"
				% error_string(copy_error)
			)

	var app_id := _safe_app_id(_executable_path.get_file().get_basename())
	var copied_icon := "%s.%s" % [app_id, icon_extension]
	copy_error = DirAccess.copy_absolute(
		icon_path,
		appdir_path.path_join(copied_icon)
	)
	if copy_error != OK:
		return _failure(
			"Could not copy the AppImage icon: %s" % error_string(copy_error)
		)
	copy_error = DirAccess.copy_absolute(
		icon_path,
		appdir_path.path_join(".DirIcon")
	)
	if copy_error != OK:
		return _failure(
			"Could not create .DirIcon: %s" % error_string(copy_error)
		)

	var desktop_lines := PackedStringArray([
		"[Desktop Entry]",
		"Type=Application",
		"Name=%s" % _desktop_value(app_name),
		"Comment=%s" % _desktop_value(app_description),
		"Icon=%s" % app_id,
		"Exec=%s" % _desktop_exec_value(executable_name),
		"Terminal=false",
		"Categories=Development;Utility;",
		"",
	])
	var write_error := _write_text_file(
		appdir_path.path_join(app_id + ".desktop"),
		"\n".join(desktop_lines)
	)
	if write_error != OK:
		return _failure(
			"Could not create the desktop file: %s" % error_string(write_error)
		)

	var app_run_path := appdir_path.path_join("AppRun")
	write_error = _write_text_file(
		app_run_path,
		"#!/bin/sh\n"
		+ "HERE=\"${APPDIR:-$(dirname \"$(readlink -f \"$0\")\")}\"\n"
		+ "exec \"${HERE}/usr/bin/%s\" \"$@\"\n" % executable_name
	)
	if write_error != OK:
		return _failure(
			"Could not create AppRun: %s" % error_string(write_error)
		)
	permission_error = FileAccess.set_unix_permissions(
		app_run_path,
		EXECUTABLE_PERMISSIONS
	)
	if permission_error != OK:
		return _failure(
			"Could not make AppRun executable: %s"
			% error_string(permission_error)
		)
	return {"success": true}


func _find_appimagetool(configured_path: String) -> String:
	var configured := _resolve_file_path(configured_path)
	if not configured.is_empty():
		if _is_executable_file(configured):
			return configured
		return ""

	var search_directories := PackedStringArray()
	for directory in OS.get_environment("PATH").split(":", false):
		search_directories.append(directory)
	var user_home := OS.get_environment("HOME")
	if not user_home.is_empty():
		search_directories.append(user_home.path_join(".local/bin"))
		search_directories.append(user_home.path_join("Applications"))
		search_directories.append(user_home.path_join("AppImages"))
	search_directories.append("/usr/local/bin")
	search_directories.append("/usr/bin")

	for directory in search_directories:
		for tool_name in TOOL_NAMES:
			var candidate := directory.path_join(tool_name)
			if _is_executable_file(candidate):
				return candidate
	return ""


func _appimagetool_warning() -> String:
	var configured_path := str(
		ProjectSettings.get_setting(APPIMAGETOOL_PATH_SETTING, "")
	)
	var resolved_path := _resolve_file_path(configured_path)
	if (
		not resolved_path.is_empty()
		and FileAccess.file_exists(resolved_path)
		and not _is_executable_file(resolved_path)
	):
		return "The selected appimagetool file is not executable (run chmod +x)."
	if _find_appimagetool(configured_path).is_empty():
		return (
			"appimagetool was not found. Select it in Project Settings > "
			+ "AppImage Export > Appimagetool Path, add it to PATH, or install "
			+ "it in ~/.local/bin, ~/Applications, or ~/AppImages."
		)
	return ""


func _is_executable_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	return (FileAccess.get_unix_permissions(path) & EXECUTE_PERMISSION_MASK) != 0


func _resolve_file_path(path: String) -> String:
	var resolved := path.strip_edges()
	if resolved.begins_with("uid://"):
		var resource_id := ResourceUID.text_to_id(resolved)
		resolved = ResourceUID.get_id_path(resource_id)
	if resolved.begins_with("res://") or resolved.begins_with("user://"):
		return ProjectSettings.globalize_path(resolved)
	return resolved


func _safe_app_id(value: String) -> String:
	var safe := ""
	for character in value.to_lower():
		if character.is_valid_identifier() or character == "-":
			safe += character
		else:
			safe += "-"
	while "--" in safe:
		safe = safe.replace("--", "-")
	safe = safe.trim_prefix("-").trim_suffix("-")
	return safe if not safe.is_empty() else "application"


func _desktop_value(value: String) -> String:
	return value.replace("\r", " ").replace("\n", " ").strip_edges()


func _desktop_exec_value(value: String) -> String:
	return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')


func _write_text_file(path: String, contents: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(contents)
	return file.get_error()


func _remove_directory_recursive(path: String) -> Error:
	var directory := DirAccess.open(path)
	if directory == null:
		return DirAccess.get_open_error()
	directory.include_hidden = true
	var list_error := directory.list_dir_begin()
	if list_error != OK:
		return list_error
	var entry := directory.get_next()
	while not entry.is_empty():
		var entry_path := path.path_join(entry)
		if directory.current_is_dir() and not directory.is_link(entry):
			var remove_error := _remove_directory_recursive(entry_path)
			if remove_error != OK:
				directory.list_dir_end()
				return remove_error
		else:
			var remove_error := DirAccess.remove_absolute(entry_path)
			if remove_error != OK:
				directory.list_dir_end()
				return remove_error
		entry = directory.get_next()
	directory.list_dir_end()
	return DirAccess.remove_absolute(path)


func _failure(message: String) -> Dictionary:
	return {
		"success": false,
		"error": message,
	}
