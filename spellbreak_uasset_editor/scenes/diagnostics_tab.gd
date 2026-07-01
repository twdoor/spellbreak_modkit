class_name DiagnosticsTab extends VBoxContainer

signal close_requested
signal status_changed(text: String, is_error: bool)

enum CheckStatus {
	PASS,
	WARN,
	FAIL,
	INFO,
}

var _cfg: ModConfigManager
var _content: VBoxContainer
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

	var scroll := ScrollContainer.new()
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
	copy_btn.text = "Copy Summary"
	copy_btn.pressed.connect(_copy_summary)
	row.add_child(copy_btn)

	_content.add_child(row)

	var hint := Label.new()
	hint.text = "Checks paths, bundled tools, external executables, writable folders, and Spellbreak profile assumptions."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	AppTheme.style_muted(hint)
	_content.add_child(hint)


func _build_summary() -> void:
	var counts := _status_counts(_checks)
	var failed := int(counts.get(CheckStatus.FAIL, 0))
	var warned := int(counts.get(CheckStatus.WARN, 0))
	var passed := int(counts.get(CheckStatus.PASS, 0))

	_summary_label = AppTheme.make_status_label(
		"%d passed, %d warning(s), %d failed" % [passed, warned, failed],
		AppTheme.StatusKind.ERROR if failed > 0 else (
			AppTheme.StatusKind.WARNING if warned > 0 else AppTheme.StatusKind.SUCCESS),
		AppTheme.FONT_STATUS)
	_content.add_child(_summary_label)


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
		_add_section(section)
		for check in section_checks:
			_add_check_row(check)


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
	checks.append(_file_check("Configuration", "Config file",
		_cfg.get_config_dir().path_join(ModConfigManager.CONFIG_FILENAME), false))

	var launch_cmd := _cfg.launch_cmd.strip_edges()
	if launch_cmd.is_empty():
		checks.append(_check("Configuration", "Launch command", CheckStatus.WARN,
			"Launch button is disabled until a command is configured"))
	else:
		checks.append(_launch_command_check(launch_cmd))

	return checks


func _filesystem_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	var profile := _cfg.get_game_profile() if _cfg != null else GameProfile.new()
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
	var checks: Array[Dictionary] = []
	var python := ProcessUtils.find_python()
	checks.append(_executable_check("Tools", "Python", python, true))
	checks.append(_executable_check("Tools", "dotnet", ProcessUtils.find_executable(["dotnet"]), true))

	var converter := UAssetFile._get_converter_dll()
	checks.append(_file_check("Tools", "UAsset converter", converter, true))

	var u4pak_path := _cfg.get_u4pak_path() if _cfg != null else ""
	checks.append(_file_check("Tools", "u4pak.py", u4pak_path, true))

	var dds_main := _cfg.get_dds_tools_main_py() if _cfg != null else ""
	checks.append(_file_check("Tools", "UE4-DDS-Tools", dds_main, false))
	checks.append(_executable_check("Tools", "ImageMagick", _find_magick(), false))

	var umodel := _cfg.get_umodel_path() if _cfg != null else ""
	if umodel.strip_edges().is_empty():
		checks.append(_check("Tools", "umodel", CheckStatus.WARN,
			"3D mesh and animation preview are disabled until umodel is configured"))
	else:
		checks.append(_file_check("Tools", "umodel", umodel, true))

	return checks


func _profile_checks() -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	var profile := _cfg.get_game_profile() if _cfg != null else GameProfile.new()
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
		checks.append(_check("Sources", "Reference sources", CheckStatus.WARN,
			"No sources configured; texture companion recovery and auto animation search are limited"))
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


func _find_magick() -> String:
	var candidates: Array[String] = ["magick"]
	if OS.get_name() != "Windows":
		candidates.append("convert")
	return ProcessUtils.find_executable(candidates)


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


func _add_section(text: String) -> void:
	var label := Label.new()
	label.text = text
	AppTheme.style_section(label)
	_content.add_child(label)


func _add_check_row(check: Dictionary) -> void:
	var row := VBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", AppTheme.SPACING_TIGHT)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", AppTheme.SPACING_ROW)

	var badge := Label.new()
	badge.text = _status_text(int(check["status"]))
	badge.custom_minimum_size.x = 72
	badge.add_theme_font_size_override("font_size", AppTheme.FONT_BADGE)
	badge.add_theme_color_override("font_color", _status_color(int(check["status"])))
	top.add_child(badge)

	var name_label := Label.new()
	name_label.text = str(check["name"])
	name_label.custom_minimum_size.x = 190
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
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD
		detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		detail.add_theme_font_size_override("font_size", AppTheme.FONT_TINY)
		AppTheme.style_muted(detail)
		row.add_child(detail)

	_content.add_child(row)


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
