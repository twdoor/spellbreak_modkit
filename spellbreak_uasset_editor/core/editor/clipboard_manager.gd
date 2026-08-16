class_name ClipboardManager extends RefCounted

## Static clipboard shared across all open tabs.
## copy() and get_label() read/write the clipboard.
## paste() receives the typed editor context plus transient selection state.

static var _clipboard: Dictionary = {}


static func is_empty() -> bool:
	return _clipboard.is_empty()


static func copy(current_data: Variant, asset: UAssetFile, selection: Array) -> Dictionary:
	_clipboard.clear()
	if asset == null:
		return {"ok": false, "message": "No asset is open"}

	# Multi-select: copy all selected items of the same type
	if selection.size() > 1:
		if _all_imports(selection):
			_clipboard = _base_payload(asset, "import_array")
			_clipboard["items"] = selection.map(func(i): return i.to_dict())
			_clipboard["source_indices"] = selection.map(
				func(i): return -(asset.imports.find(i) + 1))
			return _copy_result()
		if _all_exports(selection):
			_clipboard = _base_payload(asset, "export_array")
			_clipboard["items"] = selection.map(func(e): return e.to_dict())
			_clipboard["source_indices"] = selection.map(
				func(e): return asset.exports.find(e) + 1)
			return _copy_result()
		if _all_name_indices(selection, asset):  # name map indices
			_clipboard = {"type": "name_array", "items": selection.map(func(i): return asset.name_map[i])}
			return _copy_result()
		if _all_properties(selection):
			_clipboard = _base_payload(asset, "property_array")
			_clipboard["items"] = selection.map(func(p: UAssetProperty): return p.to_dict())
			return _copy_result()
		return {"ok": false, "message": "Selection contains mixed or unsupported items"}

	if current_data is UAssetExport:
		_clipboard = _base_payload(asset, "export")
		_clipboard["raw"] = current_data.to_dict()
		_clipboard["source_indices"] = [asset.exports.find(current_data) + 1]
	elif current_data is UAssetProperty:
		_clipboard = _base_payload(asset, "property")
		_clipboard["raw"] = current_data.to_dict()
	elif current_data is UAssetImport:
		_clipboard = _base_payload(asset, "import")
		_clipboard["raw"] = current_data.to_dict()
		_clipboard["source_indices"] = [-(asset.imports.find(current_data) + 1)]
	elif current_data is int:
		var index := current_data as int
		if index < 0 or index >= asset.name_map.size():
			return {"ok": false, "message": "Name index is out of range"}
		_clipboard = {"type": "name", "value": asset.name_map[index]}
	elif current_data is Dictionary and current_data.has("dt_row"):
		var row: UAssetProperty = current_data["dt_row"]
		_clipboard = _base_payload(asset, "dt_row")
		_clipboard["raw"] = row.raw.duplicate(true)
	else:
		return {"ok": false, "message": "Nothing copyable is selected"}
	return _copy_result()


## Human-readable label for the current clipboard content (used by toast messages).
static func get_label() -> String:
	if _clipboard.is_empty():
		return ""
	var raw: Dictionary = _clipboard.get("raw", {})
	match _clipboard["type"]:
		"export":        return str(raw.get("ObjectName", "export"))
		"import":        return str(raw.get("ObjectName", "import"))
		"property":      return str(raw.get("Name", raw.get("PropertyName", "property")))
		"export_array":    return "%d exports" % _clipboard["items"].size()
		"import_array":    return "%d imports" % _clipboard["items"].size()
		"name":            return str(_clipboard.get("value", "name"))
		"name_array":      return "%d names" % _clipboard["items"].size()
		"dt_row":          return str(raw.get("Name", "row"))
		"property_array":  return "%d properties" % _clipboard["items"].size()
	return ""


static func paste(context: AssetEditorContext, current_data: Variant,
		selection: Array, array_context: Variant = null) -> void:
	if _clipboard.is_empty():
		return
	var asset := context.get_asset()
	var detail_stack := context.detail_stack

	match _clipboard["type"]:
		"export", "export_array":
			var before := asset.capture_package_tables()
			var raws: Array = []
			var warnings: Array[String] = []
			var source_package: Dictionary = _clipboard.get("source_package", {})
			var source_indices: Array = _clipboard.get("source_indices", [])
			var copied_export_sentinels := _export_sentinel_map(source_indices)
			if _clipboard["type"] == "export":
				var r: Dictionary = _clipboard["raw"].duplicate(true)
				r["ObjectName"] = str(r.get("ObjectName", "Export")) + "_Copy"
				r["SerialSize"] = 0; r["SerialOffset"] = 0
				_remap_raw_package_indices(r, asset, source_package, copied_export_sentinels,
						warnings)
				raws.append(r)
			else:
				for r in _clipboard["items"]:
					var rc: Dictionary = r.duplicate(true)
					rc["ObjectName"] = str(rc.get("ObjectName", "Export")) + "_Copy"
					rc["SerialSize"] = 0; rc["SerialOffset"] = 0
					_remap_raw_package_indices(rc, asset, source_package, copied_export_sentinels,
							warnings)
					raws.append(rc)

			var insert_at := asset.exports.size()
			if selection.size() > 0 and selection[0] is UAssetExport:
				insert_at = asset.exports.find(selection[0])

			var added: Array = []
			for raw in raws:
				added.append(UAssetExport.from_dict(raw, asset))
			asset.insert_exports(insert_at, added)
			var final_export_map := _final_copied_export_map(source_indices,
					copied_export_sentinels, insert_at)
			if not final_export_map.is_empty():
				for expo in added:
					asset._remap_export(expo,
						func(value: int) -> int: return int(final_export_map.get(value, value)))
			var after := asset.capture_package_tables()
			context.record_applied("Paste exports",
				func() -> void: asset.restore_package_tables(after),
				func() -> void: asset.restore_package_tables(before))
			context.rebuild_tree.call()
			context.show_detail.call(added[0])
			context.select_tree_item.call(added[0])

		"import", "import_array":
			var before := asset.capture_package_tables()
			var raws: Array = []
			var warnings: Array[String] = []
			var source_package: Dictionary = _clipboard.get("source_package", {})
			var source_indices: Array = _clipboard.get("source_indices", [])
			var copied_import_sentinels := _import_sentinel_map(source_indices)
			if _clipboard["type"] == "import":
				var raw_import: Dictionary = _clipboard["raw"].duplicate(true)
				_remap_import_raw(raw_import, asset, source_package, copied_import_sentinels,
						warnings)
				raws.append(raw_import)
			else:
				for r in _clipboard["items"]:
					var raw_import: Dictionary = r.duplicate(true)
					_remap_import_raw(raw_import, asset, source_package, copied_import_sentinels,
							warnings)
					raws.append(raw_import)

			var insert_at := asset.imports.size()
			if selection.size() > 0 and selection[0] is UAssetImport:
				insert_at = asset.imports.find(selection[0])

			var added: Array = []
			for raw in raws:
				added.append(UAssetImport.from_dict(raw, 0, asset))
			asset.insert_imports(insert_at, added)
			var final_import_map := _final_copied_import_map(source_indices,
					copied_import_sentinels, insert_at)
			if not final_import_map.is_empty():
				for imp in added:
					asset._remap_import(imp,
						func(value: int) -> int: return int(final_import_map.get(value, value)))
			var after := asset.capture_package_tables()
			context.record_applied("Paste imports",
				func() -> void: asset.restore_package_tables(after),
				func() -> void: asset.restore_package_tables(before))
			context.rebuild_tree.call()
			context.show_detail.call(&"importmap")

		"name", "name_array":
			var names: Array = []
			if _clipboard["type"] == "name":
				names.append(_clipboard["value"])
			else:
				names.append_array(_clipboard["items"])

			var insert_at := asset.name_map.size()
			if selection.size() > 0 and selection[0] is int:
				insert_at = selection[0] as int

			var inserted := asset.insert_names(insert_at, names)
			if not inserted.is_empty():
				context.execute("Paste names",
					func() -> void: asset.insert_names(insert_at, inserted),
					func() -> void:
						var indices: Array = []
						for i in inserted.size():
							indices.append(insert_at + i)
						asset.remove_names(indices))
			context.show_detail.call(&"namemap")

		"property":
			var raw: Dictionary = _clipboard["raw"].duplicate(true)
			var warnings: Array[String] = []
			_remap_raw_package_indices(raw, asset, _clipboard.get("source_package", {}), {},
					warnings)
			var new_prop := UAssetProperty.from_dict(raw, asset)
			var is_map_pair := str(raw.get("$type", "")) == "MapPair"
			var paste_into: Array = []
			var show_after: Variant = null

			# Priority: explicit array_context (set when an array/map item is selected) >
			#           current_data is the array/map > detail stack > export top-level
			var array_ctx: Variant = array_context
			if array_ctx is UAssetProperty \
					and (array_ctx as UAssetProperty).prop_type in ["Array", "Map"]:
				paste_into = (array_ctx as UAssetProperty).children
				show_after = array_ctx
			elif current_data is UAssetProperty \
					and (current_data as UAssetProperty).prop_type == "Array":
				paste_into = current_data.children
				show_after = current_data
			elif is_map_pair and current_data is UAssetProperty \
					and current_data.prop_type == "Map":
				paste_into = current_data.children
				show_after = current_data
			else:
				for i in range(detail_stack.size() - 1, -1, -1):
					var d = detail_stack[i]["data"]
					if d is UAssetProperty and d.prop_type == "Array":
						paste_into = d.children
						show_after = d
						break
					if is_map_pair and d is UAssetProperty and d.prop_type == "Map":
						paste_into = d.children
						show_after = d
						break

			if show_after == null and is_map_pair:
				return  # a copied map entry can only land inside its map

			if show_after == null:
				var expo := _find_context_export(current_data, detail_stack)
				if expo == null:
					return
				paste_into = expo.properties
				show_after = expo

			var insert_at := paste_into.size()
			if current_data is UAssetProperty and paste_into.has(current_data):
				insert_at = paste_into.find(current_data)

			context.execute("Paste property",
				func() -> void: paste_into.insert(insert_at, new_prop),
				func() -> void: paste_into.erase(new_prop))
			context.rebuild_tree.call()
			context.show_detail.call(show_after)

		"property_array":
			var all_map_pairs := true
			for raw_item in _clipboard["items"]:
				if str((raw_item as Dictionary).get("$type", "")) != "MapPair":
					all_map_pairs = false
					break
			if all_map_pairs:
				var map_ctx: Variant = null
				var arr_ctx: Variant = array_context
				if arr_ctx is UAssetProperty and (arr_ctx as UAssetProperty).prop_type == "Map":
					map_ctx = arr_ctx
				elif current_data is UAssetProperty and current_data.prop_type == "Map":
					map_ctx = current_data
				else:
					for i in range(detail_stack.size() - 1, -1, -1):
						var d = detail_stack[i]["data"]
						if d is UAssetProperty and d.prop_type == "Map":
							map_ctx = d
							break
				if map_ctx == null:
					return  # copied map entries can only land inside their map
				var map_paste_into: Array = (map_ctx as UAssetProperty).children
				var map_insert_at := map_paste_into.size()
				if current_data is UAssetProperty and map_paste_into.has(current_data):
					map_insert_at = map_paste_into.find(current_data)
				var map_added: Array[UAssetProperty] = []
				var map_warnings: Array[String] = []
				for raw_item in _clipboard["items"]:
					var raw_item_copy := (raw_item as Dictionary).duplicate(true)
					_remap_raw_package_indices(raw_item_copy, asset,
							_clipboard.get("source_package", {}), {}, map_warnings)
					map_added.append(UAssetProperty.from_dict(raw_item_copy, asset))
				context.execute("Paste map entries",
					func() -> void:
						for i in map_added.size():
							map_paste_into.insert(map_insert_at + i, map_added[i]),
					func() -> void:
						for prop in map_added:
							map_paste_into.erase(prop))
				context.rebuild_tree.call()
				context.show_detail.call(map_ctx)
				return

			var paste_into: Array = []
			var show_after: Variant = null

			var array_ctx: Variant = array_context
			if array_ctx is UAssetProperty and (array_ctx as UAssetProperty).prop_type == "Array":
				paste_into = (array_ctx as UAssetProperty).children
				show_after = array_ctx
			elif current_data is UAssetProperty and current_data.prop_type == "Array":
				paste_into = current_data.children
				show_after = current_data
			else:
				for i in range(detail_stack.size() - 1, -1, -1):
					var d = detail_stack[i]["data"]
					if d is UAssetProperty and d.prop_type == "Array":
						paste_into = d.children
						show_after = d
						break

			if show_after == null:
				var expo := _find_context_export(current_data, detail_stack)
				if expo == null:
					return
				paste_into = expo.properties
				show_after = expo

			var insert_at := paste_into.size()
			if current_data is UAssetProperty and paste_into.has(current_data):
				insert_at = paste_into.find(current_data)

			var added: Array[UAssetProperty] = []
			var warnings: Array[String] = []
			for raw_item in _clipboard["items"]:
				var raw_item_copy := (raw_item as Dictionary).duplicate(true)
				_remap_raw_package_indices(raw_item_copy, asset,
						_clipboard.get("source_package", {}), {}, warnings)
				added.append(UAssetProperty.from_dict(raw_item_copy, asset))
			context.execute("Paste properties",
				func() -> void:
					for i in added.size():
						paste_into.insert(insert_at + i, added[i]),
				func() -> void:
					for prop in added:
						paste_into.erase(prop))
			context.rebuild_tree.call()
			context.show_detail.call(show_after)

		"dt_row":
			var expo := _find_target_datatable_export(current_data, detail_stack)
			if expo == null:
				return
			var rows_raw := _ensure_target_datatable_rows(expo)
			var new_raw: Dictionary = (_clipboard["raw"] as Dictionary).duplicate(true)
			new_raw["Name"] = str(new_raw.get("Name", "Row")) + "_Copy"
			var warnings: Array[String] = []
			_remap_raw_package_indices(new_raw, asset, _clipboard.get("source_package", {}), {},
					warnings)
			var insert_at := rows_raw.size()
			if current_data is Dictionary and current_data.has("dt_row"):
				var cur_row: UAssetProperty = current_data["dt_row"]
				var cur_idx := _datatable_row_index(cur_row, rows_raw)
				if cur_idx >= 0:
					insert_at = cur_idx + 1
			context.execute("Paste data table row",
				func() -> void: rows_raw.insert(insert_at, new_raw),
				func() -> void: rows_raw.remove_at(insert_at))
			context.rebuild_tree.call()
			context.show_detail.call(expo)


static func _find_context_export(current_data: Variant, detail_stack: Array) -> UAssetExport:
	if current_data is UAssetExport:
		return current_data
	for i in range(detail_stack.size() - 1, -1, -1):
		if detail_stack[i]["data"] is UAssetExport:
			return detail_stack[i]["data"]
	return null


static func _datatable_row_index(row: UAssetProperty, rows_raw: Array) -> int:
	for i in rows_raw.size():
		if (rows_raw[i] as Dictionary).get("Name") == row.prop_name:
			return i
	return -1


static func _base_payload(asset: UAssetFile, type_name: String) -> Dictionary:
	return {
		"type": type_name,
		"source_path": _asset_path(asset),
		"source_package": _package_context(asset),
	}


static func _copy_result() -> Dictionary:
	return {"ok": true, "message": get_label(), "label": get_label()}


static func _asset_path(asset: UAssetFile) -> String:
	if asset == null:
		return ""
	return asset.binary_path if not asset.binary_path.is_empty() else asset.file_path


static func _package_context(asset: UAssetFile) -> Dictionary:
	var import_data: Array = []
	for imp in asset.imports:
		import_data.append(imp.to_dict())
	var export_data: Array = []
	for expo in asset.exports:
		export_data.append(expo.to_dict())
	return {
		"path": _asset_path(asset),
		"imports": import_data,
		"exports": export_data,
	}


static func _all_imports(selection: Array) -> bool:
	for item in selection:
		if not item is UAssetImport:
			return false
	return true


static func _all_exports(selection: Array) -> bool:
	for item in selection:
		if not item is UAssetExport:
			return false
	return true


static func _all_properties(selection: Array) -> bool:
	for item in selection:
		if not item is UAssetProperty:
			return false
	return true


static func _all_name_indices(selection: Array, asset: UAssetFile) -> bool:
	for item in selection:
		if not item is int:
			return false
		var index := item as int
		if index < 0 or index >= asset.name_map.size():
			return false
	return true


static func _export_sentinel_map(source_indices: Array) -> Dictionary:
	var result := {}
	for raw_index in source_indices:
		var source_index := int(raw_index)
		if source_index > 0:
			result[source_index] = -1000000 - source_index
	return result


static func _import_sentinel_map(source_indices: Array) -> Dictionary:
	var result := {}
	for raw_index in source_indices:
		var source_index := int(raw_index)
		if source_index < 0:
			result[source_index] = 1000000 - source_index
	return result


static func _final_copied_export_map(source_indices: Array, sentinels: Dictionary,
		insert_at: int) -> Dictionary:
	var result := {}
	for i in source_indices.size():
		var source_index := int(source_indices[i])
		if sentinels.has(source_index):
			result[int(sentinels[source_index])] = insert_at + i + 1
	return result


static func _final_copied_import_map(source_indices: Array, sentinels: Dictionary,
		insert_at: int) -> Dictionary:
	var result := {}
	for i in source_indices.size():
		var source_index := int(source_indices[i])
		if sentinels.has(source_index):
			result[int(sentinels[source_index])] = -(insert_at + i + 1)
	return result


static func _remap_import_raw(raw_import: Dictionary, dest_asset: UAssetFile,
		source_package: Dictionary, copied_sentinels: Dictionary,
		warnings: Array[String]) -> void:
	var outer_index := int(raw_import.get("OuterIndex", 0))
	raw_import["OuterIndex"] = _map_source_package_index(
			outer_index, dest_asset, source_package, copied_sentinels, warnings)


static func _remap_raw_package_indices(value: Variant, dest_asset: UAssetFile,
		source_package: Dictionary, copied_sentinels: Dictionary,
		warnings: Array[String]) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for field in ["ClassIndex", "SuperIndex", "OuterIndex", "TemplateIndex"]:
			if dictionary.get(field) is int or dictionary.get(field) is float:
				dictionary[field] = _map_source_package_index(
						int(dictionary[field]), dest_asset, source_package,
						copied_sentinels, warnings)

		for field in [
			"CreateBeforeCreateDependencies",
			"CreateBeforeSerializationDependencies",
			"SerializationBeforeCreateDependencies",
			"SerializationBeforeSerializationDependencies",
		]:
			var raw_dependencies: Variant = dictionary.get(field)
			if raw_dependencies is Array:
				var dependencies: Array = []
				for raw_index in raw_dependencies:
					var mapped := _map_source_package_index(
							int(raw_index), dest_asset, source_package,
							copied_sentinels, warnings)
					if mapped != 0:
						dependencies.append(mapped)
				dictionary[field] = dependencies

		var type_name := str(dictionary.get("$type", ""))
		if "ObjectPropertyData" in type_name \
				and (dictionary.get("Value") is int or dictionary.get("Value") is float):
			dictionary["Value"] = _map_source_package_index(
					int(dictionary["Value"]), dest_asset, source_package,
					copied_sentinels, warnings)

		for key in dictionary.keys():
			var child: Variant = dictionary[key]
			if child is Dictionary or child is Array:
				_remap_raw_package_indices(child, dest_asset, source_package,
						copied_sentinels, warnings)
	elif value is Array:
		for child in value:
			if child is Dictionary or child is Array:
				_remap_raw_package_indices(child, dest_asset, source_package,
						copied_sentinels, warnings)


static func _map_source_package_index(value: int, dest_asset: UAssetFile,
		source_package: Dictionary, copied_sentinels: Dictionary,
		warnings: Array[String]) -> int:
	if value == 0:
		return 0
	if copied_sentinels.has(value):
		return int(copied_sentinels[value])
	if source_package.is_empty():
		return value
	if value < 0:
		return _ensure_source_import(dest_asset, source_package, value,
				copied_sentinels, warnings)
	return _resolve_source_export(dest_asset, source_package, value, warnings)


static func _ensure_source_import(dest_asset: UAssetFile, source_package: Dictionary,
		source_index: int, copied_sentinels: Dictionary, warnings: Array[String]) -> int:
	var imports: Array = source_package.get("imports", [])
	var actual := -source_index - 1
	if actual < 0 or actual >= imports.size() or not (imports[actual] is Dictionary):
		_add_warning(warnings, "Could not resolve copied import index %d" % source_index)
		return 0
	var raw_import := (imports[actual] as Dictionary)
	var mapped_outer := _map_source_package_index(int(raw_import.get("OuterIndex", 0)),
			dest_asset, source_package, copied_sentinels, warnings)
	var existing := _find_matching_import(dest_asset, raw_import, mapped_outer)
	if existing != 0:
		return existing

	var raw_copy := raw_import.duplicate(true)
	raw_copy["OuterIndex"] = mapped_outer
	var imp := UAssetImport.from_dict(raw_copy, -(dest_asset.imports.size() + 1), dest_asset)
	dest_asset.imports.append(imp)
	_ensure_import_names(dest_asset, imp)
	return -dest_asset.imports.size()


static func _find_matching_import(dest_asset: UAssetFile, raw_import: Dictionary,
		mapped_outer: int) -> int:
	var object_name := str(raw_import.get("ObjectName", ""))
	var import_class_name := str(raw_import.get("ClassName", ""))
	var class_package := str(raw_import.get("ClassPackage", ""))
	var package_name := _optional_string(raw_import.get("PackageName"))
	for i in dest_asset.imports.size():
		var imp := dest_asset.imports[i]
		if imp.object_name == object_name \
				and imp.class_name_str == import_class_name \
				and imp.class_package == class_package \
				and imp.package_name == package_name \
				and imp.outer_index == mapped_outer:
			return -(i + 1)
	return 0


static func _resolve_source_export(dest_asset: UAssetFile, source_package: Dictionary,
		source_index: int, warnings: Array[String]) -> int:
	if str(source_package.get("path", "")) == _asset_path(dest_asset):
		return source_index
	var exports: Array = source_package.get("exports", [])
	var actual := source_index - 1
	if actual < 0 or actual >= exports.size() or not (exports[actual] is Dictionary):
		_add_warning(warnings, "Could not resolve copied export index %d" % source_index)
		return 0
	var raw_export := exports[actual] as Dictionary
	var object_name := str(raw_export.get("ObjectName", ""))
	var export_type := _raw_export_type(raw_export)
	var matches: Array[int] = []
	var type_matches: Array[int] = []
	for i in dest_asset.exports.size():
		var candidate := dest_asset.exports[i]
		if candidate.object_name != object_name:
			continue
		matches.append(i + 1)
		if candidate.export_type == export_type:
			type_matches.append(i + 1)
	if type_matches.size() == 1:
		return type_matches[0]
	if matches.size() == 1:
		return matches[0]
	_add_warning(warnings, "Could not match copied export reference '%s'" % object_name)
	return 0


static func _find_target_datatable_export(current_data: Variant, detail_stack: Array) -> UAssetExport:
	if current_data is Dictionary and current_data.has("expo"):
		return current_data["expo"]
	if current_data is UAssetExport and current_data.export_type == "DataTableExport":
		return current_data
	for i in range(detail_stack.size() - 1, -1, -1):
		var data: Variant = detail_stack[i]["data"]
		if data is UAssetExport and data.export_type == "DataTableExport":
			return data
	return null


static func _ensure_target_datatable_rows(expo: UAssetExport) -> Array:
	var table_raw: Variant = expo.raw.get("Table")
	if not (table_raw is Dictionary):
		table_raw = {"Data": []}
		expo.raw["Table"] = table_raw
	var table := table_raw as Dictionary
	var rows_raw: Variant = table.get("Data")
	if rows_raw is Array:
		return rows_raw as Array
	var rows: Array = []
	table["Data"] = rows
	return rows


static func _ensure_import_names(asset: UAssetFile, imp: UAssetImport) -> void:
	for value in [imp.object_name, imp.class_name_str, imp.class_package, imp.package_name]:
		var text := str(value)
		if not text.is_empty():
			asset.ensure_name(text)


static func _optional_string(value: Variant) -> String:
	return "" if value == null else str(value)


static func _raw_export_type(raw_export: Dictionary) -> String:
	var full_type := str(raw_export.get("$type", ""))
	var type_parts := full_type.get_slice(",", 0).split(".")
	return type_parts[type_parts.size() - 1] if not type_parts.is_empty() else ""


static func _add_warning(warnings: Array[String], message: String) -> void:
	if message not in warnings:
		warnings.append(message)
