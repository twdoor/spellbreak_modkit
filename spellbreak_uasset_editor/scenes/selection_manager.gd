class_name SelectionManager extends RefCounted

## Manages multi-item selection state for list views (imports, exports, name map).
## Owns the set of selected items, the shift-click anchor, and the row panel map
## used for highlight rendering.

const _COLOR_SELECTED := Color(0.15, 0.38, 0.70, 0.55)
const _COLOR_NORMAL   := Color(0.0,  0.0,  0.0,  0.0)

var _selection: Array = []
var _last_selected_anchor: Variant = null
var _row_panels: Dictionary = {}

## Cached style boxes — created once, reused on every highlight update.
var _style_selected: StyleBoxFlat
var _style_normal: StyleBoxFlat


func _init() -> void:
	_style_selected = StyleBoxFlat.new()
	_style_selected.bg_color = _COLOR_SELECTED
	_style_normal = StyleBoxFlat.new()
	_style_normal.bg_color = _COLOR_NORMAL

## Emitted whenever the selection changes. current is the single selected item or null.
signal selection_changed(selection: Array, current: Variant)


func get_selection() -> Array:
	return _selection


## Returns the single selected item, or null if 0 or more than 1 items are selected.
func get_current() -> Variant:
	if _selection.size() == 1:
		return _selection[0]
	return null


func set_selection(items: Array) -> void:
	_selection = items.duplicate()
	if _selection.size() == 1:
		_last_selected_anchor = _selection[0]
	_update_row_highlights()
	selection_changed.emit(_selection, get_current())


func toggle(item: Variant) -> void:
	var idx := _selection.find(item)
	if idx >= 0:
		_selection.remove_at(idx)
	else:
		_selection.append(item)
		_last_selected_anchor = item
	_update_row_highlights()
	selection_changed.emit(_selection, get_current())


## Select all items in ordered_list between the last anchor and target (inclusive).
## ordered_list accepts Array or typed Array (passed as Variant to avoid typed-array errors).
func range_select(target: Variant, ordered_list: Variant) -> void:
	var list: Array = []
	for item in ordered_list:
		list.append(item)
	var anchor: Variant = _last_selected_anchor if _last_selected_anchor != null else target
	var a := list.find(anchor)
	var b := list.find(target)
	if a < 0 or b < 0:
		set_selection([target])
		return
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var new_sel: Array = []
	for i in range(lo, hi + 1):
		new_sel.append(list[i])
	_selection = new_sel.duplicate()
	_update_row_highlights()
	# Anchor stays fixed so repeated shift+clicks extend from the same anchor
	selection_changed.emit(_selection, get_current())


## Convenience: route a button press through shift/ctrl/plain click logic.
## ordered_list is a Callable returning the full list for shift+click range selection.
func handle_click(item: Variant, ordered_list: Callable) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		range_select(item, ordered_list.call())
	elif Input.is_key_pressed(KEY_CTRL):
		toggle(item)
	else:
		set_selection([item])


func clear() -> void:
	_selection.clear()
	_last_selected_anchor = null
	_update_row_highlights()
	selection_changed.emit(_selection, null)


## Drop all panel registrations (called before a detail panel rebuild).
func clear_panels() -> void:
	_row_panels.clear()


func _update_row_highlights() -> void:
	for key in _row_panels:
		var panel: PanelContainer = _row_panels[key]
		if not is_instance_valid(panel):
			continue
		var selected: bool = key in _selection
		panel.add_theme_stylebox_override("panel", _style_selected if selected else _style_normal)


## Wrap inner in a PanelContainer registered under key so it gets highlight updates.
## click_handler receives (ctrl_held: bool).
## get_list (optional): Callable returning the full ordered Array for shift+click range selection.
func make_selectable_row(key: Variant, inner: Control, click_handler: Callable, get_list: Callable = Callable()) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _style_normal)
	panel.add_child(inner)
	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if event.shift_pressed and not get_list.is_null():
				range_select(key, get_list.call())
			else:
				click_handler.call(event.ctrl_pressed)
	)
	_row_panels[key] = panel
	return panel
