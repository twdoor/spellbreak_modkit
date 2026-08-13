class_name AssetEditorContext extends RefCounted

## Typed dependencies and editor actions shared by detail renderers.

var document: AssetDocument
var selection: SelectionManager
var detail_stack: Array

var navigate_to: Callable
var navigate_back: Callable
var rebuild_tree: Callable
var show_detail: Callable
var refresh_tree_item: Callable
var select_tree_item: Callable
var reload_asset: Callable
var swap_exports: Callable

var texture_service: TextureService
var sound_service: SoundService
var mesh_service: MeshService
var background_jobs: BackgroundJobRunner


func get_asset() -> UAssetFile:
	return document.asset


func execute(label: String, apply_action: Callable, revert_action: Callable) -> bool:
	return document.execute(AssetEditCommand.new(label, apply_action, revert_action))


func record_applied(label: String, apply_action: Callable, revert_action: Callable) -> bool:
	return document.record_applied(AssetEditCommand.new(label, apply_action, revert_action))


func is_dirty() -> bool:
	return document.is_dirty()
