class_name ExportReorderer extends RefCounted

## Swaps two exports at indices a and b, remapping every index reference that
## pointed to either one throughout the entire asset (exports, imports, properties).
## After calling swap(), the caller is responsible for rebuilding the tree.

func swap(a: int, b: int, asset: UAssetFile) -> void:
	if a < 0 or b < 0 or a >= asset.exports.size() or b >= asset.exports.size():
		return

	# 1-based indices as seen in the file format
	var idx_a := a + 1
	var idx_b := b + 1

	# Swap in the array
	var tmp := asset.exports[a]
	asset.exports[a] = asset.exports[b]
	asset.exports[b] = tmp

	# Remap helper: swaps idx_a ↔ idx_b, leaves everything else alone
	var idx_remap := func(v: int) -> int:
		if v == idx_a: return idx_b
		if v == idx_b: return idx_a
		return v

	# Update export metadata references
	for expo in asset.exports:
		expo.outer_index    = idx_remap.call(expo.outer_index)
		expo.class_index    = idx_remap.call(expo.class_index)
		expo.super_index    = idx_remap.call(expo.super_index)
		expo.template_index = idx_remap.call(expo.template_index)
		expo.raw["OuterIndex"]    = expo.outer_index
		expo.raw["ClassIndex"]    = expo.class_index
		expo.raw["SuperIndex"]    = expo.super_index
		expo.raw["TemplateIndex"] = expo.template_index
		for prop in expo.properties:
			_remap_prop_indices(prop, idx_remap)

	# Update import outer indices (imports use positive values for export outers)
	for imp in asset.imports:
		var new_outer: int = idx_remap.call(imp.outer_index)
		if new_outer != imp.outer_index:
			imp.outer_index = new_outer
			imp.raw["OuterIndex"] = new_outer


## Recursively remap positive Object index values inside a property tree.
func _remap_prop_indices(prop: UAssetProperty, remap_fn: Callable) -> void:
	if prop.prop_type == "Object":
		var v := int(prop.value) if prop.value != null else 0
		var nv: int = remap_fn.call(v)
		if nv != v:
			prop.value = nv
			prop.raw["Value"] = nv
	for child in prop.children:
		_remap_prop_indices(child, remap_fn)
