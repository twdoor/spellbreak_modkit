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
	AppTheme.style_header(hdr_label)
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
