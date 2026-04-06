class_name ExportDetail extends DetailItem

## Detail view for a single UAssetExport: metadata, references, properties, dependencies.

var _expo: UAssetExport


func init_data(expo: UAssetExport) -> ExportDetail:
	_expo = expo
	return self


func _build_impl() -> void:
	var expo := _expo

	# Header row: title
	var hdr := HBoxContainer.new()
	var hdr_label := Label.new()
	hdr_label.text = "Export: %s" % expo.object_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	hdr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hdr_label)

	_container.add_child(hdr)

	_add_type_badge(expo.export_type)
	_add_separator()

	# Reference indices
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

	# Only show simple leaf properties — structs/arrays are navigable via the tree.
	var has_props := false
	for prop in expo.properties:
		if prop.prop_type not in ["Struct", "Array", "GameplayTagContainer"]:
			if not has_props:
				_add_separator()
				_add_section_label("PROPERTIES")
				has_props = true
			var row := PropertyRow.create(prop, _ctx["asset"])
			row.value_changed.connect(_on_row_value_changed)
			_container.add_child(row)

	# Dependency arrays
	_add_separator()
	_add_section_label("DEPENDENCIES")
	for field in [
		"CreateBeforeCreateDependencies",
		"CreateBeforeSerializationDependencies",
		"SerializationBeforeCreateDependencies",
		"SerializationBeforeSerializationDependencies"
	]:
		_add_dep_array_row(field, expo)


# ── Reference index row ────────────────────────────────────────────────────────

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


# ── Dependency array row ───────────────────────────────────────────────────────

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
		tip_parts.append("%d → %s" % [idx, _resolve_dep_index(idx)])

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
		for idx in new_indices:
			new_tip.append("%d → %s" % [idx, _resolve_dep_index(idx)])
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
