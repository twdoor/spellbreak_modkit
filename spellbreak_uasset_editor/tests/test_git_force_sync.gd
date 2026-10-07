extends SceneTree

var git := ""
var root_path := ""

func _initialize() -> void:
	_run.call_deferred()

func command(path: String, args: Array) -> Dictionary:
	return ModGitService._run(git, path, args)

func must(path: String, args: Array) -> String:
	var result := command(path, args)
	assert(result.success, str(args) + ": " + str(result.output))
	return str(result.output)

func write(path: String, value: String) -> void:
	assert(FileUtils.write_bytes_atomic(path, value.to_utf8_buffer()) == OK)

func _run() -> void:
	git = ProcessUtils.find_executable(["git"])
	assert(not git.is_empty())
	root_path = OS.get_temp_dir().path_join("sb git sync %d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_path)
	must(root_path, ["init", "--bare", "remote.git"])
	must(root_path, ["clone", "remote.git", "author"])
	var author := root_path.path_join("author")
	must(author, ["config", "user.name", "Test"])
	must(author, ["config", "user.email", "test@example.invalid"])
	must(author, ["checkout", "-b", "main"])
	write(author.path_join("README.md"), "base")
	write(author.path_join(".gitignore"), "*.cache\n")
	must(author, ["add", "--all"])
	must(author, ["commit", "-m", "base"])
	must(author, ["push", "-u", "origin", "main"])
	must(root_path, ["clone", "-b", "main", "remote.git", "local"])
	var local := root_path.path_join("local")
	must(local, ["config", "user.name", "Test"])
	must(local, ["config", "user.email", "test@example.invalid"])
	# Test a non-origin remote and an explicitly tracked branch.
	must(local, ["remote", "rename", "origin", "team"])
	# Branch creation carries work forward; switching requires committed changes.
	write(local.path_join("README.md"), "branch work")
	assert(not ModGitService.switch_branch(local, "refs/remotes/team/main").success)
	assert(ModGitService.create_branch(local, "feature/textures").success)
	assert(ModGitService.status(local).branch == "feature/textures")
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "branch work")
	assert(not ModGitService.create_branch(local, "feature/textures").success)
	for invalid in ["--force", "bad name", "@{-1}", "HEAD", "foo..bar"]:
		assert(not ModGitService.create_branch(local, invalid).success)
	must(local, ["restore", "README.md"])
	assert(ModGitService.switch_branch(local, "refs/heads/main").success)
	assert(not ModGitService.switch_branch(local, "refs/heads/missing").success)
	# Remote checkout creates tracking automatically, including on non-origin remotes.
	must(author, ["switch", "-c", "feature/team-textures"])
	write(author.path_join("protected.cache"), "remote content")
	must(author, ["add", "-f", "protected.cache"])
	must(author, ["commit", "-m", "remote branch"])
	must(author, ["push", "-u", "origin", "feature/team-textures"])
	assert(ModGitService.fetch(local).success)
	write(local.path_join("protected.cache"), "local ignored data")
	assert(not ModGitService.switch_branch(local, "refs/remotes/team/feature/team-textures").success)
	assert(FileAccess.get_file_as_string(local.path_join("protected.cache")) == "local ignored data")
	DirAccess.remove_absolute(local.path_join("protected.cache"))
	assert(ModGitService.switch_branch(local, "refs/remotes/team/feature/team-textures").success)
	assert(ModGitService.status(local).upstream == "team/feature/team-textures")
	assert(ModGitService.switch_branch(local, "refs/heads/main").success)
	must(author, ["switch", "main"])
	write(local.path_join("README.md"), "local commit")
	must(local, ["commit", "-am", "local work"])
	var old_head := must(local, ["rev-parse", "HEAD"])
	write(author.path_join("README.md"), "remote update")
	must(author, ["commit", "-am", "remote work"])
	must(author, ["push"])
	var remote_head := must(author, ["rev-parse", "HEAD"])
	write(local.path_join("README.md"), "staged work")
	must(local, ["add", "README.md"])
	write(local.path_join("README.md"), "unstaged work")
	write(local.path_join("new file.txt"), "new work")
	write(local.path_join("generated.cache"), "ignored work")
	assert("Changed: README.md" in ModGitService.status(local).changes, "Preserve first character of modified paths")
	var refused := ModGitService.force_sync(local, "wrong-branch", "team/main")
	assert(not refused.success)
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "unstaged work")
	var result := ModGitService.force_sync(local, "main", "team/main", true)
	assert(result.success, str(result))
	assert(result.has("recovery"))
	assert(must(local, ["rev-parse", "HEAD"]) == remote_head)
	assert(ModGitService.status(local).changed == 0)
	assert(not FileAccess.file_exists(local.path_join("generated.cache")))
	var backup := must(local, ["for-each-ref", "--format=%(refname:short)", "refs/heads/modkit-backup/"])
	assert(must(local, ["rev-parse", backup]) == old_head)
	var stash := must(local, ["for-each-ref", "--format=%(refname)", "refs/modkit-backups/"])
	must(local, ["stash", "drop"])
	must(local, ["switch", backup])
	must(local, ["stash", "apply", "--index", stash])
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "unstaged work")
	assert(must(local, ["show", ":README.md"]) == "staged work")
	assert(FileAccess.get_file_as_string(local.path_join("new file.txt")) == "new work")
	assert(FileAccess.get_file_as_string(local.path_join("generated.cache")) == "ignored work")
	assert(not ModGitService.force_sync(local, backup, "").success, "No-upstream branches are rejected")
	# Remote failure must leave local files untouched (before any stash or reset).
	must(local, ["branch", "--set-upstream-to=team/main", backup])
	must(local, ["remote", "set-url", "team", root_path.path_join("missing.git")])
	assert(not ModGitService.force_sync(local, backup, "team/main").success)
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "unstaged work")
	must(local, ["remote", "set-url", "team", root_path.path_join("remote.git")])
	write(local.path_join(".git/MERGE_HEAD"), remote_head + "\n")
	assert(not ModGitService.force_sync(local, backup, "team/main").success, "In-progress merges are refused")
	DirAccess.remove_absolute(local.path_join(".git/MERGE_HEAD"))
	must(local, ["checkout", "--detach"])
	assert(not ModGitService.force_sync(local, "detached HEAD", "team/main").success)
	must(local, ["switch", backup])
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "unstaged work")
	# Sync without backup discards local state without adding any recovery refs.
	var backup_refs := must(local, ["for-each-ref", "--format=%(refname)", "refs/heads/modkit-backup/", "refs/modkit-backups/", "refs/stash"])
	var plain := ModGitService.force_sync(local, backup, "team/main", false)
	assert(plain.success, str(plain))
	assert(not plain.has("recovery"))
	assert(must(local, ["rev-parse", "HEAD"]) == remote_head)
	assert(FileAccess.get_file_as_string(local.path_join("README.md")) == "remote update")
	assert(not FileAccess.file_exists(local.path_join("new file.txt")))
	assert(not FileAccess.file_exists(local.path_join("generated.cache")))
	assert(must(local, ["for-each-ref", "--format=%(refname)", "refs/heads/modkit-backup/", "refs/modkit-backups/", "refs/stash"]) == backup_refs)
	write(local.path_join("README.md"), "display change")
	# Exercise the replacement dialog without issuing any network action.
	var dialog := GitProjectDialog.new().setup(ModInfo.new("Test project", local))
	root.add_child(dialog)
	dialog.popup_centered(Vector2i(780, 680))
	while dialog._busy:
		await process_frame
	assert(dialog.size.y <= 800, "Dialog must not grow excessively during initial text wrapping")
	assert(dialog._changes.text.contains("README.md"))
	assert(not dialog._buttons.force.disabled)
	assert(not dialog._buttons.has("backup_sync"), "Only one sync button belongs in the main window")
	dialog._confirm_force_sync()
	var confirmation: ConfirmationDialog
	for child in dialog.get_children():
		if child is ConfirmationDialog:
			confirmation = child
	assert(confirmation != null)
	var backup_option := confirmation.get_node("Content/BackupOption") as CheckBox
	var description := confirmation.get_node("Content/Description") as Label
	assert(not backup_option.button_pressed, "Backups are opt-in")
	assert("No backup branch or stash" in description.text)
	backup_option.button_pressed = true
	assert("recovery stash" in description.text)
	assert(confirmation.ok_button_text == "Back up and sync")
	backup_option.button_pressed = false
	assert("No backup branch or stash" in description.text)
	assert(confirmation.ok_button_text == "Discard local work and sync")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		dialog.get_texture().get_image().save_png(args[0])
		confirmation.get_texture().get_image().save_png(args[0].get_basename() + "-popup.png")
	confirmation.queue_free()
	await process_frame
	dialog._show_branches()
	await process_frame
	var branches_popup: AcceptDialog
	for child in dialog.get_children():
		if child is AcceptDialog:
			branches_popup = child
	assert(branches_popup != null)
	var selector := branches_popup.find_child("BranchList", true, false) as OptionButton
	assert(selector != null and selector.item_count > 0)
	assert(branches_popup.size.y <= 500, "Branch popup stays compact")
	if not args.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		branches_popup.get_texture().get_image().save_png(args[0].get_basename() + "-branches.png")
	dialog.queue_free()
	await process_frame
	FileUtils.remove_dir_recursive(root_path)
	print("PASS: branches, force sync, recovery, fetch failure, Git dialog")
	quit()
