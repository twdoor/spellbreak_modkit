class_name ParticleEffectDetail extends DetailItem

## Readable particle/VFX overview for Cascade-style particle assets.
## It keeps raw tree navigation intact, but presents particle modules as a compact
## module stack with editable scalar/vector/color rows.

const _PARTICLE_PREFIXES := [
	"Particle",
	"Distribution",
	"RawDistribution",
]

const _DISTRIBUTION_TYPES := [
	"RawDistributionFloat",
	"RawDistributionVector",
	"DistributionLookupTable",
]

var _selected: UAssetExport


func init_data(expo: UAssetExport) -> ParticleEffectDetail:
	_selected = expo
	return self


static func is_particle_export(asset: UAssetFile, expo: UAssetExport) -> bool:
	if asset == null or expo == null:
		return false
	var export_class_name := asset.get_export_class_name(expo)
	return _looks_particle_text(export_class_name) \
			or _looks_particle_text(expo.object_name) \
			or _has_particle_properties(expo)


static func _looks_particle_text(text: String) -> bool:
	for prefix in _PARTICLE_PREFIXES:
		if text.begins_with(prefix):
			return true
	return false


static func _has_particle_properties(expo: UAssetExport) -> bool:
	for prop in expo.properties:
		if prop.prop_type == "Struct" and _is_distribution_type(prop.struct_type):
			return true
		if prop.prop_name.contains("Distribution"):
			return true
	return false


static func _is_distribution_type(struct_type: String) -> bool:
	return struct_type in _DISTRIBUTION_TYPES or struct_type.begins_with("RawDistribution")


func _build_impl() -> void:
	var asset := _ctx.get_asset()
	if asset == null:
		return

	var selected_class := asset.get_export_class_name(_selected)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var title := Label.new()
	title.text = "Particle/VFX Inspector"
	AppTheme.style_header(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var focus_btn := Button.new()
	focus_btn.text = "Focus in tree"
	focus_btn.flat = true
	AppTheme.style_nav_btn(focus_btn)
	focus_btn.pressed.connect(func() -> void: _ctx.select_tree_item.call(_selected))
	header.add_child(focus_btn)
	_container.add_child(header)

	_add_type_badge(_type_label(_selected, selected_class))
	_add_separator()

	var particle_exports := _collect_particle_exports(asset)
	_add_module_stack(asset, particle_exports)

	_add_separator()
	_add_section_label("SELECTED EXPORT")
	_add_info_row("Object", _selected.object_name)
	_add_info_row("Class", selected_class if not selected_class.is_empty() else _selected.export_type)
	_add_ref_row("ClassIndex", _selected.class_index, func(v):
		_selected.class_index = v; _selected.raw["ClassIndex"] = v)
	_add_ref_row("OuterIndex", _selected.outer_index, func(v):
		_selected.outer_index = v; _selected.raw["OuterIndex"] = v)


func _collect_particle_exports(asset: UAssetFile) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	for expo in asset.exports:
		if is_particle_export(asset, expo):
			result.append(expo)
	return result


func _add_module_stack(asset: UAssetFile, exports: Array[UAssetExport]) -> void:
	_add_section_label("MODULE STACK")
	if exports.is_empty():
		_add_info("No particle modules were detected in this asset.")
		return

	var grouped := _group_particle_exports(asset, exports)
	var groups: Array = grouped["groups"]
	var by_group: Dictionary = grouped["items"]
	for group_name in groups:
		var group_exports: Array = by_group[group_name]
		_add_emitter_header(str(group_name), group_exports.size())
		for expo in group_exports:
			_add_module_card(asset, expo)


func _group_particle_exports(asset: UAssetFile, exports: Array[UAssetExport]) -> Dictionary:
	var groups: Array = []
	var items: Dictionary = {}
	for expo in exports:
		var group_name := _group_name_for(asset, expo)
		if not items.has(group_name):
			items[group_name] = []
			groups.append(group_name)
		(items[group_name] as Array).append(expo)
	return {"groups": groups, "items": items}


func _group_name_for(asset: UAssetFile, expo: UAssetExport) -> String:
	var cls := asset.get_export_class_name(expo)
	if cls.contains("Emitter"):
		return expo.object_name
	if expo.outer_index > 0 and expo.outer_index <= asset.exports.size():
		var outer := asset.exports[expo.outer_index - 1]
		var outer_class := asset.get_export_class_name(outer)
		if is_particle_export(asset, outer):
			return "%s  (%s)" % [outer.object_name, outer_class if not outer_class.is_empty() else "outer"]
	if cls == "ParticleSystem" or expo.object_name.contains("ParticleSystem"):
		return expo.object_name
	return "Particle modules"


func _add_emitter_header(label_text: String, count: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var label := Label.new()
	label.text = label_text
	AppTheme.style_section(label)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var count_label := Label.new()
	count_label.text = "%d module(s)" % count
	AppTheme.style_badge(count_label)
	row.add_child(count_label)
	_container.add_child(row)


func _add_module_card(asset: UAssetFile, expo: UAssetExport) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _module_card_style(expo == _selected))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", AppTheme.SPACING_ROW)
	margin.add_theme_constant_override("margin_right", AppTheme.SPACING_ROW)
	margin.add_theme_constant_override("margin_top", AppTheme.SPACING_FIELD)
	margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_FIELD)
	panel.add_child(margin)

	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(card)

	var saved := _container
	_container = card
	_add_module_header(asset, expo)
	_add_module_properties(expo)
	_container = saved
	_container.add_child(panel)


func _module_card_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = AppTheme.BG_PANEL if not selected else AppTheme.BG_PANEL.lerp(AppTheme.BG_SELECTION, 0.35)
	style.border_color = AppTheme.BG_HOVER if not selected else AppTheme.REF_COLOR
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.set_corner_radius_all(AppTheme.CORNER_RADIUS)
	return style


func _add_module_header(asset: UAssetFile, expo: UAssetExport) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var name_label := Label.new()
	name_label.text = "%s  %s" % [_module_kind(asset, expo), expo.object_name]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)

	var class_label := Label.new()
	class_label.text = _type_label(expo, asset.get_export_class_name(expo))
	AppTheme.style_badge(class_label)
	row.add_child(class_label)

	var tree_btn := Button.new()
	tree_btn.text = "Tree"
	tree_btn.flat = true
	AppTheme.style_nav_btn(tree_btn)
	tree_btn.pressed.connect(func() -> void: _ctx.select_tree_item.call(expo))
	row.add_child(tree_btn)
	_container.add_child(row)


func _module_kind(asset: UAssetFile, expo: UAssetExport) -> String:
	var cls := asset.get_export_class_name(expo)
	if cls.begins_with("ParticleModule"):
		return cls.trim_prefix("ParticleModule")
	if cls.begins_with("Particle"):
		return cls.trim_prefix("Particle")
	if expo.object_name.begins_with("ParticleModule"):
		var parts := expo.object_name.split("_")
		return str(parts[0]).trim_prefix("ParticleModule")
	return "Module"


func _type_label(expo: UAssetExport, export_class_name: String) -> String:
	if not export_class_name.is_empty():
		return export_class_name
	return expo.export_type


func _add_module_properties(expo: UAssetExport) -> void:
	if expo.properties.is_empty():
		_add_info("(no editable module properties)")
		return
	var simple: Array[UAssetProperty] = []
	var complex: Array[UAssetProperty] = []
	for prop in expo.properties:
		if _is_module_summary_property(prop):
			simple.append(prop)
		else:
			complex.append(prop)

	var get_simple := func() -> Array: return simple
	for prop in simple:
		_add_module_property(prop, get_simple)

	if not complex.is_empty():
		_add_separator()
		for prop in complex:
			_add_nav_button(prop)


func _is_module_summary_property(prop: UAssetProperty) -> bool:
	if PropertyRow.is_color_struct(prop) or PropertyRow.is_vector_struct(prop):
		return true
	if prop.prop_type not in ["Struct", "Array", "GameplayTagContainer"]:
		return true
	if prop.prop_type == "Struct" and _is_distribution_type(prop.struct_type):
		return true
	return prop.prop_type == "Struct" and _is_simple_struct(prop)


func _add_module_property(prop: UAssetProperty, siblings: Callable = Callable()) -> void:
	if prop.prop_type == "Struct" and _is_distribution_type(prop.struct_type):
		_add_distribution(prop)
	elif prop.prop_type == "Struct" and _is_simple_struct(prop) and not PropertyRow.is_vector_struct(prop):
		_add_section_label("%s [%s]" % [prop.prop_name, prop.struct_type])
		_build_flat_leaves(prop)
	else:
		_add_selectable_property_row(prop, siblings)


func _add_distribution(prop: UAssetProperty) -> void:
	_add_section_label("%s [%s]" % [prop.prop_name, prop.struct_type])
	var editable: Array[UAssetProperty] = []
	var complex: Array[UAssetProperty] = []
	for child in prop.children:
		if PropertyRow.is_vector_struct(child) or PropertyRow.is_color_struct(child):
			editable.append(child)
		elif child.prop_type not in ["Struct", "Array", "GameplayTagContainer"]:
			editable.append(child)
		elif child.prop_type == "Struct" and _is_simple_struct(child):
			editable.append(child)
		else:
			complex.append(child)
	var get_editable := func() -> Array: return editable
	for child in editable:
		if child.prop_type == "Struct" and _is_simple_struct(child) \
				and not PropertyRow.is_vector_struct(child) \
				and not PropertyRow.is_color_struct(child):
			_build_flat_leaves(child)
		else:
			_add_selectable_property_row(child, get_editable)
	for child in complex:
		_add_nav_button(child)
