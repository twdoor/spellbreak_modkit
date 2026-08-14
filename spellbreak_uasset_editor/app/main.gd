extends CanvasLayer

const BASE_FILE_EXPLORER_TAB := preload("res://ui/tabs/base_file_explorer_tab.gd")
const MOD_SETTINGS_TAB_SCENE := preload(
	"res://features/mod_manager/ui/mod_settings_tab.tscn")
const KEYMAP_SETTINGS_TAB_SCENE := preload("res://ui/tabs/keymap_settings_tab.tscn")

@onready var open_file_popup: FileDialog = %OpenFilePopup
@onready var tab_cont: TabContainer = %TabCont
@onready var mod_manager_panel: ModManagerPanel = %ModManagerPanel
@onready var _toast_notifier: ToastNotifier = %ToastNotifier
@onready var _close_dialog: ConfirmationDialog = %CloseDialog
@onready var _compare_file_popup: FileDialog = %CompareFilePopup
@onready var _reuse_file_dialog: FileDialog = %ReuseFileDialog
@onready var _update_dialog: ConfirmationDialog = %UpdateDialog
@onready var _update_progress_bar: ProgressBar = %UpdateProgressBar
@onready var _tab_title_scroll_timer: Timer = %TabTitleScrollTimer
@onready var _status_label: Label = %StatusLabel

var _tab_pending_close: UassetFileTab
var _tab_close_icon: Texture2D
var _hovered_tab_idx := -1
var _hover_title_offset := 0
var _hover_title_hold_ticks := 0
var _compare_base_tab: UassetFileTab
var _reuse_source_tab: UassetFileTab
var _update_release_button: Button
var _latest_release_url := ""
var _pending_update: Dictionary = {}
var _prepared_update: Dictionary = {}
var _update_download_active := false
var _update_cancel_requested := false

var _cfg: ModConfigManager
var _texture_service: TextureService
var _sound_service: SoundService
var _mesh_service: MeshService
var _background_jobs: BackgroundJobRunner
var _checking_for_updates := false
var _keymap_config: Dictionary = {}
var _keymap_tab: KeymapSettingsTab

const _TAB_CLOSE_GAP := "   "
const _TAB_MAX_WIDTH := 190
const _TAB_TITLE_VISIBLE_CHARS := 24
const _TAB_TITLE_SCROLL_HOLD_TICKS := 4
const _TAB_TITLE_SCROLL_GAP := "   "
const _STARTUP_OPEN_EXTENSIONS := ["uasset", "json"]
const _CLONE_UNIQUE_OPTION := "Mark as unique file"

func _ready() -> void:
	_background_jobs = BackgroundJobRunner.new()
	_keymap_config = KeymapSettingsTab.load_saved_config()
	KeymapSettingsTab.apply_config(_keymap_config)

	_configure_scene_ui()
	_configure_tab_close_controls()
	_setup_mod_tab()
	_setup_version_manager()
	_open_startup_files.call_deferred()


func _configure_scene_ui() -> void:
	AppTheme.configure_file_dialog(open_file_popup)
	AppTheme.configure_file_dialog(_compare_file_popup)
	AppTheme.configure_file_dialog(_reuse_file_dialog)
	if _reuse_file_dialog.get_option_count() == 0:
		_reuse_file_dialog.add_option(_CLONE_UNIQUE_OPTION, PackedStringArray(), 0)
	AppTheme.apply_theme(_close_dialog)
	AppTheme.apply_theme(_update_dialog)
	AppTheme.style_muted(_status_label)

	_close_dialog.add_button("Save & Close", false, "save_close")
	_update_release_button = _update_dialog.add_button(
		"Open Release Page", false, "open_release")

	var version_manager := get_node_or_null("/root/VersionManager")
	if version_manager != null and version_manager.has_signal("update_download_progress"):
		version_manager.update_download_progress.connect(_on_update_download_progress)


func _configure_tab_close_controls() -> void:
	var tab_bar := tab_cont.get_tab_bar()
	_tab_close_icon = tab_bar.get_theme_icon("close", "TabBar") if tab_bar else _make_tab_close_icon()
	tab_cont.tab_button_pressed.connect(_on_tab_button_pressed)
	if tab_bar:
		tab_bar.set("max_tab_width", _TAB_MAX_WIDTH)
		tab_bar.set("scrolling_enabled", true)
		tab_bar.tab_rmb_clicked.connect(_on_tab_rmb_clicked)
		if tab_bar.has_signal("tab_hovered"):
			tab_bar.connect("tab_hovered", _on_tab_hovered)
		tab_bar.mouse_exited.connect(_on_tab_bar_mouse_exited)

func _make_tab_close_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var color := Color(0.78, 0.82, 0.86, 0.95)
	for i in range(5, 11):
		img.set_pixel(i, i, color)
		img.set_pixel(i + 1, i, color)
		img.set_pixel(i, 15 - i, color)
		img.set_pixel(i + 1, 15 - i, color)
	return ImageTexture.create_from_image(img)


func _process(_delta: float) -> void:
	if is_instance_valid(_keymap_tab) and _keymap_tab.is_capturing():
		return
	if Input.is_action_just_pressed(KeymapSettingsTab.ACTION_OPEN):
		_open_file_dialog()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_CLOSE):
		_close_current_tab()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_SAVE):
		_save_current_tab()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_REUSE):
		_reuse_current_asset()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_PREVIOUS_TAB):
		_select_previous_tab()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_NEXT_TAB):
		_select_next_tab()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_COPY):
		_copy_selection()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_PASTE):
		_paste_clipboard()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_CUT):
		_cut_selection()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_UNDO):
		_undo()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_DELETE):
		_delete_selection()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_CANCEL):
		_cancel_selection()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_CREATE):
		_create_file()
	elif Input.is_action_just_pressed(KeymapSettingsTab.ACTION_COMPARE):
		_compare_current_tab()


func _exit_tree() -> void:
	if _background_jobs:
		_background_jobs.wait_to_finish()
	if _texture_service:
		_texture_service.wait_to_finish()
	if _sound_service:
		_sound_service.wait_to_finish()
	if _mesh_service:
		_mesh_service.wait_to_finish()


func _setup_mod_tab() -> void:
	# Tab 0 — Mod Manager (always visible, never closeable)
	var panel := mod_manager_panel
	tab_cont.set_tab_title(0, "Mod Manager")
	panel.open_asset_requested.connect(_on_file_selected)
	panel.status_changed.connect(_on_mod_status_changed)
	_cfg = panel.get_config()
	_texture_service = TextureService.new().setup(_cfg)
	_sound_service = SoundService.new().setup(_cfg)
	_mesh_service = MeshService.new().setup(_cfg)

	# When any UassetFileTab is removed, refresh titles so lone survivors revert to short names.
	tab_cont.child_exiting_tree.connect(func(child: Node) -> void:
		if child is UassetFileTab or child is AssetDiffTab:
			_clear_hovered_tab_title()
			_refresh_tab_titles.call_deferred()
	)

	# Tab 1 — Settings (hidden by default; opened by the Settings button, closed by Save/Cancel)
	var settings := MOD_SETTINGS_TAB_SCENE.instantiate() as ModSettingsTab
	settings.setup(panel.get_config())
	tab_cont.add_child(settings)
	tab_cont.move_child(settings, 1)
	tab_cont.set_tab_title(1, "Settings")
	tab_cont.set_tab_hidden(1, true)

	panel.open_settings_requested.connect(func() -> void:
		settings.refresh()
		tab_cont.set_tab_hidden(1, false)
		tab_cont.current_tab = 1
	)

	settings.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(1, true)
		tab_cont.current_tab = 0
	)
	settings.status_changed.connect(_on_mod_status_changed)

	var keymap := KEYMAP_SETTINGS_TAB_SCENE.instantiate() as KeymapSettingsTab
	keymap.setup(_keymap_config)
	_keymap_tab = keymap
	tab_cont.add_child(keymap)
	tab_cont.move_child(keymap, 2)
	tab_cont.set_tab_title(2, "Key Mappings")
	tab_cont.set_tab_hidden(2, true)

	settings.open_keymap_requested.connect(func() -> void:
		keymap.refresh(_keymap_config)
		tab_cont.set_tab_hidden(2, false)
		tab_cont.current_tab = 2
	)

	keymap.keymap_changed.connect(func(config: Dictionary) -> void:
		_keymap_config = config.duplicate(true)
		KeymapSettingsTab.apply_config(_keymap_config)
	)
	keymap.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(2, true)
		tab_cont.current_tab = 1 if not tab_cont.is_tab_hidden(1) else 0
	)
	keymap.status_changed.connect(_on_mod_status_changed)

	var diagnostics := DiagnosticsTab.new().setup(panel.get_config())
	tab_cont.add_child(diagnostics)
	tab_cont.move_child(diagnostics, 3)
	tab_cont.set_tab_title(3, "Diagnostics")
	tab_cont.set_tab_hidden(3, true)

	panel.open_diagnostics_requested.connect(func() -> void:
		diagnostics.refresh()
		tab_cont.set_tab_hidden(3, false)
		tab_cont.current_tab = 3
	)

	diagnostics.close_requested.connect(func() -> void:
		tab_cont.set_tab_hidden(3, true)
		tab_cont.current_tab = 1 if not tab_cont.is_tab_hidden(1) else 0
	)
	diagnostics.status_changed.connect(_on_mod_status_changed)

	# Persistent source browser. Hidden utility tabs above it do not affect its
	# visible position beside Mod Manager.
	var explorer := BASE_FILE_EXPLORER_TAB.new().setup(_cfg, _background_jobs)
	tab_cont.add_child(explorer)
	tab_cont.move_child(explorer, 4)
	tab_cont.set_tab_title(4, "Base Files")
	explorer.open_asset_requested.connect(_on_file_selected)
	explorer.add_to_mod_requested.connect(panel.add_source_file_to_mod)
	explorer.open_settings_requested.connect(func() -> void:
		settings.refresh()
		tab_cont.set_tab_hidden(1, false)
		tab_cont.current_tab = 1
	)
	explorer.status_changed.connect(_on_mod_status_changed)


func _on_mod_status_changed(text: String, is_error: bool) -> void:
	_status_label.text = text
	AppTheme.style_status(_status_label, is_error)


func _show_toast(message: String) -> void:
	_toast_notifier.show_message(message)


func _on_reuse_dialog_canceled() -> void:
	_reuse_source_tab = null


func _setup_version_manager() -> void:
	call_deferred("_check_for_updates")


func _check_for_updates() -> void:
	if _checking_for_updates:
		return
	var version_manager := get_node_or_null("/root/VersionManager")
	if version_manager == null:
		print_verbose("Update check skipped: VersionManager autoload is unavailable")
		return
	_checking_for_updates = true
	var result: Dictionary = await version_manager.check_for_updates()
	_checking_for_updates = false
	if not bool(result.get("success", false)):
		print_verbose("Update check skipped: %s" % str(result.get("error", "unknown error")))
		return
	if bool(result.get("update_available", false)):
		_on_update_available(result)


func _on_update_available(result: Dictionary) -> void:
	_pending_update = result.duplicate(true)
	_prepared_update.clear()
	_update_download_active = false
	_update_cancel_requested = false
	_latest_release_url = str(result.get("release_url", ""))
	var version := str(result.get("latest_version", "")).trim_prefix("v").trim_prefix("V")
	var automatic := bool(result.get("install_supported", false))
	_update_progress_bar.visible = false
	_update_dialog.get_ok_button().disabled = false
	_update_dialog.cancel_button_text = "Later"
	if automatic:
		var asset: Dictionary = result.get("asset", {})
		_update_dialog.ok_button_text = "Download Update"
		_update_release_button.visible = true
		_update_release_button.disabled = false
		_update_dialog.dialog_text = (
			"Spellbreak Modkit %s is available.\n\n"
			+ "Download %s, verify it, then install and restart?"
		) % [version, str(asset.get("name", "the platform build"))]
	else:
		_update_dialog.ok_button_text = "Open Release Page"
		_update_release_button.visible = false
		var reason := str(result.get("install_error", "Automatic installation is unavailable."))
		_update_dialog.dialog_text = (
			"Spellbreak Modkit %s is available.\n\n%s\n\n"
			+ "Open the GitHub release page to update manually?"
		) % [version, reason]
	_update_dialog.popup_centered()


func _on_update_primary_action() -> void:
	if not _prepared_update.is_empty():
		_install_prepared_update()
	elif bool(_pending_update.get("install_supported", false)):
		_start_update_download()
	else:
		_open_latest_release()
		_update_dialog.hide()


func _on_update_dialog_action(action: StringName) -> void:
	if action == &"open_release":
		_open_latest_release()


func _on_update_dialog_cancelled() -> void:
	if not _update_download_active:
		return
	_update_cancel_requested = true
	var version_manager := get_node_or_null("/root/VersionManager")
	if version_manager != null and version_manager.has_method("cancel_update_download"):
		version_manager.cancel_update_download()


func _start_update_download() -> void:
	if _update_download_active:
		return
	var version_manager := get_node_or_null("/root/VersionManager")
	if version_manager == null or not version_manager.has_method("download_and_prepare_update"):
		_show_update_error("The update service is unavailable.")
		return
	_update_download_active = true
	_update_cancel_requested = false
	_update_dialog.get_ok_button().disabled = true
	_update_release_button.disabled = true
	_update_dialog.cancel_button_text = "Cancel Download"
	_update_progress_bar.value = 0
	_update_progress_bar.max_value = 100
	_update_progress_bar.visible = true
	var asset: Dictionary = _pending_update.get("asset", {})
	_update_dialog.dialog_text = "Downloading %s…" % str(asset.get("name", "update"))

	var result: Dictionary = await version_manager.download_and_prepare_update(_pending_update)
	_update_download_active = false
	_update_dialog.cancel_button_text = "Later"
	_update_release_button.disabled = false
	if bool(result.get("cancelled", false)) or _update_cancel_requested:
		_update_progress_bar.visible = false
		return
	if not bool(result.get("success", false)):
		_update_dialog.ok_button_text = "Retry Download"
		_update_dialog.get_ok_button().disabled = false
		_show_update_error(str(result.get("error", "The update could not be prepared.")))
		return

	_prepared_update = result
	_update_progress_bar.value = 100
	_update_progress_bar.visible = true
	_update_dialog.ok_button_text = "Install & Restart"
	_update_dialog.get_ok_button().disabled = false
	_update_dialog.dialog_text = (
		"Spellbreak Modkit %s has been downloaded and verified.\n\n"
		+ "Install it now and restart the app? A backup of this executable will be kept."
	) % str(result.get("version", ""))
	if not _update_dialog.visible:
		_update_dialog.popup_centered()


func _on_update_download_progress(downloaded_bytes: int, total_bytes: int) -> void:
	if not _update_download_active:
		return
	if total_bytes > 0:
		_update_progress_bar.value = clampf(
			float(downloaded_bytes) / float(total_bytes) * 100.0, 0.0, 100.0)
		_update_dialog.dialog_text = "Downloading update…  %s / %s" % [
			_format_update_size(downloaded_bytes), _format_update_size(total_bytes)]
	else:
		_update_dialog.dialog_text = "Downloading update…  %s" % _format_update_size(
			downloaded_bytes)


func _install_prepared_update() -> void:
	var dirty_tabs := 0
	for child in tab_cont.get_children():
		if child is UassetFileTab and (child as UassetFileTab).is_dirty():
			dirty_tabs += 1
	if dirty_tabs > 0:
		_show_update_error(
			"Save or close %d file%s with unsaved changes before restarting." % [
				dirty_tabs, "" if dirty_tabs == 1 else "s"])
		return
	var version_manager := get_node_or_null("/root/VersionManager")
	if version_manager == null or not version_manager.has_method("launch_prepared_update"):
		_show_update_error("The update installer is unavailable.")
		return
	var result: Dictionary = version_manager.launch_prepared_update(_prepared_update)
	if not bool(result.get("success", false)):
		_show_update_error(str(result.get("error", "Could not start the update installer.")))
		return
	_update_dialog.hide()
	get_tree().quit()


func _show_update_error(message: String) -> void:
	_update_progress_bar.visible = false
	_update_dialog.dialog_text = "The automatic update could not continue:\n\n%s" % message
	if not _update_dialog.visible:
		_update_dialog.popup_centered()


func _format_update_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))


func _open_latest_release() -> void:
	if _latest_release_url.is_empty():
		_show_toast("The release page URL is unavailable")
		return
	var error := OS.shell_open(_latest_release_url)
	if error != OK:
		_show_toast("Could not open release page (error %d)" % error)


func _on_discard_and_close() -> void:
	if is_instance_valid(_tab_pending_close):
		_tab_pending_close.queue_free()
	_tab_pending_close = null


func _on_save_and_close(action: StringName) -> void:
	if action != &"save_close":
		return
	if is_instance_valid(_tab_pending_close):
		var error := _tab_pending_close.save_asset()
		if error != OK:
			_show_toast("Save failed (error %d)" % error)
			_close_dialog.hide()
			return
		_show_toast("Saved  " + _tab_pending_close.tab_asset.file_path.get_file())
		_tab_pending_close.queue_free()
	_tab_pending_close = null
	_close_dialog.hide()


func _select_previous_tab() -> void:
	tab_cont.select_previous_available()


func _select_next_tab() -> void:
	tab_cont.select_next_available()


func _open_file_dialog() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		focus.release_focus()
	if open_file_popup.visible:
		return
	open_file_popup.popup_file_dialog()


func _on_file_selected(path: String) -> void:
	# Don't open duplicates — switch to existing tab instead
	for i in tab_cont.get_child_count():
		var tab = tab_cont.get_child(i)
		if tab is UassetFileTab and tab.tab_asset and tab.tab_asset.file_path == path:
			tab_cont.current_tab = tab_cont.get_tab_idx_from_control(tab)
			return

	var asset := UAssetFile.load_file(path)
	if asset == null:
		push_error("Failed to load: " + path)
		_show_toast("Failed to load  " + path.get_file())
		return

	# Attach the Spellbreak profile so property editors can access enums/tags.
	if _cfg:
		asset.game_profile = _cfg.get_game_profile()

	var new_tab := UassetFileTab.setup(asset, _texture_service, _sound_service,
		_mesh_service, _background_jobs)
	new_tab.tab_title_changed.connect(_on_asset_tab_title_changed)
	tab_cont.add_child(new_tab)
	# Refresh all tab titles: duplicates get "ParentFolder/Name", unique ones stay short.
	_refresh_tab_titles()
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(new_tab)


func _reuse_current_asset() -> void:
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		_on_reuse_requested(tab as UassetFileTab)


func _on_reuse_requested(tab: UassetFileTab) -> void:
	if not is_instance_valid(tab) or tab.tab_asset == null:
		return
	var source_path := tab.tab_asset.binary_path
	if source_path.is_empty() or source_path.get_extension().to_lower() != "uasset":
		_show_toast("Clone requires an open binary .uasset file")
		return
	_reuse_source_tab = tab
	_reuse_file_dialog.set_option_default(0, 0)
	_reuse_file_dialog.current_dir = source_path.get_base_dir()
	_reuse_file_dialog.current_file = "%s_Copy.uasset" % source_path.get_file().get_basename()
	_reuse_file_dialog.popup_centered(Vector2i(900, 650))


func _on_reuse_destination_selected(selected_path: String) -> void:
	var source_tab := _reuse_source_tab
	var selected_options := _reuse_file_dialog.get_selected_options()
	var mark_unique := int(selected_options.get(_CLONE_UNIQUE_OPTION, 0)) == 1
	_reuse_source_tab = null
	if not is_instance_valid(source_tab) or source_tab.tab_asset == null:
		_show_toast("The source asset is no longer open")
		return
	var destination_path := selected_path
	if destination_path.get_extension().is_empty():
		destination_path += ".uasset"
	if destination_path.get_extension().to_lower() != "uasset":
		_show_toast("Choose a .uasset destination")
		return
	if FileUtils.same_path(source_tab.tab_asset.binary_path, destination_path):
		_show_toast("Choose a different asset file from the source")
		return

	var unique_declaration: OperationResult = null
	if mark_unique:
		unique_declaration = ModManifest.describe_unique_clone(
				source_tab.tab_asset.binary_path, destination_path, _cfg)
		if not unique_declaration.ok:
			_show_toast(unique_declaration.message)
			return

	var existing_tab := _find_open_asset_tab(destination_path)
	if existing_tab != null and existing_tab.is_dirty():
		_show_toast("Cannot replace an open asset with unsaved changes")
		return

	_show_toast("Cloning asset...")
	var source_package := ""
	var target_package := ""
	if mark_unique:
		source_package = str(unique_declaration.value.get("source", "")).rsplit(".", true, 1)[0]
		target_package = str(unique_declaration.value.get("target", "")).rsplit(".", true, 1)[0]
	var result := source_tab.tab_asset.save_clone_copy(
			destination_path, mark_unique, source_package, target_package)
	if not result.ok:
		_show_toast(result.message)
		return
	if mark_unique:
		var manifest_result := ModManifest.record_unique_clone(unique_declaration.value, _cfg)
		if not manifest_result.ok:
			_show_toast("Cloned asset, but %s" % manifest_result.message)
			return
		mod_manager_panel.refresh_mods()

	if existing_tab != null:
		if not existing_tab.reload_asset_from_disk():
			_show_toast("Created asset, but could not reload its open tab")
			return
		tab_cont.current_tab = tab_cont.get_tab_idx_from_control(existing_tab)
	else:
		_on_file_selected(destination_path)
	_show_toast("Cloned as %s%s (%d names updated)" % [
		destination_path.get_file(),
		" and marked unique" if mark_unique else "",
		int(result.metadata.get("renamed_name_entries", 0)),
	])


func _find_open_asset_tab(path: String) -> UassetFileTab:
	for child in tab_cont.get_children():
		if child is UassetFileTab:
			var asset_tab := child as UassetFileTab
			if asset_tab.tab_asset != null \
					and FileUtils.same_path(asset_tab.tab_asset.file_path, path):
				return asset_tab
	return null


func _on_files_selected(paths: PackedStringArray) -> void:
	for path in paths:
		_on_file_selected(path)


func _open_startup_files() -> void:
	for path in _get_startup_file_paths():
		_on_file_selected(path)


func _get_startup_file_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for raw_arg in OS.get_cmdline_args():
		var path := str(raw_arg).strip_edges()
		if path.is_empty() or path.begins_with("--"):
			continue
		if path.begins_with("file://"):
			path = path.trim_prefix("file://").uri_decode()
		if _STARTUP_OPEN_EXTENSIONS.has(path.get_extension().to_lower()):
			paths.append(path)
	return paths


## Scans all open UassetFileTabs and updates their displayed title:
##   - unique filename  → short form  "FileName"
##   - duplicate filename → long form  "ParentFolder/FileName"
## Also handles the dirty (*) suffix through _update_tab_title.
func _refresh_tab_titles() -> void:
	# Count how many open tabs share each base name.
	var counts: Dictionary = {}
	for i in tab_cont.get_child_count():
		var tab := tab_cont.get_child(i)
		if tab is UassetFileTab:
			var n: String = (tab as UassetFileTab)._base_name
			counts[n] = counts.get(n, 0) + 1

	# Apply short or long form accordingly.
	for i in tab_cont.get_child_count():
		var tab := tab_cont.get_child(i)
		if tab is UassetFileTab:
			var ft := tab as UassetFileTab
			ft._display_base = ft.get_disambig_name() if counts[ft._base_name] > 1 else ft._base_name
			_set_managed_tab_title(i, ft.get_tab_title(), true)
		elif tab is AssetDiffTab:
			var diff_tab := tab as AssetDiffTab
			_set_managed_tab_title(i, diff_tab.get_tab_title(), true)
		else:
			tab_cont.set_tab_button_icon(i, null)


func _on_asset_tab_title_changed(tab: UassetFileTab) -> void:
	if not is_instance_valid(tab) or not tab.is_inside_tree():
		return
	var tab_idx := tab_cont.get_tab_idx_from_control(tab)
	if tab_idx >= 0:
		_set_managed_tab_title(tab_idx, tab.get_tab_title(), true)


func _set_managed_tab_title(tab_idx: int, full_title: String, closeable: bool) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null:
		return
	tab.set_meta("tab_full_title", full_title)
	tab.set_meta("tab_closeable", closeable)
	tab_cont.set_tab_title(tab_idx, _render_tab_title(tab_idx, full_title)
		+ (_TAB_CLOSE_GAP if closeable else ""))
	tab_cont.set_tab_button_icon(tab_idx, _tab_close_icon if closeable else null)
	tab_cont.set_tab_tooltip(tab_idx, full_title)


func _refresh_managed_tab_title(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		return
	_set_managed_tab_title(tab_idx, str(tab.get_meta("tab_full_title")),
		bool(tab.get_meta("tab_closeable", false)))


func _render_tab_title(tab_idx: int, full_title: String) -> String:
	if tab_idx == _hovered_tab_idx and _is_tab_title_long(full_title):
		return _scroll_tab_title(full_title)
	return _truncate_tab_title(full_title)


func _truncate_tab_title(full_title: String) -> String:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	var visible_chars := maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())
	if base.length() <= visible_chars:
		return base + suffix
	return base.left(maxi(4, visible_chars - 3)) + "..." + suffix


func _scroll_tab_title(full_title: String) -> String:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	var visible_chars := maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())
	if base.length() <= visible_chars:
		return base + suffix
	var source := base + _TAB_TITLE_SCROLL_GAP + base
	var cycle_length := base.length() + _TAB_TITLE_SCROLL_GAP.length()
	var start := _hover_title_offset % cycle_length
	return source.substr(start, visible_chars) + suffix


func _split_dirty_suffix(title: String) -> Dictionary:
	if title.ends_with(" *"):
		return {
			"base": title.left(title.length() - 2),
			"suffix": " *",
		}
	return {
		"base": title,
		"suffix": "",
	}


func _is_tab_title_long(full_title: String) -> bool:
	var parts := _split_dirty_suffix(full_title)
	var base := str(parts["base"])
	var suffix := str(parts["suffix"])
	return base.length() > maxi(8, _TAB_TITLE_VISIBLE_CHARS - suffix.length())


func _on_tab_hovered(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		_clear_hovered_tab_title()
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		_clear_hovered_tab_title()
		return

	var previous_idx := _hovered_tab_idx
	_hovered_tab_idx = tab_idx
	_hover_title_offset = 0
	_hover_title_hold_ticks = 0
	if previous_idx != tab_idx:
		_refresh_managed_tab_title(previous_idx)
	_refresh_managed_tab_title(tab_idx)

	if _is_tab_title_long(str(tab.get_meta("tab_full_title"))):
		_tab_title_scroll_timer.start()
	else:
		_tab_title_scroll_timer.stop()


func _on_tab_bar_mouse_exited() -> void:
	_clear_hovered_tab_title()


func _clear_hovered_tab_title() -> void:
	var previous_idx := _hovered_tab_idx
	_hovered_tab_idx = -1
	_hover_title_offset = 0
	_hover_title_hold_ticks = 0
	if _tab_title_scroll_timer:
		_tab_title_scroll_timer.stop()
	_refresh_managed_tab_title(previous_idx)


func _advance_hovered_tab_title() -> void:
	if _hovered_tab_idx < 0 or _hovered_tab_idx >= tab_cont.get_tab_count():
		_clear_hovered_tab_title()
		return
	var tab := tab_cont.get_tab_control(_hovered_tab_idx)
	if tab == null or not tab.has_meta("tab_full_title"):
		_clear_hovered_tab_title()
		return
	var full_title := str(tab.get_meta("tab_full_title"))
	if not _is_tab_title_long(full_title):
		_clear_hovered_tab_title()
		return

	if _hover_title_hold_ticks < _TAB_TITLE_SCROLL_HOLD_TICKS:
		_hover_title_hold_ticks += 1
	else:
		_hover_title_offset += 1
	_refresh_managed_tab_title(_hovered_tab_idx)


func _close_current_tab() -> void:
	var tab = tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		_request_close_tab(tab)
	elif tab is AssetDiffTab:
		tab.queue_free()


func _on_tab_button_pressed(tab_idx: int) -> void:
	_close_tab_at_index(tab_idx)


func _on_tab_rmb_clicked(tab_idx: int) -> void:
	_close_tab_at_index(tab_idx)


func _close_tab_at_index(tab_idx: int) -> void:
	if tab_idx < 0 or tab_idx >= tab_cont.get_tab_count():
		return
	var tab := tab_cont.get_tab_control(tab_idx)
	tab_cont.current_tab = tab_idx
	if tab is UassetFileTab:
		_request_close_tab(tab)
	elif tab is AssetDiffTab:
		tab.queue_free()


func _request_close_tab(tab: UassetFileTab) -> void:
	if tab._dirty:
		_tab_pending_close = tab
		_close_dialog.dialog_text = '"%s" has unsaved changes.' % tab.tab_asset.file_path.get_file()
		_close_dialog.popup_centered()
		return
	tab.queue_free()


func _save_current_tab() -> void:
	var tab = tab_cont.get_current_tab_control()
	if tab and tab is UassetFileTab:
		if not tab.is_dirty():
			_show_toast("No changes to save")
			return
		var error: Error = tab.save_asset()
		if error == OK:
			_show_toast("Saved  " + tab.tab_asset.file_path.get_file())
		else:
			_show_toast("Save failed (error %d)" % error)


func _copy_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		var result: Dictionary = tab.copy_selection()
		if bool(result.get("ok", false)):
			_show_toast("Copied  " + str(result.get("label", tab.get_clipboard_label())))
		else:
			_show_toast(str(result.get("message", "Nothing copyable is selected")))
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).copy_selection()


func _cut_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		var result: Dictionary = tab.cut_selection()
		if bool(result.get("ok", false)):
			_show_toast("Cut  " + str(result.get("label", tab.get_clipboard_label())))
		else:
			_show_toast(str(result.get("message", "Nothing cuttable is selected")))
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).cut_selection()


func _paste_clipboard() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.paste_clipboard()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).paste_clipboard()


func _delete_selection() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.delete_selection()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).delete_selection()


func _create_file() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is ModManagerPanel:
		(tab as ModManagerPanel).create_file()


func _compare_current_tab() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if not tab is UassetFileTab:
		_show_toast("Open an asset before comparing")
		return
	_compare_base_tab = tab
	var path := _compare_base_tab.tab_asset.binary_path
	if path.is_empty():
		path = _compare_base_tab.tab_asset.file_path
	if not path.is_empty():
		_compare_file_popup.current_dir = path.get_base_dir()
	if not _compare_file_popup.visible:
		_compare_file_popup.popup_file_dialog()


func _on_compare_file_selected(path: String) -> void:
	if not is_instance_valid(_compare_base_tab) or _compare_base_tab.tab_asset == null:
		_show_toast("Open an asset before comparing")
		return
	var other_asset := UAssetFile.load_file(path)
	if other_asset == null:
		_show_toast("Failed to load comparison file")
		return
	if _cfg:
		other_asset.game_profile = _cfg.get_game_profile()

	var diff_tab := AssetDiffTab.setup(_compare_base_tab.tab_asset, other_asset)
	tab_cont.add_child(diff_tab)
	_refresh_tab_titles()
	tab_cont.current_tab = tab_cont.get_tab_idx_from_control(diff_tab)
	_show_toast("%d difference(s)" % diff_tab.diffs.size())


func _undo() -> void:
	if _text_control_focused():
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.undo()


func _cancel_selection() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		focus.release_focus()
		return
	var tab := tab_cont.get_current_tab_control()
	if tab is UassetFileTab:
		tab.clear_selection()
	elif tab is ModManagerPanel:
		(tab as ModManagerPanel).clear_selection()


## Returns true when a text-editing control has keyboard focus.
## In that case, shortcuts like Ctrl+C/V/X/Z should go to the control, not the editor.
func _text_control_focused() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox
