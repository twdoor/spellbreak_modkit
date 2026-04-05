class_name StringTableDetail extends DetailItem

## Detail view for a StringTableExport.
## UAssetAPI serializes the table as:
##   raw["Table"] = {
##     "TableNamespace": "...",
##     "Value": [ ["key", "value"], ... ]
##   }

var _expo: UAssetExport


func init_data(expo: UAssetExport) -> StringTableDetail:
	_expo = expo
	return self


func _build_impl() -> void:
	var expo := _expo

	if not (_ctx["detail_stack"] as Array).is_empty():
		_add_back_button()

	var hdr_label := Label.new()
	hdr_label.text = "StringTable: %s" % expo.object_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	_container.add_child(hdr_label)
	_add_type_badge("StringTableExport")
	_add_separator()

	var table_raw: Variant = expo.raw.get("Table")
	if not (table_raw is Dictionary):
		_add_info("(no Table data found in this export)")
		return

	# Namespace
	_add_section_label("NAMESPACE")
	_add_field_editor("TableNamespace", str(table_raw.get("TableNamespace", "")),
		func(v: String) -> void: table_raw["TableNamespace"] = v
	)

	_add_separator()
	var entries: Array = _get_entries(table_raw)
	_add_section_label("ENTRIES  (%d)" % entries.size())

	_build_entries(expo, table_raw, entries)


# ── Helpers ────────────────────────────────────────────────────────────────────

func _get_entries(table_raw: Dictionary) -> Array:
	var val: Variant = table_raw.get("Value", [])
	return val as Array if val is Array else []


func _build_entries(expo: UAssetExport, table_raw: Dictionary, entries: Array) -> void:
	if entries.is_empty():
		_add_info("(no entries)")

	for i in entries.size():
		var entry: Array = entries[i] if entries[i] is Array else ["", ""]
		var ci := i

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		# Key — fixed width
		var key_edit := LineEdit.new()
		key_edit.text = str(entry[0]) if entry.size() > 0 and entry[0] != null else ""
		key_edit.custom_minimum_size.x = 180
		key_edit.placeholder_text = "Key"
		key_edit.text_submitted.connect(func(t: String) -> void:
			entry[0] = t
			_ctx["set_dirty"].call()
		)
		key_edit.focus_exited.connect(func() -> void:
			if is_instance_valid(key_edit):
				entry[0] = key_edit.text
				_ctx["set_dirty"].call()
		)
		row.add_child(key_edit)

		# Value — expands
		var val_edit := LineEdit.new()
		val_edit.text = str(entry[1]) if entry.size() > 1 and entry[1] != null else ""
		val_edit.placeholder_text = "Value"
		val_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		val_edit.text_submitted.connect(func(t: String) -> void:
			entry[1] = t
			_ctx["set_dirty"].call()
		)
		val_edit.focus_exited.connect(func() -> void:
			if is_instance_valid(val_edit):
				entry[1] = val_edit.text
				_ctx["set_dirty"].call()
		)
		row.add_child(val_edit)

		# Delete — deferred to avoid freeing during signal emit
		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.flat = true
		del_btn.tooltip_text = "Remove entry [%d]" % ci
		del_btn.add_theme_color_override("font_color", Color(0.8, 0.3, 0.3))
		del_btn.pressed.connect(func() -> void:
			entries.remove_at(ci)
			table_raw["Value"] = entries
			_ctx["set_dirty"].call()
			_rebuild_entries_deferred.call_deferred(expo, table_raw)
		)
		row.add_child(del_btn)
		_container.add_child(row)

	_add_separator()

	# Add entry
	var add_btn := Button.new()
	add_btn.text = "+ Add Entry"
	add_btn.flat = true
	add_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_btn.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	add_btn.add_theme_color_override("font_hover_color", Color(0.6, 1.0, 0.6))
	add_btn.pressed.connect(func() -> void:
		entries.append(["", ""])
		table_raw["Value"] = entries
		_ctx["set_dirty"].call()
		_ctx["show_detail"].call(expo)
	)
	_container.add_child(add_btn)


## Full panel rebuild — called deferred after a delete so the pressed signal finishes first.
func _rebuild_entries_deferred(expo: UAssetExport, _table_raw: Dictionary) -> void:
	_ctx["show_detail"].call(expo)
