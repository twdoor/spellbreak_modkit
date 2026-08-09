extends Node

## Checks the running app version against releases published for this project's
## Git repository. The repository is discovered from the checkout automatically.
##
## Usage:
##     var result := await VersionManager.check_for_updates()
##     if result.success and result.update_available:
##         print("A new version is available: ", result.latest_version)

signal update_check_completed(result: Dictionary)

const GitRepository = preload("res://addons/version_manager/git_repository.gd")
const SemanticVersion = preload("res://addons/version_manager/semantic_version.gd")
const USE_PRE_RELEASE_SETTING := "version_manager/use_pre_release"
const APP_VERSION_SETTING := "application/config/version"


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

	var use_pre_release := bool(
		ProjectSettings.get_setting(USE_PRE_RELEASE_SETTING, false)
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

	var latest_version := str(release.get("tag_name", "")).strip_edges()
	if latest_version.is_empty():
		return _finish_with_error("The latest GitHub release has no version tag.")

	var comparison := SemanticVersion.compare(current_version, latest_version)
	var result := {
		"success": true,
		"update_available": comparison < 0,
		"is_current": comparison == 0,
		"is_ahead": comparison > 0,
		"current_version": current_version,
		"latest_version": latest_version,
		"release_url": str(release.get("html_url", "")),
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

		var tag_name := str(release.get("tag_name", "")).strip_edges()
		var parsed_version := SemanticVersion.parse(tag_name)
		if not bool(parsed_version.valid):
			continue
		var prerelease: PackedStringArray = parsed_version.prerelease
		if not use_pre_release and not prerelease.is_empty():
			continue

		if latest_release.is_empty():
			latest_release = release
			continue
		if SemanticVersion.compare(
			tag_name,
			str(latest_release.get("tag_name", ""))
		) > 0:
			latest_release = release
	return latest_release


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
		"error": message,
	}
	update_check_completed.emit(result)
	return result
