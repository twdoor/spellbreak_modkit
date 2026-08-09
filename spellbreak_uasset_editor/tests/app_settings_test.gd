extends SceneTree

const AppSettingsRuntime = preload(
	"res://addons/app_settings/app_settings_runtime.gd"
)

var _test_directory := OS.get_temp_dir().path_join(
	"app-settings-test-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var override_variable := str(ProjectSettings.get_setting(
		"app_settings/override_environment_variable",
		"SPELLBREAK_MODKIT_CONFIG_DIR"
	))
	var previous_override := OS.get_environment(override_variable)
	OS.set_environment(override_variable, _test_directory)

	var settings := AppSettingsRuntime.new()
	assert(settings.config_directory_path == _test_directory)
	assert(
		settings.settings_file_path
		== _test_directory.path_join("settings.cfg")
	)
	assert(settings.get_value("window", "maximized", false) == false)

	assert(settings.set_value("window", "maximized", true, false) == OK)
	assert(not FileAccess.file_exists(settings.settings_file_path))
	assert(settings.save() == OK)
	assert(FileAccess.file_exists(settings.settings_file_path))

	var reloaded := AppSettingsRuntime.new()
	assert(reloaded.get_value("window", "maximized", false) == true)
	assert(reloaded.erase_value("window", "maximized") == OK)
	assert(not reloaded.has_value("window", "maximized"))
	assert(FileAccess.file_exists(reloaded.settings_file_path + ".bak"))

	settings.free()
	reloaded.free()
	_cleanup()
	OS.set_environment(override_variable, previous_override)
	quit(0)


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(_test_directory):
		return
	for file_name: String in DirAccess.get_files_at(_test_directory):
		DirAccess.remove_absolute(_test_directory.path_join(file_name))
	DirAccess.remove_absolute(_test_directory)
