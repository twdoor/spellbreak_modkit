class_name DataTableRowDetail extends DetailItem

## Detail view for a single DataTable row.
## RenderHint: BOTH — rows already appear in the tree (via TreeManager),
## and selecting one shows this panel with an editable row name and flat properties.

var _row: UAssetProperty
var _expo: UAssetExport


func init_data(row: UAssetProperty, expo: UAssetExport) -> DataTableRowDetail:
	_row = row
	_expo = expo
	return self


func get_render_hint() -> RenderHint:
	return RenderHint.BOTH


func _build_impl() -> void:
	var row := _row

	var hdr_label := Label.new()
	hdr_label.text = row.prop_name
	AppTheme.style_header(hdr_label)
	_container.add_child(hdr_label)
	_add_type_badge("Row: %s" % row.struct_type)
	_add_separator()

	# Editable row key name — commits on Enter / focus-exit to avoid
	# rebuilding the tree on every keystroke.
	var name_hbox := HBoxContainer.new()
	name_hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var name_label := Label.new()
	name_label.text = "Row Name"
	name_label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	name_label.size_flags_horizontal = Control.SIZE_FILL
	AppTheme.style_dim(name_label)
	name_hbox.add_child(name_label)
	name_hbox.add_child(_make_commit_line(
		row.prop_name,
		func(v: String):
			if v.is_empty():
				return
			row.prop_name = v
			row.raw["Name"] = v
			hdr_label.text = v
			_ctx["rebuild_tree"].call()
	))
	_container.add_child(name_hbox)

	_add_separator()
	_build_flat_leaves(row)


## Find a DataTable row's index in rows_raw by matching row name.
static func row_index(row: UAssetProperty, rows_raw: Array) -> int:
	for i in rows_raw.size():
		if (rows_raw[i] as Dictionary).get("Name") == row.prop_name:
			return i
	return -1
