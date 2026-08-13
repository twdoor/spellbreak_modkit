class_name AssetDiffTab
extends VBoxContainer

const MAX_VISIBLE_DIFFS := 800
const VALUE_PREVIEW_LENGTH := 260
const SMOOTH_SCROLL_CONTAINER := preload("res://ui/components/smooth_scroll_container.gd")

var left_asset: UAssetFile
var right_asset: UAssetFile
var diffs: Array[Dictionary] = []
var tab_title := "Diff"

var _list: VBoxContainer


static func setup(left: UAssetFile, right: UAssetFile) -> AssetDiffTab:
	var tab := AssetDiffTab.new()
	tab.left_asset = left
	tab.right_asset = right
	tab.diffs = AssetDiff.compare_assets(left, right)
	tab.tab_title = "Diff"
	tab.name = "Diff_%s_%s" % [tab._asset_label(left), tab._asset_label(right)]
	tab._build()
	return tab


func get_tab_title() -> String:
	return tab_title


func _build() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)

	_build_header()
	add_child(HSeparator.new())
	_build_list()


func _build_header() -> void:
	var header := MarginContainer.new()
	header.add_theme_constant_override("margin_left", AppTheme.MARGIN_TOOLBAR_H)
	header.add_theme_constant_override("margin_right", AppTheme.MARGIN_TOOLBAR_H)
	header.add_theme_constant_override("margin_top", AppTheme.MARGIN_TOOLBAR_TOP)
	header.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_TOOLBAR_BOTTOM)
	add_child(header)

	var header_box := VBoxContainer.new()
	header_box.add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)
	header.add_child(header_box)

	var title := Label.new()
	title.text = "Diff"
	title.clip_text = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_header(title)
	header_box.add_child(title)

	var files := Label.new()
	files.text = "%s  ->  %s" % [_asset_label(left_asset), _asset_label(right_asset)]
	files.tooltip_text = _asset_path(left_asset) + "\n" + _asset_path(right_asset)
	files.clip_text = true
	files.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_muted(files)
	header_box.add_child(files)

	var counts := _summary_counts()
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	header_box.add_child(summary)
	summary.add_child(_make_summary_label("%d changed" % counts["changed"],
		AppTheme.TEXT_INFO_YELLOW))
	summary.add_child(_make_summary_label("%d added" % counts["added"],
		AppTheme.STATUS_SUCCESS))
	summary.add_child(_make_summary_label("%d removed" % counts["removed"],
		AppTheme.STATUS_ERROR))
	if diffs.size() > MAX_VISIBLE_DIFFS:
		summary.add_child(_make_summary_label("showing first %d" % MAX_VISIBLE_DIFFS,
			AppTheme.TEXT_MUTED))


func _build_list() -> void:
	var scroll := SMOOTH_SCROLL_CONTAINER.new() as ScrollContainer
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_TOOLBAR_H)
	margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_TOOLBAR_H)
	margin.add_theme_constant_override("margin_top", AppTheme.MARGIN_TOOLBAR_TOP)
	margin.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_TOOLBAR_TOP)
	scroll.add_child(margin)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	margin.add_child(_list)

	if diffs.is_empty():
		var empty := Label.new()
		empty.text = "No differences"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", AppTheme.STATUS_SUCCESS)
		_list.add_child(empty)
		return

	var visible_count = mini(diffs.size(), MAX_VISIBLE_DIFFS)
	for i in range(visible_count):
		_list.add_child(_make_diff_row(diffs[i]))


func _make_diff_row(diff: Dictionary) -> Control:
	var status := str(diff.get("status", AssetDiff.STATUS_CHANGED))
	var color := _status_color(status)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _make_row_style(color))

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_FIELD)
	panel.add_child(row)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	row.add_child(top)

	var status_label := Label.new()
	status_label.text = _status_label(status)
	status_label.custom_minimum_size.x = 72
	status_label.add_theme_font_size_override("font_size", AppTheme.FONT_BADGE)
	status_label.add_theme_color_override("font_color", color)
	top.add_child(status_label)

	var path_label := Label.new()
	path_label.text = str(diff.get("path", ""))
	path_label.tooltip_text = path_label.text
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	path_label.add_theme_color_override("font_color", AppTheme.TEXT_HEADING)
	top.add_child(path_label)

	match status:
		AssetDiff.STATUS_ADDED:
			row.add_child(_make_value_line("Added", diff.get("right"), color))
		AssetDiff.STATUS_REMOVED:
			row.add_child(_make_value_line("Removed", diff.get("left"), color))
		_:
			row.add_child(_make_value_line("Before", diff.get("left"), AppTheme.TEXT_MUTED))
			row.add_child(_make_value_line("After", diff.get("right"), color))

	return panel


func _make_value_line(label_text: String, value: Variant, color: Color) -> Control:
	var line := HBoxContainer.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 72
	label.add_theme_font_size_override("font_size", AppTheme.FONT_SMALL)
	label.add_theme_color_override("font_color", color)
	line.add_child(label)

	var value_label := Label.new()
	value_label.text = AssetDiff.format_value(value, VALUE_PREVIEW_LENGTH)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value_label.add_theme_font_size_override("font_size", AppTheme.FONT_SMALL)
	value_label.add_theme_color_override("font_color", AppTheme.TEXT_PRIMARY)
	line.add_child(value_label)

	return line


func _make_summary_label(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", AppTheme.FONT_SMALL)
	label.add_theme_color_override("font_color", color)
	return label


func _make_row_style(status_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = AppTheme.BG_PANEL.lerp(status_color, 0.04)
	style.border_color = Color(status_color.r, status_color.g, status_color.b, 0.72)
	style.border_width_left = 3
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _summary_counts() -> Dictionary:
	var counts := {
		"added": 0,
		"removed": 0,
		"changed": 0,
	}
	for diff in diffs:
		match str(diff.get("status", "")):
			AssetDiff.STATUS_ADDED:
				counts["added"] += 1
			AssetDiff.STATUS_REMOVED:
				counts["removed"] += 1
			AssetDiff.STATUS_CHANGED:
				counts["changed"] += 1
	return counts


func _status_label(status: String) -> String:
	match status:
		AssetDiff.STATUS_ADDED:
			return "Added"
		AssetDiff.STATUS_REMOVED:
			return "Removed"
		_:
			return "Changed"


func _status_color(status: String) -> Color:
	match status:
		AssetDiff.STATUS_ADDED:
			return AppTheme.STATUS_SUCCESS
		AssetDiff.STATUS_REMOVED:
			return AppTheme.STATUS_ERROR
		_:
			return AppTheme.TEXT_INFO_YELLOW


func _asset_label(asset: UAssetFile) -> String:
	if asset == null:
		return "(missing)"
	var path := _asset_path(asset)
	return path.get_file() if not path.is_empty() else "(unsaved)"


func _asset_path(asset: UAssetFile) -> String:
	if asset == null:
		return ""
	return asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
