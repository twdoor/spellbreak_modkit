class_name CompletionDropdown extends RefCounted

## Focus-neutral in-tree dropdown used by editor text fields. Unlike PopupMenu,
## this does not steal keyboard focus from the source LineEdit.


static func make() -> PanelContainer:
	var dropdown := PanelContainer.new()
	dropdown.visible = false
	dropdown.top_level = true
	dropdown.z_index = 100
	dropdown.focus_mode = Control.FOCUS_NONE
	dropdown.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = AppTheme.BG_PANEL
	style.corner_radius_top_left = AppTheme.CORNER_RADIUS
	style.corner_radius_top_right = AppTheme.CORNER_RADIUS
	style.corner_radius_bottom_left = AppTheme.CORNER_RADIUS
	style.corner_radius_bottom_right = AppTheme.CORNER_RADIUS
	style.content_margin_left = 0
	style.content_margin_right = 0
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	dropdown.add_theme_stylebox_override("panel", style)
	return dropdown


static func clear(dropdown_list: Container) -> void:
	for child in dropdown_list.get_children():
		dropdown_list.remove_child(child)
		child.queue_free()


static func add_button(dropdown_list: VBoxContainer, text: String, pressed: Callable) -> Button:
	var item := Button.new()
	item.text = text
	item.flat = true
	item.focus_mode = Control.FOCUS_NONE
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.clip_text = true
	item.add_theme_color_override("font_color", AppTheme.TEXT_PRIMARY)
	item.add_theme_color_override("font_hover_color", AppTheme.TEXT_PRIMARY)
	item.pressed.connect(func() -> void:
		if pressed.is_valid():
			pressed.call()
	)
	dropdown_list.add_child(item)
	return item


static func show(dropdown: Control, source: Control, min_width: float = 260.0) -> void:
	var source_rect := source.get_global_rect()
	dropdown.global_position = source_rect.position + Vector2(0, source_rect.size.y)
	dropdown.custom_minimum_size.x = maxf(source_rect.size.x, min_width)
	dropdown.reset_size()
	dropdown.show()
	source.grab_focus.call_deferred()
