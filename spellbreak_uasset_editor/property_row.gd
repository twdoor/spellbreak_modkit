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
	row.add_theme_constant_override("separation", 8)

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
	type_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	type_label.add_theme_font_size_override("font_size", 11)
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
	match prop.prop_type:
		"Int":
			var spin := SpinBox.new()
			spin.min_value = -2147483648
			spin.max_value = 2147483647
			spin.step = 1
			spin.value = int(prop.value) if prop.value != null else 0
			spin.value_changed.connect(func(v): _on_change(row, int(v)))
			return spin

		"Float":
			var spin := SpinBox.new()
			spin.min_value = -999999.0
			spin.max_value = 999999.0
			spin.step = 0.01
			spin.value = float(prop.value) if prop.value != null else 0.0
			spin.value_changed.connect(func(v): _on_change(row, v))
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
			var known := UE4Enums.get_values(prop.enum_type)
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
			vbox.add_theme_constant_override("separation", 3)

			# Key / reference string (small, dim)
			var key_line := LineEdit.new()
			key_line.text = str(prop.value) if prop.value != null else ""
			key_line.placeholder_text = "key"
			key_line.add_theme_font_size_override("font_size", 11)
			key_line.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
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
			line.editable = false
			line.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
			return line

		"Struct":
			match prop.struct_type:
				"GameplayTag":
					var tag_child := prop.find_child("TagName")
					if tag_child:
						var current := str(tag_child.value) if tag_child.value != null else ""
						return _make_tag_autocomplete(current, func(new_tag: String):
							tag_child.value = new_tag
							tag_child.raw["Value"] = new_tag
							row.value_changed.emit(prop, current, new_tag)
						)
				"GameplayTagContainer":
					var inner: UAssetProperty = null
					if prop.children.size() > 0:
						inner = prop.children[0]
					if inner != null and inner.value is Array:
						return _make_tag_list_editor(inner, row)
			var info := Label.new()
			info.text = "%d children" % prop.children.size()
			info.add_theme_color_override("font_color", Color(0.8, 0.8, 0.4))
			return info

		"Array":
			var info := Label.new()
			info.text = "%d items" % prop.children.size()
			info.add_theme_color_override("font_color", Color(0.8, 0.8, 0.4))
			return info

		"GameplayTagContainer":
			# Standalone GameplayTagContainer (child of a GameplayTagContainer struct)
			if prop.value is Array:
				return _make_tag_list_editor(prop, row)
			var info2 := Label.new()
			info2.text = str(prop.value)
			info2.add_theme_color_override("font_color", Color(0.8, 0.8, 0.4))
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
			hbox.add_theme_constant_override("separation", 6)

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
			ref_label.add_theme_font_size_override("font_size", 15)
			ref_label.add_theme_color_override("font_color", Color(0.45, 0.65, 0.9))
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
			line.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			return line


## Returns whichever text content field is populated (culture-invariant > source string).
static func _get_text_content(prop: UAssetProperty) -> String:
	if not prop.culture_invariant.is_empty():
		return prop.culture_invariant
	return prop.source_string


## Updates the correct text content field and emits value_changed.
static func _on_text_content_change(row: PropertyRow, new_text: String) -> void:
	var prop: UAssetProperty = row.property
	var old: String = _get_text_content(prop)
	# Write to whichever field was populated; default to culture_invariant
	if not prop.source_string.is_empty() and prop.culture_invariant.is_empty():
		prop.source_string = new_text
		prop.raw["SourceString"] = new_text
	else:
		prop.culture_invariant = new_text
		prop.raw["CultureInvariantString"] = new_text
	row.value_changed.emit(prop, old, new_text)


static func _on_change(row: PropertyRow, new_value: Variant) -> void:
	var old_value: Variant = row.property.value
	row.property.value = new_value
	row.value_changed.emit(row.property, old_value, new_value)


## Creates a LineEdit with a filter-as-you-type tag autocomplete popup.
## on_change is called with the selected/submitted tag string.
static func _make_tag_autocomplete(current: String, on_change: Callable) -> Control:
	var line := LineEdit.new()
	line.text = current
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var popup := PopupMenu.new()
	popup.max_size = Vector2i(500, 280)
	line.add_child(popup)

	line.text_changed.connect(func(t: String):
		popup.clear()
		if t.length() < 2:
			popup.hide()
			return
		var t_lower := t.to_lower()
		var added := 0
		for tag in SpellbreakTags.ALL:
			if tag.to_lower().contains(t_lower):
				popup.add_item(tag)
				added += 1
				if added >= 20:
					break
		if added > 0:
			var gpos := line.get_screen_position() + Vector2(0, line.size.y)
			popup.position = Vector2i(int(gpos.x), int(gpos.y))
			popup.reset_size()
			popup.show()
		else:
			popup.hide()
	)

	popup.index_pressed.connect(func(idx: int):
		var tag := popup.get_item_text(idx)
		line.text = tag
		popup.hide()
		on_change.call(tag)
	)

	line.focus_exited.connect(func():
		if not popup.visible:
			on_change.call(line.text)
	)

	line.text_submitted.connect(func(t: String):
		popup.hide()
		on_change.call(t)
	)

	return line


## Creates an editable list of gameplay tags for a GameplayTagContainer property.
## prop.value must be an Array of String tag names.
static func _make_tag_list_editor(prop: UAssetProperty, row: PropertyRow) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	_rebuild_tag_list(vbox, prop, row)
	return vbox


## Clears and repopulates a tag list VBoxContainer.
## Called directly by class name from button callbacks to avoid closure-capture issues.
static func _rebuild_tag_list(vbox: VBoxContainer, prop: UAssetProperty, row: PropertyRow) -> void:
	for child in vbox.get_children():
		child.hide()
		child.queue_free()
	var tags: Array = prop.value as Array
	for i in tags.size():
		var tag_str := str(tags[i])
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 4)

		var autocomplete := _make_tag_autocomplete(tag_str, func(new_tag: String):
			tags[i] = new_tag
			prop.raw["Value"] = tags
			row.value_changed.emit(prop, null, null)
		)
		autocomplete.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(autocomplete)

		var del_btn := Button.new()
		del_btn.text = "×"
		del_btn.flat = true
		del_btn.custom_minimum_size.x = 24
		del_btn.pressed.connect(func():
			tags.remove_at(i)
			prop.raw["Value"] = tags
			row.value_changed.emit(prop, null, null)
			PropertyRow._rebuild_tag_list(vbox, prop, row)
		)
		hbox.add_child(del_btn)
		vbox.add_child(hbox)

	var add_btn := Button.new()
	add_btn.text = "+ Add Tag"
	add_btn.flat = true
	add_btn.pressed.connect(func():
		tags.append("")
		prop.raw["Value"] = tags
		PropertyRow._rebuild_tag_list(vbox, prop, row)
	)
	vbox.add_child(add_btn)
