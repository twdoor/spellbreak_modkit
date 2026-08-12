class_name UassetFileTab extends MarginContainer

signal tab_title_changed(tab: UassetFileTab)
signal reuse_requested(tab: UassetFileTab)

## Thin orchestrator for a single open .uasset file.
## All heavy lifting is delegated to:
##   TreeManager       — tree widget state and building
##   DetailPanelBuilder — routes selections to DetailItem subclasses
##   SelectionManager  — multi-item selection state
##   ClipboardManager  — static clipboard (copy/paste/cut)
##   AssetDocument     — asset ownership, dirty state, undo, and redo

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
var _document: AssetDocument

const UASSET_TAB = preload("uid://dxsn1gcs66ay8")
# ── Components ─────────────────────────────────────────────────────────────────
var _tree_manager:    TreeManager
var _detail_builder:  DetailPanelBuilder
var _selection:       SelectionManager
var _texture_service: TextureService
var _sound_service: SoundService
var _mesh_service: MeshService
var _background_jobs: BackgroundJobRunner
var _detail_context: AssetEditorContext


static func setup(uasset: UAssetFile, texture_service: TextureService = null,
		sound_service: SoundService = null, mesh_service: MeshService = null,
		background_jobs: BackgroundJobRunner = null) -> UassetFileTab:
	var asset_name: String = uasset.file_path.get_file().get_basename()
	var tab: UassetFileTab = UASSET_TAB.instantiate()
	tab.tab_asset = uasset
	tab._document = AssetDocument.new(uasset)
	tab._base_name = asset_name
	tab._display_base = asset_name   # main.gd may override this via _refresh_tab_titles
	tab._texture_service = texture_service
	tab._sound_service = sound_service
	tab._mesh_service = mesh_service
	tab._background_jobs = background_jobs
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
## Emits a title change so main.gd can apply shared tab truncation/scrolling.
func _update_tab_title() -> void:
	set_meta("tab_full_title", get_tab_title())
	var title := (_display_base + " *") if _dirty else _display_base
	if is_inside_tree() and get_parent() is TabContainer:
		var tc := get_parent() as TabContainer
		tc.set_tab_title(tc.get_tab_idx_from_control(self), title)
	tab_title_changed.emit(self)


func get_tab_title() -> String:
	return (_display_base + " *") if _dirty else _display_base


func _ready() -> void:
	var asset_label := %AssetLabel as Label
	asset_label.text = tab_asset.file_path.get_file()
	asset_label.tooltip_text = tab_asset.file_path
	var reuse_button := %ReuseAsButton as Button
	AppTheme.style_muted_btn(reuse_button)
	reuse_button.pressed.connect(func() -> void: reuse_requested.emit(self))
	reuse_button.disabled = tab_asset.binary_path.is_empty()
	if reuse_button.disabled:
		reuse_button.tooltip_text = "Reuse As is available for binary .uasset files"

	# Instantiate components
	_selection    = SelectionManager.new()
	_tree_manager = TreeManager.new().setup(tree, tab_asset)
	_document.dirty_changed.connect(_on_document_dirty_changed)
	_detail_context = _make_context()
	_detail_builder = DetailPanelBuilder.new().setup(detail_panel, _detail_context)

	# Wire tree signals
	tree.item_selected.connect(_on_tree_selected)
	tree.item_activated.connect(_on_tree_activated)
	tree.empty_clicked.connect(func(_pos: Vector2, _btn: int) -> void: clear_selection())
	tree.columns = 1
	tree.hide_root = true

	# Track current_data from selection changes
	_selection.selection_changed.connect(_on_selection_changed)

	_tree_manager.build_tree()


func _exit_tree() -> void:
	if _detail_builder:
		_detail_builder.clear()


func load_asset(path: String) -> void:
	var loaded := UAssetFile.load_file(path)
	if loaded:
		_base_name = path.get_file().get_basename()
		_set_asset(loaded)


# ── Typed context shared with all DetailItems ──────────────────────────────────

func _make_context() -> AssetEditorContext:
	var context := AssetEditorContext.new()
	context.document = _document
	context.selection = _selection
	context.navigate_to = _navigate_to
	context.navigate_back = _navigate_back
	context.rebuild_tree = _rebuild_tree
	context.show_detail = _show_detail
	context.refresh_tree_item = _tree_manager.refresh_item_text
	context.select_tree_item = _tree_manager.select_item
	context.swap_exports = _do_swap
	context.detail_stack = _detail_stack
	context.texture_service = _texture_service
	context.sound_service = _sound_service
	context.mesh_service = _mesh_service
	context.background_jobs = _background_jobs
	context.reload_asset = _reload_asset_from_disk
	return context


func _on_document_dirty_changed(document_dirty: bool) -> void:
	_dirty = document_dirty


func _reload_asset_from_disk() -> bool:
	var path := tab_asset.binary_path if not tab_asset.binary_path.is_empty() else tab_asset.file_path
	var profile := tab_asset.game_profile
	var current_export_index := -1
	var current_export := _find_context_export()
	if current_export:
		current_export_index = tab_asset.exports.find(current_export)
	var loaded := UAssetFile.load_file(path)
	if loaded == null:
		return false
	loaded.game_profile = profile
	_set_asset(loaded)
	if current_export_index >= 0 and current_export_index < tab_asset.exports.size():
		_show_detail(tab_asset.exports[current_export_index])
	else:
		_show_detail(&"exports")
	return true


func reload_asset_from_disk() -> bool:
	return _reload_asset_from_disk()


func _set_asset(asset: UAssetFile) -> void:
	tab_asset = asset
	_current_data = null
	_detail_stack.clear()
	_selection.clear()
	_document.replace_asset(asset)
	_tree_manager.set_asset(tab_asset)
	_tree_manager.build_tree()


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
	if path.is_empty() and not _document.is_dirty():
		return OK
	var err := tab_asset.save_file(path)
	if err == OK:
		_document.mark_saved()
	return err


func is_dirty() -> bool:
	return _document != null and _document.is_dirty()


# ── Value change (from PropertyRow via DetailItem) ────────────────────────────

# ── Clipboard ──────────────────────────────────────────────────────────────────

func clear_selection() -> void:
	_selection.clear()


func copy_selection() -> Dictionary:
	return ClipboardManager.copy(_current_data, tab_asset, _selection.get_selection())


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
	ClipboardManager.paste(_detail_context, _current_data,
		_selection.get_selection(), array_context)


func cut_selection() -> Dictionary:
	var result := copy_selection()
	if not bool(result.get("ok", false)):
		return result
	delete_selection()
	return result


# ── Export reorder (called by ExportsListDetail) ───────────────────────────────

func _do_swap(a: int, b: int) -> void:
	if not _document.execute(AssetEditCommand.new(
		"Reorder exports",
		func() -> void: tab_asset.swap_exports(a, b),
		func() -> void: tab_asset.swap_exports(a, b))):
		return
	_rebuild_tree()
	_detail_stack.clear()
	_show_detail(&"exports")


# ── Delete ─────────────────────────────────────────────────────────────────────

func delete_selection() -> void:
	var sel := _selection.get_selection()

	# Multi-delete exports
	if sel.size() > 1 and sel[0] is UAssetExport:
		var snapshot := tab_asset.capture_package_tables()
		var indices: Array = sel.map(func(expo): return tab_asset.exports.find(expo))
		_document.execute(AssetEditCommand.new(
			"Delete exports",
			func() -> void: tab_asset.remove_exports(indices),
			func() -> void: tab_asset.restore_package_tables(snapshot)))
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"exports")
		return

	# Multi-delete imports
	if sel.size() > 1 and sel[0] is UAssetImport:
		var snapshot := tab_asset.capture_package_tables()
		var indices: Array = sel.map(func(imp): return tab_asset.imports.find(imp))
		_document.execute(AssetEditCommand.new(
			"Delete imports",
			func() -> void: tab_asset.remove_imports(indices),
			func() -> void: tab_asset.restore_package_tables(snapshot)))
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
		var removals: Array = []
		for item in sel:
			var idx := arr.find(item)
			if idx >= 0:
				removals.append({"index": idx, "property": item})
		removals.sort_custom(func(a, b): return a["index"] < b["index"])
		_document.execute(AssetEditCommand.new(
			"Delete properties",
			func() -> void:
				for i in range(removals.size() - 1, -1, -1):
					arr.remove_at(removals[i]["index"]),
			func() -> void:
				for removal in removals:
					arr.insert(removal["index"], removal["property"])))
		_rebuild_tree(); _detail_stack.clear()
		_show_detail(go_back_to if go_back_to != null else &"exports")
		return

	# Multi-delete name map entries (sort descending so indices stay valid)
	if sel.size() >= 1 and sel[0] is int:
		var old_names := tab_asset.name_map.duplicate()
		var new_names := old_names.duplicate()
		var sorted_idx := sel.duplicate()
		sorted_idx.sort_custom(func(a, b): return a > b)
		for i in sorted_idx:
			new_names.remove_at(i)
		_document.execute(AssetEditCommand.new(
			"Delete names",
			func() -> void: tab_asset.name_map = new_names.duplicate(),
			func() -> void: tab_asset.name_map = old_names.duplicate()))
		_current_data = null
		_detail_stack.clear(); _show_detail(&"namemap")
		return

	# Single-item deletes
	if _current_data is UAssetExport:
		var idx := tab_asset.exports.find(_current_data)
		if idx < 0: return
		var snapshot := tab_asset.capture_package_tables()
		_document.execute(AssetEditCommand.new(
			"Delete export",
			func() -> void: tab_asset.remove_export_at(idx),
			func() -> void: tab_asset.restore_package_tables(snapshot)))
		_rebuild_tree(); _detail_stack.clear(); _show_detail(&"exports")

	elif _current_data is UAssetImport:
		var idx := tab_asset.imports.find(_current_data)
		if idx < 0: return
		var snapshot := tab_asset.capture_package_tables()
		_document.execute(AssetEditCommand.new(
			"Delete import",
			func() -> void: tab_asset.remove_import_at(idx),
			func() -> void: tab_asset.restore_package_tables(snapshot)))
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
		var removed_property: UAssetProperty = _current_data
		_document.execute(AssetEditCommand.new(
			"Delete property",
			func() -> void: arr.remove_at(idx),
			func() -> void: arr.insert(idx, removed_property)))
		_rebuild_tree(); _detail_stack.clear()
		_show_detail(go_back_to if go_back_to != null else &"exports")

	elif _current_data is Dictionary and _current_data.has("dt_row"):
		var row: UAssetProperty  = _current_data["dt_row"]
		var expo: UAssetExport   = _current_data["expo"]
		var rows_raw: Array = expo.get_datatable_rows()
		var idx: int = DataTableRowDetail.row_index(row, rows_raw)
		if idx < 0: return
		var removed_raw := row.raw.duplicate(true)
		_document.execute(AssetEditCommand.new(
			"Delete data table row",
			func() -> void: rows_raw.remove_at(idx),
			func() -> void: rows_raw.insert(idx, removed_raw.duplicate(true))))
		_current_data = null
		_rebuild_tree(); _detail_stack.clear(); _show_detail(expo)


# ── Undo ───────────────────────────────────────────────────────────────────────

func undo() -> void:
	if not _document.undo():
		return
	_rebuild_tree()
	_detail_stack.clear()
	if _current_data is UAssetProperty and not _find_property_parent(_current_data).is_empty():
		_show_detail(_current_data)
	elif _current_data is UAssetExport and tab_asset.exports.has(_current_data):
		_show_detail(_current_data)
	elif _current_data is UAssetImport and tab_asset.imports.has(_current_data):
		_show_detail(&"importmap")
	elif _current_data is int:
		_show_detail(&"namemap")
	else:
		_current_data = null
		_show_detail(&"exports")


func redo() -> void:
	if not _document.redo():
		return
	_rebuild_tree()
	_detail_stack.clear()
	_current_data = null
	_show_detail(&"exports")


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
