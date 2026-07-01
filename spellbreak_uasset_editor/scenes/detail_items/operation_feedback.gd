class_name OperationFeedback extends VBoxContainer

## Small reusable operation feedback block for asset detail actions.
## It keeps an inline status, copyable step log, and an optional retry action
## without each detail view duplicating the same controls.

signal dismiss_requested

const LOG_HEIGHT_COMPACT := 84.0
const LOG_HEIGHT_EXPANDED := 240.0
const SUCCESS_STATUS_LIMIT := 140

var _status_label: Label
var _log_edit: TextEdit
var _retry_btn: Button
var _copy_btn: Button
var _expand_btn: Button
var _close_btn: Button
var _dismiss_timer: Timer
var _retry_callback: Callable
var _dismissible := false
var _expanded := false
var _auto_dismiss_seconds := 0.0
var _lines := PackedStringArray()


func setup(retry_callback: Callable = Callable(), dismissible: bool = false) -> OperationFeedback:
	_retry_callback = retry_callback
	_dismissible = dismissible
	_build_ui()
	set_retry_enabled(false)
	return self


func clear_log() -> void:
	_lines.clear()
	_sync_log()
	if is_instance_valid(_copy_btn):
		_copy_btn.disabled = true


func set_retry_callback(callback: Callable) -> void:
	_retry_callback = callback
	set_retry_enabled(_retry_btn != null and not _retry_btn.disabled)


func set_retry_enabled(enabled: bool) -> void:
	if not is_instance_valid(_retry_btn):
		return
	_retry_btn.disabled = not enabled or not _retry_callback.is_valid()


func set_dismissible(enabled: bool) -> void:
	_dismissible = enabled
	if is_instance_valid(_close_btn):
		_close_btn.visible = enabled


func set_auto_dismiss_seconds(seconds: float) -> void:
	_auto_dismiss_seconds = maxf(seconds, 0.0)


func set_expanded(expanded: bool) -> void:
	_expanded = expanded
	if is_instance_valid(_log_edit):
		_log_edit.custom_minimum_size.y = LOG_HEIGHT_EXPANDED if expanded else LOG_HEIGHT_COMPACT
	if is_instance_valid(_expand_btn):
		_expand_btn.text = "Collapse" if expanded else "Expand"
		_expand_btn.tooltip_text = "Show less of the operation log" if expanded \
				else "Show more of the operation log"
	if expanded:
		_stop_dismiss_timer()


func set_status(text: String, kind: int = AppTheme.StatusKind.IDLE) -> void:
	AppTheme.set_status_label(_status_label, text, kind)


func set_busy(text: String) -> void:
	_stop_dismiss_timer()
	set_status(text, AppTheme.StatusKind.WORKING)
	set_retry_enabled(false)


func set_result(success: bool, message: String) -> void:
	set_status(_status_summary(message) if success else message,
			AppTheme.StatusKind.SUCCESS if success else AppTheme.StatusKind.ERROR)
	set_retry_enabled(not success)
	if success:
		_start_dismiss_timer()
	else:
		_stop_dismiss_timer()


func add_line(text: String) -> void:
	_lines.append(text)
	_sync_log()
	if is_instance_valid(_copy_btn):
		_copy_btn.disabled = _lines.is_empty()


func add_path(label: String, path: String) -> void:
	if path.is_empty():
		return
	add_line("%s: %s" % [label, path])


func log_text() -> String:
	return "\n".join(_lines)


func _build_ui() -> void:
	add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_status_label = AppTheme.make_status_label("", AppTheme.StatusKind.IDLE,
			AppTheme.FONT_STATUS)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_status_label)

	_retry_btn = Button.new()
	_retry_btn.text = "Retry"
	_retry_btn.tooltip_text = "Run the last failed operation again"
	_retry_btn.pressed.connect(_on_retry_pressed)
	header.add_child(_retry_btn)

	_copy_btn = Button.new()
	_copy_btn.text = "Copy Log"
	_copy_btn.tooltip_text = "Copy the operation log to the clipboard"
	_copy_btn.disabled = true
	_copy_btn.pressed.connect(_on_copy_pressed)
	header.add_child(_copy_btn)

	_expand_btn = Button.new()
	_expand_btn.text = "Expand"
	_expand_btn.tooltip_text = "Show more of the operation log"
	_expand_btn.pressed.connect(func() -> void: set_expanded(not _expanded))
	header.add_child(_expand_btn)

	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.tooltip_text = "Hide this operation log"
	_close_btn.visible = _dismissible
	_close_btn.pressed.connect(_on_close_pressed)
	header.add_child(_close_btn)

	add_child(header)

	_log_edit = TextEdit.new()
	_log_edit.editable = false
	_log_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_log_edit.scroll_fit_content_height = false
	_log_edit.custom_minimum_size = Vector2(0, LOG_HEIGHT_COMPACT)
	_log_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_log_edit(_log_edit)
	add_child(_log_edit)

	_dismiss_timer = Timer.new()
	_dismiss_timer.one_shot = true
	_dismiss_timer.timeout.connect(_on_dismiss_timeout)
	add_child(_dismiss_timer)


func _sync_log() -> void:
	if not is_instance_valid(_log_edit):
		return
	_log_edit.text = log_text()


func _on_retry_pressed() -> void:
	if _retry_callback.is_valid():
		_retry_callback.call()


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(log_text())


func _on_close_pressed() -> void:
	_stop_dismiss_timer()
	dismiss_requested.emit()


func _on_dismiss_timeout() -> void:
	if not _expanded:
		dismiss_requested.emit()


func _start_dismiss_timer() -> void:
	if _auto_dismiss_seconds <= 0.0 or _expanded or not is_instance_valid(_dismiss_timer):
		return
	_dismiss_timer.start(_auto_dismiss_seconds)


func _stop_dismiss_timer() -> void:
	if is_instance_valid(_dismiss_timer):
		_dismiss_timer.stop()


func _status_summary(message: String) -> String:
	var summary := message
	for marker in [". Backup:", ". Backups:"]:
		var marker_pos := summary.find(marker)
		if marker_pos >= 0:
			summary = summary.substr(0, marker_pos)
			break
	if summary.length() > SUCCESS_STATUS_LIMIT:
		summary = summary.substr(0, SUCCESS_STATUS_LIMIT - 1) + "..."
	return summary


func _style_log_edit(edit: TextEdit) -> void:
	edit.add_theme_color_override("font_color", AppTheme.TEXT_PRIMARY)
	edit.add_theme_color_override("font_readonly_color", AppTheme.TEXT_PRIMARY)
	edit.add_theme_color_override("font_placeholder_color", AppTheme.TEXT_MUTED)
	edit.add_theme_color_override("selection_color", AppTheme.BG_SELECTION)
	edit.add_theme_font_size_override("font_size", AppTheme.FONT_SMALL)

	var normal := StyleBoxFlat.new()
	normal.bg_color = AppTheme.BG_FIELD
	normal.border_color = AppTheme.BG_HOVER
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(AppTheme.CORNER_RADIUS)
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("read_only", normal)
