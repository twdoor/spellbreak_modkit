class_name SoundDetail extends DetailItem

## Detail view for a SoundWave export: audio playback controls, export button,
## and standard export metadata below.  Audio is extracted asynchronously via
## SoundService.  Pattern mirrors TextureDetail.

var _expo: UAssetExport
var _class_name: String

var _player: AudioStreamPlayer
var _play_btn: Button
var _stop_btn: Button
var _time_label: Label
var _seek_slider: HSlider
var _export_btn: Button
var _import_btn: Button
var _status_label: Label
var _extract_thread: Thread

var _audio_bytes: PackedByteArray
var _updating_slider: bool = false


func init_data(expo: UAssetExport, cls_name: String) -> SoundDetail:
	_expo = expo
	_class_name = cls_name
	return self


func _build_impl() -> void:
	var expo := _expo

	# Header
	var hdr := HBoxContainer.new()
	var hdr_label := Label.new()
	hdr_label.text = "Export: %s" % expo.object_name
	hdr_label.add_theme_font_size_override("font_size", 16)
	hdr_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(hdr_label)
	_container.add_child(hdr)

	_add_type_badge(_class_name)
	_add_separator()

	# ── Audio preview section ────────────────────────────────────────────────
	_add_section_label("AUDIO PREVIEW")

	var snd_service: SoundService = _ctx.get("sound_service")

	if snd_service == null:
		_add_info("SoundService not available.")
	else:
		# Loading label (shown while extracting audio)
		_status_label = Label.new()
		_status_label.text = "Extracting audio..."
		_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_status_label.add_theme_font_size_override("font_size", 13)
		_container.add_child(_status_label)

		# Player controls (hidden until audio loads)
		var controls := VBoxContainer.new()
		controls.name = "AudioControls"
		controls.visible = false

		# Seek slider
		_seek_slider = HSlider.new()
		_seek_slider.min_value = 0.0
		_seek_slider.max_value = 1.0
		_seek_slider.step = 0.001
		_seek_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_seek_slider.custom_minimum_size = Vector2(0, 24)
		_seek_slider.value_changed.connect(_on_seek)
		controls.add_child(_seek_slider)

		# Button row: Play | Stop | Time
		var btn_row := HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 8)

		_play_btn = Button.new()
		_play_btn.text = "Play"
		_play_btn.pressed.connect(_on_play_pressed)
		btn_row.add_child(_play_btn)

		_stop_btn = Button.new()
		_stop_btn.text = "Stop"
		_stop_btn.pressed.connect(_on_stop_pressed)
		btn_row.add_child(_stop_btn)

		_time_label = Label.new()
		_time_label.text = "0:00 / 0:00"
		_time_label.add_theme_font_size_override("font_size", 13)
		_time_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn_row.add_child(_time_label)

		controls.add_child(btn_row)
		_container.add_child(controls)

		# Create AudioStreamPlayer (add to scene tree via container)
		_player = AudioStreamPlayer.new()
		_player.finished.connect(_on_playback_finished)
		_container.add_child(_player)

		# Start extracting audio
		_load_audio_async(snd_service)

	_add_separator()

	# ── Audio actions ────────────────────────────────────────────────────────
	_add_section_label("AUDIO ACTIONS")

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)

	_export_btn = Button.new()
	_export_btn.text = "Export as OGG..."
	_export_btn.pressed.connect(_on_export_pressed)
	action_row.add_child(_export_btn)

	_import_btn = Button.new()
	_import_btn.text = "Import OGG..."
	_import_btn.pressed.connect(_on_import_pressed)
	action_row.add_child(_import_btn)

	if snd_service == null:
		_export_btn.disabled = true
		_export_btn.tooltip_text = "SoundService not available"
		_import_btn.disabled = true
		_import_btn.tooltip_text = "SoundService not available"

	_container.add_child(action_row)

	# Status label for export feedback (reuse _status_label if already created)
	if _status_label == null:
		_status_label = Label.new()
		_status_label.add_theme_font_size_override("font_size", 12)
		_status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_container.add_child(_status_label)

	_add_separator()

	# ── Standard export detail (references, properties, dependencies) ────────
	_add_section_label("REFERENCES")
	_add_field_editor("ObjectName", expo.object_name, func(v):
		expo.object_name = v
		expo.raw["ObjectName"] = v
		hdr_label.text = "Export: %s" % v
	)
	_add_ref_row("ClassIndex", expo.class_index, func(v):
		expo.class_index = v; expo.raw["ClassIndex"] = v)
	_add_ref_row("SuperIndex", expo.super_index, func(v):
		expo.super_index = v; expo.raw["SuperIndex"] = v)
	_add_ref_row("OuterIndex", expo.outer_index, func(v):
		expo.outer_index = v; expo.raw["OuterIndex"] = v)
	_add_ref_row("TemplateIndex", expo.template_index, func(v):
		expo.template_index = v; expo.raw["TemplateIndex"] = v)
	_add_field_editor("ObjectFlags", expo.object_flags, func(v):
		expo.object_flags = v; expo.raw["ObjectFlags"] = v)

	# Leaf properties
	var has_props := false
	var leaf_props: Array[UAssetProperty] = []
	for prop in expo.properties:
		if prop.prop_type not in ["Struct", "Array", "GameplayTagContainer"]:
			leaf_props.append(prop)
	var get_leaves: Callable = func() -> Array: return leaf_props
	for prop in leaf_props:
		if not has_props:
			_add_separator()
			_add_section_label("PROPERTIES")
			has_props = true
		_add_selectable_property_row(prop, get_leaves)

	# Dependencies
	_add_separator()
	_add_section_label("DEPENDENCIES")
	for field in [
		"CreateBeforeCreateDependencies",
		"CreateBeforeSerializationDependencies",
		"SerializationBeforeCreateDependencies",
		"SerializationBeforeSerializationDependencies"
	]:
		_add_dep_array_row(field, expo)


# ── Audio loading ────────────────────────────────────────────────────────────


func _load_audio_async(snd_service: SoundService) -> void:
	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	if not uasset_path.ends_with(".uasset"):
		_status_label.text = "Audio preview requires a .uasset file (not JSON)"
		return

	# Check cache first
	var cached := snd_service.get_cached_audio(uasset_path)
	if not cached.is_empty():
		var fa := FileAccess.open(cached, FileAccess.READ)
		if fa:
			var data := fa.get_buffer(fa.get_length())
			fa.close()
			if not data.is_empty():
				_on_audio_extracted(data)
				return

	# Extract in background thread
	_extract_thread = Thread.new()
	_extract_thread.start(_extract_worker.bind(snd_service, uasset_path))


func _extract_worker(snd_service: SoundService, uasset_path: String) -> void:
	var data := snd_service.get_audio_data(uasset_path)
	call_deferred("_on_audio_loaded", data)


func _on_audio_loaded(data: PackedByteArray) -> void:
	if _extract_thread:
		_extract_thread.wait_to_finish()
		_extract_thread = null
	if not data.is_empty():
		_on_audio_extracted(data)
	else:
		if is_instance_valid(_status_label):
			_status_label.text = "No audio data found in this asset"
			_status_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))


func _on_audio_extracted(data: PackedByteArray) -> void:
	_audio_bytes = data

	# Load into AudioStreamOggVorbis
	var stream := AudioStreamOggVorbis.load_from_buffer(data)
	if stream == null:
		if is_instance_valid(_status_label):
			_status_label.text = "Failed to decode OGG audio (%d bytes)" % data.size()
			_status_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		return

	if not is_instance_valid(_player):
		return

	_player.stream = stream

	# Show controls
	var controls := _container.find_child("AudioControls", false, false)
	if controls:
		controls.visible = true

	# Update status
	if is_instance_valid(_status_label):
		var duration := stream.get_length()
		_status_label.text = "Audio loaded — %s — %d bytes" % [_format_time(duration), data.size()]
		_status_label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))

	# Update time label
	if is_instance_valid(_time_label):
		var duration := stream.get_length()
		_time_label.text = "0:00 / %s" % _format_time(duration)

	# Set up slider max
	if is_instance_valid(_seek_slider):
		_seek_slider.max_value = stream.get_length()


# ── Playback controls ────────────────────────────────────────────────────────


func _on_play_pressed() -> void:
	if not is_instance_valid(_player) or _player.stream == null:
		return
	if _player.playing:
		_player.stream_paused = not _player.stream_paused
		_play_btn.text = "Play" if _player.stream_paused else "Pause"
	else:
		_player.play()
		_play_btn.text = "Pause"
		# Start updating slider
		_start_timer()


func _on_stop_pressed() -> void:
	if not is_instance_valid(_player):
		return
	_player.stop()
	_play_btn.text = "Play"
	if is_instance_valid(_seek_slider):
		_updating_slider = true
		_seek_slider.value = 0.0
		_updating_slider = false
	_update_time_label(0.0)


func _on_playback_finished() -> void:
	if is_instance_valid(_play_btn):
		_play_btn.text = "Play"
	if is_instance_valid(_seek_slider):
		_updating_slider = true
		_seek_slider.value = 0.0
		_updating_slider = false
	_update_time_label(0.0)


func _on_seek(value: float) -> void:
	if _updating_slider:
		return
	if not is_instance_valid(_player) or _player.stream == null:
		return
	if _player.playing:
		_player.seek(value)
	_update_time_label(value)


func _start_timer() -> void:
	if not is_instance_valid(_container):
		return
	# Use a Timer node for periodic updates during playback
	var existing := _container.find_child("PlaybackTimer", false, false)
	if existing:
		return
	var timer := Timer.new()
	timer.name = "PlaybackTimer"
	timer.wait_time = 0.1
	timer.autostart = true
	timer.timeout.connect(_on_timer_tick)
	_container.add_child(timer)


func _on_timer_tick() -> void:
	if not is_instance_valid(_player) or not _player.playing or _player.stream_paused:
		return
	var pos := _player.get_playback_position()
	_updating_slider = true
	if is_instance_valid(_seek_slider):
		_seek_slider.value = pos
	_updating_slider = false
	_update_time_label(pos)


func _update_time_label(pos: float) -> void:
	if not is_instance_valid(_time_label) or not is_instance_valid(_player) or _player.stream == null:
		return
	var duration := _player.stream.get_length()
	_time_label.text = "%s / %s" % [_format_time(pos), _format_time(duration)]


# ── Export action ────────────────────────────────────────────────────────────


func _on_export_pressed() -> void:
	var snd_service: SoundService = _ctx.get("sound_service")
	if snd_service == null or snd_service.is_busy():
		return

	# If we already have the audio bytes, write directly; otherwise extract first
	if _audio_bytes.is_empty():
		if is_instance_valid(_status_label):
			_status_label.text = "No audio data to export"
			_status_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		return

	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.ogg ; OGG Vorbis Audio"])
	dialog.current_file = uasset_path.get_file().get_basename() + ".ogg"
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		var fa := FileAccess.open(path, FileAccess.WRITE)
		if fa:
			fa.store_buffer(_audio_bytes)
			fa.close()
			if is_instance_valid(_status_label):
				_status_label.text = "Exported to %s" % path.get_file()
				_status_label.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
		else:
			if is_instance_valid(_status_label):
				_status_label.text = "Failed to write: %s" % path
				_status_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		dialog.queue_free()
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


# ── Import action ────────────────────────────────────────────────────────────


func _on_import_pressed() -> void:
	var snd_service: SoundService = _ctx.get("sound_service")
	if snd_service == null or snd_service.is_busy():
		return

	var asset: UAssetFile = _ctx["asset"]
	var uasset_path := asset.binary_path if not asset.binary_path.is_empty() else asset.file_path
	if not uasset_path.ends_with(".uasset"):
		if is_instance_valid(_status_label):
			_status_label.text = "Import requires a .uasset file (not JSON)"
			_status_label.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		return

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.ogg ; OGG Vorbis Audio"])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path: String) -> void:
		_status_label.text = "Injecting..."
		_export_btn.disabled = true
		_import_btn.disabled = true
		snd_service.operation_finished.connect(_on_import_finished, CONNECT_ONE_SHOT)
		snd_service.inject_ogg(uasset_path, path)
		dialog.queue_free()
	)
	_container.get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))


func _on_import_finished(success: bool, message: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = message
		_status_label.add_theme_color_override("font_color",
			Color(0.4, 0.8, 0.4) if success else Color(0.8, 0.4, 0.4))
	if is_instance_valid(_export_btn):
		_export_btn.disabled = false
	if is_instance_valid(_import_btn):
		_import_btn.disabled = false
	# Reload preview after successful import
	if success:
		var snd_service: SoundService = _ctx.get("sound_service")
		if snd_service:
			_load_audio_async(snd_service)


# ── Helpers ──────────────────────────────────────────────────────────────────


func _format_time(seconds: float) -> String:
	var mins := int(seconds) / 60.0
	var secs := int(seconds) % 60
	return "%d:%02d" % [mins, secs]


## Shared ref-row helper (same as TextureDetail / ExportDetail).
func _add_ref_row(label_text: String, current_index: int, on_change: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hbox.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = -2147483648
	spin.max_value = 2147483647
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.rounded = true
	spin.step = 1
	spin.custom_minimum_size.x = 80
	spin.value = current_index
	hbox.add_child(spin)

	var ref_label := Label.new()
	ref_label.text = PropertyRow._resolve_ref_name(current_index, _ctx["asset"])
	ref_label.tooltip_text = PropertyRow._resolve_ref_type(current_index, _ctx["asset"])
	ref_label.add_theme_font_size_override("font_size", 13)
	ref_label.add_theme_color_override("font_color", Color(0.45, 0.65, 0.9))
	ref_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_label.clip_text = true
	ref_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(ref_label)

	spin.value_changed.connect(func(v):
		_ctx["set_dirty"].call()
		on_change.call(int(v))
		ref_label.text = PropertyRow._resolve_ref_name(int(v), _ctx["asset"])
		ref_label.tooltip_text = PropertyRow._resolve_ref_type(int(v), _ctx["asset"])
	)
	_container.add_child(hbox)


func _add_dep_array_row(field: String, expo: UAssetExport) -> void:
	var raw_val = expo.raw.get(field)
	var indices: Array = raw_val if raw_val is Array else []

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = field.replace("Dependencies", "Deps")
	label.custom_minimum_size.x = PropertyRow.LABEL_MIN_WIDTH
	label.size_flags_horizontal = Control.SIZE_FILL
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.tooltip_text = field
	hbox.add_child(label)

	var tip_parts: PackedStringArray = []
	for idx in indices:
		tip_parts.append("%d -> %s" % [idx, _resolve_dep_index(idx)])

	var line := LineEdit.new()
	line.text = ", ".join(PackedStringArray(indices.map(func(i): return str(i))))
	line.placeholder_text = "(empty)"
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.tooltip_text = "\n".join(tip_parts) if tip_parts.size() > 0 else "(none)"
	line.text_submitted.connect(func(t: String):
		var new_indices: Array = []
		for part in t.split(","):
			var s := part.strip_edges()
			if s.is_empty(): continue
			if s.is_valid_int(): new_indices.append(s.to_int())
		expo.raw[field] = new_indices
		_ctx["set_dirty"].call()
		var new_tip: PackedStringArray = []
		for idx_val in new_indices:
			new_tip.append("%d -> %s" % [idx_val, _resolve_dep_index(idx_val)])
		line.tooltip_text = "\n".join(new_tip) if new_tip.size() > 0 else "(none)"
	)
	hbox.add_child(line)
	_container.add_child(hbox)


func _resolve_dep_index(idx: int) -> String:
	var asset: UAssetFile = _ctx["asset"]
	if idx > 0 and idx <= asset.exports.size():
		return asset.exports[idx - 1].object_name
	if idx < 0:
		var imp := asset.get_import(idx)
		if imp:
			return imp.object_name
	return "?"
