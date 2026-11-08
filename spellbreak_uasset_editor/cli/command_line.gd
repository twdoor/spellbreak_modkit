class_name ModkitCommandLine extends Node

## Public CLI hosted by the installed application; no external frontend runtime.
static func commands() -> Dictionary:
	var result := {}
	for action in ["inspect", "dump", "validate", "refs", "umg"]:
		result["asset " + action] = _spec(["asset"], [], [], [], "Inspect a cooked package")
	result["asset diff"] = _spec(["asset", "other"], [], [], [], "Compare two packages")
	result["asset patch"] = _spec(["asset", "patch"], ["output"], [], ["dry-run", "overwrite"], "Apply test/replace JSON pointers")
	result["asset clone"] = _spec(["asset"], ["output", "source-root", "mod"], [], [], "Clone identity and register a unique package")
	result["cosmetic clone"] = _spec(["asset"], ["source-root", "mod", "name"], ["display-name"], [], "Clone a cosmetic and editable dependencies")
	for media in ["texture", "sound"]:
		result[media + " export"] = _spec(["asset"], ["output"], [], ["overwrite"], "Export PNG or OGG")
		result[media + " import"] = _spec(["asset", "media"], ["output-dir"], [], ["overwrite"], "Import PNG or OGG into a staged package")
	result["mesh export"] = _spec(["asset"], ["output-dir"], [], [], "Export GLB")
	result["mesh animations"] = _spec(["asset"], [], [], [], "Find candidate animation assets")
	for action in ["create", "validate"]:
		result["mod " + action] = _spec(["mod"], [], [], [], "Create or validate a workspace")
	result["mod pack"] = _spec(["mods..."], ["output"], ["source-root", "game-dir"], ["with-manifest", "overwrite"], "Export mods in merge order with registry support")
	for action in ["list", "test"]:
		result["pak " + action] = _spec(["pak"], [], [], [], "List or test an archive")
	result["pak extract"] = _spec(["pak"], ["output-dir"], [], [], "Extract an archive to a new source directory")
	result["workflow"] = _spec(["request"], [], [], [], "Run localization or a batch recipe request")
	result["search"] = _spec(["root", "query"], [], ["limit"], [], "Search asset filenames without conversion")
	result["doctor"] = _spec([], [], [], [], "Show settings, profile, and bundled tools")
	result["commands"] = _spec([], [], [], [], "Discover the public command schema")
	return result

static func _spec(positional: Array, required: Array, options: Array, flags: Array, description: String) -> Dictionary:
	return {"positional": positional, "required_options": required, "options": options,
		"flags": flags, "description": description}

static func parse(arguments: PackedStringArray) -> Dictionary:
	var args: Array[String] = []
	var as_json := false
	var help := false
	var literal := false
	for argument in arguments:
		if argument == "--":
			literal = true
		if not literal and argument == "--json":
			as_json = true
		elif not literal and argument in ["--help", "-h"]:
			help = true
		else:
			args.append(argument)
	var catalog := commands()
	if args == ["--version"]:
		return {"ok": true, "json": as_json, "version": true}
	if args.is_empty():
		return {"ok": true, "json": as_json, "help": help_text("")}
	var command_name: String = args.pop_front()
	if not catalog.has(command_name) and not args.is_empty() and catalog.has(command_name + " " + args[0]):
		command_name += " " + args.pop_front()
	if help:
		var known := catalog.has(command_name)
		for command in catalog:
			known = known or str(command).begins_with(command_name + " ")
		if known:
			return {"ok": true, "json": as_json, "help": help_text(command_name)}
	if not catalog.has(command_name):
		return _error("Unknown command: " + command_name + ". Use --help.", as_json)
	var spec: Dictionary = catalog[command_name]
	var request := {"group": command_name.get_slice(" ", 0)}
	if command_name.contains(" "):
		request.action = command_name.get_slice(" ", 1)
	var values: Array[String] = []
	var seen := {}
	literal = false
	while not args.is_empty():
		var arg: String = args.pop_front()
		if not literal and arg == "--":
			literal = true
			continue
		if not literal and arg.begins_with("-"):
			var option := arg.get_slice("=", 0).trim_prefix("--")
			if not arg.begins_with("--") or option not in spec.required_options + spec.options + spec.flags:
				return _error("Unknown option for " + command_name + ": " + arg, as_json)
			if seen.has(option):
				return _error("Repeated option: --" + option, as_json)
			seen[option] = true
			var key := option.replace("-", "_")
			if option in spec.flags:
				if arg.contains("="):
					return _error("Flag does not take a value: --" + option, as_json)
				request[key] = true
			else:
				if not arg.contains("=") and (args.is_empty() or args[0].begins_with("--")):
					return _error("Missing value for --" + option, as_json)
				request[key] = arg.substr(arg.find("=") + 1) if arg.contains("=") else args.pop_front()
				if str(request[key]).is_empty():
					return _error("Empty value for --" + option, as_json)
		else:
			values.append(arg)
	for required in spec.required_options:
		if not seen.has(required):
			return _error("Missing --" + str(required), as_json)
	if spec.positional == ["mods..."]:
		if values.is_empty():
			return _error("Supply at least one mod workspace", as_json)
		request.mods = values.map(func(path: String) -> String: return absolute(path))
	elif values.size() != spec.positional.size():
		return _error("Expected arguments: " + " ".join(spec.positional), as_json)
	else:
		for i in values.size():
			request[spec.positional[i]] = values[i]
	for key in ["asset", "other", "patch", "output", "source_root", "mod", "media", "output_dir", "game_dir", "pak", "request", "root"]:
		if request.has(key):
			request[key] = absolute(str(request[key]))
	if command_name == "search":
		var limit := str(request.get("limit", "100"))
		if not limit.is_valid_int() or int(limit) < 1:
			return _error("--limit must be a positive integer", as_json)
		request.limit = int(limit)
	return {"ok": true, "json": as_json, "request": request}

static func absolute(path: String) -> String:
	if path == "~" or path.begins_with("~/"):
		var home := OS.get_environment("USERPROFILE") if OS.get_name() == "Windows" else OS.get_environment("HOME")
		path = home + path.substr(1)
	if path.is_absolute_path():
		return path.simplify_path()
	# Relative Godot filesystem paths resolve against the project, not the caller.
	# Launchers capture the terminal directory before starting the application.
	var caller_dir := OS.get_environment("SPELLBREAK_MODKIT_CLI_CWD")
	if caller_dir.is_empty() and OS.get_name() != "Windows":
		caller_dir = OS.get_environment("PWD")
	if not caller_dir.is_absolute_path():
		caller_dir = DirAccess.open(".").get_current_dir()
	return caller_dir.path_join(path).simplify_path()

static func _error(message: String, as_json: bool) -> Dictionary:
	return {"ok": false, "json": as_json, "message": message}

static func help_text(prefix: String) -> String:
	var lines: Array[String] = ["Spellbreak Modkit CLI", "Usage: modkit [--json] <command> [arguments]", ""]
	for command_name: String in commands():
		if not prefix.is_empty() and command_name != prefix and not command_name.begins_with(prefix + " "):
			continue
		var spec: Dictionary = commands()[command_name]
		var usage := command_name
		for arg in spec.positional:
			usage += " " + str(arg).to_upper()
		for option in spec.required_options:
			usage += " --" + str(option) + " VALUE"
		for option in spec.options:
			usage += " [--" + str(option) + " VALUE]"
		for flag in spec.flags:
			usage += " [--" + str(flag) + "]"
		lines.append("  " + usage + "\n    " + str(spec.description))
	lines.append("\nOptions: --json, --help, --version. Paths are relative to your current directory.")
	return "\n".join(lines)

func run(arguments: PackedStringArray) -> void:
	var parsed := parse(arguments)
	if not parsed.ok:
		_finish(OperationResult.failed(parsed.message), parsed.json, 2)
		return
	if parsed.has("help") or parsed.has("version"):
		_finish(OperationResult.succeeded(parsed.get("help", "Spellbreak Modkit " + str(ProjectSettings.get_setting("application/config/version")))), parsed.json)
		return
	var request: Dictionary = parsed.request
	if request.group == "commands":
		_finish(OperationResult.succeeded("Public commands", commands()), parsed.json)
		return
	if request.group == "search":
		_finish(_search(request), parsed.json)
		return
	if request.group == "workflow" or (request.group == "asset" and request.action == "patch"):
		var path := str(request.request if request.group == "workflow" else request.patch)
		var loaded := _read_json(path)
		if not loaded.ok:
			_finish(loaded, parsed.json)
			return
		if request.group == "workflow":
			if not loaded.value is Dictionary:
				_finish(OperationResult.failed("Workflow request must be an object"), parsed.json)
				return
			request.workflow = loaded.value
			for key in ["mod", "source"]:
				if request.workflow.has(key):
					request.workflow[key] = absolute(str(request.workflow[key]))
		else:
			if not loaded.value is Array or loaded.value.is_empty():
				_finish(OperationResult.failed("Patch must be a nonempty array"), parsed.json)
				return
			request.operations = loaded.value
	var runner := ModkitCli.new()
	add_child(runner)
	var result := await runner.execute(request)
	_finish(result, parsed.json)

func _finish(result: OperationResult, as_json: bool, failure_code: int = 1) -> void:
	if as_json:
		print(JSON.stringify({"schema_version": 1, "ok": result.ok, "message": result.message,
			"value": result.value, "metadata": result.metadata, "backups": result.backups, "logs": Array(result.logs)}))
	else:
		if result.ok:
			print(result.message)
		else:
			printerr(result.message)
		if result.value != null:
			print(JSON.stringify(result.value, "  "))
	get_tree().quit(0 if result.ok else failure_code)

static func _read_json(path: String) -> OperationResult:
	if not FileAccess.file_exists(path):
		return OperationResult.failed("File does not exist: " + path)
	var content := FileAccess.get_file_as_string(path)
	var precision := ModkitCli.json_precision_error(content)
	if not precision.is_empty():
		return OperationResult.failed(precision)
	var json := JSON.new()
	if json.parse(content) != OK:
		return OperationResult.failed("Invalid JSON: " + json.get_error_message())
	return OperationResult.succeeded("", json.data)

static func _search(request: Dictionary) -> OperationResult:
	if not DirAccess.dir_exists_absolute(request.root):
		return OperationResult.failed("Search root does not exist")
	var found: Array = []
	var pending: Array[String] = [request.root]
	while not pending.is_empty() and found.size() <= int(request.limit):
		var folder: String = pending.pop_back()
		var dir := DirAccess.open(folder)
		if dir == null:
			return OperationResult.failed("Cannot read directory: " + str(folder))
		var files := dir.get_files()
		files.sort()
		for file in files:
			var path: String = str(folder).path_join(file)
			var relative := path.trim_prefix(str(request.root).trim_suffix("/") + "/")
			if file.get_extension().to_lower() in ["uasset", "umap"] and relative.to_lower().contains(str(request.query).to_lower()):
				found.append({"path": path, "relative": relative, "source_root": request.root})
				if found.size() > int(request.limit):
					break
		var directories := dir.get_directories()
		directories.sort()
		directories.reverse()
		for child in directories:
			if not child.begins_with(".") and not dir.is_link(child):
				pending.append(str(folder).path_join(child))
	return OperationResult.succeeded("Found %d assets" % mini(found.size(), request.limit),
		{"assets": found.slice(0, request.limit), "truncated": found.size() > int(request.limit)})
