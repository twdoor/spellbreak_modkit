@tool
extends EditorPlugin

const AUTOLOAD_NAME := "AppSettings"
const AUTOLOAD_PATH := "res://addons/app_settings/app_settings_runtime.gd"
const DIRECTORY_NAME_SETTING := "app_settings/directory_name"
const OVERRIDE_ENVIRONMENT_VARIABLE_SETTING := (
	"app_settings/override_environment_variable"
)


func _enable_plugin() -> void:
	_register_project_settings()
	_ensure_autoload()


func _disable_plugin() -> void:
	var autoload_setting := "autoload/%s" % AUTOLOAD_NAME
	if not ProjectSettings.has_setting(autoload_setting):
		return

	var configured_path := str(ProjectSettings.get_setting(autoload_setting))
	if _autoload_points_to_runtime(configured_path):
		remove_autoload_singleton(AUTOLOAD_NAME)


func _enter_tree() -> void:
	_register_project_settings()
	_ensure_autoload()


func _register_project_settings() -> void:
	var directory_name := _default_directory_name()
	if not ProjectSettings.has_setting(DIRECTORY_NAME_SETTING):
		ProjectSettings.set_setting(DIRECTORY_NAME_SETTING, directory_name)
	ProjectSettings.set_initial_value(DIRECTORY_NAME_SETTING, directory_name)
	ProjectSettings.add_property_info({
		"name": DIRECTORY_NAME_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": directory_name,
	})

	var environment_variable := _environment_variable_for(directory_name)
	if not ProjectSettings.has_setting(OVERRIDE_ENVIRONMENT_VARIABLE_SETTING):
		ProjectSettings.set_setting(
			OVERRIDE_ENVIRONMENT_VARIABLE_SETTING,
			environment_variable
		)
	ProjectSettings.set_initial_value(
		OVERRIDE_ENVIRONMENT_VARIABLE_SETTING,
		environment_variable
	)
	ProjectSettings.add_property_info({
		"name": OVERRIDE_ENVIRONMENT_VARIABLE_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": environment_variable,
	})

	ProjectSettings.save()


func _ensure_autoload() -> void:
	var autoload_setting := "autoload/%s" % AUTOLOAD_NAME
	if ProjectSettings.has_setting(autoload_setting):
		var configured_path := str(ProjectSettings.get_setting(autoload_setting))
		if not _autoload_points_to_runtime(configured_path):
			push_warning(
				"App Settings could not register its autoload because '%s' is already in use."
				% AUTOLOAD_NAME
			)
		return

	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _autoload_points_to_runtime(configured_value: String) -> bool:
	var configured_path := configured_value.trim_prefix("*")
	if configured_path == AUTOLOAD_PATH:
		return true
	if configured_path.begins_with("uid://"):
		var resource_id := ResourceUID.text_to_id(configured_path)
		return ResourceUID.get_id_path(resource_id) == AUTOLOAD_PATH
	return false


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


func _environment_variable_for(directory_name: String) -> String:
	var expression := RegEx.new()
	expression.compile("[^A-Z0-9]+")
	var prefix := expression.sub(
		directory_name.to_upper(),
		"_",
		true
	).trim_prefix("_").trim_suffix("_")
	return "%s_CONFIG_DIR" % (prefix if not prefix.is_empty() else "APPLICATION")
