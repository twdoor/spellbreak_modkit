@tool
extends EditorPlugin

const AUTOLOAD_NAME := "VersionManager"
const AUTOLOAD_PATH := "res://addons/version_manager/version_manager_runtime.gd"
const LEGACY_APP_REPO_URL_SETTING := "version_manager/app_repo_url"
const USE_PRE_RELEASE_SETTING := "version_manager/use_pre_release"
const CHANGELOG_PATH_SETTING := "version_manager/changelog_path"
const BUILDS_PATH_SETTING := "version_manager/builds_path"
const EXPORT_BASENAME_SETTING := "version_manager/export_basename"
const PREPARE_RELEASE_MENU_ITEM := "Prepare Release"
const PREPARE_RELEASE_PANEL := preload(
	"res://addons/version_manager/prepare_release_panel.tscn"
)
const VERSION_MANAGER_EXPORT_PLUGIN := preload(
	"res://addons/version_manager/version_manager_export_plugin.gd"
)

var _prepare_release_dialog: Window
var _export_plugin: EditorExportPlugin

func _enable_plugin() -> void:
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
	_export_plugin = VERSION_MANAGER_EXPORT_PLUGIN.new()
	add_export_plugin(_export_plugin)
	_add_prepare_release_menu_item()


func _exit_tree() -> void:
	remove_tool_menu_item(PREPARE_RELEASE_MENU_ITEM)

	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	if _prepare_release_dialog != null:
		_prepare_release_dialog.shutdown()
		_prepare_release_dialog.queue_free()
		_prepare_release_dialog = null


func _register_project_settings() -> void:
	# Repository information comes from this project's Git checkout. Remove the
	# old manually configured URL when upgrading an existing project.
	if ProjectSettings.has_setting(LEGACY_APP_REPO_URL_SETTING):
		ProjectSettings.set_setting(LEGACY_APP_REPO_URL_SETTING, null)

	if not ProjectSettings.has_setting(USE_PRE_RELEASE_SETTING):
		ProjectSettings.set_setting(USE_PRE_RELEASE_SETTING, false)
	ProjectSettings.set_initial_value(USE_PRE_RELEASE_SETTING, false)
	ProjectSettings.add_property_info({
		"name": USE_PRE_RELEASE_SETTING,
		"type": TYPE_BOOL,
	})
	_register_string_setting(CHANGELOG_PATH_SETTING, "res://changelog.md")
	_register_string_setting(BUILDS_PATH_SETTING, "res://builds")
	_register_string_setting(EXPORT_BASENAME_SETTING, "")

	ProjectSettings.save()


func _register_string_setting(setting_name: String, default_value: String) -> void:
	if not ProjectSettings.has_setting(setting_name):
		ProjectSettings.set_setting(setting_name, default_value)
	ProjectSettings.set_initial_value(setting_name, default_value)
	ProjectSettings.add_property_info({
		"name": setting_name,
		"type": TYPE_STRING,
	})


func _ensure_autoload() -> void:
	var autoload_setting := "autoload/%s" % AUTOLOAD_NAME
	if ProjectSettings.has_setting(autoload_setting):
		var configured_path := str(ProjectSettings.get_setting(autoload_setting))
		if not _autoload_points_to_runtime(configured_path):
			push_warning(
				"Version Manager could not register its autoload because '%s' is already in use."
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


func _add_prepare_release_menu_item() -> void:
	_prepare_release_dialog = PREPARE_RELEASE_PANEL.instantiate() as Window
	_prepare_release_dialog.visible = false
	get_editor_interface().get_base_control().add_child(_prepare_release_dialog)
	_prepare_release_dialog.apply_editor_theme(
		get_editor_interface().get_editor_theme()
	)

	add_tool_menu_item(
		PREPARE_RELEASE_MENU_ITEM,
		_prepare_release_dialog.open_dialog
	)
