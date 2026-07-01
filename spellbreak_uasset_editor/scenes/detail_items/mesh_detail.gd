class_name MeshDetail extends DetailItem

## Detail view for a StaticMesh / SkeletalMesh export: 3D preview viewport with
## orbit camera, export button, and standard export metadata below.  Mesh is
## extracted asynchronously via MeshService (umodel → glTF → GLTFDocument).
## Pattern mirrors TextureDetail / SoundDetail.

var _expo: UAssetExport
var _class_name: String

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _resize_handle: Button
var _camera: Camera3D
var _mesh_root: Node3D
var _loading_label: Label
var _export_btn: Button
var _refresh_btn: Button
var _feedback: OperationFeedback
var _last_operation: Callable
var _extract_job_id := -1
var _animation_job_id := -1

var _animation_player: AnimationPlayer
var _preview_scene: Node3D
var _preview_skeleton: Skeleton3D
var _anim_auto_btn: Button
var _anim_load_btn: Button
var _anim_asset_selector: OptionButton
var _anim_selector: OptionButton
var _anim_play_btn: Button
var _anim_stop_btn: Button
var _anim_loop_check: CheckBox
var _anim_speed_spin: SpinBox
var _anim_slider: HSlider
var _anim_time_label: Label
var _anim_status_label: Label
var _anim_timer: Timer
var _anim_asset_paths: Array[String] = []
var _anim_paths: Array[String] = []
var _auto_animation_candidates: Array[String] = []
var _auto_animation_index := 0
var _auto_animation_active := false
var _anim_duration := 0.0
var _anim_loaded := false
var _anim_slider_updating := false

# Orbit camera state
var _orbit_yaw: float = PI / 4
var _orbit_pitch: float = -PI / 6
var _orbit_distance: float = 5.0
var _orbit_target: Vector3 = Vector3.ZERO
var _orbiting: bool = false
var _panning: bool = false
var _resizing_preview: bool = false

const DEFAULT_PREVIEW_HEIGHT := 384.0
const MIN_PREVIEW_HEIGHT := 200.0
const MAX_PREVIEW_HEIGHT := 1200.0
static var _saved_preview_height := DEFAULT_PREVIEW_HEIGHT


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
	AppTheme.style_header(hdr_label)
	hdr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hdr_label)
	_container.add_child(hdr)

	_add_type_badge(_class_name)
	_add_separator()

	# ── Mesh preview section ─────────────────────────────────────────────────
	_add_section_label("MESH PREVIEW")

	var mesh_service := _ctx.mesh_service

	if mesh_service == null or not mesh_service.is_configured():
		_add_info("umodel not configured. Set the path in Settings to enable 3D mesh preview.")
	else:
		# Loading label
		_loading_label = _add_status_label(
			"Extracting mesh...", AppTheme.StatusKind.WORKING, AppTheme.FONT_STATUS)

		# 3D viewport
		_viewport_container = SubViewportContainer.new()
		_viewport_container.custom_minimum_size = Vector2(0, _saved_preview_height)
		_viewport_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Manual sizing keeps the render target sharp as the preview is resized.
		_viewport_container.stretch = false
		_viewport_container.visible = false
		_viewport_container.gui_input.connect(_on_viewport_gui_input)
		_viewport_container.resized.connect(_sync_viewport_size)

		_viewport = SubViewport.new()
		_viewport.own_world_3d = true
		_viewport.transparent_bg = false
		_viewport.size = Vector2i(512, 384)
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

		var scene_root := Node3D.new()

		# Camera
		_camera = Camera3D.new()
		_camera.current = true
		scene_root.add_child(_camera)

		_add_preview_environment(scene_root)

		# Mesh placeholder — loaded content goes here
		_mesh_root = Node3D.new()
		scene_root.add_child(_mesh_root)

		_viewport.add_child(scene_root)
		_viewport_container.add_child(_viewport)
		_container.add_child(_viewport_container)

		_resize_handle = Button.new()
		_resize_handle.text = "Resize preview"
		_resize_handle.flat = true
		_resize_handle.custom_minimum_size.y = 18
		_resize_handle.mouse_default_cursor_shape = Control.CURSOR_VSIZE
		_resize_handle.tooltip_text = "Drag vertically to resize. Double-click to reset."
		_resize_handle.visible = false
		_resize_handle.gui_input.connect(_on_resize_handle_input)
		_container.add_child(_resize_handle)

		# Set initial camera position
		_update_camera()

		# Start extracting mesh
		_load_mesh_async(mesh_service)

	_add_separator()

	if _class_name == "SkeletalMesh":
		_build_animation_controls()
		if _preview_scene != null:
			_set_animation_controls_ready(_preview_skeleton != null)
		_add_separator()

	# ── Mesh actions ─────────────────────────────────────────────────────────
	_add_section_label("MESH ACTIONS")

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	_export_btn = Button.new()
	_export_btn.text = "Export as GLB..."
	_export_btn.pressed.connect(_on_export_pressed)
	btn_row.add_child(_export_btn)

	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh Preview"
	_refresh_btn.tooltip_text = "Re-export the mesh preview and reload material textures."
	_refresh_btn.pressed.connect(_on_refresh_preview_pressed)
	btn_row.add_child(_refresh_btn)

	_container.add_child(btn_row)

	if mesh_service == null or not mesh_service.is_configured():
		_export_btn.disabled = true
		_export_btn.tooltip_text = "umodel not configured"
		_refresh_btn.disabled = true
		_refresh_btn.tooltip_text = "umodel not configured"

	_feedback = OperationFeedback.new().setup(_retry_last_operation)
	_container.add_child(_feedback)

	_add_separator()

	# ── Standard export detail (references, properties, dependencies) ────────
	_add_section_label("REFERENCES")
	_add_field_editor("ObjectName", expo.object_name, func(v):
		expo.object_name = v
		expo.raw["ObjectName"] = v,
		func(v): hdr_label.text = "Export: %s" % v)
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
	var uasset_path := _get_mesh_uasset_path()
	if not uasset_path.ends_with(".uasset"):
		_set_status_label(_loading_label, "Mesh preview requires a .uasset file (not JSON)",
			AppTheme.StatusKind.ERROR)
		return

	# Check cache first
	var cached := mesh_service.get_cached_mesh(uasset_path)
	if not cached.is_empty():
		_on_mesh_file_ready(cached)
		return

	if _ctx.background_jobs == null:
		_set_status_label(_loading_label, "Background job service is unavailable",
			AppTheme.StatusKind.ERROR)
		return
	_extract_job_id = _ctx.background_jobs.run(
		func() -> Array: return mesh_service.get_preview_mesh(uasset_path),
		_on_mesh_job_finished)
	if _extract_job_id < 0:
		_set_status_label(_loading_label, "Could not start mesh extraction job",
			AppTheme.StatusKind.ERROR)
		if is_instance_valid(_refresh_btn):
			_refresh_btn.disabled = false


func _on_mesh_job_finished(result: Array) -> void:
	_on_mesh_extracted(str(result[0]), str(result[1]))


func _on_mesh_extracted(gltf_path: String, error: String) -> void:
	_extract_job_id = -1
	if not gltf_path.is_empty():
		_on_mesh_file_ready(gltf_path)
	else:
		var msg := "Failed to extract mesh"
		if not error.is_empty():
			msg += ": " + error
		_set_status_label(_loading_label, msg, AppTheme.StatusKind.ERROR)
		if is_instance_valid(_refresh_btn):
			_refresh_btn.disabled = false


func dispose() -> void:
	if _extract_job_id >= 0 and _ctx.background_jobs:
		_ctx.background_jobs.cancel(_extract_job_id)
		_extract_job_id = -1
	if _animation_job_id >= 0 and _ctx.background_jobs:
		_ctx.background_jobs.cancel(_animation_job_id)
		_animation_job_id = -1
	_stop_animation_preview()


func _on_mesh_file_ready(gltf_path: String) -> void:
	if not is_instance_valid(_viewport):
		return

	# Load glTF into the viewport
	var gltf_doc := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var err := gltf_doc.append_from_file(gltf_path, gltf_state)
	if err != OK:
		_set_status_label(_loading_label, "Failed to load glTF (error %d)" % err,
			AppTheme.StatusKind.ERROR)
		return

	var scene := gltf_doc.generate_scene(gltf_state)
	if scene == null:
		_set_status_label(_loading_label, "Failed to generate scene from glTF",
			AppTheme.StatusKind.ERROR)
		return

	var mesh_service := _ctx.mesh_service
	var resource_root := mesh_service.get_preview_resource_root(gltf_path)
	var material_result := MeshPreviewMaterialLoader.apply_to_scene(scene, resource_root)

	# Clear any previous mesh and add the new one
	_stop_animation_preview()
	_set_animation_loaded(false)
	_auto_animation_active = false
	_auto_animation_candidates.clear()
	_auto_animation_index = 0
	_anim_asset_paths.clear()
	_anim_paths.clear()
	if is_instance_valid(_anim_asset_selector):
		_anim_asset_selector.clear()
	if is_instance_valid(_anim_selector):
		_anim_selector.clear()
	_preview_scene = null
	_preview_skeleton = null
	_animation_player = null
	for child in _mesh_root.get_children():
		child.queue_free()
	_mesh_root.add_child(scene)
	_preview_scene = scene
	_preview_skeleton = _find_skeleton(scene)
	if _preview_skeleton != null:
		_animation_player = AnimationPlayer.new()
		_animation_player.name = "AnimationPreviewPlayer"
		_animation_player.root_node = NodePath("..")
		_animation_player.animation_finished.connect(_on_animation_finished)
		scene.add_child(_animation_player)

	# Auto-frame the camera to fit the mesh
	# Need to wait one frame for transforms to update
	_auto_frame.call_deferred(scene)

	# Show the viewport
	if is_instance_valid(_viewport_container):
		_viewport_container.visible = true
		_sync_viewport_size.call_deferred()
	if is_instance_valid(_resize_handle):
		_resize_handle.visible = true
	if is_instance_valid(_loading_label):
		var material_count := int(material_result["applied"])
		var status := "Left drag: orbit | Middle drag: pan | Scroll: zoom"
		if material_count > 0:
			status += " | %d textured material(s)" % material_count
		_set_status_label(_loading_label, status, AppTheme.StatusKind.SUCCESS)
	if is_instance_valid(_refresh_btn):
		_refresh_btn.disabled = false
	_set_animation_controls_ready(_preview_skeleton != null)


func _get_mesh_uasset_path() -> String:
	var asset := _ctx.get_asset()
	return asset.binary_path if not asset.binary_path.is_empty() else asset.file_path


func _add_preview_environment(scene_root: Node3D) -> void:
	var sky_color := Color(0.385, 0.454, 0.55)
	var ground_color := Color(0.2, 0.169, 0.133)
	var horizon_color := sky_color.lerp(ground_color, 0.5)
	var horizon_luminance := horizon_color.get_luminance() * 3.333
	horizon_color = horizon_color.lerp(
		Color(horizon_luminance, horizon_luminance, horizon_luminance), 0.5)

	var sky_material := ProceduralSkyMaterial.new()
	sky_material.energy_multiplier = 1.0
	sky_material.sky_top_color = sky_color
	sky_material.sky_horizon_color = horizon_color
	sky_material.ground_bottom_color = ground_color
	sky_material.ground_horizon_color = horizon_color

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ssao_enabled = false
	env.sdfgi_enabled = false
	env.glow_enabled = (
		RenderingServer.get_current_rendering_method() not in ["gl_compatibility", "dummy"])
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	scene_root.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-60.0), deg_to_rad(150.0), 0.0)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 100.0
	scene_root.add_child(sun)


# ── Animation preview ────────────────────────────────────────────────────────


func _build_animation_controls() -> void:
	_add_section_label("ANIMATION PREVIEW")

	_anim_status_label = _add_status_label("Load the skeletal mesh preview first.")

	var load_row := HBoxContainer.new()
	load_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	_anim_auto_btn = Button.new()
	_anim_auto_btn.text = "Auto Load"
	_anim_auto_btn.disabled = true
	_anim_auto_btn.tooltip_text = "Find likely animation assets and load the first compatible one."
	_anim_auto_btn.pressed.connect(_on_auto_animation_pressed)
	load_row.add_child(_anim_auto_btn)
	_anim_load_btn = Button.new()
	_anim_load_btn.text = "Browse..."
	_anim_load_btn.disabled = true
	_anim_load_btn.pressed.connect(_on_load_animation_pressed)
	load_row.add_child(_anim_load_btn)
	_anim_asset_selector = OptionButton.new()
	_anim_asset_selector.disabled = true
	_anim_asset_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_asset_selector.item_selected.connect(_on_animation_asset_selected)
	load_row.add_child(_anim_asset_selector)
	_container.add_child(load_row)

	var track_row := HBoxContainer.new()
	track_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var track_label := Label.new()
	track_label.text = "Track"
	AppTheme.style_dim(track_label)
	track_row.add_child(track_label)
	_anim_selector = OptionButton.new()
	_anim_selector.disabled = true
	_anim_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_selector.item_selected.connect(_on_animation_selected)
	track_row.add_child(_anim_selector)
	_container.add_child(track_row)

	var playback_row := HBoxContainer.new()
	playback_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	_anim_play_btn = Button.new()
	_anim_play_btn.text = "Play"
	_anim_play_btn.disabled = true
	_anim_play_btn.pressed.connect(_on_anim_play_pressed)
	playback_row.add_child(_anim_play_btn)
	_anim_stop_btn = Button.new()
	_anim_stop_btn.text = "Stop"
	_anim_stop_btn.disabled = true
	_anim_stop_btn.pressed.connect(_on_anim_stop_pressed)
	playback_row.add_child(_anim_stop_btn)
	_anim_loop_check = CheckBox.new()
	_anim_loop_check.text = "Loop"
	_anim_loop_check.button_pressed = true
	_anim_loop_check.disabled = true
	_anim_loop_check.toggled.connect(_on_anim_loop_toggled)
	playback_row.add_child(_anim_loop_check)
	var speed_label := Label.new()
	speed_label.text = "Speed"
	AppTheme.style_dim(speed_label)
	playback_row.add_child(speed_label)
	_anim_speed_spin = SpinBox.new()
	_anim_speed_spin.min_value = 0.1
	_anim_speed_spin.max_value = 4.0
	_anim_speed_spin.step = 0.1
	_anim_speed_spin.value = 1.0
	_anim_speed_spin.custom_minimum_size.x = 80
	_anim_speed_spin.editable = false
	_anim_speed_spin.value_changed.connect(_on_anim_speed_changed)
	playback_row.add_child(_anim_speed_spin)
	_container.add_child(playback_row)

	var seek_row := HBoxContainer.new()
	seek_row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	_anim_slider = HSlider.new()
	_anim_slider.min_value = 0.0
	_anim_slider.max_value = 1.0
	_anim_slider.step = 0.001
	_anim_slider.editable = false
	_anim_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_slider.value_changed.connect(_on_anim_slider_changed)
	seek_row.add_child(_anim_slider)
	_anim_time_label = Label.new()
	_anim_time_label.text = "0.00 / 0.00"
	_anim_time_label.custom_minimum_size.x = 92
	_anim_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	AppTheme.style_dim(_anim_time_label)
	seek_row.add_child(_anim_time_label)
	_container.add_child(seek_row)

	_anim_timer = Timer.new()
	_anim_timer.wait_time = 0.05
	_anim_timer.timeout.connect(_refresh_animation_time)
	_container.add_child(_anim_timer)


func _set_animation_controls_ready(is_ready: bool) -> void:
	if not is_instance_valid(_anim_load_btn):
		return
	if is_instance_valid(_anim_auto_btn):
		_anim_auto_btn.disabled = not is_ready
	_anim_load_btn.disabled = not is_ready
	if is_ready:
		_set_anim_status("Use Auto Load to find a compatible animation, or Browse for an AnimSequence .uasset.", false)
	else:
		_auto_animation_active = false
		_auto_animation_candidates.clear()
		_auto_animation_index = 0
		_set_animation_loaded(false)
		_anim_asset_paths.clear()
		_anim_paths.clear()
		if is_instance_valid(_anim_asset_selector):
			_anim_asset_selector.clear()
		if is_instance_valid(_anim_selector):
			_anim_selector.clear()
		_set_anim_status("No compatible skeleton found in this mesh preview.", true)


func _on_auto_animation_pressed() -> void:
	if _animation_player == null or _preview_skeleton == null:
		_set_anim_status("Load the skeletal mesh preview first.", true)
		return
	var mesh_service := _ctx.mesh_service
	if mesh_service == null:
		_set_anim_status("Mesh service is unavailable.", true)
		return
	var asset := _ctx.get_asset()
	var mesh_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	var candidates := mesh_service.find_animation_assets_for_mesh(mesh_path)
	_set_animation_asset_candidates(candidates)
	if candidates.is_empty():
		_set_anim_status("No likely animation assets found near this mesh or configured sources.", true)
		return

	_auto_animation_candidates.clear()
	var limit := mini(24, candidates.size())
	for index in limit:
		_auto_animation_candidates.append(candidates[index])
	_auto_animation_index = 0
	_auto_animation_active = true
	_set_anim_status("Trying animation 1/%d: %s" % [
		_auto_animation_candidates.size(), _animation_display_name(_auto_animation_candidates[0])],
		false, AppTheme.StatusKind.WORKING)
	_load_animation_asset_async(_auto_animation_candidates[0])


func _set_animation_asset_candidates(paths: Array[String]) -> void:
	_anim_asset_paths.clear()
	if is_instance_valid(_anim_asset_selector):
		_anim_asset_selector.clear()
	for path in paths:
		_anim_asset_paths.append(path)
		if is_instance_valid(_anim_asset_selector):
			_anim_asset_selector.add_item(_animation_display_name(path))
	if is_instance_valid(_anim_asset_selector):
		_anim_asset_selector.disabled = _anim_asset_paths.is_empty()
		if not _anim_asset_paths.is_empty():
			_anim_asset_selector.select(0)


func _on_animation_asset_selected(index: int) -> void:
	if index < 0 or index >= _anim_asset_paths.size():
		return
	_auto_animation_active = false
	_load_animation_asset_async(_anim_asset_paths[index])


func _try_next_auto_animation(reason: String = "") -> void:
	_auto_animation_index += 1
	if _auto_animation_index >= _auto_animation_candidates.size():
		_auto_animation_active = false
		var message := "No compatible animation found in the first %d candidate(s)." % _auto_animation_candidates.size()
		if not reason.is_empty():
			message += " Last error: " + reason
		_set_anim_status(message, true)
		return
	if is_instance_valid(_anim_asset_selector):
		_anim_asset_selector.select(_auto_animation_index)
	var path := _auto_animation_candidates[_auto_animation_index]
	_set_anim_status("Trying animation %d/%d: %s" % [
		_auto_animation_index + 1,
		_auto_animation_candidates.size(),
		_animation_display_name(path),
	], false, AppTheme.StatusKind.WORKING)
	_load_animation_asset_async(path)


func _animation_display_name(path: String) -> String:
	return "%s/%s" % [path.get_base_dir().get_file(), path.get_file().get_basename()]


func _on_load_animation_pressed() -> void:
	if _animation_player == null or _preview_skeleton == null:
		_set_anim_status("Load the skeletal mesh preview first.", true)
		return
	_auto_animation_active = false
	var asset := _ctx.get_asset()
	var base_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.uasset ; Unreal animation asset"])
	AppTheme.configure_file_dialog(dialog)
	dialog.current_dir = base_path.get_base_dir()
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_set_animation_asset_candidates([path])
		_load_animation_asset_async(path)
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(900, 650))


func _load_animation_asset_async(path: String) -> void:
	var mesh_service := _ctx.mesh_service
	if mesh_service == null or not FileAccess.file_exists(path):
		_set_anim_status("Animation file not found.", true)
		return
	if _ctx.background_jobs == null:
		_set_anim_status("Background job service is unavailable.", true)
		return
	if _animation_job_id >= 0:
		_ctx.background_jobs.cancel(_animation_job_id)
	_set_animation_loaded(false)
	_anim_paths.clear()
	_anim_selector.clear()
	_set_anim_status("Extracting animation...", false, AppTheme.StatusKind.WORKING)
	_animation_job_id = _ctx.background_jobs.run(
		func() -> Array: return mesh_service.get_preview_animations(path),
		func(result: Array) -> void: _on_animation_job_finished(path, result))


func _on_animation_job_finished(source_path: String, result: Array) -> void:
	_animation_job_id = -1
	var paths: Array = result[0] if result.size() > 0 and result[0] is Array else []
	var error := str(result[1]) if result.size() > 1 else ""
	if paths.is_empty():
		if _auto_animation_active:
			_try_next_auto_animation(error)
			return
		var msg := "Failed to extract animation"
		if not error.is_empty():
			msg += ": " + error
		_set_anim_status(msg, true)
		return

	_anim_paths.clear()
	_anim_selector.clear()
	for path in paths:
		_anim_paths.append(str(path))
		_anim_selector.add_item(str(path).get_file().get_basename())
	_anim_selector.disabled = _anim_paths.size() <= 1
	_set_anim_status("Loaded %d animation track(s) from %s." % [
		_anim_paths.size(), source_path.get_file()], false)
	for index in _anim_paths.size():
		if _load_md5_animation(_anim_paths[index]):
			if is_instance_valid(_anim_selector):
				_anim_selector.select(index)
			_auto_animation_active = false
			return
	if _auto_animation_active:
		_try_next_auto_animation("Extracted animation did not match this skeleton.")


func _on_animation_selected(index: int) -> void:
	if index < 0 or index >= _anim_paths.size():
		return
	_auto_animation_active = false
	_load_md5_animation(_anim_paths[index])


func _load_md5_animation(md5_path: String) -> bool:
	if _animation_player == null or _preview_skeleton == null or _preview_scene == null:
		_set_anim_status("Animation preview is not ready.", true)
		return false
	var parsed := Md5AnimLoader.parse_file(md5_path)
	if not bool(parsed.get("ok", false)):
		_set_anim_status(str(parsed.get("error", "Failed to parse animation")), true)
		return false
	var built := Md5AnimLoader.build_animation(parsed, _preview_skeleton, _preview_scene,
		_anim_loop_check.button_pressed)
	if not bool(built.get("ok", false)):
		_set_anim_status(str(built.get("error", "Animation is incompatible with this mesh")), true)
		return false

	_stop_animation_preview()
	_reset_preview_skeleton_pose()
	if _animation_player.has_animation_library(StringName()):
		_animation_player.remove_animation_library(StringName())
	var library := AnimationLibrary.new()
	library.add_animation(Md5AnimLoader.ANIMATION_NAME, built["animation"])
	_animation_player.add_animation_library(StringName(), library)
	_animation_player.speed_scale = float(_anim_speed_spin.value)
	_anim_duration = float(built["duration"])
	_set_animation_loaded(true)
	_animation_player.play(Md5AnimLoader.ANIMATION_NAME)
	_animation_player.pause()
	_animation_player.seek(0.0, true)
	_refresh_animation_time()

	var missing: Array = built.get("missing_bones", [])
	var status := "Animation ready: %d frame(s), %.2f fps, %d/%d mesh bone(s) animated." % [
		int(built["frame_count"]),
		float(built["frame_rate"]),
		int(built["animated_bones"]),
		int(built.get("target_bone_count", _preview_skeleton.get_bone_count())),
	]
	if bool(built.get("flattened_hierarchy", false)):
		status += " Flattened source skeleton normalized (%s rotations)." % str(
			built.get("rotation_mode", "local"))
	if not missing.is_empty():
		status += " %d source-only bone(s) ignored." % missing.size()
	_set_anim_status(status, false, AppTheme.StatusKind.SUCCESS)
	return true


func _set_animation_loaded(loaded: bool) -> void:
	_anim_loaded = loaded
	if not loaded:
		_anim_duration = 0.0
	if is_instance_valid(_anim_play_btn):
		_anim_play_btn.disabled = not loaded
		_anim_play_btn.text = "Play"
	if is_instance_valid(_anim_stop_btn):
		_anim_stop_btn.disabled = not loaded
	if is_instance_valid(_anim_loop_check):
		_anim_loop_check.disabled = not loaded
	if is_instance_valid(_anim_speed_spin):
		_anim_speed_spin.editable = loaded
	if is_instance_valid(_anim_slider):
		_anim_slider.editable = loaded
		_anim_slider.max_value = maxf(_anim_duration, 0.001)
		_set_slider_value(0.0)
	if is_instance_valid(_anim_time_label) and not loaded:
		_anim_time_label.text = "0.00 / 0.00"


func _on_anim_play_pressed() -> void:
	if not _anim_loaded or _animation_player == null:
		return
	if _animation_player.is_playing():
		_animation_player.pause()
		_anim_play_btn.text = "Play"
		if _anim_timer:
			_anim_timer.stop()
	else:
		_animation_player.speed_scale = float(_anim_speed_spin.value)
		_animation_player.play(Md5AnimLoader.ANIMATION_NAME)
		_anim_play_btn.text = "Pause"
		if _anim_timer:
			_anim_timer.start()


func _on_anim_stop_pressed() -> void:
	_stop_animation_preview()
	_refresh_animation_time()


func _stop_animation_preview() -> void:
	if _animation_player:
		_animation_player.stop(false)
		_animation_player.seek(0.0, true)
	if is_instance_valid(_anim_play_btn):
		_anim_play_btn.text = "Play"
	if _anim_timer:
		_anim_timer.stop()
	_set_slider_value(0.0)


func _reset_preview_skeleton_pose() -> void:
	if is_instance_valid(_preview_skeleton):
		_preview_skeleton.reset_bone_poses()


func _on_anim_loop_toggled(enabled: bool) -> void:
	if _animation_player == null or not _animation_player.has_animation(Md5AnimLoader.ANIMATION_NAME):
		return
	var library := _animation_player.get_animation_library(StringName())
	var animation := library.get_animation(Md5AnimLoader.ANIMATION_NAME)
	animation.loop_mode = Animation.LOOP_LINEAR if enabled else Animation.LOOP_NONE


func _on_anim_speed_changed(value: float) -> void:
	if _animation_player:
		_animation_player.speed_scale = value


func _on_anim_slider_changed(value: float) -> void:
	if _anim_slider_updating or not _anim_loaded or _animation_player == null:
		return
	_animation_player.seek(value, true)
	_refresh_animation_time()


func _on_animation_finished(_animation_name: StringName) -> void:
	if not is_instance_valid(_anim_loop_check) or _anim_loop_check.button_pressed:
		return
	if is_instance_valid(_anim_play_btn):
		_anim_play_btn.text = "Play"
	if _anim_timer:
		_anim_timer.stop()
	_refresh_animation_time()


func _refresh_animation_time() -> void:
	var position := 0.0
	if _animation_player:
		position = _animation_player.current_animation_position
	_set_slider_value(position)
	if is_instance_valid(_anim_time_label):
		_anim_time_label.text = "%.2f / %.2f" % [position, _anim_duration]


func _set_slider_value(value: float) -> void:
	if not is_instance_valid(_anim_slider):
		return
	_anim_slider_updating = true
	_anim_slider.value = clampf(value, 0.0, maxf(_anim_duration, 0.001))
	_anim_slider_updating = false


func _set_anim_status(message: String, is_error: bool,
		kind: int = AppTheme.StatusKind.IDLE) -> void:
	if is_error:
		kind = AppTheme.StatusKind.ERROR
	_set_status_label(_anim_status_label, message,
		kind)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


# ── Orbit camera ─────────────────────────────────────────────────────────────


func _on_resize_handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			_set_preview_height(DEFAULT_PREVIEW_HEIGHT)
			_resizing_preview = false
		else:
			_resizing_preview = event.pressed
		_resize_handle.accept_event()
	elif event is InputEventMouseMotion and _resizing_preview:
		_set_preview_height(_saved_preview_height + event.relative.y)
		_resize_handle.accept_event()


func _set_preview_height(height: float) -> void:
	_saved_preview_height = clampf(height, MIN_PREVIEW_HEIGHT, MAX_PREVIEW_HEIGHT)
	if is_instance_valid(_viewport_container):
		_viewport_container.custom_minimum_size.y = _saved_preview_height
		_sync_viewport_size.call_deferred()


func _sync_viewport_size() -> void:
	if not is_instance_valid(_viewport) or not is_instance_valid(_viewport_container):
		return
	var target_size := Vector2i(
		maxi(1, roundi(_viewport_container.size.x)),
		maxi(1, roundi(_viewport_container.size.y)))
	if _viewport.size != target_size:
		_viewport.size = target_size


func _on_viewport_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_orbiting = event.pressed
				_viewport_container.accept_event()
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
				_viewport_container.accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				_orbit_distance = max(0.5, _orbit_distance * 0.9)
				_update_camera()
				_viewport_container.accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				_orbit_distance = min(100.0, _orbit_distance * 1.1)
				_update_camera()
				_viewport_container.accept_event()
	elif event is InputEventMouseMotion:
		if _panning:
			_pan_camera(event.relative)
			_viewport_container.accept_event()
		elif _orbiting:
			_orbit_yaw -= event.relative.x * 0.005
			_orbit_pitch = clamp(_orbit_pitch - event.relative.y * 0.005,
				-PI / 2 + 0.1, PI / 2 - 0.1)
			_update_camera()
			_viewport_container.accept_event()


func _pan_camera(relative: Vector2) -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_viewport_container):
		return
	var viewport_height := maxf(_viewport_container.size.y, 1.0)
	var visible_height := 2.0 * tan(deg_to_rad(_camera.fov) * 0.5) * _orbit_distance
	var units_per_pixel := visible_height / viewport_height
	var camera_right := _camera.global_transform.basis.x.normalized()
	var camera_up := _camera.global_transform.basis.y.normalized()
	_orbit_target += (-camera_right * relative.x + camera_up * relative.y) * units_per_pixel
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


# ── Refresh action ───────────────────────────────────────────────────────────


func _on_refresh_preview_pressed() -> void:
	var mesh_service := _ctx.mesh_service
	if mesh_service == null or not mesh_service.is_configured():
		return
	var uasset_path := _get_mesh_uasset_path()
	if not uasset_path.ends_with(".uasset"):
		_set_status_label(_loading_label, "Mesh preview requires a .uasset file (not JSON)",
			AppTheme.StatusKind.ERROR)
		return
	if _extract_job_id >= 0 and _ctx.background_jobs:
		_ctx.background_jobs.cancel(_extract_job_id)
		_extract_job_id = -1
	mesh_service.clear_cached_mesh(uasset_path)
	if is_instance_valid(_refresh_btn):
		_refresh_btn.disabled = true
	_set_status_label(_loading_label, "Refreshing mesh preview...", AppTheme.StatusKind.WORKING)
	_load_mesh_async(mesh_service)


# ── Export action ────────────────────────────────────────────────────────────


func _on_export_pressed() -> void:
	var mesh_service := _ctx.mesh_service
	if mesh_service == null or mesh_service.is_busy():
		return

	var uasset_path := _get_mesh_uasset_path()

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	AppTheme.configure_file_dialog(dialog)
	dialog.dir_selected.connect(func(path: String) -> void:
		_run_mesh_export(uasset_path, path)
		dialog.queue_free()
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _run_mesh_export(uasset_path: String, output_dir: String) -> void:
	var mesh_service := _ctx.mesh_service
	if mesh_service == null or mesh_service.is_busy():
		return
	_last_operation = func() -> void: _run_mesh_export(uasset_path, output_dir)
	_start_feedback("Mesh export", [
		["Source", uasset_path],
		["Output folder", output_dir],
	])
	if is_instance_valid(_export_btn):
		_export_btn.disabled = true
	mesh_service.operation_finished.connect(_on_export_finished, CONNECT_ONE_SHOT)
	mesh_service.export_glb(uasset_path, output_dir)


func _on_export_finished(success: bool, message: String) -> void:
	_finish_feedback(success, message)
	if is_instance_valid(_export_btn):
		_export_btn.disabled = false


func _retry_last_operation() -> void:
	if _last_operation.is_valid():
		_last_operation.call()


func _start_feedback(title: String, paths: Array) -> void:
	if not is_instance_valid(_feedback):
		return
	_feedback.clear_log()
	_feedback.set_busy("%s..." % title)
	_feedback.add_line(title)
	for pair in paths:
		if pair is Array and pair.size() >= 2:
			_feedback.add_path(str(pair[0]), str(pair[1]))


func _finish_feedback(success: bool, message: String) -> void:
	if not is_instance_valid(_feedback):
		return
	_feedback.add_line("Result: %s" % message)
	_feedback.set_result(success, message)
