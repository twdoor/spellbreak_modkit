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
			_build_children_sorted(prop.children)

		"Array":
			_add_header(prop.prop_name)
			_add_type_badge("Array: %s · %d items" % [prop.array_type, prop.children.size()])
			_add_separator()
			_build_array_detail(prop)

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
						func(v): _ctx["set_dirty"].call(); prop.culture_invariant = v; prop.raw["CultureInvariantString"] = v)
					_add_text_area("SourceString", prop.source_string,
						func(v): _ctx["set_dirty"].call(); prop.source_string = v; prop.raw["SourceString"] = v)
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
	edit.text_changed.connect(func(): on_change.call(edit.text))
	_container.add_child(edit)


# ── GameplayTagContainer editor ───────────────────────────────────────────────

func _build_tag_container(prop: UAssetProperty) -> void:
	if not (prop.value is Array):
		prop.value = []

	var tags: Array = prop.value

	if tags.is_empty():
		_add_info("(no tags)")

	for i in tags.size():
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_theme_constant_override("separation", 6)

		var line := LineEdit.new()
		line.text = str(tags[i])
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.placeholder_text = "Tag.Name.Here"
		var ci := i
		line.text_submitted.connect(func(t): tags[ci] = t)
		line.focus_exited.connect(func():
			if is_instance_valid(line):
				tags[ci] = line.text
		)
		hbox.add_child(line)

		hbox.add_child(_make_delete_btn(func():
			tags.remove_at(ci)
			prop.value = tags
			prop.raw["Value"] = tags
			_ctx["show_detail"].call(prop)
		))
		_container.add_child(hbox)

	_add_separator()
	_container.add_child(_make_add_btn("+ Add Tag", func():
		tags.append("")
		prop.value = tags
		prop.raw["Value"] = tags
		_ctx["show_detail"].call(prop)
	))
