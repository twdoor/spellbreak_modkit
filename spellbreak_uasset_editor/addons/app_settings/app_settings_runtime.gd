extends Node

## Stores application preferences in the operating system's standard per-user
## configuration directory.
##
## Values are saved to settings.cfg automatically:
##     AppSettings.set_value("window", "maximized", true)
##     var maximized := AppSettings.get_value("window", "maximized", false)
##
## Pass false as the fourth set_value argument to batch several changes, then
## call save once. get_file_path can be used for additional app-owned files.

signal value_changed(section: String, key: String, value: Variant)
signal settings_reloaded
signal settings_saved(path: String)

const DIRECTORY_NAME_SETTING := "app_settings/directory_name"
const OVERRIDE_ENVIRONMENT_VARIABLE_SETTING := (
	"app_settings/override_environment_variable"
)
const SETTINGS_FILE_NAME := "settings.cfg"

var config_directory_path := ""
var settings_file_path := ""
var last_error := ""

var _config := ConfigFile.new()


func _init() -> void:
	_refresh_paths()
	reload()


## Returns a stored value, or default when the section/key does not exist.
func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _config.get_value(section, key, default)


## Stores a value. By default the settings file is updated immediately.
func set_value(
	section: String,
	key: String,
	value: Variant,
	save_immediately := true
) -> Error:
	_config.set_value(section, key, value)
	value_changed.emit(section, key, value)
	return save() if save_immediately else OK


func has_value(section: String, key: String) -> bool:
	return _config.has_section_key(section, key)


## Removes one value. Missing values are treated as a successful no-op.
func erase_value(section: String, key: String, save_immediately := true) -> Error:
	if not _config.has_section_key(section, key):
		return OK
	_config.erase_section_key(section, key)
	value_changed.emit(section, key, null)
	return save() if save_immediately else OK


## Removes a complete section. Missing sections are a successful no-op.
func erase_section(section: String, save_immediately := true) -> Error:
	if not _config.has_section(section):
		return OK
	var keys := _config.get_section_keys(section)
	_config.erase_section(section)
	for key in keys:
		value_changed.emit(section, key, null)
	return save() if save_immediately else OK


func get_sections() -> PackedStringArray:
	return _config.get_sections()


func get_section_keys(section: String) -> PackedStringArray:
	return _config.get_section_keys(section)


## Loads settings from disk. A missing settings file is not an error.
## Backup and temporary files are checked if the main file cannot be read.
func reload() -> Error:
	last_error = ""
	var candidates := PackedStringArray([
		settings_file_path,
		settings_file_path + ".bak",
		settings_file_path + ".tmp",
	])
	var found_file := false
	var first_error := OK

	for path in candidates:
		if not FileAccess.file_exists(path):
			continue
		found_file = true
		var loaded_config := ConfigFile.new()
		var error := loaded_config.load(path)
		if error == OK:
			_config = loaded_config
			settings_reloaded.emit()
			return OK
		if first_error == OK:
			first_error = error

	if not found_file:
		_config = ConfigFile.new()
		settings_reloaded.emit()
		return OK

	last_error = "Could not read application settings from %s (error %d)." % [
		settings_file_path,
		first_error,
	]
	push_error(last_error)
	return first_error


## Atomically writes the current settings. The previous file is kept as .bak.
func save() -> Error:
	last_error = ""
	var error := ensure_config_directory()
	if error != OK:
		return error

	var temporary_path := settings_file_path + ".tmp"
	var backup_path := settings_file_path + ".bak"
	if FileAccess.file_exists(temporary_path):
		error = DirAccess.remove_absolute(temporary_path)
		if error != OK:
			return _finish_with_error(
				"Could not replace the temporary settings file.",
				error
			)

	error = _config.save(temporary_path)
	if error != OK:
		return _finish_with_error("Could not write application settings.", error)

	if FileAccess.file_exists(backup_path):
		error = DirAccess.remove_absolute(backup_path)
		if error != OK:
			DirAccess.remove_absolute(temporary_path)
			return _finish_with_error(
				"Could not replace the settings backup.",
				error
			)

	var had_previous_file := FileAccess.file_exists(settings_file_path)
	if had_previous_file:
		error = DirAccess.rename_absolute(settings_file_path, backup_path)
		if error != OK:
			DirAccess.remove_absolute(temporary_path)
			return _finish_with_error(
				"Could not back up the previous settings file.",
				error
			)

	error = DirAccess.rename_absolute(temporary_path, settings_file_path)
	if error != OK:
		if had_previous_file:
			DirAccess.rename_absolute(backup_path, settings_file_path)
		DirAccess.remove_absolute(temporary_path)
		return _finish_with_error("Could not install the new settings file.", error)

	settings_saved.emit(settings_file_path)
	return OK


## Ensures the app's configuration directory exists and returns the result.
func ensure_config_directory() -> Error:
	var error := DirAccess.make_dir_recursive_absolute(config_directory_path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		return _finish_with_error(
			"Could not create the configuration directory: %s" % config_directory_path,
			error
		)
	return OK


## Returns a path inside the app's configuration directory.
func get_file_path(file_name: String) -> String:
	return config_directory_path.path_join(file_name)


func open_config_directory() -> Error:
	var error := ensure_config_directory()
	if error == OK:
		OS.shell_show_in_file_manager(config_directory_path, true)
	return error


func _refresh_paths() -> void:
	config_directory_path = _resolve_config_directory()
	settings_file_path = config_directory_path.path_join(SETTINGS_FILE_NAME)


func _resolve_config_directory() -> String:
	var override_variable := str(ProjectSettings.get_setting(
		OVERRIDE_ENVIRONMENT_VARIABLE_SETTING,
		_default_override_environment_variable()
	)).strip_edges()
	if not override_variable.is_empty():
		var override_path := OS.get_environment(override_variable).strip_edges()
		if not override_path.is_empty():
			return override_path

	var base_path := ""
	match OS.get_name():
		"Windows":
			base_path = OS.get_environment("APPDATA")
			if base_path.is_empty():
				base_path = OS.get_environment("LOCALAPPDATA")
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			base_path = OS.get_environment("XDG_CONFIG_HOME")
			if base_path.is_empty():
				var user_home := OS.get_environment("HOME")
				if not user_home.is_empty():
					base_path = user_home.path_join(".config")
		"macOS":
			var user_home := OS.get_environment("HOME")
			if not user_home.is_empty():
				base_path = user_home.path_join("Library/Application Support")

	var directory_name := _configured_directory_name()
	if base_path.is_empty():
		return ProjectSettings.globalize_path("user://").path_join(directory_name)
	return base_path.path_join(directory_name)


func _configured_directory_name() -> String:
	var directory_name := str(ProjectSettings.get_setting(
		DIRECTORY_NAME_SETTING,
		_default_directory_name()
	)).strip_edges()
	return directory_name if not directory_name.is_empty() else _default_directory_name()


func _default_override_environment_variable() -> String:
	var expression := RegEx.new()
	expression.compile("[^A-Z0-9]+")
	var prefix := expression.sub(
		_configured_directory_name().to_upper(),
		"_",
		true
	).trim_prefix("_").trim_suffix("_")
	return "%s_CONFIG_DIR" % (prefix if not prefix.is_empty() else "APPLICATION")


func _default_directory_name() -> String:
	var application_name := str(
		ProjectSettings.get_setting("application/config/name", "application")
	).strip_edges()
	var expression := RegEx.new()
	expression.compile("[^a-z0-9]+")
	var slug := expression.sub(
		application_name.to_lower(),
		"-",
		true
	).trim_prefix("-").trim_suffix("-")
	return slug if not slug.is_empty() else "application"


func _finish_with_error(message: String, error: Error) -> Error:
	last_error = "%s (error %d)" % [message, error]
	push_error(last_error)
	return error
