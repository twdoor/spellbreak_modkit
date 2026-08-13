class_name ParticleMaterialAnalyzer extends RefCounted

## Reads the small subset of UE material metadata needed by particle previews.

static func preview_alpha(asset: UAssetFile) -> float:
	var alpha := 1.0
	for expo in asset.exports:
		for prop in expo.properties:
			alpha *= _alpha_from_property(prop)
	return clampf(alpha, 0.0, 1.0)


static func preview_blend_mode(asset: UAssetFile) -> String:
	for expo in asset.exports:
		for prop in expo.properties:
			var mode := _blend_mode_from_property(prop)
			if not mode.is_empty():
				return mode
	return ""


static func texture_score(path: String) -> int:
	var name := path.get_file().get_basename().to_lower()
	var score := 0
	for token in ["base", "diffuse", "albedo", "color", "campfire", "flame", "smoke"]:
		if name.contains(token):
			score += 4
	for token in ["normal", "_n", "noise", "mask", "erosion", "height"]:
		if name.contains(token):
			score -= 3
	return score


static func _blend_mode_from_property(prop: UAssetProperty) -> String:
	if prop == null:
		return ""
	if prop.prop_name == "BlendMode":
		if prop.value != null:
			return str(prop.value)
		return str(prop.raw.get("EnumValue", prop.raw.get("Value", "")))
	for child in prop.children:
		var mode := _blend_mode_from_property(child)
		if not mode.is_empty():
			return mode
	return ""


static func _alpha_from_property(prop: UAssetProperty) -> float:
	if prop == null:
		return 1.0
	if prop.prop_name == "ScalarParameterValues":
		var alpha := 1.0
		for child in prop.children:
			if _is_alpha_parameter(_parameter_name(child)):
				alpha *= clampf(_numeric_value(child.find_child("ParameterValue"), 1.0), 0.0, 1.0)
		return alpha
	if prop.prop_name == "VectorParameterValues":
		var alpha := 1.0
		for child in prop.children:
			if _is_color_parameter(_parameter_name(child)):
				alpha *= clampf(_color_alpha(child.find_child("ParameterValue")), 0.0, 1.0)
		return alpha
	var child_alpha := 1.0
	for child in prop.children:
		child_alpha *= _alpha_from_property(child)
	return child_alpha


static func _parameter_name(parameter_struct: UAssetProperty) -> String:
	if parameter_struct == null:
		return ""
	var info := parameter_struct.find_child("ParameterInfo")
	var name_prop := info.find_child("Name") if info != null else null
	return str(name_prop.value) if name_prop != null and name_prop.value != null else ""


static func _is_alpha_parameter(parameter_name: String) -> bool:
	var name := parameter_name.to_lower()
	for excluded in ["min", "max", "mask", "clip", "depth", "fade", "distance", "refraction"]:
		if name.contains(excluded):
			return false
	return name.contains("opacity") or name.contains("alpha") or name.contains("translucency")


static func _is_color_parameter(parameter_name: String) -> bool:
	var name := parameter_name.to_lower()
	return name.contains("color") or name.contains("tint") or name.contains("albedo")


static func _numeric_value(prop: UAssetProperty, fallback: float) -> float:
	if prop == null:
		return fallback
	var value: Variant = prop.value
	if value is int or value is float:
		return float(value)
	if value is String and str(value).is_valid_float():
		return float(value)
	return fallback


static func _color_alpha(prop: UAssetProperty) -> float:
	if prop == null:
		return 1.0
	var value: Variant = prop.value if prop.value is Dictionary else prop.raw.get("Value")
	if value is Dictionary:
		return float((value as Dictionary).get("A", 1.0))
	var alpha := prop.find_child("A")
	return _numeric_value(alpha, 1.0)
