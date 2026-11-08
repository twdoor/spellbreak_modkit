extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	var native := ModkitCommandLine.parse(["--json", "asset", "patch", "input.uasset", "patch.json", "--output=out.uasset", "--dry-run"])
	_check(native.ok and native.json and native.request.dry_run, "native flags and option values")
	_check(native.request.output.is_absolute_path(), "native output resolves to an absolute path")
	var literal := ModkitCommandLine.parse(["search", ".", "--", "--json"])
	_check(literal.ok and not literal.json and literal.request.query == "--json", "literal option-like positional")
	_check(not ModkitCommandLine.parse(["asset", "dump"]).ok, "native missing positional rejected")
	_check(not ModkitCommandLine.parse(["doctor", "--overwrite"]).ok, "native unrelated flag rejected")
	_check(not ModkitCommandLine.parse(["search", ".", "x", "--limit=0"]).ok, "native bad limit rejected")
	var exporter := preload("res://addons/cli_export/launcher_export.gd")
	var batch := exporter.windows_launcher("sbue.exe")
	_check(batch.contains("%~dp0sbue.console.exe") and batch.contains("cli %*") and batch.contains("exit /b %errorlevel%"), "Windows launcher preserves console output, arguments and exit status")
	var data := {"Exports": [{"Data": [{"Value": 4, "$type": "TypedProperty"}]}], "a/b": {"~key": 7}}
	var result := ModkitCli.apply_patch(data, [
		{"op": "test", "path": "/Exports/0/Data/0/Value", "value": 4},
		{"op": "replace", "path": "/Exports/0/Data/0/Value", "value": 9},
		{"op": "replace", "path": "/a~1b/~0key", "value": 8}])
	_check(result.ok, "valid escaped pointer patch")
	_check(result.value.Exports[0].Data[0].Value == 9, "nested value updated")
	_check(result.value["a/b"]["~key"] == 8, "escaped keys updated")
	_check(data.Exports[0].Data[0].Value == 4, "baseline unchanged")
	_check(result.value.Exports[0].Data[0]["$type"] == "TypedProperty", "serializer type retained")
	for pointer in ["/Exports/-1", "/Exports/01", "/Exports/2", "/missing", "/a~2b", ""]:
		_check(not ModkitCli.apply_patch(data, [{"op": "replace", "path": pointer, "value": 1}]).ok,
			"invalid pointer rejected: " + pointer)
	_check(not ModkitCli.apply_patch(data, [{"op": "test", "path": "/a~1b/~0key", "value": 42}]).ok,
		"failed precondition rejected")
	for failure in failures:
		printerr("FAIL: " + failure)
	if failures.is_empty():
		print("PASS: CLI patch tests")
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
