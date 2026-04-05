class_name ClipboardManager extends RefCounted

## Static clipboard shared across all open tabs.
## copy() and get_label() read/write the clipboard.
## paste() receives a context dict with all the callbacks it needs to modify the asset.
##
## Context dict keys expected by paste():
##   "asset"            : UAssetFile
##   "current_data"     : Variant   (currently focused data object)
##   "detail_stack"     : Array     (navigation stack, direct reference)
##   "selection"        : Array     (currently selected items)
##   "set_dirty"        : Callable  ()
##   "push_undo"        : Callable  (entry: Dictionary)
##   "rebuild_tree"     : Callable  ()
##   "show_detail"      : Callable  (data: Variant)
##   "select_tree_item" : Callable  (data: Variant)

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


static func paste(context: Dictionary) -> void:
	if _clipboard.is_empty():
		return
	var asset: UAssetFile        = context["asset"]
	var current_data: Variant    = context["current_data"]
	var detail_stack: Array      = context["detail_stack"]
	var selection: Array         = context["selection"]

	match _clipboard["type"]:
		"export", "export_array":
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
			for i in raws.size():
				var new_expo := UAssetExport.from_dict(raws[i])
				asset.exports.insert(insert_at + i, new_expo)
				context["push_undo"].call({"action": "remove_export", "export": new_expo})
				added.append(new_expo)
			context["rebuild_tree"].call()
			context["show_detail"].call(added[0])
			context["select_tree_item"].call(added[0])

		"import", "import_array":
			var raws: Array = []
			if _clipboard["type"] == "import":
				raws.append(_clipboard["raw"].duplicate(true))
			else:
				for r in _clipboard["items"]:
					raws.append(r.duplicate(true))

			var insert_at := asset.imports.size()
			if selection.size() > 0 and selection[0] is UAssetImport:
				insert_at = asset.imports.find(selection[0])

			for i in raws.size():
				var new_imp := UAssetImport.from_dict(raws[i], -(insert_at + i + 1))
				asset.imports.insert(insert_at + i, new_imp)
				context["push_undo"].call({"action": "remove_import", "import": new_imp})
			context["rebuild_tree"].call()
			context["show_detail"].call(&"importmap")

		"name", "name_array":
			var names: Array = []
			if _clipboard["type"] == "name":
				names.append(_clipboard["value"])
			else:
				names.append_array(_clipboard["items"])

			var insert_at := asset.name_map.size()
			if selection.size() > 0 and selection[0] is int:
				insert_at = selection[0] as int

			for i in names.size():
				var n: String = str(names[i])
				if not asset.has_name(n):
					asset.name_map.insert(insert_at + i, n)
			context["show_detail"].call(&"namemap")

		"property":
			var raw: Dictionary = _clipboard["raw"].duplicate(true)
			var new_prop := UAssetProperty.from_dict(raw)
			var paste_into: Array = []
			var show_after: Variant = null

			# Priority: explicit array_context (set when an array item is selected) >
			#           current_data is the array > detail stack > export top-level
			var array_ctx: Variant = context.get("array_context")
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

			paste_into.insert(insert_at, new_prop)
			context["set_dirty"].call()
			context["push_undo"].call({"action": "remove_from_array", "array": paste_into, "prop": new_prop, "show": show_after})
			context["rebuild_tree"].call()
			context["show_detail"].call(show_after)

		"property_array":
			var paste_into: Array = []
			var show_after: Variant = null

			var array_ctx: Variant = context.get("array_context")
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

			for i in (_clipboard["items"] as Array).size():
				var new_prop := UAssetProperty.from_dict(
					((_clipboard["items"] as Array)[i] as Dictionary).duplicate(true))
				paste_into.insert(insert_at + i, new_prop)
				context["push_undo"].call({"action": "remove_from_array",
					"array": paste_into, "prop": new_prop, "show": show_after})
			context["set_dirty"].call()
			context["rebuild_tree"].call()
			context["show_detail"].call(show_after)

		"dt_row":
			var expo: UAssetExport = _clipboard["expo"]
			var rows_raw: Array = []
			var table_raw: Variant = expo.raw.get("Table")
			if table_raw is Dictionary:
				var dr: Variant = table_raw.get("Data")
				if dr is Array:
					rows_raw = dr as Array
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
			rows_raw.insert(insert_at, new_raw)
			context["set_dirty"].call()
			context["push_undo"].call({"action": "datatable_remove_row", "rows_raw": rows_raw, "index": insert_at, "expo": expo})
			context["rebuild_tree"].call()
			context["show_detail"].call(expo)


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
