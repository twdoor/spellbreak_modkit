class_name UmgDesignerDetail extends DetailItem

var _model: UmgDesignerModel
var _canvas: UmgCanvas
var _hierarchy: Tree
var _tree_items: Dictionary = {}
var _selected := -1
var _selection_label: Label
var _inspector_title: Label
var _geometry_box: VBoxContainer
var _geometry_inputs: Dictionary = {}
var _updating_inspector := false
var _texture_job := -1
var _texture_status: Label


func _build_impl() -> void:
	_model = UmgDesignerModel.create(_ctx.get_asset())
	_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var toolbar := HBoxContainer.new()
	var exit_button := Button.new()
	exit_button.text = "‹ Raw asset"
	exit_button.pressed.connect(func() -> void: _ctx.show_detail.call(&"exports"))
	toolbar.add_child(exit_button)
	var title := Label.new()
	title.text = "UI Designer"
	AppTheme.style_header(title)
	toolbar.add_child(title)
	var tree_picker := OptionButton.new()
	tree_picker.custom_minimum_size.x = 280
	for tree_data in _model.roots():
		tree_picker.add_item(str(tree_data["name"]))
	toolbar.add_child(tree_picker)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	var help := Label.new()
	help.text = "Wheel zoom · MMB pan · drag move"
	help.tooltip_text = "Mouse wheel: zoom at cursor\nMiddle mouse: pan\nLeft click: select\nDrag a CanvasPanel child: move"
	AppTheme.style_dim(help)
	toolbar.add_child(help)
	_texture_status = Label.new()
	AppTheme.style_dim(_texture_status)
	toolbar.add_child(_texture_status)
	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.pressed.connect(func() -> void:
		_canvas.zoom = 1.0
		_canvas.pan = Vector2.ZERO
		_canvas.queue_redraw())
	toolbar.add_child(fit_button)
	_container.add_child(toolbar)

	var split := HSplitContainer.new()
	split.custom_minimum_size = Vector2(900, 480)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 260
	_hierarchy = Tree.new()
	_hierarchy.custom_minimum_size.x = 220
	_hierarchy.hide_root = true
	_hierarchy.item_selected.connect(_on_hierarchy_selected)
	split.add_child(_hierarchy)
	var preview_column := VBoxContainer.new()
	preview_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas = UmgCanvas.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.widget_selected.connect(_select_widget)
	_canvas.widget_moved.connect(_on_widget_moved)
	preview_column.add_child(_canvas)
	_selection_label = Label.new()
	AppTheme.style_dim(_selection_label)
	preview_column.add_child(_selection_label)
	split.add_child(preview_column)
	var inspector := VBoxContainer.new()
	inspector.custom_minimum_size.x = 245
	inspector.add_theme_constant_override("separation", 8)
	_inspector_title = Label.new()
	_inspector_title.text = "INSPECTOR"
	AppTheme.style_section(_inspector_title)
	inspector.add_child(_inspector_title)
	_geometry_box = VBoxContainer.new()
	inspector.add_child(_geometry_box)
	for field in ["left", "top", "right", "bottom"]:
		_add_geometry_field(field)
	var raw_button := Button.new()
	raw_button.text = "Advanced properties…"
	raw_button.pressed.connect(_open_selected_export)
	inspector.add_child(raw_button)
	split.add_child(inspector)
	_container.add_child(split)

	tree_picker.item_selected.connect(_show_tree)
	if not _model.roots().is_empty():
		_show_tree(0)


func _show_tree(which: int) -> void:
	var tree_data: Dictionary = _model.roots()[which]
	var root_index: int = tree_data["root_index"]
	_canvas.show_tree(_model, root_index)
	_hierarchy.clear()
	_tree_items.clear()
	var root_item := _hierarchy.create_item()
	_add_hierarchy_item(root_item, root_index, {})
	_load_tree_textures(root_index)


func _load_tree_textures(root_index: int) -> void:
	if _texture_job >= 0 and _ctx.background_jobs:
		_ctx.background_jobs.cancel(_texture_job)
		_texture_job = -1
	_canvas.set_brush_textures({})
	if _ctx.texture_service == null or _ctx.background_jobs == null \
			or not _ctx.texture_service.is_configured():
		_texture_status.text = "Textures unavailable"
		return
	var resources: Array[Dictionary] = _model.brush_resources_for_tree(root_index, 32)
	if resources.is_empty():
		_texture_status.text = "No bitmap brushes"
		return
	_texture_status.text = "Loading %d textures…" % resources.size()
	var near_path := _ctx.get_asset().binary_path
	var service := _ctx.texture_service
	_texture_job = _ctx.background_jobs.run(func() -> Dictionary:
		var images := {}
		for resource in resources:
			var package_path := str(resource["package_path"])
			var asset_path := service.find_package_asset(package_path, near_path)
			if asset_path.is_empty():
				continue
			var preview: Image
			if str(resource["class"]) == "Texture2D":
				preview = _load_texture_preview(service, asset_path)
			else:
				preview = _load_material_brush_preview(service, asset_path)
			if preview:
				images[package_path] = preview
		return images,
		func(images: Dictionary) -> void:
			_texture_job = -1
			var textures := {}
			for package_path in images:
				textures[package_path] = ImageTexture.create_from_image(images[package_path])
			_canvas.set_brush_textures(textures)
			_texture_status.text = "%d/%d textures" % [textures.size(), resources.size()])


func _load_texture_preview(service: TextureService, asset_path: String) -> Image:
	var cached := service.get_cached_preview(asset_path)
	return Image.load_from_file(cached) if not cached.is_empty() \
			else service.get_preview_image(asset_path)


## Slate frequently uses a MaterialInstanceConstant as its brush resource.
## Godot cannot execute the UE shader, so use the most likely referenced color
## texture as an honest approximation instead of a generic rectangle.
func _load_material_brush_preview(service: TextureService, material_path: String) -> Image:
	var material := UAssetFile.load_file(material_path)
	if material == null:
		return null
	var candidates: Array[Dictionary] = []
	# Only use textures explicitly assigned to this material instance. Walking
	# every import also finds editor defaults and parent-material helper textures
	# (including the gray missing-resource icon), which is not the brush artwork.
	for expo in material.exports:
		for prop in expo.properties:
			_collect_material_texture_parameters(material, prop, candidates)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["score"]) > int(b["score"]))
	for candidate in candidates:
		var texture_path := service.find_package_asset(str(candidate["path"]), material_path)
		if not texture_path.is_empty():
			var preview := _load_texture_preview(service, texture_path)
			if preview:
				return preview
	return null


func _collect_material_texture_parameters(material: UAssetFile, prop: UAssetProperty,
		candidates: Array[Dictionary]) -> void:
	if prop.prop_name == "ParameterValue" and (prop.value is int or prop.value is float):
		var package_index := int(prop.value)
		if package_index < 0:
			var imp := material.get_import(package_index)
			if imp and imp.class_name_str == "Texture2D":
				var package_path := _package_path_for_import(material, imp)
				if not package_path.is_empty():
					candidates.append({"path": package_path,
						"score": ParticleMaterialAnalyzer.texture_score(package_path) + 1000})
	for child in prop.children:
		_collect_material_texture_parameters(material, child, candidates)


func _package_path_for_import(asset: UAssetFile, imp: UAssetImport) -> String:
	if imp.object_name.begins_with("/Game/"):
		return imp.object_name
	if imp.outer_index >= 0:
		return ""
	var outer := asset.get_import(imp.outer_index)
	return _package_path_for_import(asset, outer) if outer else ""


func _add_hierarchy_item(parent: TreeItem, index: int, visited: Dictionary) -> void:
	if visited.has(index):
		return
	var next := visited.duplicate()
	next[index] = true
	var data := _model.node(index)
	if data.is_empty():
		return
	var item := _hierarchy.create_item(parent)
	item.set_text(0, "%s  ·  %s" % [data["name"], data["class"]])
	item.set_metadata(0, index)
	_tree_items[index] = item
	for child_index: int in _model.visual_children(index):
		_add_hierarchy_item(item, child_index, next)


func _on_hierarchy_selected() -> void:
	var item := _hierarchy.get_selected()
	if item:
		_select_widget(int(item.get_metadata(0)))


func _select_widget(index: int) -> void:
	_selected = index
	_canvas.select_widget(index)
	if _tree_items.has(index):
		_hierarchy.set_selected(_tree_items[index], 0)
	var data := _model.node(index)
	_selection_label.text = "%s · %s · export #%d" % [data.get("name", "Nothing selected"),
			data.get("class", ""), index + 1] if index >= 0 else "Nothing selected"
	if index >= 0:
		_ctx.selection.set_selection([data["export"]])
	_refresh_inspector()


func _on_widget_moved(index: int, delta: Vector2) -> void:
	# Dragging applies continuously for feedback; register that applied edit so
	# undo/redo uses the same cooked CanvasPanelSlot values.
	_ctx.record_applied("Move UI widget",
		func() -> void: _model.move_canvas_widget(index, delta),
		func() -> void: _model.move_canvas_widget(index, -delta))
	_refresh_inspector()


func _add_geometry_field(field: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = field.capitalize()
	label.custom_minimum_size.x = 62
	AppTheme.style_dim(label)
	row.add_child(label)
	var input := SpinBox.new()
	input.min_value = -100000
	input.max_value = 100000
	input.step = 1
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.value_changed.connect(func(value: float) -> void: _set_geometry_field(field, value))
	_geometry_inputs[field] = input
	row.add_child(input)
	_geometry_box.add_child(row)


func _refresh_inspector() -> void:
	_updating_inspector = true
	var data := _model.node(_selected)
	if _selected < 0 or data.is_empty():
		_inspector_title.text = "INSPECTOR"
		_geometry_box.visible = false
		_updating_inspector = false
		return
	_inspector_title.text = "%s\n%s" % [data["name"], data["class"]]
	var layout := _model.canvas_layout(_selected)
	_geometry_box.visible = bool(layout["valid"])
	if bool(layout["valid"]):
		for field in _geometry_inputs:
			(_geometry_inputs[field] as SpinBox).value = float(layout[field])
	_updating_inspector = false


func _set_geometry_field(field: String, value: float) -> void:
	if _updating_inspector or _selected < 0:
		return
	var before := _model.canvas_layout(_selected)
	if not bool(before["valid"]) or is_equal_approx(float(before[field]), value):
		return
	var after := before.duplicate()
	after[field] = value
	_model.set_canvas_offsets(_selected, after)
	var index := _selected
	_ctx.record_applied("Edit UI %s" % field,
		func() -> void: _model.set_canvas_offsets(index, after),
		func() -> void: _model.set_canvas_offsets(index, before))
	_canvas.queue_redraw()


func _open_selected_export() -> void:
	if _selected < 0:
		return
	var data := _model.node(_selected)
	_ctx.navigate_to.call(data["export"], str(data["name"]))


func dispose() -> void:
	if _texture_job >= 0 and _ctx.background_jobs:
		_ctx.background_jobs.cancel(_texture_job)
		_texture_job = -1
