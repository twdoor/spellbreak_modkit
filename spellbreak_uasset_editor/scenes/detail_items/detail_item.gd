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
	AppTheme.style_header(label)
	_container.add_child(label)


func _add_type_badge(text: String) -> void:
	var label := Label.new()
	label.text = text
	AppTheme.style_badge(label)
	_container.add_child(label)


func _add_section_label(text: String) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", AppTheme.MARGIN_SELECTABLE_V * 2)
	var label := Label.new()
	label.text = text
	AppTheme.style_section(label)
	margin.add_child(label)
	_container.add_child(margin)


func _add_separator() -> void:
	_container.add_child(HSeparator.new())


func _add_info(text: String) -> void:
	var label := Label.new()
	label.text = text
	AppTheme.style_dim(label)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_container.add_child(label)


func _add_info_row(key: String, value: String) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var klabel := Label.new()
	klabel.text = key
	klabel.custom_minimum_size.x = 120
	AppTheme.style_dim(klabel)
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
	AppTheme.style_nav_btn(btn)
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
	AppTheme.style_nav_btn(btn)
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
	AppTheme.style_nav_btn(btn)
	btn.pressed.connect(func(): _ctx["navigate_to"].call(prop, "[%d]" % index))
	_container.add_child(btn)


func _add_field_editor(label_text: String, current_value: String, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	AppTheme.style_dim(label)
	hbox.add_child(label)
	var line := LineEdit.new()
	line.text = current_value
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text_changed.connect(func(t): _ctx["set_dirty"].call(); on_change.call(t))
	hbox.add_child(line)
	_container.add_child(hbox)


func _add_field_int(label_text: String, current_value: int, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	AppTheme.style_dim(label)
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
			vbox.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)
			var lbl := Label.new()
			lbl.text = "[%d]" % i
			if not child.struct_type.is_empty():
				lbl.text += "  %s" % child.struct_type
			AppTheme.style_section(lbl)
			vbox.add_child(lbl)
			var saved := _container
			_container = vbox
			_build_flat_leaves(child)
			_container = saved
			content = vbox

		elif child.prop_type in ["Struct", "Array", "GameplayTagContainer"] and not child.children.is_empty():
			var vbox := VBoxContainer.new()
			vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vbox.add_theme_constant_override("separation", AppTheme.SPACING_TAGS)
			var lbl := Label.new()
			lbl.text = "[%d]" % i
			if child.prop_type == "Struct" and not child.struct_type.is_empty():
				lbl.text += "  %s" % child.struct_type
			AppTheme.style_section(lbl)
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
		margin.add_theme_constant_override("margin_left",   AppTheme.MARGIN_SELECTABLE_H_L)
		margin.add_theme_constant_override("margin_right",  AppTheme.MARGIN_SELECTABLE_H_R)
		margin.add_theme_constant_override("margin_top",    AppTheme.MARGIN_SELECTABLE_V)
		margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_SELECTABLE_V)
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
	AppTheme.style_delete_btn(btn)
	btn.pressed.connect(on_pressed)
	return btn


## Create a green "+ Label" add button.
static func _make_add_btn(label: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_add_btn(btn)
	btn.pressed.connect(on_pressed)
	return btn


## Create a standard HBoxContainer row with SPACING_FIELD separation and expand-fill.
static func _make_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	return row


## Create a LineEdit that commits on Enter and on focus loss.
## commit_fn receives (new_text: String). Marks dirty automatically when auto_dirty is true.
## Returns the LineEdit so the caller can add it to a row.
func _make_commit_line(
	current_value: String,
	commit_fn: Callable,
	placeholder: String = "",
	min_width: float = 0.0,
	expand: bool = true,
	auto_dirty: bool = true
) -> LineEdit:
	var line := LineEdit.new()
	line.text = current_value
	line.placeholder_text = placeholder
	if min_width > 0.0:
		line.custom_minimum_size.x = min_width
	if expand:
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text_submitted.connect(func(t: String) -> void:
		commit_fn.call(t)
		if auto_dirty:
			_ctx["set_dirty"].call()
	)
	line.focus_exited.connect(func() -> void:
		if is_instance_valid(line):
			commit_fn.call(line.text)
			if auto_dirty:
				_ctx["set_dirty"].call()
	)
	return line


## Add a row of column header labels.
## Each entry: [text, min_width] — width of 0 means SIZE_EXPAND_FILL.
## Optional 3rd element for font size override (e.g. AppTheme.FONT_TINY).
func _add_column_headers(columns: Array) -> void:
	var hdr := _make_row()
	for col in columns:
		var lbl := Label.new()
		lbl.text = col[0]
		lbl.add_theme_color_override("font_color", AppTheme.TEXT_VERY_MUTED)
		if col.size() > 2:
			lbl.add_theme_font_size_override("font_size", col[2])
		if col[1] > 0:
			lbl.custom_minimum_size.x = col[1]
		else:
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hdr.add_child(lbl)
	_container.add_child(hdr)


# ── Shared export reference / dependency helpers ─────────────────────────────

func _add_ref_row(label_text: String, current_index: int, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	AppTheme.style_dim(label)
	hbox.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = -2147483648
	spin.max_value = 2147483647
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.rounded = true
	spin.step = 1
	spin.custom_minimum_size.x = 80
	spin.value = current_index
	hbox.add_child(spin)

	var ref_label := Label.new()
	ref_label.text = PropertyRow._resolve_ref_name(current_index, _ctx["asset"])
	ref_label.tooltip_text = PropertyRow._resolve_ref_type(current_index, _ctx["asset"])
	AppTheme.style_ref(ref_label, AppTheme.FONT_STATUS)
	ref_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_label.clip_text = true
	ref_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(ref_label)

	spin.value_changed.connect(func(v):
		_ctx["set_dirty"].call()
		on_change.call(int(v))
		ref_label.text = PropertyRow._resolve_ref_name(int(v), _ctx["asset"])
		ref_label.tooltip_text = PropertyRow._resolve_ref_type(int(v), _ctx["asset"])
	)
	_container.add_child(hbox)


func _add_dep_array_row(field: String, expo: UAssetExport) -> void:
	var raw_val = expo.raw.get(field)
	var indices: Array = raw_val if raw_val is Array else []

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var label := Label.new()
	label.text = field.replace("Dependencies", "Deps")
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	AppTheme.style_dim(label)
	label.tooltip_text = field
	hbox.add_child(label)

	var tip_parts: PackedStringArray = []
	for idx in indices:
		tip_parts.append("%d → %s" % [idx, _resolve_dep_index(idx)])

	var line := LineEdit.new()
	line.text = ", ".join(PackedStringArray(indices.map(func(i): return str(i))))
	line.placeholder_text = "(empty)"
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.tooltip_text = "\n".join(tip_parts) if tip_parts.size() > 0 else "(none)"
	line.text_submitted.connect(func(t: String):
		var new_indices: Array = []
		for part in t.split(","):
			var s := part.strip_edges()
			if s.is_empty(): continue
			if s.is_valid_int(): new_indices.append(s.to_int())
		expo.raw[field] = new_indices
		_ctx["set_dirty"].call()
		var new_tip: PackedStringArray = []
		for idx in new_indices:
			new_tip.append("%d → %s" % [idx, _resolve_dep_index(idx)])
		line.tooltip_text = "\n".join(new_tip) if new_tip.size() > 0 else "(none)"
	)
	hbox.add_child(line)
	_container.add_child(hbox)


func _resolve_dep_index(idx: int) -> String:
	var asset: UAssetFile = _ctx["asset"]
	if idx > 0 and idx <= asset.exports.size():
		return asset.exports[idx - 1].object_name
	if idx < 0:
		var imp := asset.get_import(idx)
		if imp:
			return imp.object_name
	return "?"


func _on_row_value_changed(prop: UAssetProperty, old_value: Variant, _new_value: Variant) -> void:
	_ctx["set_dirty"].call()
	_ctx["push_undo"].call({"action": "set_value", "prop": prop, "value": old_value})
	_ctx["refresh_tree_item"].call(prop)
