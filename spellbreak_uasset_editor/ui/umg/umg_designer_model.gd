class_name UmgDesignerModel extends RefCounted

## Interprets cooked UMG exports as widget trees. Unlike OuterIndex ownership,
## visual parentage is encoded by UPanelSlot Parent/Content references.

var asset: UAssetFile
var widget_trees: Array[Dictionary] = []
var nodes: Dictionary = {} # export index (zero based) -> node
var _tree_root_by_owner: Dictionary = {}
var _tree_roots_by_identity: Dictionary = {}
var _visual_children_cache: Dictionary = {}
var _preview_children_cache: Dictionary = {}
var _desired_size_cache: Dictionary = {}
var _brush_cache: Dictionary = {}
var _slot_cache: Dictionary = {}
var _canvas_layout_cache: Dictionary = {}
var _render_transform_cache: Dictionary = {}


static func create(source: UAssetFile) -> UmgDesignerModel:
	var model := UmgDesignerModel.new()
	model.asset = source
	model._parse()
	return model


static func supports(source: UAssetFile) -> bool:
	for expo in source.exports:
		if source.get_export_class_name(expo) == "WidgetTree":
			return true
	return false


func _parse() -> void:
	for i in asset.exports.size():
		var expo := asset.exports[i]
		var resolved_class := asset.get_export_class_name(expo)
		if resolved_class == "WidgetTree":
			var root_prop := expo.find_property("RootWidget")
			var root_index := _object_index(root_prop)
			if root_index >= 0:
				var owner_index := expo.outer_index - 1
				widget_trees.append({
					"export_index": i,
					"name": _tree_label(i, expo),
					"root_index": root_index,
					"owner_index": owner_index,
				})
				if owner_index >= 0 and owner_index < asset.exports.size():
					_tree_root_by_owner[owner_index] = root_index
					var identity := _widget_identity(owner_index)
					if not identity.is_empty():
						if not _tree_roots_by_identity.has(identity):
							_tree_roots_by_identity[identity] = []
						(_tree_roots_by_identity[identity] as Array).append(root_index)

	# Slots define the visual graph and also identify widget exports.
	for i in asset.exports.size():
		var slot := asset.exports[i]
		var slot_class := asset.get_export_class_name(slot)
		if not slot_class.ends_with("Slot"):
			continue
		var parent_index := _object_index(slot.find_property("Parent"))
		var content_index := _object_index(slot.find_property("Content"))
		if parent_index < 0 or content_index < 0:
			continue
		var parent_node := _ensure_node(parent_index)
		var child_node := _ensure_node(content_index)
		child_node["slot_index"] = i
		child_node["parent_index"] = parent_index
		if not (parent_node["children"] as Array).has(content_index):
			(parent_node["children"] as Array).append(content_index)

	for tree in widget_trees:
		_ensure_node(int(tree["root_index"]))


func _tree_label(index: int, tree_export: UAssetExport) -> String:
	if tree_export.object_name == "WidgetTree":
		return "Main Widget Tree"
	var owner := tree_export.outer_index - 1
	if owner >= 0 and owner < asset.exports.size():
		return asset.exports[owner].object_name
	return "Widget Tree #%d" % (index + 1)


func _ensure_node(index: int) -> Dictionary:
	if nodes.has(index):
		return nodes[index]
	var expo := asset.exports[index]
	var node_data := {
		"export_index": index,
		"export": expo,
		"name": expo.object_name,
		"class": asset.get_export_class_name(expo),
		"parent_index": -1,
		"slot_index": -1,
		"children": [],
	}
	nodes[index] = node_data
	return node_data


static func _object_index(prop: UAssetProperty) -> int:
	if prop == null or not (prop.value is int or prop.value is float):
		return -1
	var package_index := int(prop.value)
	return package_index - 1 if package_index > 0 else -1


func roots() -> Array[Dictionary]:
	return widget_trees


func node(index: int) -> Dictionary:
	return nodes.get(index, {})


## Cooked UserWidget instances keep their visual contents in a separate
## WidgetTree owned by the generated instance/archetype. Expose that root as a
## child so the designer renders the complete composed widget, not a placeholder.
func visual_children(index: int) -> Array:
	if _visual_children_cache.has(index):
		return _visual_children_cache[index]
	var data := node(index)
	if data.is_empty():
		return []
	var result: Array = (data["children"] as Array).duplicate()
	var embedded_root := embedded_root_for(index)
	if embedded_root >= 0 and embedded_root != index and not result.has(embedded_root):
		result.append(embedded_root)
	_visual_children_cache[index] = result
	return result


func preview_children(index: int) -> Array:
	if _preview_children_cache.has(index):
		return _preview_children_cache[index]
	var result: Array = []
	for child_index: int in visual_children(index):
		if is_preview_visible(child_index):
			result.append(child_index)
	var data := node(index)
	if not data.is_empty() and str(data["class"]).contains("WidgetSwitcher") \
			and result.size() > 1:
		# Cooked defaults commonly point at a loading/empty state; gameplay changes
		# the active index before showing the menu. For a useful design preview,
		# choose the most substantial visible branch instead of that runtime default.
		var best_child: int = result[0]
		var best_area := -1.0
		for candidate: int in result:
			var candidate_size := desired_size(candidate)
			var candidate_area := candidate_size.x * candidate_size.y
			if candidate_area > best_area:
				best_area = candidate_area
				best_child = candidate
		result = [best_child]
	_preview_children_cache[index] = result
	return result


func is_preview_visible(index: int) -> bool:
	var data := node(index)
	if data.is_empty():
		return false
	var visibility := _enum_suffix(
			(data["export"] as UAssetExport).find_property("Visibility"), "Visible")
	return visibility not in ["Collapsed", "Hidden"]


func embedded_root_for(index: int) -> int:
	if _tree_root_by_owner.has(index):
		return int(_tree_root_by_owner[index])
	var identity := _widget_identity(index)
	if identity.is_empty() or not _tree_roots_by_identity.has(identity):
		return -1
	var candidates: Array = _tree_roots_by_identity[identity]
	return int(candidates[0]) if not candidates.is_empty() else -1


func _widget_identity(index: int) -> String:
	if index < 0 or index >= asset.exports.size():
		return ""
	var expo := asset.exports[index]
	return "%s|%s" % [asset.get_export_class_name(expo), expo.object_name]


func canvas_layout(index: int) -> Dictionary:
	if _canvas_layout_cache.has(index):
		return _canvas_layout_cache[index]
	var data := {"valid": false, "left": 0.0, "top": 0.0, "right": 100.0,
		"bottom": 40.0, "anchor_min": Vector2.ZERO, "anchor_max": Vector2.ZERO}
	var widget: Dictionary = node(index)
	if widget.is_empty() or int(widget["slot_index"]) < 0:
		_canvas_layout_cache[index] = data
		return data
	var slot := asset.exports[int(widget["slot_index"])]
	if asset.get_export_class_name(slot) != "CanvasPanelSlot":
		_canvas_layout_cache[index] = data
		return data
	var layout := slot.find_property("LayoutData")
	if layout == null:
		_canvas_layout_cache[index] = data
		return data
	var offsets := _child(layout, "Offsets")
	if offsets:
		data["left"] = _number_child(offsets, "Left", 0.0)
		data["top"] = _number_child(offsets, "Top", 0.0)
		data["right"] = _number_child(offsets, "Right", 100.0)
		data["bottom"] = _number_child(offsets, "Bottom", 40.0)
	var anchors := _child(layout, "Anchors")
	if anchors:
		data["anchor_min"] = _vector_child(anchors, "Minimum", Vector2.ZERO)
		data["anchor_max"] = _vector_child(anchors, "Maximum", Vector2.ZERO)
	data["valid"] = true
	_canvas_layout_cache[index] = data
	return data


func move_canvas_widget(index: int, delta: Vector2) -> bool:
	var widget: Dictionary = node(index)
	if widget.is_empty() or int(widget["slot_index"]) < 0:
		return false
	var slot := asset.exports[int(widget["slot_index"])]
	var layout := slot.find_property("LayoutData")
	var offsets := _child(layout, "Offsets") if layout else null
	if offsets == null:
		return false
	var left := _child(offsets, "Left")
	var top := _child(offsets, "Top")
	if left == null or top == null:
		return false
	left.value = float(left.value) + delta.x
	top.value = float(top.value) + delta.y
	left.raw["Value"] = left.value
	top.raw["Value"] = top.value
	_canvas_layout_cache.erase(index)
	return true


func set_canvas_offsets(index: int, values: Dictionary) -> bool:
	var widget: Dictionary = node(index)
	if widget.is_empty() or int(widget["slot_index"]) < 0:
		return false
	var slot := asset.exports[int(widget["slot_index"])]
	var layout := slot.find_property("LayoutData")
	var offsets := _child(layout, "Offsets") if layout else null
	if offsets == null:
		return false
	for field in ["Left", "Top", "Right", "Bottom"]:
		var prop := _child(offsets, field)
		if prop and values.has(field.to_lower()):
			prop.value = float(values[field.to_lower()])
			prop.raw["Value"] = prop.value
	_canvas_layout_cache.erase(index)
	return true


func display_text(index: int) -> String:
	var data := node(index)
	if data.is_empty():
		return ""
	var prop: UAssetProperty = (data["export"] as UAssetExport).find_property("Text")
	if prop == null:
		return ""
	if not prop.source_string.is_empty():
		return prop.source_string
	if not prop.culture_invariant.is_empty():
		return prop.culture_invariant
	return str(prop.value) if prop.value != null else ""


func widget_color(index: int) -> Color:
	var data := node(index)
	if data.is_empty():
		return Color.WHITE
	var expo: UAssetExport = data["export"]
	var result := Color.WHITE
	for property_name in ["ColorAndOpacity", "BrushColor", "ForegroundColor"]:
		var color_prop := expo.find_property(property_name)
		if color_prop:
			result *= _color_value(color_prop, Color.WHITE)
	for brush_name in ["Brush", "Background"]:
		var brush_prop := expo.find_property(brush_name)
		var tint_prop := _child(brush_prop, "TintColor") if brush_prop else null
		if tint_prop:
			result *= _color_value(tint_prop, Color.WHITE)
	return result


func text_style(index: int) -> Dictionary:
	var data := node(index)
	if data.is_empty():
		return {"size": 14, "alignment": HORIZONTAL_ALIGNMENT_LEFT}
	var expo: UAssetExport = data["export"]
	var font := expo.find_property("Font")
	var font_size := int(_number_child(font, "Size", 14.0))
	var justification := _enum_suffix(expo.find_property("Justification"), "Left")
	var alignment := HORIZONTAL_ALIGNMENT_LEFT
	if justification == "Center":
		alignment = HORIZONTAL_ALIGNMENT_CENTER
	elif justification == "Right":
		alignment = HORIZONTAL_ALIGNMENT_RIGHT
	return {"size": maxi(6, font_size), "alignment": alignment}


func clips_children(index: int) -> bool:
	var data := node(index)
	if data.is_empty():
		return false
	var clipping := _enum_suffix(
			(data["export"] as UAssetExport).find_property("Clipping"), "Inherit")
	return clipping in ["ClipToBounds", "ClipToBoundsAlways"]


func brush_resource(index: int) -> Dictionary:
	if _brush_cache.has(index):
		return _brush_cache[index]
	var data := node(index)
	if data.is_empty():
		_brush_cache[index] = {}
		return {}
	var expo: UAssetExport = data["export"]
	var resource_prop: UAssetProperty
	var brush_prop: UAssetProperty
	for candidate in ["Brush", "Background", "WidgetStyle", "Style"]:
		var root_prop := expo.find_property(candidate)
		resource_prop = _child(root_prop, "ResourceObject") if root_prop else null
		if resource_prop:
			brush_prop = root_prop
			break
	if resource_prop == null or not (resource_prop.value is int or resource_prop.value is float):
		_brush_cache[index] = {}
		return {}
	var package_index := int(resource_prop.value)
	if package_index >= 0:
		_brush_cache[index] = {}
		return {}
	var imp := asset.get_import(package_index)
	if imp == null:
		_brush_cache[index] = {}
		return {}
	var package_path := _import_package_path(imp)
	if package_path.is_empty():
		_brush_cache[index] = {}
		return {}
	var image_size := _named_vector_value(brush_prop, "ImageSize")
	var margin_prop := _child(brush_prop, "Margin")
	var draw_prop := _child(brush_prop, "DrawAs")
	var draw_as := str(draw_prop.value) if draw_prop and draw_prop.value != null else ""
	if draw_as.is_empty() and draw_prop:
		draw_as = str(draw_prop.raw.get("EnumValue", ""))
	var result := {"package_path": package_path, "class": imp.class_name_str,
		"object_name": imp.object_name, "image_size": image_size,
		"draw_as": draw_as.get_slice("::", 1) if "::" in draw_as else draw_as,
		"margin": Vector4(
			_number_child(margin_prop, "Left", 0.0),
			_number_child(margin_prop, "Top", 0.0),
			_number_child(margin_prop, "Right", 0.0),
			_number_child(margin_prop, "Bottom", 0.0))}
	_brush_cache[index] = result
	return result


func _import_package_path(imp: UAssetImport) -> String:
	if imp.object_name.begins_with("/Game/") or imp.object_name.begins_with("/Engine/"):
		return imp.object_name
	if imp.outer_index >= 0:
		return ""
	var outer := asset.get_import(imp.outer_index)
	return _import_package_path(outer) if outer else ""


func brush_resources_for_tree(root_index: int, limit: int = 32) -> Array[Dictionary]:
	var found := {}
	_collect_brush_resources(root_index, found, {}, limit)
	var result: Array[Dictionary] = []
	for value: Dictionary in found.values():
		result.append(value)
	return result


func desired_size(index: int, visited: Dictionary = {}) -> Vector2:
	if visited.is_empty() and _desired_size_cache.has(index):
		return _desired_size_cache[index]
	if visited.has(index):
		return Vector2.ZERO
	var next := visited.duplicate()
	next[index] = true
	var data := node(index)
	if data.is_empty():
		return Vector2.ZERO
	var expo: UAssetExport = data["export"]
	var width := _property_number(expo.find_property("WidthOverride"), 0.0)
	var height := _property_number(expo.find_property("HeightOverride"), 0.0)
	var brush := brush_resource(index)
	# Border/Box brushes are resizable decoration. Their tiny source ImageSize
	# must not override the desired size supplied by their child content.
	if not brush.is_empty() and (widget_class_for(index).contains("Image") \
			or str(brush.get("draw_as", "Image")) == "Image"):
		var image_size: Vector2 = brush.get("image_size", Vector2.ZERO)
		if width <= 0: width = image_size.x
		if height <= 0: height = image_size.y
	var widget_class := str(data["class"])
	var children: Array = preview_children(index)
	if (width <= 0 or height <= 0) and not children.is_empty():
		var aggregate := Vector2.ZERO
		for child_index: int in children:
			var child_size := desired_size(child_index, next)
			if widget_class.contains("VerticalBox"):
				aggregate.x = maxf(aggregate.x, child_size.x)
				aggregate.y += child_size.y
			elif widget_class.contains("HorizontalBox"):
				aggregate.x += child_size.x
				aggregate.y = maxf(aggregate.y, child_size.y)
			else:
				aggregate.x = maxf(aggregate.x, child_size.x)
				aggregate.y = maxf(aggregate.y, child_size.y)
		if width <= 0: width = aggregate.x
		if height <= 0: height = aggregate.y
	var result := Vector2(width, height)
	if visited.is_empty():
		_desired_size_cache[index] = result
	return result


func widget_class_for(index: int) -> String:
	var data := node(index)
	return str(data.get("class", ""))


func slot_info(index: int) -> Dictionary:
	if _slot_cache.has(index):
		return _slot_cache[index]
	var data := node(index)
	if data.is_empty() or int(data["slot_index"]) < 0:
		var fallback := {"horizontal": "Fill", "vertical": "Fill", "size_rule": "Auto",
			"padding": Vector4.ZERO}
		_slot_cache[index] = fallback
		return fallback
	var slot := asset.exports[int(data["slot_index"])]
	var slot_class := asset.get_export_class_name(slot)
	# This four-corner pattern serializes only the axes that differ from its
	# top-left archetype: TR stores Right, BL stores Bottom, BR stores both. The
	# omitted axes therefore mean Left/Top for corner ornaments, not slot Fill.
	# Keep normal overlay backgrounds on Fill.
	var is_corner_ornament := slot_class == "OverlaySlot" \
			and str(data["name"]).begins_with("Corner_")
	var default_horizontal := "Left" if is_corner_ornament else "Fill"
	var default_vertical := "Top" if is_corner_ornament else "Fill"
	var padding := slot.find_property("Padding")
	var result := {
		"horizontal": _enum_suffix(slot.find_property("HorizontalAlignment"), default_horizontal),
		"vertical": _enum_suffix(slot.find_property("VerticalAlignment"), default_vertical),
		"size_rule": _enum_suffix(_child(slot.find_property("Size"), "SizeRule"), "Auto"),
		"padding": Vector4(_number_child(padding, "Left", 0.0),
			_number_child(padding, "Top", 0.0),
			_number_child(padding, "Right", 0.0),
			_number_child(padding, "Bottom", 0.0)),
	}
	_slot_cache[index] = result
	return result


func render_transform(index: int) -> Dictionary:
	if _render_transform_cache.has(index):
		return _render_transform_cache[index]
	var data := node(index)
	if data.is_empty():
		var fallback := {"translation": Vector2.ZERO, "scale": Vector2.ONE,
			"pivot": Vector2(0.5, 0.5)}
		_render_transform_cache[index] = fallback
		return fallback
	var expo: UAssetExport = data["export"]
	var transform := expo.find_property("RenderTransform")
	var translation := _named_vector_value(transform, "Translation")
	var render_scale := _named_vector_value(transform, "Scale")
	if render_scale.is_zero_approx():
		render_scale = Vector2.ONE
	var pivot_prop := expo.find_property("RenderTransformPivot")
	var pivot := Vector2(0.5, 0.5)
	if pivot_prop and pivot_prop.value is Dictionary:
		pivot = Vector2(float(pivot_prop.value.get("X", 0.5)),
				float(pivot_prop.value.get("Y", 0.5)))
	var result := {"translation": translation, "scale": render_scale, "pivot": pivot}
	_render_transform_cache[index] = result
	return result


static func _enum_suffix(prop: UAssetProperty, fallback: String) -> String:
	if prop == null:
		return fallback
	var text := str(prop.value) if prop.value != null else str(prop.raw.get("EnumValue", ""))
	if "_" in text:
		return text.get_slice("_", text.count("_"))
	if "::" in text:
		return text.get_slice("::", 1)
	return text if not text.is_empty() else fallback


static func _property_number(prop: UAssetProperty, fallback: float) -> float:
	return float(prop.value) if prop and (prop.value is int or prop.value is float) else fallback


func _collect_brush_resources(index: int, found: Dictionary, visited: Dictionary,
		limit: int) -> void:
	if visited.has(index) or found.size() >= limit:
		return
	visited[index] = true
	var resource := brush_resource(index)
	if not resource.is_empty() and str(resource["class"]) in [
			"Texture2D", "Material", "MaterialInstance", "MaterialInstanceConstant"]:
		found[resource["package_path"]] = resource
	for child_index: int in visual_children(index):
		_collect_brush_resources(child_index, found, visited, limit)


static func _child(prop: UAssetProperty, wanted: String) -> UAssetProperty:
	if prop == null:
		return null
	for child in prop.children:
		if child.prop_name == wanted:
			return child
		var nested := _child(child, wanted)
		if nested:
			return nested
	return null


static func _number_child(prop: UAssetProperty, wanted: String, fallback: float) -> float:
	var found := _child(prop, wanted)
	return float(found.value) if found and found.value is float else fallback


static func _vector_child(prop: UAssetProperty, wanted: String, fallback: Vector2) -> Vector2:
	var found := _child(prop, wanted)
	if found and found.value is Dictionary:
		return Vector2(float(found.value.get("X", fallback.x)), float(found.value.get("Y", fallback.y)))
	return fallback


static func _named_vector_value(prop: UAssetProperty, wanted: String) -> Vector2:
	if prop == null:
		return Vector2.ZERO
	if prop.prop_name == wanted and prop.value is Dictionary:
		return Vector2(float(prop.value.get("X", 0.0)), float(prop.value.get("Y", 0.0)))
	for child in prop.children:
		var result := _named_vector_value(child, wanted)
		if not result.is_zero_approx():
			return result
	return Vector2.ZERO


static func _color_value(prop: UAssetProperty, fallback: Color) -> Color:
	if prop == null:
		return fallback
	if prop.value is Dictionary:
		var value: Dictionary = prop.value
		if value.has("R") or value.has("G") or value.has("B"):
			return Color(float(value.get("R", 1.0)), float(value.get("G", 1.0)),
					float(value.get("B", 1.0)), float(value.get("A", 1.0)))
	for child in prop.children:
		var found := _color_value(child, Color(-1, -1, -1, -1))
		if found.r >= 0.0:
			return found
	return fallback
