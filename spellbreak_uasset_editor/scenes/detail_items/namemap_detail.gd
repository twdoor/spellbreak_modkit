class_name NamemapDetail extends DetailItem

## Detail view for the full name map: editable index→name rows with multi-select.
## RenderHint: DETAIL — shown in the panel when the "NameMap" section header is selected.


func _build_impl() -> void:
	var asset: UAssetFile = _ctx["asset"]

	_add_header("NameMap [%d]" % asset.name_map.size())
	_add_separator()

	# Column headers
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 6)
	var hdr_idx := Label.new()
	hdr_idx.text = "#"
	hdr_idx.custom_minimum_size.x = 40
	hdr_idx.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	hdr.add_child(hdr_idx)
	var hdr_name := Label.new()
	hdr_name.text = "Name"
	hdr_name.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	hdr.add_child(hdr_name)
	_container.add_child(hdr)

	_build_virtual(asset.name_map.size(), _build_name_row)


func _build_name_row(index: int) -> void:
	var asset: UAssetFile = _ctx["asset"]
	var sel: SelectionManager = _ctx["selection"]

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)

	# Index badge — click to select
	var idx_btn := Button.new()
	idx_btn.text = str(index)
	idx_btn.flat = true
	idx_btn.focus_mode = Control.FOCUS_NONE
	idx_btn.custom_minimum_size.x = 40
	idx_btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	idx_btn.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	idx_btn.add_theme_color_override("font_hover_color", Color(0.75, 0.85, 1.0))
	var _get_indices := func() -> Array:
		var arr: Array = []
		for j in asset.name_map.size():
			arr.append(j)
		return arr
	idx_btn.pressed.connect(func():
		sel.handle_click(index, _get_indices)
	)
	row.add_child(idx_btn)

	var line := LineEdit.new()
	line.text = asset.name_map[index]
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit := func(t: String):
		if t == asset.name_map[index]:
			return
		if asset.has_name(t):
			line.text = asset.name_map[index]
			return
		_ctx["set_dirty"].call()
		asset.name_map[index] = t
	line.text_submitted.connect(commit)
	line.focus_exited.connect(func(): commit.call(line.text))
	row.add_child(line)

	var panel := sel.make_selectable_row(index, row,
		func(ctrl: bool):
			if ctrl: sel.toggle(index)
			else: sel.set_selection([index]),
		_get_indices
	)
	_container.add_child(panel)
