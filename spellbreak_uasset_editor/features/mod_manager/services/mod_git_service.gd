class_name ModGitService extends RefCounted

## Git operations used by the mod collaboration menu. Network access only
## occurs after an explicit Fetch, Pull, Push, or Force Sync action from the user.

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
		"upstream": "",
		"remote_url": "",
		"changes": PackedStringArray(),
		"branches": [],
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
	info.changes = _friendly_changes(str(changes.raw_output))
	info.changed = info.changes.size()

	var upstream := _run(git, path, ["rev-parse", "--abbrev-ref", "@{upstream}"])
	info.has_upstream = upstream.success
	info.upstream = str(upstream.output) if upstream.success else ""
	if upstream.success:
		var counts := _run(git, path,
				["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
		if counts.success:
			var parts := str(counts.output).replace("\t", " ").split(" ", false)
			if parts.size() >= 2:
				info.behind = int(parts[0])
				info.ahead = int(parts[1])

	var remote_name := "origin"
	if info.has_upstream:
		var configured := _run(git, path, ["config", "--get", "branch." + str(info.branch) + ".remote"])
		if configured.success:
			remote_name = str(configured.output)
	var remote := _run(git, path, ["remote", "get-url", remote_name])
	if remote.success:
		info.remote_url = str(remote.output)
	var branches := _run(git, path, ["for-each-ref", "--format=%(refname)%09%(symref)", "refs/heads/", "refs/remotes/"])
	if not branches.success:
		info.error = _failure_text(branches, "Could not list branches.")
		return info
	for line in str(branches.raw_output).split("\n", false):
		var fields := line.strip_edges().split("\t")
		if fields.size() > 1 and not fields[1].is_empty():
			continue # Skip remote HEAD aliases.
		var ref := str(fields[0])
		var remote_branch := ref.begins_with("refs/remotes/")
		info.branches.append({"ref": ref, "remote": remote_branch,
			"name": ref.trim_prefix("refs/remotes/" if remote_branch else "refs/heads/")})
	info.success = true
	return info


## Use explicit refs and non-forced switches; never overwrite ignored files.
static func switch_branch(path: String, target_ref: String) -> Dictionary:
	var info := status(path)
	if not info.success:
		return {"success": false, "output": info.error}
	if info.changed > 0:
		return {"success": false, "output": "Commit local changes before switching branches. You can create a new branch to keep working on them."}
	for branch: Dictionary in info.branches:
		if branch.ref != target_ref:
			continue
		if branch.remote:
			var name := str(branch.name).get_slice("/", 0)
			var local_name := str(branch.name).trim_prefix(name + "/")
			return _run_found(path, ["switch", "--no-overwrite-ignore", "--track", "-c", local_name, target_ref])
		return _run_found(path, ["switch", "--no-overwrite-ignore", "--no-guess", "--", str(branch.name)])
	return {"success": false, "output": "That branch no longer exists. Reopen the branch menu to refresh the list."}


static func create_branch(path: String, name: String) -> Dictionary:
	# Validate the literal name, not check-ref-format --branch (which expands @{-1}).
	if name.is_empty() or name.begins_with("-") or name == "HEAD":
		return {"success": false, "output": "Enter a valid branch name, such as feature/new-textures."}
	var valid := _run_found(path, ["check-ref-format", "refs/heads/" + name])
	if not valid.success:
		return {"success": false, "output": "Invalid branch name. Use a name such as feature/new-textures, without spaces."}
	return _run_found(path, ["switch", "--no-overwrite-ignore", "--no-track", "-c", name])


static func fetch(path: String) -> Dictionary:
	return _run_found(path, ["fetch", "--prune"])


static func pull(path: String) -> Dictionary:
	# Never create an unexpected merge commit from this beginner-facing menu.
	return _run_found(path, ["pull", "--ff-only"])


## Called only after the user confirms replacement of the working tree.
## Fetch and validate before touching local work. Backups are explicitly optional.
static func force_sync(path: String, expected_branch: String, expected_upstream: String, create_backup: bool = false) -> Dictionary:
	var git := ProcessUtils.find_executable(["git"])
	if git.is_empty():
		return {"success": false, "output": "Git is not available on PATH."}
	var info := status(path)
	if not info.success or not info.has_upstream or info.branch == "detached HEAD":
		return {"success": false, "output": "Force sync requires a local branch with a tracked remote branch."}
	if info.branch != expected_branch or info.upstream != expected_upstream:
		return {"success": false, "output": "The branch or upstream changed. Review the repository and confirm again."}
	for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]:
		var location := _run(git, path, ["rev-parse", "--git-path", marker])
		if not location.success:
			return location
		var marker_path := str(location.output)
		if not marker_path.is_absolute_path():
			marker_path = path.path_join(marker_path)
		if FileAccess.file_exists(marker_path) or DirAccess.dir_exists_absolute(marker_path):
			return {"success": false, "output": "Finish or abort the current Git operation before force syncing."}
	var entries := _run(git, path, ["ls-files", "--stage"])
	if not entries.success:
		return entries
	for line in str(entries.output).split("\n"):
		if line.begins_with("160000 "):
			return {"success": false, "output": "Use a Git client to force sync repositories with submodules."}
	var tracking := _run(git, path, ["for-each-ref", "--format=%(upstream:remotename)%09%(upstream:remoteref)", "refs/heads/" + expected_branch])
	var parts := str(tracking.output).split("\t")
	if not tracking.success or parts.size() != 2 or parts[0].is_empty() or parts[0] == "." or not parts[1].begins_with("refs/heads/"):
		return {"success": false, "output": "The upstream must be a branch on a configured remote."}
	var fetched := _run(git, path, ["fetch", "--no-tags", "--", parts[0], parts[1]])
	if not fetched.success:
		return fetched
	var target := _run(git, path, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"])
	if not target.success:
		return target
	# Recheck after the network operation, which may have taken a while.
	var latest := status(path)
	if not latest.success or latest.branch != expected_branch or latest.upstream != expected_upstream:
		return {"success": false, "output": "Repository branch changed during fetch; local files were not replaced."}
	if not create_backup:
		# A single -f preserves nested repositories. Never use -ff here.
		var cleaned := _run(git, path, ["clean", "-fdx"])
		if not cleaned.success:
			return cleaned
		var untracked := _run(git, path, ["ls-files", "--others"])
		if not untracked.success or not str(untracked.output).is_empty():
			return {"success": false, "output": "Some untracked files or nested repositories remain. Cleanup may be partial; the branch was not reset."}
		var branch_now := _run(git, path, ["branch", "--show-current"])
		if not branch_now.success or branch_now.output != expected_branch:
			return {"success": false, "output": "The current branch changed during sync. The branch was not reset."}
		return _run(git, path, ["reset", "--hard", str(target.output)])
	var suffix := "%d-%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	var backup := "modkit-backup/force-sync-" + suffix
	var saved := _run(git, path, ["branch", backup, "HEAD"])
	if not saved.success:
		return saved
	var recovery := "Local commits: " + backup
	var dirty := _run(git, path, ["status", "--porcelain", "--ignored", "--untracked-files=all"])
	if not dirty.success:
		return _with_recovery(dirty, recovery)
	if not str(dirty.output).is_empty():
		var stashed := _run(git, path, ["stash", "push", "--all", "-m", "Modkit force sync " + suffix])
		if not stashed.success:
			return _with_recovery(stashed, recovery + "\nInspect git stash list for any partially completed backup.")
		var stash := _run(git, path, ["rev-parse", "--verify", "refs/stash"])
		if not stash.success:
			return _with_recovery(stash, recovery)
		var stash_ref := "refs/modkit-backups/force-sync-" + suffix
		var pinned := _run(git, path, ["update-ref", stash_ref, str(stash.output)])
		recovery += "\nLocal files: " + stash_ref + " (also in git stash list)"
		if not pinned.success:
			return _with_recovery(pinned, recovery)
	# Nested repositories or files modified by another app must not be erased.
	var remaining := _run(git, path, ["status", "--porcelain", "--ignored", "--untracked-files=all"])
	if not remaining.success or not str(remaining.output).is_empty():
		return _with_recovery({"success": false, "output": "Some files could not be backed up, or changed during sync. Reset was not performed."}, recovery)
	var current_branch := _run(git, path, ["branch", "--show-current"])
	if not current_branch.success or current_branch.output != expected_branch:
		return _with_recovery({"success": false, "output": "The current branch changed during backup. Reset was not performed."}, recovery)
	var reset := _run(git, path, ["reset", "--hard", str(target.output)])
	return _with_recovery(reset, recovery)


static func _with_recovery(result: Dictionary, recovery: String) -> Dictionary:
	result["recovery"] = recovery
	return result


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
		"raw_output": "".join(PackedStringArray(output)),
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
