class_name FileAssociationService extends RefCounted

## Registers Spellbreak Modkit as a per-user handler for .uasset files.
## Windows protects the final default-app choice, so registration opens its
## Default Apps page. Linux can set the default directly through xdg-mime.

const MIME_TYPE := "application/x-unreal-uasset"
const DESKTOP_FILE_NAME := "spellbreak-modkit.desktop"
const PROG_ID := "SpellbreakModkit.uasset"
const REGISTERED_APP_NAME := "Spellbreak Modkit"
const UASSET_ICON_RESOURCE := "res://assets/uasset_icon.svg"
const UASSET_ICON_ICO := "res://assets/uasset_icon.ico"
const APP_ICON_RESOURCE := "res://assets/icon.svg"

var _config_directory := ""


func setup(config_directory: String) -> FileAssociationService:
	_config_directory = config_directory
	return self


func is_supported() -> bool:
	return OS.get_name() in ["Windows", "Linux"]


func is_available_in_current_build() -> bool:
	return is_supported() and not OS.has_feature("editor")


func action_label() -> String:
	if OS.get_name() == "Windows":
		return "Register and Choose Default…"
	return "Set as Default for .uasset"


func register() -> OperationResult:
	if not is_supported():
		return OperationResult.failed(
				"File association is currently supported on Windows and Linux.")
	if OS.has_feature("editor"):
		return OperationResult.failed(
				"File association can only target an exported Spellbreak Modkit build.")
	var executable_path := current_application_path()
	if executable_path.is_empty() or not FileAccess.file_exists(executable_path):
		return OperationResult.failed("Could not locate the running application.")
	if OS.get_name() == "Windows":
		return _register_windows(executable_path)
	return _register_linux(executable_path)


static func current_application_path() -> String:
	if OS.get_name() == "Linux":
		var appimage_path := OS.get_environment("APPIMAGE").strip_edges()
		if not appimage_path.is_empty() and FileAccess.file_exists(appimage_path):
			return appimage_path
	return OS.get_executable_path()


static func windows_registry_entries(executable_path: String,
		icon_path: String) -> Array[Dictionary]:
	var classes_root := "HKCU\\Software\\Classes"
	var prog_id_key := classes_root + "\\" + PROG_ID
	var capabilities_key := "HKCU\\Software\\SpellbreakModkit\\Capabilities"
	return [
		{"key": prog_id_key, "name": "", "data": "Unreal Engine Asset"},
		{"key": prog_id_key, "name": "FriendlyTypeName", "data": "Unreal Engine Asset"},
		{"key": prog_id_key + "\\DefaultIcon", "name": "",
			"data": "\"" + icon_path + "\",0"},
		{"key": prog_id_key + "\\shell\\open\\command", "name": "",
			"data": "\"" + executable_path + "\" \"%1\""},
		{"key": classes_root + "\\.uasset\\OpenWithProgids", "name": PROG_ID,
			"data": ""},
		{"key": capabilities_key, "name": "ApplicationName",
			"data": REGISTERED_APP_NAME},
		{"key": capabilities_key, "name": "ApplicationDescription",
			"data": "Edit Spellbreak Unreal Engine asset files."},
		{"key": capabilities_key + "\\FileAssociations", "name": ".uasset",
			"data": PROG_ID},
		{"key": "HKCU\\Software\\RegisteredApplications",
			"name": REGISTERED_APP_NAME,
			"data": "Software\\SpellbreakModkit\\Capabilities"},
	]


static func linux_desktop_entry(executable_path: String) -> String:
	return "\n".join(PackedStringArray([
		"[Desktop Entry]",
		"Type=Application",
		"Name=Spellbreak Modkit",
		"Comment=Edit Spellbreak Unreal Engine asset files",
		"Icon=spellbreak-modkit",
		"Exec=%s %%F" % _desktop_quote(executable_path),
		"Terminal=false",
		"Categories=Development;Utility;",
		"MimeType=%s;" % MIME_TYPE,
		"",
	]))


static func linux_mime_package() -> String:
	return "\n".join(PackedStringArray([
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
		"<mime-info xmlns=\"http://www.freedesktop.org/standards/shared-mime-info\">",
		"  <mime-type type=\"%s\">" % MIME_TYPE,
		"    <comment>Unreal Engine Asset</comment>",
		"    <icon name=\"application-x-unreal-uasset\"/>",
		"    <glob pattern=\"*.uasset\"/>",
		"  </mime-type>",
		"</mime-info>",
		"",
	]))


static func _desktop_quote(value: String) -> String:
	# Desktop Exec values are unescaped once as strings and again as quoted args.
	var escaped := value.replace("\\", "\\\\\\\\")
	escaped = escaped.replace("\"", "\\\"")
	escaped = escaped.replace("`", "\\\\`")
	escaped = escaped.replace("$", "\\\\$")
	escaped = escaped.replace("%", "%%")
	return "\"%s\"" % escaped


func _register_windows(executable_path: String) -> OperationResult:
	var association_dir := _config_directory.path_join("file-association")
	var icon_path := association_dir.path_join("uasset_icon.ico")
	var icon_error := _write_resource(UASSET_ICON_ICO, icon_path)
	if icon_error != OK:
		return OperationResult.failed(
				"Could not install the .uasset icon (error %d)." % icon_error)

	for entry: Dictionary in windows_registry_entries(executable_path, icon_path):
		var args := PackedStringArray(["add", str(entry["key"])])
		var value_name := str(entry["name"])
		if value_name.is_empty():
			args.append("/ve")
		else:
			args.append_array(PackedStringArray(["/v", value_name]))
		args.append_array(PackedStringArray([
			"/t", "REG_SZ", "/d", str(entry["data"]), "/f",
		]))
		var output: Array = []
		var exit_code := OS.execute("reg.exe", args, output, true, false)
		if exit_code != 0:
			return OperationResult.failed(
					"Windows rejected the .uasset registration (exit %d): %s" % [
						exit_code, ProcessUtils.output_text(output),
					])

	var icon_refresh := ProcessUtils.find_executable(["ie4uinit.exe"])
	if not icon_refresh.is_empty():
		OS.execute(icon_refresh, PackedStringArray(["-show"]), [], true, false)
	var settings_error := OS.shell_open(
			"ms-settings:defaultapps?registeredAppUser=Spellbreak%20Modkit")
	if settings_error != OK:
		return OperationResult.succeeded(
				"Spellbreak Modkit is registered for .uasset files. " +
				"Choose it in Windows Settings > Apps > Default apps.")
	return OperationResult.succeeded(
			"Spellbreak Modkit is registered. Choose it for .uasset files in Default Apps.")


func _register_linux(executable_path: String) -> OperationResult:
	var data_home := _linux_data_home()
	if data_home.is_empty():
		return OperationResult.failed("Could not locate the user data directory.")

	var applications_dir := data_home.path_join("applications")
	var mime_root := data_home.path_join("mime")
	var package_path := mime_root.path_join("packages/spellbreak-modkit-uasset.xml")
	var desktop_path := applications_dir.path_join(DESKTOP_FILE_NAME)
	var app_icon_path := data_home.path_join(
			"icons/hicolor/128x128/apps/spellbreak-modkit.png")
	var mime_icon_path := data_home.path_join(
			"icons/hicolor/128x128/mimetypes/application-x-unreal-uasset.png")

	var writes := [
		_write_text(desktop_path, linux_desktop_entry(executable_path)),
		_write_text(package_path, linux_mime_package()),
		_write_texture_png(APP_ICON_RESOURCE, app_icon_path),
		_write_texture_png(UASSET_ICON_RESOURCE, mime_icon_path),
	]
	for error_value in writes:
		var error := int(error_value)
		if error != OK:
			return OperationResult.failed(
					"Could not install .uasset association metadata (error %d)." % error)

	var mime_updater := ProcessUtils.find_executable(["update-mime-database"])
	if mime_updater.is_empty():
		return OperationResult.failed(
				"Association files were installed, but update-mime-database was not found.")
	var output: Array = []
	var exit_code := OS.execute(
			mime_updater, PackedStringArray([mime_root]), output, true, false)
	if exit_code != 0:
		return OperationResult.failed(
				"Could not update the MIME database (exit %d): %s" % [
					exit_code, ProcessUtils.output_text(output),
				])

	var desktop_updater := ProcessUtils.find_executable(["update-desktop-database"])
	if not desktop_updater.is_empty():
		OS.execute(desktop_updater, PackedStringArray([applications_dir]), [], true, false)
	var icon_updater := ProcessUtils.find_executable(["gtk-update-icon-cache"])
	if not icon_updater.is_empty():
		OS.execute(icon_updater, PackedStringArray([
			"-f", "-t", data_home.path_join("icons/hicolor"),
		]), [], true, false)

	var xdg_mime := ProcessUtils.find_executable(["xdg-mime"])
	if xdg_mime.is_empty():
		return OperationResult.failed(
				"Association files were installed, but xdg-mime was not found.")
	output = []
	exit_code = OS.execute(xdg_mime, PackedStringArray([
		"default", DESKTOP_FILE_NAME, MIME_TYPE,
	]), output, true, false)
	if exit_code != 0:
		return OperationResult.failed(
				"Could not set the .uasset default app (exit %d): %s" % [
					exit_code, ProcessUtils.output_text(output),
				])
	output = []
	exit_code = OS.execute(xdg_mime, PackedStringArray([
		"query", "default", MIME_TYPE,
	]), output, true, false)
	if exit_code != 0 or ProcessUtils.output_text(output, "") != DESKTOP_FILE_NAME:
		return OperationResult.failed(
				"The .uasset handler was installed, but the desktop did not accept it as default.")
	return OperationResult.succeeded(
			"Spellbreak Modkit is now the default app for .uasset files.")


func _linux_data_home() -> String:
	var data_home := OS.get_environment("XDG_DATA_HOME").strip_edges()
	if not data_home.is_empty():
		return data_home
	var user_home := OS.get_environment("HOME").strip_edges()
	return user_home.path_join(".local/share") if not user_home.is_empty() else ""


func _write_resource(source_path: String, target_path: String) -> Error:
	if not FileAccess.file_exists(source_path):
		return ERR_FILE_NOT_FOUND
	return FileUtils.write_bytes_atomic(
			target_path, FileAccess.get_file_as_bytes(source_path))


func _write_texture_png(source_path: String, target_path: String) -> Error:
	var texture := load(source_path) as Texture2D
	if texture == null:
		return ERR_FILE_NOT_FOUND
	var image := texture.get_image()
	if image == null or image.is_empty():
		return ERR_CANT_CREATE
	return FileUtils.write_bytes_atomic(target_path, image.save_png_to_buffer())


func _write_text(target_path: String, contents: String) -> Error:
	return FileUtils.write_bytes_atomic(target_path, contents.to_utf8_buffer())
