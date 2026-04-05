class_name ExportsListDetail extends DetailItem

## Detail view showing all exports as a navigable list with move-up/down buttons.
## Selecting an export in this list navigates into ExportDetail.
## RenderHint: DETAIL — shown in the panel when the "Exports" section header is selected.


func _build_impl() -> void:
	var asset: UAssetFile = _ctx["asset"]
	var sel: SelectionManager = _ctx["selection"]

	_add_header("Exports")
	_add_separator()

	for i in asset.exports.size():
		var expo := asset.exports[i]
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.flat = true
		btn.text = "▸ [%d]  %s  · %s" % [i + 1, expo.object_name, expo.export_type]
		btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
		btn.pressed.connect(func():
			if Input.is_key_pressed(KEY_SHIFT):
				sel.range_select(expo, asset.exports)
			elif Input.is_key_pressed(KEY_CTRL):
				sel.toggle(expo)
			else:
				sel.set_selection([expo])
				_ctx["select_tree_item"].call(expo)
				_ctx["navigate_to"].call(expo, "[%d] %s" % [i + 1, expo.object_name])
		)
		row.add_child(btn)

		# Move-up button
		if i > 0:
			var up_btn := Button.new()
			up_btn.text = "↑"
			up_btn.flat = true
			up_btn.tooltip_text = "Move up (swap with previous export, updates all index references)"
			up_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			up_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
			up_btn.pressed.connect(func(): _request_swap(i, i - 1))
			row.add_child(up_btn)

		# Move-down button
		if i < asset.exports.size() - 1:
			var dn_btn := Button.new()
			dn_btn.text = "↓"
			dn_btn.flat = true
			dn_btn.tooltip_text = "Move down (swap with next export, updates all index references)"
			dn_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			dn_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
			dn_btn.pressed.connect(func(): _request_swap(i, i + 1))
			row.add_child(dn_btn)

		var panel := sel.make_selectable_row(expo, row,
			func(ctrl: bool):
				if ctrl: sel.toggle(expo)
				else: sel.set_selection([expo]),
			func(): return asset.exports
		)
		_container.add_child(panel)


## Ask the tab to perform a swap (context callback "swap_exports" → UassetFileTab._do_swap).
func _request_swap(a: int, b: int) -> void:
	if _ctx.has("swap_exports"):
		_ctx["swap_exports"].call(a, b)
