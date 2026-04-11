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
	line.text_changed.connect(func(t): _ctx["set_dirty"].call(); on_change.call(t))
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


## Wrap a PropertyRow (or any Control) as a selectable row so clicking it sets
## the selection to that property, enabling copy/paste/cut/delete from the detail panel.
## siblings (optional): callable returning the ordered Array for shift+click range selection.
func _add_selectable_property_row(prop: UAssetProperty, siblings: Callable = Callable()) -> void:
	var sel: SelectionManager = _ctx["selection"]
	var row := PropertyRow.create(prop, _ctx["asset"])
	row.value_changed.connect(_on_row_value_changed)
	_container.add_child(sel.make_selectable_row(
		prop, row,
		func(ctrl: bool) -> void:
			if ctrl: sel.toggle(prop)
			else:    sel.set_selection([prop]),
		siblings
	))


## Recursively render all leaf values from a struct inline.
func _build_flat_leaves(prop: UAssetProperty) -> void:
	if prop.prop_type == "Struct" and not prop.children.is_empty():
		for child in prop.children:
			_build_flat_leaves(child)
	elif prop.prop_type == "Array" and not prop.children.is_empty():
		_add_nav_button(prop)
	else:
		_add_selectable_property_row(prop)


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

	var get_simple: Callable = func() -> Array: return simple_rows
	for prop in simple_rows:
		_add_selectable_property_row(prop, get_simple)

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
## Large arrays are paginated to avoid per-frame lag.
func _build_array_detail(prop: UAssetProperty) -> void:
	var sel: SelectionManager = _ctx["selection"]

	_build_virtual(prop.children.size(), func(i: int) -> void:
		var child := prop.children[i]

		# ── Build visible content ────────────────────────────────────────────
		var content: Control

		if _is_simple_struct(child):
			var vbox := VBoxContainer.new()
			vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vbox.add_theme_constant_override("separation", 3)
			var lbl := Label.new()
			lbl.text = "[%d]" % i
			if not child.struct_type.is_empty():
				lbl.text += "  %s" % child.struct_type
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
			vbox.add_child(lbl)
			var saved := _container
			_container = vbox
			_build_flat_leaves(child)
			_container = saved
			content = vbox

		elif child.prop_type in ["Struct", "Array", "GameplayTagContainer"] and not child.children.is_empty():
			var vbox := VBoxContainer.new()
			vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vbox.add_theme_constant_override("separation", 3)
			var lbl := Label.new()
			lbl.text = "[%d]" % i
			if child.prop_type == "Struct" and not child.struct_type.is_empty():
				lbl.text += "  %s" % child.struct_type
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
			vbox.add_child(lbl)
			var saved := _container
			_container = vbox
			_build_children_sorted(child.children)
			_container = saved
			content = vbox

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
	)


## ── Incremental build ─────────────────────────────────────────────────────────
## Builds all rows but spreads the work across frames so the UI never freezes.
## Each frame gets up to FRAME_BUDGET_MS milliseconds of build time; whatever
## fits gets rendered, then the function yields and continues next frame.
## All rows end up in the VBox — scrolling is entirely native with no stutter.
##
## A sentinel node is added first; if the panel is cleared while building is
## still in progress the sentinel gets freed and the coroutine stops cleanly.

func _build_virtual(total: int, build_row: Callable, _unused_row_h: float = 30.0) -> void:
	if total == 0:
		return

	# Add a sentinel as the first child so we can detect panel-clear mid-build.
	var sentinel := Node.new()
	_container.add_child(sentinel)

	const FRAME_BUDGET_MS := 12  # leave ~4 ms headroom in a 60 fps frame
	var frame_start := Time.get_ticks_msec()

	for i in total:
		# Panel was cleared (navigated away) — stop immediately.
		if not is_instance_valid(sentinel):
			return
		build_row.call(i)
		# Every 8 rows check if we've used up the frame budget.
		if i % 8 == 7 and Time.get_ticks_msec() - frame_start >= FRAME_BUDGET_MS:
			await _container.get_tree().process_frame
			if not is_instance_valid(sentinel):
				return
			frame_start = Time.get_ticks_msec()

	if is_instance_valid(sentinel):
		sentinel.queue_free()


## Create a small red "✕" delete button.
static func _make_delete_btn(on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = "✕"
	btn.flat = true
	btn.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.5, 0.5))
	btn.pressed.connect(on_pressed)
	return btn


## Create a green "+ Label" add button.
static func _make_add_btn(label: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	btn.add_theme_color_override("font_hover_color", Color(0.6, 1.0, 0.6))
	btn.pressed.connect(on_pressed)
	return btn


func _on_row_value_changed(prop: UAssetProperty, old_value: Variant, _new_value: Variant) -> void:
	_ctx["set_dirty"].call()
	_ctx["push_undo"].call({"action": "set_value", "prop": prop, "value": old_value})
	_ctx["refresh_tree_item"].call(prop)
