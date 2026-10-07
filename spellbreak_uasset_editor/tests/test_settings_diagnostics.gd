extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(936, 1014)
	var config := ModConfigManager.new()
	# Only edit this in-memory config; never save or migrate a user's override.
	config.umodel_path = ""
	var settings := preload("res://features/mod_manager/ui/mod_settings_tab.tscn").instantiate() as ModSettingsTab
	settings.setup(config)
	root.add_child(settings)
	settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	assert(not settings.get_node("%AdvancedContent").visible)
	assert(not settings._is_dirty())
	settings._umodel_edit.text = "/custom/umodel"
	settings._on_umodel_path_changed("/custom/umodel")
	assert(settings._is_dirty())
	assert("Custom mesh exporter" in settings.get_node("%AdvancedToggle").text)
	settings._on_use_bundled_pressed()
	assert(config.umodel_path.is_empty())
	assert(settings._umodel_edit.text.is_empty())
	assert(not settings._is_dirty())
	settings.get_node("%AdvancedToggle").button_pressed = true
	assert(settings.get_node("%AdvancedContent").visible)
	settings.get_node("%AdvancedToggle").button_pressed = false
	await process_frame
	await _screenshot("settings")
	settings._on_umodel_path_changed("/custom/saved/umodel")
	settings.refresh()
	assert(settings._umodel_edit.text == "/custom/saved/umodel", "Reopening preserves a configured override")
	assert(not settings._is_dirty())
	settings._on_use_bundled_pressed()
	assert(settings._is_dirty(), "Resetting a saved override must enable Save")
	settings.free()
	var diagnostics := DiagnosticsTab.new().setup(config)
	root.add_child(diagnostics)
	diagnostics.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	var details := diagnostics._content.find_children("CheckDetail", "Label", true, false)
	assert(not details.is_empty())
	for detail in details:
		assert(not detail.visible)
	var full_report := diagnostics._summary_text()
	assert(config.get_config_dir() in full_report)
	var custom := diagnostics._capability_check("Mesh preview", ["/missing/custom/umodel"], true)
	assert(custom.status == DiagnosticsTab.CheckStatus.FAIL)
	assert("custom path" in custom.message)
	await _screenshot("diagnostics")
	var toggle := diagnostics._header.find_children("*", "CheckButton", true, false)[0] as CheckButton
	toggle.button_pressed = true
	for detail in details:
		assert(detail.visible)
	root.size.x = 640
	await process_frame
	await process_frame
	assert(diagnostics.get_combined_minimum_size().x <= 640, "Diagnostics must fit a narrow window")
	diagnostics.free()
	print("PASS: settings overrides and diagnostics disclosure")
	quit()

func _screenshot(label: String) -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(args[0])
	root.get_texture().get_image().save_png(args[0].path_join(label + ".png"))
