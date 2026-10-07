class_name GitProjectDialog extends AcceptDialog

signal operation_started
signal operation_finished
signal repository_changed

const ACTION_LABELS := {"force": "Sync", "backup_sync": "Back up and sync",
	"switch_branch": "Switch branch", "create_branch": "Create branch"}

var mutation_guard: Callable
var _mod: ModInfo
var _info: Dictionary = {}
var _jobs := BackgroundJobRunner.new()
var _busy := false
var _summary: Label
var _tracking: Label
var _changes_title: Label
var _changes: RichTextLabel
var _message: LineEdit
var _feedback: Label
var _log: RichTextLabel
var _buttons: Dictionary = {}
var _last_report := ""
var _remote_button: Button
var _copy_button: Button

func setup(mod: ModInfo) -> GitProjectDialog:
	_mod = mod
	return self

func _ready() -> void:
	title = _mod.name + " · Git repository"
	min_size = Vector2i(600, 540)
	unresizable = false
	exclusive = true
	ok_button_text = "Close"
	dialog_hide_on_ok = false
	dialog_close_on_escape = false
	AppTheme.apply_theme(self)
	var outer := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, 16)
	add_child(outer)
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = 540
	content.add_theme_constant_override("separation", 10)
	outer.add_child(content)
	var branch_row := HBoxContainer.new()
	content.add_child(branch_row)
	_summary = _label(branch_row, "Reading repository…")
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_header(_summary)
	_add_button(branch_row, "branches", "Branches…", "Switch branches or create a new branch from your current work")
	_buttons.branches.pressed.connect(_show_branches)
	_tracking = _label(content, "")
	AppTheme.style_muted(_tracking)
	var sync := HBoxContainer.new()
	content.add_child(sync)
	_add_button(sync, "fetch", "Fetch", "Update remote status without changing project files")
	_add_button(sync, "pull", "Pull", "Update local files using fast-forward only")
	_add_button(sync, "push", "Push", "Upload local commits to the tracked remote branch")
	_buttons.fetch.pressed.connect(func() -> void: _run_action("fetch"))
	_buttons.pull.pressed.connect(func() -> void: _run_action("pull"))
	_buttons.push.pressed.connect(func() -> void: _run_action("push"))
	content.add_child(HSeparator.new())
	_changes_title = _label(content, "Local changes")
	AppTheme.style_section(_changes_title)
	_changes = RichTextLabel.new()
	_changes.custom_minimum_size.y = 150
	_changes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_changes.selection_enabled = true
	_changes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_changes)
	var commit_row := HBoxContainer.new()
	content.add_child(commit_row)
	_message = LineEdit.new()
	_message.placeholder_text = "Commit message"
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_row.add_child(_message)
	_add_button(commit_row, "commit", "Commit all", "Stage and commit all tracked changes and new files")
	_buttons.commit.pressed.connect(func() -> void: _run_action("commit"))
	_message.text_submitted.connect(func(_text: String) -> void:
		if not _buttons.commit.disabled:
			_run_action("commit"))
	content.add_child(HSeparator.new())
	var force_row := HBoxContainer.new()
	content.add_child(force_row)
	var force_hint := _label(force_row, "Replace local work with the remote version.")
	force_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AppTheme.style_muted(force_hint)
	_add_button(force_row, "force", "Sync…", "Review sync options and choose whether to back up local work")
	_buttons.force.add_theme_color_override("font_color", AppTheme.BTN_REMOVE)
	_buttons.force.pressed.connect(_confirm_force_sync)
	_feedback = AppTheme.make_status_label("Remote counts reflect the last fetch.")
	_feedback.custom_minimum_size.x = 540
	content.add_child(_feedback)
	_log = RichTextLabel.new()
	_log.custom_minimum_size.y = 85
	_log.selection_enabled = true
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.visible = false
	content.add_child(_log)
	_copy_button = add_button("Copy result", true, "copy")
	_copy_button.tooltip_text = "Copy the last operation output and recovery references"
	add_button("Open folder", false, "folder")
	_remote_button = add_button("Open repository", false, "remote")
	custom_action.connect(func(action: StringName) -> void:
		if action == "copy":
			DisplayServer.clipboard_set(_last_report)
		elif action == "folder":
			ExternalFileLauncher.open(_mod.path)
		elif action == "remote":
			var url := ModGitService.browser_url(str(_info.get("remote_url", "")))
			if not url.is_empty():
				OS.shell_open(url))
	confirmed.connect(_request_close)
	canceled.connect(_request_close)
	_run_action("status")

func _exit_tree() -> void:
	_jobs.wait_to_finish()

func _request_close() -> void:
	if not _busy:
		queue_free()

func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	# Bound wrapping before the first container layout, so the window does not
	# grow to fit a temporary one-character-wide label.
	label.custom_minimum_size.x = 300
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _add_button(parent: Node, key: String, text: String, tip: String) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	parent.add_child(button)
	_buttons[key] = button

func _update_state() -> void:
	_copy_button.disabled = _last_report.is_empty()
	_remote_button.disabled = ModGitService.browser_url(str(_info.get("remote_url", ""))).is_empty()
	for button: Button in _buttons.values():
		button.disabled = _busy or not bool(_info.get("success", false))
	get_ok_button().disabled = _busy
	_message.editable = not _busy
	if _info.is_empty():
		return
	if not _info.success:
		_summary.text = "Git unavailable"
		_tracking.text = str(_info.error)
		return
	_summary.text = str(_info.branch)
	var upstream := str(_info.get("upstream", ""))
	_tracking.text = ("Tracking " + upstream if not upstream.is_empty() else "No upstream · publish this branch to begin syncing")
	_tracking.text += "\n%d outgoing commits · %d incoming commits" % [_info.ahead, _info.behind]
	_changes_title.text = "Local changes · 1 file" if _info.changed == 1 else "Local changes · %d files" % _info.changed
	_changes.text = "\n".join(_info.changes) if _info.changed > 0 else "No uncommitted changes."
	_buttons.commit.disabled = _busy or _info.changed == 0
	_buttons.fetch.disabled = _busy or str(_info.remote_url).is_empty()
	_buttons.pull.disabled = _busy or not _info.has_upstream or _info.changed > 0 or _info.ahead > 0 or _info.behind == 0
	_buttons.pull.tooltip_text = "Fetch first to check for updates. Pull requires a clean working tree and no diverging local commits."
	_buttons.push.disabled = _busy or str(_info.remote_url).is_empty() or _info.branch == "detached HEAD" or _info.behind > 0 or (_info.has_upstream and _info.ahead == 0)
	_buttons.push.text = "Push" if _info.has_upstream else "Publish branch"
	_buttons.force.disabled = _busy or not _info.has_upstream or _info.branch == "detached HEAD"
	if _info.ahead > 0 and _info.behind > 0:
		_tracking.text += "\nBranches have diverged. Merge in a Git client, or sync to keep the remote version."

func _show_branches() -> void:
	var popup := AcceptDialog.new()
	popup.title = "Branches"
	popup.exclusive = true
	popup.ok_button_text = "Close"
	AppTheme.apply_theme(popup)
	var content := VBoxContainer.new()
	content.custom_minimum_size.x = 500
	content.add_theme_constant_override("separation", 12)
	popup.add_child(content)
	_label(content, "Current branch: " + str(_info.branch))
	var select := OptionButton.new()
	select.name = "BranchList"
	select.fit_to_longest_item = false
	select.custom_minimum_size.x = 500
	content.add_child(select)
	for branch: Dictionary in _info.get("branches", []):
		if not branch.remote and branch.name == _info.branch:
			continue
		select.add_item(str(branch.name) + (" (remote)" if branch.remote else ""))
		select.set_item_metadata(select.item_count - 1, branch.ref)
	var switch_button := Button.new()
	switch_button.text = "Switch branch"
	switch_button.disabled = select.item_count == 0 or _info.changed > 0
	content.add_child(switch_button)
	_label(content, "Commit local changes before switching. Creating a new branch keeps your current changes."
		if _info.changed > 0 else "Remote branches create a local tracking branch. Fetch in the Git window to update the list.")
	switch_button.pressed.connect(func() -> void:
		var target := str(select.get_item_metadata(select.selected))
		popup.queue_free()
		_run_action("switch_branch", target))
	content.add_child(HSeparator.new())
	_label(content, "New branch from the current commit")
	var name_input := LineEdit.new()
	name_input.name = "BranchName"
	name_input.placeholder_text = "feature/new-textures"
	content.add_child(name_input)
	var create := Button.new()
	create.text = "Create and switch"
	create.disabled = true
	content.add_child(create)
	name_input.text_changed.connect(func(value: String) -> void: create.disabled = value.strip_edges().is_empty())
	var submit := func() -> void:
		var name := name_input.text.strip_edges()
		if name.is_empty():
			return
		popup.queue_free()
		_run_action("create_branch", name)
	create.pressed.connect(submit)
	name_input.text_submitted.connect(func(_value: String) -> void: submit.call())
	popup.confirmed.connect(popup.queue_free)
	popup.canceled.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered(Vector2i(560, 360))


func _confirm_force_sync() -> void:
	var branch := str(_info.branch)
	var upstream := str(_info.upstream)
	var confirm := ConfirmationDialog.new()
	confirm.title = "Sync from remote"
	confirm.exclusive = true
	AppTheme.apply_theme(confirm)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.custom_minimum_size.x = 540
	content.add_theme_constant_override("separation", 16)
	confirm.add_child(content)
	var description := Label.new()
	description.name = "Description"
	description.custom_minimum_size.x = 540
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(description)
	var backup := CheckBox.new()
	backup.name = "BackupOption"
	backup.text = "Back up local work first"
	backup.button_pressed = false
	content.add_child(backup)
	var update_text := func() -> void:
		var effect := (
			"Local commits will be saved on a backup branch.\n"
			+ "Modified, new, and ignored files will be moved into a recovery stash.\n"
			+ "Those local files will no longer be in the working folder."
		) if backup.button_pressed else (
			"Local-only commits will be removed from this branch.\n"
			+ "Modified files will be replaced; new and ignored files will be deleted.\n"
			+ "No backup branch or stash will be created."
		)
		description.text = ("Replace local branch %s with the latest %s.\n\n%s\n\n"
			+ "The remote repository will not be changed.") % [branch, upstream, effect]
		confirm.ok_button_text = "Back up and sync" if backup.button_pressed else "Discard local work and sync"
	backup.toggled.connect(func(_enabled: bool) -> void: update_text.call())
	update_text.call()
	confirm.confirmed.connect(func() -> void:
		var action := "backup_sync" if backup.button_pressed else "force"
		confirm.queue_free()
		_run_action(action, branch, upstream))
	confirm.canceled.connect(confirm.queue_free)
	add_child(confirm)
	confirm.popup_centered(Vector2i(620, 340))

func _run_action(action: String, branch: String = "", upstream: String = "") -> void:
	if _busy:
		return
	if action == "commit" and _message.text.strip_edges().is_empty():
		AppTheme.set_status_label(_feedback, "Enter a commit message first.", AppTheme.StatusKind.WARNING)
		_message.grab_focus()
		return
	if action in ["pull", "commit", "force", "backup_sync", "switch_branch", "create_branch"] and mutation_guard.is_valid():
		var reason := str(mutation_guard.call())
		if not reason.is_empty():
			AppTheme.set_status_label(_feedback, reason, AppTheme.StatusKind.WARNING)
			return
	_busy = true
	_update_state()
	AppTheme.set_status_label(_feedback, "Running Git · " + str(ACTION_LABELS.get(action, action.capitalize())) + "…", AppTheme.StatusKind.WORKING)
	var path := _mod.path
	var message := _message.text
	var previous := _info.duplicate(true)
	if action != "status":
		operation_started.emit()
	var job := _jobs.run(func() -> Dictionary:
		var result := {"success": true, "output": ""}
		match action:
			"fetch": result = ModGitService.fetch(path)
			"pull": result = ModGitService.pull(path)
			"push": result = ModGitService.push(path, str(previous.branch), bool(previous.has_upstream))
			"commit": result = ModGitService.commit_all(path, message)
			"switch_branch": result = ModGitService.switch_branch(path, branch)
			"create_branch": result = ModGitService.create_branch(path, branch)
			"force", "backup_sync": result = ModGitService.force_sync(path, branch, upstream, action == "backup_sync")
		return {"result": result, "status": ModGitService.status(path)},
		func(payload: Dictionary) -> void: _completed(action, payload))
	if job < 0:
		_completed(action, {"result": {"success": false, "output": "Could not start Git worker."}, "status": previous})

func _completed(action: String, payload: Dictionary) -> void:
	_busy = false
	_info = payload.status
	var result: Dictionary = payload.result
	if action != "status":
		operation_finished.emit()
		_last_report = str(result.get("output", ""))
		if result.has("recovery"):
			_last_report += "\n\nRecovery backup\n" + str(result.recovery)
		_log.text = _last_report
		_log.visible = not _last_report.is_empty()
		AppTheme.set_status_label(_feedback,
			"Completed · " + str(ACTION_LABELS.get(action, action.capitalize())) if result.success else "Git could not complete this action. See the result below.",
			AppTheme.StatusKind.SUCCESS if result.success else AppTheme.StatusKind.ERROR)
		if action == "commit" and result.success:
			_message.clear()
		repository_changed.emit()
	else:
		AppTheme.set_status_label(_feedback, "Remote counts reflect the last fetch. Fetch to check for updates.")
	_update_state()
	if not visible:
		queue_free()
