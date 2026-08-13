class_name MeshPreviewMaterialLoader extends RefCounted

## Reconstructs simple Godot materials from umodel's exported .mat descriptors.
## Umodel's glTF contains material slot names, but keeps image references in
## sidecar files instead of embedding them in the glTF.

const IMAGE_EXTENSIONS := ["bmp", "jpeg", "jpg", "png", "tga", "webp"]


static func apply_to_scene(scene: Node, search_root: String) -> Dictionary:
	var files := _index_files(search_root)
	var material_cache := {}
	var texture_cache := {}
	var applied := 0
	var missing: Array[String] = []

	for mesh_instance in _get_mesh_instances(scene):
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		for surface_index in mesh.get_surface_count():
			var source := mesh_instance.get_active_material(surface_index)
			if source == null or source.resource_name.is_empty():
				continue
			var material_name := source.resource_name
			var key := material_name.to_lower()
			var descriptor_path := str(files["materials"].get(key, ""))
			if descriptor_path.is_empty():
				if material_name not in missing:
					missing.append(material_name)
				continue
			if not material_cache.has(key):
				material_cache[key] = _load_material(
					material_name, descriptor_path, files, texture_cache)
			var material: StandardMaterial3D = material_cache[key]
			if material != null:
				mesh_instance.set_surface_override_material(surface_index, material)
				applied += 1

	return {
		"applied": applied,
		"missing": missing,
		"texture_count": texture_cache.size(),
	}


static func parse_descriptor(text: String) -> Dictionary:
	var result := {}
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		var separator := line.find("=")
		if separator <= 0:
			continue
		var key := line.substr(0, separator).strip_edges()
		var value := line.substr(separator + 1).strip_edges()
		if not key.is_empty() and not value.is_empty():
			result[key] = value
	return result


static func _load_material(material_name: String, descriptor_path: String,
		files: Dictionary, texture_cache: Dictionary) -> StandardMaterial3D:
	var descriptor := parse_descriptor(FileAccess.get_file_as_string(descriptor_path))
	var material := StandardMaterial3D.new()
	material.resource_name = material_name
	material.metallic = 0.0
	material.roughness = 0.75
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	var diffuse_name := str(descriptor.get("Diffuse", ""))
	var diffuse := _load_texture(diffuse_name, descriptor_path, files["images"], texture_cache)
	if diffuse != null:
		material.albedo_texture = diffuse

	var normal_name := str(descriptor.get("Normal", ""))
	var normal := _load_texture(normal_name, descriptor_path, files["images"], texture_cache)
	if normal != null:
		material.normal_enabled = true
		material.normal_texture = normal

	var props_path := str(files["properties"].get(material_name.to_lower(), ""))
	if not props_path.is_empty():
		var props := FileAccess.get_file_as_string(props_path)
		if "BlendMode = BLEND_Masked" in props:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = 0.3333
		if "TwoSided = true" in props:
			material.cull_mode = BaseMaterial3D.CULL_DISABLED

	return material


static func _load_texture(texture_name: String, descriptor_path: String,
		image_index: Dictionary, texture_cache: Dictionary) -> Texture2D:
	if texture_name.is_empty():
		return null
	var key := texture_name.to_lower()
	if texture_cache.has(key):
		return texture_cache[key]
	var candidates: Array = image_index.get(key, [])
	if candidates.is_empty():
		return null

	var image_path := str(candidates[0])
	var material_dir := descriptor_path.get_base_dir()
	for candidate in candidates:
		if str(candidate).get_base_dir() == material_dir:
			image_path = str(candidate)
			break

	var image := Image.new()
	if image.load(image_path) != OK:
		return null
	if not image.has_mipmaps() and image.get_width() > 1 and image.get_height() > 1:
		image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	texture_cache[key] = texture
	return texture


static func _index_files(search_root: String) -> Dictionary:
	var result := {
		"materials": {},
		"properties": {},
		"images": {},
	}
	_index_directory(search_root, result)
	return result


static func _index_directory(dir_path: String, result: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var files := Array(dir.get_files())
	files.sort()
	for file_name in files:
		var lower_name := str(file_name).to_lower()
		var path := dir_path.path_join(str(file_name))
		if lower_name.ends_with(".props.txt"):
			var material_name := lower_name.trim_suffix(".props.txt")
			result["properties"][material_name] = path
		elif lower_name.ends_with(".mat"):
			result["materials"][lower_name.trim_suffix(".mat")] = path
		elif lower_name.get_extension() in IMAGE_EXTENSIONS:
			var image_name := lower_name.get_basename()
			if not result["images"].has(image_name):
				result["images"][image_name] = []
			result["images"][image_name].append(path)

	var directories := Array(dir.get_directories())
	directories.sort()
	for child_dir in directories:
		if not str(child_dir).begins_with("."):
			_index_directory(dir_path.path_join(str(child_dir)), result)


static func _get_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_get_mesh_instances(child))
	return result
