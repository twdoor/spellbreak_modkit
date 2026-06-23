class_name DetailPanelBuilder extends RefCounted

## Routes a data object to the correct DetailItem subclass and mounts it in the panel.
## Owns the "what's shown in the detail panel" concern; UassetFileTab owns state management.
##
## AssetEditorContext is shared with each DetailItem. Add new item types by creating
## a DetailItem subclass and registering it in _resolve_item().

var _panel: VBoxContainer
var _ctx: AssetEditorContext
var _active_item: DetailItem


func setup(panel: VBoxContainer, ctx: AssetEditorContext) -> DetailPanelBuilder:
	_panel = panel
	_ctx = ctx
	return self


## Clear the panel and drop all selection-panel registrations.
func clear() -> void:
	if _active_item:
		_active_item.dispose()
		_active_item = null
	for child in _panel.get_children():
		child.queue_free()
	var sel := _ctx.selection
	if sel:
		sel.clear_panels()


## Resolve, setup, and render the appropriate DetailItem for data.
## No-ops if data maps to TREE-only hint.
func show(data: Variant) -> void:
	clear()
	var item := _resolve_item(data)
	if item == null:
		return
	if item.get_render_hint() == DetailItem.RenderHint.TREE:
		return
	item.setup(_ctx)
	_active_item = item
	item.build_detail(_panel)


## Factory: map a data object to the correct DetailItem subclass.
## To add a new detail type: create a DetailItem subclass and add a branch here.
func _resolve_item(data: Variant) -> DetailItem:
	if data is UAssetProperty:
		return PropertyDetail.new().init_data(data)
	if data is UAssetExport:
		if data.export_type == "StringTableExport":
			return StringTableDetail.new().init_data(data)
		# Check if this export is a texture or sound type
		var asset := _ctx.get_asset()
		if asset:
			var cls_name := asset.get_export_class_name(data)
			if cls_name in UAssetFile.TEXTURE_CLASSES:
				return TextureDetail.new().init_data(data, cls_name)
			if cls_name in UAssetFile.SOUND_CLASSES:
				return SoundDetail.new().init_data(data, cls_name)
			if cls_name in UAssetFile.MESH_CLASSES:
				return MeshDetail.new().init_data(data, cls_name)
		return ExportDetail.new().init_data(data)
	if data is Dictionary and data.has("dt_row"):
		return DataTableRowDetail.new().init_data(data["dt_row"], data["expo"])
	if data is StringName:
		match data:
			&"namemap":   return NamemapDetail.new()
			&"importmap": return ImportDetail.new()
			&"exports":   return null  # list view removed (performance)
	return null
