class_name TextureDetail extends DetailItem

## Detail view for a texture export: preview image, export/import buttons, and standard
## export metadata below.  Preview is loaded asynchronously via TextureService.

var _expo: UAssetExport
var _class_name: String

var _preview_rect: TextureRect
var _loading_label: Label
var _export_btn: Button
var _import_btn: Button
var _status_label: Label
var _preview_thread: Thread


func init_data(expo: UAssetExport, cls_name: String) -> TextureDetail:
	_expo = expo
	_class_name = cls_name
	return self


func _build_impl() -> void:
	var expo := _expo

	# Header
	var hdr := HBoxContainer.new()
	var hdr_label := Label.new()
	hdr_label.text = "Export: %s" % expo.object_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	hdr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hdr_label)
	_container.add_child(hdr)

	_add_type_badge(_class_name)
	_add_separator()

	# ── Texture preview section ───────────────────────────────────────────────
	_add_section_label("TEXTURE PREVIEW")

	var tex_service: TextureService = _ctx.get("texture_service")

	if tex_service == null or not tex_service.is_configured():
		_add_info("UE4-DDS-Tools not configured. Set the path in Settings to enable texture preview.")
	else:
		# Preview image container
		var preview_container := VBoxContainer.new()
		preview_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		_loading_label = Label.new()
		_loading_label.text = "Loading preview..."
		_loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_loading_label.add_theme_font_size_override("font_size", 13)
		preview_container.add_child(_loading_label)

		_preview_rect = TextureRect.new()
		_preview_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_preview_rect.custom_minimum_size = Vector2(0, 256)
		_preview_rect.visible = false
		preview_container.add_child(_preview_rect)

		_container.add_child(preview_container)

		# Start loading preview
		_load_preview_async(tex_service)

	_add_separator()

	# ── Texture actions ───────────────────────────────────────────────────────
	_add_section_label("TEXTURE ACTIONS")

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)

	_export_btn = Button.new()
	_export_btn.text = "Export as PNG..."
	_export_btn.pressed.connect(_on_export_pressed)
	btn_row.add_child(_export_btn)

	_import_btn = Button.new()
	_import_btn.text = "Import PNG..."
	_import_btn.pressed.connect(_on_import_pressed)
	btn_row.add_child(_import_btn)

	_container.add_child(btn_row)

	# Availability checks
	if tex_service == null or not tex_service.is_configured():
		_export_btn.disabled = true
		_export_btn.tooltip_text = "UE4-DDS-Tools not configured"
		_import_btn.disabled = true
		_import_btn.tooltip_text = "UE4-DDS-Tools not configured"
	elif not tex_service.has_magick():
		_export_btn.disabled = true
		_export_btn.tooltip_text = "ImageMagick (magick) not found in PATH"
		_import_btn.disabled = true
		_import_btn.tooltip_text = "ImageMagick (magick) not found in PATH"

	# Status label for operation feedback
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_container.add_child(_status_label)

	_add_separator()

	# ── Standard export detail (references, properties, dependencies) ─────────
	_add_section_label("REFERENCES")
	_add_field_editor("ObjectName", expo.object_name, func(v):
		expo.object_name = v
		expo.raw["ObjectName"] = v
		hdr_label.text = "Export: %s" % v
	)
	_add_ref_row("ClassIndex", expo.class_index, func(v):
		expo.class_index = v; expo.raw["ClassIndex"] = v)
	_add_ref_row("SuperIndex", expo.super_index, func(v):
		expo.super_index = v; expo.raw["SuperIndex"] = v)
	_add_ref_row("OuterIndex", expo.outer_index, func(v):
		expo.outer_index = v; expo.raw["OuterIndex"] = v)
	_add_ref_row("TemplateIndex", expo.template_index, func(v):
		expo.template_index = v; expo.raw["TemplateIndex"] = v)
	_add_field_editor("ObjectFlags", expo.object_flags, func(v):
		expo.object_flags = v; expo.raw["ObjectFlags"] = v)

	# Leaf properties
	var has_props := false
	var leaf_props: Array[UAssetProperty] = []
	for prop in expo.properties:
		if prop.prop_type not in ["Struct", "Array", "GameplayTagContainer"]:
			leaf_props.append(prop)
	var get_leaves: Callable = func() -> Array: return leaf_props
	for prop in leaf_props:
		if not has_props:
			_add_separator()
			_add_section_label("PROPERTIES")
			has_props = true
		_add_selectable_property_row(prop, get_leaves)

	# Dependencies
	_add_separator()
	_add_section_label("DEPENDENCIES")
	for field in [
		"CreateBeforeCreateDependencies",
		"CreateBeforeSerializationDependencies",
		"SerializationBeforeCreateDependencies",
		"SerializationBeforeSerializationDependencies"
	]:
		_add_dep_array_row(field, expo)


# ── Preview loading ───────────────────────────────────────────────────────────


func _load_preview_async(tex_service: TextureService) -> void:
	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	if not uasset_path.ends_with(".uasset"):
		_loading_label.text = "Preview requires a .uasset file (not JSON)"
		return

	# Check cache first
	var cached := tex_service.get_cached_preview(uasset_path)
	if not cached.is_empty():
		var img := Image.load_from_file(cached)
		if img:
			_show_preview(img)
			return

	# Load in background thread
	_preview_thread = Thread.new()
	_preview_thread.start(_preview_worker.bind(tex_service, uasset_path))


func _preview_worker(tex_service: TextureService, uasset_path: String) -> void:
	var img := tex_service.get_preview_image(uasset_path)
	call_deferred("_on_preview_loaded", img)


func _on_preview_loaded(img: Image) -> void:
	if _preview_thread:
		_preview_thread.wait_to_finish()
		_preview_thread = null
	if img:
		_show_preview(img)
	else:
		if is_instance_valid(_loading_label):
			_loading_label.text = "Failed to load preview"
			_loading_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))


func _show_preview(img: Image) -> void:
	if not is_instance_valid(_preview_rect):
		return
	var tex := ImageTexture.create_from_image(img)
	_preview_rect.texture = tex
	_preview_rect.visible = true
	# Scale: fit within max 512px width, use actual aspect ratio for height
	var max_w := 512.0
	var aspect := float(img.get_height()) / float(img.get_width()) if img.get_width() > 0 else 1.0
	var display_w := minf(max_w, img.get_width())
	_preview_rect.custom_minimum_size = Vector2(display_w, display_w * aspect)
	if is_instance_valid(_loading_label):
		_loading_label.text = "%dx%d" % [img.get_width(), img.get_height()]


# ── Export / Import actions ───────────────────────────────────────────────────


func _on_export_pressed() -> void:
	var tex_service: TextureService = _ctx.get("texture_service")
	if tex_service == null or tex_service.is_busy():
		return

	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.png ; PNG Image"])
	dialog.current_file = uasset_path.get_file().get_basename() + ".png"
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		_status_label.text = "Exporting..."
		_export_btn.disabled = true
		_import_btn.disabled = true
		tex_service.operation_finished.connect(_on_export_finished, CONNECT_ONE_SHOT)
		tex_service.export_png(uasset_path, path)
		dialog.queue_free()
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _on_export_finished(success: bool, message: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = message
		_status_label.add_theme_color_override("font_color",
			Color(0.4, 0.8, 0.4) if success else Color(0.8, 0.4, 0.4))
	if is_instance_valid(_export_btn):
		_export_btn.disabled = false
	if is_instance_valid(_import_btn):
		_import_btn.disabled = false


func _on_import_pressed() -> void:
	var tex_service: TextureService = _ctx.get("texture_service")
	if tex_service == null or tex_service.is_busy():
		return

	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	var output_dir := uasset_path.get_base_dir()

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.png ; PNG Image"])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		_status_label.text = "Injecting..."
		_export_btn.disabled = true
		_import_btn.disabled = true
		tex_service.operation_finished.connect(_on_import_finished, CONNECT_ONE_SHOT)
		tex_service.inject_png(uasset_path, path, output_dir)
		dialog.queue_free()
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _on_import_finished(success: bool, message: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = message
		_status_label.add_theme_color_override("font_color",
			Color(0.4, 0.8, 0.4) if success else Color(0.8, 0.4, 0.4))
	if is_instance_valid(_export_btn):
		_export_btn.disabled = false
	if is_instance_valid(_import_btn):
		_import_btn.disabled = false
	# Reload preview after successful import
	if success:
		var tex_service: TextureService = _ctx.get("texture_service")
		if tex_service and is_instance_valid(_preview_rect):
			_load_preview_async(tex_service)


# ── Shared helpers (duplicated from ExportDetail for self-containment) ────────


func _add_ref_row(label_text: String, current_index: int, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = -2147483648
	spin.max_value = 2147483647
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.rounded = true
	spin.step = 1
	spin.custom_minimum_size.x = 80
	spin.value = current_index
	hbox.add_child(spin)

	var ref_label := Label.new()
	ref_label.text = PropertyRow._resolve_ref_name(current_index, _ctx["asset"])
	ref_label.tooltip_text = PropertyRow._resolve_ref_type(current_index, _ctx["asset"])
	ref_label.add_theme_font_size_override("font_size", 13)
	ref_label.add_theme_color_override("font_color", Color(0.45, 0.65, 0.9))
	ref_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_label.clip_text = true
	ref_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(ref_label)

	spin.value_changed.connect(func(v):
		_ctx["set_dirty"].call()
		on_change.call(int(v))
		ref_label.text = PropertyRow._resolve_ref_name(int(v), _ctx["asset"])
		ref_label.tooltip_text = PropertyRow._resolve_ref_type(int(v), _ctx["asset"])
	)
	_container.add_child(hbox)


func _add_dep_array_row(field: String, expo: UAssetExport) -> void:
	var raw_val = expo.raw.get(field)
	var indices: Array = raw_val if raw_val is Array else []

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = field.replace("Dependencies", "Deps")
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.tooltip_text = field
	hbox.add_child(label)

	var tip_parts: PackedStringArray = []
	for idx in indices:
		tip_parts.append("%d -> %s" % [idx, _resolve_dep_index(idx)])

	var line := LineEdit.new()
	line.text = ", ".join(PackedStringArray(indices.map(func(i): return str(i))))
	line.placeholder_text = "(empty)"
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.tooltip_text = "\n".join(tip_parts) if tip_parts.size() > 0 else "(none)"
	line.text_submitted.connect(func(t: String):
		var new_indices: Array = []
		for part in t.split(","):
			var s := part.strip_edges()
			if s.is_empty(): continue
			if s.is_valid_int(): new_indices.append(s.to_int())
		expo.raw[field] = new_indices
		_ctx["set_dirty"].call()
		var new_tip: PackedStringArray = []
		for idx_val in new_indices:
			new_tip.append("%d -> %s" % [idx_val, _resolve_dep_index(idx_val)])
		line.tooltip_text = "\n".join(new_tip) if new_tip.size() > 0 else "(none)"
	)
	hbox.add_child(line)
	_container.add_child(hbox)


func _resolve_dep_index(idx: int) -> String:
	var asset: UAssetFile = _ctx["asset"]
	if idx > 0 and idx <= asset.exports.size():
		return asset.exports[idx - 1].object_name
	if idx < 0:
		var imp := asset.get_import(idx)
		if imp:
			return imp.object_name
	return "?"
