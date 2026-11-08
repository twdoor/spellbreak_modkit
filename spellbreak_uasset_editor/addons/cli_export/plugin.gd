@tool
extends EditorPlugin

const LauncherExport = preload("res://addons/cli_export/launcher_export.gd")
var _exporter: EditorExportPlugin

func _enter_tree() -> void:
	_exporter = LauncherExport.new()
	add_export_plugin(_exporter)

func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null
