class_name PropertyDetail extends DetailItem

## Detail view for a single UAssetProperty (any type).
## Handles Struct, Array, GameplayTagContainer, and all leaf value types.

var _prop: UAssetProperty


func init_data(prop: UAssetProperty) -> PropertyDetail:
	_prop = prop
	return self


func _build_impl() -> void:
	var prop := _prop

	match prop.prop_type:
		"Struct":
			_add_header(prop.prop_name)
			_add_type_badge("Struct: %s" % prop.struct_type)
			_add_separator()
			if PropertyRow.is_color_struct(prop) or PropertyRow.is_vector_struct(prop):
				_add_selectable_property_row(prop)
				_add_separator()
			_build_children_sorted(prop.children)

		"Array":
			_add_header(prop.prop_name)
			_add_type_badge("Array: %s · %d items" % [prop.array_type, prop.children.size()])
			_add_separator()
			_build_array_detail(prop)

		"Map":
			_add_header(prop.prop_name)
			_add_type_badge("Map · %d entries" % prop.children.size())
			_add_separator()
			_build_map_detail(prop)

		"MapPair":
			var pair_title := _map_pair_key_summary(prop)
			_add_header(pair_title if not pair_title.is_empty() else "Map entry")
			_add_type_badge("Map entry")
			_add_separator()
			_build_map_pair_fields(prop)

		"GameplayTagContainer":
			_add_header(prop.prop_name)
			_add_type_badge("GameplayTagContainer")
			_add_separator()
			_build_tag_container(prop)

		_:
			_add_header(prop.prop_name)
			var _tparts := prop.prop_type_full.get_slice(",", 0).split(".")
			_add_type_badge(_tparts[_tparts.size() - 1] if not _tparts.is_empty() else "")
			_add_separator()

			# Main value editor
			_add_selectable_property_row(prop)

			# Type-specific extra fields
			match prop.prop_type:
				"Text":
					_add_separator()
					_add_section_label("TEXT PROPERTIES")
					_add_text_area("CultureInvariantString", prop.culture_invariant,
						func(v): prop.culture_invariant = v; prop.raw["CultureInvariantString"] = v)
					_add_text_area("SourceString", prop.source_string,
						func(v): prop.source_string = v; prop.raw["SourceString"] = v)
					_add_field_editor("Namespace", prop.name_space,
						func(v): prop.name_space = v; prop.raw["Namespace"] = v)

				"Enum":
					_add_separator()
					_add_field_editor("EnumType", prop.enum_type,
						func(v): prop.enum_type = v; prop.raw["EnumType"] = v)

				"SoftObject":
					_add_separator()
					_add_section_label("ASSET PATH")
					if prop.value is Dictionary:
						var ap = prop.value.get("AssetPath", {})
						if ap is Dictionary:
							_add_field_editor("PackageName", str(ap.get("PackageName", "")),
								func(v): ap["PackageName"] = v if v != "" else null)
							_add_field_editor("AssetName", str(ap.get("AssetName", "")),
								func(v): ap["AssetName"] = v if v != "" else null)
						var sub = prop.value.get("SubPathString")
						_add_field_editor("SubPathString", str(sub) if sub != null else "",
							func(v): prop.value["SubPathString"] = v if v != "" else null)


# ── Text area helper (used only by Text properties) ───────────────────────────

func _add_text_area(label_text: String, current_value: String, on_change: Callable) -> void:
	_add_section_label(label_text)
	var edit := TextEdit.new()
	edit.text = current_value
	edit.placeholder_text = "(empty)"
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.scroll_fit_content_height = true
	edit.custom_minimum_size.y = 48
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var committed := {"value": current_value}
	var commit := func() -> void:
		var new_value := edit.text
		if new_value == committed["value"]:
			return
		var old_value: String = committed["value"]
		_ctx.execute("Edit %s" % label_text,
			func() -> void: on_change.call(new_value),
			func() -> void: on_change.call(old_value))
		committed["value"] = new_value
	edit.focus_exited.connect(commit)
	_container.add_child(edit)


# ── Map editor ────────────────────────────────────────────────────────────────

func _build_map_detail(prop: UAssetProperty) -> void:
	var sel := _ctx.selection
	var pairs := prop.children

	if pairs.is_empty():
		_add_info("(no entries)")

	_build_virtual(pairs.size(), func(i: int) -> void:
		var pair := pairs[i]
		var vbox := VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)

		var lbl := Label.new()
		lbl.text = "[%d]" % i
		var key_summary := _map_pair_key_summary(pair)
		if not key_summary.is_empty():
			lbl.text += "  %s" % key_summary
		AppTheme.style_section(lbl)
		vbox.add_child(lbl)

		var saved := _container
		_container = vbox
		_build_map_pair_fields(pair)
		_container = saved

		var margin := MarginContainer.new()
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		margin.add_theme_constant_override("margin_left",   AppTheme.MARGIN_SELECTABLE_H_L)
		margin.add_theme_constant_override("margin_right",  AppTheme.MARGIN_SELECTABLE_H_R)
		margin.add_theme_constant_override("margin_top",    AppTheme.MARGIN_SELECTABLE_V)
		margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_SELECTABLE_V)
		margin.add_child(vbox)

		_container.add_child(sel.make_selectable_row(
			pair, margin,
			func(ctrl: bool) -> void:
				if ctrl: sel.toggle(pair)
				else:    sel.set_selection([pair]),
			func() -> Array: return pairs
		))
	)


## Renders the editable key/value rows of one map entry into _container.
func _build_map_pair_fields(pair: UAssetProperty) -> void:
	if pair.children.size() < 2:
		_add_info("(empty entry)")
		return
	_add_selectable_property_row(pair.children[0])
	var val := pair.children[1]
	if val.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"] \
			and not val.children.is_empty() \
			and not PropertyRow.is_color_struct(val) \
			and not PropertyRow.is_vector_struct(val):
		_add_nav_button(val)
	else:
		_add_selectable_property_row(val)


## Short human-readable summary of a map entry's key.
static func _map_pair_key_summary(pair: UAssetProperty) -> String:
	if pair.children.size() < 1:
		return ""
	var summary := pair.get_display_value()
	if summary.is_empty() or summary == "null" or summary == "?":
		return ""
	return summary


# ── GameplayTagContainer editor ───────────────────────────────────────────────

func _build_tag_container(prop: UAssetProperty) -> void:
	var tags: Array = prop.value if prop.value is Array else []

	if tags.is_empty():
		_add_info("(no tags)")

	for i in tags.size():
		var ci := i
		var row := _make_row()
		row.add_child(_make_commit_line(str(tags[ci]), func(t): tags[ci] = t, "Tag.Name.Here"))
		row.add_child(_make_delete_btn(func():
			var old_tags := tags.duplicate(true)
			var new_tags := tags.duplicate(true)
			new_tags.remove_at(ci)
			_ctx.execute("Delete gameplay tag",
				func() -> void: prop.set_value(new_tags),
				func() -> void: prop.set_value(old_tags))
			_ctx.show_detail.call(prop)
		))
		_container.add_child(row)

	_add_separator()
	_container.add_child(_make_add_btn("+ Add Tag", func():
		var old_tags := tags.duplicate(true)
		var new_tags := tags.duplicate(true)
		new_tags.append("")
		_ctx.execute("Add gameplay tag",
			func() -> void: prop.set_value(new_tags),
			func() -> void: prop.set_value(old_tags))
		_ctx.show_detail.call(prop)
	))
