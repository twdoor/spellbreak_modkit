extends Node

## Checks the running app version against releases published for this project's
## Git repository. The repository is discovered from the checkout automatically.
##
## Usage:
##     var result := await VersionManager.check_for_updates()
##     if result.success and result.update_available:
##         print("A new version is available: ", result.latest_version)

signal update_check_completed(result: Dictionary)
signal update_download_progress(downloaded_bytes: int, total_bytes: int)

const GitRepository = preload("res://addons/version_manager/git_repository.gd")
const SemanticVersion = preload("res://addons/version_manager/semantic_version.gd")
const USE_PRE_RELEASE_SETTING := "version_manager/use_pre_release"
const APP_VERSION_SETTING := "application/config/version"

var _download_request: HTTPRequest
var _download_progress_timer: Timer
var _download_cancelled := false


func check_for_updates() -> Dictionary:
	var current_version := str(ProjectSettings.get_setting(APP_VERSION_SETTING, "")).strip_edges()
	if current_version.is_empty():
		return _finish_with_error(
			"Set application/config/version in Project Settings before checking for updates."
		)
	if not bool(SemanticVersion.parse(current_version).valid):
		return _finish_with_error(
			"The current project version must use semantic versioning, such as 1.2.3."
		)

	var repository := _project_repository_url()
	if not bool(repository.success):
		return _finish_with_error(str(repository.error))

	var api_url := _github_releases_api_url(str(repository.url))
	if api_url.is_empty():
		return _finish_with_error(
			"This project's Git remote must point to a GitHub repository."
		)

	var request := HTTPRequest.new()
	request.timeout = 15.0
	add_child(request)

	var headers := PackedStringArray([
		"Accept: application/vnd.github+json",
		"X-GitHub-Api-Version: 2022-11-28",
		"User-Agent: Godot-Version-Manager",
	])
	var request_error := request.request(api_url, headers)
	if request_error != OK:
		request.queue_free()
		return _finish_with_error(
			"Could not start the release request (error %d)." % request_error
		)

	var response: Array = await request.request_completed
	request.queue_free()

	var transport_result: int = response[0]
	var response_code: int = response[1]
	var body: PackedByteArray = response[3]

	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return _finish_with_error(
			"The release request failed (transport result %d)." % transport_result
		)
	if response_code != 200:
		return _finish_with_error(
			"GitHub returned HTTP %d while checking releases." % response_code
		)

	var parsed_response: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed_response is Array:
		return _finish_with_error("GitHub returned an unexpected release response.")

	var use_pre_release := _uses_prerelease_channel(
		current_version,
		bool(ProjectSettings.get_setting(USE_PRE_RELEASE_SETTING, false))
	)
	var release := _find_latest_release(parsed_response, use_pre_release)
	if release.is_empty():
		var release_kind := "published"
		if not use_pre_release:
			release_kind = "stable"
		return _finish_with_error(
			"The repository has no %s releases with semantic-version tags."
			% release_kind
		)

	var latest_version := _release_version(release)
	if latest_version.is_empty():
		return _finish_with_error("The latest GitHub release has no usable version tag.")

	var comparison := SemanticVersion.compare(current_version, latest_version)
	var target_path := _update_target_path()
	var asset := _select_release_asset(
		release.get("assets", []),
		OS.get_name(),
		Engine.get_architecture_name(),
		target_path.get_file()
	)
	var checksum_asset := _select_checksum_asset(release.get("assets", []))
	var support := _automatic_update_support(asset)
	if (
		bool(support.get("supported", false))
		and _asset_sha256(asset).is_empty()
		and checksum_asset.is_empty()
	):
		support = {
			"supported": false,
			"error": (
				"This release has no SHA-256 digest or SHA256SUMS asset, so it "
				+ "cannot be installed safely."
			),
		}
	var result := {
		"success": true,
		"update_available": comparison < 0,
		"is_current": comparison == 0,
		"is_ahead": comparison > 0,
		"current_version": current_version,
		"latest_version": latest_version,
		"release_url": str(release.get("html_url", "")),
		"asset": asset,
		"checksum_asset": checksum_asset,
		"install_supported": bool(support.get("supported", false)),
		"install_error": str(support.get("error", "")),
		"error": "",
	}
	update_check_completed.emit(result)
	return result


func _project_repository_url() -> Dictionary:
	var embedded_repository := _embedded_repository_identifier()
	if not embedded_repository.is_empty():
		return {
			"success": true,
			"url": embedded_repository,
			"error": "",
		}

	return GitRepository.find_remote(ProjectSettings.globalize_path("res://"))


func _embedded_repository_identifier() -> String:
	if not FileAccess.file_exists(GitRepository.EXPORT_METADATA_PATH):
		return ""

	var contents := FileAccess.get_file_as_string(GitRepository.EXPORT_METADATA_PATH)
	var parsed: Variant = JSON.parse_string(contents)
	if not parsed is Dictionary:
		return ""
	return str(parsed.get("repository", "")).strip_edges()


func _find_latest_release(releases: Array, use_pre_release: bool) -> Dictionary:
	var latest_release: Dictionary = {}
	for release: Variant in releases:
		if not release is Dictionary:
			continue
		if bool(release.get("draft", false)):
			continue
		if not use_pre_release and bool(release.get("prerelease", false)):
			continue

		var release_version := _release_version(release)
		var parsed_version := SemanticVersion.parse(release_version)
		if not bool(parsed_version.valid):
			continue
		var prerelease: PackedStringArray = parsed_version.prerelease
		if not use_pre_release and not prerelease.is_empty():
			continue

		if latest_release.is_empty():
			latest_release = release
			continue
		if SemanticVersion.compare(
			release_version,
			_release_version(latest_release)
		) > 0:
			latest_release = release
	return latest_release


static func _release_version(release: Dictionary) -> String:
	var tag_name := str(release.get("tag_name", "")).strip_edges()
	var parsed := SemanticVersion.parse(tag_name)
	if bool(parsed.get("valid", false)):
		return str(parsed.get("normalized", tag_name))
	# Older project releases used tags such as "0.11" while displaying
	# "0.11.0". Preserve compatibility with that established release format.
	var shorthand := RegEx.new()
	if shorthand.compile("^[vV]?(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$") != OK:
		return ""
	var matched := shorthand.search(tag_name)
	if matched == null:
		return ""
	return "%s.%s.0" % [matched.get_string(1), matched.get_string(2)]


func download_and_prepare_update(update_info: Dictionary) -> Dictionary:
	if is_instance_valid(_download_request):
		return _update_error("An update download is already running.")
	var asset: Variant = update_info.get("asset", {})
	if not asset is Dictionary or (asset as Dictionary).is_empty():
		return _update_error("This release has no compatible download for your platform.")
	var support := _automatic_update_support(asset)
	if not bool(support.get("supported", false)):
		return _update_error(str(support.get("error", "Automatic updating is unavailable.")))

	var target_path := _update_target_path()
	var writable_error := _target_directory_error(target_path)
	if not writable_error.is_empty():
		return _update_error(writable_error)
	var version := str(update_info.get("latest_version", "update")).validate_filename()
	if version.is_empty():
		version = "update"
	var update_dir := ProjectSettings.globalize_path("user://updates").path_join(version)
	var directory_error := DirAccess.make_dir_recursive_absolute(update_dir)
	if directory_error != OK:
		return _update_error("Could not create the update staging folder (error %d)."
			% directory_error)

	var asset_name := str(asset.get("name", "update")).get_file().validate_filename()
	if asset_name.is_empty():
		asset_name = "update"
	var download_path := update_dir.path_join(asset_name)
	if FileAccess.file_exists(download_path):
		DirAccess.remove_absolute(download_path)

	var checksum_contents := ""
	if _asset_sha256(asset).is_empty():
		var checksum_asset: Variant = update_info.get("checksum_asset", {})
		if not checksum_asset is Dictionary or (checksum_asset as Dictionary).is_empty():
			return _update_error(
				"The release does not provide a SHA-256 digest or checksum file."
			)
		var checksum_name := str(
			(checksum_asset as Dictionary).get("name", "SHA256SUMS")
		).get_file().validate_filename()
		if checksum_name.is_empty():
			checksum_name = "SHA256SUMS"
		var checksum_path := update_dir.path_join(checksum_name)
		if FileAccess.file_exists(checksum_path):
			DirAccess.remove_absolute(checksum_path)
		var checksum_download := await _download_asset(
			checksum_asset as Dictionary, checksum_path, false
		)
		if not bool(checksum_download.get("success", false)):
			return checksum_download
		checksum_contents = FileAccess.get_file_as_string(checksum_path)
		if _checksum_for_asset(checksum_contents, str(asset.get("name", ""))).is_empty():
			return _update_error(
				"The release checksum file has no SHA-256 entry for %s."
				% str(asset.get("name", "the selected update"))
			)

	var download_result := await _download_asset(asset, download_path)
	if not bool(download_result.get("success", false)):
		return download_result
	var verify_error := _verify_download(download_path, asset, checksum_contents)
	if not verify_error.is_empty():
		return _update_error(verify_error)

	var staged_path := update_dir.path_join("staged-" + target_path.get_file())
	var stage_result := _stage_update_asset(
		download_path,
		staged_path,
		str(asset.get("name", "")),
		target_path.get_file(),
		OS.get_name()
	)
	if not bool(stage_result.get("success", false)):
		return stage_result
	return {
		"success": true,
		"error": "",
		"version": str(update_info.get("latest_version", "")),
		"asset_name": str(asset.get("name", "")),
		"download_path": download_path,
		"staged_path": staged_path,
		"target_path": target_path,
		"update_dir": update_dir,
		"archive_entry": str(stage_result.get("archive_entry", "")),
	}


func cancel_update_download() -> void:
	_download_cancelled = true
	if is_instance_valid(_download_request):
		_download_request.cancel_request()


func launch_prepared_update(prepared: Dictionary) -> Dictionary:
	var staged_path := str(prepared.get("staged_path", ""))
	var target_path := str(prepared.get("target_path", ""))
	var update_dir := str(prepared.get("update_dir", ""))
	if staged_path.is_empty() or not FileAccess.file_exists(staged_path):
		return _update_error("The staged update executable is missing.")
	if target_path.is_empty() or not FileAccess.file_exists(target_path):
		return _update_error("The current application executable could not be found.")
	if update_dir.is_empty() or not DirAccess.dir_exists_absolute(update_dir):
		return _update_error("The update staging folder is missing.")

	var backup_path := target_path + ".previous"
	var platform := OS.get_name()
	var script_extension := ".ps1" if platform == "Windows" else ".sh"
	var script_path := update_dir.path_join("install-update" + script_extension)
	var script_text := _installer_script(platform)
	if script_text.is_empty():
		return _update_error("Automatic installation is not supported on %s." % platform)
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	if script_file == null:
		return _update_error("Could not create the update installer script.")
	script_file.store_string(script_text)
	script_file.close()

	var process_id := -1
	if platform == "Windows":
		process_id = OS.create_process("powershell.exe", PackedStringArray([
			"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path,
			"-TargetPath", target_path,
			"-StagedPath", staged_path,
			"-BackupPath", backup_path,
			"-ParentPid", str(OS.get_process_id()),
		]))
	elif platform == "Linux" or platform == "FreeBSD" or platform == "NetBSD" \
			or platform == "OpenBSD" or platform == "BSD":
		process_id = OS.create_process("/bin/sh", PackedStringArray([
			script_path, target_path, staged_path, backup_path,
			str(OS.get_process_id()),
		]))
	if process_id < 0:
		return _update_error("Could not launch the update installer.")
	return {"success": true, "error": "", "installer_pid": process_id}


func _download_asset(
	asset: Dictionary,
	download_path: String,
	report_progress := true
) -> Dictionary:
	var url := str(asset.get("browser_download_url", ""))
	if not url.begins_with("https://github.com/"):
		return _update_error("The release download URL is not a trusted GitHub URL.")
	_download_cancelled = false
	_download_request = HTTPRequest.new()
	_download_request.timeout = 180.0
	_download_request.download_file = download_path
	add_child(_download_request)

	if report_progress:
		_download_progress_timer = Timer.new()
		_download_progress_timer.wait_time = 0.15
		_download_progress_timer.timeout.connect(func() -> void:
			if is_instance_valid(_download_request):
				update_download_progress.emit(
					_download_request.get_downloaded_bytes(),
					int(asset.get("size", 0)))
		)
		add_child(_download_progress_timer)
		_download_progress_timer.start()

	var headers := PackedStringArray(["User-Agent: Godot-Version-Manager"])
	var request_error := _download_request.request(url, headers)
	if request_error != OK:
		_cleanup_download_nodes()
		return _update_error("Could not start the update download (error %d)." % request_error)
	var response: Array = await _download_request.request_completed
	var was_cancelled := _download_cancelled
	_cleanup_download_nodes()
	if was_cancelled:
		return {"success": false, "cancelled": true, "error": "Download cancelled."}
	var transport_result: int = response[0]
	var response_code: int = response[1]
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return _update_error("The update download failed (transport result %d)."
			% transport_result)
	if response_code != 200:
		return _update_error("GitHub returned HTTP %d while downloading the update."
			% response_code)
	return {"success": true, "error": ""}


func _cleanup_download_nodes() -> void:
	if is_instance_valid(_download_progress_timer):
		_download_progress_timer.stop()
		_download_progress_timer.queue_free()
	if is_instance_valid(_download_request):
		_download_request.queue_free()
	_download_progress_timer = null
	_download_request = null


func _verify_download(
	download_path: String,
	asset: Dictionary,
	checksum_contents := ""
) -> String:
	if not FileAccess.file_exists(download_path):
		return "The downloaded update is missing."
	var expected_size := int(asset.get("size", 0))
	var file := FileAccess.open(download_path, FileAccess.READ)
	if file == null:
		return "The downloaded update could not be read."
	var actual_size := file.get_length()
	file.close()
	if expected_size > 0 and actual_size != expected_size:
		return "The update download is incomplete (%d of %d bytes)." % [
			actual_size, expected_size]
	var expected_hash := _asset_sha256(asset)
	if expected_hash.is_empty():
		expected_hash = _checksum_for_asset(
			checksum_contents, str(asset.get("name", ""))
		)
	if expected_hash.is_empty():
		return "The release does not provide a usable SHA-256 checksum."
	var actual_hash := FileAccess.get_sha256(download_path).to_lower()
	if actual_hash != expected_hash:
		return "The downloaded update failed SHA-256 verification."
	return ""


func _stage_update_asset(
	download_path: String,
	staged_path: String,
	asset_name: String,
	target_filename: String,
	platform: String
) -> Dictionary:
	if asset_name.to_lower().ends_with(".zip"):
		return _extract_update_executable(
			download_path, staged_path, target_filename, platform
		)
	if not _is_direct_executable_asset(asset_name, platform):
		return _update_error(
			"The downloaded release asset is not a supported executable."
		)
	if FileAccess.file_exists(staged_path):
		DirAccess.remove_absolute(staged_path)
	var copy_error := DirAccess.copy_absolute(download_path, staged_path)
	if copy_error != OK:
		return _update_error(
			"Could not stage the downloaded update (error %d)." % copy_error
		)
	return {"success": true, "error": "", "archive_entry": ""}


func _extract_update_executable(archive_path: String, staged_path: String,
		target_filename: String, platform: String) -> Dictionary:
	var reader := ZIPReader.new()
	var open_error := reader.open(archive_path)
	if open_error != OK:
		return _update_error("Could not open the update archive (error %d)." % open_error)
	var archive_entry := _select_executable_entry(
		reader.get_files(), platform, target_filename)
	if archive_entry.is_empty():
		reader.close()
		return _update_error("The update archive does not contain a compatible executable.")
	var executable_bytes := reader.read_file(archive_entry, true)
	reader.close()
	if executable_bytes.is_empty():
		return _update_error("The update executable could not be extracted.")
	if FileAccess.file_exists(staged_path):
		DirAccess.remove_absolute(staged_path)
	var output := FileAccess.open(staged_path, FileAccess.WRITE)
	if output == null:
		return _update_error("Could not write the staged update executable.")
	output.store_buffer(executable_bytes)
	output.close()
	return {"success": true, "error": "", "archive_entry": archive_entry}


func _automatic_update_support(asset: Dictionary) -> Dictionary:
	if asset.is_empty():
		return {"supported": false,
			"error": "This release has no compatible download for your platform."}
	if OS.has_feature("editor"):
		return {"supported": false,
			"error": "Automatic installation is available in exported builds only."}
	if OS.get_name() not in ["Windows", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return {"supported": false,
			"error": "Automatic installation is not supported on %s." % OS.get_name()}
	return {"supported": true, "error": ""}


func _target_directory_error(target_path: String) -> String:
	if target_path.is_empty() or not FileAccess.file_exists(target_path):
		return "The running application executable could not be located."
	var probe_path := target_path.get_base_dir().path_join(
		".sb-update-write-test-%d" % OS.get_process_id())
	var probe := FileAccess.open(probe_path, FileAccess.WRITE)
	if probe == null:
		return "The application folder is not writable. Open the release page to update manually."
	probe.store_8(0)
	probe.close()
	DirAccess.remove_absolute(probe_path)
	return ""


static func _select_release_asset(
	assets_value: Variant,
	platform: String,
	architecture := "",
	target_filename := ""
) -> Dictionary:
	if not assets_value is Array:
		return {}
	var normalized_architecture := architecture.strip_edges().to_lower()
	if not normalized_architecture.is_empty() \
			and normalized_architecture not in ["x86_64", "amd64"]:
		return {}
	var aliases: Array[String] = []
	match platform:
		"Windows":
			aliases = ["sbue.exe", "win.zip", "windows.zip", "windows-x86_64.zip"]
		"Linux":
			if target_filename.to_lower().ends_with(".appimage"):
				aliases = [
					"sbue.appimage", "sbue.x86_64", "linux.zip", "linux-x86_64.zip"
				]
			else:
				aliases = [
					"sbue.x86_64", "sbue.appimage", "linux.zip", "linux-x86_64.zip"
				]
		"FreeBSD", "NetBSD", "OpenBSD", "BSD":
			aliases = ["linux.zip", "linux-x86_64.zip"]
		_:
			return {}
	for alias in aliases:
		for asset_value in assets_value:
			if asset_value is Dictionary \
					and str(asset_value.get("name", "")).to_lower() == alias:
				return (asset_value as Dictionary).duplicate(true)
	if platform == "Linux":
		var extensions: Array[String] = [".x86_64", ".appimage"]
		if target_filename.to_lower().ends_with(".appimage"):
			extensions = [".appimage", ".x86_64"]
		for wanted_extension: String in extensions:
			for asset_value in assets_value:
				if asset_value is Dictionary \
						and str(asset_value.get("name", "")).to_lower().ends_with(
							wanted_extension
						):
					return (asset_value as Dictionary).duplicate(true)
	if platform == "Windows":
		for asset_value in assets_value:
			if asset_value is Dictionary \
					and str(asset_value.get("name", "")).to_lower().ends_with(".exe"):
				return (asset_value as Dictionary).duplicate(true)

	var platform_term := "win" if platform == "Windows" else "linux"
	for asset_value in assets_value:
		if not asset_value is Dictionary:
			continue
		var asset_name := str(asset_value.get("name", "")).to_lower()
		if platform_term in asset_name and asset_name.ends_with(".zip") \
				and (architecture.is_empty() or architecture.to_lower() in asset_name):
			return (asset_value as Dictionary).duplicate(true)
	return {}


static func _select_checksum_asset(assets_value: Variant) -> Dictionary:
	if not assets_value is Array:
		return {}
	for wanted_name: String in ["sha256sums", "sha256sums.txt", "checksums.txt"]:
		for asset_value in assets_value:
			if asset_value is Dictionary \
					and str(asset_value.get("name", "")).to_lower() == wanted_name:
				return (asset_value as Dictionary).duplicate(true)
	return {}


static func _asset_sha256(asset: Dictionary) -> String:
	var digest := str(asset.get("digest", "")).strip_edges().to_lower()
	if digest.begins_with("sha256:") and digest.length() == 71:
		var value := digest.trim_prefix("sha256:")
		if value.is_valid_hex_number():
			return value
	return ""


static func _checksum_for_asset(contents: String, asset_name: String) -> String:
	var expression := RegEx.new()
	if expression.compile("^([0-9A-Fa-f]{64})[\\t ]+[*]?(.+)$") != OK:
		return ""
	var expected_name := asset_name.get_file().to_lower()
	for raw_line: String in contents.split("\n"):
		var matched := expression.search(raw_line.strip_edges())
		if matched == null:
			continue
		if matched.get_string(2).strip_edges().get_file().to_lower() == expected_name:
			return matched.get_string(1).to_lower()
	return ""


static func _is_direct_executable_asset(asset_name: String, platform: String) -> bool:
	var lower := asset_name.to_lower()
	if platform == "Windows":
		return lower.ends_with(".exe")
	if platform == "Linux":
		return lower.ends_with(".appimage") or lower.ends_with(".x86_64")
	return false


static func _uses_prerelease_channel(current_version: String, configured: bool) -> bool:
	if configured:
		return true
	var parsed := SemanticVersion.parse(current_version)
	return bool(parsed.get("valid", false)) \
		and not (parsed.get("prerelease", PackedStringArray()) as PackedStringArray).is_empty()


func _update_target_path() -> String:
	if OS.get_name() == "Linux":
		var appimage_path := OS.get_environment("APPIMAGE").strip_edges()
		if not appimage_path.is_empty() and FileAccess.file_exists(appimage_path):
			return appimage_path
	return OS.get_executable_path()


static func _select_executable_entry(files: PackedStringArray, platform: String,
		target_filename: String) -> String:
	var target_lower := target_filename.to_lower()
	for entry in files:
		if not entry.ends_with("/") and entry.get_file().to_lower() == target_lower:
			return entry
	var candidates := PackedStringArray()
	for entry in files:
		if entry.ends_with("/"):
			continue
		var lower := entry.to_lower()
		if (platform == "Windows" and lower.ends_with(".exe")) \
				or (platform != "Windows" and (
					lower.ends_with(".x86_64") or lower.ends_with(".appimage"))):
			candidates.append(entry)
	return candidates[0] if candidates.size() == 1 else ""


static func _installer_script(platform: String) -> String:
	if platform == "Windows":
		return """param(
    [string]$TargetPath,
    [string]$StagedPath,
    [string]$BackupPath,
    [int]$ParentPid
)
$ErrorActionPreference = 'Stop'
try { Wait-Process -Id $ParentPid -Timeout 120 -ErrorAction SilentlyContinue } catch {}
for ($i = 0; $i -lt 40; $i++) {
    try {
        if (Test-Path -LiteralPath $BackupPath) { Remove-Item -LiteralPath $BackupPath -Force }
        Move-Item -LiteralPath $TargetPath -Destination $BackupPath -Force
        Move-Item -LiteralPath $StagedPath -Destination $TargetPath -Force
        Start-Process -FilePath $TargetPath -WorkingDirectory (Split-Path -Parent $TargetPath)
        exit 0
    } catch {
        if (-not (Test-Path -LiteralPath $TargetPath) -and (Test-Path -LiteralPath $BackupPath)) {
            Move-Item -LiteralPath $BackupPath -Destination $TargetPath -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }
}
exit 1
"""
	if platform in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return """#!/bin/sh
target="$1"
staged="$2"
backup="$3"
parent_pid="$4"
attempt=0
while kill -0 "$parent_pid" 2>/dev/null && [ "$attempt" -lt 120 ]; do
    sleep 1
    attempt=$((attempt + 1))
done
rm -f "$backup"
if mv -f "$target" "$backup" && mv -f "$staged" "$target"; then
    chmod +x "$target"
    "$target" >/dev/null 2>&1 &
    exit 0
fi
if [ ! -f "$target" ] && [ -f "$backup" ]; then
    mv -f "$backup" "$target"
fi
exit 1
"""
	return ""


static func _update_error(message: String) -> Dictionary:
	return {"success": false, "cancelled": false, "error": message}


func _github_releases_api_url(repo_url: String) -> String:
	var repository := GitRepository.github_repository_identifier(repo_url)
	if repository.is_empty():
		return ""

	return "https://api.github.com/repos/%s/releases?per_page=100" % repository


func _finish_with_error(message: String) -> Dictionary:
	var result := {
		"success": false,
		"update_available": false,
		"is_current": false,
		"is_ahead": false,
		"current_version": str(ProjectSettings.get_setting(APP_VERSION_SETTING, "")),
		"latest_version": "",
		"release_url": "",
		"asset": {},
		"checksum_asset": {},
		"install_supported": false,
		"install_error": "",
		"error": message,
	}
	update_check_completed.emit(result)
	return result
