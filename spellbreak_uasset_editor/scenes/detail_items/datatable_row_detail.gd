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
	hdr_label.add_theme_font_size_override("font_size", 16)
	_container.add_child(hdr_label)
	_add_type_badge("Row: %s" % row.struct_type)
	_add_separator()

	# Editable row key name
	_add_field_editor("Row Name", row.prop_name, func(v: String):
		if v.is_empty():
			return
		row.prop_name = v
		row.raw["Name"] = v
		hdr_label.text = v
		_ctx["set_dirty"].call()
		# Update the tree item label in-place — no full rebuild needed
		# (TreeManager.refresh_item_text only handles UAssetProperty leaves;
		#  for DataTable rows we rebuild the tree via the standard path)
		_ctx["rebuild_tree"].call()
	)

	_add_separator()
	_build_flat_leaves(row)


## Find a DataTable row's index in rows_raw by matching row name.
static func row_index(row: UAssetProperty, rows_raw: Array) -> int:
	for i in rows_raw.size():
		if (rows_raw[i] as Dictionary).get("Name") == row.prop_name:
			return i
	return -1
