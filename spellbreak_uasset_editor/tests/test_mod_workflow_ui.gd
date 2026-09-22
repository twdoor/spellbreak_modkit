extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var watcher := ModFileWatcher.new()
	var notifications: Array = []
	watcher.pack_triggered.connect(func(count: int) -> void: notifications.append(count))
	watcher._emit_pack_triggered_and_pack(1, [])
	assert(notifications.is_empty(), "A paused watcher must ignore queued pack requests")
	var temp := FileUtils.make_temp_dir("sb_workflow_ui_test")
	assert(temp.ok)
	var mod_path: String = temp.path
	DirAccess.make_dir_recursive_absolute(mod_path.path_join("g3"))
	var mods: Array[ModInfo] = [ModInfo.new("Test Mod", mod_path, 0, 0)]
	var dialog := ModWorkflowDialog.new()
	dialog.setup(mods, [], 0)
	root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))
	assert(dialog._mods.item_count == 1)
	assert(dialog._tabs.get_tab_count() == 2)
	assert(dialog._apply.disabled)
	dialog._run("scan")
	var deadline := Time.get_ticks_msec() + 15000
	while dialog._service.is_busy() and Time.get_ticks_msec() < deadline:
		await process_frame
	assert(not dialog._service.is_busy())
	assert(dialog._catalog.has("rows"))
	assert(dialog._catalog.rows.is_empty())
	assert(not dialog._mods.disabled)
	dialog.queue_free()
	await process_frame
	FileUtils.remove_dir_recursive(mod_path)
	print("Mod workflow UI and subprocess smoke checks passed")
	quit()
