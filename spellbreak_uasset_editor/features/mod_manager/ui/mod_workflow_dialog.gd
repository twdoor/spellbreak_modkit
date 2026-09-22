class_name ModWorkflowDialog extends Window

signal content_changed
signal mutation_started
signal mutation_finished

var mutation_guard: Callable
var _service := ModWorkflowService.new()
var _mods: OptionButton
var _sources: OptionButton
var _cultures: OptionButton
var _tabs: TabContainer
var _texts: ItemList
var _english: TextEdit
var _translation: TextEdit
var _recipe: CodeEdit
var _preview: Tree
var _status: Label
var _buttons: Array[Button] = []
var _apply: Button
var _catalog: Dictionary = {}
var _token := ""
var _command := ""
var _mutating := false
var _updating_text := false
var _translations_dirty := false
var _recipe_dirty := false
var _mod_index := 0

const CULTURES := {"de": "German", "es": "Spanish", "fr": "French", "it": "Italian",
	"ja": "Japanese", "ko": "Korean", "pt-BR": "Portuguese (Brazil)", "ru": "Russian", "zh-Hans": "Chinese (Simplified)"}

func setup(mods: Array[ModInfo], sources: Array, initial_tab: int) -> void:
	title = "Mod Workflows"
	visible = false
	transient = true
	exclusive = true
	min_size = Vector2i(640, 480)
	AppTheme.apply_theme(self)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var layout := VBoxContainer.new()
	margin.add_child(layout)
	var selectors := HBoxContainer.new()
	layout.add_child(selectors)
	_mods = _picker(selectors, "Mod")
	for mod in mods:
		_mods.add_item(mod.name)
		_mods.set_item_metadata(_mods.item_count - 1, mod.path)
	_sources = _picker(selectors, "Base source")
	for source: Dictionary in sources:
		_sources.add_item(str(source.get("name", source.get("path", ""))))
		_sources.set_item_metadata(_sources.item_count - 1, str(source.get("path", "")))
	_sources.tooltip_text = "Extracted source containing the original Game.locres language files"
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_tabs)
	_build_localization()
	_build_recipes()
	_tabs.current_tab = initial_tab
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Choose a mod, then scan its text or load a recipe."
	layout.add_child(_status)
	_mods.item_selected.connect(func(index: int) -> void:
		_mods.select(_mod_index)
		_confirm_discard(func() -> void:
			_mod_index = index
			_mods.select(index)
			_catalog.clear()
			_texts.clear()
			_english.text = ""
			_translation.text = ""
			_invalidate_preview(), true))
	_service.finished.connect(_finished)
	close_requested.connect(func() -> void:
		if not _service.is_busy():
			_confirm_discard(queue_free))

func _confirm_discard(action: Callable, translations_only: bool = false, recipe_only: bool = false) -> void:
	if (recipe_only or not _translations_dirty) and (translations_only or not _recipe_dirty):
		action.call()
		return
	var dialog := ConfirmationDialog.new()
	AppTheme.apply_theme(dialog)
	dialog.dialog_text = "There are unsaved edits. Discard them?\nCancel to save translations or the recipe first."
	dialog.ok_button_text = "Discard"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		if not recipe_only:
			_translations_dirty = false
		if not translations_only:
			_recipe_dirty = false
		dialog.queue_free()
		action.call())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()

func _exit_tree() -> void:
	_service.wait_to_finish()

func _picker(parent: Node, label_text: String) -> OptionButton:
	var label := Label.new()
	label.text = label_text
	parent.add_child(label)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(picker)
	return picker

func _button(parent: Node, label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(action)
	parent.add_child(button)
	_buttons.append(button)
	return button

func _build_localization() -> void:
	var page := VBoxContainer.new()
	page.name = "Localization"
	_tabs.add_child(page)
	var bar := HBoxContainer.new()
	page.add_child(bar)
	_button(bar, "Scan Text", func() -> void: _run("scan"))
	_button(bar, "Save Translations", func() -> void: _run("save_catalog"))
	_button(bar, "Build Language Files", func() -> void: _run("localize"))
	_cultures = _picker(bar, "Language")
	for culture: String in CULTURES:
		_cultures.add_item(CULTURES[culture])
		_cultures.set_item_metadata(_cultures.item_count - 1, culture)
	_cultures.item_selected.connect(func(_index: int) -> void: _show_text())
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(split)
	_texts = ItemList.new()
	_texts.custom_minimum_size.x = 230
	_texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_texts)
	_texts.item_selected.connect(func(_index: int) -> void: _show_text())
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(fields)
	var label := Label.new()
	label.text = "English source"
	fields.add_child(label)
	_english = TextEdit.new()
	_english.editable = false
	_english.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_english.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fields.add_child(_english)
	label = Label.new()
	label.text = "Translation (leave blank to use English)"
	fields.add_child(label)
	_translation = TextEdit.new()
	_translation.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_translation.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fields.add_child(_translation)
	_translation.text_changed.connect(func() -> void:
		if _updating_text or _texts.get_selected_items().is_empty():
			return
		var row: Dictionary = _catalog.rows[_texts.get_selected_items()[0]]
		row.translations[_culture()] = _translation.text)
	_translation.text_changed.connect(func() -> void:
		if not _updating_text and not _texts.get_selected_items().is_empty():
			_translations_dirty = true)

func _build_recipes() -> void:
	var page := VBoxContainer.new()
	page.name = "Batch Recipes"
	_tabs.add_child(page)
	var bar := HBoxContainer.new()
	page.add_child(bar)
	_button(bar, "Inspect Asset…", _inspect_asset)
	_button(bar, "Load Recipe…", func() -> void: _recipe_file(false))
	_button(bar, "Save Recipe…", func() -> void: _recipe_file(true))
	_button(bar, "Preview", func() -> void: _run("preview_recipe"))
	_apply = _button(bar, "Apply", func() -> void: _run("apply_recipe"))
	_apply.disabled = true
	_recipe = CodeEdit.new()
	_recipe.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_recipe.placeholder_text = "Inspect a mod asset to create a recipe, or load an existing recipe."
	page.add_child(_recipe)
	_recipe.text_changed.connect(_invalidate_preview)
	_recipe.text_changed.connect(func() -> void: _recipe_dirty = true)
	_preview = Tree.new()
	_preview.columns = 3
	_preview.column_titles_visible = true
	_preview.set_column_title(0, "Property")
	_preview.set_column_title(1, "Before")
	_preview.set_column_title(2, "After")
	_preview.hide_root = true
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(_preview)

func _culture() -> String:
	return str(_cultures.get_item_metadata(_cultures.selected))

func _show_text() -> void:
	_updating_text = true
	if not _texts.get_selected_items().is_empty():
		var row: Dictionary = _catalog.rows[_texts.get_selected_items()[0]]
		_english.text = row.source
		_translation.text = str(row.translations.get(_culture(), ""))
	_updating_text = false

func _invalidate_preview() -> void:
	_token = ""
	_apply.disabled = true
	_preview.clear()

func _file_dialog(save: bool, filter_text: String) -> FileDialog:
	var dialog := FileDialog.new()
	AppTheme.configure_file_dialog(dialog)
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if save else FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray([filter_text])
	add_child(dialog)
	dialog.canceled.connect(dialog.queue_free)
	return dialog

func _recipe_file(save: bool) -> void:
	if not save and _recipe_dirty:
		_confirm_discard(func() -> void: _recipe_file(false), false, true)
		return
	var dialog := _file_dialog(save, "*.json ; Batch recipe")
	dialog.current_file = "recipe.json" if save else ""
	dialog.file_selected.connect(func(path: String) -> void:
		if save:
			var error := FileUtils.write_bytes_atomic(path, _recipe.text.to_utf8_buffer())
			_status.text = "Recipe saved." if error == OK else "Could not save recipe."
			if error == OK:
				_recipe_dirty = false
		else:
			_recipe.text = FileAccess.get_file_as_string(path)
			_invalidate_preview()
			_recipe_dirty = false
		dialog.queue_free())
	dialog.popup_centered_clamped(Vector2i(760, 520))

func _inspect_asset() -> void:
	if _recipe_dirty:
		_confirm_discard(_inspect_asset, false, true)
		return
	if _mods.selected < 0:
		return
	var dialog := _file_dialog(false, "*.uasset ; Mod asset")
	dialog.current_dir = str(_mods.get_item_metadata(_mods.selected)).path_join("g3")
	dialog.file_selected.connect(func(path: String) -> void:
		var root := str(_mods.get_item_metadata(_mods.selected)).rstrip("/")
		if not FileUtils.is_path_within(path, root):
			_status.text = "Choose an asset inside the selected mod."
		else:
			_run("inspect", {"asset": path.trim_prefix(root + "/")})
		dialog.queue_free())
	dialog.popup_centered_clamped(Vector2i(760, 520))

func _run(command: String, extra: Dictionary = {}) -> void:
	if _service.is_busy() or _mods.selected < 0:
		return
	if command == "scan" and _translations_dirty:
		_confirm_discard(func() -> void: _run(command, extra), true)
		return
	var mod_path := str(_mods.get_item_metadata(_mods.selected))
	var mutating := command in ["localize", "apply_recipe"]
	if mutating and mutation_guard.is_valid():
		var reason: String = mutation_guard.call(mod_path)
		if not reason.is_empty():
			_status.text = reason
			return
	if command == "apply_recipe" and _translations_dirty:
		_confirm_discard(func() -> void: _run(command, extra), true)
		return
	if command in ["save_catalog", "localize"] and _catalog.is_empty():
		_status.text = "Scan the mod’s text first."
		return
	if command == "localize" and _sources.selected < 0:
		_status.text = "Add an extracted base source in Settings first."
		return
	var request := {"command": command, "mod": mod_path, "catalog": _catalog,
		"recipe_text": _recipe.text, "token": _token}
	if command == "localize":
		request.source = str(_sources.get_item_metadata(_sources.selected))
		var cultures: Array[String] = []
		for row: Dictionary in _catalog.rows:
			for culture: String in row.translations:
				if not str(row.translations[culture]).strip_edges().is_empty() and culture not in cultures:
					cultures.append(culture)
		request.cultures = cultures
	request.merge(extra, true)
	_command = command
	_mutating = mutating
	if _mutating:
		mutation_started.emit()
	_busy(true)
	_status.text = "Working…"
	_service.run(request)

func _busy(active: bool) -> void:
	for button in _buttons:
		button.disabled = active
	_apply.disabled = active or _token.is_empty()
	_mods.disabled = active
	_sources.disabled = active
	_cultures.disabled = active
	_recipe.editable = not active
	_translation.editable = not active

func _finished(result: OperationResult) -> void:
	if _mutating:
		mutation_finished.emit()
		_mutating = false
	_busy(false)
	_status.text = result.message
	if not result.ok:
		return
	var data: Dictionary = result.value
	if _command in ["save_catalog", "localize", "scan"]:
		_translations_dirty = false
	if data.has("backup"):
		_status.text += "\nBackup: " + str(data.backup)
	if data.has("catalog"):
		_catalog = data.catalog
		_texts.clear()
		for row: Dictionary in _catalog.rows:
			var index := _texts.item_count
			_texts.add_item(str(row.asset).get_file().get_basename() + " · " + str(row.label))
			_texts.set_item_tooltip(index, str(row.asset) + "\n" + str(row.source))
		if _texts.item_count:
			_texts.select(0)
			_show_text()
	if data.has("recipe_text"):
		_recipe.text = data.recipe_text
		_invalidate_preview()
	if data.has("changes"):
		_preview.clear()
		var root := _preview.create_item()
		for change: Dictionary in data.changes:
			var row := _preview.create_item(root)
			row.set_text(0, str(change.asset).get_file() + " · " + str(change.label))
			row.set_tooltip_text(0, str(change.export) + str(change.property))
			row.set_text(1, change.old)
			row.set_text(2, change.new)
		_token = data.token
		_apply.disabled = false
	if _command in ["localize", "apply_recipe"]:
		_invalidate_preview()
		content_changed.emit()
		if _command == "apply_recipe":
			_catalog.clear()
			_texts.clear()
