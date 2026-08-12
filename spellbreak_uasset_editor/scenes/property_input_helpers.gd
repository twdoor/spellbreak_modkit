class_name PropertyInputHelpers extends RefCounted

## Autocomplete controls for gameplay tags and named numeric constants.

static func make_tag_autocomplete(current: String, on_change: Callable,
		tag_list: Array = []) -> Control:
	var line := LineEdit.new()
	line.text = current
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dropdown := CompletionDropdown.make()
	var dropdown_list := VBoxContainer.new()
	dropdown.add_child(dropdown_list)
	line.add_child(dropdown)
	var committed := {"value": current}
	var commit := func(value: String) -> void:
		if value != committed["value"]:
			committed["value"] = value
			on_change.call(value)
	line.text_changed.connect(func(text: String) -> void:
		CompletionDropdown.clear(dropdown_list)
		if text.length() < 2:
			dropdown.hide()
			return
		var needle := text.to_lower()
		var added := 0
		for tag in tag_list:
			if str(tag).to_lower().contains(needle):
				_add_tag_item(dropdown_list, line, dropdown, str(tag), commit)
				added += 1
				if added >= 20:
					break
		if added > 0:
			CompletionDropdown.show(dropdown, line, 280.0)
		else:
			dropdown.hide()
	)
	line.focus_exited.connect(func() -> void:
		dropdown.hide.call_deferred()
		commit.call(line.text)
	)
	line.text_submitted.connect(func(text: String) -> void:
		dropdown.hide()
		commit.call(text)
	)
	return line


static func make_tag_list_editor(prop: UAssetProperty, row: PropertyRow,
		tag_list: Array = []) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)
	rebuild_tag_list(vbox, prop, row, tag_list)
	return vbox


static func rebuild_tag_list(vbox: VBoxContainer, prop: UAssetProperty,
		row: PropertyRow, tag_list: Array = []) -> void:
	for child in vbox.get_children():
		child.hide()
		child.queue_free()
	var tags: Array = prop.value as Array
	for i in tags.size():
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)
		var autocomplete := make_tag_autocomplete(str(tags[i]), func(new_tag: String) -> void:
			var old_state := prop.capture_state()
			tags[i] = new_tag
			prop.raw["Value"] = tags
			row.value_changed.emit(prop, old_state, prop.capture_state())
		, tag_list)
		autocomplete.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(autocomplete)
		var delete_button := Button.new()
		delete_button.text = "×"
		delete_button.flat = true
		delete_button.custom_minimum_size.x = 24
		delete_button.pressed.connect(func() -> void:
			var old_state := prop.capture_state()
			tags.remove_at(i)
			prop.raw["Value"] = tags
			row.value_changed.emit(prop, old_state, prop.capture_state())
			rebuild_tag_list(vbox, prop, row, tag_list)
		)
		hbox.add_child(delete_button)
		vbox.add_child(hbox)
	var add_button := Button.new()
	add_button.text = "+ Add Tag"
	add_button.flat = true
	add_button.pressed.connect(func() -> void:
		var old_state := prop.capture_state()
		tags.append("")
		prop.raw["Value"] = tags
		row.value_changed.emit(prop, old_state, prop.capture_state())
		rebuild_tag_list(vbox, prop, row, tag_list)
	)
	vbox.add_child(add_button)


static func attach_constant_helper(spin: SpinBox, constants: Dictionary,
		is_int: bool) -> void:
	var line_edit := spin.get_line_edit()
	var tip_lines := PackedStringArray(["Constants:"])
	for key in constants:
		tip_lines.append("  %s = %s" % [key, constants[key]])
	spin.tooltip_text = "\n".join(tip_lines)
	var dropdown := CompletionDropdown.make()
	var dropdown_list := VBoxContainer.new()
	dropdown.add_child(dropdown_list)
	line_edit.add_child(dropdown)
	line_edit.focus_exited.connect(func() -> void: dropdown.hide.call_deferred())
	line_edit.text_changed.connect(func(text: String) -> void:
		if not line_edit.has_focus():
			return
		var token := _token_at_caret(text, line_edit.caret_column)
		CompletionDropdown.clear(dropdown_list)
		if token.is_empty() or token.is_valid_float():
			dropdown.hide()
			return
		var added := 0
		for key in constants:
			if str(key).to_lower().contains(token.to_lower()):
				_add_constant_item(dropdown_list, line_edit, dropdown,
						str(key), constants[key])
				added += 1
				if added >= 15:
					break
		if added > 0:
			CompletionDropdown.show(dropdown, line_edit)
		else:
			dropdown.hide()
	)
	line_edit.text_submitted.connect(func(text: String) -> void:
		var expression_text := _substitute_constants(text, constants)
		if expression_text == text:
			return
		var expression := Expression.new()
		if expression.parse(expression_text) == OK:
			var result: Variant = expression.execute()
			if not expression.has_execute_failed():
				spin.value = float(int(result)) if is_int else float(result)
	)


static func _add_tag_item(container: VBoxContainer, line_edit: LineEdit,
		dropdown: Control, text: String, selected: Callable) -> void:
	CompletionDropdown.add_button(container, text, func() -> void:
		line_edit.set_block_signals(true)
		line_edit.text = text
		line_edit.set_block_signals(false)
		line_edit.caret_column = text.length()
		dropdown.hide()
		line_edit.grab_focus.call_deferred()
		selected.call(text)
	)


static func _add_constant_item(container: VBoxContainer, line_edit: LineEdit,
		dropdown: Control, constant_name: String, value: Variant) -> void:
	CompletionDropdown.add_button(container, "%s  =  %s" % [constant_name, value],
			func() -> void: _insert_constant(line_edit, dropdown, constant_name))


static func _insert_constant(line_edit: LineEdit, dropdown: Control,
		constant_name: String) -> void:
	var bounds := _token_bounds(line_edit.text, line_edit.caret_column)
	line_edit.text = line_edit.text.substr(0, bounds[0]) + constant_name \
			+ line_edit.text.substr(bounds[1])
	line_edit.caret_column = bounds[0] + constant_name.length()
	dropdown.hide()
	line_edit.grab_focus.call_deferred()


static func _substitute_constants(text: String, constants: Dictionary) -> String:
	var result := text
	for key in constants:
		var regex := RegEx.new()
		regex.compile("(?i)\\b" + str(key) + "\\b")
		result = regex.sub(result, str(constants[key]), true)
	return result


static func _token_at_caret(text: String, caret: int) -> String:
	var bounds := _token_bounds(text, caret)
	return text.substr(bounds[0], bounds[1] - bounds[0])


static func _token_bounds(text: String, caret: int) -> Array[int]:
	const SEPARATORS := " +-*/()\t"
	var start := caret
	var end := caret
	while start > 0 and not SEPARATORS.contains(text[start - 1]):
		start -= 1
	while end < text.length() and not SEPARATORS.contains(text[end]):
		end += 1
	return [start, end]
