extends Node

## Loads user-editable theme values and applies changes while the app is running.

signal theme_reloaded
signal theme_reload_failed(message: String)

const COLORS_FILE_NAME := "colors.json"
const THEME_FILE_NAME := "theme.json"
const WATCH_INTERVAL_SECONDS := 0.5
const LIVE_NODES_PER_FRAME := 250
const COMPACT_COLOR_REPRESENTATIVES := {
	"canvas": "BG_PRIMARY",
	"surface": "BG_PANEL",
	"interactive": "BG_HOVER",
	"bars_and_popups": "BG_CHROME",
	"accent": "ACCENT",
	"secondary_accent": "ACCENT_DIM",
	"primary_text": "TEXT_PRIMARY",
	"secondary_text": "TEXT_MUTED",
	"links": "BTN_NAV",
	"success": "STATUS_SUCCESS",
	"warning": "STATUS_WARNING",
	"danger": "STATUS_ERROR",
}
const COMPACT_METRIC_REPRESENTATIVES := {
	"title_text": "FONT_HEADER",
	"body_text": "FONT_DEFAULT",
	"small_text": "FONT_SMALL",
	"compact_text": "FONT_TINY",
	"tight_gap": "SPACING_TIGHT",
	"normal_gap": "SPACING_FIELD",
	"large_gap": "SPACING_ROW",
	"horizontal_padding": "MARGIN_TOOLBAR_H",
	"vertical_padding": "MARGIN_TOOLBAR_TOP",
	"roundness": "CORNER_RADIUS",
}

var colors_file_path := ""
var theme_file_path := ""
var last_error := ""

var _colors_hash := 0
var _theme_hash := 0
var _elapsed := 0.0
var _current_colors: Dictionary = {}
var _current_metrics: Dictionary = {}
var _compact_colors: Dictionary = {}
var _compact_metrics: Dictionary = {}
var _default_compact_colors: Dictionary = {}
var _default_compact_metrics: Dictionary = {}
var _pending_objects: Array[Variant] = []
var _pending_colors: Dictionary = {}
var _pending_metrics: Dictionary = {}


func _ready() -> void:
	var settings := get_node_or_null("/root/AppSettings")
	if settings == null:
		_fail("AppSettings is unavailable; dynamic themes are disabled.")
		return
	colors_file_path = settings.get_file_path(COLORS_FILE_NAME)
	theme_file_path = settings.get_file_path(THEME_FILE_NAME)
	settings.ensure_config_directory()
	_current_colors = _read_app_colors()
	_current_metrics = _read_app_metrics()
	_default_compact_colors = _compact_colors_from_expanded(_current_colors)
	_default_compact_metrics = _compact_metrics_from_expanded(_current_metrics)
	_compact_colors = _default_compact_colors.duplicate()
	_compact_metrics = _default_compact_metrics.duplicate()
	_write_default_file(colors_file_path, _serialize_colors(_compact_colors))
	_write_default_file(theme_file_path, _compact_metrics)
	reload()
	set_process(true)


func _process(delta: float) -> void:
	_process_live_updates()
	_elapsed += delta
	if _elapsed < WATCH_INTERVAL_SECONDS:
		return
	_elapsed = 0.0
	var colors_hash := _file_hash(colors_file_path)
	var theme_hash := _file_hash(theme_file_path)
	if colors_hash != _colors_hash or theme_hash != _theme_hash:
		if reload() != OK:
			# Do not report the same invalid save every polling interval. A later
			# edit changes the hash and triggers another attempt.
			_colors_hash = colors_hash
			_theme_hash = theme_hash


func reload() -> Error:
	var colors_result := _load_json_object(colors_file_path)
	if not colors_result.ok:
		return _fail(colors_result.error)
	var theme_result := _load_json_object(theme_file_path)
	if not theme_result.ok:
		return _fail(theme_result.error)

	var parsed_colors := _parse_compact_colors(colors_result.value)
	if not parsed_colors.ok:
		return _fail(parsed_colors.error)
	var parsed_metrics := _parse_compact_metrics(theme_result.value)
	if not parsed_metrics.ok:
		return _fail(parsed_metrics.error)
	_apply_compact_values(parsed_colors.value, parsed_metrics.value)
	if parsed_colors.legacy or parsed_metrics.legacy:
		var migration_error := _save_compact_files(_compact_colors, _compact_metrics)
		if migration_error != OK:
			return _fail("Could not migrate theme files to the compact format (error %d)." % migration_error)
	_colors_hash = _file_hash(colors_file_path)
	_theme_hash = _file_hash(theme_file_path)
	last_error = ""
	theme_reloaded.emit()
	return OK


func get_color_values() -> Dictionary:
	return _compact_colors.duplicate()


func get_metric_values() -> Dictionary:
	return _compact_metrics.duplicate()


func get_default_color_values() -> Dictionary:
	return _default_compact_colors.duplicate()


func get_default_metric_values() -> Dictionary:
	return _default_compact_metrics.duplicate()


## Applies an in-memory preview. This does not modify either JSON file.
func preview_values(colors: Dictionary, metrics: Dictionary) -> Error:
	if not _values_are_valid(colors, metrics):
		return ERR_INVALID_PARAMETER
	var next_colors := _compact_colors.duplicate()
	var next_metrics := _compact_metrics.duplicate()
	for key: String in colors:
		if next_colors.has(key):
			next_colors[key] = colors[key]
	for key: String in metrics:
		if next_metrics.has(key):
			next_metrics[key] = int(metrics[key])
	_apply_compact_values(next_colors, next_metrics)
	return OK


## Saves and applies complete editor values through atomic file replacements.
func save_values(colors: Dictionary, metrics: Dictionary) -> Error:
	if not _values_are_valid(colors, metrics):
		return ERR_INVALID_PARAMETER
	var saved_colors := _compact_colors.duplicate()
	var saved_metrics := _compact_metrics.duplicate()
	for key: String in colors:
		if saved_colors.has(key):
			saved_colors[key] = colors[key]
	for key: String in metrics:
		if saved_metrics.has(key):
			saved_metrics[key] = int(metrics[key])
	var error := _save_compact_files(saved_colors, saved_metrics)
	if error != OK:
		return error
	preview_values(saved_colors, saved_metrics)
	_colors_hash = _file_hash(colors_file_path)
	_theme_hash = _file_hash(theme_file_path)
	return OK


func _apply_values(next_colors: Dictionary, next_metrics: Dictionary) -> void:
	var old_colors := _changed_values(_current_colors, next_colors)
	var old_metrics := _changed_values(_current_metrics, next_metrics)
	_current_colors = next_colors
	_current_metrics = next_metrics
	_assign_app_values(old_colors, old_metrics)
	if not old_colors.is_empty() or not old_metrics.is_empty():
		_update_theme_resource(AppTheme._theme, old_colors, old_metrics)
		_update_live_tree(old_colors, old_metrics)


func _apply_compact_values(colors: Dictionary, metrics: Dictionary) -> void:
	_compact_colors = colors.duplicate()
	_compact_metrics = metrics.duplicate()
	_apply_values(_expand_colors(_compact_colors), _expand_metrics(_compact_metrics))


func _values_are_valid(colors: Dictionary, metrics: Dictionary) -> bool:
	for key: String in colors:
		if _compact_colors.has(key) and not colors[key] is Color:
			return false
	for key: String in metrics:
		if not _compact_metrics.has(key):
			continue
		var value: Variant = metrics[key]
		if not (value is int or value is float) or value < 0:
			return false
	return true


func _parse_compact_colors(raw: Dictionary) -> Dictionary:
	var result := _compact_colors.duplicate()
	var legacy := false
	for compact_key: String in COMPACT_COLOR_REPRESENTATIVES:
		var source_key := compact_key
		var legacy_key := str(COMPACT_COLOR_REPRESENTATIVES[compact_key])
		if not raw.has(source_key) and raw.has(legacy_key):
			source_key = legacy_key
			legacy = true
		if not raw.has(source_key):
			legacy = true
			continue
		var parsed := Color.from_string(str(raw[source_key]), Color(-1, -1, -1, -1))
		if parsed.r < 0.0:
			return {"ok": false, "error": "Invalid color '%s' for %s in %s." % [raw[source_key], source_key, colors_file_path]}
		result[compact_key] = parsed
	for key: String in raw:
		if _current_colors.has(key):
			legacy = true
	return {"ok": true, "value": result, "legacy": legacy}


func _parse_compact_metrics(raw: Dictionary) -> Dictionary:
	var result := _compact_metrics.duplicate()
	var legacy := false
	for compact_key: String in COMPACT_METRIC_REPRESENTATIVES:
		var source_key := compact_key
		var legacy_key := str(COMPACT_METRIC_REPRESENTATIVES[compact_key])
		if not raw.has(source_key) and raw.has(legacy_key):
			source_key = legacy_key
			legacy = true
		if not raw.has(source_key):
			legacy = true
			continue
		var value: Variant = raw[source_key]
		if not (value is int or value is float) or value < 0:
			return {"ok": false, "error": "Invalid non-negative number for %s in %s." % [source_key, theme_file_path]}
		result[compact_key] = int(value)
	for key: String in raw:
		if _current_metrics.has(key):
			legacy = true
	return {"ok": true, "value": result, "legacy": legacy}


func _compact_colors_from_expanded(expanded: Dictionary) -> Dictionary:
	var result := {}
	for key: String in COMPACT_COLOR_REPRESENTATIVES:
		result[key] = expanded[str(COMPACT_COLOR_REPRESENTATIVES[key])]
	return result


func _compact_metrics_from_expanded(expanded: Dictionary) -> Dictionary:
	var result := {}
	for key: String in COMPACT_METRIC_REPRESENTATIVES:
		result[key] = expanded[str(COMPACT_METRIC_REPRESENTATIVES[key])]
	return result


func _expand_colors(compact: Dictionary) -> Dictionary:
	var result := _current_colors.duplicate()
	_set_dictionary_values(result, ["BG_PRIMARY"], compact.canvas)
	_set_dictionary_values(result, ["BG_PANEL"], compact.surface)
	_set_dictionary_values(result, ["BG_FIELD"], _variant(compact.surface, -0.12, 0.60))
	_set_dictionary_values(result, ["BG_TOAST"], _variant(compact.surface, -0.08, 0.93))
	_set_dictionary_values(result, ["BG_HOVER"], compact.interactive)
	_set_dictionary_values(result, ["TREE_SELECTED"], _variant(compact.interactive, -0.08, 1.0))
	_set_dictionary_values(result, ["BG_CHROME"], compact.bars_and_popups)
	_set_dictionary_values(result, ["ACCENT", "BTN_PACK", "BTN_LAUNCH"], compact.accent)
	_set_dictionary_values(result, ["BG_SELECTION"], _variant(compact.accent, -0.28, 0.55))
	_set_dictionary_values(result, ["ACCENT_DIM", "STATUS_WORKING"], compact.secondary_accent)
	_set_dictionary_values(result, ["TEXT_PRIMARY", "TEXT_TOAST"], compact.primary_text)
	_set_dictionary_values(result, ["TEXT_HEADING", "BTN_MUTED_HOVER"], _variant(compact.primary_text, 0.04))
	_set_dictionary_values(result, ["MOD_DISABLED"], _variant(compact.primary_text, -0.06))
	_set_dictionary_values(result, ["TEXT_MUTED", "STATUS_IDLE", "BTN_MUTED", "MOD_PLACEHOLDER"], compact.secondary_text)
	_set_dictionary_values(result, ["TEXT_DIM", "TEXT_SUBTLE", "MOD_FILE_OTHER"], _variant(compact.secondary_text, 0.10))
	_set_dictionary_values(result, ["TREE_FONT_COLOR"], _variant(compact.secondary_text, 0.20))
	_set_dictionary_values(result, ["TEXT_VERY_MUTED"], _variant(compact.secondary_text, -0.08))
	_set_dictionary_values(result, ["MOD_DIR"], _variant(compact.secondary_text, 0.04))
	_set_dictionary_values(result, ["BTN_NAV", "REF_LINE_COLOR", "MOD_FILE_UASSET"], compact.links)
	_set_dictionary_values(result, ["BTN_NAV_HOVER"], _variant(compact.links, 0.18))
	_set_dictionary_values(result, ["REF_COLOR"], _variant(compact.links, -0.05))
	_set_dictionary_values(result, ["STATUS_SUCCESS", "BTN_ADD", "BTN_NEW_MOD", "BTN_SAVE", "MOD_ENABLED"], compact.success)
	_set_dictionary_values(result, ["STATUS_ACTIVE"], _variant(compact.success, 0.08))
	_set_dictionary_values(result, ["BTN_ADD_HOVER"], _variant(compact.success, 0.20))
	_set_dictionary_values(result, ["STATUS_WARNING", "TEXT_SECTION"], compact.warning)
	_set_dictionary_values(result, ["TEXT_INFO_YELLOW"], _variant(compact.warning, 0.10))
	_set_dictionary_values(result, ["STATUS_ERROR", "BTN_DELETE", "BTN_REMOVE"], compact.danger)
	_set_dictionary_values(result, ["BTN_DELETE_HOVER"], _variant(compact.danger, 0.16))
	return result


func _expand_metrics(compact: Dictionary) -> Dictionary:
	var result := _current_metrics.duplicate()
	_set_dictionary_values(result, ["FONT_HEADER"], compact.title_text)
	_set_dictionary_values(result, ["FONT_DEFAULT"], compact.body_text)
	_set_dictionary_values(result, ["FONT_TOAST", "FONT_REF"], int(compact.body_text) + 1)
	_set_dictionary_values(result, ["FONT_STATUS", "FONT_SECTION", "FONT_SMALL"], compact.small_text)
	_set_dictionary_values(result, ["FONT_BADGE", "FONT_STATUS_BAR", "FONT_TINY"], compact.compact_text)
	_set_dictionary_values(result, ["SPACING_TAGS", "SPACING_TIGHT"], compact.tight_gap)
	_set_dictionary_values(result, ["SPACING_FIELD"], compact.normal_gap)
	_set_dictionary_values(result, ["SPACING_ROW"], compact.large_gap)
	var horizontal := int(compact.horizontal_padding)
	_set_dictionary_values(result, ["MARGIN_TOOLBAR_H"], horizontal)
	_set_dictionary_values(result, ["MARGIN_STATUS_H", "MARGIN_LOG_H"], maxi(0, roundi(horizontal * 1.25)))
	_set_dictionary_values(result, ["MARGIN_SETTINGS_H"], maxi(0, roundi(horizontal * 2.5)))
	_set_dictionary_values(result, ["MARGIN_SELECTABLE_H_L"], maxi(0, roundi(horizontal * 0.75)))
	_set_dictionary_values(result, ["MARGIN_SELECTABLE_H_R"], maxi(0, roundi(horizontal * 0.5)))
	var vertical := int(compact.vertical_padding)
	_set_dictionary_values(result, ["MARGIN_TOOLBAR_TOP"], vertical)
	_set_dictionary_values(result, ["MARGIN_TOOLBAR_BOTTOM", "MARGIN_LOG_BOTTOM"], maxi(0, vertical - 2))
	_set_dictionary_values(result, ["MARGIN_STATUS_V", "MARGIN_SELECTABLE_V"], maxi(0, roundi(vertical * 0.5)))
	_set_dictionary_values(result, ["MARGIN_LOG_TOP"], maxi(0, roundi(vertical / 3.0)))
	_set_dictionary_values(result, ["MARGIN_SETTINGS_V"], maxi(0, roundi(vertical * 2.67)))
	var roundness := int(compact.roundness)
	_set_dictionary_values(result, ["CORNER_RADIUS"], roundness)
	_set_dictionary_values(result, ["CORNER_TOAST"], maxi(0, roundi(roundness * 2.67)))
	return result


func _set_dictionary_values(target: Dictionary, keys: Array, value: Variant) -> void:
	for key: String in keys:
		if target.has(key):
			target[key] = value


func _variant(color: Color, brightness: float, alpha: float = -1.0) -> Color:
	var result := color.lightened(brightness) if brightness >= 0.0 else color.darkened(-brightness)
	if alpha >= 0.0:
		result.a = alpha
	return result


func _with_alpha(color: Color, alpha: float) -> Color:
	color.a = alpha
	return color


func _save_compact_files(colors: Dictionary, metrics: Dictionary) -> Error:
	var error := FileUtils.write_bytes_atomic(
		colors_file_path,
		(JSON.stringify(_serialize_colors(colors), "  ") + "\n").to_utf8_buffer()
	)
	if error != OK:
		return error
	return FileUtils.write_bytes_atomic(
		theme_file_path,
		(JSON.stringify(metrics, "  ") + "\n").to_utf8_buffer()
	)


func _assign_app_values(changed_colors: Dictionary, changed_metrics: Dictionary) -> void:
	for key: String in changed_colors:
		_set_app_color(key, _current_colors[key])
	for key: String in changed_metrics:
		_set_app_metric(key, _current_metrics[key])


func _update_theme_resource(theme: Theme, old_colors: Dictionary, old_metrics: Dictionary) -> void:
	var changed := false
	# Theme emits a change for every setter. Suppress those intermediate events
	# and send one notification after the batch instead.
	theme.set_block_signals(true)
	for type_name: String in theme.get_type_list():
		for color_name: String in theme.get_color_list(type_name):
			var current := theme.get_color(color_name, type_name)
			var replacement := _replace_color(current, old_colors)
			if not current.is_equal_approx(replacement):
				theme.set_color(color_name, type_name, replacement)
				changed = true
		for constant_name: String in theme.get_constant_list(type_name):
			var current := theme.get_constant(constant_name, type_name)
			var replacement := _replace_metric(current, old_metrics)
			if current != replacement:
				theme.set_constant(constant_name, type_name, replacement)
				changed = true
		for stylebox_name: String in theme.get_stylebox_list(type_name):
			changed = _update_resource(
				theme.get_stylebox(stylebox_name, type_name), old_colors
			) or changed
	changed = _update_chrome_theme_styles(theme) or changed
	theme.set_block_signals(false)
	if changed:
		theme.emit_changed()


func _update_live_tree(old_colors: Dictionary, old_metrics: Dictionary) -> void:
	# Existing local overrides cannot inherit the shared Theme change. Update
	# them in bounded chunks so a large, deeply expanded asset view never stalls
	# the UI thread for an entire frame.
	_pending_colors = old_colors.duplicate()
	_pending_metrics = old_metrics.duplicate()
	_pending_objects.assign([get_tree().root])
	_refresh_window_panels(get_tree().root)


func _refresh_window_panels(node: Node) -> void:
	if node is Window:
		for child in node.get_children(true):
			var panel := child as Panel
			if panel != null and panel.name != "_AppThemeChromeBackground":
				var dialog_style := StyleBoxFlat.new()
				dialog_style.bg_color = AppTheme.BG_CHROME
				panel.add_theme_stylebox_override("panel", dialog_style)
	for child in node.get_children():
		_refresh_window_panels(child)


func _update_chrome_theme_styles(theme: Theme) -> bool:
	var color: Color = _current_colors.BG_CHROME
	var primary_text: Color = _current_colors.TEXT_PRIMARY
	var secondary_text: Color = _current_colors.TEXT_MUTED
	var styles := [
		["TabContainer", "tab_unselected", color],
		["TabContainer", "tab_selected", color],
		["TabContainer", "tab_focus", color],
		["TabContainer", "tab_hovered", color.lightened(0.08)],
		["TabContainer", "tab_disabled", _with_alpha(color.darkened(0.18), 0.5)],
		["PopupMenu", "panel", color],
		["PopupPanel", "panel", color],
		["TooltipPanel", "panel", color],
		["Window", "embedded_border", color],
		["Window", "embedded_unfocused_border", color.darkened(0.18)],
	]
	var changed := false
	for entry: Array in styles:
		var style := theme.get_stylebox(entry[1], entry[0]) as StyleBoxFlat
		if style == null or style.bg_color.is_equal_approx(entry[2]):
			continue
		style.bg_color = entry[2]
		changed = true
	# FileDialog uses these roles for its built-in file/folder icons.
	for entry: Array in [
		["folder_icon_color", _current_colors.BTN_NAV],
		["file_icon_color", primary_text],
		["file_disabled_color", _with_alpha(secondary_text, 0.5)],
	]:
		changed = _set_theme_color(theme, "FileDialog", entry[0], entry[1]) or changed
	for type_name in ["TabContainer", "TabBar"]:
		changed = _set_theme_color(theme, type_name, "font_selected_color",
			primary_text.lightened(0.12)) or changed
		changed = _set_theme_color(theme, type_name, "font_hovered_color",
			primary_text.lightened(0.05)) or changed
		changed = _set_theme_color(theme, type_name, "font_unselected_color",
			primary_text.darkened(0.24)) or changed
		changed = _set_theme_color(theme, type_name, "font_disabled_color",
			_with_alpha(secondary_text, 0.5)) or changed
	return changed


func _set_theme_color(theme: Theme, type_name: String, color_name: String,
		color: Color) -> bool:
	if theme.has_color(color_name, type_name) \
			and theme.get_color(color_name, type_name).is_equal_approx(color):
		return false
	theme.set_color(color_name, type_name, color)
	return true


func _process_live_updates() -> void:
	var remaining := LIVE_NODES_PER_FRAME
	while remaining > 0 and not _pending_objects.is_empty():
		remaining -= 1
		var object: Variant = _pending_objects.pop_back()
		if not is_instance_valid(object):
			continue
		if object is Node:
			_update_node(object, _pending_colors, _pending_metrics)
			for child: Node in object.get_children():
				_pending_objects.push_back(child)
			if object is Tree:
				var root_item := (object as Tree).get_root()
				if root_item != null:
					_pending_objects.push_back(root_item)
		elif object is TreeItem:
			_update_tree_item(object, _pending_colors)
			var child_item := (object as TreeItem).get_first_child()
			while child_item != null:
				_pending_objects.push_back(child_item)
				child_item = child_item.get_next()
	if _pending_objects.is_empty():
		_pending_colors.clear()
		_pending_metrics.clear()


func _update_tree_item(item: TreeItem, old_colors: Dictionary) -> void:
	if old_colors.is_empty():
		return
	var tree := item.get_tree()
	if tree == null:
		return
	for column in range(tree.columns):
		var current := item.get_custom_color(column)
		var replacement := _replace_color(current, old_colors)
		if not current.is_equal_approx(replacement):
			item.set_custom_color(column, replacement)


func _update_node(node: Node, old_colors: Dictionary, old_metrics: Dictionary) -> void:
	if node is Control:
		# AcceptDialog's private Panel is not represented by a Theme type, so keep
		# its local override attached to the live chrome style explicitly.
		if node is Panel and node.get_parent() is Window:
			var dialog_style := StyleBoxFlat.new()
			dialog_style.bg_color = AppTheme.BG_CHROME
			node.add_theme_stylebox_override("panel", dialog_style)
		for property: Dictionary in node.get_property_list():
			var property_name := str(property.name)
			if not old_colors.is_empty() and property_name.begins_with("theme_override_colors/"):
				var value: Variant = node.get(property_name)
				if value is Color:
					var replacement := _replace_color(value, old_colors)
					if not value.is_equal_approx(replacement):
						node.set(property_name, replacement)
			elif not old_metrics.is_empty() and (property_name.begins_with("theme_override_constants/") or property_name.begins_with("theme_override_font_sizes/")):
				var value: Variant = node.get(property_name)
				if value is int:
					var replacement := _replace_metric(value, old_metrics)
					if value != replacement:
						node.set(property_name, replacement)
			elif not old_colors.is_empty() and property_name.begins_with("theme_override_styles/"):
				var value: Variant = node.get(property_name)
				if value is Resource and value != AppTheme.make_chrome_background_style():
					_update_resource(value, old_colors)


func _update_resource(resource: Resource, old_colors: Dictionary) -> bool:
	if resource == null:
		return false
	var changed := false
	resource.set_block_signals(true)
	for property: Dictionary in resource.get_property_list():
		if not (int(property.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var value: Variant = resource.get(property.name)
		if value is Color:
			var replacement := _replace_color(value, old_colors)
			if not value.is_equal_approx(replacement):
				resource.set(property.name, replacement)
				changed = true
		elif value is Resource:
			changed = _update_resource(value, old_colors) or changed
	resource.set_block_signals(false)
	if changed:
		resource.emit_changed()
	return changed


func _replace_color(value: Color, old_values: Dictionary) -> Color:
	for key: String in old_values:
		if value.is_equal_approx(old_values[key]):
			return _current_colors[key]
	return value


func _replace_metric(value: int, old_values: Dictionary) -> int:
	for key: String in old_values:
		if value == old_values[key]:
			return _current_metrics[key]
	return value


func _changed_values(previous: Dictionary, next: Dictionary) -> Dictionary:
	var changed := {}
	for key: String in previous:
		if previous[key] != next[key]:
			changed[key] = previous[key]
	return changed


func _load_json_object(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Could not read %s (error %d)." % [path, FileAccess.get_open_error()]}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK:
		return {"ok": false, "error": "Invalid JSON in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()]}
	if not json.data is Dictionary:
		return {"ok": false, "error": "%s must contain a JSON object." % path}
	return {"ok": true, "value": json.data}


func _write_default_file(path: String, value: Dictionary) -> void:
	if FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("Could not create %s (error %d)." % [path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(value, "  ") + "\n")


func _file_hash(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text().hash() if file != null else 0


func _serialize_colors(values: Dictionary) -> Dictionary:
	var result := {}
	for key: String in values:
		result[key] = "#" + (values[key] as Color).to_html(true)
	return result


func _fail(message: String) -> Error:
	last_error = message
	push_error(message)
	theme_reload_failed.emit(message)
	return ERR_PARSE_ERROR


func _read_app_colors() -> Dictionary:
	return {
		"BG_PRIMARY": AppTheme.BG_PRIMARY, "BG_PANEL": AppTheme.BG_PANEL, "BG_FIELD": AppTheme.BG_FIELD,
		"BG_HOVER": AppTheme.BG_HOVER, "BG_TOAST": AppTheme.BG_TOAST, "BG_SELECTION": AppTheme.BG_SELECTION,
		"BG_CHROME": AppTheme.BG_CHROME,
		"ACCENT": AppTheme.ACCENT, "ACCENT_DIM": AppTheme.ACCENT_DIM, "TEXT_PRIMARY": AppTheme.TEXT_PRIMARY,
		"TEXT_HEADING": AppTheme.TEXT_HEADING, "TEXT_DIM": AppTheme.TEXT_DIM, "TEXT_MUTED": AppTheme.TEXT_MUTED,
		"TEXT_VERY_MUTED": AppTheme.TEXT_VERY_MUTED, "TEXT_SUBTLE": AppTheme.TEXT_SUBTLE,
		"TEXT_SECTION": AppTheme.TEXT_SECTION, "TEXT_INFO_YELLOW": AppTheme.TEXT_INFO_YELLOW,
		"TEXT_TOAST": AppTheme.TEXT_TOAST, "BTN_NAV": AppTheme.BTN_NAV, "BTN_NAV_HOVER": AppTheme.BTN_NAV_HOVER,
		"BTN_DELETE": AppTheme.BTN_DELETE, "BTN_DELETE_HOVER": AppTheme.BTN_DELETE_HOVER,
		"BTN_ADD": AppTheme.BTN_ADD, "BTN_ADD_HOVER": AppTheme.BTN_ADD_HOVER, "BTN_MUTED": AppTheme.BTN_MUTED,
		"BTN_MUTED_HOVER": AppTheme.BTN_MUTED_HOVER, "BTN_PACK": AppTheme.BTN_PACK,
		"BTN_LAUNCH": AppTheme.BTN_LAUNCH, "BTN_NEW_MOD": AppTheme.BTN_NEW_MOD, "BTN_REMOVE": AppTheme.BTN_REMOVE,
		"BTN_SAVE": AppTheme.BTN_SAVE, "REF_COLOR": AppTheme.REF_COLOR, "REF_LINE_COLOR": AppTheme.REF_LINE_COLOR,
		"STATUS_SUCCESS": AppTheme.STATUS_SUCCESS, "STATUS_ERROR": AppTheme.STATUS_ERROR,
		"STATUS_WARNING": AppTheme.STATUS_WARNING, "STATUS_ACTIVE": AppTheme.STATUS_ACTIVE,
		"STATUS_IDLE": AppTheme.STATUS_IDLE, "STATUS_WORKING": AppTheme.STATUS_WORKING,
		"TREE_FONT_COLOR": AppTheme.TREE_FONT_COLOR, "TREE_SELECTED": AppTheme.TREE_SELECTED,
		"MOD_ENABLED": AppTheme.MOD_ENABLED, "MOD_DISABLED": AppTheme.MOD_DISABLED,
		"MOD_PLACEHOLDER": AppTheme.MOD_PLACEHOLDER, "MOD_DIR": AppTheme.MOD_DIR,
		"MOD_FILE_UASSET": AppTheme.MOD_FILE_UASSET, "MOD_FILE_OTHER": AppTheme.MOD_FILE_OTHER,
	}


func _read_app_metrics() -> Dictionary:
	return {
		"FONT_HEADER": AppTheme.FONT_HEADER, "FONT_TOAST": AppTheme.FONT_TOAST, "FONT_REF": AppTheme.FONT_REF,
		"FONT_DEFAULT": AppTheme.FONT_DEFAULT, "FONT_STATUS": AppTheme.FONT_STATUS,
		"FONT_SECTION": AppTheme.FONT_SECTION, "FONT_SMALL": AppTheme.FONT_SMALL,
		"FONT_BADGE": AppTheme.FONT_BADGE, "FONT_STATUS_BAR": AppTheme.FONT_STATUS_BAR,
		"FONT_TINY": AppTheme.FONT_TINY, "SPACING_ROW": AppTheme.SPACING_ROW,
		"SPACING_FIELD": AppTheme.SPACING_FIELD, "SPACING_TAGS": AppTheme.SPACING_TAGS,
		"SPACING_TIGHT": AppTheme.SPACING_TIGHT, "MARGIN_TOOLBAR_H": AppTheme.MARGIN_TOOLBAR_H,
		"MARGIN_TOOLBAR_TOP": AppTheme.MARGIN_TOOLBAR_TOP, "MARGIN_TOOLBAR_BOTTOM": AppTheme.MARGIN_TOOLBAR_BOTTOM,
		"MARGIN_STATUS_H": AppTheme.MARGIN_STATUS_H, "MARGIN_STATUS_V": AppTheme.MARGIN_STATUS_V,
		"MARGIN_LOG_H": AppTheme.MARGIN_LOG_H, "MARGIN_LOG_TOP": AppTheme.MARGIN_LOG_TOP,
		"MARGIN_LOG_BOTTOM": AppTheme.MARGIN_LOG_BOTTOM, "MARGIN_SETTINGS_H": AppTheme.MARGIN_SETTINGS_H,
		"MARGIN_SETTINGS_V": AppTheme.MARGIN_SETTINGS_V, "MARGIN_SELECTABLE_H_L": AppTheme.MARGIN_SELECTABLE_H_L,
		"MARGIN_SELECTABLE_H_R": AppTheme.MARGIN_SELECTABLE_H_R, "MARGIN_SELECTABLE_V": AppTheme.MARGIN_SELECTABLE_V,
		"CORNER_RADIUS": AppTheme.CORNER_RADIUS, "CORNER_TOAST": AppTheme.CORNER_TOAST,
	}


func _set_app_color(key: String, value: Color) -> void:
	match key:
		"BG_PRIMARY": AppTheme.BG_PRIMARY = value
		"BG_PANEL": AppTheme.BG_PANEL = value
		"BG_FIELD": AppTheme.BG_FIELD = value
		"BG_HOVER": AppTheme.BG_HOVER = value
		"BG_TOAST": AppTheme.BG_TOAST = value
		"BG_SELECTION": AppTheme.BG_SELECTION = value
		"BG_CHROME":
			AppTheme.BG_CHROME = value
			AppTheme.refresh_dynamic_styles()
		"ACCENT": AppTheme.ACCENT = value
		"ACCENT_DIM": AppTheme.ACCENT_DIM = value
		"TEXT_PRIMARY": AppTheme.TEXT_PRIMARY = value
		"TEXT_HEADING": AppTheme.TEXT_HEADING = value
		"TEXT_DIM": AppTheme.TEXT_DIM = value
		"TEXT_MUTED": AppTheme.TEXT_MUTED = value
		"TEXT_VERY_MUTED": AppTheme.TEXT_VERY_MUTED = value
		"TEXT_SUBTLE": AppTheme.TEXT_SUBTLE = value
		"TEXT_SECTION": AppTheme.TEXT_SECTION = value
		"TEXT_INFO_YELLOW": AppTheme.TEXT_INFO_YELLOW = value
		"TEXT_TOAST": AppTheme.TEXT_TOAST = value
		"BTN_NAV": AppTheme.BTN_NAV = value
		"BTN_NAV_HOVER": AppTheme.BTN_NAV_HOVER = value
		"BTN_DELETE": AppTheme.BTN_DELETE = value
		"BTN_DELETE_HOVER": AppTheme.BTN_DELETE_HOVER = value
		"BTN_ADD": AppTheme.BTN_ADD = value
		"BTN_ADD_HOVER": AppTheme.BTN_ADD_HOVER = value
		"BTN_MUTED": AppTheme.BTN_MUTED = value
		"BTN_MUTED_HOVER": AppTheme.BTN_MUTED_HOVER = value
		"BTN_PACK": AppTheme.BTN_PACK = value
		"BTN_LAUNCH": AppTheme.BTN_LAUNCH = value
		"BTN_NEW_MOD": AppTheme.BTN_NEW_MOD = value
		"BTN_REMOVE": AppTheme.BTN_REMOVE = value
		"BTN_SAVE": AppTheme.BTN_SAVE = value
		"REF_COLOR": AppTheme.REF_COLOR = value
		"REF_LINE_COLOR": AppTheme.REF_LINE_COLOR = value
		"STATUS_SUCCESS": AppTheme.STATUS_SUCCESS = value
		"STATUS_ERROR": AppTheme.STATUS_ERROR = value
		"STATUS_WARNING": AppTheme.STATUS_WARNING = value
		"STATUS_ACTIVE": AppTheme.STATUS_ACTIVE = value
		"STATUS_IDLE": AppTheme.STATUS_IDLE = value
		"STATUS_WORKING": AppTheme.STATUS_WORKING = value
		"TREE_FONT_COLOR": AppTheme.TREE_FONT_COLOR = value
		"TREE_SELECTED": AppTheme.TREE_SELECTED = value
		"MOD_ENABLED": AppTheme.MOD_ENABLED = value
		"MOD_DISABLED": AppTheme.MOD_DISABLED = value
		"MOD_PLACEHOLDER": AppTheme.MOD_PLACEHOLDER = value
		"MOD_DIR": AppTheme.MOD_DIR = value
		"MOD_FILE_UASSET": AppTheme.MOD_FILE_UASSET = value
		"MOD_FILE_OTHER": AppTheme.MOD_FILE_OTHER = value


func _set_app_metric(key: String, value: int) -> void:
	match key:
		"FONT_HEADER": AppTheme.FONT_HEADER = value
		"FONT_TOAST": AppTheme.FONT_TOAST = value
		"FONT_REF": AppTheme.FONT_REF = value
		"FONT_DEFAULT": AppTheme.FONT_DEFAULT = value
		"FONT_STATUS": AppTheme.FONT_STATUS = value
		"FONT_SECTION": AppTheme.FONT_SECTION = value
		"FONT_SMALL": AppTheme.FONT_SMALL = value
		"FONT_BADGE": AppTheme.FONT_BADGE = value
		"FONT_STATUS_BAR": AppTheme.FONT_STATUS_BAR = value
		"FONT_TINY": AppTheme.FONT_TINY = value
		"SPACING_ROW": AppTheme.SPACING_ROW = value
		"SPACING_FIELD": AppTheme.SPACING_FIELD = value
		"SPACING_TAGS": AppTheme.SPACING_TAGS = value
		"SPACING_TIGHT": AppTheme.SPACING_TIGHT = value
		"MARGIN_TOOLBAR_H": AppTheme.MARGIN_TOOLBAR_H = value
		"MARGIN_TOOLBAR_TOP": AppTheme.MARGIN_TOOLBAR_TOP = value
		"MARGIN_TOOLBAR_BOTTOM": AppTheme.MARGIN_TOOLBAR_BOTTOM = value
		"MARGIN_STATUS_H": AppTheme.MARGIN_STATUS_H = value
		"MARGIN_STATUS_V": AppTheme.MARGIN_STATUS_V = value
		"MARGIN_LOG_H": AppTheme.MARGIN_LOG_H = value
		"MARGIN_LOG_TOP": AppTheme.MARGIN_LOG_TOP = value
		"MARGIN_LOG_BOTTOM": AppTheme.MARGIN_LOG_BOTTOM = value
		"MARGIN_SETTINGS_H": AppTheme.MARGIN_SETTINGS_H = value
		"MARGIN_SETTINGS_V": AppTheme.MARGIN_SETTINGS_V = value
		"MARGIN_SELECTABLE_H_L": AppTheme.MARGIN_SELECTABLE_H_L = value
		"MARGIN_SELECTABLE_H_R": AppTheme.MARGIN_SELECTABLE_H_R = value
		"MARGIN_SELECTABLE_V": AppTheme.MARGIN_SELECTABLE_V = value
		"CORNER_RADIUS": AppTheme.CORNER_RADIUS = value
		"CORNER_TOAST": AppTheme.CORNER_TOAST = value
