class_name UmgCanvas extends Control

signal widget_selected(index: int)
signal widget_moved(index: int, delta: Vector2)

const DESIGN_SIZE := Vector2(1920, 1080)

var model: UmgDesignerModel
var root_index := -1
var selected_index := -1
var rects: Dictionary = {}
var clip_rects: Dictionary = {}
var order: Array[int] = []
var _drag_start := Vector2.ZERO
var _drag_total := Vector2.ZERO
var _dragging := false
var zoom := 1.0
var pan := Vector2.ZERO
var _panning := false
var _design_rect := Rect2()
var _draw_scale := 1.0
var brush_textures: Dictionary = {} # /Game package -> Texture2D
var _flipped_textures: Dictionary = {} # widget index -> mirrored Texture2D

const VIEW_MARGIN := 64.0


func _ready() -> void:
	custom_minimum_size = Vector2(720, 405)
	# Custom draw commands are otherwise allowed to spill outside this Control,
	# painting the panned artboard over the hierarchy, toolbar, and inspector.
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	queue_redraw()
	resized.connect(func() -> void:
		_clamp_pan()
		queue_redraw())


func show_tree(source: UmgDesignerModel, new_root: int) -> void:
	model = source
	root_index = new_root
	selected_index = -1
	queue_redraw()


func select_widget(index: int) -> void:
	selected_index = index
	queue_redraw()


func set_brush_textures(textures: Dictionary) -> void:
	brush_textures = textures
	_flipped_textures.clear()
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("10151d"), true)
	if model == null or root_index < 0:
		return
	var scale_factor := minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y) * zoom
	_draw_scale = scale_factor
	var origin := (size - DESIGN_SIZE * scale_factor) * 0.5 + pan
	var screen_rect := Rect2(origin, DESIGN_SIZE * scale_factor)
	_design_rect = screen_rect
	draw_rect(screen_rect, Color("151b24"), true)
	draw_rect(screen_rect, Color("65758b"), false, 1.0)
	rects.clear()
	clip_rects.clear()
	order.clear()
	_layout_node(root_index, screen_rect, screen_rect, scale_factor, 0)
	for index in order:
		var rect: Rect2 = rects[index]
		var clip_rect: Rect2 = clip_rects.get(index, screen_rect)
		var item := model.node(index)
		var selected := index == selected_index
		var widget_class := str(item["class"])
		var is_container := _is_container(widget_class)
		if not is_container:
			_draw_widget(index, rect, clip_rect, widget_class)
		elif selected:
			draw_rect(rect.intersection(clip_rect), Color(0.15, 0.55, 0.95, 0.06), true)
		if selected:
			draw_rect(rect, Color("42b8ff"), false, 2.0)
			_draw_handles(rect)


func _draw_widget(index: int, rect: Rect2, clip_rect: Rect2, widget_class: String) -> void:
	var visible_rect := rect.intersection(clip_rect)
	if visible_rect.size.x <= 0 or visible_rect.size.y <= 0:
		return
	if widget_class.contains("Spacer"):
		return
	if widget_class.contains("Text"):
		var content := model.display_text(index)
		if content.is_empty():
			content = "<%s>" % str(model.node(index)["name"])
		var style := model.text_style(index)
		var font_size := maxi(6, int(style["size"] * _draw_scale))
		var max_lines := maxi(1, int(visible_rect.size.y / maxf(font_size + 2, 1)))
		draw_multiline_string(get_theme_default_font(), visible_rect.position + Vector2(4, font_size),
				content, style["alignment"], maxf(0, visible_rect.size.x - 8), font_size,
				max_lines, model.widget_color(index))
		return
	var brush := model.brush_resource(index)
	if not brush.is_empty() and brush_textures.has(brush["package_path"]):
		var texture: Texture2D = brush_textures[brush["package_path"]]
		_draw_brush(index, texture, rect, clip_rect, brush, model.widget_color(index))
		return
	var color := Color(0.18, 0.35, 0.5, 0.32)
	if widget_class.contains("Button"):
		color = Color(0.12, 0.43, 0.68, 0.48)
	elif widget_class.contains("Image"):
		color = Color(0.32, 0.37, 0.44, 0.32)
	color *= model.widget_color(index)
	draw_rect(visible_rect, color, true)
	draw_rect(visible_rect, Color(0.55, 0.7, 0.82, 0.35), false, 1.0)


func _draw_brush(index: int, texture: Texture2D, rect: Rect2, clip_rect: Rect2,
		brush: Dictionary, tint: Color) -> void:
	var visible_rect := rect.intersection(clip_rect)
	if visible_rect.size.x <= 0 or visible_rect.size.y <= 0:
		return
	texture = _texture_for_render(index, texture)
	var draw_as := str(brush.get("draw_as", "Image"))
	if draw_as in ["Box", "Border"]:
		var margins: Vector4 = brush.get("margin", Vector4.ZERO)
		var style := StyleBoxTexture.new()
		style.texture = texture
		style.texture_margin_left = texture.get_width() * margins.x
		style.texture_margin_top = texture.get_height() * margins.y
		style.texture_margin_right = texture.get_width() * margins.z
		style.texture_margin_bottom = texture.get_height() * margins.w
		style.draw_center = draw_as == "Box"
		style.modulate_color = tint
		# Nine-slice decorations normally stay inside their own geometry. If an
		# ancestor clips them, constrain the command to that visible geometry.
		draw_style_box(style, visible_rect)
		return

	# Plain Image brushes use their cooked ImageSize as the desired aspect.
	# Fit inside the allocated Slate geometry rather than deforming the artwork.
	var intrinsic: Vector2 = brush.get("image_size", Vector2.ZERO)
	if intrinsic.x <= 0 or intrinsic.y <= 0:
		intrinsic = texture.get_size()
	var scale_factor := minf(rect.size.x / intrinsic.x, rect.size.y / intrinsic.y)
	var fitted_size := intrinsic * scale_factor
	var fitted := Rect2(rect.position + (rect.size - fitted_size) * 0.5, fitted_size)
	var clipped := fitted.intersection(clip_rect)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	var normalized_position := (clipped.position - fitted.position) / fitted.size
	var normalized_size := clipped.size / fitted.size
	var uv_position := normalized_position * texture.get_size()
	var uv_size := normalized_size * texture.get_size()
	draw_texture_rect_region(texture, clipped, Rect2(uv_position, uv_size), tint)


func _texture_for_render(index: int, source: Texture2D) -> Texture2D:
	var render_scale: Vector2 = model.render_transform(index)["scale"]
	if render_scale.x >= 0.0 and render_scale.y >= 0.0:
		return source
	if _flipped_textures.has(index):
		return _flipped_textures[index]
	var flipped := source.get_image().duplicate()
	if render_scale.x < 0.0:
		flipped.flip_x()
	if render_scale.y < 0.0:
		flipped.flip_y()
	var result := ImageTexture.create_from_image(flipped)
	_flipped_textures[index] = result
	return result


func _draw_handles(rect: Rect2) -> void:
	for point in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)]:
		draw_rect(Rect2(point - Vector2(3, 3), Vector2(6, 6)), Color("e9f7ff"), true)


static func _is_container(widget_class: String) -> bool:
	return widget_class.contains("Panel") or widget_class.contains("Box") \
			or widget_class.contains("Overlay") or widget_class.contains("Switcher") \
			or widget_class.contains("Canvas") or widget_class.contains("ScaleBox") \
			or widget_class.contains("SizeBox")


func _layout_node(index: int, rect: Rect2, inherited_clip: Rect2,
		scale_factor: float, depth: int) -> void:
	if depth > 128 or rect.size.x < 1 or rect.size.y < 1:
		return
	rects[index] = rect
	clip_rects[index] = inherited_clip
	order.append(index)
	var item := model.node(index)
	if item.is_empty():
		return
	var children: Array = model.preview_children(index)
	var child_clip := inherited_clip.intersection(rect) \
			if model.clips_children(index) else inherited_clip
	for child_position in children.size():
		var child_index: int = children[child_position]
		var child_rect := rect
		var layout := model.canvas_layout(child_index)
		if bool(layout["valid"]):
			var amin: Vector2 = layout["anchor_min"]
			var amax: Vector2 = layout["anchor_max"]
			var start := rect.position + rect.size * amin + Vector2(layout["left"], layout["top"]) * scale_factor
			var child_size: Vector2
			if amin.is_equal_approx(amax):
				child_size = Vector2(maxf(8, absf(layout["right"]) * scale_factor),
						maxf(8, absf(layout["bottom"]) * scale_factor))
			else:
				var finish := rect.position + rect.size * amax + Vector2(layout["right"], layout["bottom"]) * scale_factor
				child_size = Vector2(maxf(8, finish.x - start.x), maxf(8, finish.y - start.y))
			child_rect = Rect2(start, child_size)
		elif str(item["class"]).contains("VerticalBox") and not children.is_empty():
			child_rect = _stack_child_rect(children, child_position, rect, scale_factor, true)
		elif str(item["class"]).contains("HorizontalBox") and not children.is_empty():
			child_rect = _stack_child_rect(children, child_position, rect, scale_factor, false)
		if not bool(layout["valid"]):
			child_rect = _apply_slot_alignment(child_index, child_rect, scale_factor)
			if str(item["class"]).contains("ScaleBox"):
				child_rect = _fit_desired_aspect(child_index, child_rect, scale_factor)
		child_rect = _apply_render_transform(child_index, child_rect, scale_factor)
		_layout_node(child_index, child_rect, child_clip, scale_factor, depth + 1)


func _stack_child_rect(children: Array, wanted: int, parent_rect: Rect2,
		scale_factor: float, vertical: bool) -> Rect2:
	var available := parent_rect.size.y if vertical else parent_rect.size.x
	var fixed := 0.0
	var fill_count := 0
	for child_index: int in children:
		var info := model.slot_info(child_index)
		var padding: Vector4 = info["padding"]
		var axis_padding := (padding.y + padding.w) if vertical else (padding.x + padding.z)
		if info["size_rule"] == "Fill":
			fill_count += 1
		else:
			var desired := model.desired_size(child_index) * scale_factor
			fixed += (desired.y if vertical else desired.x) + axis_padding * scale_factor
	var fill_size := maxf(0.0, available - fixed) / maxf(1, fill_count)
	var cursor := 0.0
	for child_position in children.size():
		var child_index: int = children[child_position]
		var info := model.slot_info(child_index)
		var padding: Vector4 = info["padding"]
		var axis_padding := (padding.y + padding.w) if vertical else (padding.x + padding.z)
		var desired := model.desired_size(child_index) * scale_factor
		var extent := fill_size if info["size_rule"] == "Fill" \
				else (desired.y if vertical else desired.x) + axis_padding * scale_factor
		if extent <= 0:
			extent = available / maxf(1, children.size())
		if child_position == wanted:
			return Rect2(parent_rect.position + (Vector2(0, cursor) if vertical else Vector2(cursor, 0)),
					Vector2(parent_rect.size.x, extent) if vertical else Vector2(extent, parent_rect.size.y))
		cursor += extent
	return parent_rect


func _apply_slot_alignment(index: int, allocated: Rect2, scale_factor: float) -> Rect2:
	var desired := model.desired_size(index) * scale_factor
	var info := model.slot_info(index)
	var padding: Vector4 = info["padding"]
	var result := Rect2(allocated.position + Vector2(padding.x, padding.y) * scale_factor,
			allocated.size - Vector2(padding.x + padding.z, padding.y + padding.w) * scale_factor)
	result.size.x = maxf(0, result.size.x)
	result.size.y = maxf(0, result.size.y)
	if desired.x > 0 and info["horizontal"] != "Fill":
		var padded_width := result.size.x
		result.size.x = minf(desired.x, padded_width)
		if info["horizontal"] == "Center":
			result.position.x += (padded_width - result.size.x) * 0.5
		elif info["horizontal"] == "Right":
			result.position.x += padded_width - result.size.x
	if desired.y > 0 and info["vertical"] != "Fill":
		var padded_height := result.size.y
		result.size.y = minf(desired.y, padded_height)
		if info["vertical"] == "Center":
			result.position.y += (padded_height - result.size.y) * 0.5
		elif info["vertical"] == "Bottom":
			result.position.y += padded_height - result.size.y
	return result


func _fit_desired_aspect(index: int, allocated: Rect2, scale_factor: float) -> Rect2:
	var desired := model.desired_size(index) * scale_factor
	if desired.x <= 0 or desired.y <= 0 or allocated.size.x <= 0 or allocated.size.y <= 0:
		return allocated
	var fit := minf(allocated.size.x / desired.x, allocated.size.y / desired.y)
	var fitted_size := desired * fit
	return Rect2(allocated.position + (allocated.size - fitted_size) * 0.5, fitted_size)


func _apply_render_transform(index: int, source: Rect2, scale_factor: float) -> Rect2:
	var transform := model.render_transform(index)
	var render_scale: Vector2 = transform["scale"]
	var pivot: Vector2 = transform["pivot"]
	var pivot_point := source.position + source.size * pivot
	var transformed_size := source.size * Vector2(absf(render_scale.x), absf(render_scale.y))
	var transformed_position := pivot_point - transformed_size * pivot \
			+ (transform["translation"] as Vector2) * scale_factor
	return Rect2(transformed_position, transformed_size)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(event.position, minf(4.0, zoom * 1.12))
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(event.position, maxf(0.25, zoom / 1.12))
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			selected_index = _hit_test(event.position)
			widget_selected.emit(selected_index)
			_drag_start = event.position
			_drag_total = Vector2.ZERO
			_dragging = selected_index >= 0 and bool(model.canvas_layout(selected_index)["valid"])
			queue_redraw()
		elif _dragging:
			_dragging = false
			if not _drag_total.is_zero_approx():
				widget_moved.emit(selected_index, _drag_total)
	elif event is InputEventMouseMotion and _panning:
		pan += event.relative
		_clamp_pan()
		queue_redraw()
	elif event is InputEventMouseMotion and _dragging:
		var scale_factor := minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y) * zoom
		var screen_delta := _clamp_move_delta(selected_index, event.relative)
		var design_delta: Vector2 = screen_delta / scale_factor
		if model.move_canvas_widget(selected_index, design_delta):
			_drag_total += design_delta
			queue_redraw()
	elif event is InputEventMouseMotion:
		var hover_index := _hit_test(event.position)
		if hover_index >= 0:
			var hover_data := model.node(hover_index)
			tooltip_text = "%s · %s · export #%d" % [hover_data["name"],
					hover_data["class"], hover_index + 1]
		else:
			tooltip_text = ""


func _zoom_at(cursor: Vector2, new_zoom: float) -> void:
	if is_equal_approx(new_zoom, zoom):
		return
	var fit_scale := minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	var old_scale := fit_scale * zoom
	var old_origin := (size - DESIGN_SIZE * old_scale) * 0.5 + pan
	var design_point := (cursor - old_origin) / old_scale
	zoom = new_zoom
	var new_scale := fit_scale * zoom
	var desired_origin := cursor - design_point * new_scale
	pan = desired_origin - (size - DESIGN_SIZE * new_scale) * 0.5
	_clamp_pan()
	queue_redraw()


func _clamp_pan() -> void:
	var fit_scale := minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	var scaled_size := DESIGN_SIZE * fit_scale * zoom
	var centered := (size - scaled_size) * 0.5
	var min_pan := Vector2(VIEW_MARGIN - scaled_size.x, VIEW_MARGIN - scaled_size.y) - centered
	var max_pan := Vector2(size.x - VIEW_MARGIN, size.y - VIEW_MARGIN) - centered
	pan.x = clampf(pan.x, min_pan.x, max_pan.x)
	pan.y = clampf(pan.y, min_pan.y, max_pan.y)


func _clamp_move_delta(index: int, requested: Vector2) -> Vector2:
	if not rects.has(index):
		return Vector2.ZERO
	var child_rect: Rect2 = rects[index]
	var data := model.node(index)
	var parent_index := int(data.get("parent_index", -1))
	var bounds: Rect2 = rects.get(parent_index, _design_rect)
	var result := requested
	if child_rect.size.x <= bounds.size.x:
		result.x = clampf(result.x, bounds.position.x - child_rect.position.x,
				bounds.end.x - child_rect.end.x)
	else:
		result.x = 0.0
	if child_rect.size.y <= bounds.size.y:
		result.y = clampf(result.y, bounds.position.y - child_rect.position.y,
				bounds.end.y - child_rect.end.y)
	else:
		result.y = 0.0
	return result


func _hit_test(point: Vector2) -> int:
	for order_index in range(order.size() - 1, -1, -1):
		var index := order[order_index]
		if (rects[index] as Rect2).has_point(point):
			return index
	return -1
