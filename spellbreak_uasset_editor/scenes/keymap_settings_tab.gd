class_name KeymapSettingsTab extends VBoxContainer

signal close_requested
signal keymap_changed(config: GUIDERemappingConfig)
signal status_changed(text: String, is_error: bool)

const KEYMAP_PATH := "user://keymaps/editor_keymap.tres"

var _mapping_context: GUIDEMappingContext
var _working_config: GUIDERemappingConfig
var _remapper := GUIDERemapper.new()
var _items: Array = []
var _row_data: Array = []
var _items_container: VBoxContainer
var _status_label: Label
var _detector: GUIDEInputDetector
var _capturing_item: Variant = null
var _dirty := false


static func load_saved_config() -> GUIDERemappingConfig:
	if FileAccess.file_exists(KEYMAP_PATH):
		var loaded := ResourceLoader.load(KEYMAP_PATH)
		if loaded is GUIDERemappingConfig:
			return loaded as GUIDERemappingConfig
	return GUIDERemappingConfig.new()


static func save_config(config: GUIDERemappingConfig) -> Error:
	var dir := ProjectSettings.globalize_path(KEYMAP_PATH.get_base_dir())
	var dir_error := DirAccess.make_dir_recursive_absolute(dir)
	if dir_error != OK:
		return dir_error
	return ResourceSaver.save(config, KEYMAP_PATH)


func setup(mapping_context: GUIDEMappingContext, config: GUIDERemappingConfig) -> KeymapSettingsTab:
	_mapping_context = mapping_context
	_working_config = config.duplicate() if config != null else GUIDERemappingConfig.new()
	return self


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detector = GUIDEInputDetector.new()
	_detector.detection_started.connect(_on_detection_started)
	_detector.input_detected.connect(_on_input_detected)
	add_child(_detector)
	_build_ui()


func refresh(config: GUIDERemappingConfig = null) -> void:
	if config != null:
		_working_config = config.duplicate()
	_dirty = false
	if _detector and _detector.is_detecting:
		_detector.abort_detection()
	_capturing_item = null
	for child in get_children():
		if child != _detector:
			child.free()
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 0)
	_rebuild_items()

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("margin_left", AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_right", AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_top", AppTheme.MARGIN_SETTINGS_V)
	outer.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_SETTINGS_V)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", AppTheme.MARGIN_SETTINGS_V)
	outer.add_child(content)
	scroll.add_child(outer)
	add_child(scroll)

	content.add_child(_section("Key Mappings"))
	content.add_child(_hint("Customize editor shortcuts. Changes apply immediately for this session; save to keep them after restart."))

	_items_container = VBoxContainer.new()
	_items_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_container.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	content.add_child(_items_container)
	_rebuild_rows()

	_status_label = _hint("")
	_status_label.visible = false
	content.add_child(_status_label)

	add_child(HSeparator.new())
	_add_footer()


func _rebuild_items() -> void:
	var contexts: Array[GUIDEMappingContext] = [_mapping_context]
	_remapper.initialize(contexts, _working_config)
	_items = _remapper.get_remappable_items(_mapping_context)
	_items.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ac := str(a.display_category)
		var bc := str(b.display_category)
		if ac == bc:
			return str(a.display_name) < str(b.display_name)
		return ac < bc
	)


func _rebuild_rows() -> void:
	_row_data.clear()
	while _items_container.get_child_count() > 0:
		_items_container.get_child(0).free()

	if _items.is_empty():
		_items_container.add_child(_hint("No remappable editor actions are configured."))
		return

	var current_category := ""
	for group: Dictionary in _group_items_by_action():
		var category := str(group.get("category", ""))
		if category != current_category:
			current_category = category
			_items_container.add_child(_section(category if not category.is_empty() else "General"))
		_items_container.add_child(_build_action_row(group))


func _group_items_by_action() -> Array:
	var groups: Array = []
	var by_action: Dictionary = {}
	for item in _items:
		var key := "%d:%d" % [item.context.get_instance_id(), item.action.get_instance_id()]
		if not by_action.has(key):
			var group := {
				"category": str(item.display_category),
				"name": _item_label(item),
				"items": [],
			}
			by_action[key] = group
			groups.append(group)
		(by_action[key]["items"] as Array).append(item)

	for group: Dictionary in groups:
		(group["items"] as Array).sort_custom(func(a: Variant, b: Variant) -> bool:
			return a.index < b.index
		)
	return groups


func _build_action_row(group: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)

	var name_label := Label.new()
	name_label.text = str(group.get("name", ""))
	name_label.custom_minimum_size.x = 210
	name_label.size_flags_horizontal = Control.SIZE_FILL
	row.add_child(name_label)

	var slot_row := HBoxContainer.new()
	slot_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot_row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	row.add_child(slot_row)

	for item in group.get("items", []):
		slot_row.add_child(_build_binding_button(item))

	return row


func _build_binding_button(item: Variant) -> Button:
	var binding_btn := Button.new()
	binding_btn.text = _format_input(_remapper.get_bound_input_or_null(item))
	binding_btn.tooltip_text = "Left click to change\nMiddle click to clear\nRight click to reset"
	binding_btn.custom_minimum_size.x = 160
	binding_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	binding_btn.clip_text = true
	binding_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	AppTheme.style_muted_btn(binding_btn)
	binding_btn.gui_input.connect(func(event: InputEvent) -> void:
		_on_binding_button_input(event, item, binding_btn)
	)
	_row_data.append({"item": item, "button": binding_btn})
	return binding_btn


func _on_binding_button_input(event: InputEvent, item: Variant, button: Button) -> void:
	if not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed:
		return

	match mouse_event.button_index:
		MOUSE_BUTTON_LEFT:
			_start_capture(item)
		MOUSE_BUTTON_MIDDLE:
			_remapper.set_bound_input(item, null)
			_after_binding_changed("Cleared %s" % _slot_label(item))
		MOUSE_BUTTON_RIGHT:
			_remapper.restore_default_for(item)
			_after_binding_changed("Reset %s" % _slot_label(item))
		_:
			return
	button.accept_event()


func _add_footer() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_SETTINGS_H)
	margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_SETTINGS_H)
	margin.add_theme_constant_override("margin_top", AppTheme.SPACING_ROW)
	margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_ROW)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.add_theme_color_override("font_color", AppTheme.BTN_SAVE)
	save_btn.pressed.connect(_on_save_pressed)
	row.add_child(save_btn)

	var apply_btn := Button.new()
	apply_btn.text = "Apply"
	AppTheme.style_muted_btn(apply_btn)
	apply_btn.pressed.connect(_apply_working_config)
	row.add_child(apply_btn)

	var reset_all_btn := Button.new()
	reset_all_btn.text = "Reset All"
	reset_all_btn.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
	reset_all_btn.pressed.connect(_on_reset_all_pressed)
	row.add_child(reset_all_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	AppTheme.style_muted_btn(close_btn)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	row.add_child(close_btn)

	margin.add_child(row)
	add_child(margin)


func _start_capture(item: Variant) -> void:
	if _detector.is_detecting:
		_detector.abort_detection()
	_capturing_item = item
	_set_status("Press a key, mouse button, or controller input for %s..." % _item_label(item), false)
	_detector.detect(item.value_type, [
		GUIDEInput.DeviceType.KEYBOARD,
		GUIDEInput.DeviceType.MOUSE,
		GUIDEInput.DeviceType.JOY,
	])


func _on_detection_started() -> void:
	if _capturing_item != null:
		_set_status("Listening for %s..." % _item_label(_capturing_item), false)


func _on_input_detected(input: GUIDEInput) -> void:
	var item: Variant = _capturing_item
	_capturing_item = null
	if item == null:
		return
	if input == null:
		_set_status("Input capture cancelled", true)
		return
	var collisions: Array = _remapper.get_input_collisions(item, input)
	_remapper.set_bound_input(item, input)
	var message: String = "Bound %s to %s" % [_item_label(item), _format_input(input)]
	if not collisions.is_empty():
		var names := collisions.map(func(other: Variant) -> String: return _item_label(other))
		message += " (also used by %s)" % ", ".join(PackedStringArray(names))
	_after_binding_changed(message, not collisions.is_empty())


func _after_binding_changed(message: String, is_warning: bool = false) -> void:
	_dirty = true
	_apply_working_config()
	_refresh_binding_labels()
	_set_status(message + ". Save to keep it.", is_warning)


func _refresh_binding_labels() -> void:
	for entry: Dictionary in _row_data:
		var button := entry["button"] as Button
		if is_instance_valid(button):
			button.text = _format_input(_remapper.get_bound_input_or_null(entry["item"]))


func _apply_working_config() -> void:
	_working_config = _remapper.get_mapping_config()
	keymap_changed.emit(_working_config)


func _on_save_pressed() -> void:
	_apply_working_config()
	var err := save_config(_working_config)
	if err != OK:
		_set_status("Could not save keymap (error %d)" % err, true)
		return
	_dirty = false
	_set_status("Keymap saved", false)


func _on_reset_all_pressed() -> void:
	_working_config = GUIDERemappingConfig.new()
	_rebuild_items()
	_rebuild_rows()
	_apply_working_config()
	_dirty = true
	_set_status("Restored all default key mappings. Save to keep it.", false)


func _item_label(item: Variant) -> String:
	var text := str(item.display_name)
	if text.is_empty():
		text = str(item.action.name)
	return text


func _slot_label(item: Variant) -> String:
	var label := _item_label(item)
	if item.index == 0:
		return label
	return "%s secondary" % label


func _format_input(input: GUIDEInput) -> String:
	if input == null:
		return "Unbound"
	if input is GUIDEInputKey:
		return _format_key_input(input as GUIDEInputKey)
	if input is GUIDEInputMouseButton:
		return _format_mouse_button(input as GUIDEInputMouseButton)
	if input is GUIDEInputJoyButton:
		return "Joy Button %d" % int((input as GUIDEInputJoyButton).button)
	if input is GUIDEInputJoyAxis1D:
		return "Joy Axis %d" % int((input as GUIDEInputJoyAxis1D).axis)
	if input is GUIDEInputMouseAxis1D:
		return "Mouse Axis"
	if input is GUIDEInputMouseAxis2D:
		return "Mouse Move"
	return input._editor_name()


func _format_key_input(input: GUIDEInputKey) -> String:
	var parts: Array[String] = []
	if input.control:
		parts.append("Ctrl")
	if input.shift:
		parts.append("Shift")
	if input.alt:
		parts.append("Alt")
	if input.meta:
		parts.append("Meta")
	var key_name := OS.get_keycode_string(input.key)
	parts.append(key_name if not key_name.is_empty() else str(input.key))
	return "+".join(parts)


func _format_mouse_button(input: GUIDEInputMouseButton) -> String:
	match input.button:
		MOUSE_BUTTON_LEFT:
			return "Mouse Left"
		MOUSE_BUTTON_RIGHT:
			return "Mouse Right"
		MOUSE_BUTTON_MIDDLE:
			return "Mouse Middle"
		MOUSE_BUTTON_WHEEL_UP:
			return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "Wheel Down"
		_:
			return "Mouse Button %d" % int(input.button)


func _set_status(text: String, is_error: bool) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text
		_status_label.visible = not text.is_empty()
		AppTheme.style_status(_status_label, is_error)
	status_changed.emit(text, is_error)


func _section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", AppTheme.FONT_HEADER)
	lbl.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	return lbl


func _hint(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	AppTheme.style_muted(lbl)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	return lbl
