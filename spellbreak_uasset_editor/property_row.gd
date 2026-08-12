class_name PropertyRow
extends HBoxContainer
## A single row in the detail panel: Label + Editor control.
## Creates the appropriate control based on property type.

signal value_changed(property: UAssetProperty, old_value: Variant, new_value: Variant)

var property: UAssetProperty
var editor_control: Control

const LABEL_MIN_WIDTH := 180


static func create(prop: UAssetProperty, asset: UAssetFile = null) -> PropertyRow:
	var row := PropertyRow.new()
	row.property = prop
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	# Label
	var label := Label.new()
	label.text = prop.prop_name
	label.custom_minimum_size.x = LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.tooltip_text = "%s (%s)" % [prop.prop_name, prop.prop_type]
	label.clip_text = true
	row.add_child(label)

	# Type badge
	var type_label := Label.new()
	type_label.text = _type_badge(prop)
	type_label.custom_minimum_size.x = 70
	type_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	AppTheme.style_badge(type_label)
	row.add_child(type_label)

	# Editor control
	row.editor_control = _create_editor(prop, row, asset)
	row.editor_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(row.editor_control)

	return row


static func _type_badge(prop: UAssetProperty) -> String:
	match prop.prop_type:
		"Struct":
			match prop.struct_type:
				"GameplayTag": return "tag"
				"GameplayTagContainer": return "tags"
				_: return "[%s]" % prop.struct_type
		"Array": return "[%s]" % prop.array_type
		"Enum": return "enum"
		"GameplayTagContainer": return "tags"
		_: return prop.prop_type.to_lower()


static func _resolve_ref(index: int, asset: UAssetFile) -> String:
	var uname := _resolve_ref_name(index, asset)
	var type := _resolve_ref_type(index, asset)
	if type.is_empty() or uname == type:
		return uname
	return "%s  ·  %s" % [uname, type]


static func _resolve_ref_name(index: int, asset: UAssetFile) -> String:
	if asset == null:
		return ""
	if index == 0:
		return "None"
	if index < 0:
		var i := (-index) - 1
		if i >= 0 and i < asset.imports.size():
			return asset.imports[i].object_name
		return "(import %d — out of range)" % index
	else:
		var i := index - 1
		if i >= 0 and i < asset.exports.size():
			var expo := asset.exports[i]
			return expo.object_name if not expo.object_name.is_empty() else "[export %d]" % index
		return "(export %d — out of range)" % index


static func _resolve_ref_type(index: int, asset: UAssetFile) -> String:
	if asset == null or index == 0:
		return ""
	if index < 0:
		var i := (-index) - 1
		if i >= 0 and i < asset.imports.size():
			return asset.imports[i].class_name_str
		return ""
	else:
		var i := index - 1
		if i >= 0 and i < asset.exports.size():
			return asset.exports[i].export_type
		return ""


static func _create_editor(prop: UAssetProperty, row: PropertyRow, asset: UAssetFile = null) -> Control:
	if is_color_struct(prop):
		return _make_color_editor(prop, row)
	if is_vector_struct(prop):
		return _make_vector_editor(prop, row, asset)

	match prop.prop_type:
		"Int":
			var spin := SpinBox.new()
			spin.min_value = -2147483648
			spin.max_value = 2147483647
			spin.step = 1
			spin.value = int(prop.value) if prop.value != null else 0
			spin.value_changed.connect(func(v): _on_change(row, int(v)))
			if asset and asset.game_profile and not asset.game_profile.constants.is_empty():
				_attach_constant_helper(spin, asset.game_profile.constants, true)
			return spin

		"Float":
			var spin := SpinBox.new()
			spin.min_value = -999999.0
			spin.max_value = 999999.0
			spin.step = 0.01
			spin.value = float(prop.value) if prop.value != null else 0.0
			spin.value_changed.connect(func(v): _on_change(row, v))
			if asset and asset.game_profile and not asset.game_profile.constants.is_empty():
				_attach_constant_helper(spin, asset.game_profile.constants, false)
			return spin

		"Bool":
			var check := CheckBox.new()
			var bval: bool = false
			if prop.value is bool:
				bval = prop.value
			elif prop.value is String:
				bval = prop.value.to_lower() == "true"
			elif prop.value != null:
				bval = bool(prop.value)
			check.button_pressed = bval
			check.text = "True" if check.button_pressed else "False"
			check.toggled.connect(func(v):
				check.text = "True" if v else "False"
				_on_change(row, v)
			)
			return check

		"Enum":
			var current := str(prop.value) if prop.value != null else ""
			var known := PackedStringArray()
			if asset and asset.game_profile:
				known = asset.game_profile.get_enum_values(prop.enum_type)
			else:
				known = SpellbreakProfile.shared().get_enum_values(prop.enum_type)
			if known.size() > 0:
				var opt := OptionButton.new()
				var selected_idx := 0
				for i in known.size():
					opt.add_item(known[i])
					if known[i] == current:
						selected_idx = i
				# If the current value isn't in the known list, add it at the top
				if current != "" and not current in known:
					opt.add_item(current + "  (?)")
					selected_idx = opt.item_count - 1
				opt.selected = selected_idx
				opt.item_selected.connect(func(idx): _on_change(row, opt.get_item_text(idx).trim_suffix("  (?)")))
				return opt
			else:
				var line := LineEdit.new()
				line.text = current
				line.placeholder_text = prop.enum_type
				line.text_changed.connect(func(t): _on_change(row, t))
				return line

		"Text":
			var vbox := VBoxContainer.new()
			vbox.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)

			# Key / reference string (small, dim)
			var key_line := LineEdit.new()
			key_line.text = str(prop.value) if prop.value != null else ""
			key_line.placeholder_text = "key"
			key_line.add_theme_font_size_override("font_size", AppTheme.FONT_BADGE)
			key_line.add_theme_color_override("font_color", AppTheme.TEXT_SUBTLE)
			key_line.text_changed.connect(func(t): _on_change(row, t))
			vbox.add_child(key_line)

			# Actual text content — multiline
			var content_edit := TextEdit.new()
			content_edit.text = _get_text_content(prop)
			content_edit.placeholder_text = "text content..."
			content_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			content_edit.scroll_fit_content_height = true
			content_edit.custom_minimum_size.y = 40
			content_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			content_edit.text_changed.connect(func():
				_on_text_content_change(row, content_edit.text)
			)
			vbox.add_child(content_edit)
			return vbox

		"Name", "Str":
			var line := LineEdit.new()
			line.text = str(prop.value) if prop.value != null else ""
			line.text_changed.connect(func(t): _on_change(row, t))
			return line

		"SoftObject":
			var line := LineEdit.new()
			line.text = prop.get_display_value()
			line.add_theme_color_override("font_color", AppTheme.REF_LINE_COLOR)
			line.text_changed.connect(func(t):
				if prop.value is Dictionary:
					var asset_path = prop.value.get("AssetPath", {})
					if asset_path is Dictionary:
						var old_state := prop.capture_state()
						asset_path["PackageName"] = t if t != "" else null
						row.value_changed.emit(prop, old_state, prop.capture_state())
			)
			return line

		"Struct":
			var _tag_list: Array = []
			if asset and asset.game_profile:
				_tag_list = asset.game_profile.tags
			match prop.struct_type:
				"GameplayTag":
					var tag_child := prop.find_child("TagName")
					if tag_child:
						var current := str(tag_child.value) if tag_child.value != null else ""
						return _make_tag_autocomplete(current, func(new_tag: String):
							var old_state := prop.capture_state()
							tag_child.set_value(new_tag)
							row.value_changed.emit(prop, old_state, prop.capture_state())
						, _tag_list)
				"GameplayTagContainer":
					var inner: UAssetProperty = null
					if prop.children.size() > 0:
						inner = prop.children[0]
					if inner != null and inner.value is Array:
						return _make_tag_list_editor(inner, row, _tag_list)
			var info := Label.new()
			info.text = "%d children" % prop.children.size()
			info.add_theme_color_override("font_color", AppTheme.TEXT_INFO_YELLOW)
			return info

		"Array":
			var info := Label.new()
			info.text = "%d items" % prop.children.size()
			info.add_theme_color_override("font_color", AppTheme.TEXT_INFO_YELLOW)
			return info

		"GameplayTagContainer":
			# Standalone GameplayTagContainer (child of a GameplayTagContainer struct)
			if prop.value is Array:
				var _tag_list2: Array = []
				if asset and asset.game_profile:
					_tag_list2 = asset.game_profile.tags
				return _make_tag_list_editor(prop, row, _tag_list2)
			var info2 := Label.new()
			info2.text = str(prop.value)
			info2.add_theme_color_override("font_color", AppTheme.TEXT_INFO_YELLOW)
			return info2

		"Byte":
			if prop.value is String:
				var line := LineEdit.new()
				line.text = str(prop.value)
				line.text_submitted.connect(func(t): _on_change(row, t))
				return line
			else:
				var spin := SpinBox.new()
				spin.min_value = 0
				spin.max_value = 255
				spin.value = int(prop.value) if prop.value != null else 0
				spin.value_changed.connect(func(v): _on_change(row, int(v)))
				return spin

		"Object":
			# Index reference: editable int + resolved name label inline
			var hbox := HBoxContainer.new()
			hbox.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

			var spin := SpinBox.new()
			spin.min_value = -2147483648
			spin.max_value = 2147483647
			spin.allow_greater = true
			spin.allow_lesser = true
			spin.rounded = true
			spin.step = 1
			spin.custom_minimum_size.x = 80
			var idx: int = int(prop.value) if prop.value != null else 0
			spin.value = idx
			hbox.add_child(spin)

			var ref_label := Label.new()
			ref_label.text = _resolve_ref_name(idx, asset)
			ref_label.tooltip_text = _resolve_ref_type(idx, asset)
			AppTheme.style_ref(ref_label, AppTheme.FONT_REF)
			ref_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ref_label.clip_text = true
			ref_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			hbox.add_child(ref_label)

			spin.value_changed.connect(func(v):
				_on_change(row, int(v))
				ref_label.text = _resolve_ref_name(int(v), asset)
				ref_label.tooltip_text = _resolve_ref_type(int(v), asset)
			)
			return hbox

		_:
			# Unknown type - show as read-only text
			var line := LineEdit.new()
			line.text = str(prop.value) if prop.value != null else "null"
			line.editable = false
			line.add_theme_color_override("font_color", AppTheme.TEXT_MUTED)
			return line


static func is_color_struct(prop: UAssetProperty) -> bool:
	if prop == null:
		return false
	if prop.prop_type == "Struct":
		if prop.struct_type not in ["LinearColor", "Color"]:
			return false
		for component in ["R", "G", "B"]:
			var child := prop.find_child(component)
			if child == null or not _is_color_component(child):
				return false
		var alpha := prop.find_child("A")
		return alpha == null or _is_color_component(alpha)
	return _color_value_dict(prop) != null


static func _is_color_component(prop: UAssetProperty) -> bool:
	if prop.prop_type not in ["Float", "Int", "Byte"]:
		return false
	if prop.value is String:
		return false
	return prop.value == null or prop.value is int or prop.value is float


static func _make_color_editor(prop: UAssetProperty, row: PropertyRow) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var picker := ColorPickerButton.new()
	picker.edit_alpha = _color_has_alpha(prop)
	picker.color = _color_from_struct(prop)
	picker.custom_minimum_size.x = 64
	picker.tooltip_text = "Edit %s color" % _color_type_label(prop)
	hbox.add_child(picker)

	var value_label := Label.new()
	value_label.text = _color_label_text(prop)
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_dim(value_label)
	hbox.add_child(value_label)

	picker.color_changed.connect(func(color: Color) -> void:
		var old_state := prop.capture_state()
		_apply_color_to_struct(prop, color)
		value_label.text = _color_label_text(prop)
		var new_state := prop.capture_state()
		if new_state != old_state:
			row.value_changed.emit(prop, old_state, new_state)
	)
	return hbox


static func _color_from_struct(prop: UAssetProperty) -> Color:
	var dict: Variant = _color_value_dict(prop)
	if dict is Dictionary:
		var color_dict: Dictionary = dict
		return Color(
			_color_dict_component_to_float(color_dict, "R", prop, 0.0),
			_color_dict_component_to_float(color_dict, "G", prop, 0.0),
			_color_dict_component_to_float(color_dict, "B", prop, 0.0),
			_color_dict_component_to_float(color_dict, "A", prop, 1.0)
		)
	return Color(
		_color_component_to_float(prop.find_child("R"), prop.struct_type, 0.0),
		_color_component_to_float(prop.find_child("G"), prop.struct_type, 0.0),
		_color_component_to_float(prop.find_child("B"), prop.struct_type, 0.0),
		_color_component_to_float(prop.find_child("A"), prop.struct_type, 1.0)
	)


static func _color_component_to_float(child: UAssetProperty, struct_type: String,
		default_value: float) -> float:
	if child == null or child.value == null:
		return default_value
	var value := float(child.value)
	if _color_component_is_byte(child, struct_type):
		value /= 255.0
	return clampf(value, 0.0, 1.0)


static func _color_dict_component_to_float(dict: Dictionary, component: String,
		prop: UAssetProperty, default_value: float) -> float:
	if not dict.has(component) or dict[component] == null:
		return default_value
	var value := float(dict[component])
	if _color_dict_is_byte(prop):
		value /= 255.0
	return clampf(value, 0.0, 1.0)


static func _apply_color_to_struct(prop: UAssetProperty, color: Color) -> void:
	var dict: Variant = _color_value_dict(prop)
	if dict is Dictionary:
		_apply_color_to_dict(prop, dict, color)
		return

	var components := {
		"R": color.r,
		"G": color.g,
		"B": color.b,
		"A": color.a,
	}
	for component in components:
		var child := prop.find_child(str(component))
		if child == null:
			continue
		var value := clampf(float(components[component]), 0.0, 1.0)
		if _color_component_is_byte(child, prop.struct_type):
			child.set_value(int(round(value * 255.0)))
		else:
			child.set_value(value)


static func _color_component_is_byte(child: UAssetProperty, struct_type: String) -> bool:
	return struct_type == "Color" or child.prop_type in ["Byte", "Int"]


static func _apply_color_to_dict(prop: UAssetProperty, dict: Dictionary, color: Color) -> void:
	var components := {
		"R": color.r,
		"G": color.g,
		"B": color.b,
		"A": color.a,
	}
	for component in components:
		if not dict.has(component):
			continue
		var value := clampf(float(components[component]), 0.0, 1.0)
		if _color_dict_is_byte(prop):
			dict[component] = int(round(value * 255.0))
		else:
			dict[component] = value
	prop.value = dict
	prop.raw["Value"] = dict


static func _color_value_dict(prop: UAssetProperty) -> Variant:
	if prop.value is Dictionary and _dict_looks_like_color(prop.value, prop.prop_type):
		return prop.value
	var raw_value: Variant = prop.raw.get("Value")
	if raw_value is Dictionary and _dict_looks_like_color(raw_value, prop.prop_type):
		return raw_value
	return null


static func _dict_looks_like_color(dict: Dictionary, prop_type: String) -> bool:
	if not (dict.has("R") and dict.has("G") and dict.has("B")):
		return false
	var type_name := _color_dict_type_name(dict, prop_type)
	return type_name in ["LinearColor", "FLinearColor", "Color", "FColor"]


static func _color_dict_type_name(dict: Dictionary, fallback_type: String) -> String:
	var type_text := str(dict.get("$type", ""))
	if type_text.contains("FLinearColor"):
		return "FLinearColor"
	if type_text.contains("FColor"):
		return "FColor"
	return fallback_type


static func _color_dict_is_byte(prop: UAssetProperty) -> bool:
	var dict: Variant = _color_value_dict(prop)
	var color_dict: Dictionary = dict if dict is Dictionary else {}
	var type_name := _color_dict_type_name(color_dict, prop.prop_type)
	return type_name in ["Color", "FColor"]


static func _color_has_alpha(prop: UAssetProperty) -> bool:
	var dict: Variant = _color_value_dict(prop)
	if dict is Dictionary:
		return dict.has("A")
	return prop.find_child("A") != null


static func _color_type_label(prop: UAssetProperty) -> String:
	var dict: Variant = _color_value_dict(prop)
	if dict is Dictionary:
		return _color_dict_type_name(dict, prop.prop_type).trim_prefix("F")
	return prop.struct_type


static func _color_label_text(prop: UAssetProperty) -> String:
	var color := _color_from_struct(prop)
	if _color_has_alpha(prop):
		return "#%s" % color.to_html(true)
	return "#%s" % color.to_html(false)


static func is_vector_struct(prop: UAssetProperty) -> bool:
	if prop == null:
		return false
	var components := _vector_components(prop)
	if components.is_empty():
		return false
	var dict: Variant = _vector_value_dict(prop)
	if dict is Dictionary:
		for component in components:
			if not dict.has(component) or not _is_numeric_value(dict[component]):
				return false
		return true
	if prop.prop_type != "Struct":
		return false
	for component in components:
		var child := prop.find_child(str(component))
		if child == null or not _is_vector_component(child):
			return false
	return true


static func _make_vector_editor(prop: UAssetProperty, row: PropertyRow,
		asset: UAssetFile = null) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	for component in _vector_components(prop):
		hbox.add_child(_make_vector_component_editor(prop, row, str(component), asset))
	return hbox


static func _make_vector_component_editor(prop: UAssetProperty, row: PropertyRow,
		component: String, asset: UAssetFile = null) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)

	var label := Label.new()
	label.text = component
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	AppTheme.style_dim(label)
	hbox.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = -999999999.0
	spin.max_value = 999999999.0
	spin.allow_lesser = true
	spin.allow_greater = true
	spin.step = 0.01
	spin.value = _vector_component_value(prop, component)
	spin.custom_minimum_size.x = 92
	spin.tooltip_text = "%s.%s" % [_vector_type_label(prop), component]
	if asset and asset.game_profile and not asset.game_profile.constants.is_empty():
		_attach_constant_helper(spin, asset.game_profile.constants, false)
	spin.value_changed.connect(func(v: float) -> void:
		var old_state := prop.capture_state()
		_apply_vector_component(prop, component, v)
		var new_state := prop.capture_state()
		if new_state != old_state:
			row.value_changed.emit(prop, old_state, new_state)
	)
	hbox.add_child(spin)
	return hbox


static func _vector_component_value(prop: UAssetProperty, component: String) -> float:
	var dict: Variant = _vector_value_dict(prop)
	if dict is Dictionary and dict.has(component) and dict[component] != null:
		return _numeric_value_to_float(dict[component])
	var child := prop.find_child(component)
	if child != null and child.value != null:
		return _numeric_value_to_float(child.value)
	return 0.0


static func _apply_vector_component(prop: UAssetProperty, component: String, value: float) -> void:
	var dict: Variant = _vector_value_dict(prop)
	if dict is Dictionary:
		dict[component] = _vector_cast_value(dict.get(component), value)
		prop.value = dict
		prop.raw["Value"] = dict
		return

	var child := prop.find_child(component)
	if child != null:
		child.set_value(_vector_cast_value(child.value, value, child.prop_type))


static func _vector_cast_value(old_value: Variant, value: float, prop_type: String = "") -> Variant:
	if prop_type in ["Int", "Byte"] or old_value is int:
		return int(round(value))
	if old_value is String and _is_numeric_value(old_value):
		var text := str(value)
		if value >= 0.0 and str(old_value).strip_edges().begins_with("+"):
			text = "+" + text
		return text
	return value


static func _vector_value_dict(prop: UAssetProperty) -> Variant:
	var components := _vector_components(prop)
	if components.is_empty():
		return null
	if prop.value is Dictionary and _dict_has_components(prop.value, components):
		return prop.value
	var raw_value: Variant = prop.raw.get("Value")
	if raw_value is Dictionary and _dict_has_components(raw_value, components):
		return raw_value
	return null


static func _dict_has_components(dict: Dictionary, components: Array) -> bool:
	for component in components:
		if not dict.has(component):
			return false
	return true


static func _vector_components(prop: UAssetProperty) -> Array[String]:
	var type_name := _vector_type_name(prop)
	var normalized := type_name.trim_prefix("F")
	if normalized in ["Vector2D", "Vector2", "IntPoint"]:
		return ["X", "Y"]
	if normalized in ["Vector4", "Quat"]:
		return ["X", "Y", "Z", "W"]
	if normalized in ["Vector", "Vector3", "IntVector"] \
			or normalized.begins_with("Vector_NetQuantize"):
		return ["X", "Y", "Z"]
	return []


static func _vector_type_name(prop: UAssetProperty) -> String:
	if prop.prop_type == "Struct" and not prop.struct_type.is_empty():
		return prop.struct_type
	var raw_type := _vector_raw_type_name(prop.value)
	if not raw_type.is_empty():
		return raw_type
	raw_type = _vector_raw_type_name(prop.raw.get("Value"))
	if not raw_type.is_empty():
		return raw_type
	return prop.prop_type


static func _vector_raw_type_name(value: Variant) -> String:
	if not (value is Dictionary):
		return ""
	var type_text := str((value as Dictionary).get("$type", ""))
	if type_text.contains("FVector4"):
		return "Vector4"
	if type_text.contains("FVector2D"):
		return "Vector2D"
	if type_text.contains("FVector"):
		return "Vector"
	return ""


static func _vector_type_label(prop: UAssetProperty) -> String:
	return _vector_type_name(prop).trim_prefix("F")


static func _is_vector_component(prop: UAssetProperty) -> bool:
	if prop.prop_type not in ["Float", "Int", "Byte"]:
		return false
	return _is_numeric_value(prop.value)


static func _is_numeric_value(value: Variant) -> bool:
	if value == null:
		return true
	if value is String:
		var text := str(value).strip_edges()
		if text.begins_with("+"):
			text = text.substr(1)
		return text.is_valid_float()
	return value is int or value is float


static func _numeric_value_to_float(value: Variant) -> float:
	if value is String:
		var text := str(value).strip_edges()
		if text.begins_with("+"):
			text = text.substr(1)
		return float(text)
	return float(value)


## Returns whichever text content field is populated (culture-invariant > source string).
static func _get_text_content(prop: UAssetProperty) -> String:
	if not prop.culture_invariant.is_empty():
		return prop.culture_invariant
	return prop.source_string


## Updates the correct text content field and emits value_changed.
static func _on_text_content_change(row: PropertyRow, new_text: String) -> void:
	var prop: UAssetProperty = row.property
	var old_state := prop.capture_state()
	# Write to whichever field was populated; default to culture_invariant
	if not prop.source_string.is_empty() and prop.culture_invariant.is_empty():
		prop.source_string = new_text
		prop.raw["SourceString"] = new_text
	else:
		prop.culture_invariant = new_text
		prop.raw["CultureInvariantString"] = new_text
	row.value_changed.emit(prop, old_state, prop.capture_state())


static func _on_change(row: PropertyRow, new_value: Variant) -> void:
	var old_state := row.property.capture_state()
	row.property.set_value(new_value)
	row.value_changed.emit(row.property, old_state, row.property.capture_state())


## Creates a LineEdit with a filter-as-you-type tag autocomplete dropdown.
## on_change is called with the selected/submitted tag string.
## tag_list: the array of known Spellbreak tags to search against.
static func _make_tag_autocomplete(current: String, on_change: Callable, tag_list: Array = []) -> Control:
	return PropertyInputHelpers.make_tag_autocomplete(current, on_change, tag_list)


## Creates an editable list of gameplay tags for a GameplayTagContainer property.
## prop.value must be an Array of String tag names.
static func _make_tag_list_editor(prop: UAssetProperty, row: PropertyRow, tag_list: Array = []) -> Control:
	return PropertyInputHelpers.make_tag_list_editor(prop, row, tag_list)


## Clears and repopulates a tag list VBoxContainer.
## Called directly by class name from button callbacks to avoid closure-capture issues.
static func _rebuild_tag_list(vbox: VBoxContainer, prop: UAssetProperty, row: PropertyRow, tag_list: Array = []) -> void:
	PropertyInputHelpers.rebuild_tag_list(vbox, prop, row, tag_list)


# ── Numeric constant helpers ──────────────────────────────────────────────────

## Attaches constant autocomplete and expression evaluation to a SpinBox.
## constants: Dictionary of Spellbreak constant name → numeric value.
## is_int: if true, the final result is cast to int.
static func _attach_constant_helper(spin: SpinBox, constants: Dictionary, is_int: bool) -> void:
	PropertyInputHelpers.attach_constant_helper(spin, constants, is_int)
