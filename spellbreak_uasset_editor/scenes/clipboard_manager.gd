class_name ClipboardManager extends RefCounted

## Static clipboard shared across all open tabs.
## copy() and get_label() read/write the clipboard.
## paste() receives the typed editor context plus transient selection state.

static var _clipboard: Dictionary = {}


static func is_empty() -> bool:
	return _clipboard.is_empty()


static func copy(current_data: Variant, asset: UAssetFile, selection: Array) -> void:
	# Multi-select: copy all selected items of the same type
	if selection.size() > 1:
		if selection[0] is UAssetImport:
			_clipboard = {"type": "import_array", "items": selection.map(func(i): return i.to_dict())}
			return
		if selection[0] is UAssetExport:
			_clipboard = {"type": "export_array", "items": selection.map(func(e): return e.to_dict())}
			return
		if selection[0] is int:  # name map indices
			_clipboard = {"type": "name_array", "items": selection.map(func(i): return asset.name_map[i])}
			return
		if selection[0] is UAssetProperty:
			_clipboard = {"type": "property_array", "items": selection.map(func(p: UAssetProperty): return p.to_dict())}
			return

	if current_data is UAssetExport:
		_clipboard = {"type": "export", "raw": current_data.to_dict()}
	elif current_data is UAssetProperty:
		_clipboard = {"type": "property", "raw": current_data.to_dict()}
	elif current_data is UAssetImport:
		_clipboard = {"type": "import", "raw": current_data.to_dict()}
	elif current_data is int:
		_clipboard = {"type": "name", "value": asset.name_map[current_data as int]}
	elif current_data is Dictionary and current_data.has("dt_row"):
		var row: UAssetProperty = current_data["dt_row"]
		_clipboard = {"type": "dt_row", "raw": row.raw.duplicate(true), "expo": current_data["expo"]}


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
			if _clipboard["type"] == "export":
				var r: Dictionary = _clipboard["raw"].duplicate(true)
				r["ObjectName"] = str(r.get("ObjectName", "Export")) + "_Copy"
				r["SerialSize"] = 0; r["SerialOffset"] = 0
				raws.append(r)
			else:
				for r in _clipboard["items"]:
					var rc: Dictionary = r.duplicate(true)
					rc["ObjectName"] = str(rc.get("ObjectName", "Export")) + "_Copy"
					rc["SerialSize"] = 0; rc["SerialOffset"] = 0
					raws.append(rc)

			var insert_at := asset.exports.size()
			if selection.size() > 0 and selection[0] is UAssetExport:
				insert_at = asset.exports.find(selection[0])

			var added: Array = []
			for raw in raws:
				added.append(UAssetExport.from_dict(raw))
			asset.insert_exports(insert_at, added)
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
			if _clipboard["type"] == "import":
				raws.append(_clipboard["raw"].duplicate(true))
			else:
				for r in _clipboard["items"]:
					raws.append(r.duplicate(true))

			var insert_at := asset.imports.size()
			if selection.size() > 0 and selection[0] is UAssetImport:
				insert_at = asset.imports.find(selection[0])

			var added: Array = []
			for raw in raws:
				added.append(UAssetImport.from_dict(raw, 0))
			asset.insert_imports(insert_at, added)
			var after := asset.capture_package_tables()
			context.record_applied("Paste imports",
				func() -> void: asset.restore_package_tables(after),
				func() -> void: asset.restore_package_tables(before))
			context.rebuild_tree.call()
			context.show_detail.call(&"importmap")

		"name", "name_array":
			var old_names := asset.name_map.duplicate()
			var new_names := old_names.duplicate()
			var names: Array = []
			if _clipboard["type"] == "name":
				names.append(_clipboard["value"])
			else:
				names.append_array(_clipboard["items"])

			var insert_at := asset.name_map.size()
			if selection.size() > 0 and selection[0] is int:
				insert_at = selection[0] as int

			var changed := false
			var insertion_offset := 0
			for raw_name in names:
				var n := str(raw_name)
				if not new_names.has(n):
					new_names.insert(insert_at + insertion_offset, n)
					insertion_offset += 1
					changed = true
			if changed:
				context.execute("Paste names",
					func() -> void: asset.name_map = new_names.duplicate(),
					func() -> void: asset.name_map = old_names.duplicate())
			context.show_detail.call(&"namemap")

		"property":
			var raw: Dictionary = _clipboard["raw"].duplicate(true)
			var new_prop := UAssetProperty.from_dict(raw)
			var paste_into: Array = []
			var show_after: Variant = null

			# Priority: explicit array_context (set when an array item is selected) >
			#           current_data is the array > detail stack > export top-level
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

			context.execute("Paste property",
				func() -> void: paste_into.insert(insert_at, new_prop),
				func() -> void: paste_into.erase(new_prop))
			context.rebuild_tree.call()
			context.show_detail.call(show_after)

		"property_array":
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
			for raw_item in _clipboard["items"]:
				added.append(UAssetProperty.from_dict((raw_item as Dictionary).duplicate(true)))
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
			var expo: UAssetExport = _clipboard["expo"]
			var rows_raw: Array = expo.get_datatable_rows()
			if rows_raw.is_empty():
				return
			var new_raw: Dictionary = (_clipboard["raw"] as Dictionary).duplicate(true)
			new_raw["Name"] = str(new_raw.get("Name", "Row")) + "_Copy"
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
