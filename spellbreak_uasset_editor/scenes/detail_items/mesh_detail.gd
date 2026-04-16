class_name MeshDetail extends DetailItem

## Detail view for a StaticMesh / SkeletalMesh export: 3D preview viewport with
## orbit camera, export button, and standard export metadata below.  Mesh is
## extracted asynchronously via MeshService (umodel → glTF → GLTFDocument).
## Pattern mirrors TextureDetail / SoundDetail.

var _expo: UAssetExport
var _class_name: String

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _camera: Camera3D
var _mesh_root: Node3D
var _loading_label: Label
var _export_btn: Button
var _status_label: Label
var _extract_thread: Thread

# Orbit camera state
var _orbit_yaw: float = PI / 4
var _orbit_pitch: float = -PI / 6
var _orbit_distance: float = 5.0
var _orbit_target: Vector3 = Vector3.ZERO
var _dragging: bool = false


func init_data(expo: UAssetExport, cls_name: String) -> MeshDetail:
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

	# ── Mesh preview section ─────────────────────────────────────────────────
	_add_section_label("MESH PREVIEW")

	var mesh_service: MeshService = _ctx.get("mesh_service")

	if mesh_service == null or not mesh_service.is_configured():
		_add_info("umodel not configured. Set the path in Settings to enable 3D mesh preview.")
	else:
		# Loading label
		_loading_label = Label.new()
		_loading_label.text = "Extracting mesh..."
		_loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_loading_label.add_theme_font_size_override("font_size", 13)
		_container.add_child(_loading_label)

		# 3D viewport
		_viewport_container = SubViewportContainer.new()
		_viewport_container.custom_minimum_size = Vector2(512, 384)
		_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_viewport_container.stretch = true
		_viewport_container.visible = false
		_viewport_container.gui_input.connect(_on_viewport_gui_input)

		_viewport = SubViewport.new()
		_viewport.own_world_3d = true
		_viewport.transparent_bg = true
		_viewport.size = Vector2i(512, 384)
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

		var scene_root := Node3D.new()

		# Camera
		_camera = Camera3D.new()
		_camera.current = true
		scene_root.add_child(_camera)

		# Lighting — two directional lights for balanced shading
		var light := DirectionalLight3D.new()
		light.rotation = Vector3(deg_to_rad(-45), deg_to_rad(45), 0)
		light.light_energy = 0.8
		scene_root.add_child(light)

		var fill_light := DirectionalLight3D.new()
		fill_light.rotation = Vector3(deg_to_rad(-30), deg_to_rad(-120), 0)
		fill_light.light_energy = 0.3
		scene_root.add_child(fill_light)

		# Environment (ambient light so the mesh isn't pitch-dark on unlit sides)
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.15, 0.15, 0.18)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.3, 0.3, 0.35)
		env.ambient_light_energy = 0.5
		var world_env := WorldEnvironment.new()
		world_env.environment = env
		scene_root.add_child(world_env)

		# Mesh placeholder — loaded content goes here
		_mesh_root = Node3D.new()
		scene_root.add_child(_mesh_root)

		_viewport.add_child(scene_root)
		_viewport_container.add_child(_viewport)
		_container.add_child(_viewport_container)

		# Set initial camera position
		_update_camera()

		# Start extracting mesh
		_load_mesh_async(mesh_service)

	_add_separator()

	# ── Mesh actions ─────────────────────────────────────────────────────────
	_add_section_label("MESH ACTIONS")

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)

	_export_btn = Button.new()
	_export_btn.text = "Export as glTF..."
	_export_btn.pressed.connect(_on_export_pressed)
	btn_row.add_child(_export_btn)

	_container.add_child(btn_row)

	if mesh_service == null or not mesh_service.is_configured():
		_export_btn.disabled = true
		_export_btn.tooltip_text = "umodel not configured"

	# Status label
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_container.add_child(_status_label)

	_add_separator()

	# ── Standard export detail (references, properties, dependencies) ────────
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


# ── Mesh loading ─────────────────────────────────────────────────────────────


func _load_mesh_async(mesh_service: MeshService) -> void:
	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	if not uasset_path.ends_with(".uasset"):
		_loading_label.text = "Mesh preview requires a .uasset file (not JSON)"
		return

	# Check cache first
	var cached := mesh_service.get_cached_mesh(uasset_path)
	if not cached.is_empty():
		_on_mesh_file_ready(cached)
		return

	# Extract in background thread
	_extract_thread = Thread.new()
	_extract_thread.start(_extract_worker.bind(mesh_service, uasset_path))


func _extract_worker(mesh_service: MeshService, uasset_path: String) -> void:
	var result := mesh_service.get_preview_mesh(uasset_path)
	call_deferred("_on_mesh_extracted", result[0], result[1])


func _on_mesh_extracted(gltf_path: String, error: String) -> void:
	if _extract_thread:
		_extract_thread.wait_to_finish()
		_extract_thread = null
	if not gltf_path.is_empty():
		_on_mesh_file_ready(gltf_path)
	else:
		if is_instance_valid(_loading_label):
			var msg := "Failed to extract mesh"
			if not error.is_empty():
				msg += ": " + error
			_loading_label.text = msg
			_loading_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))


func _on_mesh_file_ready(gltf_path: String) -> void:
	if not is_instance_valid(_viewport):
		return

	# Load glTF into the viewport
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var err := gltf_doc.append_from_file(gltf_path, gltf_state)
	if err != OK:
		if is_instance_valid(_loading_label):
			_loading_label.text = "Failed to load glTF (error %d)" % err
			_loading_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		return

	var scene := gltf_doc.generate_scene(gltf_state)
	if scene == null:
		if is_instance_valid(_loading_label):
			_loading_label.text = "Failed to generate scene from glTF"
			_loading_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		return

	# Clear any previous mesh and add the new one
	for child in _mesh_root.get_children():
		child.queue_free()
	_mesh_root.add_child(scene)

	# Auto-frame the camera to fit the mesh
	# Need to wait one frame for transforms to update
	_auto_frame.call_deferred(scene)

	# Show the viewport
	if is_instance_valid(_viewport_container):
		_viewport_container.visible = true
	if is_instance_valid(_loading_label):
		_loading_label.text = "Drag to orbit, scroll to zoom"
		_loading_label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))


# ── Orbit camera ─────────────────────────────────────────────────────────────


func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_orbit_distance = max(0.5, _orbit_distance * 0.9)
				_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				_orbit_distance = min(100.0, _orbit_distance * 1.1)
				_update_camera()
	elif event is InputEventMouseMotion and _dragging:
		_orbit_yaw -= event.relative.x * 0.005
		_orbit_pitch = clamp(_orbit_pitch - event.relative.y * 0.005, -PI / 2 + 0.1, PI / 2 - 0.1)
		_update_camera()


func _update_camera() -> void:
	if not is_instance_valid(_camera):
		return
	var offset := Vector3(
		sin(_orbit_yaw) * cos(_orbit_pitch),
		sin(_orbit_pitch),
		cos(_orbit_yaw) * cos(_orbit_pitch)
	) * _orbit_distance
	_camera.position = _orbit_target + offset
	_camera.look_at(_orbit_target, Vector3.UP)


# ── Auto-framing ────────────────────────────────────────────────────────────


func _auto_frame(node: Node3D) -> void:
	var aabb := _get_combined_aabb(node)
	_orbit_target = aabb.get_center()
	_orbit_distance = aabb.size.length() * 1.5
	if _orbit_distance < 1.0:
		_orbit_distance = 5.0
	_update_camera()


func _get_combined_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var first := true
	for child in _get_all_mesh_instances(node):
		var mesh_aabb := child.get_aabb()
		mesh_aabb = child.global_transform * mesh_aabb
		if first:
			aabb = mesh_aabb
			first = false
		else:
			aabb = aabb.merge(mesh_aabb)
	if first:
		aabb = AABB(Vector3.ZERO, Vector3.ONE)
	return aabb


func _get_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_get_all_mesh_instances(child))
	return result


# ── Export action ────────────────────────────────────────────────────────────


func _on_export_pressed() -> void:
	var mesh_service: MeshService = _ctx.get("mesh_service")
	if mesh_service == null or mesh_service.is_busy():
		return

	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.dir_selected.connect(func(path: String) -> void:
		_status_label.text = "Exporting..."
		_export_btn.disabled = true
		mesh_service.operation_finished.connect(_on_export_finished, CONNECT_ONE_SHOT)
		mesh_service.export_gltf(uasset_path, path)
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


# ── Shared helpers (duplicated from TextureDetail for self-containment) ──────


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
