class_name Md5AnimLoader extends RefCounted

## Parses umodel's MD5Anim export and builds Godot bone animation tracks.
## Umodel already applies its Unreal-to-MD5 mirroring. The remaining conversion
## to the Godot glTF skeleton basis is:
##   position:   (x, y, z) cm -> (x, z, -y) m
##   quaternion: (x, y, z, w) -> (x, z, -y, -w)

const ANIMATION_NAME := &"preview"
const POSITION_SCALE := 0.01
const POSITION_EPSILON := 0.0001
const FLATTENED_ROTATION_LOCAL := "local"
const FLATTENED_ROTATION_DELTA := "delta"
const DELTA_IDENTITY_ANGLE_DEGREES := 2.0
const DELTA_IDENTITY_RATIO := 0.55


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Animation file not found: %s" % path}
	return parse_text(FileAccess.get_file_as_string(path), path.get_file().get_basename())


static func parse_text(text: String, fallback_name: String = "preview") -> Dictionary:
	var result := {
		"ok": false,
		"error": "",
		"name": fallback_name,
		"num_frames": 0,
		"num_joints": 0,
		"frame_rate": 0.0,
		"num_components": 0,
		"joints": [],
		"baseframe": [],
		"frames": [],
	}
	var section := ""
	var current_frame := -1
	var raw_frames: Array[PackedFloat64Array] = []

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("commandline"):
			continue
		if line.begins_with("numFrames"):
			result["num_frames"] = _line_int_value(line)
			continue
		if line.begins_with("numJoints"):
			result["num_joints"] = _line_int_value(line)
			continue
		if line.begins_with("frameRate"):
			result["frame_rate"] = _line_float_value(line)
			continue
		if line.begins_with("numAnimatedComponents"):
			result["num_components"] = _line_int_value(line)
			continue
		if line == "hierarchy {":
			section = "hierarchy"
			continue
		if line == "bounds {":
			section = "bounds"
			continue
		if line == "baseframe {":
			section = "baseframe"
			continue
		if line.begins_with("frame ") and line.ends_with("{"):
			section = "frame"
			current_frame = _line_int_value(line)
			while raw_frames.size() <= current_frame:
				raw_frames.append(PackedFloat64Array())
			continue
		if line == "}":
			section = ""
			current_frame = -1
			continue

		match section:
			"hierarchy":
				var joint := _parse_hierarchy_line(line)
				if not joint.is_empty():
					result["joints"].append(joint)
			"baseframe":
				var base_values := _parse_transform_line(line)
				if base_values.has("ok"):
					result["baseframe"].append(base_values)
			"frame":
				if current_frame >= 0:
					raw_frames[current_frame].append_array(_numbers_in_line(line))

	if int(result["num_frames"]) <= 0:
		return _parse_error(result, "MD5Anim has no frames")
	if int(result["num_joints"]) <= 0:
		return _parse_error(result, "MD5Anim has no joints")
	if float(result["frame_rate"]) <= 0.0:
		return _parse_error(result, "MD5Anim has an invalid frame rate")
	if result["joints"].size() != int(result["num_joints"]):
		return _parse_error(result, "MD5Anim joint count does not match header")
	if result["baseframe"].size() != int(result["num_joints"]):
		return _parse_error(result, "MD5Anim baseframe count does not match joint count")
	if raw_frames.size() != int(result["num_frames"]):
		return _parse_error(result, "MD5Anim frame count does not match header")

	var frame_result := _build_frame_transforms(result["joints"], result["baseframe"], raw_frames,
		int(result["num_components"]))
	if not bool(frame_result.get("ok", false)):
		return _parse_error(result, str(frame_result.get("error", "MD5Anim frame data is invalid")))
	result["frames"] = frame_result["frames"]

	result["ok"] = true
	return result


static func build_animation(parsed: Dictionary, skeleton: Skeleton3D, root: Node,
		loop: bool = true) -> Dictionary:
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": str(parsed.get("error", "Invalid animation"))}
	if skeleton == null or root == null:
		return {"ok": false, "error": "Animation preview has no skeleton"}

	var animation := Animation.new()
	var frame_rate := float(parsed["frame_rate"])
	var frame_count := int(parsed["num_frames"])
	animation.length = maxf(1.0 / frame_rate, float(maxi(frame_count - 1, 1)) / frame_rate)
	animation.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE

	var joints: Array = parsed["joints"]
	var frames: Array = parsed["frames"]
	var missing: Array[String] = []
	var animated_bones := 0
	var position_bones := 0
	var skeleton_path := root.get_path_to(skeleton)
	var flattened_hierarchy := _has_flattened_hierarchy(joints)
	var flattened_rotation_mode := FLATTENED_ROTATION_LOCAL
	if flattened_hierarchy:
		flattened_rotation_mode = _flattened_rotation_mode(joints, frames, skeleton)

	for joint_index in joints.size():
		var joint: Dictionary = joints[joint_index]
		var bone_name := str(joint["name"])
		var bone_index := skeleton.find_bone(bone_name)
		if bone_index < 0:
			missing.append(bone_name)
			continue
		var track_path := NodePath("%s:%s" % [str(skeleton_path), bone_name])
		var should_write_position := _should_write_position_track(
			frames, joint_index, joint, flattened_hierarchy)
		var position_track := -1
		if should_write_position:
			position_track = animation.add_track(Animation.TYPE_POSITION_3D)
			animation.track_set_path(position_track, track_path)
			position_bones += 1
		var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(rotation_track, track_path)

		for frame_index in frames.size():
			var transform: Dictionary = frames[frame_index][joint_index]
			var time := float(frame_index) / frame_rate
			if position_track >= 0:
				animation.position_track_insert_key(position_track, time, transform["position"])
			var rotation: Quaternion = transform["rotation"]
			if flattened_hierarchy:
				rotation = _flattened_rotation_key(
					rotation, skeleton, bone_index, flattened_rotation_mode)
			animation.rotation_track_insert_key(rotation_track, time, rotation)
		animated_bones += 1

	if animated_bones <= 0:
		return {
			"ok": false,
			"error": "Animation skeleton is incompatible with this mesh",
			"missing_bones": missing,
		}
	return {
		"ok": true,
		"animation": animation,
		"name": str(parsed.get("name", "preview")),
		"frame_count": frame_count,
		"frame_rate": frame_rate,
		"duration": animation.length,
		"animated_bones": animated_bones,
		"position_bones": position_bones,
		"missing_bones": missing,
		"flattened_hierarchy": flattened_hierarchy,
		"rotation_mode": flattened_rotation_mode,
		"target_bone_count": skeleton.get_bone_count(),
	}


static func _parse_error(result: Dictionary, message: String) -> Dictionary:
	result["ok"] = false
	result["error"] = message
	return result


static func _parse_hierarchy_line(line: String) -> Dictionary:
	var first_quote := line.find("\"")
	var second_quote := line.find("\"", first_quote + 1)
	if first_quote < 0 or second_quote <= first_quote:
		return {}
	var name := line.substr(first_quote + 1, second_quote - first_quote - 1)
	var rest := line.substr(second_quote + 1).strip_edges().split(" ", false)
	if rest.size() < 3:
		return {}
	return {
		"name": name,
		"parent": int(rest[0]),
		"flags": int(rest[1]),
		"start": int(rest[2]),
	}


static func _parse_transform_line(line: String) -> Dictionary:
	var values := _numbers_in_line(line)
	if values.size() < 6:
		return {}
	var raw_position := Vector3(values[0], values[1], values[2])
	var raw_rotation := Vector3(values[3], values[4], values[5])
	var transform := _build_transform(raw_position, raw_rotation)
	return {
		"ok": true,
		"raw_position": raw_position,
		"raw_rotation": raw_rotation,
		"position": transform["position"],
		"rotation": transform["rotation"],
	}


static func _build_frame_transforms(joints: Array, baseframe: Array,
		raw_frames: Array[PackedFloat64Array], expected_components: int) -> Dictionary:
	var frames: Array = []
	for frame_values in raw_frames:
		if expected_components > 0 and frame_values.size() != expected_components:
			return {
				"ok": false,
				"error": "MD5Anim frame has %d animated components, expected %d" % [
					frame_values.size(), expected_components],
			}
		var frame: Array = []
		for joint_index in joints.size():
			var joint: Dictionary = joints[joint_index]
			var base: Dictionary = baseframe[joint_index]
			var position: Vector3 = base["raw_position"]
			var rotation: Vector3 = base["raw_rotation"]
			var component_index := int(joint["start"])
			var flags := int(joint["flags"])

			if flags & 1:
				if component_index >= frame_values.size():
					return _component_error(joint)
				position.x = frame_values[component_index]
				component_index += 1
			if flags & 2:
				if component_index >= frame_values.size():
					return _component_error(joint)
				position.y = frame_values[component_index]
				component_index += 1
			if flags & 4:
				if component_index >= frame_values.size():
					return _component_error(joint)
				position.z = frame_values[component_index]
				component_index += 1
			if flags & 8:
				if component_index >= frame_values.size():
					return _component_error(joint)
				rotation.x = frame_values[component_index]
				component_index += 1
			if flags & 16:
				if component_index >= frame_values.size():
					return _component_error(joint)
				rotation.y = frame_values[component_index]
				component_index += 1
			if flags & 32:
				if component_index >= frame_values.size():
					return _component_error(joint)
				rotation.z = frame_values[component_index]
			frame.append(_build_transform(position, rotation))
		frames.append(frame)
	return {"ok": true, "frames": frames}


static func _component_error(joint: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"error": "MD5Anim frame data is missing components for bone %s" % str(joint.get("name", "")),
	}


static func _has_flattened_hierarchy(joints: Array) -> bool:
	var non_root_count := 0
	var root_parent_count := 0
	for joint_index in joints.size():
		var parent := int((joints[joint_index] as Dictionary).get("parent", -1))
		if parent < 0:
			continue
		non_root_count += 1
		if parent == 0:
			root_parent_count += 1
	return non_root_count >= 8 and float(root_parent_count) / float(non_root_count) >= 0.8


static func _flattened_rotation_mode(joints: Array, frames: Array, skeleton: Skeleton3D) -> String:
	if frames.is_empty():
		return FLATTENED_ROTATION_LOCAL
	var first_frame: Array = frames[0]
	var sample_count := 0
	var identity_count := 0
	var angles: Array[float] = []
	for joint_index in joints.size():
		if joint_index >= first_frame.size():
			continue
		var bone_name := str((joints[joint_index] as Dictionary).get("name", ""))
		var bone_index := skeleton.find_bone(bone_name)
		if bone_index < 0 or skeleton.get_bone_parent(bone_index) < 0:
			continue
		var transform: Dictionary = first_frame[joint_index]
		var rotation: Quaternion = transform["rotation"]
		var angle := _rotation_angle_degrees(rotation)
		angles.append(angle)
		sample_count += 1
		if angle <= DELTA_IDENTITY_ANGLE_DEGREES:
			identity_count += 1
	if sample_count <= 0:
		return FLATTENED_ROTATION_LOCAL
	angles.sort()
	var median_index := floori(float(angles.size()) / 2.0)
	var median_angle := angles[median_index]
	var identity_ratio := float(identity_count) / float(sample_count)
	if identity_ratio >= DELTA_IDENTITY_RATIO and median_angle <= DELTA_IDENTITY_ANGLE_DEGREES:
		return FLATTENED_ROTATION_DELTA
	return FLATTENED_ROTATION_LOCAL


static func _should_write_position_track(frames: Array, joint_index: int, joint: Dictionary,
		flattened_hierarchy: bool) -> bool:
	if flattened_hierarchy and int(joint.get("parent", -1)) >= 0:
		return false
	for frame in frames:
		var transform: Dictionary = frame[joint_index]
		var position: Vector3 = transform["position"]
		if position.length() > POSITION_EPSILON:
			return true
	return false


static func _flattened_rotation_key(rotation: Quaternion, skeleton: Skeleton3D, bone_index: int,
		rotation_mode: String) -> Quaternion:
	if rotation_mode == FLATTENED_ROTATION_DELTA:
		return (_bone_rest_rotation(skeleton, bone_index) * rotation).normalized()
	return rotation.normalized()


static func _bone_rest_rotation(skeleton: Skeleton3D, bone_index: int) -> Quaternion:
	return skeleton.get_bone_rest(bone_index).basis.get_rotation_quaternion().normalized()


static func _rotation_angle_degrees(rotation: Quaternion) -> float:
	var normalized := rotation.normalized()
	var w := clampf(absf(normalized.w), 0.0, 1.0)
	return rad_to_deg(2.0 * acos(w))


static func _build_transform(md5_position: Vector3, md5_rotation: Vector3) -> Dictionary:
	var position := Vector3(md5_position.x, md5_position.z, -md5_position.y) * POSITION_SCALE
	return {
		"position": position,
		"rotation": _convert_quaternion(md5_rotation),
	}


static func _convert_quaternion(md5_rotation: Vector3) -> Quaternion:
	var x := md5_rotation.x
	var y := md5_rotation.y
	var z := md5_rotation.z
	var w_sq := 1.0 - x * x - y * y - z * z
	var w := sqrt(maxf(w_sq, 0.0))
	return Quaternion(x, z, -y, -w).normalized()


static func _line_int_value(line: String) -> int:
	var parts := line.split(" ", false)
	return int(parts[1]) if parts.size() > 1 else 0


static func _line_float_value(line: String) -> float:
	var parts := line.split(" ", false)
	return float(parts[1]) if parts.size() > 1 else 0.0


static func _numbers_in_line(line: String) -> PackedFloat64Array:
	var regex := RegEx.new()
	regex.compile("[-+]?\\d*\\.?\\d+(?:[eE][-+]?\\d+)?")
	var values := PackedFloat64Array()
	for match_result in regex.search_all(line):
		values.append(float(match_result.get_string()))
	return values
