class_name KeymapSettingsTab extends VBoxContainer

signal close_requested
signal keymap_changed(config: Dictionary)
signal status_changed(text: String, is_error: bool)

const KEYMAP_PATH := "user://keymaps/editor_keymap.json"
const SLOT_COUNT := 2
const SMOOTH_SCROLL_CONTAINER := preload("res://scenes/smooth_scroll_container.gd")

const ACTION_OPEN := &"open_file"
const ACTION_CLOSE := &"close_tab"
const ACTION_SAVE := &"save_file"
const ACTION_REUSE := &"reuse_asset"
const ACTION_PREVIOUS_TAB := &"previous_tab"
const ACTION_NEXT_TAB := &"next_tab"
const ACTION_COPY := &"copy_selection"
const ACTION_PASTE := &"paste_selection"
const ACTION_CUT := &"cut_selection"
const ACTION_UNDO := &"undo"
const ACTION_DELETE := &"delete_selection"
const ACTION_CANCEL := &"cancel"
const ACTION_CREATE := &"add_files_from_sources"
const ACTION_COMPARE := &"compare_file"

var _working_config: Dictionary = {}
var _row_data: Array[Dictionary] = []
var _items_container: VBoxContainer
var _status_label: Label
var _capturing_action := StringName()
var _capturing_slot := -1
var _dirty := false


static func action_definitions() -> Array[Dictionary]:
	return [
		_definition(ACTION_OPEN, "Open File", "File", _key(KEY_SPACE, true)),
		_definition(ACTION_CLOSE, "Close Tab", "File", _key(KEY_Q, true)),
		_definition(ACTION_SAVE, "Save File", "File", _key(KEY_S, true)),
		_definition(ACTION_REUSE, "Reuse Asset As", "File", _key(KEY_S, true, true)),
		_definition(ACTION_COMPARE, "Compare File", "File", _key(KEY_K, true)),
		_definition(ACTION_COPY, "Copy", "Edit", _key(KEY_C, true)),
		_definition(ACTION_PASTE, "Paste", "Edit", _key(KEY_V, true)),
		_definition(ACTION_CUT, "Cut", "Edit", _key(KEY_X, true)),
		_definition(ACTION_UNDO, "Undo", "Edit", _key(KEY_Z, true)),
		_definition(ACTION_DELETE, "Delete Selection", "Edit",
				_key(KEY_D, true), _key(KEY_DELETE)),
		_definition(ACTION_CANCEL, "Cancel / Clear Selection", "Edit", _key(KEY_ESCAPE)),
		_definition(ACTION_PREVIOUS_TAB, "Previous Tab", "Navigation",
				_key(KEY_A, true), _key(KEY_LEFT, true)),
		_definition(ACTION_NEXT_TAB, "Next Tab", "Navigation",
				_key(KEY_F, true), _key(KEY_RIGHT, true)),
		_definition(ACTION_CREATE, "Add Files from Sources", "Mod Manager",
				_key(KEY_E, true)),
	]


static func load_saved_config() -> Dictionary:
	if not FileAccess.file_exists(KEYMAP_PATH):
		return default_config()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(KEYMAP_PATH))
	return normalize_config(parsed if parsed is Dictionary else {})


static func save_config(config: Dictionary) -> Error:
	var directory := ProjectSettings.globalize_path(KEYMAP_PATH.get_base_dir())
	var directory_error := DirAccess.make_dir_recursive_absolute(directory)
	if directory_error != OK:
		return directory_error
	return FileUtils.write_bytes_atomic(
			ProjectSettings.globalize_path(KEYMAP_PATH),
			(JSON.stringify(normalize_config(config), "\t") + "\n").to_utf8_buffer())


static func default_config() -> Dictionary:
	var result := {}
	for definition in action_definitions():
		result[str(definition["action"])] = (definition["defaults"] as Array).duplicate(true)
	return result


static func normalize_config(raw_config: Dictionary) -> Dictionary:
	var result := default_config()
	var explicitly_bound: Array[Dictionary] = []
	for definition in action_definitions():
		var action := str(definition["action"])
		if not raw_config.has(action) or not raw_config[action] is Array:
			continue
		var raw_slots := raw_config[action] as Array
		var slots: Array = [null, null]
		for slot in mini(raw_slots.size(), SLOT_COUNT):
			var event_data: Variant = raw_slots[slot]
			if event_data == null or event_data is Dictionary:
				if event_data is Dictionary:
					slots[slot] = (event_data as Dictionary).duplicate(true)
				else:
					slots[slot] = null
				if slots[slot] != null:
					explicitly_bound.append({"action": action, "slot": slot,
						"event": slots[slot]})
		result[action] = slots

	# A saved user binding wins over a default introduced for another action.
	for explicit in explicitly_bound:
		for definition in action_definitions():
			var other_action := str(definition["action"])
			if raw_config.has(other_action):
				continue
			var slots := result[other_action] as Array
			for slot in slots.size():
				if events_equal_data(slots[slot], explicit["event"]):
					slots[slot] = null
	return result


static func apply_config(config: Dictionary) -> void:
	var normalized := normalize_config(config)
	for definition in action_definitions():
		var action := definition["action"] as StringName
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for event_data in normalized[str(action)]:
			var event := event_from_data(event_data)
			if event != null:
				InputMap.action_add_event(action, event)


static func set_binding(config: Dictionary, action: StringName, slot: int,
		event: InputEvent) -> Dictionary:
	var result := normalize_config(config)
	var event_data: Variant = event_to_data(event) if event != null else null
	if event_data != null:
		for action_name in result:
			var slots := result[action_name] as Array
			for index in slots.size():
				if events_equal_data(slots[index], event_data):
					slots[index] = null
	(result[str(action)] as Array)[slot] = event_data
	return result


static func event_to_data(event: InputEvent) -> Variant:
	if event is InputEventKey:
		var key := event as InputEventKey
		return {
			"type": "key", "keycode": int(key.keycode),
			"physical_keycode": int(key.physical_keycode),
			"ctrl": key.ctrl_pressed, "shift": key.shift_pressed,
			"alt": key.alt_pressed, "meta": key.meta_pressed,
		}
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		return {"type": "mouse_button", "button": int(mouse.button_index)}
	if event is InputEventJoypadButton:
		return {"type": "joy_button", "button": int((event as InputEventJoypadButton).button_index)}
	return null


static func event_from_data(data: Variant) -> InputEvent:
	if not data is Dictionary:
		return null
	var values := data as Dictionary
	match str(values.get("type", "")):
		"key":
			var key := InputEventKey.new()
			key.keycode = int(values.get("keycode", 0)) as Key
			key.physical_keycode = int(values.get("physical_keycode", 0)) as Key
			key.ctrl_pressed = bool(values.get("ctrl", false))
			key.shift_pressed = bool(values.get("shift", false))
			key.alt_pressed = bool(values.get("alt", false))
			key.meta_pressed = bool(values.get("meta", false))
			return key
		"mouse_button":
			var mouse := InputEventMouseButton.new()
			mouse.button_index = int(values.get("button", 0)) as MouseButton
			return mouse
		"joy_button":
			var joy := InputEventJoypadButton.new()
			joy.button_index = int(values.get("button", 0)) as JoyButton
			return joy
	return null


static func events_equal_data(a: Variant, b: Variant) -> bool:
	var first := event_from_data(a)
	var second := event_from_data(b)
	return first != null and second != null and first.is_match(second)


static func _definition(action: StringName, display_name: String, category: String,
		primary: InputEvent, secondary: InputEvent = null) -> Dictionary:
	return {"action": action, "name": display_name, "category": category,
		"defaults": [event_to_data(primary), event_to_data(secondary)]}


static func _key(keycode: Key, control := false, shift := false,
		alt := false, meta := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.ctrl_pressed = control
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.meta_pressed = meta
	return event


func setup(config: Dictionary) -> KeymapSettingsTab:
	_working_config = normalize_config(config)
	return self


func is_capturing() -> bool:
	return not _capturing_action.is_empty()


func refresh(config: Dictionary = {}) -> void:
	if not config.is_empty():
		_working_config = normalize_config(config)
	_dirty = false
	_capturing_action = &""
	_capturing_slot = -1
	for child in get_children():
		child.free()
	_build_ui()


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()


func _input(event: InputEvent) -> void:
	if not is_capturing() or not _is_bindable_event(event):
		return
	var captured := _clean_event(event)
	var old_config := _working_config
	_working_config = set_binding(
			_working_config, _capturing_action, _capturing_slot, captured)
	var replaced := _binding_replacement_labels(old_config, _working_config)
	var label := _action_label(_capturing_action)
	_capturing_action = &""
	_capturing_slot = -1
	var message := "Bound %s to %s" % [label, format_event(captured)]
	if not replaced.is_empty():
		message += " (replaced %s)" % ", ".join(replaced)
	_after_binding_changed(message)
	get_viewport().set_input_as_handled()


func _build_ui() -> void:
	add_theme_constant_override("separation", 0)
	var scroll := SMOOTH_SCROLL_CONTAINER.new() as ScrollContainer
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right"]:
		outer.add_theme_constant_override("margin_" + side, AppTheme.MARGIN_SETTINGS_H)
	for side in ["top", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, AppTheme.MARGIN_SETTINGS_V)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", AppTheme.MARGIN_SETTINGS_V)
	content.add_child(_section("Key Mappings"))
	content.add_child(_hint("Customize native Godot shortcuts. Changes apply immediately; save to keep them after restart."))
	_items_container = VBoxContainer.new()
	_items_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_container.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	content.add_child(_items_container)
	_rebuild_rows()
	_status_label = _hint("")
	_status_label.visible = false
	content.add_child(_status_label)
	outer.add_child(content)
	scroll.add_child(outer)
	add_child(scroll)
	add_child(HSeparator.new())
	_add_footer()


func _rebuild_rows() -> void:
	_row_data.clear()
	for child in _items_container.get_children():
		child.free()
	var current_category := ""
	for definition in action_definitions():
		var category := str(definition["category"])
		if category != current_category:
			current_category = category
			_items_container.add_child(_section(category))
		_items_container.add_child(_build_action_row(definition))


func _build_action_row(definition: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	var label := Label.new()
	label.text = str(definition["name"])
	label.custom_minimum_size.x = 210
	row.add_child(label)
	var slots := HBoxContainer.new()
	slots.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	row.add_child(slots)
	var action := definition["action"] as StringName
	for slot in SLOT_COUNT:
		slots.add_child(_build_binding_button(action, slot))
	return row


func _build_binding_button(action: StringName, slot: int) -> Button:
	var button := Button.new()
	button.text = format_event(event_from_data((_working_config[str(action)] as Array)[slot]))
	button.tooltip_text = "Left click to change\nMiddle click to clear\nRight click to reset"
	button.custom_minimum_size.x = 160
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	AppTheme.style_muted_btn(button)
	button.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			match (event as InputEventMouseButton).button_index:
				MOUSE_BUTTON_LEFT: _start_capture(action, slot)
				MOUSE_BUTTON_MIDDLE: _change_binding(action, slot, null, "Cleared")
				MOUSE_BUTTON_RIGHT: _reset_binding(action, slot)
				_: return
			button.accept_event()
	)
	_row_data.append({"action": action, "slot": slot, "button": button})
	return button


func _start_capture(action: StringName, slot: int) -> void:
	_capturing_action = action
	_capturing_slot = slot
	_set_status("Press a key combination, mouse button, or controller button for %s..." %
			_action_label(action), false)


func _change_binding(action: StringName, slot: int, event: InputEvent,
		verb: String) -> void:
	_working_config = set_binding(_working_config, action, slot, event)
	_after_binding_changed("%s %s" % [verb, _slot_label(action, slot)])


func _reset_binding(action: StringName, slot: int) -> void:
	var defaults := default_config()
	var event := event_from_data((defaults[str(action)] as Array)[slot])
	_change_binding(action, slot, event, "Reset")


func _after_binding_changed(message: String) -> void:
	_dirty = true
	apply_config(_working_config)
	keymap_changed.emit(_working_config.duplicate(true))
	_refresh_binding_labels()
	_set_status(message + ". Save to keep it.", false)


func _refresh_binding_labels() -> void:
	for entry in _row_data:
		var button := entry["button"] as Button
		if is_instance_valid(button):
			var slots := _working_config[str(entry["action"])] as Array
			button.text = format_event(event_from_data(slots[int(entry["slot"])]))


func _on_save_pressed() -> void:
	apply_config(_working_config)
	keymap_changed.emit(_working_config.duplicate(true))
	var error := save_config(_working_config)
	if error != OK:
		_set_status("Could not save keymap (error %d)" % error, true)
		return
	_dirty = false
	_set_status("Keymap saved", false)


func _on_reset_all_pressed() -> void:
	_working_config = default_config()
	apply_config(_working_config)
	keymap_changed.emit(_working_config.duplicate(true))
	_rebuild_rows()
	_dirty = true
	_set_status("Restored all default key mappings. Save to keep it.", false)


func _add_footer() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, AppTheme.MARGIN_SETTINGS_H)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, AppTheme.SPACING_ROW)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	var save_button := Button.new()
	save_button.text = "Save"
	save_button.add_theme_color_override("font_color", AppTheme.BTN_SAVE)
	save_button.pressed.connect(_on_save_pressed)
	row.add_child(save_button)
	var reset_button := Button.new()
	reset_button.text = "Reset All"
	reset_button.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
	reset_button.pressed.connect(_on_reset_all_pressed)
	row.add_child(reset_button)
	var close_button := Button.new()
	close_button.text = "Close"
	AppTheme.style_muted_btn(close_button)
	close_button.pressed.connect(func() -> void: close_requested.emit())
	row.add_child(close_button)
	margin.add_child(row)
	add_child(margin)


static func format_event(event: InputEvent) -> String:
	if event == null:
		return "Unbound"
	if event is InputEventKey:
		var key := event as InputEventKey
		var parts: Array[String] = []
		if key.ctrl_pressed: parts.append("Ctrl")
		if key.shift_pressed: parts.append("Shift")
		if key.alt_pressed: parts.append("Alt")
		if key.meta_pressed: parts.append("Meta")
		var code := key.keycode if key.keycode != KEY_NONE else key.physical_keycode
		parts.append(OS.get_keycode_string(code))
		return "+".join(parts)
	if event is InputEventMouseButton:
		return "Mouse Button %d" % int((event as InputEventMouseButton).button_index)
	if event is InputEventJoypadButton:
		return "Joy Button %d" % int((event as InputEventJoypadButton).button_index)
	return event.as_text()


func _binding_replacement_labels(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var labels := PackedStringArray()
	for definition in action_definitions():
		var action := definition["action"] as StringName
		for slot in SLOT_COUNT:
			var old_value: Variant = (before[str(action)] as Array)[slot]
			var new_value: Variant = (after[str(action)] as Array)[slot]
			if old_value != null and new_value == null \
					and not (action == _capturing_action and slot == _capturing_slot):
				labels.append(_slot_label(action, slot))
	return labels


func _action_label(action: StringName) -> String:
	for definition in action_definitions():
		if definition["action"] == action:
			return str(definition["name"])
	return str(action)


func _slot_label(action: StringName, slot: int) -> String:
	return _action_label(action) if slot == 0 else "%s secondary" % _action_label(action)


func _is_bindable_event(event: InputEvent) -> bool:
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo and not _is_modifier_key(key)
	return (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
			or (event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed)


static func _is_modifier_key(event: InputEventKey) -> bool:
	var modifiers: Array[Key] = [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]
	return event.keycode in modifiers or event.physical_keycode in modifiers


func _clean_event(event: InputEvent) -> InputEvent:
	var clean := event.duplicate() as InputEvent
	clean.set("pressed", false)
	if clean is InputEventKey:
		(clean as InputEventKey).echo = false
	return clean


func _set_status(text: String, is_error: bool) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text
		_status_label.visible = not text.is_empty()
		AppTheme.style_status(_status_label, is_error)
	status_changed.emit(text, is_error)


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", AppTheme.FONT_HEADER)
	label.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	return label


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	AppTheme.style_muted(label)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	return label
