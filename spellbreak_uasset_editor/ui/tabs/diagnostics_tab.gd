class_name DiagnosticsTab extends VBoxContainer

signal close_requested
signal status_changed(text: String, is_error: bool)

const SMOOTH_SCROLL_CONTAINER := preload("res://ui/components/smooth_scroll_container.gd")

enum CheckStatus {
	PASS,
	WARN,
	FAIL,
	INFO,
}

var _cfg: ModConfigManager
var _content: VBoxContainer
var _header: VBoxContainer
var _show_details := false
var _section_expanded: Dictionary = {}
var _summary_label: Label
var _checks: Array[Dictionary] = []


func setup(cfg: ModConfigManager) -> DiagnosticsTab:
	_cfg = cfg
	return self


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()


func refresh() -> void:
	if is_inside_tree():
		_build_ui()


func _build_ui() -> void:
	for child in get_children():
		child.free()

	add_theme_constant_override("separation", 0)

	var scroll := SMOOTH_SCROLL_CONTAINER.new() as ScrollContainer
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var outer := MarginContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("margin_left", AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_right", AppTheme.MARGIN_SETTINGS_H)
	outer.add_theme_constant_override("margin_top", AppTheme.MARGIN_SETTINGS_V)
	outer.add_theme_constant_override("margin_bottom", AppTheme.MARGIN_SETTINGS_V)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	outer.add_child(_content)
	scroll.add_child(outer)
	var header_margin := MarginContainer.new()
	header_margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_SETTINGS_H)
	header_margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_SETTINGS_H)
	header_margin.add_theme_constant_override("margin_top", AppTheme.MARGIN_SETTINGS_V)
	header_margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_ROW)
	_header = VBoxContainer.new()
	_header.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
	header_margin.add_child(_header)
	add_child(header_margin)
	add_child(HSeparator.new())
	add_child(scroll)

	_build_header()
	_checks = _run_checks()
	_build_summary()
	_build_sections()

	add_child(HSeparator.new())
	_build_footer()


func _build_header() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var title := Label.new()
	title.text = "Diagnostics"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_header(title)
	row.add_child(title)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(_refresh_from_button, CONNECT_DEFERRED)
	row.add_child(refresh_btn)

	var copy_btn := Button.new()
	copy_btn.text = "Copy report"
	copy_btn.tooltip_text = "Copy all checks and full paths for troubleshooting"
	copy_btn.pressed.connect(_copy_summary)
	row.add_child(copy_btn)

	_header.add_child(row)

	var details := CheckButton.new()
	details.text = "Show technical details"
	details.button_pressed = _show_details
	details.toggled.connect(func(enabled: bool) -> void:
		_show_details = enabled
		for node in _content.find_children("CheckDetail", "Label", true, false):
			node.visible = enabled)
	_header.add_child(details)

	var hint := Label.new()
	hint.text = "Checks tool availability and your configured folders. Copy report includes full paths."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	AppTheme.style_muted(hint)
	_header.add_child(hint)


func _build_summary() -> void:
	var counts := _status_counts(_checks)
	var failed := int(counts.get(CheckStatus.FAIL, 0))
	var warned := int(counts.get(CheckStatus.WARN, 0))
	var issues := failed + warned
	var summary := "All availability checks passed"
	if issues > 0:
		summary = "1 issue needs attention" if issues == 1 else "%d issues need attention" % issues

	_summary_label = AppTheme.make_status_label(
		summary,
		AppTheme.StatusKind.ERROR if failed > 0 else (
			AppTheme.StatusKind.WARNING if warned > 0 else AppTheme.StatusKind.SUCCESS),
		AppTheme.FONT_STATUS)
	_header.add_child(_summary_label)


func _build_sections() -> void:
	for section in [
		"Configuration",
		"Filesystem",
		"Tools",
		"Spellbreak Profile",
		"Sources",
	]:
		var section_checks := _checks.filter(func(check: Dictionary) -> bool:
			return str(check.get("section", "")) == section)
		if section_checks.is_empty():
			continue
		var issues := section_checks.filter(func(check: Dictionary) -> bool:
			return int(check.status) in [CheckStatus.FAIL, CheckStatus.WARN]).size()
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", AppTheme.SPACING_ROW)
		body.visible = issues > 0 or bool(_section_expanded.get(section,
			section not in ["Configuration", "Spellbreak Profile"]))
		var toggle := Button.new()
		toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
		toggle.toggle_mode = true
		toggle.button_pressed = body.visible
		var caption := "%s · %d checks" % [section, section_checks.size()]
		if issues > 0:
			caption += " · %d need attention" % issues
		toggle.text = ("▾ " if body.visible else "▸ ") + caption
		toggle.toggled.connect(func(expanded: bool) -> void:
			body.visible = expanded
			_section_expanded[section] = expanded
			toggle.text = ("▾ " if expanded else "▸ ") + caption)
		_content.add_child(toggle)
		_content.add_child(body)
		for check in section_checks:
			_add_check_row(check, body)



func _build_footer() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", AppTheme.MARGIN_SETTINGS_H)
	margin.add_theme_constant_override("margin_right", AppTheme.MARGIN_SETTINGS_H)
	margin.add_theme_constant_override("margin_top", AppTheme.SPACING_ROW)
	margin.add_theme_constant_override("margin_bottom", AppTheme.SPACING_ROW)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	row.add_child(close_btn)

	margin.add_child(row)
	add_child(margin)


func _run_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	checks.append_array(_configuration_checks())
	checks.append_array(_filesystem_checks())
	checks.append_array(_tool_checks())
	checks.append_array(_profile_checks())
	checks.append_array(_source_checks())
	return checks


func _configuration_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	if _cfg == null:
		checks.append(_check("Configuration", "Config manager", CheckStatus.FAIL,
			"Configuration service is unavailable"))
		return checks

	checks.append(_path_check("Configuration", "Config folder", _cfg.get_config_dir(), true, true))
	checks.append(_file_check("Configuration", "Config file", _cfg.get_config_path(), false))

	var launch_cmd := _cfg.launch_cmd.strip_edges()
	if launch_cmd.is_empty():
		checks.append(_check("Configuration", "Launch command", CheckStatus.INFO,
			"Optional · Launch button is disabled"))
	else:
		checks.append(_launch_command_check(launch_cmd))

	return checks


func _filesystem_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	var profile := _cfg.get_game_profile() if _cfg != null else SpellbreakProfile.shared()
	var game_dir := _cfg.game_dir if _cfg != null else ""
	var mods_dir := _cfg.mods_dir if _cfg != null else ""

	checks.append(_path_check("Filesystem", "Game folder", game_dir, true, false))
	if not game_dir.strip_edges().is_empty():
		var paks_dir := game_dir.path_join(profile.paks_subpath)
		checks.append(_path_check("Filesystem", "Paks folder", paks_dir, true, true))
		if not FileUtils.is_path_within(paks_dir, game_dir):
			checks.append(_check("Filesystem", "Paks path safety", CheckStatus.FAIL,
				"Paks path escapes the configured game folder", paks_dir))
		else:
			checks.append(_check("Filesystem", "Paks path safety", CheckStatus.PASS,
				"Paks path stays inside the configured game folder", paks_dir))

	checks.append(_path_check("Filesystem", "Mods folder", mods_dir, true, true))
	checks.append(_path_check("Filesystem", "User data folder", OS.get_user_data_dir(), true, true))
	checks.append(_path_check("Filesystem", "Temp folder", OS.get_temp_dir(), true, true))
	checks.append(_temp_creation_check())

	return checks


func _tool_checks() -> Array[Dictionary]:
	var python := ProcessUtils.find_python()
	var dotnet := ProcessUtils.find_dotnet()
	var dds := _cfg.get_dds_tools_main_py() if _cfg != null else ""
	var native := dds.get_base_dir().path_join("directx/texconv.dll" if OS.get_name() == "Windows" else "directx/libtexconv.so")
	var umodel := _cfg.get_umodel_path() if _cfg != null else ""
	return [
		_capability_check("Asset reading and writing", [dotnet, ToolchainRegistry.converter_dll()],
			false, not dotnet.replace("\\", "/").contains("/runtimes/")),
		_capability_check("Mod packing", [python, _cfg.get_u4pak_path() if _cfg != null else ""],
			_cfg != null and not _cfg.u4pak_dir.is_empty(), not python.contains("runtimes")),
		_capability_check("Texture preview and import", [python, dds, native],
			_cfg != null and not _cfg.ue4_dds_tools_dir.is_empty(), not python.contains("runtimes")),
		_capability_check("Mesh and animation preview", [umodel],
			_cfg != null and not _cfg.umodel_path.is_empty()),
	]


func _capability_check(label: String, paths: Array, custom: bool = false,
		system_runtime: bool = false) -> Dictionary:
	var details := PackedStringArray()
	var missing := false
	for path_value in paths:
		var path := str(path_value)
		details.append(path if not path.is_empty() else "Missing tool path")
		missing = missing or path.is_empty() or not FileAccess.file_exists(path)
	if missing:
		return _check("Tools", label, CheckStatus.FAIL,
			"Tool missing · check the custom path in Settings" if custom else
			"Tool missing · reinstall the complete Modkit build", "\n".join(details))
	var origin := "Custom override" if custom else ("Development runtime" if system_runtime else "Bundled")
	return _check("Tools", label, CheckStatus.PASS, "Available · " + origin, "\n".join(details))


func _profile_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	var profile := _cfg.get_game_profile() if _cfg != null else SpellbreakProfile.shared()
	checks.append(_check("Spellbreak Profile", "Profile", CheckStatus.PASS,
		profile.display_name, profile.profile_id))
	checks.append(_check("Spellbreak Profile", "UE version", CheckStatus.PASS,
		profile.ue_version, profile.umodel_game_flag))
	checks.append(_check("Spellbreak Profile", "DDS tools version", CheckStatus.PASS,
		profile.dds_tools_version))

	var content_root := profile.content_root.strip_edges()
	if FileUtils.is_safe_filename(content_root):
		checks.append(_check("Spellbreak Profile", "Content root", CheckStatus.PASS,
			content_root))
	else:
		checks.append(_check("Spellbreak Profile", "Content root", CheckStatus.FAIL,
			"Invalid content root: %s" % content_root))

	if profile.paks_subpath.begins_with(content_root + "/"):
		checks.append(_check("Spellbreak Profile", "Paks subpath", CheckStatus.PASS,
			profile.paks_subpath))
	else:
		checks.append(_check("Spellbreak Profile", "Paks subpath", CheckStatus.WARN,
			"Paks path does not start with content root", profile.paks_subpath))

	if FileUtils.is_safe_filename(profile.pak_output_name):
		checks.append(_check("Spellbreak Profile", "Pak output name", CheckStatus.PASS,
			profile.pak_output_name))
	else:
		checks.append(_check("Spellbreak Profile", "Pak output name", CheckStatus.FAIL,
			"Invalid pak output name: %s" % profile.pak_output_name))

	var data_parts: Array[String] = []
	data_parts.append("%d enum type(s)" % profile.enums.size())
	data_parts.append("%d tag(s)" % profile.tags.size())
	data_parts.append("%d constant(s)" % profile.constants.size())
	checks.append(_check("Spellbreak Profile", "Profile data", CheckStatus.PASS,
		", ".join(data_parts)))
	return checks


func _source_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	if _cfg == null or _cfg.sources.is_empty():
		checks.append(_check("Sources", "Reference sources", CheckStatus.INFO,
			"Optional · add sources in Settings for companion recovery and animation search"))
		return checks

	var content_root := _cfg.get_game_profile().content_root
	var index := 1
	for entry in _cfg.sources:
		if not entry is Dictionary:
			continue
		var source_name := str(entry.get("name", "")).strip_edges()
		var path := str(entry.get("path", "")).rstrip("/")
		var label := source_name if not source_name.is_empty() else "Source %d" % index
		if path.is_empty():
			checks.append(_check("Sources", label, CheckStatus.FAIL, "Source path is empty"))
		elif not DirAccess.dir_exists_absolute(path):
			checks.append(_check("Sources", label, CheckStatus.FAIL,
				"Source folder does not exist", path))
		elif not DirAccess.dir_exists_absolute(path.path_join(content_root)):
			checks.append(_check("Sources", label, CheckStatus.WARN,
				"Source folder exists but does not contain %s/" % content_root, path))
		else:
			checks.append(_check("Sources", label, CheckStatus.PASS,
				"Source folder is available", path))
		index += 1
	return checks


func _path_check(section: String, check_name: String, path: String, required: bool,
		writable: bool) -> Dictionary:
	path = path.strip_edges()
	if path.is_empty():
		return _check(section, check_name, CheckStatus.FAIL if required else CheckStatus.WARN,
			"Path is not configured")
	if not DirAccess.dir_exists_absolute(path):
		return _check(section, check_name, CheckStatus.FAIL if required else CheckStatus.WARN,
			"Folder does not exist", path)
	if writable:
		var write_error := _check_writable_dir(path)
		if write_error != OK:
			return _check(section, check_name, CheckStatus.FAIL,
				"Folder is not writable (error %d)" % write_error, path)
	return _check(section, check_name, CheckStatus.PASS, "Folder is available", path)


func _file_check(section: String, check_name: String, path: String, required: bool) -> Dictionary:
	path = path.strip_edges()
	if path.is_empty():
		return _check(section, check_name, CheckStatus.FAIL if required else CheckStatus.WARN,
			"Path is not configured")
	if not FileAccess.file_exists(path):
		return _check(section, check_name, CheckStatus.FAIL if required else CheckStatus.WARN,
			"File does not exist", path)
	return _check(section, check_name, CheckStatus.PASS, "File is available", path)


func _executable_check(section: String, check_name: String, executable: String,
		required: bool) -> Dictionary:
	if executable.strip_edges().is_empty():
		return _check(section, check_name, CheckStatus.FAIL if required else CheckStatus.WARN,
			"Executable was not found in PATH")
	return _check(section, check_name, CheckStatus.PASS, "Executable found", executable)


func _launch_command_check(command: String) -> Dictionary:
	var slash_pos := command.find("://")
	if slash_pos != -1 and not " " in command.left(slash_pos):
		return _check("Configuration", "Launch command", CheckStatus.PASS,
			"URL launch command", command)

	var parts := ProcessUtils.parse_command_line(command)
	if parts.is_empty():
		return _check("Configuration", "Launch command", CheckStatus.FAIL,
			"Launch command could not be parsed", command)

	var exe := str(parts[0])
	if exe.is_absolute_path():
		if FileAccess.file_exists(exe):
			return _check("Configuration", "Launch command", CheckStatus.PASS,
				"Executable exists", command)
		return _check("Configuration", "Launch command", CheckStatus.FAIL,
			"Executable does not exist", exe)

	var resolved := ProcessUtils.find_executable([exe])
	if resolved.is_empty():
		return _check("Configuration", "Launch command", CheckStatus.WARN,
			"Executable was not found in PATH", exe)
	return _check("Configuration", "Launch command", CheckStatus.PASS,
		"Executable found", resolved)


func _temp_creation_check() -> Dictionary:
	var result := FileUtils.make_temp_dir("sb_diag")
	if not bool(result.get("ok", false)):
		return _check("Filesystem", "Temp creation", CheckStatus.FAIL,
			str(result.get("error", "Could not create temp directory")))
	var path := str(result["path"])
	var write_error := FileUtils.write_bytes_atomic(path.path_join("probe.txt"),
		"ok".to_utf8_buffer())
	FileUtils.remove_dir_recursive(path)
	if write_error != OK:
		return _check("Filesystem", "Temp creation", CheckStatus.FAIL,
			"Could not write temp probe (error %d)" % write_error, path)
	return _check("Filesystem", "Temp creation", CheckStatus.PASS,
		"Temporary folder can be created and removed", OS.get_temp_dir())


func _check_writable_dir(path: String) -> Error:
	var probe := path.path_join(".sb_diag_%d_%d.tmp" % [
		OS.get_process_id(), Time.get_ticks_usec()])
	var error := FileUtils.write_bytes_atomic(probe, "ok".to_utf8_buffer())
	if error == OK and FileAccess.file_exists(probe):
		DirAccess.remove_absolute(probe)
	return error


func _refresh_from_button() -> void:
	_build_ui()
	status_changed.emit("Diagnostics refreshed", false)


func _check(section: String, check_name: String, status: int, message: String,
		detail: String = "") -> Dictionary:
	return {
		"section": section,
		"name": check_name,
		"status": status,
		"message": message,
		"detail": detail,
	}


func _add_check_row(check: Dictionary, parent: VBoxContainer) -> void:
	var row := VBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var badge := Label.new()
	badge.text = _status_text(int(check["status"]))
	badge.custom_minimum_size.x = 48
	badge.add_theme_font_size_override("font_size", AppTheme.FONT_BADGE)
	badge.add_theme_color_override("font_color", _status_color(int(check["status"])))
	top.add_child(badge)

	var name_label := Label.new()
	name_label.text = str(check["name"])
	name_label.custom_minimum_size.x = 220
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	AppTheme.style_dim(name_label)
	top.add_child(name_label)

	var message := Label.new()
	message.text = str(check["message"])
	message.autowrap_mode = TextServer.AUTOWRAP_WORD
	message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	message.add_theme_color_override("font_color", _status_color(int(check["status"])))
	top.add_child(message)

	row.add_child(top)

	var detail_text := str(check.get("detail", ""))
	if not detail_text.is_empty():
		var detail := Label.new()
		detail.text = detail_text
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.name = "CheckDetail"
		detail.visible = _show_details
		detail.tooltip_text = detail_text
		detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		detail.add_theme_font_size_override("font_size", AppTheme.FONT_TINY)
		AppTheme.style_muted(detail)
		row.add_child(detail)

	parent.add_child(row)


func _copy_summary() -> void:
	DisplayServer.clipboard_set(_summary_text())
	status_changed.emit("Diagnostics summary copied", false)


func _summary_text() -> String:
	var lines := PackedStringArray()
	lines.append("Spellbreak Modkit diagnostics")
	for check in _checks:
		var detail := str(check.get("detail", ""))
		var line := "[%s] %s: %s" % [
			_status_text(int(check["status"])),
			str(check["name"]),
			str(check["message"]),
		]
		if not detail.is_empty():
			line += " (%s)" % detail
		lines.append(line)
	return "\n".join(lines)


func _status_counts(checks: Array[Dictionary]) -> Dictionary:
	var counts := {}
	for check in checks:
		var status := int(check["status"])
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _status_text(status: int) -> String:
	match status:
		CheckStatus.PASS:
			return "PASS"
		CheckStatus.WARN:
			return "WARN"
		CheckStatus.FAIL:
			return "FAIL"
		_:
			return "INFO"


func _status_color(status: int) -> Color:
	match status:
		CheckStatus.PASS:
			return AppTheme.STATUS_SUCCESS
		CheckStatus.WARN:
			return AppTheme.STATUS_WARNING
		CheckStatus.FAIL:
			return AppTheme.STATUS_ERROR
		_:
			return AppTheme.TEXT_MUTED
