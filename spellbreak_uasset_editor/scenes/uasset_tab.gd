class_name UassetFileTab extends MarginContainer

## Thin orchestrator for a single open .uasset file.
## All heavy lifting is delegated to:
##   TreeManager       — tree widget state and building
##   DetailPanelBuilder — routes selections to DetailItem subclasses
##   SelectionManager  — multi-item selection state
##   ClipboardManager  — static clipboard (copy/paste/cut)
##   UndoManager       — bounded undo stack
##   ExportReorderer   — swap exports + remap references

@export var tree: Tree
@export var detail_panel: VBoxContainer

var tab_asset: UAssetFile
var _base_name: String = ""       ## Short stem used for duplicate detection ("MyFile")
var _display_base: String = ""    ## What actually appears in the tab — set by main.gd
var _dirty: bool = false:
	set(value):
		_dirty = value
		_update_tab_title()

## Navigation stack: [{data, label}, ...]
var _detail_stack: Array = []
## Currently focused data object (single item from last non-stack navigation).
var _current_data: Variant = null

const UASSET_TAB = preload("uid://dxsn1gcs66ay8")

# ── Components ─────────────────────────────────────────────────────────────────
var _tree_manager:    TreeManager
var _detail_builder:  DetailPanelBuilder
var _selection:       SelectionManager
var _undo_manager:    UndoManager
var _reorderer:       ExportReorderer
var _texture_service: TextureService
var _sound_service: SoundService
var _mesh_service: MeshService


static func setup(uasset: UAssetFile, texture_service: TextureService = null, sound_service: SoundService = null, mesh_service: MeshService = null) -> UassetFileTab:
	var asset_name: String = uasset.file_path.get_file().get_basename()
	var tab: UassetFileTab = UASSET_TAB.instantiate()
	tab.tab_asset = uasset
	tab._base_name = asset_name
	tab._display_base = asset_name   # main.gd may override this via _refresh_tab_titles
	tab._texture_service = texture_service
	tab._sound_service = sound_service
	tab._mesh_service = mesh_service
	tab.name = asset_name
	return tab


## Returns the disambiguated title: "ModFolder/FileName"
## ModFolder is the root directory that contains the content root folder (e.g. "g3").
## Falls back to the immediate parent folder if the content root is not found in the path.
func get_disambig_name() -> String:
	var parts := tab_asset.file_path.split("/")
	var content_root := "g3"
	if tab_asset.game_profile:
		content_root = tab_asset.game_profile.content_root
	var cr_idx := parts.find(content_root)
	var mod_folder := parts[cr_idx - 1] if cr_idx > 0 else tab_asset.file_path.get_base_dir().get_file()
	return "@" + mod_folder + "/" + _base_name


## Called by main.gd after add_child / on close, and by the _dirty setter.
## Uses set_tab_title so the label is always correct regardless of node name collisions.
func _update_tab_title() -> void:
	var title := (_display_base + " *") if _dirty else _display_base
	if is_inside_tree() and get_parent() is TabContainer:
		var tc := get_parent() as TabContainer
		tc.set_tab_title(tc.get_tab_idx_from_control(self), title)


func _ready() -> void:
	# Instantiate components
	_selection    = SelectionManager.new()
	_undo_manager = UndoManager.new()
	_reorderer    = ExportReorderer.new()
	_tree_manager = TreeManager.new().setup(tree, tab_asset)
	_detail_builder = DetailPanelBuilder.new().setup(detail_panel, _make_context())

	# Wire tree signals
	tree.item_selected.connect(_on_tree_selected)
	tree.item_activated.connect(_on_tree_activated)
	tree.empty_clicked.connect(func(_pos: Vector2, _btn: int) -> void: clear_selection())
	tree.columns = 1
	tree.hide_root = true

	# Track current_data from selection changes
	_selection.selection_changed.connect(_on_selection_changed)

	_tree_manager.build_tree()


func load_asset(path: String) -> void:
	tab_asset = UAssetFile.load_file(path)
	if tab_asset:
		_base_name = path.get_file().get_basename()
		_dirty = false
		_tree_manager.set_asset(tab_asset)
		_tree_manager.build_tree()


# ── Context dict (shared with all DetailItems) ─────────────────────────────────

func _make_context() -> Dictionary:
	return {
		"asset":             tab_asset,
		"selection":         _selection,
		"navigate_to":       _navigate_to,
		"navigate_back":     _navigate_back,
		"set_dirty":         _mark_dirty,
		"push_undo":         _undo_manager.push,
		"rebuild_tree":      _rebuild_tree,
		"show_detail":       _show_detail,
		"refresh_tree_item": _tree_manager.refresh_item_text,
		"select_tree_item":  _tree_manager.select_item,
		"paste":             paste_clipboard,
		"swap_exports":      _do_swap,
		"detail_stack":      _detail_stack,
		"texture_service":   _texture_service,
		"sound_service":     _sound_service,
		"mesh_service":      _mesh_service,
	}


func _mark_dirty() -> void:
	_dirty = true


# ── Tree events ────────────────────────────────────────────────────────────────

func _on_tree_selected() -> void:
	var selected := tree.get_selected()
	if not selected or not _tree_manager.get_item_map().has(selected):
		return
	_detail_stack.clear()
	_show_detail(_tree_manager.get_item_map()[selected])


func _on_tree_activated() -> void:
	var item := tree.get_selected()
	if item:
		item.collapsed = not item.collapsed


func _on_selection_changed(_sel: Array, current: Variant) -> void:
	_current_data = current


# ── Navigation ─────────────────────────────────────────────────────────────────

func _navigate_to(data: Variant, label: String) -> void:
	_detail_stack.append({"data": _current_data, "label": label})
	_show_detail(data)


func _navigate_back() -> void:
	if _detail_stack.is_empty():
		return
	var prev = _detail_stack.pop_back()
	_show_detail(prev["data"])


# ── Detail display ─────────────────────────────────────────────────────────────

func _show_detail(data: Variant) -> void:
	_current_data = data
	# Update selection to match, so single-click navigation keeps selection in sync
	if data is UAssetExport or data is UAssetImport or data is UAssetProperty:
		_selection.set_selection([data])
		_tree_manager.select_item(data)
	elif data is Dictionary and data.has("dt_row"):
		_selection.set_selection([data])
		_tree_manager.select_item(data)
	_detail_builder.show(data)


func _rebuild_tree() -> void:
	_tree_manager.rebuild_preserving_state()


# ── Save ───────────────────────────────────────────────────────────────────────

func save_asset(path: String = "") -> Error:
	if not tab_asset:
		return ERR_DOES_NOT_EXIST
	var err := tab_asset.save_file(path)
	if err == OK:
		_dirty = false
	return err


# ── Value change (from PropertyRow via DetailItem) ────────────────────────────

func _on_value_changed(prop: UAssetProperty, old_value: Variant, _new_value: Variant) -> void:
	_dirty = true
	_undo_manager.push({"action": "set_value", "prop": prop, "value": old_value})
	_tree_manager.refresh_item_text(prop)


# ── Clipboard ──────────────────────────────────────────────────────────────────

func clear_selection() -> void:
	_selection.clear()


func copy_selection() -> void:
	ClipboardManager.copy(_current_data, tab_asset, _selection.get_selection())


func get_clipboard_label() -> String:
	return ClipboardManager.get_label()


func paste_clipboard() -> void:
	# When an array item is selected, find its parent array so paste lands there.
	var array_context: Variant = null
	if _current_data is UAssetProperty and (_current_data as UAssetProperty).prop_type != "Array":
		var result := _find_property_parent(_current_data)
		if not result.is_empty():
			var pp: Variant = result.get("parent_prop")
			if pp is UAssetProperty and (pp as UAssetProperty).prop_type == "Array":
				array_context = pp
	ClipboardManager.paste({
		"asset":            tab_asset,
		"current_data":     _current_data,
		"detail_stack":     _detail_stack,
		"selection":        _selection.get_selection(),
		"set_dirty":        _mark_dirty,
		"push_undo":        _undo_manager.push,
		"rebuild_tree":     _rebuild_tree,
		"show_detail":      _show_detail,
		"select_tree_item": _tree_manager.select_item,
		"array_context":    array_context,
	})


func cut_selection() -> void:
	copy_selection()
	delete_selection()


# ── Export reorder (called by ExportsListDetail) ───────────────────────────────

func _do_swap(a: int, b: int) -> void:
	_reorderer.swap(a, b, tab_asset)
	_dirty = true
	_rebuild_tree()
	_detail_stack.clear()
	_show_detail(&"exports")


# ── Delete ─────────────────────────────────────────────────────────────────────

func delete_selection() -> void:
	var sel := _selection.get_selection()

	# Multi-delete exports
	if sel.size() > 1 and sel[0] is UAssetExport:
		_dirty = true
		var sorted := sel.duplicate()
		sorted.sort_custom(func(a, b): return tab_asset.exports.find(a) > tab_asset.exports.find(b))
		for expo in sorted:
			var idx := tab_asset.exports.find(expo)
			if idx >= 0:
				_undo_manager.push({"action": "insert_export", "index": idx, "raw": expo.to_dict()})
				tab_asset.exports.remove_at(idx)
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"exports")
		return

	# Multi-delete imports
	if sel.size() > 1 and sel[0] is UAssetImport:
		_dirty = true
		var sorted := sel.duplicate()
		sorted.sort_custom(func(a, b): return tab_asset.imports.find(a) > tab_asset.imports.find(b))
		for imp in sorted:
			var idx := tab_asset.imports.find(imp)
			if idx >= 0:
				_undo_manager.push({"action": "insert_import", "index": -(idx + 1), "raw": imp.to_dict()})
				tab_asset.imports.remove_at(idx)
		_current_data = null
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"importmap")
		return

	# Multi-delete array items
	if sel.size() > 1 and sel[0] is UAssetProperty:
		var result := _find_property_parent(sel[0])
		if result.is_empty(): return
		var arr: Array          = result["array"]
		var go_back_to: Variant = result.get("parent_prop")
		if go_back_to == null and not _detail_stack.is_empty():
			go_back_to = _detail_stack.back()["data"]
		if go_back_to == null:
			go_back_to = _find_context_export()
		_dirty = true
		var sorted := sel.duplicate()
		sorted.sort_custom(func(a, b): return arr.find(a) > arr.find(b))
		for item in sorted:
			var idx := arr.find(item)
			if idx < 0: continue
			_undo_manager.push({"action": "insert_property", "array": arr, "index": idx,
				"raw": (item as UAssetProperty).to_dict()})
			arr.remove_at(idx)
		_rebuild_tree(); _detail_stack.clear()
		_show_detail(go_back_to if go_back_to != null else &"exports")
		return

	# Multi-delete name map entries (sort descending so indices stay valid)
	if sel.size() >= 1 and sel[0] is int:
		_dirty = true
		var sorted_idx := sel.duplicate()
		sorted_idx.sort_custom(func(a, b): return a > b)
		for i in sorted_idx:
			tab_asset.name_map.remove_at(i)
		_current_data = null
		_detail_stack.clear(); _show_detail(&"namemap")
		return

	# Single-item deletes
	if _current_data is UAssetExport:
		var idx := tab_asset.exports.find(_current_data)
		if idx < 0: return
		_dirty = true
		_undo_manager.push({"action": "insert_export", "index": idx, "raw": _current_data.to_dict()})
		tab_asset.exports.remove_at(idx)
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"exports")

	elif _current_data is UAssetImport:
		var idx := tab_asset.imports.find(_current_data)
		if idx < 0: return
		_dirty = true
		_undo_manager.push({"action": "insert_import", "index": -(idx + 1), "raw": _current_data.to_dict()})
		tab_asset.imports.remove_at(idx)
		_current_data = null
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"importmap")

	elif _current_data is UAssetProperty:
		var result := _find_property_parent(_current_data)
		if result.is_empty(): return
		var arr: Array          = result["array"]
		var idx: int            = result["index"]
		# If item was inside an array property, go back to that array; otherwise the export
		var go_back_to: Variant = result.get("parent_prop")
		if go_back_to == null and not _detail_stack.is_empty():
			go_back_to = _detail_stack.back()["data"]
		if go_back_to == null:
			go_back_to = _find_context_export()
		_dirty = true
		_undo_manager.push({"action": "insert_property", "array": arr, "index": idx, "raw": _current_data.to_dict()})
		arr.remove_at(idx)
		_rebuild_tree(); _detail_stack.clear()
		_show_detail(go_back_to if go_back_to != null else &"exports")

	elif _current_data is Dictionary and _current_data.has("dt_row"):
		var row: UAssetProperty  = _current_data["dt_row"]
		var expo: UAssetExport   = _current_data["expo"]
		var rows_raw: Array = expo.get_datatable_rows()
		var idx := DataTableRowDetail.row_index(row, rows_raw)
		if idx < 0: return
		_dirty = true
		_undo_manager.push({"action": "datatable_insert_row", "rows_raw": rows_raw, "index": idx,
			"raw": row.raw.duplicate(true), "expo": expo})
		rows_raw.remove_at(idx)
		_current_data = null
		_rebuild_tree(); _detail_stack.clear(); _show_detail(expo)


# ── Undo ───────────────────────────────────────────────────────────────────────

func undo() -> void:
	if _undo_manager.is_empty():
		return
	_dirty = true
	var entry: Dictionary = _undo_manager.pop()
	match entry["action"]:
		"set_value":
			var prop: UAssetProperty = entry["prop"]
			prop.value = entry["value"]
			_tree_manager.refresh_item_text(prop)
			if _current_data == prop:
				_show_detail(prop)

		"insert_export":
			var expo := UAssetExport.from_dict(entry["raw"])
			tab_asset.exports.insert(entry["index"], expo)
			_rebuild_tree(); _detail_stack.clear()
			_show_detail(expo); _tree_manager.select_item(expo)

		"remove_export":
			var expo: UAssetExport = entry["export"]
			tab_asset.exports.erase(expo)
			_rebuild_tree(); _detail_stack.clear(); _show_detail(&"exports")

		"insert_property":
			var arr: Array = entry["array"]
			var prop := UAssetProperty.from_dict(entry["raw"])
			arr.insert(entry["index"], prop)
			_rebuild_tree(); _detail_stack.clear(); _show_detail(prop)

		"remove_property":
			var expo: UAssetExport   = entry["export"]
			var prop: UAssetProperty = entry["prop"]
			expo.properties.erase(prop)
			_rebuild_tree(); _detail_stack.clear(); _show_detail(expo)

		"remove_from_array":
			var arr: Array           = entry["array"]
			var prop: UAssetProperty = entry["prop"]
			arr.erase(prop)
			_rebuild_tree(); _detail_stack.clear()
			_show_detail(entry.get("show", &"exports"))

		"insert_import":
			var imp := UAssetImport.from_dict(entry["raw"], entry["index"])
			tab_asset.imports.insert(-entry["index"] - 1, imp)
			_rebuild_tree(); _detail_stack.clear(); _show_detail(&"importmap")

		"remove_import":
			var imp: UAssetImport = entry["import"]
			tab_asset.imports.erase(imp)
			_rebuild_tree(); _detail_stack.clear(); _show_detail(&"importmap")

		"datatable_remove_row":
			var rows_raw: Array = entry["rows_raw"]
			rows_raw.remove_at(entry["index"])
			_rebuild_tree(); _detail_stack.clear()
			_show_detail(entry.get("expo", _find_context_export()))

		"datatable_insert_row":
			var rows_raw: Array = entry["rows_raw"]
			rows_raw.insert(entry["index"], entry["raw"])
			_rebuild_tree(); _detail_stack.clear()
			_show_detail(entry.get("expo", _find_context_export()))


# ── Private helpers ────────────────────────────────────────────────────────────

func _find_context_export() -> UAssetExport:
	if _current_data is UAssetExport:
		return _current_data
	for i in range(_detail_stack.size() - 1, -1, -1):
		if _detail_stack[i]["data"] is UAssetExport:
			return _detail_stack[i]["data"]
	return null


## Recursive search for a property's parent array and its index within it.
## Returns {"array": Array, "index": int} or {} if not found.
func _find_property_parent(target: UAssetProperty) -> Dictionary:
	for expo in tab_asset.exports:
		var result := _search_in_array(expo.properties, target)
		if not result.is_empty():
			return result
	return {}


## parent_prop: the UAssetProperty whose .children == arr (null at top level).
func _search_in_array(arr: Array, target: UAssetProperty,
		parent_prop: UAssetProperty = null) -> Dictionary:
	for i in arr.size():
		if arr[i] == target:
			return {"array": arr, "index": i, "parent_prop": parent_prop}
		var child: UAssetProperty = arr[i]
		if child.children.size() > 0:
			var result := _search_in_array(child.children, target, child)
			if not result.is_empty():
				return result
	return {}
