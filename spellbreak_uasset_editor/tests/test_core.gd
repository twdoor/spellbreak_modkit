extends SceneTree

var _failures: Array[String] = []


func _init() -> void:
	_run()
	if _failures.is_empty():
		print("PASS: core regression tests")
		quit(0)
	else:
		for failure in _failures:
			printerr("FAIL: " + failure)
		quit(1)


func _run() -> void:
	_test_export_insert()
	_test_export_remove()
	_test_import_insert_remove()
	_test_swap_and_snapshot_restore()
	_test_asset_document_history()
	_test_clipboard_rejects_unsupported_copy()
	_test_clipboard_datatable_row_targets_current_table()
	_test_clipboard_datatable_row_pastes_into_empty_table()
	_test_clipboard_export_cross_file_remaps_imports()
	_test_clipboard_export_group_preserves_internal_refs()
	_test_property_state_restore()
	_test_byte_enum_property_round_trip()
	_test_asset_diff_engine()
	_test_asset_diff_tab_layout()
	_test_linear_color_property_editor()
	_test_mesh_preview_materials()
	_test_glb_export()
	_test_md5_animation_loader()
	_test_animation_candidate_discovery()
	_test_mesh_preview_environment()
	_test_mesh_animation_controls_build()
	_test_texture_injection_preserves_companions()
	_test_texture_companion_recovery()
	_test_background_job_shutdown()
	_test_file_watcher_rapid_toggle()
	_test_atomic_file_install()
	_test_mod_manifest()
	_test_mod_preflight()
	_test_uasset_save_validation()
	_test_path_safety()
	_test_process_arguments()
	_test_update_version_compare()
	_test_keymap_config_rebinds_loaded_resources()
	_test_keymap_migration_user_binding_wins_new_defaults()
	_test_guide_remap_rebuilds_default_active_mapping()
	_test_base_source_generation()
	_test_packing_transaction()


func _test_export_insert() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	var first_import := asset.imports[0]
	var added := [
		_make_export("AddedA", 2, -2, 3, [2, 3, -2], 3),
		_make_export("AddedB", 2, -2, 3, [2, 3, -2], 3),
	]
	asset.insert_exports(1, added)

	_expect(asset.exports.size() == 5, "bulk export insert changes table size")
	_expect(first.outer_index == 4, "existing export positive metadata shifts by insert count")
	_expect(first.class_index == -2, "export insert leaves import references unchanged")
	_expect(_object_value(first) == 5, "existing ObjectProperty reference shifts")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [4, 5, -2],
		"existing dependency references shift")
	_expect(added[0].outer_index == 4 and _object_value(added[0]) == 5,
		"new exports are remapped from the pre-insert coordinate system")
	_expect(first_import.outer_index == 4, "import outer export reference shifts")


func _test_export_remove() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	asset.imports[0].outer_index = 3
	asset.imports[0].raw["OuterIndex"] = 3
	asset.remove_export_at(1)

	_expect(asset.exports.size() == 2, "export removal changes table size")
	_expect(first.outer_index == 0, "references to a deleted export are cleared")
	_expect(_object_value(first) == 2, "references after a deleted export shift down")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [2, -2],
		"deleted dependencies are removed and later dependencies shift")
	_expect(asset.imports[0].outer_index == 2, "import outer reference shifts after export removal")


func _test_import_insert_remove() -> void:
	var asset := _make_asset()
	var first := asset.exports[0]
	var added := [
		_make_import("AddedA", -2),
		_make_import("AddedB", -3),
	]
	asset.insert_imports(1, added)

	_expect(first.class_index == -4, "existing import reference shifts by bulk insert count")
	_expect(added[0].outer_index == -4, "new import references use pre-insert coordinates")
	_expect(asset.imports[1].super_index == -2 and asset.imports[2].super_index == -3,
		"display indices are synchronized after import insertion")

	asset = _make_asset()
	first = asset.exports[0]
	first.class_index = -2
	first.template_index = -3
	first.raw["ClassIndex"] = -2
	first.raw["TemplateIndex"] = -3
	first.properties[0].value = -2
	first.properties[0].raw["Value"] = -2
	first.raw["CreateBeforeCreateDependencies"] = [-2, -3, 1]
	asset.remove_import_at(1)

	_expect(first.class_index == 0 and _object_value(first) == 0,
		"references to a deleted import are cleared")
	_expect(first.template_index == -2, "later import references shift toward zero")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [-2, 1],
		"import dependency references are remapped")


func _test_update_version_compare() -> void:
	_expect(UpdateChecker.is_newer_version("v0.10.0", "0.9.0"),
		"update checker treats 0.10.0 as newer than 0.9.0")
	_expect(UpdateChecker.is_newer_version("release-1.0.0", "0.9.9"),
		"update checker extracts versions from release tags")
	_expect(not UpdateChecker.is_newer_version("v0.9.0", "0.9.0"),
		"update checker ignores matching versions")
	_expect(not UpdateChecker.is_newer_version("v0.8.9", "0.9.0"),
		"update checker ignores older releases")
	_expect(UpdateChecker.normalize_version("v0.10.0") == "0.10.0",
		"update checker normalizes v-prefixed tags")


func _test_keymap_config_rebinds_loaded_resources() -> void:
	var current_mapping := _load_test_mapping_context()
	var loaded_mapping := _load_test_mapping_context()
	var loaded_open := _find_test_action(loaded_mapping, "res://guide/open.tres")
	var current_open := _find_test_action(current_mapping, "res://guide/open.tres")
	var input := _make_key_input(KEY_L, true)

	var saved_config := GUIDERemappingConfig.new()
	saved_config._bind(loaded_mapping, loaded_open, input, 0)

	var normalized := KeymapSettingsTab.normalize_config_for_mapping(saved_config, current_mapping)
	var rebound := normalized._get_bound_input_or_null(current_mapping, current_open, 0)
	_expect(rebound != null and rebound.is_same_as(input),
		"keymap migration rebinds saved resource keys to the active mapping")


func _test_keymap_migration_user_binding_wins_new_defaults() -> void:
	var mapping := _load_test_mapping_context()
	var open_action := _find_test_action(mapping, "res://guide/open.tres")
	var compare_action := _find_test_action(mapping, "res://guide/compare.tres")
	var input := _make_key_input(KEY_K, true)

	var saved_config := GUIDERemappingConfig.new()
	saved_config._bind(mapping, open_action, input, 0)

	var normalized := KeymapSettingsTab.normalize_config_for_mapping(saved_config, mapping)
	var open_input := normalized._get_bound_input_or_null(mapping, open_action, 0)
	_expect(open_input != null and open_input.is_same_as(input),
		"keymap migration preserves the user's explicit binding")
	_expect(normalized._has(mapping, compare_action, 0)
			and normalized._get_bound_input_or_null(mapping, compare_action, 0) == null,
		"keymap migration clears a new default shortcut that collides with a saved user binding")


func _test_guide_remap_rebuilds_default_active_mapping() -> void:
	var guide_script: Script = load("res://addons/guide/guide.gd")
	var reset_script: Script = load("res://addons/guide/guide_reset.gd")
	var guide = guide_script.new()
	guide._input_state = GUIDEInputState.new()
	guide._input_state._reset()
	guide._reset_node = reset_script.new()
	guide._reset_node.guide = guide

	var mapping := _load_test_mapping_context()
	var open_action := _find_test_action(mapping, "res://guide/open.tres")
	var save_action := _find_test_action(mapping, "res://guide/save.tres")
	var open_default := _default_input_for_action(mapping, open_action, 0)

	guide.enable_mapping_context(mapping)

	var remap := GUIDERemappingConfig.new()
	remap._bind(mapping, open_action, null, 0)
	remap._bind(mapping, save_action, open_default, 0)
	guide.set_remapping_config(remap)

	var active_open := _active_input_for_action(guide, open_action, 0)
	var active_save := _active_input_for_action(guide, save_action, 0)
	_expect(active_open == null,
		"GUIDE remapping can explicitly unbind the first default action slot")
	_expect(active_save != null and active_save.is_same_as(open_default),
		"GUIDE remapping applies a new binding over an existing default action mapping")

	guide.free()


func _test_swap_and_snapshot_restore() -> void:
	var asset := _make_asset()
	var snapshot := asset.capture_package_tables()
	var first := asset.exports[0]
	asset.swap_exports(1, 2)
	_expect(first.outer_index == 3 and _object_value(first) == 2,
		"export swap remaps metadata and ObjectProperty references")
	_expect(first.raw["CreateBeforeCreateDependencies"] == [3, 2, -2],
		"export swap remaps dependencies")

	asset.remove_export_at(1)
	asset.remove_import_at(0)
	asset.restore_package_tables(snapshot)
	_expect(asset.exports.size() == 3 and asset.imports.size() == 3,
		"package table snapshot restores table sizes")
	_expect(asset.exports[0].outer_index == 2 and _object_value(asset.exports[0]) == 3,
		"package table snapshot restores exact references")


func _test_asset_document_history() -> void:
	var asset := _make_asset()
	var document := AssetDocument.new(asset)
	var state := {"value": 1}
	var first := AssetEditCommand.new("Set two",
		func() -> void: state["value"] = 2,
		func() -> void: state["value"] = 1)
	_expect(document.execute(first) and state["value"] == 2, "document executes commands")
	_expect(document.is_dirty() and document.can_undo(), "executed command marks document dirty")
	document.mark_saved()
	_expect(not document.is_dirty(), "mark_saved establishes a clean history position")

	var second := AssetEditCommand.new("Set three",
		func() -> void: state["value"] = 3,
		func() -> void: state["value"] = 2)
	document.execute(second)
	_expect(state["value"] == 3 and document.is_dirty(), "later commands move beyond the save point")
	_expect(document.undo() and state["value"] == 2 and not document.is_dirty(),
		"undo returns to the saved state")
	_expect(document.redo() and state["value"] == 3 and document.is_dirty(), "redo reapplies a command")

	document.undo()
	document.undo()
	var branch := AssetEditCommand.new("Set four",
		func() -> void: state["value"] = 4,
		func() -> void: state["value"] = 1)
	document.execute(branch)
	_expect(state["value"] == 4 and not document.can_redo(), "new edits discard the redo branch")
	_expect(document.is_dirty(), "discarding the saved branch keeps the document dirty")


func _test_clipboard_rejects_unsupported_copy() -> void:
	var asset := _make_asset()
	var copied := ClipboardManager.copy(asset.exports[0], asset, [asset.exports[0]])
	_expect(bool(copied.get("ok", false)), "clipboard accepts a normal export copy")

	var rejected := ClipboardManager.copy([], asset, [])
	_expect(not bool(rejected.get("ok", true)),
		"clipboard rejects unsupported copy targets")
	_expect(ClipboardManager.is_empty(),
		"clipboard clears stale data after an unsupported copy")


func _test_clipboard_datatable_row_targets_current_table() -> void:
	var source := _make_empty_asset("res://source_table.uasset")
	var source_rows := [_make_datatable_row_raw("SourceRow", 11)]
	var source_table := _make_datatable_export("SourceTable", source_rows)
	source.exports = [source_table]

	var target := _make_empty_asset("res://target_table.uasset")
	var target_rows := [_make_datatable_row_raw("TargetRow", 22)]
	var target_table := _make_datatable_export("TargetTable", target_rows)
	target.exports = [target_table]

	var source_row := UAssetProperty.from_dict(source_rows[0])
	var copy_result := ClipboardManager.copy({"dt_row": source_row, "expo": source_table}, source, [])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts data table row copy")

	var target_row := UAssetProperty.from_dict(target_rows[0])
	ClipboardManager.paste(_make_clipboard_context(target),
		{"dt_row": target_row, "expo": target_table}, [], null)

	var copied_target_rows := target_table.get_datatable_rows()
	_expect(source_table.get_datatable_rows().size() == 1,
		"data table row paste leaves the source table unchanged")
	_expect(copied_target_rows.size() == 2
			and str((copied_target_rows[1] as Dictionary).get("Name")) == "SourceRow_Copy",
			"data table row paste inserts into the current target table")


func _test_clipboard_datatable_row_pastes_into_empty_table() -> void:
	var source := _make_empty_asset("res://source_empty_table.uasset")
	var source_rows := [_make_datatable_row_raw("SourceRow", 33)]
	var source_table := _make_datatable_export("SourceTable", source_rows)
	source.exports = [source_table]

	var target := _make_empty_asset("res://target_empty_table.uasset")
	var target_table := _make_datatable_export("TargetTable", [])
	target.exports = [target_table]

	var source_row := UAssetProperty.from_dict(source_rows[0])
	var copy_result := ClipboardManager.copy({"dt_row": source_row, "expo": source_table}, source, [])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts row copy for empty-table paste")

	ClipboardManager.paste(_make_clipboard_context(target), target_table, [], null)
	var target_rows := target_table.get_datatable_rows()
	_expect(target_rows.size() == 1
			and str((target_rows[0] as Dictionary).get("Name")) == "SourceRow_Copy",
		"data table row paste works when the target table starts empty")


func _test_clipboard_export_cross_file_remaps_imports() -> void:
	var source := _make_empty_asset("res://source_refs.uasset")
	source.imports = [_make_import("SourceClass", 0)]
	source.exports = [_make_export("NeedsImport", 0, -1, 0, [-1], -1)]

	var target := _make_empty_asset("res://target_refs.uasset")
	target.imports = [_make_import("OtherClass", 0)]

	var copy_result := ClipboardManager.copy(source.exports[0], source, [source.exports[0]])
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts cross-file export copy")
	ClipboardManager.paste(_make_clipboard_context(target), null, [], null)

	_expect(target.imports.size() == 2
			and target.imports[1].object_name == "SourceClass"
			and target.imports[1].package_name.is_empty()
			and target.imports[1].to_dict().get("PackageName") == null,
		"cross-file export paste adds the referenced source import once")
	_expect(target.exports.size() == 1
			and target.exports[0].class_index == -2
			and _object_value(target.exports[0]) == -2,
		"cross-file export paste rewrites copied import references to the target asset")


func _test_clipboard_export_group_preserves_internal_refs() -> void:
	var source := _make_empty_asset("res://source_group.uasset")
	source.exports = [
		_make_export("CopiedA", 0, 0, 0, [], 0),
		_make_export("CopiedB", 0, 0, 0, [1], 1),
	]

	var target := _make_empty_asset("res://target_group.uasset")
	target.exports = [_make_export("Existing", 0, 0, 0, [], 0)]

	var copy_result := ClipboardManager.copy(null, source, source.exports)
	_expect(bool(copy_result.get("ok", false)), "clipboard accepts grouped export copy")
	ClipboardManager.paste(_make_clipboard_context(target), null, [], null)

	_expect(target.exports.size() == 3
			and target.exports[1].object_name == "CopiedA_Copy"
			and target.exports[2].object_name == "CopiedB_Copy",
		"grouped export paste inserts copied exports in order")
	_expect(_object_value(target.exports[2]) == 2
			and target.exports[2].raw["CreateBeforeCreateDependencies"] == [2],
		"grouped export paste preserves references between copied exports")


func _test_property_state_restore() -> void:
	var prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.StructPropertyData, UAssetAPI",
		"Name": "Container",
		"StructType": "TestStruct",
		"Value": [{
			"$type": "UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI",
			"Name": "TagName",
			"Value": "Before",
		}],
	})
	var before := prop.capture_state()
	prop.children[0].set_value("After")
	var after := prop.capture_state()
	prop.restore_state(before)
	_expect(prop.children[0].value == "Before" and prop.to_dict() == before,
		"property restore synchronizes parsed and raw state")
	prop.restore_state(after)
	_expect(prop.children[0].value == "After" and prop.to_dict() == after,
		"property snapshots can be reapplied for redo")


func _test_byte_enum_property_round_trip() -> void:
	var enum_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"ByteType": "FName",
		"EnumType": "EMaterialParameterAssociation",
		"EnumValue": "GlobalParameter",
		"Name": "Association",
		"ArrayIndex": 0,
		"IsZero": false,
	})
	_expect(enum_prop.value == "GlobalParameter",
		"byte enum property reads EnumValue instead of null")
	var enum_dict := enum_prop.to_dict()
	_expect(enum_dict.get("EnumValue") == "GlobalParameter" and not enum_dict.has("Value"),
		"byte enum property serializes without a null Value field")

	enum_prop.set_value("LayerParameter")
	enum_dict = enum_prop.to_dict()
	_expect(enum_dict.get("EnumValue") == "LayerParameter" and not enum_dict.has("Value"),
		"byte enum property edits write back to EnumValue")

	var polluted_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"ByteType": "FName",
		"EnumType": "EMaterialParameterAssociation",
		"EnumValue": "GlobalParameter",
		"Name": "Association",
		"Value": null,
	})
	_expect(polluted_prop.value == "GlobalParameter" and not polluted_prop.to_dict().has("Value"),
		"byte enum property recovers from a stale null Value field")

	var numeric_prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.BytePropertyData, UAssetAPI",
		"Name": "Channel",
		"Value": 2,
	})
	numeric_prop.set_value(5)
	_expect(numeric_prop.to_dict().get("Value") == 5,
		"numeric byte property still serializes Value")


func _test_asset_diff_engine() -> void:
	var left := {
		"NameMap": PackedStringArray(["One"]),
		"Exports": [{
			"ObjectName": "Export1",
			"Data": [{
				"Name": "Value",
				"Value": 1,
			}],
		}],
		"OnlyLeft": true,
	}
	var right := {
		"NameMap": PackedStringArray(["One", "Two"]),
		"Exports": [{
			"ObjectName": "Export1",
			"Data": [{
				"Name": "Value",
				"Value": 2,
			}],
		}],
		"OnlyRight": true,
	}
	var diffs := AssetDiff.compare_values(left, right)
	var by_path: Dictionary = {}
	for diff in diffs:
		by_path[str(diff["path"])] = diff

	_expect(by_path.has("Exports[0].Data[0].Value"),
		"asset diff detects changed nested values")
	_expect(by_path.has("NameMap[1]")
			and by_path["NameMap[1]"]["status"] == AssetDiff.STATUS_ADDED,
		"asset diff detects added packed-string-array items")
	_expect(by_path.has("OnlyLeft")
			and by_path["OnlyLeft"]["status"] == AssetDiff.STATUS_REMOVED
			and by_path.has("OnlyRight")
			and by_path["OnlyRight"]["status"] == AssetDiff.STATUS_ADDED,
		"asset diff detects removed and added dictionary keys")


func _test_asset_diff_tab_layout() -> void:
	var left := _make_asset()
	var right := _make_asset()
	right.name_map.append("Four")
	var tab := AssetDiffTab.setup(left, right)
	_expect(tab.tab_title == "Diff", "asset diff tab uses a short readable title")
	_expect(tab.get_child_count() >= 3 and tab.diffs.size() > 0,
		"asset diff tab builds a readable change list")
	tab.free()


func _test_linear_color_property_editor() -> void:
	var prop := UAssetProperty.from_dict({
		"$type": "UAssetAPI.PropertyTypes.Objects.LinearColorPropertyData, UAssetAPI",
		"Name": "ParameterValue",
		"Value": {
			"$type": "UAssetAPI.UnrealTypes.FLinearColor, UAssetAPI",
			"R": 1.0,
			"G": 0.25,
			"B": 0.5,
			"A": 1.0,
		},
	})
	_expect(PropertyRow.is_color_struct(prop),
		"linear color property data is detected as editable color")

	var row := PropertyRow.create(prop)
	var editor := row.editor_control as HBoxContainer
	_expect(editor != null and editor.get_child(0) is ColorPickerButton,
		"linear color property uses a color picker editor")

	var changes: Array[Dictionary] = []
	row.value_changed.connect(func(_prop: UAssetProperty, _old_value: Variant, _new_value: Variant) -> void:
		changes.append({"old": _old_value, "new": _new_value})
	)
	var picker := editor.get_child(0) as ColorPickerButton
	picker.color_changed.emit(Color(0.1, 0.2, 0.3, 0.4))
	var value := prop.value as Dictionary
	var raw_value := prop.raw["Value"] as Dictionary
	_expect(changes.size() == 1, "linear color picker emits a property change")
	_expect(_approx_float(float(value["G"]), 0.2)
			and _approx_float(float(raw_value["B"]), 0.3),
		"linear color picker writes back to raw FLinearColor values")


func _test_mesh_preview_materials() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_mesh_material_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	FileUtils.write_bytes_atomic(root.path_join("Body.mat"),
		"Diffuse=BodyColor\nNormal=BodyNormal\n".to_utf8_buffer())
	FileUtils.write_bytes_atomic(root.path_join("Body.props.txt"),
		("BlendMode = BLEND_Masked (1)\n" +
		"TwoSided = true\n").to_utf8_buffer())
	var color_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(0.2, 0.4, 0.8, 1.0))
	color_image.save_png(root.path_join("BodyColor.png"))
	var normal_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	normal_image.fill(Color(0.5, 0.5, 1.0, 1.0))
	normal_image.save_png(root.path_join("BodyNormal.png"))

	var source_material := StandardMaterial3D.new()
	source_material.resource_name = "Body"
	var quad := QuadMesh.new()
	quad.material = source_material
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = quad
	var result := MeshPreviewMaterialLoader.apply_to_scene(mesh_instance, root)
	var material := mesh_instance.get_surface_override_material(0) as StandardMaterial3D
	_expect(result["applied"] == 1 and material != null,
		"mesh preview reconstructs an exported material slot")
	_expect(material.albedo_texture != null and material.normal_texture != null,
		"mesh preview attaches diffuse and normal textures")
	_expect(material.cull_mode == BaseMaterial3D.CULL_DISABLED,
		"mesh preview preserves two-sided material metadata")
	mesh_instance.free()
	FileUtils.remove_dir_recursive(root)


func _test_glb_export() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_glb_export_%d" % Time.get_ticks_usec())
	var out_dir := root.path_join("out")
	DirAccess.make_dir_recursive_absolute(root)
	FileUtils.write_bytes_atomic(root.path_join("Body.mat"),
		"Diffuse=BodyColor\n".to_utf8_buffer())
	var color_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(0.8, 0.2, 0.1, 1.0))
	color_image.save_png(root.path_join("BodyColor.png"))

	var scene := Node3D.new()
	var source_material := StandardMaterial3D.new()
	source_material.resource_name = "Body"
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.material = source_material
	mesh_instance.mesh = mesh
	scene.add_child(mesh_instance)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var error := doc.append_from_scene(scene, state)
	var source_path := root.path_join("SourceMesh.gltf")
	if error == OK:
		error = doc.write_to_filesystem(state, source_path)
	_expect(error == OK and FileAccess.file_exists(source_path),
		"test fixture writes a source glTF")

	var service := MeshService.new()
	var result := service._write_glb_from_gltf(source_path, out_dir)
	var glb_path := str(result[2])
	var bytes := FileAccess.get_file_as_bytes(glb_path) if FileAccess.file_exists(glb_path) else PackedByteArray()
	_expect(bool(result[0]) and glb_path.ends_with(".glb") and bytes.size() >= 4
			and bytes.slice(0, 4).get_string_from_ascii() == "glTF",
		"mesh export writes a Blender-compatible GLB")
	_expect(str(result[1]).contains("textured material"),
		"mesh GLB export reports embedded textured materials")

	var read_doc := GLTFDocument.new()
	var read_state := GLTFState.new()
	var read_error := read_doc.append_from_file(glb_path, read_state)
	var read_scene := read_doc.generate_scene(read_state) if read_error == OK else null
	var read_mesh := _find_first_mesh_instance(read_scene) if read_scene != null else null
	var read_material := read_mesh.get_active_material(0) as StandardMaterial3D \
		if read_mesh != null else null
	_expect(read_material != null and read_material.albedo_texture != null,
		"mesh GLB export embeds reconstructed material textures")

	scene.free()
	if read_scene != null:
		read_scene.free()
	FileUtils.remove_dir_recursive(root)


func _test_md5_animation_loader() -> void:
	var md5_text := """
MD5Version 10
numFrames 2
numJoints 2
frameRate 30
numAnimatedComponents 12
hierarchy {
	"root" -1 63 0
	"hand_r" 0 63 6
}
bounds {
	( -1 -1 -1 ) ( 1 1 1 )
	( -1 -1 -1 ) ( 1 1 1 )
}
baseframe {
	( 0 0 0 ) ( 0 0 0 )
	( 0 0 0 ) ( 0 0 0 )
}
frame 0 {
	( 0 0 0 ) ( 0 0 0 )
	( 0 0 0 ) ( 0 0 0 )
}
frame 1 {
	( 100 0 0 ) ( 0 0 0 )
	( 0 50 0 ) ( 0 0 0.70710678 )
}
"""
	var parsed := Md5AnimLoader.parse_text(md5_text, "Synthetic")
	_expect(bool(parsed.get("ok", false)), "MD5 animation parser accepts umodel-style data")
	_expect(int(parsed["num_frames"]) == 2 and int(parsed["num_joints"]) == 2,
		"MD5 animation parser preserves header counts")

	var frames: Array = parsed["frames"]
	var root_frame: Dictionary = frames[1][0]
	var hand_frame: Dictionary = frames[1][1]
	_expect(_approx_vec3(root_frame["position"], Vector3(1.0, 0.0, 0.0)),
		"MD5 animation loader converts positions from centimeters to Godot axes")
	_expect(_approx_vec3(hand_frame["position"], Vector3(0.0, 0.0, -0.5)),
		"MD5 animation loader mirrors Unreal Y into Godot Z")

	var preview_root := Node3D.new()
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	skeleton.add_bone("root")
	skeleton.add_bone("hand_r")
	skeleton.set_bone_parent(1, 0)
	preview_root.add_child(skeleton)

	var built := Md5AnimLoader.build_animation(parsed, skeleton, preview_root, true)
	_expect(bool(built.get("ok", false)), "MD5 animation builder targets matching skeleton bones")
	var animation := built.get("animation") as Animation
	_expect(animation != null and animation.get_track_count() == 4,
		"MD5 animation builder creates position and rotation tracks per matched bone")
	if animation != null:
		_expect(str(animation.track_get_path(0)) == "Rig:root",
			"MD5 animation tracks address skeleton bones relative to the preview root")
		_expect(is_equal_approx(animation.length, 1.0 / 30.0),
			"MD5 animation length reflects frame count and frame rate")
		_expect(animation.loop_mode == Animation.LOOP_LINEAR,
			"MD5 animation builder applies requested loop mode")
	preview_root.free()

	var sparse_text := """
MD5Version 10
numFrames 1
numJoints 1
frameRate 24
numAnimatedComponents 1
hierarchy {
	"root" -1 2 0
}
baseframe {
	( 10 20 30 ) ( 0 0 0 )
}
frame 0 {
	50
}
"""
	var sparse := Md5AnimLoader.parse_text(sparse_text, "Sparse")
	_expect(bool(sparse.get("ok", false)), "MD5 animation parser accepts sparse component frames")
	var sparse_frames: Array = sparse["frames"]
	var sparse_root: Dictionary = sparse_frames[0][0]
	_expect(_approx_vec3(sparse_root["position"], Vector3(0.1, 0.3, -0.5)),
		"MD5 animation parser overlays animated components onto the base frame")

	var flat_root := Node3D.new()
	var flat_skeleton := Skeleton3D.new()
	flat_skeleton.name = "FlatRig"
	flat_skeleton.add_bone("root")
	for index in range(1, 10):
		flat_skeleton.add_bone("bone_%d" % index)
		flat_skeleton.set_bone_parent(index, index - 1)
	var flat_child_rest := Transform3D.IDENTITY
	flat_child_rest.basis = Basis(Quaternion(Vector3.FORWARD, deg_to_rad(90.0)))
	flat_skeleton.set_bone_rest(1, flat_child_rest)
	flat_root.add_child(flat_skeleton)
	var flat_joints: Array = [{"name": "root", "parent": -1, "flags": 63, "start": 0}]
	var flat_frame: Array = [{
		"position": Vector3.ZERO,
		"rotation": Quaternion(Vector3.FORWARD, deg_to_rad(10.0)),
	}]
	for index in range(1, 10):
		flat_joints.append({"name": "bone_%d" % index, "parent": 0, "flags": 63, "start": index * 6})
		flat_frame.append({
			"position": Vector3.ZERO,
			"rotation": Quaternion(Vector3.FORWARD, deg_to_rad(20.0)),
		})
	var flat_parsed := {
		"ok": true,
		"name": "Flattened",
		"num_frames": 1,
		"num_joints": flat_joints.size(),
		"frame_rate": 30.0,
		"joints": flat_joints,
		"frames": [flat_frame],
	}
	var flat_built := Md5AnimLoader.build_animation(flat_parsed, flat_skeleton, flat_root, true)
	_expect(bool(flat_built.get("ok", false)), "MD5 animation builder accepts flattened umodel hierarchy")
	var flat_animation := flat_built.get("animation") as Animation
	_expect(bool(flat_built.get("flattened_hierarchy", false)),
		"MD5 animation builder detects flattened umodel hierarchy")
	_expect(int(flat_built.get("position_bones", -1)) == 0,
		"MD5 animation builder skips child position tracks for flattened hierarchy")
	_expect(str(flat_built.get("rotation_mode", "")) == Md5AnimLoader.FLATTENED_ROTATION_LOCAL,
		"flattened MD5 animation keeps absolute local rotations when frames contain a full pose")
	if flat_animation != null:
		_expect(flat_animation.get_track_count() == flat_joints.size(),
			"flattened MD5 animation emits rotation tracks without collapsing positions")
		var local_rotation := flat_animation.track_get_key_value(1, 0) as Quaternion
		_expect(_approx_quat(local_rotation, Quaternion(Vector3.FORWARD, deg_to_rad(20.0))),
			"flattened MD5 animation preserves absolute local child rotation")

	var delta_frame: Array = [{
		"position": Vector3.ZERO,
		"rotation": Quaternion.IDENTITY,
	}]
	for index in range(1, 10):
		var rotation := Quaternion.IDENTITY
		if index == 1:
			rotation = Quaternion(Vector3.FORWARD, deg_to_rad(10.0))
		delta_frame.append({
			"position": Vector3.ZERO,
			"rotation": rotation,
		})
	var delta_parsed := {
		"ok": true,
		"name": "FlattenedDelta",
		"num_frames": 1,
		"num_joints": flat_joints.size(),
		"frame_rate": 30.0,
		"joints": flat_joints,
		"frames": [delta_frame],
	}
	var delta_built := Md5AnimLoader.build_animation(delta_parsed, flat_skeleton, flat_root, true)
	var delta_animation := delta_built.get("animation") as Animation
	_expect(str(delta_built.get("rotation_mode", "")) == Md5AnimLoader.FLATTENED_ROTATION_DELTA,
		"flattened MD5 animation detects mostly identity pose-delta rotations")
	if delta_animation != null:
		var delta_rotation := delta_animation.track_get_key_value(1, 0) as Quaternion
		var expected_delta_rotation := flat_child_rest.basis.get_rotation_quaternion() * Quaternion(
			Vector3.FORWARD, deg_to_rad(10.0))
		_expect(_approx_quat(delta_rotation, expected_delta_rotation),
			"flattened MD5 animation composes pose-delta rotations with target rest rotation")
	flat_root.free()


func _test_animation_candidate_discovery() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_anim_candidates_%d" % Time.get_ticks_usec())
	var mod_root := root.path_join("Mods/TestMod")
	var source_root := root.path_join("Unchanged")
	var mesh_path := mod_root.path_join("g3/Content/Characters/Human/Hero/HeroBody.uasset")
	var idle_path := source_root.path_join("g3/Content/Characters/Human/Animations/Female_Idle_Breathing.uasset")
	var attack_path := source_root.path_join("g3/Content/Characters/Human/Animations/Combat/FireballAttackToIdleR.uasset")
	var anim_bp_path := source_root.path_join("g3/Content/Characters/Human/Animations/Human_AnimBlueprint.uasset")
	var blueprint_path := source_root.path_join("g3/Content/Characters/Human/Animations/BP_NotAnAnimation.uasset")
	for path in [mesh_path, idle_path, attack_path, anim_bp_path, blueprint_path]:
		FileUtils.write_bytes_atomic(path, "asset".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Base", "path": source_root}]
	var service := MeshService.new().setup(config)
	var candidates := service.find_animation_assets_for_mesh(mesh_path, 20)
	_expect(idle_path in candidates and attack_path in candidates,
		"animation discovery finds likely source animations for a human skeletal mesh")
	_expect(not anim_bp_path in candidates and not blueprint_path in candidates,
		"animation discovery filters animation blueprints and regular blueprints")
	_expect(candidates.find(idle_path) < candidates.find(attack_path),
		"animation discovery ranks idle animations before attack candidates")
	FileUtils.remove_dir_recursive(root)


func _test_texture_injection_preserves_companions() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_tex_install_%d" % Time.get_ticks_usec())
	var original_dir := root.path_join("original")
	var staged_dir := root.path_join("staged")
	var output_dir := root.path_join("output")
	DirAccess.make_dir_recursive_absolute(original_dir)
	DirAccess.make_dir_recursive_absolute(staged_dir)
	DirAccess.make_dir_recursive_absolute(output_dir)

	var original_uasset := original_dir.path_join("Texture.uasset")
	var original_uexp := original_dir.path_join("Texture.uexp")
	var original_ubulk := original_dir.path_join("Texture.ubulk")
	FileUtils.write_bytes_atomic(original_uasset, "old-uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(original_uexp, "old-uexp".to_utf8_buffer())
	FileUtils.write_bytes_atomic(original_ubulk, "old-ubulk".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uasset"), "new-uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uexp"), "new-uexp".to_utf8_buffer())

	var service := TextureService.new()
	var collected := service._collect_injected_texture_files(
		original_uasset, staged_dir, original_dir, "Texture")
	_expect(bool(collected.get("ok", false)),
		"texture injection collects generated files for in-place install")
	var install_error := FileUtils.install_staged_files(collected["files"])
	_expect(install_error == OK, "texture injection staged install succeeds")
	_expect(FileAccess.get_file_as_string(original_uasset) == "new-uasset",
		"texture injection replaces generated uasset")
	_expect(FileAccess.get_file_as_string(original_uexp) == "new-uexp",
		"texture injection replaces generated uexp")
	_expect(FileAccess.get_file_as_string(original_ubulk) == "old-ubulk",
		"texture injection preserves existing ubulk when injector omits it")

	staged_dir = root.path_join("staged_external")
	DirAccess.make_dir_recursive_absolute(staged_dir)
	FileUtils.write_bytes_atomic(staged_dir.path_join("Texture.uasset"), "external-uasset".to_utf8_buffer())
	collected = service._collect_injected_texture_files(original_uasset, staged_dir, output_dir, "Texture")
	_expect(bool(collected.get("ok", false)),
		"texture injection collects preserved companions for alternate output")
	install_error = FileUtils.install_staged_files(collected["files"])
	_expect(install_error == OK, "texture injection alternate output install succeeds")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.uasset")) == "external-uasset",
		"texture injection writes generated uasset to alternate output")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.uexp")) == "new-uexp",
		"texture injection copies original uexp to alternate output when omitted")
	_expect(FileAccess.get_file_as_string(output_dir.path_join("Texture.ubulk")) == "old-ubulk",
		"texture injection copies original ubulk to alternate output when omitted")
	FileUtils.remove_dir_recursive(root)


func _test_texture_companion_recovery() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_tex_recover_%d" % Time.get_ticks_usec())
	var mod_dir := root.path_join("Mods/TestMod")
	var source_dir := root.path_join("Unchanged")
	var relative := "g3/Content/Characters/Human/Test/Texture"
	DirAccess.make_dir_recursive_absolute(mod_dir.path_join(relative.get_base_dir()))
	DirAccess.make_dir_recursive_absolute(source_dir.path_join(relative.get_base_dir()))

	var uasset_path := mod_dir.path_join(relative + ".uasset")
	var source_ubulk := source_dir.path_join(relative + ".ubulk")
	var target_ubulk := mod_dir.path_join(relative + ".ubulk")
	FileUtils.write_bytes_atomic(uasset_path, "uasset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(source_ubulk, "source-ubulk".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Base", "path": source_dir}]
	var service := TextureService.new().setup(config)
	var recovered := service._restore_missing_texture_companions(uasset_path)
	_expect(bool(recovered.get("ok", false)),
		"texture recovery succeeds when a configured source has the missing companion")
	_expect(FileAccess.get_file_as_string(target_ubulk) == "source-ubulk",
		"texture recovery restores missing ubulk before DDS tools read the package")
	FileUtils.remove_dir_recursive(root)


func _test_mesh_animation_controls_build() -> void:
	var detail := MeshDetail.new()
	var container := VBoxContainer.new()
	detail._container = container
	detail._preview_scene = Node3D.new()
	detail._preview_skeleton = Skeleton3D.new()
	detail._preview_skeleton.add_bone("root")
	detail._set_animation_controls_ready(true)
	detail._build_animation_controls()
	detail._set_animation_controls_ready(detail._preview_skeleton != null)
	_expect(container.get_child_count() > 0,
		"mesh animation controls build without runtime property errors")
	_expect(not detail._anim_auto_btn.disabled and not detail._anim_load_btn.disabled,
		"mesh animation controls enable when cached mesh preview already found a skeleton")
	_expect(detail._anim_speed_spin is SpinBox and not detail._anim_speed_spin.editable,
		"mesh animation speed control starts read-only")
	_expect(detail._anim_slider is HSlider and not detail._anim_slider.editable,
		"mesh animation scrub control starts read-only")
	detail._set_animation_loaded(true)
	_expect(detail._anim_speed_spin.editable,
		"mesh animation speed control becomes editable when animation is loaded")
	_expect(detail._anim_slider.editable,
		"mesh animation scrub control becomes editable when animation is loaded")
	detail._set_animation_loaded(false)
	_expect(not detail._anim_speed_spin.editable,
		"mesh animation speed control returns to read-only when animation is cleared")
	_expect(not detail._anim_slider.editable,
		"mesh animation scrub control returns to read-only when animation is cleared")
	detail._preview_skeleton.set_bone_pose_rotation(0, Quaternion(Vector3.FORWARD, deg_to_rad(20.0)))
	detail._reset_preview_skeleton_pose()
	_expect(_approx_quat(detail._preview_skeleton.get_bone_pose_rotation(0), Quaternion.IDENTITY),
		"mesh animation preview resets stale bone poses before loading another animation")
	detail._preview_scene.free()
	container.free()


func _test_mesh_preview_environment() -> void:
	var detail := MeshDetail.new()
	var root := Node3D.new()
	detail._add_preview_environment(root)

	var world_env: WorldEnvironment = null
	var key_light: DirectionalLight3D = null
	var light_count := 0
	for child in root.get_children():
		if child is WorldEnvironment:
			world_env = child
		elif child is DirectionalLight3D:
			light_count += 1
			if key_light == null:
				key_light = child

	var sky_material: ProceduralSkyMaterial = null
	if world_env != null and world_env.environment.sky is Sky:
		sky_material = (world_env.environment.sky as Sky).sky_material as ProceduralSkyMaterial

	_expect(world_env != null
			and world_env.environment.background_mode == Environment.BG_SKY
			and sky_material != null,
		"mesh preview environment uses Godot's preview sky background")
	_expect(world_env != null
			and world_env.environment.tonemap_mode == Environment.TONE_MAPPER_FILMIC
			and not world_env.environment.ssao_enabled
			and not world_env.environment.sdfgi_enabled,
		"mesh preview environment matches Godot's default preview effects")
	_expect(sky_material != null
			and _approx_color(sky_material.sky_top_color, Color(0.385, 0.454, 0.55))
			and _approx_color(sky_material.ground_bottom_color, Color(0.2, 0.169, 0.133)),
		"mesh preview environment uses Godot's default preview sky colors")
	_expect(light_count == 1
			and key_light != null
			and key_light.shadow_enabled
			and key_light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			and _approx_float(key_light.directional_shadow_max_distance, 100.0)
			and _approx_float(key_light.rotation.x, deg_to_rad(-60.0))
			and _approx_float(key_light.rotation.y, deg_to_rad(150.0)),
		"mesh preview environment uses Godot's default preview sun")
	root.free()


func _test_background_job_shutdown() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_job_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var marker := root.path_join("finished.txt")
	var runner := BackgroundJobRunner.new()
	var job_id := runner.run(func() -> bool:
		OS.delay_msec(10)
		return FileUtils.write_bytes_atomic(marker, "done".to_utf8_buffer()) == OK,
		Callable())
	_expect(job_id >= 0, "background runner accepts work")
	runner.wait_to_finish()
	_expect(FileAccess.get_file_as_string(marker) == "done",
		"background runner joins active work during shutdown")
	FileUtils.remove_dir_recursive(root)


func _test_file_watcher_rapid_toggle() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_watch_%d" % Time.get_ticks_usec())
	var mods_dir := root.path_join("Mods")
	var game_dir := root.path_join("Game")
	DirAccess.make_dir_recursive_absolute(mods_dir.path_join("TestMod/g3/Content"))
	DirAccess.make_dir_recursive_absolute(game_dir.path_join("g3/Content/Paks"))

	var config := ModConfigManager.new()
	config.mods_dir = mods_dir
	config.game_dir = game_dir
	var state := ModStateManager.new().setup(root.path_join(".mod_state.json"))
	state.set_enabled("TestMod", true)
	var packer := PackingService.new().setup(config)
	var watcher := ModFileWatcher.new().setup(config, state, packer)

	var started := Time.get_ticks_msec()
	watcher.start()
	watcher.stop()
	watcher.start()
	watcher.stop()
	watcher.wait_to_finish()
	var elapsed := Time.get_ticks_msec() - started

	_expect(not watcher.is_watching(),
		"file watcher stops after rapid start/stop/start/stop")
	_expect(elapsed < 1000,
		"file watcher rapid toggle does not block for the full poll interval")
	FileUtils.remove_dir_recursive(root)


func _test_atomic_file_install() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_files_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var target := root.path_join("target.bin")
	var staged := root.path_join("staged.bin")
	var obsolete := root.path_join("obsolete.bin")
	FileUtils.write_bytes_atomic(target, "old".to_utf8_buffer())
	FileUtils.write_bytes_atomic(staged, "new".to_utf8_buffer())
	FileUtils.write_bytes_atomic(obsolete, "stale".to_utf8_buffer())
	var error := FileUtils.install_staged_files(
		[{"source": staged, "target": target}], [obsolete])
	_expect(error == OK, "atomic file install succeeds")
	_expect(FileAccess.get_file_as_string(target) == "new", "atomic file install replaces content")
	_expect(not FileAccess.file_exists(staged), "atomic file install consumes staged file")
	_expect(not FileAccess.file_exists(obsolete), "atomic file install removes obsolete companions")

	staged = root.path_join("staged-again.bin")
	FileUtils.write_bytes_atomic(staged, "newer".to_utf8_buffer())
	var result := FileUtils.install_staged_files_with_result(
		[{"source": staged, "target": target}], [], true, "restore")
	_expect(int(result.get("error", ERR_BUG)) == OK,
		"atomic file install can keep a persistent restore backup")
	var backups: Array = result.get("backups", [])
	_expect(backups.size() == 1 and FileAccess.file_exists(str(backups[0]["backup"])),
		"persistent restore backup is kept after successful install")
	if backups.size() == 1:
		_expect(FileAccess.get_file_as_string(str(backups[0]["backup"])) == "new",
			"persistent restore backup contains the replaced content")
	_expect(FileAccess.get_file_as_string(target) == "newer",
		"persistent-backup install still replaces content")
	if backups.size() == 1:
		var restore_error := FileUtils.restore_backup(backups[0])
		_expect(restore_error == OK and FileAccess.get_file_as_string(target) == "new",
			"persistent restore backup can restore replaced content")
	FileUtils.remove_dir_recursive(root)


func _test_mod_manifest() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_manifest_%d" % Time.get_ticks_usec())
	var source_root := root.path_join("Source")
	var mod_path := root.path_join("Mods/TestMod")
	var source_file := source_root.path_join("g3/Content/Items/Test.uasset")
	var target_file := mod_path.path_join("g3/Content/Items/Test.uasset")
	var manual_file := mod_path.path_join("g3/Content/Items/Manual.uexp")
	FileUtils.write_bytes_atomic(source_file, "asset".to_utf8_buffer())
	FileUtils.copy_file(source_file, target_file)
	FileUtils.write_bytes_atomic(manual_file, "manual".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	config.sources = [{"name": "Source", "path": source_root}]
	var mod := {"name": "TestMod", "path": mod_path}
	var error := ModManifest.record_copied_files(mod, source_root, [source_file], config)
	_expect(error == OK and FileAccess.file_exists(ModManifest.manifest_path(mod)),
		"mod manifest is written after copied files are recorded")

	var manifest: Dictionary = JSON.parse_string(
			FileAccess.get_file_as_string(ModManifest.manifest_path(mod)))
	var by_target := {}
	for entry: Dictionary in manifest.get("files", []):
		by_target[str(entry.get("target", ""))] = entry
	_expect(by_target.has("g3/Content/Items/Test.uasset"),
		"mod manifest records copied target path")
	_expect(by_target.has("g3/Content/Items/Manual.uexp"),
		"mod manifest snapshots manually present target path")
	var copied_entry: Dictionary = by_target.get("g3/Content/Items/Test.uasset", {})
	var source_info: Dictionary = copied_entry.get("source", {})
	_expect(str(source_info.get("path", "")) == source_file,
		"mod manifest preserves copied file source path")
	_expect(str(manifest.get("build", {}).get("content_root", "")) == "g3",
		"mod manifest records build content root")
	FileUtils.remove_dir_recursive(root)


func _test_mod_preflight() -> void:
	var root := OS.get_temp_dir().path_join("sb_test_preflight_%d" % Time.get_ticks_usec())
	var mod_path := root.path_join("Mods/TestMod")
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Good.uasset"),
			"asset".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Good.uexp"),
			"companion".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Orphan.uexp"),
			"orphan".to_utf8_buffer())
	FileUtils.write_bytes_atomic(mod_path.path_join("g3/Content/Loose.bin"),
			"loose".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.mods_dir = root.path_join("Mods")
	var issues := ModPreflight.validate_mod_for_pack({"name": "TestMod", "path": mod_path}, config)
	_expect(ModPreflight.error_count(issues) >= 1,
		"mod preflight reports orphan package companion as an error")
	_expect(ModPreflight.warning_count(issues) >= 1,
		"mod preflight reports unusual loose files as warnings")
	FileUtils.remove_dir_recursive(root)


func _test_uasset_save_validation() -> void:
	var asset := _make_asset()
	_expect(asset.validate_for_save().is_empty(),
		"uasset save validation accepts valid package indices")
	asset.exports[0].class_index = -99
	var issues := asset.validate_for_save()
	_expect(not issues.is_empty()
			and "Invalid package index" in str(issues[0].get("message", "")),
		"uasset save validation rejects invalid package indices")


func _test_path_safety() -> void:
	_expect(FileUtils.is_path_within("/mods/example/Content/a.uasset", "/mods/example"),
		"path containment accepts descendants")
	_expect(not FileUtils.is_path_within("/mods/example2/a.uasset", "/mods/example"),
		"path containment rejects prefix collisions")
	_expect(not FileUtils.is_path_within("/mods/example/../outside", "/mods/example"),
		"path containment rejects parent traversal")
	_expect(FileUtils.is_safe_filename("My Mod") and not FileUtils.is_safe_filename("../outside"),
		"folder name validation rejects path components")


func _test_process_arguments() -> void:
	var python := ProcessUtils.find_python()
	if python.is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb test's args %d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root)
	var script := root.path_join("print_args.py")
	FileUtils.write_bytes_atomic(script,
		"import os, sys\nprint(os.getcwd())\nprint(sys.argv[1])\n".to_utf8_buffer())
	var output: Array = []
	var argument := "value with spaces and 'quotes'"
	var code := ProcessUtils.run_python_script(python, script, root, [argument], output)
	var text := ProcessUtils.output_text(output, "")
	_expect(code == 0, "Python working-directory wrapper succeeds")
	_expect(root.get_file() in text and argument in text,
		"subprocess paths and arguments are passed literally")
	FileUtils.remove_dir_recursive(root)

	var launch := ProcessUtils.parse_command_line(
			"\"C:\\Games\\Spellbreak CE\\Spellbreak.exe\" -log \"value with spaces\"")
	_expect(launch.size() == 3
			and launch[0] == "C:\\Games\\Spellbreak CE\\Spellbreak.exe"
			and launch[1] == "-log"
			and launch[2] == "value with spaces",
			"launch command parser preserves quoted Windows paths and arguments")


func _test_base_source_generation() -> void:
	if ProcessUtils.find_python().is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb_test_base_source_%d" % Time.get_ticks_usec())
	var tool_dir := root.path_join("u4pak")
	var output_dir := root.path_join("source")
	var pak_path := root.path_join("Game.pak")
	DirAccess.make_dir_recursive_absolute(tool_dir)
	FileUtils.write_bytes_atomic(pak_path, "fake pak".to_utf8_buffer())
	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import os, sys\n"
			+ "args = sys.argv[1:]\n"
			+ "if args[0] == 'list':\n"
			+ "    print('g3/Content/TestAsset.uasset')\n"
			+ "    raise SystemExit(0)\n"
			+ "if args[0] == 'unpack' and args[1] == '-C':\n"
			+ "    out = args[2]\n"
			+ "    target = os.path.join(out, 'g3', 'Content', 'TestAsset.uasset')\n"
			+ "    os.makedirs(os.path.dirname(target), exist_ok=True)\n"
			+ "    open(target, 'wb').write(b'data')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(9)\n"
	).to_utf8_buffer())

	var config := ModConfigManager.new()
	config.u4pak_dir = tool_dir
	var service := BaseSourceService.new().setup(config)
	var result := service._do_generate(pak_path, output_dir)
	_expect(result[0], "base source generation succeeds with u4pak unpack")
	_expect(DirAccess.dir_exists_absolute(output_dir.path_join("g3/Content")),
		"base source generation creates the configured content root")
	_expect(result[2] == "Base Game (Game)", "base source generation returns a useful source name")
	_expect(result[3] == output_dir, "base source generation returns the output folder as source path")

	var fallback_dir := root.path_join("fallback_source")
	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import os, sys\n"
			+ "args = sys.argv[1:]\n"
			+ "if args[0] == 'list':\n"
			+ "    if '--ignore-magic' in args and '--force-version=3' in args:\n"
			+ "        print('g3/Content/FallbackAsset.uasset')\n"
			+ "        raise SystemExit(0)\n"
			+ "    print('illegal file magic: 0x00000000')\n"
			+ "    raise SystemExit(1)\n"
			+ "if args[0] == 'unpack':\n"
			+ "    if '--ignore-magic' not in args or '--force-version=3' not in args:\n"
			+ "        raise SystemExit(8)\n"
			+ "    out = args[args.index('-C') + 1]\n"
			+ "    target = os.path.join(out, 'g3', 'Content', 'FallbackAsset.uasset')\n"
			+ "    os.makedirs(os.path.dirname(target), exist_ok=True)\n"
			+ "    open(target, 'wb').write(b'data')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(9)\n"
	).to_utf8_buffer())
	var fallback_result := service._do_generate(pak_path, fallback_dir)
	_expect(fallback_result[0],
		"base source generation retries pak parsing with profile archive flags")
	_expect(FileAccess.file_exists(fallback_dir.path_join("g3/Content/FallbackAsset.uasset")),
		"base source generation reuses fallback flags for unpack")

	FileUtils.write_bytes_atomic(tool_dir.path_join("u4pak.py"), (
			"import sys\n"
			+ "if sys.argv[1] == 'list':\n"
			+ "    print('../Outside.uasset')\n"
			+ "    raise SystemExit(0)\n"
			+ "raise SystemExit(0)\n"
	).to_utf8_buffer())
	var unsafe_result := service._do_generate(pak_path, root.path_join("unsafe_source"))
	_expect(not unsafe_result[0], "base source generation rejects unsafe pak paths")

	FileUtils.remove_dir_recursive(root)


func _test_packing_transaction() -> void:
	if ProcessUtils.find_python().is_empty():
		return
	var root := OS.get_temp_dir().path_join("sb_test_pack_%d" % Time.get_ticks_usec())
	var game_dir := root.path_join("game")
	var paks_dir := game_dir.path_join("g3/Content/Paks")
	var mod_dir := root.path_join("mods/TestMod")
	DirAccess.make_dir_recursive_absolute(paks_dir)
	FileUtils.write_bytes_atomic(mod_dir.path_join("g3/Content/example.bin"), "payload".to_utf8_buffer())

	var config := ModConfigManager.new()
	config.game_dir = game_dir
	config.mods_dir = root.path_join("mods")
	config.u4pak_dir = ProjectSettings.globalize_path("res://u4pak")
	var packer := PackingService.new().setup(config)
	var result := packer._do_pack([{"name": "TestMod", "path": mod_dir}])
	var pak_path := paks_dir.path_join("zzz_mods_P.pak")
	_expect(result[0] and FileAccess.file_exists(pak_path), "u4pak integration produces a pak")
	FileUtils.write_bytes_atomic(paks_dir.path_join("Game.sig"), "sig-template".to_utf8_buffer())

	FileUtils.write_bytes_atomic(mod_dir.path_join("g3/Content/example.bin"), "payload2".to_utf8_buffer())
	var second_result := packer._do_pack([{"name": "TestMod", "path": mod_dir}])
	_expect(second_result[0] and "Backup" in str(second_result[1]),
		"repacking an existing installed pak reports retained backup paths")

	var export_path := root.path_join("exports/TestMod.pak")
	var export_result := packer._do_pack_to_path([{"name": "TestMod", "path": mod_dir}], export_path)
	_expect(export_result[0]
			and FileAccess.file_exists(export_path)
			and FileAccess.file_exists(export_path.get_basename() + ".sig"),
		"middle-click mod export writes chosen pak and sibling sig")
	_expect(FileAccess.get_file_as_string(export_path.get_basename() + ".sig") == "sig-template",
		"middle-click mod export copies the game signature template")

	if FileAccess.file_exists(pak_path):
		var previous := FileAccess.get_file_as_bytes(pak_path)
		var failing_tool_dir := root.path_join("failing_u4pak")
		DirAccess.make_dir_recursive_absolute(failing_tool_dir)
		FileUtils.write_bytes_atomic(failing_tool_dir.path_join("u4pak.py"),
			"raise SystemExit(7)\n".to_utf8_buffer())
		config.u4pak_dir = failing_tool_dir
		var failed_result := packer._do_pack([{"name": "TestMod", "path": mod_dir}])
		_expect(not failed_result[0], "packing reports subprocess failure")
		_expect(FileAccess.get_file_as_bytes(pak_path) == previous,
			"failed packing preserves the previously installed pak")

	FileUtils.remove_dir_recursive(root)


func _load_test_mapping_context() -> GUIDEMappingContext:
	var mapping := ResourceLoader.load("res://guide/mapping.tres", "",
		ResourceLoader.CACHE_MODE_IGNORE) as GUIDEMappingContext
	mapping.display_name = "Editor"
	for action_mapping: GUIDEActionMapping in mapping.mappings:
		var action := action_mapping.action
		action.name = action.resource_path.get_file().get_basename()
		action.display_name = action.name.capitalize()
		action.display_category = "Test"
		action.is_remappable = not action.resource_path.ends_with("/shift.tres") \
			and not action.resource_path.ends_with("/ctrl.tres")
	return mapping


func _find_test_action(mapping: GUIDEMappingContext, resource_path: String) -> GUIDEAction:
	for action_mapping: GUIDEActionMapping in mapping.mappings:
		if action_mapping.action.resource_path == resource_path:
			return action_mapping.action
	_expect(false, "test mapping action exists: " + resource_path)
	return null


func _default_input_for_action(mapping: GUIDEMappingContext, action: GUIDEAction,
		index: int) -> GUIDEInput:
	for action_mapping: GUIDEActionMapping in mapping.mappings:
		if action_mapping.action == action and action_mapping.input_mappings.size() > index:
			return action_mapping.input_mappings[index].input
	_expect(false, "test mapping default input exists")
	return null


func _active_input_for_action(guide, action: GUIDEAction, index: int) -> GUIDEInput:
	for action_mapping: GUIDEActionMapping in guide._active_action_mappings:
		if action_mapping.action == action and action_mapping.input_mappings.size() > index:
			return action_mapping.input_mappings[index].input
	return null


func _make_key_input(key: Key, control: bool = false, shift: bool = false,
		alt: bool = false, meta: bool = false) -> GUIDEInputKey:
	var input := GUIDEInputKey.new()
	input.key = key
	input.control = control
	input.shift = shift
	input.alt = alt
	input.meta = meta
	return input


func _make_empty_asset(path: String = "") -> UAssetFile:
	var asset := UAssetFile.new()
	asset.raw = {}
	asset.file_path = path
	asset.binary_path = path
	asset.name_map = PackedStringArray()
	asset.imports = []
	asset.exports = []
	return asset


func _make_clipboard_context(asset: UAssetFile, detail_stack: Array = []) -> AssetEditorContext:
	var context := AssetEditorContext.new()
	context.document = AssetDocument.new(asset)
	context.detail_stack = detail_stack
	context.rebuild_tree = func() -> void: pass
	context.show_detail = func(_data: Variant) -> void: pass
	context.select_tree_item = func(_data: Variant) -> void: pass
	return context


func _make_asset() -> UAssetFile:
	var asset := UAssetFile.new()
	asset.raw = {}
	asset.name_map = PackedStringArray(["One", "Two", "Three"])
	asset.imports = [
		_make_import("Import1", 2),
		_make_import("Import2", -1),
		_make_import("Import3", -2),
	]
	asset.exports = [
		_make_export("Export1", 2, -2, 0, [2, 3, -2], 3),
		_make_export("Export2", 1, -1, 0, [1], 1),
		_make_export("Export3", 1, -3, 0, [1, -3], 1),
	]
	return asset


func _make_datatable_export(name: String, rows: Array) -> UAssetExport:
	return UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.DataTableExport, UAssetAPI",
		"ObjectName": name,
		"OuterIndex": 0,
		"ClassIndex": 0,
		"SuperIndex": 0,
		"TemplateIndex": 0,
		"SerialSize": 0,
		"SerialOffset": 0,
		"CreateBeforeCreateDependencies": [],
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Table": {"Data": rows},
		"Data": [],
	})


func _make_datatable_row_raw(name: String, value: int) -> Dictionary:
	return {
		"$type": "UAssetAPI.PropertyTypes.Objects.IntPropertyData, UAssetAPI",
		"Name": name,
		"ArrayIndex": 0,
		"IsZero": false,
		"Value": value,
	}


func _make_import(name: String, outer: int) -> UAssetImport:
	return UAssetImport.from_dict({
		"$type": "UAssetAPI.Import, UAssetAPI",
		"ObjectName": name,
		"ClassName": "Class",
		"ClassPackage": "/Script/CoreUObject",
		"PackageName": null,
		"OuterIndex": outer,
		"bImportOptional": false,
	}, 0)


func _make_export(name: String, outer: int, class_index: int, template: int,
		dependencies: Array, object_value: int) -> UAssetExport:
	return UAssetExport.from_dict({
		"$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
		"ObjectName": name,
		"OuterIndex": outer,
		"ClassIndex": class_index,
		"SuperIndex": 0,
		"TemplateIndex": template,
		"SerialSize": 0,
		"SerialOffset": 0,
		"CreateBeforeCreateDependencies": dependencies.duplicate(),
		"CreateBeforeSerializationDependencies": [],
		"SerializationBeforeCreateDependencies": [],
		"SerializationBeforeSerializationDependencies": [],
		"Data": [{
			"$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
			"Name": "ObjectRef",
			"ArrayIndex": 0,
			"IsZero": false,
			"Value": object_value,
		}],
	})


func _object_value(expo: UAssetExport) -> int:
	return int(expo.properties[0].value)


func _find_first_mesh_instance(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_first_mesh_instance(child)
		if found != null:
			return found
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _approx_float(actual: float, expected: float, epsilon: float = 0.0001) -> bool:
	return abs(actual - expected) <= epsilon


func _approx_color(actual: Color, expected: Color, epsilon: float = 0.0001) -> bool:
	return _approx_float(actual.r, expected.r, epsilon) \
			and _approx_float(actual.g, expected.g, epsilon) \
			and _approx_float(actual.b, expected.b, epsilon) \
			and _approx_float(actual.a, expected.a, epsilon)


func _approx_vec3(actual: Vector3, expected: Vector3, epsilon: float = 0.0001) -> bool:
	return actual.distance_to(expected) <= epsilon


func _approx_quat(actual: Quaternion, expected: Quaternion, epsilon: float = 0.0001) -> bool:
	return abs(actual.normalized().dot(expected.normalized())) >= 1.0 - epsilon
