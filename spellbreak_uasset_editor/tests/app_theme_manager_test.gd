extends SceneTree

class ThemeProbe:
	extends Label
	var theme_change_count := 0

	func _notification(what: int) -> void:
		if what == NOTIFICATION_THEME_CHANGED:
			theme_change_count += 1


var _test_directory := OS.get_temp_dir().path_join(
	"app-theme-test-%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
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

	# Script tests start after autoloads, so point the services at an isolated directory.
	var settings := get_root().get_node("AppSettings")
	settings.config_directory_path = _test_directory
	settings.settings_file_path = _test_directory.path_join("settings.cfg")
	settings.ensure_config_directory()
	var manager := get_root().get_node("AppThemeManager")
	manager.colors_file_path = settings.get_file_path(manager.COLORS_FILE_NAME)
	manager.theme_file_path = settings.get_file_path(manager.THEME_FILE_NAME)
	manager._current_colors = manager._read_app_colors()
	manager._current_metrics = manager._read_app_metrics()
	# Legacy expanded files are migrated to the compact schema on reload.
	_write_json(manager.colors_file_path, manager._serialize_colors(manager._current_colors))
	_write_json(manager.theme_file_path, manager._current_metrics)
	assert(manager.reload() == OK)
	assert(FileAccess.file_exists(manager.colors_file_path))
	assert(FileAccess.file_exists(manager.theme_file_path))
	var migrated_colors: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(manager.colors_file_path))
	var migrated_theme: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(manager.theme_file_path))
	assert(migrated_colors.size() == 12)
	assert(migrated_theme.size() == 10)
	assert(migrated_colors.has("canvas"))
	assert(migrated_colors.has("bars_and_popups"))
	assert(migrated_theme.has("body_text"))
	var main_scene: Node = load("res://app/main.tscn").instantiate()
	get_root().add_child(main_scene)
	await process_frame
	var file_dialog := FileDialog.new()
	AppTheme.apply_theme(file_dialog)
	file_dialog.use_native_dialog = false
	file_dialog.exclusive = false
	get_root().add_child(file_dialog)
	file_dialog.popup(Rect2i(0, 0, 800, 600))
	await process_frame
	var file_lists := file_dialog.get_vbox().find_children("*", "ItemList", true, false)
	assert(not file_lists.is_empty())
	var file_list := file_lists[0] as ItemList
	var tab_container := main_scene.find_child("TabCont", true, false) as TabContainer
	var edit_theme_button := main_scene.find_child("EditThemeButton", true, false) as Button
	var theme_tab := main_scene.find_child("ThemeSettingsTab", true, false) as ThemeSettingsTab
	assert(tab_container != null)
	assert(edit_theme_button != null)
	assert(theme_tab != null)
	edit_theme_button.pressed.emit()
	await process_frame
	var theme_tab_index := tab_container.get_tab_idx_from_control(theme_tab)
	assert(theme_tab_index >= 0)
	assert(not tab_container.is_tab_hidden(theme_tab_index))
	assert(tab_container.current_tab == theme_tab_index)
	var color_pickers := theme_tab.find_children("*", "ColorPickerButton", true, false)
	var metric_inputs := theme_tab.find_children("*", "SpinBox", true, false)
	assert(color_pickers.size() == 12)
	assert(metric_inputs.size() == 10)
	var primary_picker: ColorPickerButton
	var success_picker: ColorPickerButton
	var chrome_picker: ColorPickerButton
	var body_text_input: SpinBox
	for candidate: Node in color_pickers:
		var picker := candidate as ColorPickerButton
		if picker.tooltip_text.begins_with("canvas"):
			primary_picker = picker
		elif picker.tooltip_text.begins_with("success"):
			success_picker = picker
		elif picker.tooltip_text.begins_with("bars_and_popups"):
			chrome_picker = picker
	assert(primary_picker != null)
	assert(success_picker != null)
	assert(chrome_picker != null)
	for candidate: Node in metric_inputs:
		var input := candidate as SpinBox
		if input.tooltip_text == "body_text":
			body_text_input = input
			break
	assert(body_text_input != null)
	var original_primary := AppTheme.BG_PRIMARY
	var original_success := AppTheme.STATUS_SUCCESS
	var original_chrome := AppTheme.BG_CHROME
	var original_body_size := AppTheme.FONT_DEFAULT
	primary_picker.color = Color("#654321ff")
	primary_picker.color_changed.emit(primary_picker.color)
	success_picker.color = Color("#22aa44ff")
	success_picker.color_changed.emit(success_picker.color)
	chrome_picker.color = Color("#445566ff")
	chrome_picker.color_changed.emit(chrome_picker.color)
	body_text_input.value = 16
	body_text_input.value_changed.emit(body_text_input.value)
	await create_timer(0.15).timeout
	assert(AppTheme.BG_PRIMARY.is_equal_approx(Color("#654321ff")))
	assert(AppTheme.STATUS_SUCCESS.is_equal_approx(Color("#22aa44ff")))
	assert(AppTheme.MOD_ENABLED.is_equal_approx(Color("#22aa44ff")))
	assert(AppTheme.BTN_SAVE.is_equal_approx(Color("#22aa44ff")))
	assert(AppTheme.BG_CHROME.is_equal_approx(Color("#445566ff")))
	var status_bar := main_scene.find_child("StatusBar", true, false) as PanelContainer
	assert(status_bar.get_theme_stylebox("panel").bg_color.is_equal_approx(Color("#445566ff")))
	var tab_bar := tab_container.get_tab_bar()
	var tab_background := tab_bar.get_node("ChromeBackground") as Panel
	assert(tab_background.get_theme_stylebox("panel").bg_color.is_equal_approx(Color("#445566ff")))
	var close_dialog := main_scene.find_child("CloseDialog", true, false) as Window
	assert(close_dialog.transparent_bg)
	close_dialog.popup_centered()
	await process_frame
	var internal_dialog_panel: Panel = null
	for child in close_dialog.get_children(true):
		var panel := child as Panel
		if panel != null and panel.name != "_AppThemeChromeBackground":
			internal_dialog_panel = panel
			break
	assert(internal_dialog_panel != null)
	assert(internal_dialog_panel.get_theme_stylebox("panel").bg_color.is_equal_approx(
		Color("#445566ff")))
	var dialog_background := close_dialog.get_node("_AppThemeChromeBackground") as Panel
	assert(dialog_background.get_theme_stylebox("panel").bg_color.is_equal_approx(Color("#445566ff")))
	assert(AppTheme._theme.get_stylebox("panel", "PopupPanel").bg_color.is_equal_approx(Color("#445566ff")))
	assert(AppTheme._theme.get_stylebox("tab_selected", "TabContainer").bg_color.is_equal_approx(Color("#445566ff")))
	assert(AppTheme._theme.get_color("font_selected_color", "TabContainer").is_equal_approx(
		AppTheme.TEXT_PRIMARY.lightened(0.12)))
	assert(manager.preview_values({
		"surface": Color("#345678ff"),
		"primary_text": Color("#fedcbaff"),
		"links": Color("#ab3456ff"),
	}, {}) == OK)
	await process_frame
	assert(file_dialog.get_theme_color("folder_icon_color", "FileDialog").is_equal_approx(AppTheme.BTN_NAV))
	assert(file_list.get_theme_color("font_color").is_equal_approx(AppTheme.TEXT_PRIMARY))
	assert(file_list.get_theme_stylebox("panel").bg_color.is_equal_approx(AppTheme.BG_FIELD))
	assert(file_dialog.get_theme_stylebox("panel", "TooltipPanel").bg_color.is_equal_approx(AppTheme.BG_CHROME))
	file_dialog.queue_free()
	assert(AppTheme.FONT_DEFAULT == 16)
	assert(AppTheme.FONT_TOAST == 17)
	assert(AppTheme.FONT_REF == 17)
	theme_tab._on_close_pressed()
	await process_frame
	assert(AppTheme.BG_PRIMARY.is_equal_approx(original_primary))
	assert(AppTheme.STATUS_SUCCESS.is_equal_approx(original_success))
	assert(AppTheme.BG_CHROME.is_equal_approx(original_chrome))
	assert(AppTheme.FONT_DEFAULT == original_body_size)
	assert(tab_container.is_tab_hidden(theme_tab_index))
	var saved_colors: Dictionary = manager.get_color_values()
	var saved_metrics: Dictionary = manager.get_metric_values()
	saved_colors.canvas = Color("#334455ff")
	assert(manager.save_values(saved_colors, saved_metrics) == OK)
	var saved_json: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(manager.colors_file_path))
	assert(saved_json.canvas == "#334455ff")
	assert(saved_json.size() == 12)
	saved_colors.canvas = original_primary
	assert(manager.save_values(saved_colors, saved_metrics) == OK)
	var mod_tree := main_scene.find_child("ModTree", true, false) as Tree
	assert(mod_tree != null)
	var placeholder_item := mod_tree.get_root().get_first_child()
	assert(placeholder_item != null)
	assert(placeholder_item.get_custom_color(0).is_equal_approx(AppTheme.MOD_PLACEHOLDER))
	var live_label := ThemeProbe.new()
	live_label.add_theme_color_override("font_color", AppTheme.BG_PRIMARY)
	live_label.add_theme_font_size_override("font_size", AppTheme.FONT_HEADER)
	get_root().add_child(live_label)
	live_label.theme_change_count = 0

	var colors: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manager.colors_file_path))
	colors.canvas = "#123456ff"
	colors.secondary_text = "#abcdefFF"
	_write_json(manager.colors_file_path, colors)
	var theme: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manager.theme_file_path))
	theme.title_text = 19
	_write_json(manager.theme_file_path, theme)

	await create_timer(0.8).timeout
	assert(AppTheme.BG_PRIMARY.is_equal_approx(Color("#123456ff")))
	assert(AppTheme.FONT_HEADER == 19)
	assert(placeholder_item.get_custom_color(0).is_equal_approx(Color("#abcdefff")))
	assert(live_label.get_theme_color("font_color").is_equal_approx(Color("#123456ff")))
	assert(live_label.get_theme_font_size("font_size") == 19)
	# A reload is batched: controls should not receive an event for every
	# property in the shared Theme resource.
	assert(live_label.theme_change_count <= 4)

	_cleanup()
	OS.set_environment(override_variable, previous_override)
	quit(0)


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(JSON.stringify(value, "  ") + "\n")


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(_test_directory):
		return
	for file_name: String in DirAccess.get_files_at(_test_directory):
		DirAccess.remove_absolute(_test_directory.path_join(file_name))
	DirAccess.remove_absolute(_test_directory)
