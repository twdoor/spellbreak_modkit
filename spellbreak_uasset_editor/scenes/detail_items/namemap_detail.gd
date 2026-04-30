class_name NamemapDetail extends DetailItem

## Detail view for the full name map: editable index→name rows with multi-select.
## RenderHint: DETAIL — shown in the panel when the "NameMap" section header is selected.


func _build_impl() -> void:
	var asset: UAssetFile = _ctx["asset"]

	_add_header("NameMap [%d]" % asset.name_map.size())
	_add_separator()
	_add_column_headers([["#", 40], ["Name", 0]])

	_build_virtual(asset.name_map.size(), _build_name_row)


func _build_name_row(index: int) -> void:
	var asset: UAssetFile = _ctx["asset"]
	var sel: SelectionManager = _ctx["selection"]
	var row := _make_row()

	# Index badge — click to select
	var idx_btn := Button.new()
	idx_btn.text = str(index)
	idx_btn.flat = true
	idx_btn.focus_mode = Control.FOCUS_NONE
	idx_btn.custom_minimum_size.x = 40
	idx_btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	AppTheme.style_index(idx_btn)
	var _get_indices := func() -> Array:
		var arr: Array = []
		for j in asset.name_map.size():
			arr.append(j)
		return arr
	idx_btn.pressed.connect(func():
		sel.handle_click(index, _get_indices)
	)
	row.add_child(idx_btn)

	# Forward-declare so the commit callable can access the LineEdit for rejection
	var line: LineEdit
	line = _make_commit_line(
		asset.name_map[index],
		func(t: String):
			if t == asset.name_map[index]:
				return
			if asset.has_name(t):
				line.text = asset.name_map[index]
				return
			_ctx["set_dirty"].call()
			asset.name_map[index] = t,
		"", 0.0, true, false
	)
	row.add_child(line)

	var panel := sel.make_selectable_row(index, row,
		func(ctrl: bool):
			if ctrl: sel.toggle(index)
			else: sel.set_selection([index]),
		_get_indices
	)
	_container.add_child(panel)
