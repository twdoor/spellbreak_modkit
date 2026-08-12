@tool
extends EditorPlugin

const APPIMAGE_EXPORT_PLUGIN := preload(
	"res://addons/appimage_export/appimage_export_plugin.gd"
)
const APPIMAGETOOL_PATH_SETTING := "appimage_export/appimagetool_path"

var _appimage_export_plugin: EditorExportPlugin


func _enable_plugin() -> void:
	_register_project_settings()


func _enter_tree() -> void:
	_register_project_settings()
	_appimage_export_plugin = APPIMAGE_EXPORT_PLUGIN.new()
	add_export_plugin(_appimage_export_plugin)


func _exit_tree() -> void:
	if _appimage_export_plugin == null:
		return
	remove_export_plugin(_appimage_export_plugin)
	_appimage_export_plugin = null


func _register_project_settings() -> void:
	if not ProjectSettings.has_setting(APPIMAGETOOL_PATH_SETTING):
		ProjectSettings.set_setting(APPIMAGETOOL_PATH_SETTING, "")
	ProjectSettings.set_initial_value(APPIMAGETOOL_PATH_SETTING, "")
	ProjectSettings.add_property_info({
		"name": APPIMAGETOOL_PATH_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*",
	})
	ProjectSettings.save()
