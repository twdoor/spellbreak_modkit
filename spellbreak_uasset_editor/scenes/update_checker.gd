class_name UpdateChecker extends Node

signal update_available(version: String, release_url: String, release_name: String)
signal check_failed(message: String)

const DEFAULT_REPOSITORY := "twdoor/spellbreak_modkit"
const GITHUB_LATEST_RELEASE_API := "https://api.github.com/repos/%s/releases/latest"
const GITHUB_LATEST_RELEASE_PAGE := "https://github.com/%s/releases/latest"
const REQUEST_TIMEOUT := 10.0

var repository := DEFAULT_REPOSITORY
var current_version := ""

var _request: HTTPRequest
var _checking := false


func _ready() -> void:
	_request = HTTPRequest.new()
	_request.timeout = REQUEST_TIMEOUT
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func check_now() -> void:
	if _checking:
		return
	if current_version.is_empty():
		current_version = str(ProjectSettings.get_setting("application/config/version", "0.0.0"))

	_checking = true
	var headers := PackedStringArray([
		"Accept: application/vnd.github+json",
		"User-Agent: Spellbreak-Modkit",
		"X-GitHub-Api-Version: 2022-11-28",
	])
	var error := _request.request(GITHUB_LATEST_RELEASE_API % repository, headers)
	if error != OK:
		_checking = false
		check_failed.emit("Could not check for updates (error %d)" % error)


static func is_newer_version(latest: String, current: String) -> bool:
	var latest_parts := _version_parts(latest)
	var current_parts := _version_parts(current)
	var count := maxi(latest_parts.size(), current_parts.size())

	for i in range(count):
		var latest_part := latest_parts[i] if i < latest_parts.size() else 0
		var current_part := current_parts[i] if i < current_parts.size() else 0
		if latest_part > current_part:
			return true
		if latest_part < current_part:
			return false
	return false


static func normalize_version(value: String) -> String:
	var parts := _version_parts(value)
	if parts.is_empty():
		return value.strip_edges().trim_prefix("v").trim_prefix("V")

	var strings: Array[String] = []
	for part in parts:
		strings.append(str(part))
	return ".".join(strings)


static func _version_parts(value: String) -> Array[int]:
	var text := value.strip_edges()
	if text.begins_with("v") or text.begins_with("V"):
		text = text.substr(1)

	var parts: Array[int] = []
	var current := ""
	for i in range(text.length()):
		var ch := text.substr(i, 1)
		if ch.is_valid_int():
			current += ch
		elif ch == ".":
			if current.is_empty():
				if not parts.is_empty():
					parts.append(0)
			else:
				parts.append(current.to_int())
				current = ""
		elif current.is_empty() and parts.is_empty():
			continue
		else:
			break

	if not current.is_empty():
		parts.append(current.to_int())
	return parts


func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	_checking = false

	if result != HTTPRequest.RESULT_SUCCESS:
		check_failed.emit("Could not check for updates (request failed)")
		return
	if response_code < 200 or response_code >= 300:
		check_failed.emit("Could not check for updates (HTTP %d)" % response_code)
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		check_failed.emit("Could not read update response")
		return

	var tag_name := str(parsed.get("tag_name", ""))
	if tag_name.is_empty():
		check_failed.emit("Latest release has no version tag")
		return

	if not is_newer_version(tag_name, current_version):
		return

	var release_url := str(parsed.get("html_url", ""))
	if release_url.is_empty():
		release_url = GITHUB_LATEST_RELEASE_PAGE % repository

	var release_name := str(parsed.get("name", ""))
	update_available.emit(normalize_version(tag_name), release_url, release_name)
