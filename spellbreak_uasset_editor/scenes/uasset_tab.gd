class_name UassetFileTab extends MarginContainer

@export var tree: Tree
@export var detail_panel: VBoxContainer

var tab_asset: UAssetFile
var _item_map: Dictionary = {}
var _detail_stack: Array = []

## Shared clipboard across all tabs: {"type": "export"/"import"/"property", "raw": Dictionary}
static var _clipboard: Dictionary = {}

## Undo stack — each entry has an "action" key describing what to reverse
const MAX_UNDO := 50
var _undo_stack: Array = []

var _base_name: String = ""
var _dirty: bool = false:
	set(value):
		_dirty = value
		name = (_base_name + " *") if _dirty else _base_name

const UASSET_TAB = preload("uid://dxsn1gcs66ay8")


static func setup(uasset: UAssetFile) -> UassetFileTab:
	var asset_name: String = uasset.file_path.get_file().get_basename()
	var tab = UASSET_TAB.instantiate()
	tab.tab_asset = uasset
	tab._base_name = asset_name
	tab.name = asset_name
	return tab


func _ready() -> void:
	tree.item_selected.connect(_on_tree_selected)
	tree.item_activated.connect(_on_tree_activated)
	tree.columns = 1
	tree.hide_root = true
	build_tree()


func load_asset(path: String) -> void:
	tab_asset = UAssetFile.load_file(path)
	if tab_asset:
		_base_name = path.get_file().get_basename()
		_dirty = false  # fresh load, triggers setter to set name cleanly
		build_tree()


#region Tree

func build_tree() -> void:
	if not tab_asset or not tree:
		return
	tree.clear()
	_item_map.clear()
	var root := tree.create_item()

	var names_item := _add_section(root, "NameMap [%d]" % tab_asset.name_map.size())
	_item_map[names_item] = &"namemap"

	var imports_item := _add_section(root, "Imports [%d]" % tab_asset.imports.size())
	_item_map[imports_item] = &"importmap"

	var exports_item := _add_section(root, "Exports [%d]" % tab_asset.exports.size())
	_item_map[exports_item] = &"exports"
	for i in tab_asset.exports.size():
		var expo := tab_asset.exports[i]
		var ei := tree.create_item(exports_item)
		ei.set_text(0, "[%d] %s" % [i + 1, expo.object_name])
		ei.collapsed = true
		_item_map[ei] = expo
		for prop in expo.properties:
			if prop.prop_type in ["Struct", "Array", "GameplayTagContainer"]:
				_add_property_to_tree(ei, prop)
		# DataTable: add rows directly to the tree
		if expo.export_type == "DataTableExport":
			var table_raw: Variant = expo.raw.get("Table")
			if table_raw is Dictionary:
				var rows_raw: Variant = table_raw.get("Data")
				if rows_raw is Array and not (rows_raw as Array).is_empty():
					var table_item := tree.create_item(ei)
					table_item.set_text(0, "Table [%d rows]" % (rows_raw as Array).size())
					table_item.collapsed = false
					for row_dict in (rows_raw as Array):
						if row_dict is Dictionary:
							var row := UAssetProperty.from_dict(row_dict)
							var ri := tree.create_item(table_item)
							ri.set_text(0, row.prop_name)
							ri.collapsed = true
							_item_map[ri] = {"dt_row": row, "expo": expo}
							for child in row.children:
								if child.prop_type in ["Struct", "Array", "GameplayTagContainer"]:
									_add_property_to_tree(ri, child)


## Rebuild the tree while keeping the user's expanded/selected state intact.
## Use this instead of build_tree() for operations that mutate data in-place.
func _rebuild_tree_preserving_state() -> void:
	# Snapshot: which data objects had their item expanded, and which was selected
	var expanded: Dictionary = {}
	var selected_data: Variant = null
	for item: TreeItem in _item_map:
		var mapped: Variant = _item_map[item]
		# Dictionary items (e.g. DataTable rows) can't be used as dict keys safely; skip
		if not mapped is Dictionary and not item.collapsed:
			expanded[mapped] = true
		if tree.get_selected() == item:
			selected_data = mapped

	build_tree()

	# Restore expanded flags
	for item: TreeItem in _item_map:
		var mapped: Variant = _item_map[item]
		if not mapped is Dictionary and expanded.has(mapped):
			item.collapsed = false

	# Restore selection if the data object still exists in the new tree.
	# Skip StringName entries — they are section headers, not selectable data items.
	if selected_data != null and not selected_data is StringName:
		for item: TreeItem in _item_map:
			var mapped: Variant = _item_map[item]
			if mapped is StringName:
				continue
			# Guard: Dictionary and Object can't be compared with == across types
			if typeof(mapped) != typeof(selected_data):
				continue
			if mapped == selected_data:
				tree.set_selected(item, 0)
				break


func _add_section(parent: TreeItem, text: String) -> TreeItem:
	var item := tree.create_item(parent)
	item.set_text(0, text)
	item.collapsed = true
	return item


func _add_property_to_tree(parent: TreeItem, prop: UAssetProperty) -> TreeItem:
	var item := tree.create_item(parent)
	_item_map[item] = prop

	match prop.prop_type:
		"Struct":
			item.set_text(0, "%s [%s]" % [prop.prop_name, prop.struct_type])
			for child in prop.children:
				if child.prop_type in ["Struct", "Array", "GameplayTagContainer"]:
					_add_property_to_tree(item, child)
		"Array":
			item.set_text(0, "%s [%d items]" % [prop.prop_name, prop.children.size()])
			for i in prop.children.size():
				var child := prop.children[i]
				if child.prop_type in ["Struct", "Array", "GameplayTagContainer"]:
					var ci := _add_property_to_tree(item, child)
					if child.prop_name.is_empty() or child.prop_name == prop.prop_name:
						ci.set_text(0, "[%d] %s" % [i, ci.get_text(0)])
		"GameplayTagContainer":
			var count: int = prop.value.size() if prop.value is Array else 0
			item.set_text(0, "%s [%d tags]" % [prop.prop_name, count])

	item.collapsed = true
	return item

#endregion

#region DetailPanel

func _on_tree_selected() -> void:
	var selected := tree.get_selected()
	if not selected or not _item_map.has(selected):
		return
	_detail_stack.clear()
	_show_detail(_item_map[selected])


func _on_tree_activated() -> void:
	var item := tree.get_selected()
	if item:
		item.collapsed = not item.collapsed


## Find and select the tree item for a given data object, expanding its parents so it is visible.
func _select_tree_item(data: Variant) -> void:
	for item in _item_map:
		if _item_map[item] is StringName:
			continue
		if _item_map[item] == data:
			# Expand all ancestors
			var parent: TreeItem = item.get_parent()
			while parent and parent != tree.get_root():
				parent.collapsed = false
				parent = parent.get_parent()
			item.collapsed = false
			tree.set_selected(item, 0)
			tree.scroll_to_item(item)
			return


func _show_detail(data: Variant) -> void:
	_clear_detail()
	if data is UAssetProperty:
		_build_property_detail(data)
	elif data is UAssetExport:
		_build_export_detail(data)
	elif data is Dictionary and data.has("dt_row"):
		_build_datatable_row_detail(data["dt_row"], data["expo"])
	elif data is StringName and data == &"namemap":
		_build_namemap_detail()
	elif data is StringName and data == &"importmap":
		_build_import_detail()
	elif data is StringName and data == &"exports":
		_build_exports_list()


func _navigate_to(data: Variant, label: String) -> void:
	_detail_stack.append({"data": _current_data, "label": label})
	_show_detail(data)


func _navigate_back() -> void:
	if _detail_stack.is_empty():
		return
	var prev = _detail_stack.pop_back()
	_show_detail(prev["data"])


var _current_data: Variant = null

## Multi-select: items currently selected in a list view (imports/exports/name-map indices).
var _selection: Array = []
## Last single-clicked item — used as the anchor for shift+click range selection.
var _last_selected_anchor: Variant = null
## Maps each selectable item to its PanelContainer row for highlight updates.
var _row_panels: Dictionary = {}

const _COLOR_SELECTED := Color(0.15, 0.38, 0.70, 0.55)
const _COLOR_NORMAL   := Color(0.0,  0.0,  0.0,  0.0)


func _set_selection(items: Array) -> void:
	_selection = items.duplicate()
	if _selection.size() == 1:
		_current_data = _selection[0]
		_last_selected_anchor = _selection[0]
	_update_row_highlights()


func _toggle_in_selection(item: Variant) -> void:
	var idx := _selection.find(item)
	if idx >= 0:
		_selection.remove_at(idx)
	else:
		_selection.append(item)
		_last_selected_anchor = item
	if _selection.size() == 1:
		_current_data = _selection[0]
	elif _selection.is_empty():
		_current_data = null
	_update_row_highlights()


## Select all items in ordered_list between _last_selected_anchor and target (inclusive).
## ordered_list accepts Array or Array[T] (passed as Variant to avoid typed-array type errors).
func _range_select(target: Variant, ordered_list: Variant) -> void:
	var list: Array = []
	for item in ordered_list:
		list.append(item)
	var anchor: Variant = _last_selected_anchor if _last_selected_anchor != null else target
	var a := list.find(anchor)
	var b := list.find(target)
	if a < 0 or b < 0:
		_set_selection([target])
		return
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var new_sel: Array = []
	for i in range(lo, hi + 1):
		new_sel.append(list[i])
	_selection = new_sel.duplicate()
	if _selection.size() == 1:
		_current_data = _selection[0]
	_update_row_highlights()
	# Anchor stays fixed so repeated shift+clicks extend from the same anchor


func _update_row_highlights() -> void:
	for key in _row_panels:
		var panel: PanelContainer = _row_panels[key]
		if not is_instance_valid(panel):
			continue
		var selected: bool = key in _selection
		var style := StyleBoxFlat.new()
		style.bg_color = _COLOR_SELECTED if selected else _COLOR_NORMAL
		panel.add_theme_stylebox_override("panel", style)


## Wrap a row node in a selectable PanelContainer, registered under key.
## click_handler receives (ctrl_held: bool).
## get_list (optional): callable that returns the full ordered Array for shift+click range selection.
func _make_selectable_row(key: Variant, inner: Control, click_handler: Callable, get_list: Callable = Callable()) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = _COLOR_NORMAL
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(inner)
	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if event.shift_pressed and not get_list.is_null():
				_range_select(key, get_list.call())
			else:
				click_handler.call(event.ctrl_pressed)
	)
	_row_panels[key] = panel
	return panel


func _build_property_detail(prop: UAssetProperty) -> void:
	_current_data = prop

	if not _detail_stack.is_empty():
		_add_back_button()

	match prop.prop_type:
		"Struct":
			_add_header(prop.prop_name)
			_add_type_badge("Struct: %s" % prop.struct_type)
			_add_separator()
			_build_children_sorted(prop.children)

		"Array":
			_add_header(prop.prop_name)
			_add_type_badge("Array: %s · %d items" % [prop.array_type, prop.children.size()])
			_add_separator()
			_build_array_detail(prop)

		"GameplayTagContainer":
			_add_header(prop.prop_name)
			_add_type_badge("GameplayTagContainer")
			_add_separator()
			_build_tag_container(prop)

		_:
			_add_header(prop.prop_name)
			var _tparts := prop.prop_type_full.get_slice(",", 0).split(".")
			_add_type_badge(_tparts[_tparts.size() - 1] if not _tparts.is_empty() else "")
			_add_separator()

			# Main value editor
			var row := PropertyRow.create(prop, tab_asset)
			row.value_changed.connect(_on_value_changed)
			detail_panel.add_child(row)

			# Type-specific extra fields
			match prop.prop_type:
				"Text":
					_add_separator()
					_add_section_label("TEXT PROPERTIES")
					_add_text_area("CultureInvariantString", prop.culture_invariant,
						func(v): _dirty = true; prop.culture_invariant = v; prop.raw["CultureInvariantString"] = v)
					_add_text_area("SourceString", prop.source_string,
						func(v): _dirty = true; prop.source_string = v; prop.raw["SourceString"] = v)
					_add_field_editor("Namespace", prop.name_space,
						func(v): prop.name_space = v; prop.raw["Namespace"] = v)

				"Enum":
					_add_separator()
					_add_field_editor("EnumType", prop.enum_type,
						func(v): prop.enum_type = v; prop.raw["EnumType"] = v)

				"SoftObject":
					_add_separator()
					_add_section_label("ASSET PATH")
					if prop.value is Dictionary:
						var ap = prop.value.get("AssetPath", {})
						if ap is Dictionary:
							_add_field_editor("PackageName", str(ap.get("PackageName", "")),
								func(v): ap["PackageName"] = v if v != "" else null)
							_add_field_editor("AssetName", str(ap.get("AssetName", "")),
								func(v): ap["AssetName"] = v if v != "" else null)
						var sub = prop.value.get("SubPathString")
						_add_field_editor("SubPathString", str(sub) if sub != null else "",
							func(v): prop.value["SubPathString"] = v if v != "" else null)


func _build_export_detail(expo: UAssetExport) -> void:
	_current_data = expo

	if not _detail_stack.is_empty():
		_add_back_button()

	var hdr := HBoxContainer.new()
	var hdr_label := Label.new()
	hdr_label.text = "Export: %s" % expo.object_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	hdr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hdr_label)
	var dup_btn := Button.new()
	dup_btn.text = "⎘ Duplicate"
	dup_btn.flat = true
	dup_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	dup_btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	dup_btn.pressed.connect(func():
		_clipboard = {"type": "export", "raw": expo.to_dict()}
		paste_clipboard()
	)
	hdr.add_child(dup_btn)
	detail_panel.add_child(hdr)
	_add_type_badge(expo.export_type)
	_add_separator()

	# Export metadata / reference indices
	_add_section_label("REFERENCES")
	_add_field_editor("ObjectName", expo.object_name, func(v):
		expo.object_name = v
		expo.raw["ObjectName"] = v
		hdr_label.text = "Export: %s" % v
	)
	_add_ref_row("ClassIndex", expo.class_index, func(v):
		expo.class_index = v
		expo.raw["ClassIndex"] = v
	)
	_add_ref_row("SuperIndex", expo.super_index, func(v):
		expo.super_index = v
		expo.raw["SuperIndex"] = v
	)
	_add_ref_row("OuterIndex", expo.outer_index, func(v):
		expo.outer_index = v
		expo.raw["OuterIndex"] = v
	)
	_add_ref_row("TemplateIndex", expo.template_index, func(v):
		expo.template_index = v
		expo.raw["TemplateIndex"] = v
	)
	_add_field_editor("ObjectFlags", expo.object_flags, func(v):
		expo.object_flags = v
		expo.raw["ObjectFlags"] = v
	)

	# Split: simple values up top, complex below
	var simple: Array[UAssetProperty] = []
	var complex: Array[UAssetProperty] = []
	for prop in expo.properties:
		if prop.prop_type in ["Struct", "Array", "GameplayTagContainer"]:
			complex.append(prop)
		else:
			simple.append(prop)

	if not simple.is_empty():
		_add_separator()
		_add_section_label("PROPERTIES")
		for prop in simple:
			var row := PropertyRow.create(prop, tab_asset)
			row.value_changed.connect(_on_value_changed)
			detail_panel.add_child(row)

	if not complex.is_empty():
		_add_separator()
		_add_section_label("STRUCTS & ARRAYS")
		for prop in complex:
			_add_nav_button(prop)

	# Dependency arrays — shown for every export
	_add_separator()
	_add_section_label("DEPENDENCIES")
	for field in ["CreateBeforeCreateDependencies", "CreateBeforeSerializationDependencies",
			"SerializationBeforeCreateDependencies", "SerializationBeforeSerializationDependencies"]:
		_add_dep_array_row(field, expo)


## Build the detail view for a single DataTable row.
func _build_datatable_row_detail(row: UAssetProperty, expo: UAssetExport) -> void:
	_current_data = {"dt_row": row, "expo": expo}

	var hdr_label := Label.new()
	hdr_label.text = row.prop_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	detail_panel.add_child(hdr_label)
	_add_type_badge("Row: %s" % row.struct_type)
	_add_separator()

	# Editable row key name
	_add_field_editor("Row Name", row.prop_name, func(v: String):
		if v.is_empty():
			return
		row.prop_name = v
		row.raw["Name"] = v
		hdr_label.text = v
		_dirty = true
		# Update the tree item text in-place — no full rebuild needed
		for ti: TreeItem in _item_map:
			var d: Variant = _item_map[ti]
			if d is Dictionary and d.get("dt_row") == row:
				ti.set_text(0, v)
				break
	)

	_add_separator()
	_build_flat_leaves(row)


## Find a DataTable row's index in rows_raw by matching row name.
func _datatable_row_index(row: UAssetProperty, rows_raw: Array) -> int:
	for i in rows_raw.size():
		if (rows_raw[i] as Dictionary).get("Name") == row.prop_name:
			return i
	return -1


## Shows a list of children, split into editable values and navigable complex types.
## Simple structs (all-leaf children) get flattened inline.
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

	# Simple editable values first
	for prop in simple_rows:
		var row := PropertyRow.create(prop, tab_asset)
		row.value_changed.connect(_on_value_changed)
		detail_panel.add_child(row)

	# Inline simple structs — flattened with a group header
	for prop in inline_structs:
		_add_section_label("%s [%s]" % [prop.prop_name, prop.struct_type])
		_build_flat_leaves(prop)

	# Complex types — navigate buttons
	if not nav_items.is_empty():
		if not simple_rows.is_empty() or not inline_structs.is_empty():
			_add_separator()
		for prop in nav_items:
			_add_nav_button(prop)


## Array: show items grouped, flatten simple structs inline
func _build_array_detail(prop: UAssetProperty) -> void:
	for i in prop.children.size():
		var child := prop.children[i]

		if _is_simple_struct(child):
			var label := "[%d]" % i
			if not child.struct_type.is_empty():
				label += " %s" % child.struct_type
			_add_section_label(label)
			_build_flat_leaves(child)
		elif child.prop_type in ["Struct", "Array", "GameplayTagContainer"] and not child.children.is_empty():
			_add_nav_button_indexed(child, i)
		else:
			var row := PropertyRow.create(child, tab_asset)
			row.value_changed.connect(_on_value_changed)
			detail_panel.add_child(row)

		if i < prop.children.size() - 1:
			var spacer := Control.new()
			spacer.custom_minimum_size.y = 4
			detail_panel.add_child(spacer)


## Recursively output all leaf values from a struct
func _build_flat_leaves(prop: UAssetProperty) -> void:
	if prop.prop_type == "Struct" and not prop.children.is_empty():
		for child in prop.children:
			_build_flat_leaves(child)
	elif prop.prop_type == "Array" and not prop.children.is_empty():
		_add_nav_button(prop)
	else:
		var row := PropertyRow.create(prop, tab_asset)
		row.value_changed.connect(_on_value_changed)
		detail_panel.add_child(row)


## A struct is "simple" if all descendants are leaf values (max 2 levels deep)
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


func _build_tag_container(prop: UAssetProperty) -> void:
	if not (prop.value is Array):
		prop.value = []

	var tags: Array = prop.value

	if tags.is_empty():
		_add_info("(no tags)")

	for i in tags.size():
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_theme_constant_override("separation", 6)

		var line := LineEdit.new()
		line.text = str(tags[i])
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.placeholder_text = "Tag.Name.Here"
		var ci := i
		line.text_submitted.connect(func(t):
			tags[ci] = t
		)
		line.focus_exited.connect(func():
			if is_instance_valid(line):
				tags[ci] = line.text
		)
		hbox.add_child(line)

		var del_btn := Button.new()
		del_btn.text = "✕"
		del_btn.flat = true
		del_btn.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		del_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.5, 0.5))
		del_btn.pressed.connect(func():
			tags.remove_at(ci)
			prop.value = tags
			prop.raw["Value"] = tags
			_show_detail(prop)
		)
		hbox.add_child(del_btn)
		detail_panel.add_child(hbox)

	_add_separator()
	var add_btn := Button.new()
	add_btn.text = "+ Add Tag"
	add_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_btn.flat = true
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
	add_btn.add_theme_color_override("font_hover_color", Color(0.6, 1.0, 0.6))
	add_btn.pressed.connect(func():
		tags.append("")
		prop.value = tags
		prop.raw["Value"] = tags
		_show_detail(prop)
	)
	detail_panel.add_child(add_btn)


func _build_exports_list() -> void:
	_current_data = &"exports"
	_add_header("Exports")
	_add_separator()
	for i in tab_asset.exports.size():
		var expo := tab_asset.exports[i]
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
				_range_select(expo, tab_asset.exports)
			elif Input.is_key_pressed(KEY_CTRL):
				_toggle_in_selection(expo)
			else:
				_set_selection([expo])
				_select_tree_item(expo)
				_navigate_to(expo, "[%d] %s" % [i + 1, expo.object_name])
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
			up_btn.pressed.connect(func(): _swap_exports(i, i - 1))
			row.add_child(up_btn)

		# Move-down button
		if i < tab_asset.exports.size() - 1:
			var dn_btn := Button.new()
			dn_btn.text = "↓"
			dn_btn.flat = true
			dn_btn.tooltip_text = "Move down (swap with next export, updates all index references)"
			dn_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			dn_btn.add_theme_color_override("font_hover_color", Color(0.9, 0.9, 0.9))
			dn_btn.pressed.connect(func(): _swap_exports(i, i + 1))
			row.add_child(dn_btn)

		var panel := _make_selectable_row(expo, row, func(ctrl: bool):
			if ctrl:
				_toggle_in_selection(expo)
			else:
				_set_selection([expo])
		, func(): return tab_asset.exports)
		detail_panel.add_child(panel)


func _build_import_detail() -> void:
	_current_data = &"importmap"
	_add_header("Imports [%d]" % tab_asset.imports.size())
	_add_separator()
	_add_import_header()
	for i in tab_asset.imports.size():
		_add_import_tab(tab_asset.imports[i], -(i + 1))


func _build_namemap_detail() -> void:
	_current_data = &"namemap"
	_add_header("NameMap [%d]" % tab_asset.name_map.size())
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
	detail_panel.add_child(hdr)
	for i in tab_asset.name_map.size():
		_build_name_detail(i)


func _build_name_detail(index: int) -> void:
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
	idx_btn.pressed.connect(func():
		if Input.is_key_pressed(KEY_SHIFT):
			var arr: Array = []
			for j in tab_asset.name_map.size():
				arr.append(j)
			_range_select(index, arr)
		elif Input.is_key_pressed(KEY_CTRL):
			_toggle_in_selection(index)
		else:
			_set_selection([index])
	)
	row.add_child(idx_btn)

	var line := LineEdit.new()
	line.text = tab_asset.name_map[index]
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit := func(t: String):
		if t == tab_asset.name_map[index]:
			return
		if tab_asset.has_name(t):
			line.text = tab_asset.name_map[index]  # revert duplicate
			return
		_dirty = true
		tab_asset.name_map[index] = t
	line.text_submitted.connect(commit)
	line.focus_exited.connect(func(): commit.call(line.text))
	row.add_child(line)

	var panel := _make_selectable_row(index, row, func(ctrl: bool):
		if ctrl:
			_toggle_in_selection(index)
		else:
			_set_selection([index])
	, func():
		var arr: Array = []
		for j in tab_asset.name_map.size():
			arr.append(j)
		return arr
	)
	detail_panel.add_child(panel)

#endregion

#region DetailPanel Helpers

func _clear_detail() -> void:
	for child in detail_panel.get_children():
		child.queue_free()
	_row_panels.clear()
	_selection.clear()
	_last_selected_anchor = null


func _add_back_button() -> void:
	var btn := Button.new()
	btn.text = "◂ Back"
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	btn.pressed.connect(_navigate_back)
	detail_panel.add_child(btn)


func _add_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	detail_panel.add_child(label)


func _add_type_badge(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	detail_panel.add_child(label)


func _add_section_label(text: String) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 6)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
	margin.add_child(label)
	detail_panel.add_child(margin)


func _add_separator() -> void:
	detail_panel.add_child(HSeparator.new())


func _add_info(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	detail_panel.add_child(label)


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
	detail_panel.add_child(hbox)


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
	btn.pressed.connect(func(): _navigate_to(prop, prop.prop_name))
	detail_panel.add_child(btn)


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
	btn.pressed.connect(func(): _navigate_to(prop, "[%d]" % index))
	detail_panel.add_child(btn)


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
	detail_panel.add_child(hbox)


func _add_import_tab(imp: UAssetImport, index: int) -> void:
	var tab := ImportTab.setup(imp, index, func():
		if Input.is_key_pressed(KEY_SHIFT):
			_range_select(imp, tab_asset.imports)
		elif Input.is_key_pressed(KEY_CTRL):
			_toggle_in_selection(imp)
		else:
			_set_selection([imp])
	)
	var panel := _make_selectable_row(imp, tab, func(ctrl: bool):
		if ctrl:
			_toggle_in_selection(imp)
		else:
			_set_selection([imp])
	, func(): return tab_asset.imports)
	detail_panel.add_child(panel)


## Index reference row: label + SpinBox + resolved name (same pattern as ObjectProperty).
func _add_ref_row(label_text: String, current_index: int, on_change: Callable) -> void:
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
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.rounded = true
	spin.step = 1
	spin.custom_minimum_size.x = 80
	spin.value = current_index
	hbox.add_child(spin)

	var ref_label := Label.new()
	ref_label.text = PropertyRow._resolve_ref_name(current_index, tab_asset)
	ref_label.tooltip_text = PropertyRow._resolve_ref_type(current_index, tab_asset)
	ref_label.add_theme_font_size_override("font_size", 13)
	ref_label.add_theme_color_override("font_color", Color(0.45, 0.65, 0.9))
	ref_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_label.clip_text = true
	ref_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(ref_label)

	spin.value_changed.connect(func(v):
		_dirty = true
		on_change.call(int(v))
		ref_label.text = PropertyRow._resolve_ref_name(int(v), tab_asset)
		ref_label.tooltip_text = PropertyRow._resolve_ref_type(int(v), tab_asset)
	)
	detail_panel.add_child(hbox)


func _add_text_area(label_text: String, current_value: String, on_change: Callable) -> void:
	_add_section_label(label_text)
	var edit := TextEdit.new()
	edit.text = current_value
	edit.placeholder_text = "(empty)"
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.scroll_fit_content_height = true
	edit.custom_minimum_size.y = 48
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text_changed.connect(func(): on_change.call(edit.text))
	detail_panel.add_child(edit)


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
	line.text_submitted.connect(func(t): _dirty = true; on_change.call(t))
	hbox.add_child(line)
	detail_panel.add_child(hbox)


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
	detail_panel.add_child(hbox)

## Renders a dependency index array (e.g. CreateBeforeCreateDependencies) as an editable
## comma-separated list of indices with resolved name tooltips.
func _add_dep_array_row(field: String, expo: UAssetExport) -> void:
	var raw_val = expo.raw.get(field)
	var indices: Array = raw_val if raw_val is Array else []

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = field.replace("Dependencies", "Deps")
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.tooltip_text = field
	hbox.add_child(label)

	# Build a resolved tooltip so the user can see what each index means
	var tip_parts: PackedStringArray = []
	for idx in indices:
		var resolved := _resolve_dep_index(idx)
		tip_parts.append("%d → %s" % [idx, resolved])

	var line := LineEdit.new()
	line.text = ", ".join(PackedStringArray(indices.map(func(i): return str(i))))
	line.placeholder_text = "(empty)"
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.tooltip_text = "\n".join(tip_parts) if tip_parts.size() > 0 else "(none)"
	line.text_submitted.connect(func(t: String):
		var new_indices: Array = []
		for part in t.split(","):
			var s := part.strip_edges()
			if s.is_empty():
				continue
			if s.is_valid_int():
				new_indices.append(s.to_int())
		expo.raw[field] = new_indices
		_dirty = true
		# Rebuild tooltip
		var new_tip: PackedStringArray = []
		for idx in new_indices:
			new_tip.append("%d → %s" % [idx, _resolve_dep_index(idx)])
		line.tooltip_text = "\n".join(new_tip) if new_tip.size() > 0 else "(none)"
	)
	hbox.add_child(line)
	detail_panel.add_child(hbox)


func _resolve_dep_index(idx: int) -> String:
	if idx > 0 and idx <= tab_asset.exports.size():
		return tab_asset.exports[idx - 1].object_name
	if idx < 0:
		var imp := tab_asset.get_import(idx)
		if imp:
			return imp.object_name
	return "?"

#endregion

#region Save

func _on_value_changed(prop: UAssetProperty, old_value: Variant, _new_value: Variant) -> void:
	_dirty = true
	_push_undo({"action": "set_value", "prop": prop, "value": old_value})
	_refresh_tree_item_text(prop)


func _refresh_tree_item_text(prop: UAssetProperty) -> void:
	for item in _item_map:
		if _item_map[item] is StringName:
			continue
		if _item_map[item] == prop:
			if prop.prop_type not in ["Struct", "Array"]:
				var val_str := prop.get_display_value()
				if val_str.length() > 40:
					val_str = val_str.left(37) + "..."
				item.set_text(0, "%s = %s" % [prop.prop_name, val_str])
			break


func save_asset(path: String = "") -> Error:
	if not tab_asset:
		return ERR_DOES_NOT_EXIST
	var err := tab_asset.save_file(path)
	if err == OK:
		_dirty = false
	return err

#endregion

#region Clipboard

func clear_selection() -> void:
	_selection.clear()
	_last_selected_anchor = null
	_update_row_highlights()


func copy_selection() -> void:
	# Multi-select: copy all selected items of the same type
	if _selection.size() > 1:
		if _selection[0] is UAssetImport:
			_clipboard = {"type": "import_array", "items": _selection.map(func(i): return i.to_dict())}
			return
		if _selection[0] is UAssetExport:
			_clipboard = {"type": "export_array", "items": _selection.map(func(e): return e.to_dict())}
			return
		if _selection[0] is int:  # name map indices
			_clipboard = {"type": "name_array", "items": _selection.map(func(i): return tab_asset.name_map[i])}
			return

	if _current_data is UAssetExport:
		_clipboard = {"type": "export", "raw": _current_data.to_dict()}
	elif _current_data is UAssetProperty:
		_clipboard = {"type": "property", "raw": _current_data.to_dict()}
	elif _current_data is UAssetImport:
		_clipboard = {"type": "import", "raw": _current_data.to_dict()}
	elif _current_data is int:  # name map index
		_clipboard = {"type": "name", "value": tab_asset.name_map[_current_data as int]}
	elif _current_data is Dictionary and _current_data.has("dt_row"):
		var row: UAssetProperty = _current_data["dt_row"]
		_clipboard = {"type": "dt_row", "raw": row.raw.duplicate(true), "expo": _current_data["expo"]}


## Human-readable label for the current clipboard content, used by toast messages.
func get_clipboard_label() -> String:
	if _clipboard.is_empty():
		return ""
	var raw: Dictionary = _clipboard.get("raw", {})
	match _clipboard["type"]:
		"export":        return str(raw.get("ObjectName", "export"))
		"import":        return str(raw.get("ObjectName", "import"))
		"property":      return str(raw.get("Name", raw.get("PropertyName", "property")))
		"export_array":  return "%d exports" % _clipboard["items"].size()
		"import_array":  return "%d imports" % _clipboard["items"].size()
		"name":          return str(_clipboard.get("value", "name"))
		"name_array":    return "%d names" % _clipboard["items"].size()
		"dt_row":        return str(raw.get("Name", "row"))
	return ""


func paste_clipboard() -> void:
	if _clipboard.is_empty():
		return
	match _clipboard["type"]:
		"export", "export_array":
			var raws: Array = []
			if _clipboard["type"] == "export":
				var r: Dictionary = _clipboard["raw"].duplicate(true)
				r["ObjectName"] = str(r.get("ObjectName", "Export")) + "_Copy"
				r["SerialSize"] = 0; r["SerialOffset"] = 0
				raws.append(r)
			else:
				for r in _clipboard["items"]:
					var rc: Dictionary = r.duplicate(true)
					rc["ObjectName"] = str(rc.get("ObjectName", "Export")) + "_Copy"
					rc["SerialSize"] = 0; rc["SerialOffset"] = 0
					raws.append(rc)

			# Insert position: at selected export, or append
			var insert_at := tab_asset.exports.size()
			if _selection.size() > 0 and _selection[0] is UAssetExport:
				insert_at = tab_asset.exports.find(_selection[0])

			var added: Array = []
			for i in raws.size():
				var new_expo := UAssetExport.from_dict(raws[i])
				tab_asset.exports.insert(insert_at + i, new_expo)
				_push_undo({"action": "remove_export", "export": new_expo})
				added.append(new_expo)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(added[0])
			_select_tree_item(added[0])

		"import", "import_array":
			var raws: Array = []
			if _clipboard["type"] == "import":
				raws.append(_clipboard["raw"].duplicate(true))
			else:
				for r in _clipboard["items"]:
					raws.append(r.duplicate(true))

			# Insert position: at selected import, or append
			var insert_at := tab_asset.imports.size()
			if _selection.size() > 0 and _selection[0] is UAssetImport:
				insert_at = tab_asset.imports.find(_selection[0])

			for i in raws.size():
				var new_imp := UAssetImport.from_dict(raws[i], -(insert_at + i + 1))
				tab_asset.imports.insert(insert_at + i, new_imp)
				_push_undo({"action": "remove_import", "import": new_imp})
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(&"importmap")

		"name", "name_array":
			var names: Array = []
			if _clipboard["type"] == "name":
				names.append(_clipboard["value"])
			else:
				names.append_array(_clipboard["items"])

			# Insert position: at selected name map index, or append
			var insert_at := tab_asset.name_map.size()
			if _selection.size() > 0 and _selection[0] is int:
				insert_at = _selection[0] as int

			for i in names.size():
				var n: String = str(names[i])
				if not tab_asset.has_name(n):
					tab_asset.name_map.insert(insert_at + i, n)
			_detail_stack.clear()
			_show_detail(&"namemap")

		"property":
			var raw: Dictionary = _clipboard["raw"].duplicate(true)
			var new_prop := UAssetProperty.from_dict(raw)
			var paste_into: Array = []
			var show_after: Variant = null

			if _current_data is UAssetProperty and _current_data.prop_type == "Array":
				paste_into = _current_data.children
				show_after = _current_data
			else:
				for i in range(_detail_stack.size() - 1, -1, -1):
					var d = _detail_stack[i]["data"]
					if d is UAssetProperty and d.prop_type == "Array":
						paste_into = d.children
						show_after = d
						break

			if show_after == null:
				var expo := _find_context_export()
				if expo == null:
					return
				paste_into = expo.properties
				show_after = expo

			# Insert at selected property position if one is selected
			var insert_at := paste_into.size()
			if _current_data is UAssetProperty and paste_into.has(_current_data):
				insert_at = paste_into.find(_current_data)

			paste_into.insert(insert_at, new_prop)
			_dirty = true
			_push_undo({"action": "remove_from_array", "array": paste_into, "prop": new_prop, "show": show_after})
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(show_after)

		"dt_row":
			var expo: UAssetExport = _clipboard["expo"]
			var rows_raw: Array = []
			var table_raw: Variant = expo.raw.get("Table")
			if table_raw is Dictionary:
				var dr: Variant = table_raw.get("Data")
				if dr is Array:
					rows_raw = dr as Array
			if rows_raw.is_empty():
				return
			var new_raw: Dictionary = (_clipboard["raw"] as Dictionary).duplicate(true)
			new_raw["Name"] = str(new_raw.get("Name", "Row")) + "_Copy"
			# Insert after current row if one is selected, otherwise append
			var insert_at := rows_raw.size()
			if _current_data is Dictionary and _current_data.has("dt_row"):
				var cur_row: UAssetProperty = _current_data["dt_row"]
				var cur_idx := _datatable_row_index(cur_row, rows_raw)
				if cur_idx >= 0:
					insert_at = cur_idx + 1
			rows_raw.insert(insert_at, new_raw)
			_dirty = true
			_push_undo({"action": "datatable_remove_row", "rows_raw": rows_raw, "index": insert_at, "expo": expo})
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(expo)


## Swap two exports and rewrite every positive index reference that pointed to
## either one throughout the entire file (exports, imports, properties).
func _swap_exports(a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= tab_asset.exports.size() or b >= tab_asset.exports.size():
		return

	# 1-based indices as seen in the file format
	var idx_a := a + 1
	var idx_b := b + 1

	# Swap in the array
	var tmp := tab_asset.exports[a]
	tab_asset.exports[a] = tab_asset.exports[b]
	tab_asset.exports[b] = tmp

	# Remap helper: swaps idx_a ↔ idx_b, leaves everything else alone
	var idx_remap := func(v: int) -> int:
		if v == idx_a: return idx_b
		if v == idx_b: return idx_a
		return v

	# Update export metadata references
	for expo in tab_asset.exports:
		expo.outer_index    = idx_remap.call(expo.outer_index)
		expo.class_index    = idx_remap.call(expo.class_index)
		expo.super_index    = idx_remap.call(expo.super_index)
		expo.template_index = idx_remap.call(expo.template_index)
		expo.raw["OuterIndex"]    = expo.outer_index
		expo.raw["ClassIndex"]    = expo.class_index
		expo.raw["SuperIndex"]    = expo.super_index
		expo.raw["TemplateIndex"] = expo.template_index
		# Remap inside property values
		for prop in expo.properties:
			_remap_prop_indices(prop, idx_remap)

	# Update import outer indices (imports use positive values for export outers)
	for imp in tab_asset.imports:
		var new_outer: int = idx_remap.call(imp.outer_index)
		if new_outer != imp.outer_index:
			imp.outer_index = new_outer
			imp.raw["OuterIndex"] = new_outer

	_dirty = true
	_rebuild_tree_preserving_state()
	_detail_stack.clear()
	_show_detail(&"exports")


## Recursively remap positive Object index values inside a property tree.
func _remap_prop_indices(prop: UAssetProperty, remap_fn: Callable) -> void:
	if prop.prop_type == "Object":
		var v := int(prop.value) if prop.value != null else 0
		var nv: int = remap_fn.call(v)
		if nv != v:
			prop.value = nv
			prop.raw["Value"] = nv
	for child in prop.children:
		_remap_prop_indices(child, remap_fn)


func _find_context_export() -> UAssetExport:
	if _current_data is UAssetExport:
		return _current_data
	for i in range(_detail_stack.size() - 1, -1, -1):
		if _detail_stack[i]["data"] is UAssetExport:
			return _detail_stack[i]["data"]
	return null


func cut_selection() -> void:
	copy_selection()
	delete_selection()


func delete_selection() -> void:
	# Multi-delete exports
	if _selection.size() > 1 and _selection[0] is UAssetExport:
		_dirty = true
		var sorted := _selection.duplicate()
		sorted.sort_custom(func(a, b): return tab_asset.exports.find(a) > tab_asset.exports.find(b))
		for expo in sorted:
			var idx := tab_asset.exports.find(expo)
			if idx >= 0:
				_push_undo({"action": "insert_export", "index": idx, "raw": expo.to_dict()})
				tab_asset.exports.remove_at(idx)
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(&"exports")
		return

	# Multi-delete imports
	if _selection.size() > 1 and _selection[0] is UAssetImport:
		_dirty = true
		var sorted := _selection.duplicate()
		sorted.sort_custom(func(a, b): return tab_asset.imports.find(a) > tab_asset.imports.find(b))
		for imp in sorted:
			var idx := tab_asset.imports.find(imp)
			if idx >= 0:
				_push_undo({"action": "insert_import", "index": -(idx + 1), "raw": imp.to_dict()})
				tab_asset.imports.remove_at(idx)
		_current_data = null
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(&"importmap")
		return

	# Multi-delete name map entries (sort descending so indices stay valid)
	if _selection.size() >= 1 and _selection[0] is int:
		_dirty = true
		var sorted_idx := _selection.duplicate()
		sorted_idx.sort_custom(func(a, b): return a > b)
		for i in sorted_idx:
			tab_asset.name_map.remove_at(i)
		_current_data = null
		_detail_stack.clear()
		_show_detail(&"namemap")
		return

	if _current_data is UAssetExport:
		var idx := tab_asset.exports.find(_current_data)
		if idx < 0:
			return
		_dirty = true
		_push_undo({"action": "insert_export", "index": idx, "raw": _current_data.to_dict()})
		tab_asset.exports.remove_at(idx)
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(&"exports")

	elif _current_data is UAssetImport:
		var idx := tab_asset.imports.find(_current_data)
		if idx < 0:
			return
		_dirty = true
		_push_undo({"action": "insert_import", "index": -(idx + 1), "raw": _current_data.to_dict()})
		tab_asset.imports.remove_at(idx)
		_current_data = null
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(&"importmap")

	elif _current_data is UAssetProperty:
		var result := _find_property_parent(_current_data)
		if result.is_empty():
			return
		# Capture where to navigate after deletion
		var go_back_to: Variant = null
		if not _detail_stack.is_empty():
			go_back_to = _detail_stack.back()["data"]
		if go_back_to == null:
			go_back_to = _find_context_export()

		var arr: Array = result["array"]
		var idx: int = result["index"]
		_dirty = true
		_push_undo({"action": "insert_property", "array": arr, "index": idx, "raw": _current_data.to_dict()})
		arr.remove_at(idx)
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(go_back_to if go_back_to != null else &"exports")

	elif _current_data is Dictionary and _current_data.has("dt_row"):
		var row: UAssetProperty = _current_data["dt_row"]
		var expo: UAssetExport = _current_data["expo"]
		var rows_raw: Array = []
		var table_raw: Variant = expo.raw.get("Table")
		if table_raw is Dictionary:
			var dr: Variant = table_raw.get("Data")
			if dr is Array:
				rows_raw = dr as Array
		var idx := _datatable_row_index(row, rows_raw)
		if idx < 0:
			return
		_dirty = true
		_push_undo({"action": "datatable_insert_row", "rows_raw": rows_raw, "index": idx, "raw": row.raw.duplicate(true), "expo": expo})
		rows_raw.remove_at(idx)
		_current_data = null
		_rebuild_tree_preserving_state()
		_detail_stack.clear()
		_show_detail(expo)


func undo() -> void:
	if _undo_stack.is_empty():
		return
	_dirty = true
	var entry: Dictionary = _undo_stack.pop_back()
	match entry["action"]:
		"set_value":
			var prop: UAssetProperty = entry["prop"]
			prop.value = entry["value"]
			_refresh_tree_item_text(prop)
			if _current_data == prop:
				_show_detail(prop)

		"insert_export":
			var expo := UAssetExport.from_dict(entry["raw"])
			tab_asset.exports.insert(entry["index"], expo)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(expo)
			_select_tree_item(expo)

		"remove_export":
			var expo: UAssetExport = entry["export"]
			tab_asset.exports.erase(expo)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(&"exports")

		"insert_property":
			var arr: Array = entry["array"]
			var prop := UAssetProperty.from_dict(entry["raw"])
			arr.insert(entry["index"], prop)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(prop)

		"remove_property":
			var expo: UAssetExport = entry["export"]
			var prop: UAssetProperty = entry["prop"]
			expo.properties.erase(prop)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(expo)

		"remove_from_array":
			var arr: Array = entry["array"]
			var prop: UAssetProperty = entry["prop"]
			arr.erase(prop)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(entry.get("show", &"exports"))

		"insert_import":
			var imp := UAssetImport.from_dict(entry["raw"], entry["index"])
			tab_asset.imports.insert(-entry["index"] - 1, imp)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(&"importmap")

		"remove_import":
			var imp: UAssetImport = entry["import"]
			tab_asset.imports.erase(imp)
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(&"importmap")

		"datatable_remove_row":
			var rows_raw: Array = entry["rows_raw"]
			rows_raw.remove_at(entry["index"])
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(entry.get("expo", _find_context_export()))

		"datatable_insert_row":
			var rows_raw: Array = entry["rows_raw"]
			rows_raw.insert(entry["index"], entry["raw"])
			_rebuild_tree_preserving_state()
			_detail_stack.clear()
			_show_detail(entry.get("expo", _find_context_export()))


## Recursive search for a property's parent array and its index within it.
## Returns {"array": Array, "index": int} or {} if not found.
func _find_property_parent(target: UAssetProperty) -> Dictionary:
	for expo in tab_asset.exports:
		var result := _search_in_array(expo.properties, target)
		if not result.is_empty():
			return result
	return {}


func _search_in_array(arr: Array, target: UAssetProperty) -> Dictionary:
	for i in arr.size():
		if arr[i] == target:
			return {"array": arr, "index": i}
		var child: UAssetProperty = arr[i]
		if child.children.size() > 0:
			var result := _search_in_array(child.children, target)
			if not result.is_empty():
				return result
	return {}


func _push_undo(entry: Dictionary) -> void:
	_undo_stack.append(entry)
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()


#endregion
