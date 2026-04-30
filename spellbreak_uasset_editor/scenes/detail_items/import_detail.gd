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
			sel.handle_click(imp, func(): return asset.imports)
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
	_add_column_headers([
		["#", 32, AppTheme.FONT_TINY],
		["ClassPackage", 180, AppTheme.FONT_TINY],
		["ClassName", 140, AppTheme.FONT_TINY],
		["ObjectName", 0, AppTheme.FONT_TINY],
		["Outer", 72, AppTheme.FONT_TINY],
	])
