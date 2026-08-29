extends SceneTree

## Headless smoke-check for the cooked UMG designer model.
## Usage: godot --headless --path . --script res://tools/inspect_umg.gd -- FILE.uasset

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("Pass a WidgetBlueprint .uasset path")
		quit(2)
		return
	var asset := UAssetFile.load_file(args[0])
	if asset == null:
		quit(1)
		return
	var model := UmgDesignerModel.create(asset)
	if model.roots().is_empty():
		for i in asset.exports.size():
			if asset.exports[i].object_name.begins_with("WidgetTree"):
				printerr("Candidate #%d class=%s RootWidget=%s" % [i + 1,
					asset.get_export_class_name(asset.exports[i]),
					str(asset.exports[i].find_property("RootWidget").value)])
		printerr("No WidgetTree exports found")
		quit(1)
		return
	var linked := 0
	var canvas_slots := 0
	var embedded_instances := 0
	var main_brushes := model.brush_resources_for_tree(int(model.roots()[0]["root_index"]), 128).size()
	for data in model.nodes.values():
		if int(data["parent_index"]) >= 0:
			linked += 1
		if bool(model.canvas_layout(int(data["export_index"]))["valid"]):
			canvas_slots += 1
		if model.embedded_root_for(int(data["export_index"])) >= 0:
			embedded_instances += 1
	# Construct the real detail control as part of the smoke check. This catches
	# model-valid/UI-invalid regressions without needing interactive automation.
	var host := VBoxContainer.new()
	root.add_child(host)
	var context := AssetEditorContext.new()
	context.document = AssetDocument.new(asset)
	context.selection = SelectionManager.new()
	context.navigate_to = func(_data: Variant, _label: String) -> void: pass
	context.navigate_back = func() -> void: pass
	var detail := UmgDesignerDetail.new().setup(context)
	detail.build_detail(host)
	print("UMG designer: %d trees, %d linked widgets, %d embedded instances, %d canvas slots, %d main bitmap brushes" % [
		model.roots().size(), linked, embedded_instances, canvas_slots, main_brushes])
	quit(0)
