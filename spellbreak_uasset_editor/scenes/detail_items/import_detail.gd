class_name ImportDetail extends DetailItem

## Detail view for the full imports list.
## RenderHint: DETAIL — shown in the panel when the "Imports" section header is selected.


func _build_impl() -> void:
	var asset: UAssetFile = _ctx["asset"]
	var sel: SelectionManager = _ctx["selection"]

	_add_header("Imports [%d]" % asset.imports.size())
	_add_separator()
	_add_import_header()

	_build_virtual(asset.imports.size(), func(i: int) -> void:
		var imp   := asset.imports[i]
		var index := -(i + 1)
		var row := ImportTab.setup(imp, index, func():
			if Input.is_key_pressed(KEY_SHIFT):
				sel.range_select(imp, asset.imports)
			elif Input.is_key_pressed(KEY_CTRL):
				sel.toggle(imp)
			else:
				sel.set_selection([imp])
		)
		var panel := sel.make_selectable_row(imp, row,
			func(ctrl: bool):
				if ctrl: sel.toggle(imp)
				else: sel.set_selection([imp]),
			func(): return asset.imports
		)
		_container.add_child(panel)
	)


func _add_import_header() -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	for col in [["#", 32], ["ClassPackage", 180], ["ClassName", 140], ["ObjectName", 0], ["Outer", 72]]:
		var lbl := Label.new()
		lbl.text = col[0]
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
		if col[1] > 0:
			lbl.custom_minimum_size.x = col[1]
		else:
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(lbl)
	_container.add_child(hbox)
