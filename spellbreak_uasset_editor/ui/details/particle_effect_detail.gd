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

const _PREVIEW_HEIGHT := 280.0
const _UE_TO_GODOT_DISTANCE := 100.0

var _selected: UAssetExport
var _preview_root: Node3D
var _preview_camera: Camera3D
var _preview_bounds := AABB()
var _preview_has_bounds := false
var _preview_visual_bounds := AABB()
var _preview_has_visual_bounds := false
var _preview_status_label: Label
var _preview_mesh_jobs: Array[int] = []
var _preview_texture_jobs: Array[int] = []


func init_data(expo: UAssetExport) -> ParticleEffectDetail:
	_selected = expo
	return self


func dispose() -> void:
	if _ctx != null and _ctx.background_jobs != null:
		for job_id in _preview_mesh_jobs:
			_ctx.background_jobs.cancel(job_id)
		for job_id in _preview_texture_jobs:
			_ctx.background_jobs.cancel(job_id)
	_preview_mesh_jobs.clear()
	_preview_texture_jobs.clear()


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
	_add_preview(asset, particle_exports)
	_add_separator()
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

	var effect_emitters := _collect_effect_emitters(asset, exports)
	if not effect_emitters.is_empty():
		for emitter_info in effect_emitters:
			var modules: Array = emitter_info.get("modules", [])
			_add_emitter_header(str(emitter_info.get("name", "Particle emitter")), modules.size())
			for expo in modules:
				_add_module_card(asset, expo)
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


func _is_particle_system_export(asset: UAssetFile, expo: UAssetExport) -> bool:
	var cls := asset.get_export_class_name(expo)
	return cls == "ParticleSystem" or expo.object_name.contains("ParticleSystem")


func _is_particle_emitter_export(asset: UAssetFile, expo: UAssetExport) -> bool:
	if _is_particle_system_export(asset, expo) \
			or _is_particle_lod_export(asset, expo) \
			or _is_particle_module_export(asset, expo):
		return false
	var cls := asset.get_export_class_name(expo)
	if cls.contains("Emitter") or expo.object_name.contains("Emitter"):
		return true
	return expo.find_property("LODLevel") != null \
			or expo.find_property("LODLevels") != null \
			or expo.find_property("RequiredModule") != null \
			or expo.find_property("SpawnModule") != null


func _is_particle_lod_export(asset: UAssetFile, expo: UAssetExport) -> bool:
	var cls := asset.get_export_class_name(expo)
	return cls.contains("LODLevel") or expo.object_name.begins_with("ParticleLODLevel")


func _is_particle_module_export(asset: UAssetFile, expo: UAssetExport) -> bool:
	var cls := asset.get_export_class_name(expo)
	return cls.begins_with("ParticleModule") or expo.object_name.begins_with("ParticleModule")


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


func _add_preview(asset: UAssetFile, exports: Array[UAssetExport]) -> void:
	_add_section_label("VFX PREVIEW")
	if exports.is_empty():
		_add_info("No previewable particle modules were detected.")
		return

	var viewport_container := SubViewportContainer.new()
	viewport_container.custom_minimum_size = Vector2(0, _PREVIEW_HEIGHT)
	viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport_container.stretch = true

	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.size = Vector2i(640, 360)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.add_child(viewport)

	_preview_root = Node3D.new()
	viewport.add_child(_preview_root)
	_add_preview_environment(_preview_root)

	_preview_camera = Camera3D.new()
	_preview_camera.current = true
	_preview_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_preview_camera.size = 5.0
	_preview_camera.look_at_from_position(Vector3(3.5, 2.0, 4.0), Vector3.ZERO, Vector3.UP)
	_preview_root.add_child(_preview_camera)

	_container.add_child(viewport_container)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var restart_btn := Button.new()
	restart_btn.text = "Restart Preview"
	restart_btn.flat = true
	AppTheme.style_nav_btn(restart_btn)
	restart_btn.pressed.connect(func() -> void: _restart_preview_emitters())
	controls.add_child(restart_btn)
	_container.add_child(controls)

	_preview_status_label = _add_status_label("", AppTheme.StatusKind.IDLE, AppTheme.FONT_SMALL)
	_add_preview_emitters(asset, exports)


func _add_preview_environment(root: Node3D) -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = AppTheme.BG_PRIMARY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.48, 0.52)
	env.ambient_light_energy = 0.9
	world_env.environment = env
	root.add_child(world_env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 35, 0)
	light.light_energy = 0.9
	root.add_child(light)


func _add_preview_emitters(asset: UAssetFile, exports: Array[UAssetExport]) -> void:
	var effect_emitters := _preview_effect_emitters(asset)
	if effect_emitters.is_empty():
		effect_emitters = _collect_effect_emitters(asset, exports)
	if not effect_emitters.is_empty():
		for emitter_info in effect_emitters:
			var modules: Array = emitter_info.get("modules", [])
			var spec := _preview_spec_from_modules(asset, modules)
			var particles := _make_preview_particles(spec)
			particles.name = "Preview_%s" % str(emitter_info.get("name", "Emitter"))
			_preview_root.add_child(particles)
			_include_preview_spec_bounds(particles, spec)
			_maybe_load_preview_assets(particles, spec)
		return

	var preview_exports := _preview_exports_for(asset, exports)
	var grouped := _group_particle_exports(asset, preview_exports)
	var groups: Array = grouped["groups"]
	var by_group: Dictionary = grouped["items"]
	var count := maxi(groups.size(), 1)
	for i in groups.size():
		var group_name := str(groups[i])
		var modules: Array = by_group[group_name]
		var spec := _preview_spec_from_modules(asset, modules)
		var particles := _make_preview_particles(spec)
		particles.name = "Preview_%s" % group_name
		particles.position.x = (float(i) - float(count - 1) * 0.5) * 1.1
		_preview_root.add_child(particles)
		_include_preview_spec_bounds(particles, spec)
		_maybe_load_preview_assets(particles, spec)


func _preview_effect_emitters(asset: UAssetFile) -> Array[Dictionary]:
	var emitter_exports := _system_effect_emitters(asset)
	if emitter_exports.is_empty():
		return []
	return _effect_emitters_from_exports(asset, emitter_exports)


func _collect_effect_emitters(asset: UAssetFile, _exports: Array[UAssetExport]) -> Array[Dictionary]:
	var emitter_exports := _selected_effect_emitters(asset)
	if emitter_exports.is_empty():
		emitter_exports = _system_effect_emitters(asset)
	if emitter_exports.is_empty():
		emitter_exports = _all_particle_emitters(asset)
	return _effect_emitters_from_exports(asset, emitter_exports)


func _effect_emitters_from_exports(asset: UAssetFile,
		emitter_exports: Array[UAssetExport]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary = {}
	for emitter in emitter_exports:
		var index := _export_index(asset, emitter)
		if index == 0 or seen.has(index):
			continue
		seen[index] = true
		var modules := _modules_for_emitter(asset, emitter)
		if modules.is_empty():
			continue
		result.append({
			"name": emitter.object_name,
			"emitter": emitter,
			"modules": modules,
		})
	return result


func _selected_effect_emitters(asset: UAssetFile) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	if _selected == null:
		return result
	if _is_particle_emitter_export(asset, _selected):
		result.append(_selected)
		return result
	if _is_particle_system_export(asset, _selected):
		return _emitters_from_system(asset, _selected)
	return _emitters_referencing_export(asset, _selected)


func _system_effect_emitters(asset: UAssetFile) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	var seen: Dictionary = {}
	for expo in asset.exports:
		if not _is_particle_system_export(asset, expo):
			continue
		for emitter in _emitters_from_system(asset, expo):
			_append_export_unique(asset, result, seen, emitter)
	return result


func _emitters_from_system(asset: UAssetFile, system: UAssetExport) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	var seen: Dictionary = {}
	_append_export_refs_from_array_property(asset, system.find_property("Emitters"), result, seen)
	_append_export_refs_from_array_property(asset, system.find_property("Emitter"), result, seen)
	return result


func _all_particle_emitters(asset: UAssetFile) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	for expo in asset.exports:
		if _is_particle_emitter_export(asset, expo):
			result.append(expo)
	return result


func _emitters_referencing_export(asset: UAssetFile, target: UAssetExport) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	if _export_index(asset, target) == 0:
		return result
	for emitter in _all_particle_emitters(asset):
		if _export_contains_export(asset, emitter, target):
			result.append(emitter)
			continue
		for lod in _lods_for_emitter(asset, emitter):
			if _lod_contains_export(asset, lod, target):
				result.append(emitter)
				break
	return result


func _modules_for_emitter(asset: UAssetFile, emitter: UAssetExport) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	var seen: Dictionary = {}
	_append_export_unique(asset, result, seen, emitter)

	var lod := _active_lod_for_emitter(asset, emitter)
	if lod != null:
		_append_export_unique(asset, result, seen, lod)

	var sources: Array[UAssetExport] = []
	if lod != null:
		sources.append(lod)
	sources.append(emitter)
	for source in sources:
		_append_module_refs_from_source(asset, source, result, seen)
	return result


func _active_lod_for_emitter(asset: UAssetFile, emitter: UAssetExport) -> UAssetExport:
	var lod_refs := _lods_for_emitter(asset, emitter)
	if not lod_refs.is_empty():
		for lod in lod_refs:
			if _selected != null and _lod_contains_export(asset, lod, _selected):
				return lod
		return lod_refs[0]
	return null


func _lods_for_emitter(asset: UAssetFile, emitter: UAssetExport) -> Array[UAssetExport]:
	var result: Array[UAssetExport] = []
	var seen: Dictionary = {}
	_append_export_ref_from_property(asset, emitter.find_property("LODLevel"), result, seen)
	_append_export_refs_from_array_property(asset, emitter.find_property("LODLevels"), result, seen)
	return result


func _lod_contains_export(asset: UAssetFile, lod: UAssetExport, target: UAssetExport) -> bool:
	if _export_contains_export(asset, lod, target):
		return true
	var modules: Array[UAssetExport] = []
	var seen: Dictionary = {}
	_append_module_refs_from_source(asset, lod, modules, seen)
	for module in modules:
		if _export_contains_export(asset, module, target):
			return true
	return false


func _append_module_refs_from_source(asset: UAssetFile, source: UAssetExport,
		result: Array[UAssetExport], seen: Dictionary) -> void:
	_append_export_ref_from_property(asset, source.find_property("RequiredModule"), result, seen)
	_append_export_ref_from_property(asset, source.find_property("SpawnModule"), result, seen)
	_append_export_ref_from_property(asset, source.find_property("TypeDataModule"), result, seen)
	_append_export_refs_from_array_property(asset, source.find_property("Modules"), result, seen)


func _export_contains_export(asset: UAssetFile, owner: UAssetExport, target: UAssetExport) -> bool:
	if owner == null or target == null:
		return false
	if owner == target:
		return true
	var target_index := _export_index(asset, target)
	if target_index != 0 and _export_references_index(owner, target_index):
		return true
	return _export_has_outer_ancestor(asset, target, owner)


func _export_has_outer_ancestor(asset: UAssetFile, child: UAssetExport, ancestor: UAssetExport) -> bool:
	var ancestor_index := _export_index(asset, ancestor)
	if ancestor_index == 0:
		return false
	var outer_index := child.outer_index
	var guard := 0
	while outer_index > 0 and guard < asset.exports.size():
		if outer_index == ancestor_index:
			return true
		var outer := _resolve_export_ref(asset, outer_index)
		if outer == null:
			return false
		outer_index = outer.outer_index
		guard += 1
	return false


func _append_export_unique(asset: UAssetFile, result: Array[UAssetExport],
		seen: Dictionary, expo: UAssetExport) -> void:
	if expo == null:
		return
	var index := _export_index(asset, expo)
	if index == 0 or seen.has(index):
		return
	seen[index] = true
	result.append(expo)


func _append_export_ref_from_property(asset: UAssetFile, prop: UAssetProperty,
		result: Array[UAssetExport], seen: Dictionary) -> void:
	var expo := _export_from_property_ref(asset, prop)
	if expo != null:
		_append_export_unique(asset, result, seen, expo)


func _append_export_refs_from_array_property(asset: UAssetFile, prop: UAssetProperty,
		result: Array[UAssetExport], seen: Dictionary) -> void:
	if prop == null:
		return
	for child in prop.children:
		var expo := _export_from_property_ref(asset, child)
		if expo != null:
			_append_export_unique(asset, result, seen, expo)

	var raw_value: Variant = prop.raw.get("Value")
	if raw_value is Array:
		for raw_item in raw_value:
			var ref := _object_ref_from_variant(raw_item)
			var expo := _resolve_export_ref(asset, ref)
			if expo != null:
				_append_export_unique(asset, result, seen, expo)


func _export_from_property_ref(asset: UAssetFile, prop: UAssetProperty) -> UAssetExport:
	return _resolve_export_ref(asset, _object_ref_from_property(prop))


func _object_ref_from_property(prop: UAssetProperty) -> int:
	if prop == null:
		return 0
	if prop.value is int or prop.value is float:
		return int(prop.value)
	var raw_ref := _object_ref_from_variant(prop.raw.get("Value"))
	if raw_ref != 0:
		return raw_ref
	if prop.prop_type == "Raw":
		return _object_ref_from_variant(prop.value)
	return 0


func _object_ref_from_variant(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	if value is Dictionary:
		var dict := value as Dictionary
		var raw_value: Variant = dict.get("Value")
		if raw_value is int or raw_value is float:
			return int(raw_value)
	return 0


func _resolve_export_ref(asset: UAssetFile, package_index: int) -> UAssetExport:
	if package_index <= 0 or package_index > asset.exports.size():
		return null
	return asset.exports[package_index - 1]


func _resolve_import_ref(asset: UAssetFile, package_index: int) -> UAssetImport:
	if package_index >= 0:
		return null
	var import_index := (-package_index) - 1
	if import_index < 0 or import_index >= asset.imports.size():
		return null
	return asset.imports[import_index]


func _package_index_label(asset: UAssetFile, package_index: int) -> String:
	if package_index > 0:
		var expo := _resolve_export_ref(asset, package_index)
		return expo.object_name if expo != null else ""
	var imp := _resolve_import_ref(asset, package_index)
	if imp == null:
		return ""
	var package_path := _import_package_path(asset, imp)
	return package_path if not package_path.is_empty() else imp.object_name


func _uasset_path_for_package_index(asset: UAssetFile, package_index: int) -> String:
	var imp := _resolve_import_ref(asset, package_index)
	if imp == null:
		return ""
	var package_path := _import_package_path(asset, imp)
	return _uasset_path_for_package_path(asset, package_path)


func _import_package_path(asset: UAssetFile, imp: UAssetImport) -> String:
	if imp == null:
		return ""
	if imp.object_name.begins_with("/Game/") or imp.object_name.begins_with("/Engine/"):
		return imp.object_name
	if imp.outer_index == 0:
		return ""
	var outer := _resolve_import_ref(asset, imp.outer_index)
	if outer == null:
		return ""
	var outer_path := _import_package_path(asset, outer)
	if outer_path.begins_with("/Game/") or outer_path.begins_with("/Engine/"):
		return outer_path
	return ""


func _uasset_path_for_package_path(asset: UAssetFile, package_path: String) -> String:
	if package_path.is_empty() or package_path.begins_with("/Engine/"):
		return ""
	var current_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	if current_path.is_empty():
		return ""
	var normalized := current_path.replace("\\", "/")
	var marker := "/Content/"
	var marker_index := normalized.find(marker)
	if marker_index < 0:
		return ""
	var content_root := normalized.substr(0, marker_index + marker.length() - 1)
	var relative := package_path
	if relative.begins_with("/Game/"):
		relative = relative.trim_prefix("/Game/")
	elif relative.begins_with("Game/"):
		relative = relative.trim_prefix("Game/")
	else:
		return ""
	return content_root.path_join(relative + ".uasset")


func _export_index(asset: UAssetFile, expo: UAssetExport) -> int:
	for i in asset.exports.size():
		if asset.exports[i] == expo:
			return i + 1
	return 0


func _export_references_index(expo: UAssetExport, package_index: int) -> bool:
	for prop in expo.properties:
		if _property_references_index(prop, package_index):
			return true
	return false


func _property_references_index(prop: UAssetProperty, package_index: int) -> bool:
	if _object_ref_from_property(prop) == package_index:
		return true
	if _raw_value_references_index(prop.raw.get("Value"), package_index):
		return true
	for child in prop.children:
		if _property_references_index(child, package_index):
			return true
	return false


func _raw_value_references_index(value: Variant, package_index: int) -> bool:
	if _object_ref_from_variant(value) == package_index:
		return true
	if value is Dictionary:
		for key in (value as Dictionary).keys():
			if _raw_value_references_index((value as Dictionary)[key], package_index):
				return true
	elif value is Array:
		for child in value:
			if _raw_value_references_index(child, package_index):
				return true
	return false


func _preview_exports_for(asset: UAssetFile, exports: Array[UAssetExport]) -> Array[UAssetExport]:
	var module_exports: Array[UAssetExport] = []
	for expo in exports:
		if not _is_particle_system_export(asset, expo):
			module_exports.append(expo)
	return module_exports if not module_exports.is_empty() else exports


func _restart_preview_emitters() -> void:
	if not is_instance_valid(_preview_root):
		return
	for child in _preview_root.get_children():
		if child is CPUParticles3D:
			(child as CPUParticles3D).restart()
			(child as CPUParticles3D).emitting = true


func _make_preview_particles(spec: Dictionary) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	var is_mesh_particle := bool(spec.get("is_mesh_particle", false))
	particles.set_meta("preview_is_mesh_particle", is_mesh_particle)
	particles.set_meta("preview_scale_max", float(spec.get("scale_max", 0.16)))
	_set_property_if_present(particles, "amount", int(spec.get("amount", 96)))
	_set_property_if_present(particles, "lifetime", float(spec.get("lifetime", 1.2)))
	_set_property_if_present(particles, "preprocess", float(spec.get("lifetime", 1.2)))
	_set_property_if_present(particles, "explosiveness", 0.0)
	_set_property_if_present(particles, "randomness", 0.55)
	_set_property_if_present(particles, "fixed_fps", 30)
	_set_property_if_present(particles, "local_coords", bool(spec.get("local_coords", false)))
	_set_property_if_present(particles, "emitting", true)
	_set_property_if_present(particles, "emission_shape", CPUParticles3D.EMISSION_SHAPE_SPHERE)
	_set_property_if_present(particles, "emission_sphere_radius",
		float(spec.get("emission_radius", 0.08)))
	_set_property_if_present(particles, "direction", spec.get("direction", Vector3.UP))
	_set_property_if_present(particles, "spread", float(spec.get("spread", 45.0)))
	_set_property_if_present(particles, "gravity", spec.get("gravity", Vector3(0, -0.25, 0)))
	_set_property_if_present(particles, "initial_velocity_min", float(spec.get("velocity_min", 0.4)))
	_set_property_if_present(particles, "initial_velocity_max", float(spec.get("velocity_max", 1.2)))
	_set_property_if_present(particles, "scale_amount_min", float(spec.get("scale_min", 0.08)))
	_set_property_if_present(particles, "scale_amount_max", float(spec.get("scale_max", 0.16)))
	_set_property_if_present(particles, "angle_min", float(spec.get("angle_min", 0.0)))
	_set_property_if_present(particles, "angle_max", float(spec.get("angle_max", 0.0)))
	_set_property_if_present(particles, "angular_velocity_min",
		float(spec.get("angular_velocity_min", 0.0)))
	_set_property_if_present(particles, "angular_velocity_max",
		float(spec.get("angular_velocity_max", 0.0)))
	_set_property_if_present(particles, "color", spec.get("color", Color(0.65, 0.82, 1.0, 0.82)))
	var mesh_billboard := _mesh_particle_should_billboard(spec)
	var align_to_velocity := _particle_should_align_to_velocity(spec)
	var rotate_y := _particle_should_rotate_y(spec)
	particles.set_meta("preview_mesh_billboard", mesh_billboard)
	particles.set_meta("preview_align_to_velocity", align_to_velocity)
	particles.set_meta("preview_rotate_y", rotate_y)
	particles.set_meta("preview_screen_alignment", str(spec.get("screen_alignment", "")))
	particles.set_meta("preview_camera_facing_option", str(spec.get("camera_facing_option", "")))
	_set_property_if_present(particles, "particle_flag_align_y", align_to_velocity)
	_set_property_if_present(particles, "particle_flag_rotate_y", rotate_y)
	var preview_mesh := _make_preview_mesh_placeholder(spec) \
		if is_mesh_particle else _make_preview_particle_mesh(spec)
	_set_property_if_present(particles, "mesh", preview_mesh)
	return particles


func _make_preview_particle_mesh(spec: Dictionary) -> Mesh:
	var mesh := QuadMesh.new()
	mesh.size = spec.get("sprite_size", Vector2.ONE)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = spec.get("color", Color(0.65, 0.82, 1.0, 0.82))
	material.albedo_texture = _make_preview_particle_texture()
	mesh.material = material
	return mesh


func _make_preview_particle_texture() -> Texture2D:
	var size := 32
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(float(size - 1) * 0.5, float(size - 1) * 0.5)
	var radius := float(size - 1) * 0.5
	for y in size:
		for x in size:
			var distance := Vector2(float(x), float(y)).distance_to(center) / radius
			var alpha := clampf(1.0 - distance, 0.0, 1.0)
			alpha = pow(alpha, 2.2)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	return ImageTexture.create_from_image(image)


func _make_preview_mesh_placeholder(spec: Dictionary) -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.18
	mesh.height = 0.36
	var material := StandardMaterial3D.new()
	material.albedo_color = spec.get("color", Color(0.95, 0.45, 0.18, 0.9))
	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = 1.5
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _mesh_particle_should_billboard(spec):
		material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mesh.material = material
	return mesh


func _maybe_load_preview_assets(particles: CPUParticles3D, spec: Dictionary) -> void:
	if not is_instance_valid(particles):
		return
	_maybe_load_preview_material_texture(particles, spec)
	_maybe_load_preview_mesh(particles, spec)


func _maybe_load_preview_mesh(particles: CPUParticles3D, spec: Dictionary) -> void:
	var mesh_path := str(spec.get("mesh_path", ""))
	if mesh_path.is_empty():
		return
	particles.set_meta("preview_mesh_path", mesh_path)
	particles.set_meta("preview_mesh_name", str(spec.get("mesh_name", mesh_path.get_file())))

	if not FileAccess.file_exists(mesh_path):
		_set_preview_status("Mesh particle referenced, but file was not found: %s" % mesh_path,
			AppTheme.StatusKind.ERROR)
		return
	var mesh_service := _ctx.mesh_service if _ctx != null else null
	if mesh_service == null or not mesh_service.is_configured():
		_set_preview_status("Mesh particle: configure umodel in Settings to load %s"
			% mesh_path.get_file(), AppTheme.StatusKind.ERROR)
		return

	var cached := mesh_service.get_cached_mesh(mesh_path)
	if not cached.is_empty():
		_apply_preview_mesh_file(particles, cached)
		return

	if _ctx.background_jobs == null:
		_set_preview_status("Mesh particle preview needs the background job service.",
			AppTheme.StatusKind.ERROR)
		return
	_set_preview_status("Loading mesh particle: %s" % mesh_path.get_file(),
		AppTheme.StatusKind.WORKING)
	var job_id := _ctx.background_jobs.run(
		func() -> OperationResult: return mesh_service.get_preview_mesh(mesh_path),
		func(result: OperationResult) -> void: _on_preview_mesh_loaded(particles, result))
	if job_id >= 0:
		_preview_mesh_jobs.append(job_id)


func _on_preview_mesh_loaded(particles: CPUParticles3D, result: OperationResult) -> void:
	if not is_instance_valid(particles):
		return
	var gltf_path := str(result.value) if result.ok else ""
	var error := result.message
	if gltf_path.is_empty():
		_set_preview_status("Failed to load mesh particle%s" % (
			": " + error if not error.is_empty() else ""), AppTheme.StatusKind.ERROR)
		return
	_apply_preview_mesh_file(particles, gltf_path)


func _apply_preview_mesh_file(particles: CPUParticles3D, gltf_path: String) -> void:
	if not FileAccess.file_exists(gltf_path):
		return
	var mesh_result := _load_mesh_resource_from_gltf(gltf_path)
	var mesh := mesh_result.get("mesh") as Mesh
	if mesh == null:
		var error := str(mesh_result.get("error", "Could not read glTF mesh"))
		_set_preview_status(error, AppTheme.StatusKind.ERROR)
		return
	mesh = _orient_loaded_particle_mesh(particles, mesh)
	_configure_loaded_particle_mesh_materials(particles, mesh)
	_set_property_if_present(particles, "mesh", mesh)
	_apply_particle_material_texture_from_meta(particles)
	_include_preview_mesh_bounds(particles, mesh)
	var name := str(particles.get_meta("preview_mesh_name", gltf_path.get_file()))
	_set_preview_status("Loaded mesh particle: %s" % name, AppTheme.StatusKind.SUCCESS)


func _load_mesh_resource_from_gltf(gltf_path: String) -> Dictionary:
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var err := gltf_doc.append_from_file(gltf_path, gltf_state, 0, gltf_path.get_base_dir())
	if err != OK:
		return {"error": "Failed to load particle mesh glTF (error %d)" % err}
	var scene := gltf_doc.generate_scene(gltf_state)
	if scene == null:
		return {"error": "Failed to build particle mesh scene"}
	if _ctx != null and _ctx.mesh_service != null:
		var resource_root := _ctx.mesh_service.get_preview_resource_root(gltf_path)
		MeshPreviewMaterialLoader.apply_to_scene(scene, resource_root)
	var mesh_info := _find_first_mesh_instance_with_transform(scene,
		Transform3D(Basis(), Vector3.ZERO))
	var mesh_instance := mesh_info.get("mesh_instance") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		scene.free()
		return {"error": "Particle mesh export did not contain a mesh"}
	var mesh_transform: Transform3D = mesh_info.get("transform",
		Transform3D(Basis(), Vector3.ZERO))
	var mesh := _duplicate_mesh_with_transform(mesh_instance.mesh, mesh_transform)
	for surface_index in mesh.get_surface_count():
		var material := mesh_instance.get_active_material(surface_index)
		if material != null and mesh.has_method("surface_set_material"):
			mesh.call("surface_set_material", surface_index, material)
	scene.free()
	return {"mesh": mesh}


func _duplicate_mesh_with_transform(mesh: Mesh, transform: Transform3D) -> Mesh:
	var surfaces: Array[Dictionary] = []
	var has_bounds := false
	var bounds := AABB()
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex_index in vertices.size():
			vertices[vertex_index] = transform * vertices[vertex_index]
			if has_bounds:
				bounds = bounds.expand(vertices[vertex_index])
			else:
				bounds = AABB(vertices[vertex_index], Vector3.ZERO)
				has_bounds = true
		arrays[Mesh.ARRAY_VERTEX] = vertices

		var normal_data: Variant = arrays[Mesh.ARRAY_NORMAL]
		if normal_data is PackedVector3Array:
			var normals := normal_data as PackedVector3Array
			for normal_index in normals.size():
				normals[normal_index] = (transform.basis * normals[normal_index]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = normals

		var tangent_data: Variant = arrays[Mesh.ARRAY_TANGENT]
		if tangent_data is PackedFloat32Array:
			var tangents := tangent_data as PackedFloat32Array
			for tangent_index in range(0, tangents.size(), 4):
				var tangent := Vector3(tangents[tangent_index], tangents[tangent_index + 1],
					tangents[tangent_index + 2])
				tangent = (transform.basis * tangent).normalized()
				tangents[tangent_index] = tangent.x
				tangents[tangent_index + 1] = tangent.y
				tangents[tangent_index + 2] = tangent.z
			arrays[Mesh.ARRAY_TANGENT] = tangents

		surfaces.append({
			"arrays": arrays,
			"material": mesh.surface_get_material(surface_index),
			"primitive": mesh.surface_get_primitive_type(surface_index),
		})

	var center := bounds.get_center() if has_bounds else Vector3.ZERO
	var baked := ArrayMesh.new()
	for surface in surfaces:
		var arrays: Array = surface["arrays"]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex_index in vertices.size():
			vertices[vertex_index] -= center
		arrays[Mesh.ARRAY_VERTEX] = vertices
		baked.add_surface_from_arrays(int(surface["primitive"]), arrays)
		baked.surface_set_material(baked.get_surface_count() - 1, surface["material"])
	return baked


func _orient_loaded_particle_mesh(particles: CPUParticles3D, mesh: Mesh) -> Mesh:
	if not bool(particles.get_meta("preview_mesh_billboard", false)):
		return mesh
	var bounds := mesh.get_aabb()
	if not _bounds_are_flat(bounds):
		return mesh

	var basis := Basis()
	var min_axis := _smallest_extent_axis(bounds.size)
	if min_axis == 0:
		basis = Basis(Vector3.UP, -PI * 0.5) * basis
	elif min_axis == 1:
		basis = Basis(Vector3.RIGHT, PI * 0.5) * basis

	if bool(particles.get_meta("preview_align_to_velocity", false)):
		basis = Basis(Vector3.BACK, -PI * 0.5) * basis
	return _duplicate_mesh_with_transform(mesh, Transform3D(basis, Vector3.ZERO))


func _bounds_are_flat(bounds: AABB) -> bool:
	var extents := bounds.size.abs()
	var largest := maxf(maxf(extents.x, extents.y), extents.z)
	if largest <= 0.0001:
		return false
	var smallest := minf(minf(extents.x, extents.y), extents.z)
	return smallest <= largest * 0.08


func _smallest_extent_axis(extents: Vector3) -> int:
	var absolute := extents.abs()
	if absolute.x <= absolute.y and absolute.x <= absolute.z:
		return 0
	if absolute.y <= absolute.z:
		return 1
	return 2


func _configure_loaded_particle_mesh_materials(particles: CPUParticles3D, mesh: Mesh) -> void:
	if mesh == null or not mesh.has_method("surface_set_material"):
		return
	var billboard := bool(particles.get_meta("preview_mesh_billboard", false))
	for surface_index in mesh.get_surface_count():
		var source_material := mesh.surface_get_material(surface_index)
		var material: Material = source_material.duplicate() as Material \
			if source_material != null else StandardMaterial3D.new()
		if material is BaseMaterial3D:
			var base_material := material as BaseMaterial3D
			base_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			if billboard:
				base_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mesh.call("surface_set_material", surface_index, material)


func _include_preview_spec_bounds(particles: CPUParticles3D, spec: Dictionary) -> void:
	var lifetime := float(spec.get("lifetime", 1.2))
	var velocity := float(spec.get("velocity_max", 1.2))
	var scale := float(spec.get("scale_max", 0.16))
	var radius := float(spec.get("emission_radius", 0.08))
	var extent := radius + velocity * lifetime + scale
	if bool(spec.get("is_mesh_particle", false)):
		extent += scale * 2.0
	else:
		var sprite_size: Vector2 = spec.get("sprite_size", Vector2.ONE)
		extent += maxf(sprite_size.x, sprite_size.y) * scale
	extent = clampf(extent, 0.75, 12.0)
	_include_preview_bounds(AABB(particles.position - Vector3.ONE * extent,
		Vector3.ONE * extent * 2.0))


func _include_preview_mesh_bounds(particles: CPUParticles3D, mesh: Mesh) -> void:
	if mesh == null:
		return
	var mesh_bounds := mesh.get_aabb()
	var scale := float(particles.get_meta("preview_scale_max", 1.0))
	var bounds := AABB(
		particles.position + mesh_bounds.position * scale,
		mesh_bounds.size * scale
	)
	_include_preview_visual_bounds(bounds)


func _include_preview_visual_bounds(bounds: AABB) -> void:
	if bounds.size.length_squared() <= 0.0001:
		return
	if _preview_has_visual_bounds:
		_preview_visual_bounds = _preview_visual_bounds.merge(bounds)
	else:
		_preview_visual_bounds = bounds
		_preview_has_visual_bounds = true
	_update_preview_camera()


func _include_preview_bounds(bounds: AABB) -> void:
	if bounds.size.length_squared() <= 0.0001:
		return
	if _preview_has_bounds:
		_preview_bounds = _preview_bounds.merge(bounds)
	else:
		_preview_bounds = bounds
		_preview_has_bounds = true
	_update_preview_camera()


func _update_preview_camera() -> void:
	if not is_instance_valid(_preview_camera) or (not _preview_has_visual_bounds and not _preview_has_bounds):
		return
	var bounds := _preview_visual_bounds if _preview_has_visual_bounds else _preview_bounds
	var center := bounds.get_center()
	var size := maxf(maxf(bounds.size.x, bounds.size.y), bounds.size.z)
	var min_size := 0.9 if _preview_has_visual_bounds else 3.5
	var margin := 1.45 if _preview_has_visual_bounds else 1.35
	_preview_camera.size = clampf(size * margin, min_size, 14.0)
	var direction := Vector3(3.5, 2.0, 4.0).normalized()
	_preview_camera.look_at_from_position(center + direction * 8.0, center, Vector3.UP)


func _find_first_mesh_instance_with_transform(node: Node,
		parent_transform: Transform3D) -> Dictionary:
	if node == null:
		return {}
	var current_transform := parent_transform
	if node is Node3D:
		current_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return {
			"mesh_instance": node,
			"transform": current_transform,
		}
	for child in node.get_children():
		var found := _find_first_mesh_instance_with_transform(child, current_transform)
		if not found.is_empty():
			return found
	return {}


func _maybe_load_preview_material_texture(particles: CPUParticles3D, spec: Dictionary) -> void:
	var material_path := str(spec.get("material_path", ""))
	if material_path.is_empty():
		return
	particles.set_meta("preview_material_name",
		str(spec.get("material_name", material_path.get_file())))
	var applies_to_particle := not bool(spec.get("is_mesh_particle", false)) \
			or bool(spec.get("override_mesh_material", true))
	particles.set_meta("preview_apply_material_override", applies_to_particle)
	if not applies_to_particle:
		return
	if not FileAccess.file_exists(material_path):
		return
	var texture_service := _ctx.texture_service if _ctx != null else null
	if texture_service == null or not texture_service.is_configured():
		_set_preview_status("Material referenced, but texture tools are not configured: %s"
			% material_path.get_file(), AppTheme.StatusKind.ERROR)
		return
	if _ctx.background_jobs == null:
		return
	_set_preview_status("Loading material texture: %s" % material_path.get_file(),
		AppTheme.StatusKind.WORKING)
	var job_id := _ctx.background_jobs.run(
		func() -> OperationResult:
			return _load_material_preview_image(material_path, texture_service),
		func(result: OperationResult) -> void:
			_on_preview_material_texture_loaded(particles, result))
	if job_id >= 0:
		_preview_texture_jobs.append(job_id)


func _load_material_preview_image(material_path: String,
		texture_service: TextureService) -> OperationResult:
	var material_asset := UAssetFile.load_file(material_path)
	if material_asset == null:
		return OperationResult.failed("Could not load material asset")
	var alpha := ParticleMaterialAnalyzer.preview_alpha(material_asset)
	var blend_mode := ParticleMaterialAnalyzer.preview_blend_mode(material_asset)
	var texture_path := _first_texture_path_for_material(material_asset)
	if texture_path.is_empty() or not FileAccess.file_exists(texture_path):
		return OperationResult.failed("No preview texture found", {
			"alpha": alpha,
			"blend_mode": blend_mode,
		})
	var cached := texture_service.get_cached_preview(texture_path)
	var image := Image.load_from_file(cached) if not cached.is_empty() \
			else texture_service.get_preview_image(texture_path)
	if image == null:
		return OperationResult.failed("Could not load preview texture", {
			"texture_path": texture_path,
			"alpha": alpha,
			"blend_mode": blend_mode,
		})
	return OperationResult.succeeded("Loaded preview texture", image, {
		"texture_path": texture_path,
		"alpha": alpha,
		"blend_mode": blend_mode,
	})


func _first_texture_path_for_material(material_asset: UAssetFile) -> String:
	var candidates: Array[String] = []
	for imp in material_asset.imports:
		if imp.class_name_str != "Texture2D" and not imp.object_name.contains("Texture"):
			continue
		var package_path := _import_package_path(material_asset, imp)
		var texture_path := _uasset_path_for_package_path(material_asset, package_path)
		if texture_path.is_empty():
			continue
		candidates.append(texture_path)
	if candidates.is_empty():
		return ""
	candidates.sort_custom(func(a: String, b: String) -> bool:
		return ParticleMaterialAnalyzer.texture_score(a) \
				> ParticleMaterialAnalyzer.texture_score(b)
	)
	return candidates[0]


func _on_preview_material_texture_loaded(particles: CPUParticles3D,
		result: OperationResult) -> void:
	if not is_instance_valid(particles):
		return
	var image := result.value as Image if result.ok else null
	var material_alpha := float(result.metadata.get("alpha", 1.0))
	particles.set_meta("preview_material_alpha", material_alpha)
	particles.set_meta("preview_material_blend_mode",
			str(result.metadata.get("blend_mode", "")))
	if image == null:
		var missing_material_name := str(particles.get_meta("preview_material_name", "material"))
		_set_preview_status("No preview texture found for %s" % missing_material_name,
			AppTheme.StatusKind.ERROR)
		return
	var texture := ImageTexture.create_from_image(image)
	particles.set_meta("preview_material_texture", texture)
	_apply_particle_material_texture_from_meta(particles)
	var loaded_material_name := str(particles.get_meta("preview_material_name", "material"))
	_set_preview_status("Loaded preview texture for %s" % loaded_material_name,
		AppTheme.StatusKind.SUCCESS)


func _apply_particle_material_texture_from_meta(particles: CPUParticles3D) -> void:
	if not bool(particles.get_meta("preview_apply_material_override", true)):
		return
	if not particles.has_meta("preview_material_texture"):
		return
	var texture := particles.get_meta("preview_material_texture") as Texture2D
	if texture == null:
		return
	var mesh := particles.mesh
	if mesh == null:
		return
	var color := particles.color
	color.a = clampf(color.a * float(particles.get_meta("preview_material_alpha", 1.0)), 0.0, 1.0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = _godot_blend_mode_for_preview_material(particles) as BaseMaterial3D.BlendMode
	if not bool(particles.get_meta("preview_is_mesh_particle", false)) \
			or bool(particles.get_meta("preview_mesh_billboard", false)):
		material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	material.albedo_texture = texture
	material.emission_enabled = true
	material.emission = color
	material.emission_texture = texture
	material.emission_energy_multiplier = clampf(color.a, 0.15, 1.0)
	if mesh is PrimitiveMesh:
		(mesh as PrimitiveMesh).material = material
	elif mesh.has_method("surface_set_material"):
		for surface_index in mesh.get_surface_count():
			mesh.call("surface_set_material", surface_index, material)


func _godot_blend_mode_for_preview_material(particles: CPUParticles3D) -> int:
	var blend_mode := str(particles.get_meta("preview_material_blend_mode", "")).to_lower()
	if blend_mode.contains("add"):
		return BaseMaterial3D.BLEND_MODE_ADD
	if blend_mode.contains("modulate"):
		return BaseMaterial3D.BLEND_MODE_MUL
	if not blend_mode.is_empty():
		return BaseMaterial3D.BLEND_MODE_MIX
	return BaseMaterial3D.BLEND_MODE_ADD


func _set_preview_status(text: String, kind: int = AppTheme.StatusKind.IDLE) -> void:
	if is_instance_valid(_preview_status_label):
		_set_status_label(_preview_status_label, text, kind)


func _preview_spec_from_modules(asset: UAssetFile, modules: Array) -> Dictionary:
	var spec := {
		"amount": 24,
		"amount_locked": false,
		"lifetime": 1.2,
		"direction": Vector3.UP,
		"emission_radius": 0.08,
		"spread": 45.0,
		"gravity": Vector3(0, -0.25, 0),
		"velocity_min": 0.4,
		"velocity_max": 1.2,
		"scale_min": 0.08,
		"scale_max": 0.16,
		"sprite_size": Vector2.ONE,
		"color": Color(0.65, 0.82, 1.0, 0.82),
		"screen_alignment": "",
		"axis_lock": "",
		"camera_facing": false,
		"camera_facing_option": "",
	}
	for expo in modules:
		var particle_export := expo as UAssetExport
		if particle_export == null:
			continue
		var module_name := "%s %s" % [
			asset.get_export_class_name(particle_export),
			particle_export.object_name,
		]
		_apply_preview_module(asset, spec, module_name.to_lower(), particle_export)
	return spec


func _apply_preview_module(asset: UAssetFile, spec: Dictionary,
		module_name: String, expo: UAssetExport) -> void:
	var screen_alignment := _string_from_property(expo.find_property("ScreenAlignment"))
	if not screen_alignment.is_empty():
		spec["screen_alignment"] = screen_alignment

	var material_prop := expo.find_property("Material")
	if material_prop != null:
		var material_ref := _object_ref_from_property(material_prop)
		if material_ref != 0:
			spec["material_ref"] = material_ref
			spec["material_name"] = _package_index_label(asset, material_ref)
			spec["material_path"] = _uasset_path_for_package_index(asset, material_ref)

	var mesh_prop := expo.find_property("Mesh")
	if mesh_prop != null:
		var mesh_ref := _object_ref_from_property(mesh_prop)
		if mesh_ref != 0:
			spec["is_mesh_particle"] = true
			spec["mesh_ref"] = mesh_ref
			spec["mesh_name"] = _package_index_label(asset, mesh_ref)
			spec["mesh_path"] = _uasset_path_for_package_index(asset, mesh_ref)
	var override_material := expo.find_property("bOverrideMaterial")
	if override_material != null:
		spec["override_mesh_material"] = _bool_from_property(override_material, true)

	var camera_facing := expo.find_property("bCameraFacing")
	if camera_facing != null:
		spec["camera_facing"] = _bool_from_property(camera_facing, false)
	var face_camera_direction := expo.find_property("bFaceCameraDirectionRatherThanPosition")
	if face_camera_direction != null:
		spec["camera_facing"] = _bool_from_property(face_camera_direction, false)
	var camera_facing_option := _string_from_property(expo.find_property("CameraFacingOption"))
	if not camera_facing_option.is_empty():
		spec["camera_facing_option"] = camera_facing_option
	var axis_lock := _string_from_property(expo.find_property("AxisLockOption"))
	if axis_lock.is_empty():
		axis_lock = _string_from_property(expo.find_property("LockAxisFlags"))
	if not axis_lock.is_empty():
		spec["axis_lock"] = axis_lock

	var peak_active := expo.find_property("PeakActiveParticles")
	if peak_active != null:
		spec["amount"] = clampi(roundi(_float_from_property(peak_active, float(spec["amount"]))), 1, 600)
		spec["amount_locked"] = true

	var local_space := expo.find_property("bUseLocalSpace")
	if local_space != null:
		spec["local_coords"] = _bool_from_property(local_space, false)

	if module_name.contains("spawn"):
		var spawn_rate := _module_float(expo, ["Rate", "SpawnRate"], 24.0)
		var burst_count := _module_burst_count(expo)
		if burst_count > 0:
			spec["amount"] = max(int(spec["amount"]), burst_count)
		var amount := int(clampf(spawn_rate * float(spec["lifetime"]), 12.0, 600.0))
		if not bool(spec.get("amount_locked", false)):
			spec["amount"] = max(int(spec["amount"]), amount)
	elif module_name.contains("lifetime"):
		var lifetime := _module_float(expo, ["Lifetime", "LifeTime"], float(spec["lifetime"]))
		spec["lifetime"] = clampf(lifetime, 0.05, 20.0)
	elif module_name.contains("size"):
		var size_vec := _module_vector(expo, ["StartSize", "Size"], Vector3(12, 12, 12))
		var width := maxf(absf(size_vec.x), 0.01)
		var height := absf(size_vec.y)
		if height <= 0.001:
			height = width
		var dominant := maxf(width, height)
		var divisor := 1.0 if bool(spec.get("is_mesh_particle", false)) else _UE_TO_GODOT_DISTANCE
		var scale := clampf(dominant / divisor, 0.02, 3.5)
		spec["scale_min"] = scale * 0.75
		spec["scale_max"] = scale * 1.25
		if not bool(spec.get("is_mesh_particle", false)):
			spec["sprite_size"] = Vector2(width / dominant, height / dominant)
	elif module_name.contains("velocity"):
		var velocity_vec := _ue_vector_to_godot(_module_vector(
			expo, ["StartVelocity", "Velocity"], Vector3(0, 0, 120)))
		var speed := velocity_vec.length() / _UE_TO_GODOT_DISTANCE
		if speed > 0.001:
			spec["direction"] = velocity_vec.normalized()
			spec["velocity_min"] = clampf(speed * 0.55, 0.05, 20.0)
			spec["velocity_max"] = clampf(speed * 1.25, 0.1, 30.0)
			spec["spread"] = 25.0
	elif module_name.contains("acceleration"):
		var accel := _ue_vector_to_godot(_module_vector(
			expo, ["Acceleration", "StartAcceleration"], Vector3(0, 0, -30)))
		spec["gravity"] = accel / _UE_TO_GODOT_DISTANCE
	elif module_name.contains("meshrotationrate"):
		var mesh_rotation_rate := _module_vector(expo, ["StartRotationRate"], Vector3.ZERO)
		spec["angular_velocity_min"] = mesh_rotation_rate.z * 360.0
		spec["angular_velocity_max"] = mesh_rotation_rate.z * 360.0
	elif module_name.contains("meshrotation"):
		var mesh_rotation := _module_vector(expo, ["StartRotation"], Vector3.ZERO)
		spec["angle_min"] = mesh_rotation.z * 360.0
		spec["angle_max"] = mesh_rotation.z * 360.0
	elif module_name.contains("rotationrate"):
		var rotation_rate := _module_float_range(expo, ["StartRotationRate", "RotationRate"], 0.0)
		spec["angular_velocity_min"] = float(rotation_rate[0]) * 360.0
		spec["angular_velocity_max"] = float(rotation_rate[1]) * 360.0
	elif module_name.contains("rotation"):
		var rotation := _module_float_range(expo, ["StartRotation", "Rotation"], 0.0)
		spec["angle_min"] = float(rotation[0]) * 360.0
		spec["angle_max"] = float(rotation[1]) * 360.0
	elif module_name.contains("location") or module_name.contains("sphere"):
		var radius := _module_float(expo, ["StartRadius", "Radius"], 8.0)
		spec["emission_radius"] = clampf(radius / _UE_TO_GODOT_DISTANCE, 0.02, 5.0)
	elif module_name.contains("color"):
		var color := _module_color(expo, ["StartColor", "Color", "ColorOverLife"],
			spec["color"])
		var alpha := _module_float(expo, ["StartAlpha", "Alpha", "AlphaOverLife"], color.a)
		color.a = clampf(alpha, 0.0, 1.0)
		spec["color"] = color


func _mesh_particle_should_billboard(spec: Dictionary) -> bool:
	if not bool(spec.get("is_mesh_particle", false)):
		return false
	if bool(spec.get("camera_facing", false)):
		return true
	var screen_alignment := str(spec.get("screen_alignment", "")).to_lower()
	var camera_facing_option := str(spec.get("camera_facing_option", "")).to_lower()
	return screen_alignment.contains("camera") \
			or screen_alignment.contains("velocity") \
			or camera_facing_option.contains("camera") \
			or camera_facing_option.contains("velocity")


func _particle_should_align_to_velocity(spec: Dictionary) -> bool:
	var screen_alignment := str(spec.get("screen_alignment", "")).to_lower()
	var camera_facing_option := str(spec.get("camera_facing_option", "")).to_lower()
	return screen_alignment.contains("velocity") \
			or camera_facing_option.contains("velocity")


func _particle_should_rotate_y(spec: Dictionary) -> bool:
	return str(spec.get("axis_lock", "")).to_lower().contains("rotate_y")


func _string_from_property(prop: UAssetProperty) -> String:
	if prop == null:
		return ""
	if prop.value != null:
		return str(prop.value)
	if prop.raw.has("EnumValue"):
		return str(prop.raw.get("EnumValue", ""))
	if prop.raw.has("Value") and prop.raw.get("Value") != null:
		return str(prop.raw.get("Value"))
	return ""


func _bool_from_property(prop: UAssetProperty, fallback: bool) -> bool:
	if prop == null or prop.value == null:
		return fallback
	if prop.value is bool:
		return bool(prop.value)
	var text := str(prop.value).strip_edges().to_lower()
	if text in ["true", "1", "yes"]:
		return true
	if text in ["false", "0", "no"]:
		return false
	return fallback


func _module_float(expo: UAssetExport, names: Array[String], fallback: float) -> float:
	for name in names:
		var prop := expo.find_property(name)
		if prop != null:
			return _float_from_property(prop, fallback)
	for prop in expo.properties:
		if prop.prop_type == "Struct" and _is_distribution_type(prop.struct_type):
			return _float_from_property(prop, fallback)
	return fallback


func _module_float_range(expo: UAssetExport, names: Array[String], fallback: float) -> Array[float]:
	for name in names:
		var prop := expo.find_property(name)
		if prop != null:
			return _float_range_from_property(prop, fallback)
	for prop in expo.properties:
		if prop.prop_type == "Struct" and _is_distribution_type(prop.struct_type):
			return _float_range_from_property(prop, fallback)
	return [fallback, fallback]


func _module_burst_count(expo: UAssetExport) -> int:
	var burst := expo.find_property("BurstList")
	if burst == null:
		return 0
	return _burst_count_from_property(burst)


func _burst_count_from_property(prop: UAssetProperty) -> int:
	var total := 0
	if prop.prop_name == "Count":
		total += maxi(0, roundi(_float_from_property(prop, 0.0)))
	for child in prop.children:
		total += _burst_count_from_property(child)
	return total


func _module_vector(expo: UAssetExport, names: Array[String], fallback: Vector3) -> Vector3:
	for name in names:
		var prop := expo.find_property(name)
		if prop != null:
			return _vector_from_distribution(prop, fallback)
	for prop in expo.properties:
		var found := _vector_from_distribution(prop, Vector3.INF)
		if found != Vector3.INF:
			return found
	return fallback


func _module_color(expo: UAssetExport, names: Array[String], fallback: Color) -> Color:
	for name in names:
		var prop := expo.find_property(name)
		if prop != null:
			return _color_from_any_property(prop, fallback)
	for prop in expo.properties:
		var color := _color_from_any_property(prop, Color(-1, -1, -1, -1))
		if color.r >= 0.0:
			return color
	return fallback


func _float_from_property(prop: UAssetProperty, fallback: float) -> float:
	if prop.value is int or prop.value is float or (prop.value is String and str(prop.value).is_valid_float()):
		return _float_variant(prop.value, fallback)
	var range_values := _float_range_from_property(prop, INF)
	if not is_inf(float(range_values[0])) and not is_inf(float(range_values[1])):
		return (float(range_values[0]) + float(range_values[1])) * 0.5
	var values: Array[float] = []
	_collect_numeric_values(prop, values)
	if values.is_empty():
		return fallback
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _float_range_from_property(prop: UAssetProperty, fallback: float) -> Array[float]:
	if prop == null:
		return [fallback, fallback]
	if prop.value is int or prop.value is float or prop.value is String:
		var value := _float_variant(prop.value, fallback)
		return [value, value]
	var min_child := prop.find_child("MinValue")
	var max_child := prop.find_child("MaxValue")
	if min_child != null or max_child != null:
		var min_value := _float_from_property(min_child, fallback) if min_child != null else fallback
		var max_value := _float_from_property(max_child, min_value) if max_child != null else min_value
		return [min_value, max_value]
	return [fallback, fallback]


func _collect_numeric_values(prop: UAssetProperty, values: Array[float]) -> void:
	if prop.value is int or prop.value is float:
		values.append(float(prop.value))
	elif prop.value is String and str(prop.value).is_valid_float():
		values.append(float(prop.value))
	for child in prop.children:
		if child.prop_name in ["Distribution", "Table"]:
			continue
		_collect_numeric_values(child, values)


func _vector_from_distribution(prop: UAssetProperty, fallback: Vector3) -> Vector3:
	if PropertyRow.is_vector_struct(prop):
		return _vector_from_property(prop, fallback)
	if prop.prop_type != "Struct":
		return fallback
	var min_child := prop.find_child("MinValueVec")
	var max_child := prop.find_child("MaxValueVec")
	if min_child != null and max_child != null:
		return (_vector_from_property(min_child, fallback) + _vector_from_property(max_child, fallback)) * 0.5
	for child in prop.children:
		if PropertyRow.is_vector_struct(child):
			return _vector_from_property(child, fallback)
	return fallback


func _vector_from_property(prop: UAssetProperty, fallback: Vector3) -> Vector3:
	var value: Variant = prop.value if prop.value is Dictionary else prop.raw.get("Value")
	if value is Dictionary:
		var dict := value as Dictionary
		var from_dict := _vector_from_dictionary(dict, fallback)
		if from_dict != Vector3.INF:
			return from_dict
	if value is Array:
		for item in value:
			var from_item := _vector_from_variant(item, Vector3.INF)
			if from_item != Vector3.INF:
				return from_item
	var x := prop.find_child("X")
	var y := prop.find_child("Y")
	var z := prop.find_child("Z")
	if x != null and y != null and z != null:
		return Vector3(
			_float_variant(x.value, fallback.x),
			_float_variant(y.value, fallback.y),
			_float_variant(z.value, fallback.z)
		)
	for child in prop.children:
		var from_child := _vector_from_property(child, Vector3.INF)
		if from_child != Vector3.INF:
			return from_child
	return fallback


func _vector_from_variant(value: Variant, fallback: Vector3) -> Vector3:
	if value is Dictionary:
		return _vector_from_dictionary(value as Dictionary, fallback)
	if value is Array:
		for item in value:
			var from_item := _vector_from_variant(item, Vector3.INF)
			if from_item != Vector3.INF:
				return from_item
	return fallback


func _vector_from_dictionary(dict: Dictionary, fallback: Vector3) -> Vector3:
	if dict.has("X") and dict.has("Y") and dict.has("Z"):
		return Vector3(
			_float_variant(dict.get("X"), fallback.x),
			_float_variant(dict.get("Y"), fallback.y),
			_float_variant(dict.get("Z"), fallback.z)
		)
	var nested: Variant = dict.get("Value")
	if nested != null:
		return _vector_from_variant(nested, fallback)
	return fallback


func _color_from_any_property(prop: UAssetProperty, fallback: Color) -> Color:
	if PropertyRow.is_color_struct(prop):
		return _color_from_color_property(prop, fallback)
	var vector := _vector_from_distribution(prop, Vector3.INF)
	if vector != Vector3.INF:
		return Color(clampf(vector.x, 0.0, 1.0), clampf(vector.y, 0.0, 1.0),
			clampf(vector.z, 0.0, 1.0), fallback.a)
	for child in prop.children:
		var color := _color_from_any_property(child, Color(-1, -1, -1, -1))
		if color.r >= 0.0:
			return color
	return fallback


func _color_from_color_property(prop: UAssetProperty, fallback: Color) -> Color:
	var value: Variant = prop.value if prop.value is Dictionary else prop.raw.get("Value")
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(
			_float_variant(dict.get("R"), fallback.r),
			_float_variant(dict.get("G"), fallback.g),
			_float_variant(dict.get("B"), fallback.b),
			_float_variant(dict.get("A"), fallback.a)
		)
	var r := prop.find_child("R")
	var g := prop.find_child("G")
	var b := prop.find_child("B")
	var a := prop.find_child("A")
	if r != null and g != null and b != null:
		return Color(
			_float_variant(r.value, fallback.r),
			_float_variant(g.value, fallback.g),
			_float_variant(b.value, fallback.b),
			_float_variant(a.value, fallback.a) if a != null else fallback.a
		)
	return fallback


func _float_variant(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		return float(value)
	if value is String:
		var text := str(value).strip_edges()
		if text.begins_with("+"):
			text = text.substr(1)
		if text.is_valid_float():
			return float(text)
	return fallback


func _ue_vector_to_godot(value: Vector3) -> Vector3:
	return Vector3(value.x, value.z, -value.y)


func _set_property_if_present(object: Object, property_name: StringName, value: Variant) -> void:
	for property in object.get_property_list():
		if StringName(str(property.get("name"))) == property_name:
			object.set(property_name, value)
			return
