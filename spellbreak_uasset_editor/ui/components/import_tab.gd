class_name ImportTab extends HBoxContainer


static func setup(imp: UAssetImport, index: int, on_select: Callable = Callable(),
		on_change: Callable = Callable()) -> ImportTab:
	var tab := ImportTab.new()
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	# Index badge — clickable button when a selection callback is provided
	var idx_btn := Button.new()
	idx_btn.text = str(index)
	idx_btn.flat = true
	idx_btn.focus_mode = Control.FOCUS_NONE
	idx_btn.custom_minimum_size.x = 32
	idx_btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	AppTheme.style_index(idx_btn)
	if on_select.is_valid():
		idx_btn.pressed.connect(on_select)
	tab.add_child(idx_btn)

	# ClassPackage
	tab.add_child(_make_edit(imp.class_package, 180, func(t):
		if imp.class_package != t:
			var old := imp.class_package
			_apply_change(on_change, "Edit import class package",
				func() -> void: imp.class_package = t,
				func() -> void: imp.class_package = old)))

	# ClassName
	tab.add_child(_make_edit(imp.class_name_str, 140, func(t):
		if imp.class_name_str != t:
			var old := imp.class_name_str
			_apply_change(on_change, "Edit import class name",
				func() -> void: imp.class_name_str = t,
				func() -> void: imp.class_name_str = old)))

	# ObjectName
	tab.add_child(_make_edit(imp.object_name, 0, func(t):
		if imp.object_name != t:
			var old := imp.object_name
			_apply_change(on_change, "Edit import object name",
				func() -> void: imp.object_name = t,
				func() -> void: imp.object_name = old), true))

	# OuterIndex
	var outer := SpinBox.new()
	outer.min_value = -2147483648
	outer.max_value = 2147483647
	outer.allow_greater = true
	outer.allow_lesser = true
	outer.update_on_text_changed = true
	outer.rounded = true
	outer.value = imp.outer_index
	outer.custom_minimum_size.x = 72
	outer.value_changed.connect(func(v):
		var new_value := int(v)
		if imp.outer_index != new_value:
			var old_value := imp.outer_index
			_apply_change(on_change, "Edit import outer index",
				func() -> void: imp.outer_index = new_value,
				func() -> void: imp.outer_index = old_value))
	tab.add_child(outer)

	## PackageName
	#tab.add_child(_make_edit(imp.package_name, 220, func(t): imp.package_name = t))

	return tab


static func _make_edit(text: String, min_width: int, on_submit: Callable, expand: bool = false) -> LineEdit:
	var line := LineEdit.new()
	line.text = text
	line.placeholder_text = "-"
	if min_width > 0:
		line.custom_minimum_size.x = min_width
	if expand:
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text_submitted.connect(on_submit)
	line.focus_exited.connect(func(): on_submit.call(line.text))
	return line


static func _apply_change(on_change: Callable, label: String,
		apply_action: Callable, revert_action: Callable) -> void:
	if on_change.is_valid():
		on_change.call(label, apply_action, revert_action)
	else:
		apply_action.call()
