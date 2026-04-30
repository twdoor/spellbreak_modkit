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
	AppTheme.style_header(hdr_label)
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
		var row := _make_row()

		row.add_child(_make_commit_line(
			str(entry[0]) if entry.size() > 0 and entry[0] != null else "",
			func(t: String): entry[0] = t,
			"Key", 180, false
		))
		row.add_child(_make_commit_line(
			str(entry[1]) if entry.size() > 1 and entry[1] != null else "",
			func(t: String): entry[1] = t,
			"Value"
		))

		var del_btn := _make_delete_btn(func() -> void:
			entries.remove_at(ci)
			table_raw["Value"] = entries
			_ctx["set_dirty"].call()
			_rebuild_entries_deferred.call_deferred(expo, table_raw)
		)
		del_btn.tooltip_text = "Remove entry [%d]" % ci
		row.add_child(del_btn)
		_container.add_child(row)

	_add_separator()

	_container.add_child(_make_add_btn("+ Add Entry", func() -> void:
		entries.append(["", ""])
		table_raw["Value"] = entries
		_ctx["set_dirty"].call()
		_ctx["show_detail"].call(expo)
	))


## Full panel rebuild — called deferred after a delete so the pressed signal finishes first.
func _rebuild_entries_deferred(expo: UAssetExport, _table_raw: Dictionary) -> void:
	_ctx["show_detail"].call(expo)
