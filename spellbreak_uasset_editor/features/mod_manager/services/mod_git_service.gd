class_name ModGitService extends RefCounted

## Git operations used by the mod collaboration menu. Network access only
## occurs after an explicit Fetch, Pull, or Push action from the user.

static func is_repository(path: String) -> bool:
	var marker := path.path_join(".git")
	return DirAccess.dir_exists_absolute(marker) or FileAccess.file_exists(marker)


static func status(path: String) -> Dictionary:
	var info := {
		"success": false,
		"branch": "unknown",
		"changed": 0,
		"ahead": 0,
		"behind": 0,
		"has_upstream": false,
		"remote_url": "",
		"changes": PackedStringArray(),
		"error": "",
	}
	if not is_repository(path):
		info.error = "This mod is not a Git repository."
		return info
	var git := ProcessUtils.find_executable(["git"])
	if git.is_empty():
		info.error = "Git is not installed or is not available on PATH."
		return info

	var branch := _run(git, path, ["branch", "--show-current"])
	if not branch.success:
		info.error = _failure_text(branch, "Could not read the current branch.")
		return info
	info.branch = str(branch.output)
	if str(info.branch).is_empty():
		info.branch = "detached HEAD"

	var changes := _run(git, path, ["status", "--porcelain"])
	if not changes.success:
		info.error = _failure_text(changes, "Could not read repository status.")
		return info
	info.changed = str(changes.output).split("\n", false).size()
	info.changes = _friendly_changes(str(changes.output))

	var upstream := _run(git, path, ["rev-parse", "--abbrev-ref", "@{upstream}"])
	info.has_upstream = upstream.success
	if upstream.success:
		var counts := _run(git, path,
				["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
		if counts.success:
			var parts := str(counts.output).replace("\t", " ").split(" ", false)
			if parts.size() >= 2:
				info.behind = int(parts[0])
				info.ahead = int(parts[1])

	var remote := _run(git, path, ["remote", "get-url", "origin"])
	if remote.success:
		info.remote_url = str(remote.output)
	info.success = true
	return info


static func fetch(path: String) -> Dictionary:
	return _run_found(path, ["fetch", "--prune"])


static func pull(path: String) -> Dictionary:
	# Never create an unexpected merge commit from this beginner-facing menu.
	return _run_found(path, ["pull", "--ff-only"])


static func push(path: String, branch: String, has_upstream: bool) -> Dictionary:
	if has_upstream:
		return _run_found(path, ["push"])
	if branch.is_empty() or branch == "detached HEAD":
		return {"success": false, "output": "Create or switch to a branch before sharing commits."}
	return _run_found(path, ["push", "--set-upstream", "origin", branch])


static func commit_all(path: String, message: String) -> Dictionary:
	message = message.strip_edges()
	if message.is_empty():
		return {"success": false, "output": "Enter a short description of your changes."}
	var git := ProcessUtils.find_executable(["git"])
	if git.is_empty():
		return {"success": false, "output": "Git is not installed or is not available on PATH."}
	var staged := _run(git, path, ["add", "--all"])
	if not staged.success:
		return staged
	return _run(git, path, ["commit", "-m", message])


static func browser_url(remote_url: String) -> String:
	var url := remote_url.strip_edges().trim_suffix("/").trim_suffix(".git")
	if url.begins_with("git@") and ":" in url:
		var host_and_path := url.trim_prefix("git@").split(":", true, 1)
		if host_and_path.size() == 2:
			return "https://%s/%s" % [host_and_path[0], host_and_path[1]]
	if url.begins_with("ssh://git@"):
		return "https://" + url.trim_prefix("ssh://git@")
	return url if url.begins_with("https://") or url.begins_with("http://") else ""


static func _run(git: String, path: String, arguments: Array) -> Dictionary:
	var args := PackedStringArray(["-C", path])
	args.append_array(PackedStringArray(arguments))
	var output: Array = []
	var exit_code := OS.execute(git, args, output, true, false)
	return {
		"success": exit_code == 0,
		"output": ProcessUtils.output_text(output, ""),
	}


static func _run_found(path: String, arguments: Array) -> Dictionary:
	var git := ProcessUtils.find_executable(["git"])
	if git.is_empty():
		return {"success": false, "output": "Git is not installed or is not available on PATH."}
	return _run(git, path, arguments)


static func _friendly_changes(porcelain: String) -> PackedStringArray:
	var result := PackedStringArray()
	for line: String in porcelain.split("\n", false):
		if line.length() < 4:
			continue
		var code := line.substr(0, 2)
		var path := line.substr(3)
		var action := "Changed"
		if "?" in code:
			action = "New"
		elif "D" in code:
			action = "Deleted"
		elif "R" in code:
			action = "Renamed"
		elif "A" in code:
			action = "Added"
		result.append("%s: %s" % [action, path])
	return result


static func _failure_text(result: Dictionary, fallback: String) -> String:
	var output := str(result.get("output", "")).strip_edges()
	return output if not output.is_empty() else fallback
