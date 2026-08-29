class_name TreeManager extends RefCounted

## Owns the Tree widget state: builds and rebuilds the asset tree,
## manages _item_map, and provides select/refresh helpers.

var _tree: Tree
var _asset: UAssetFile
var _item_map: Dictionary = {}

## Items whose property children haven't been built yet (lazy load on expand).
## Maps TreeItem → Callable that builds the real children.
var _lazy_items: Dictionary = {}
var _filter := ""
var _visible_export_count := 0

func setup(tree: Tree, asset: UAssetFile) -> TreeManager:
	_tree = tree
	_asset = asset
	# Connect once — guard against double-connect if setup() is called again.
	if not _tree.item_collapsed.is_connected(_on_item_toggled):
		_tree.item_collapsed.connect(_on_item_toggled)
	return self


func set_asset(asset: UAssetFile) -> void:
	_asset = asset


func get_item_map() -> Dictionary:
	return _item_map


func set_filter(value: String) -> void:
	_filter = value.strip_edges()


func get_visible_export_count() -> int:
	return _visible_export_count


# ── Build ──────────────────────────────────────────────────────────────────────

func build_tree() -> void:
	if not _asset or not _tree:
		return
	_tree.clear()
	_item_map.clear()
	_lazy_items.clear()
	var root := _tree.create_item()

	var names_item := _add_section(root, "NameMap [%d]" % _asset.name_map.size())
	_item_map[names_item] = &"namemap"

	var imports_item := _add_section(root, "Imports [%d]" % _asset.imports.size())
	_item_map[imports_item] = &"importmap"

	if UmgDesignerModel.supports(_asset):
		var designer_item := _add_section(root, "UI Designer")
		designer_item.collapsed = false
		_item_map[designer_item] = &"ui_designer"

	var matching_indices := find_export_indices(_asset, _filter)
	_visible_export_count = matching_indices.size()
	var exports_label := "Exports [%d]" % _asset.exports.size()
	if not _filter.is_empty():
		exports_label = "Exports [%d matches / %d]" % [matching_indices.size(), _asset.exports.size()]
	var exports_item := _add_section(root, exports_label)
	_item_map[exports_item] = &"exports"
	exports_item.collapsed = false

	var hierarchy := build_export_hierarchy(_asset)
	var children: Dictionary = hierarchy["children"]
	var visible: Dictionary = _visible_hierarchy_indices(_asset, matching_indices)
	_add_export_collection(exports_item, hierarchy["roots"], children, visible, {})


func _add_export_collection(parent: TreeItem, indices: Array, children: Dictionary,
		visible: Dictionary, ancestors: Dictionary) -> void:
	var shown := indices.filter(func(index: int) -> bool: return visible.has(index))
	# Broad ownership levels are grouped by UObject class, which is useful
	# information (Button, TextBlock, Function, Property...) rather than an
	# arbitrary range of serialization indices.
	if _filter.is_empty() and shown.size() > 100:
		var by_kind := {}
		for index: int in shown:
			var kind := _export_kind(_asset.exports[index])
			if not by_kind.has(kind):
				by_kind[kind] = []
			(by_kind[kind] as Array).append(index)
		var kinds := by_kind.keys()
		kinds.sort()
		for kind: String in kinds:
			var group := _tree.create_item(parent)
			var members: Array = by_kind[kind]
			group.set_text(0, "%s [%d]" % [kind, members.size()])
			group.collapsed = true
			_add_lazy_placeholder(group, func() -> void:
				for index: int in members:
					_add_export_to_tree(group, index, children, visible, ancestors))
		return
	for index: int in shown:
		_add_export_to_tree(parent, index, children, visible, ancestors)


func _export_kind(expo: UAssetExport) -> String:
	var resolved_class := _asset.get_export_class_name(expo)
	if not resolved_class.is_empty() and resolved_class != "?":
		return resolved_class.trim_suffix("_C")
	return expo.export_type.trim_suffix("Export")


func _add_export_to_tree(parent: TreeItem, i: int, children: Dictionary,
		visible: Dictionary, ancestors: Dictionary) -> void:
	if ancestors.has(i):
		return
	var expo := _asset.exports[i]
	var ei := _tree.create_item(parent)
	ei.set_text(0, "%s  ·  %s" % [expo.object_name, expo.export_type.trim_suffix("Export")])
	ei.set_tooltip_text(0, "Export #%d · OuterIndex %d" % [i + 1, expo.outer_index])
	ei.collapsed = true
	_item_map[ei] = expo

	var owned: Array = children.get(i, [])
	var complex_props: Array = expo.properties.filter(
			func(p: UAssetProperty) -> bool:
				return p.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"])
	var has_visible_owned := owned.any(func(child_index: int) -> bool: return visible.has(child_index))
	if has_visible_owned or not complex_props.is_empty() \
			or expo.export_type in ["DataTableExport", "StringTableExport"]:
		var next_ancestors := ancestors.duplicate()
		next_ancestors[i] = true
		_add_lazy_placeholder(ei, func() -> void:
			_add_export_collection(ei, owned, children, visible, next_ancestors)
			for prop: UAssetProperty in complex_props:
				_add_property_to_tree(ei, prop)
			_add_special_export_children(ei, expo))

	# A filtered tree should expose the ownership path immediately.
	if not _filter.is_empty() and has_visible_owned:
		ei.collapsed = false
		_expand_lazy_item(ei)


func _add_special_export_children(ei: TreeItem, expo: UAssetExport) -> void:

	# DataTable exports: rows go directly into the tree (RenderHint = BOTH)
	if expo.export_type == "DataTableExport":
		var table_raw: Variant = expo.raw.get("Table")
		if table_raw is Dictionary:
			var rows_raw: Variant = table_raw.get("Data")
			if rows_raw is Array and not (rows_raw as Array).is_empty():
				var table_item := _tree.create_item(ei)
				table_item.set_text(0, "Table [%d rows]" % (rows_raw as Array).size())
				table_item.collapsed = true
				_add_lazy_placeholder(table_item, func() -> void:
					for row_dict: Variant in (rows_raw as Array):
						if row_dict is Dictionary:
							var row := UAssetProperty.from_dict(row_dict, _asset)
							var ri := _tree.create_item(table_item)
							ri.set_text(0, row.prop_name)
							ri.collapsed = true
							_item_map[ri] = {"dt_row": row, "expo": expo}
							var complex_children: Array = row.children.filter(
									func(c: UAssetProperty) -> bool:
										return c.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"])
							if not complex_children.is_empty():
								_add_lazy_placeholder(ri, func() -> void:
									for child: UAssetProperty in complex_children:
										_add_property_to_tree(ri, child)))

	# StringTable exports: show entry count node (clicking opens StringTableDetail)
	if expo.export_type == "StringTableExport":
		var table_raw: Variant = expo.raw.get("Table")
		if table_raw is Dictionary:
			var entries: Variant = table_raw.get("Value", [])
			var count: int = (entries as Array).size() if entries is Array else 0
			var st_item := _tree.create_item(ei)
			st_item.set_text(0, "StringTable [%d entries]" % count)
			st_item.collapsed = false
			_item_map[st_item] = expo  # clicking navigates to StringTableDetail


## Returns the actual UObject ownership graph encoded by each export's
## one-based OuterIndex. Orphans and invalid/cyclic owners remain top-level.
static func build_export_hierarchy(asset: UAssetFile) -> Dictionary:
	var children: Dictionary = {}
	var roots: Array[int] = []
	for i in asset.exports.size():
		children[i] = []
	for i in asset.exports.size():
		var parent := asset.exports[i].outer_index - 1
		if parent >= 0 and parent < asset.exports.size() and parent != i:
			(children[parent] as Array).append(i)
		else:
			roots.append(i)
	return {"roots": roots, "children": children}


static func _visible_hierarchy_indices(asset: UAssetFile, matches: Array[int]) -> Dictionary:
	var visible := {}
	for match_index in matches:
		var current: int = match_index
		var visited := {}
		while current >= 0 and current < asset.exports.size() and not visited.has(current):
			visible[current] = true
			visited[current] = true
			var outer := asset.exports[current].outer_index
			current = outer - 1 if outer > 0 else -1
	return visible


## Fast, UI-independent matching kept static so it can be regression-tested.
## Terms are ANDed. `#123` jumps to a one-based export index.
static func find_export_indices(asset: UAssetFile, query: String) -> Array[int]:
	var result: Array[int] = []
	var normalized := query.strip_edges().to_lower()
	if normalized.begins_with("#") and normalized.substr(1).is_valid_int():
		var requested := normalized.substr(1).to_int() - 1
		if requested >= 0 and requested < asset.exports.size():
			result.append(requested)
		return result
	var terms := normalized.split(" ", false)
	for i in asset.exports.size():
		var expo := asset.exports[i]
		var haystack := (expo.object_name + " " + expo.export_type).to_lower()
		for prop in expo.properties:
			haystack += " " + _property_search_text(prop)
		var matches := true
		for term in terms:
			if not haystack.contains(term):
				matches = false
				break
		if matches:
			result.append(i)
	return result


static func _property_search_text(prop: UAssetProperty) -> String:
	var text := (prop.prop_name + " " + prop.prop_type + " " + prop.struct_type).to_lower()
	for child in prop.children:
		text += " " + _property_search_text(child)
	return text


## Rebuild the tree while preserving the user's expanded/selected state.
func rebuild_preserving_state() -> void:
	# Snapshot expanded state and current selection
	var expanded: Dictionary = {}
	var selected_data: Variant = null
	for item: TreeItem in _item_map:
		var mapped: Variant = _item_map[item]
		# Dictionary items (e.g. DataTable rows) can't be dict keys safely; skip
		if not mapped is Dictionary and not item.collapsed:
			expanded[mapped] = true
		if _tree.get_selected() == item:
			selected_data = mapped

	build_tree()

	# Restore expanded flags; also trigger lazy build for items that were previously open.
	for item: TreeItem in _item_map:
		var mapped: Variant = _item_map[item]
		if not mapped is Dictionary and expanded.has(mapped):
			item.collapsed = false
			_expand_lazy_item(item)

	# Restore selection (skip StringName section headers — not selectable data)
	if selected_data != null and not selected_data is StringName:
		for item: TreeItem in _item_map:
			var mapped: Variant = _item_map[item]
			if mapped is StringName:
				continue
			if typeof(mapped) != typeof(selected_data):
				continue
			if mapped == selected_data:
				_tree.set_selected(item, 0)
				break


# ── Selection helpers ──────────────────────────────────────────────────────────

## Find and select the tree item for data, expanding its ancestors so it is visible.
func select_item(data: Variant) -> void:
	for item in _item_map:
		var mapped: Variant = _item_map[item]
		if mapped is StringName:
			continue
		if typeof(mapped) != typeof(data):
			continue
		if mapped == data:
			# Expand ancestors so the item is reachable — but do NOT expand the item
			# itself here: if it has lazy children, setting collapsed=false would fire
			# item_collapsed inside a signal callback and hit the "blocked > 0" crash.
			var parent: TreeItem = item.get_parent()
			while parent and parent != _tree.get_root():
				parent.collapsed = false
				parent = parent.get_parent()
			_tree.set_selected(item, 0)
			_tree.scroll_to_item(item)
			_tree.queue_redraw()
			return


## Update the tree label for a property after its value changes.
func refresh_item_text(prop: UAssetProperty) -> void:
	for item in _item_map:
		if _item_map[item] is StringName:
			continue
		if _item_map[item] == prop:
			if prop.prop_type not in ["Struct", "Array", "Map"]:
				var val_str := prop.get_display_value()
				if val_str.length() > 40:
					val_str = val_str.left(37) + "..."
				item.set_text(0, "%s = %s" % [prop.prop_name, val_str])
			break


# ── Lazy-load helpers ─────────────────────────────────────────────────────────

## Registers a placeholder child under item so the expand arrow appears.
## build_fn is called once when the user actually opens the item.
func _add_lazy_placeholder(item: TreeItem, build_fn: Callable) -> void:
	var ph := _tree.create_item(item)
	ph.set_text(0, "")
	ph.set_metadata(0, "__lazy_placeholder__")
	_lazy_items[item] = build_fn


## Called by the item_collapsed signal; triggers lazy build on expansion.
## Deferred so create_item() is never called from inside a tree signal callback.
func _on_item_toggled(item: TreeItem) -> void:
	if item.collapsed:
		return  # nothing to do when folding
	(func() -> void: _expand_lazy_item(item)).call_deferred()


## If item has a pending lazy build, run it now and remove the placeholder.
func _expand_lazy_item(item: TreeItem) -> void:
	if not _lazy_items.has(item):
		return
	var build_fn: Callable = _lazy_items[item]
	_lazy_items.erase(item)
	# Remove the placeholder child before building real children.
	var ph := item.get_first_child()
	if ph != null and ph.get_metadata(0) == "__lazy_placeholder__":
		ph.free()
	build_fn.call()


# ── Private tree builders ─────────────────────────────────────────────────────

func _add_section(parent: TreeItem, text: String) -> TreeItem:
	var item := _tree.create_item(parent)
	item.set_text(0, text)
	item.collapsed = true
	return item


func _add_property_to_tree(parent: TreeItem, prop: UAssetProperty) -> TreeItem:
	var item := _tree.create_item(parent)
	_item_map[item] = prop

	match prop.prop_type:
		"Struct":
			item.set_text(0, "%s [%s]" % [prop.prop_name, prop.struct_type])
			for child in prop.children:
				if child.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"]:
					_add_property_to_tree(item, child)
		"Array":
			item.set_text(0, "%s [%d items]" % [prop.prop_name, prop.children.size()])
			for i in prop.children.size():
				var child := prop.children[i]
				if child.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"]:
					var ci := _add_property_to_tree(item, child)
					if child.prop_name.is_empty() or child.prop_name == prop.prop_name:
						ci.set_text(0, "[%d] %s" % [i, ci.get_text(0)])
		"Map":
			item.set_text(0, "%s [map · %d entries]" % [prop.prop_name, prop.children.size()])
			for i in prop.children.size():
				var pair := prop.children[i]
				if pair.prop_type != "MapPair":
					continue
				var pi := _tree.create_item(item)
				_item_map[pi] = pair
				var key_summary := PropertyDetail._map_pair_key_summary(pair)
				pi.set_text(0, "[%d] %s" % [i, key_summary])
				for child in pair.children:
					if child.prop_type in ["Struct", "Array", "Map", "GameplayTagContainer"] \
							and not child.children.is_empty():
						_add_property_to_tree(pi, child)
		"GameplayTagContainer":
			var count: int = prop.value.size() if prop.value is Array else 0
			item.set_text(0, "%s [%d tags]" % [prop.prop_name, count])

	item.collapsed = true
	return item
