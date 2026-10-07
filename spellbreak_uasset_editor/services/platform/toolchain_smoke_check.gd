class_name ToolchainSmokeCheck extends RefCounted

var failures: Array[String] = []

func run(texture_path: String = "") -> PackedStringArray:
	failures.clear()
	# Exercise the exact subprocess paths used in releases with PATH disabled.
	OS.set_environment("PATH", "")
	OS.set_environment("PYTHONHOME", "/invalid-system-python")
	OS.set_environment("PYTHONPATH", "/invalid-system-python")
	var python := ProcessUtils.find_python()
	var dotnet := ProcessUtils.find_dotnet()
	var umodel := BundledRuntime.executable("umodel")
	check(not python.is_empty() and python.contains("runtimes"), "Bundled Python selected")
	check(not dotnet.is_empty() and dotnet.contains("runtimes"), "Bundled .NET selected")
	check(not umodel.is_empty(), "Bundled umodel selected")
	if python.is_empty() or dotnet.is_empty() or umodel.is_empty():
		return PackedStringArray(failures)
	var output: Array = []
	check(OS.execute(python, ["-I", "-c", "import ctypes,zlib,json,ssl; print('ok')"], output, true) == 0,
		"Python native standard-library modules load")
	output.clear()
	check(OS.execute(dotnet, [ToolchainRegistry.converter_dll()], output, true) in [0, 1],
		"Converter launches without installed .NET: " + ProcessUtils.output_text(output))
	output.clear()
	check(OS.execute(umodel, ["-help"], output, true) == 0, "umodel launches")
	output.clear()
	var script := ToolchainRegistry.dds_tools_script()
	check(ProcessUtils.run_python_script(python, script, script.get_base_dir(), ["--help"], output) == 0,
		"Texture tool starts with private Python: " + ProcessUtils.output_text(output))
	output.clear()
	var pak_script := ToolchainRegistry.u4pak_script()
	check(ProcessUtils.run_python_script(python, pak_script, pak_script.get_base_dir(), ["--help"], output) == 0,
		"Pak tool starts with private Python: " + ProcessUtils.output_text(output))
	if not texture_path.is_empty():
		var fixture := FileUtils.make_temp_dir("sb-smoke-input")
		if not fixture.get("ok", false):
			failures.append("Could not stage input texture")
			return PackedStringArray(failures)
		var staged_texture := str(fixture.path).path_join(texture_path.get_file())
		for extension in ["uasset", "uexp", "ubulk", "uptnl"]:
			var source: String = texture_path.get_basename() + "." + extension
			if FileAccess.file_exists(source):
				check(DirAccess.copy_absolute(source, staged_texture.get_basename() + "." + extension) == OK,
					"Stage texture companion: " + extension)
		var config := ModConfigManager.new()
		var texture := TextureService.new().setup(config)
		var result := texture.get_preview_result(staged_texture)
		check(result.ok, "Real texture preview: " + result.message)
		check(UAssetFile.load_file(staged_texture) != null, "Real asset parsing using bundled .NET")
		if result.ok:
			var tmp := FileUtils.make_temp_dir("sb-smoke-texture")
			check(tmp.get("ok", false), "Create disposable import workspace")
			if tmp.get("ok", false):
				var root := str(tmp.path)
				var png := root.path_join("image.png")
				(result.value as Image).save_png(png)
				var imported := texture._do_inject_png(staged_texture, png, root.path_join("injected"))
				check(imported.ok, "Real texture import: " + imported.message)
				if imported.ok:
					var asset := root.path_join("injected").path_join(texture_path.get_file())
					var files_before := DirAccess.get_files_at(asset.get_base_dir())
					var replaced := texture._do_inject_png(asset, png, asset.get_base_dir())
					check(replaced.ok, "Replace existing texture: " + replaced.message)
					check(DirAccess.get_files_at(asset.get_base_dir()) == files_before,
						"Replacing a texture leaves no backup or staging files")
					check(texture.get_preview_result(asset).ok, "Re-export imported texture")
					check(UAssetFile.load_file(asset) != null, "Reparse imported texture")
				FileUtils.remove_dir_recursive(root)
		FileUtils.remove_dir_recursive(str(fixture.path))
	return PackedStringArray(failures)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
