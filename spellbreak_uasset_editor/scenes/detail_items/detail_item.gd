class_name DetailItem extends RefCounted

## Base class for all detail-panel and tree-item renderers.
##
## Subclasses implement _build_impl() to populate a VBoxContainer,
## and optionally override get_render_hint() and build_tree_item().
##
## Context dict keys (passed via setup()):
##   "asset"            : UAssetFile
##   "selection"        : SelectionManager
##   "navigate_to"      : Callable  (data: Variant, label: String)
##   "navigate_back"    : Callable  ()
##   "set_dirty"        : Callable  ()
##   "push_undo"        : Callable  (entry: Dictionary)
##   "rebuild_tree"     : Callable  ()
##   "show_detail"      : Callable  (data: Variant)
##   "refresh_tree_item": Callable  (prop: UAssetProperty)
##   "select_tree_item" : Callable  (data: Variant)
##   "paste"            : Callable  ()
##   "detail_stack"     : Array     (direct reference, read-only in detail items)

enum RenderHint {
	DETAIL,  ## Only appears in the detail panel (default)
	TREE,    ## Only appears as tree items
	BOTH     ## Appears in the tree AND has a detail-panel view
}

var _container: Control
var _ctx: Dictionary


func setup(ctx: Dictionary) -> DetailItem:
	_ctx = ctx
	return self


## Override to declare where this item renders. Default: detail panel only.
func get_render_hint() -> RenderHint:
	return RenderHint.DETAIL


## Called by DetailPanelBuilder. Stores the container and delegates to _build_impl().
func build_detail(container: Control) -> void:
	_container = container
	_build_impl()


## Override this to populate _container with UI nodes.
func _build_impl() -> void:
	pass


## Override to add tree children when RenderHint is TREE or BOTH.
func build_tree_item(_parent: TreeItem) -> void:
	pass


# ── Shared UI primitive helpers ───────────────────────────────────────────────

func _add_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	_container.add_child(label)


func _add_type_badge(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_container.add_child(label)


func _add_section_label(text: String) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 6)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
	margin.add_child(label)
	_container.add_child(margin)


func _add_separator() -> void:
	_container.add_child(HSeparator.new())


func _add_info(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_container.add_child(label)


func _add_info_row(key: String, value: String) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var klabel := Label.new()
	klabel.text = key
	klabel.custom_minimum_size.x = 120
	klabel.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(klabel)
	var vlabel := Label.new()
	vlabel.text = value
	vlabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vlabel.clip_text = true
	hbox.add_child(vlabel)
	_container.add_child(hbox)


func _add_back_button() -> void:
	var btn := Button.new()
	btn.text = "◂ Back"
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	btn.pressed.connect(_ctx["navigate_back"])
	_container.add_child(btn)


func _add_nav_button(prop: UAssetProperty) -> void:
	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.flat = true
	match prop.prop_type:
		"Struct":
			btn.text = "▸ %s  [%s · %d]" % [prop.prop_name, prop.struct_type, prop.children.size()]
		"Array":
			btn.text = "▸ %s  [%d items]" % [prop.prop_name, prop.children.size()]
		"GameplayTagContainer":
			var count: int = prop.value.size() if prop.value is Array else 0
			btn.text = "▸ %s  [%d tags]" % [prop.prop_name, count]
		_:
			btn.text = "▸ %s" % prop.prop_name
	btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	btn.pressed.connect(func(): _ctx["navigate_to"].call(prop, prop.prop_name))
	_container.add_child(btn)


func _add_nav_button_indexed(prop: UAssetProperty, index: int) -> void:
	var btn := Button.new()
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.flat = true
	var label := "[%d]" % index
	if prop.prop_type == "Struct" and not prop.struct_type.is_empty():
		label += " %s" % prop.struct_type
	btn.text = "▸ %s  [%d children]" % [label, prop.children.size()]
	btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	btn.pressed.connect(func(): _ctx["navigate_to"].call(prop, "[%d]" % index))
	_container.add_child(btn)


func _add_field_editor(label_text: String, current_value: String, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(label)
	var line := LineEdit.new()
	line.text = current_value
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text_submitted.connect(func(t): _ctx["set_dirty"].call(); on_change.call(t))
	hbox.add_child(line)
	_container.add_child(hbox)


func _add_field_int(label_text: String, current_value: int, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = -2147483648
	spin.max_value = 2147483647
	spin.value = current_value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(func(v): on_change.call(int(v)))
	hbox.add_child(spin)
	_container.add_child(hbox)


# ── Shared property-building helpers (used by property and datatable subclasses) ──

## A struct is "simple" if all descendants are leaf values (max 2 levels deep).
func _is_simple_struct(prop: UAssetProperty) -> bool:
	if prop.prop_type != "Struct":
		return false
	for child in prop.children:
		if child.prop_type == "Array" and not child.children.is_empty():
			return false
		if child.prop_type == "Struct" and not child.children.is_empty():
			for gc in child.children:
				if gc.prop_type in ["Struct", "Array"] and not gc.children.is_empty():
					return false
	return true


## Recursively render all leaf values from a struct inline.
func _build_flat_leaves(prop: UAssetProperty) -> void:
	if prop.prop_type == "Struct" and not prop.children.is_empty():
		for child in prop.children:
			_build_flat_leaves(child)
	elif prop.prop_type == "Array" and not prop.children.is_empty():
		_add_nav_button(prop)
	else:
		var row := PropertyRow.create(prop, _ctx["asset"])
		row.value_changed.connect(_on_row_value_changed)
		_container.add_child(row)


## Render children split into: simple editable values, inline simple structs, nav buttons.
func _build_children_sorted(children: Array[UAssetProperty]) -> void:
	var simple_rows: Array[UAssetProperty] = []
	var inline_structs: Array[UAssetProperty] = []
	var nav_items: Array[UAssetProperty] = []

	for child in children:
		if child.prop_type == "Struct" and _is_simple_struct(child):
			inline_structs.append(child)
		elif child.prop_type in ["Struct", "Array", "GameplayTagContainer"] and not child.children.is_empty():
			nav_items.append(child)
		else:
			simple_rows.append(child)

	for prop in simple_rows:
		var row := PropertyRow.create(prop, _ctx["asset"])
		row.value_changed.connect(_on_row_value_changed)
		_container.add_child(row)

	for prop in inline_structs:
		_add_section_label("%s [%s]" % [prop.prop_name, prop.struct_type])
		_build_flat_leaves(prop)

	if not nav_items.is_empty():
		if not simple_rows.is_empty() or not inline_structs.is_empty():
			_add_separator()
		for prop in nav_items:
			_add_nav_button(prop)


## Render array children as selectable rows — same click / Ctrl / Shift pattern as imports.
## Copy (Ctrl+C), paste (Ctrl+V), and delete work through the global keyboard handlers.
func _build_array_detail(prop: UAssetProperty) -> void:
	var sel: SelectionManager = _ctx["selection"]

	for i in prop.children.size():
		var child := prop.children[i]
		var ci    := i  # capture by value for lambdas

		# ── Build visible content ────────────────────────────────────────────
		var content: Control

		if _is_simple_struct(child):
			# Label + flat leaves, all inside a VBox
			var vbox := VBoxContainer.new()
			vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vbox.add_theme_constant_override("separation", 3)
			var lbl := Label.new()
			lbl.text = "[%d]" % ci
			if not child.struct_type.is_empty():
				lbl.text += "  %s" % child.struct_type
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
			vbox.add_child(lbl)
			# Temporarily redirect _container so _build_flat_leaves fills the vbox
			var saved := _container
			_container = vbox
			_build_flat_leaves(child)
			_container = saved
			content = vbox

		elif child.prop_type in ["Struct", "Array", "GameplayTagContainer"] and not child.children.is_empty():
			var btn := Button.new()
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.flat = true
			var lbl := "[%d]" % ci
			if child.prop_type == "Struct" and not child.struct_type.is_empty():
				lbl += "  %s" % child.struct_type
			btn.text = "▸ %s  [%d children]" % [lbl, child.children.size()]
			btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
			btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
			btn.pressed.connect(func() -> void: _ctx["navigate_to"].call(child, "[%d]" % ci))
			content = btn

		else:
			var row := PropertyRow.create(child, _ctx["asset"])
			row.value_changed.connect(_on_row_value_changed)
			content = row

		# ── Wrap in margin, then make selectable ─────────────────────────────
		var margin := MarginContainer.new()
		margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		margin.add_theme_constant_override("margin_left",   6)
		margin.add_theme_constant_override("margin_right",  4)
		margin.add_theme_constant_override("margin_top",    3)
		margin.add_theme_constant_override("margin_bottom", 3)
		margin.add_child(content)

		_container.add_child(sel.make_selectable_row(
			child, margin,
			func(ctrl: bool) -> void:
				if ctrl: sel.toggle(child)
				else:    sel.set_selection([child]),
			func() -> Array: return prop.children
		))

		if i < prop.children.size() - 1:
			var spacer := Control.new()
			spacer.custom_minimum_size.y = 2
			_container.add_child(spacer)


func _on_row_value_changed(prop: UAssetProperty, old_value: Variant, _new_value: Variant) -> void:
	_ctx["set_dirty"].call()
	_ctx["push_undo"].call({"action": "set_value", "prop": prop, "value": old_value})
	_ctx["refresh_tree_item"].call(prop)
