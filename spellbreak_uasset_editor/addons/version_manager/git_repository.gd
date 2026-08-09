@tool
extends RefCounted

const EXPORT_METADATA_PATH := "res://.version_manager_repository.json"


static func find_remote(project_path: String) -> Dictionary:
	var repository_check := _run_git(PackedStringArray([
		"-C",
		project_path,
		"rev-parse",
		"--is-inside-work-tree",
	]))
	if not bool(repository_check.success):
		return {
			"success": false,
			"url": "",
			"error": (
				"The project is not inside a Git repository. Initialize Git for the "
				+ "project and add a GitHub remote before checking for updates."
			),
		}

	var remote_name := "origin"
	var remote := _run_git(PackedStringArray([
		"-C",
		project_path,
		"remote",
		"get-url",
		remote_name,
	]))
	if not bool(remote.success):
		var remotes := _remote_names(project_path)
		if remotes.size() == 1:
			remote_name = remotes[0]
			remote = _run_git(PackedStringArray([
				"-C",
				project_path,
				"remote",
				"get-url",
				remote_name,
			]))

	if not bool(remote.success) or str(remote.output).is_empty():
		return {
			"success": false,
			"url": "",
			"error": (
				"The project's Git repository has no default remote. Add a GitHub "
				+ "remote named 'origin' before checking for updates."
			),
		}

	return {
		"success": true,
		"url": str(remote.output),
		"error": "",
	}


static func github_repository_identifier(remote_url: String) -> String:
	var repository := remote_url.strip_edges().trim_suffix("/")
	if repository.is_empty():
		return ""

	repository = repository.split("?", true, 1)[0].split("#", true, 1)[0]
	repository = repository.trim_suffix(".git").trim_suffix("/")

	if repository.begins_with("git@github.com:"):
		repository = repository.trim_prefix("git@github.com:")
	elif repository.begins_with("ssh://git@github.com/"):
		repository = repository.trim_prefix("ssh://git@github.com/")
	elif repository.begins_with("https://github.com/"):
		repository = repository.trim_prefix("https://github.com/")
	elif repository.begins_with("http://github.com/"):
		repository = repository.trim_prefix("http://github.com/")
	elif repository.begins_with("https://api.github.com/repos/"):
		repository = repository.trim_prefix("https://api.github.com/repos/")
	else:
		if "://" in repository or "@" in repository:
			return ""

	var parts := repository.split("/", false)
	if parts.size() != 2 or parts[0].is_empty() or parts[1].is_empty():
		return ""

	return "%s/%s" % [parts[0], parts[1]]


static func _remote_names(project_path: String) -> PackedStringArray:
	var result := _run_git(PackedStringArray([
		"-C",
		project_path,
		"remote",
	]))
	var names := PackedStringArray()
	if not bool(result.success):
		return names

	for line: String in str(result.output).split("\n", false):
		var remote_name := line.strip_edges()
		if not remote_name.is_empty():
			names.append(remote_name)
	return names


static func _run_git(arguments: PackedStringArray) -> Dictionary:
	var command_output: Array = []
	var exit_code := OS.execute("git", arguments, command_output, true)
	var output := ""
	for chunk: Variant in command_output:
		output += str(chunk)

	return {
		"success": exit_code == 0,
		"output": output.strip_edges(),
	}
