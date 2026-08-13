class_name SoundService extends BackgroundOperationService

## Extracts audio data from UE4 SoundWave .uasset files by locating OGG Vorbis
## data in the companion .uexp / .ubulk files.  No external tools required —
## UE4 4.22 stores audio as raw OGG which Godot can play directly.
##
## Pattern mirrors TextureService: synchronous helpers called from worker threads,
## results marshalled back to the main thread via call_deferred().

signal operation_finished(result: OperationResult)

var _cfg: ModConfigManager

## OGG Vorbis magic bytes: "OggS"
static var OGG_MAGIC := PackedByteArray([0x4F, 0x67, 0x67, 0x53])

## Temp directory for audio cache
const CACHE_DIR := "sb_audio_cache"


func setup(cfg: ModConfigManager) -> SoundService:
	_cfg = cfg
	return self


# ── Public API ────────────────────────────────────────────────────────────────


## Extract audio from a SoundWave .uasset and return it as a PackedByteArray.
## Synchronous — intended to be called from a worker thread.
## Returns empty array on failure.
func get_audio_data(uasset_path: String) -> PackedByteArray:
	var result := _do_extract_audio(uasset_path)
	if not result.ok:
		return PackedByteArray()
	return result.value as PackedByteArray


## Export audio from a SoundWave .uasset to an .ogg file.
## Runs in a background thread. Emits operation_finished when done.
func export_ogg(uasset_path: String, output_ogg: String) -> void:
	_start_operation(_do_export_ogg.bind(uasset_path, output_ogg))


## Inject an OGG file into a SoundWave .uasset, replacing the existing audio.
## Runs in a background thread. Emits operation_finished when done.
func inject_ogg(uasset_path: String, ogg_path: String) -> void:
	_start_operation(_do_inject_ogg.bind(uasset_path, ogg_path),
			_invalidate_cache.bind(uasset_path))


# ── Cache ─────────────────────────────────────────────────────────────────────


func _get_cache_dir() -> String:
	return OS.get_temp_dir().path_join(CACHE_DIR)


func _cache_key(uasset_path: String) -> String:
	var mtime := FileAccess.get_modified_time(uasset_path)
	return str(uasset_path.hash()) + "_" + str(mtime)


## Check if cached OGG data exists for this asset. Returns path or "".
func get_cached_audio(uasset_path: String) -> String:
	var cache_path := _get_cache_dir().path_join(_cache_key(uasset_path) + ".ogg")
	if FileAccess.file_exists(cache_path):
		return cache_path
	return ""


# ── Background operations ────────────────────────────────────────────────────


func _start_operation(task: Callable, success_callback: Callable = Callable()) -> void:
	var error := _start_background(task, _on_operation_done.bind(success_callback))
	if error == ERR_ALREADY_IN_USE:
		return
	if error != OK:
		operation_finished.emit(OperationResult.failed(
				"Could not start audio operation (error %d)" % error))


func _on_operation_done(result: OperationResult, success_callback: Callable) -> void:
	if result.ok and success_callback.is_valid():
		success_callback.call()
	operation_finished.emit(result)


func _do_export_ogg(uasset_path: String, output_ogg: String) -> OperationResult:
	var result := _do_extract_audio(uasset_path)
	if result.ok:
		var write_error := FileUtils.write_bytes_atomic(output_ogg, result.value)
		if write_error == OK:
			return OperationResult.succeeded(
					"Exported to %s" % output_ogg.get_file(), output_ogg)
		return OperationResult.failed(
				"Failed to write %s (error %d)" % [output_ogg, write_error])
	return result


# ── Core extraction ──────────────────────────────────────────────────────────


## Extract OGG audio bytes from a SoundWave .uasset's companion files.
func _do_extract_audio(uasset_path: String) -> OperationResult:
	if _cfg and _cfg.get_game_profile().audio_format != "ogg_raw":
		return OperationResult.failed("Audio format '%s' is not supported — only raw OGG (ogg_raw) is currently supported" % _cfg.get_game_profile().audio_format)

	if not FileAccess.file_exists(uasset_path):
		return OperationResult.failed("File not found: %s" % uasset_path)

	var base_path := uasset_path.trim_suffix(".uasset")

	# Try companion files in order: .ubulk first (large assets), then .uexp (inline)
	var search_files: PackedStringArray = []
	if FileAccess.file_exists(base_path + ".ubulk"):
		search_files.append(base_path + ".ubulk")
	if FileAccess.file_exists(base_path + ".uexp"):
		search_files.append(base_path + ".uexp")

	if search_files.is_empty():
		return OperationResult.failed("No .uexp or .ubulk file found")

	# Search for OGG magic bytes in each file
	for file_path in search_files:
		var ogg_data := _find_ogg_in_file(file_path)
		if not ogg_data.is_empty():
			# Cache the extracted audio
			var cache_dir := _get_cache_dir()
			DirAccess.make_dir_recursive_absolute(cache_dir)
			var cache_path := cache_dir.path_join(_cache_key(uasset_path) + ".ogg")
			FileUtils.write_bytes_atomic(cache_path, ogg_data)
			return OperationResult.succeeded(
					"Extracted %d bytes of audio" % ogg_data.size(), ogg_data)

	return OperationResult.failed("No OGG audio data found in companion files")


## Search a binary file for OGG Vorbis data starting with "OggS" magic bytes.
## Returns the OGG data from the first occurrence to the end of the OGG stream.
func _find_ogg_in_file(file_path: String) -> PackedByteArray:
	var fa := FileAccess.open(file_path, FileAccess.READ)
	if not fa:
		return PackedByteArray()

	var file_size := fa.get_length()
	if file_size < 4:
		fa.close()
		return PackedByteArray()

	# Read entire file into memory for searching
	var data := fa.get_buffer(file_size)
	fa.close()

	# Find OGG magic bytes
	var ogg_start := _find_bytes(data, OGG_MAGIC)
	if ogg_start < 0:
		return PackedByteArray()

	# OGG data runs from the magic bytes to the end of the stream.
	# For UE4 SoundWave bulk data, the OGG file is typically the last chunk
	# in the bulk section, so we take everything from OggS to end of file.
	# However, there might be trailing data after the OGG stream ends.
	# We find the last OGG page to determine the true end.
	var ogg_end := _find_ogg_stream_end(data, ogg_start)
	return data.slice(ogg_start, ogg_end)


## Find the byte offset of a needle in a haystack. Returns -1 if not found.
func _find_bytes(haystack: PackedByteArray, needle: PackedByteArray) -> int:
	var h_len := haystack.size()
	var n_len := needle.size()
	if n_len > h_len:
		return -1
	for i in range(h_len - n_len + 1):
		var found := true
		for j in range(n_len):
			if haystack[i + j] != needle[j]:
				found = false
				break
		if found:
			return i
	return -1


## Find the end of an OGG stream by locating the last OGG page.
## Each OGG page starts with "OggS" and has a known header structure:
##   bytes 0-3:   "OggS" capture pattern
##   byte  4:     stream structure version
##   byte  5:     header type flag (bit 2 = last page of stream)
##   bytes 6-13:  granule position
##   bytes 14-17: serial number
##   bytes 18-21: page sequence number
##   bytes 22-25: CRC checksum
##   byte  26:    number of page segments
##   bytes 27...: segment table (one byte per segment)
##   After segment table: payload data (sum of segment sizes bytes)
func _find_ogg_stream_end(data: PackedByteArray, start: int) -> int:
	var pos := start
	var data_size := data.size()
	var last_page_end := data_size  # fallback

	while pos < data_size - 27:  # minimum OGG header is 27 bytes
		# Verify OGG page magic
		if data[pos] != 0x4F or data[pos + 1] != 0x67 or \
		   data[pos + 2] != 0x67 or data[pos + 3] != 0x53:
			break

		# Read number of segments at byte 26
		var num_segments: int = data[pos + 26]
		if pos + 27 + num_segments > data_size:
			break

		# Calculate total payload size from segment table
		var payload_size := 0
		for i in range(num_segments):
			payload_size += data[pos + 27 + i]

		# Page ends after header + segment table + payload
		var page_end := pos + 27 + num_segments + payload_size
		last_page_end = mini(page_end, data_size)

		# Check if this is the last page (header type flag bit 2)
		if data[pos + 5] & 0x04:
			return last_page_end

		# Move to next page
		pos = page_end

	return last_page_end


# ── Core injection ───────────────────────────────────────────────────────────


## Inject an OGG file into a SoundWave .uasset's companion file, replacing the
## existing audio data.  Updates the FByteBulkData header size fields so UE4
## recognises the new payload length.
func _do_inject_ogg(uasset_path: String, ogg_path: String) -> OperationResult:
	if _cfg and _cfg.get_game_profile().audio_format != "ogg_raw":
		return OperationResult.failed("Audio injection not supported for format '%s' — only raw OGG (ogg_raw) is supported" % _cfg.get_game_profile().audio_format)

	if not FileAccess.file_exists(uasset_path):
		return OperationResult.failed("Asset not found: %s" % uasset_path)
	if not FileAccess.file_exists(ogg_path):
		return OperationResult.failed("OGG file not found: %s" % ogg_path)

	# Read new OGG data
	var new_fa := FileAccess.open(ogg_path, FileAccess.READ)
	if not new_fa:
		return OperationResult.failed("Cannot open OGG file: %s" % ogg_path)
	var new_ogg := new_fa.get_buffer(new_fa.get_length())
	new_fa.close()

	if new_ogg.size() < 4 or new_ogg[0] != 0x4F or new_ogg[1] != 0x67 or \
	   new_ogg[2] != 0x67 or new_ogg[3] != 0x53:
		return OperationResult.failed("File does not appear to be OGG Vorbis")

	# Find which companion file contains the old OGG data
	var base_path := uasset_path.trim_suffix(".uasset")
	var search_files: PackedStringArray = []
	if FileAccess.file_exists(base_path + ".ubulk"):
		search_files.append(base_path + ".ubulk")
	if FileAccess.file_exists(base_path + ".uexp"):
		search_files.append(base_path + ".uexp")

	if search_files.is_empty():
		return OperationResult.failed("No .uexp or .ubulk file found")

	# Locate old OGG range in companion file
	var target_file := ""
	var file_data := PackedByteArray()
	var ogg_start := -1
	var ogg_end := -1

	for file_path in search_files:
		var fa := FileAccess.open(file_path, FileAccess.READ)
		if not fa:
			continue
		var data := fa.get_buffer(fa.get_length())
		fa.close()

		var start := _find_bytes(data, OGG_MAGIC)
		if start >= 0:
			target_file = file_path
			file_data = data
			ogg_start = start
			ogg_end = _find_ogg_stream_end(data, start)
			break

	if ogg_start < 0:
		return OperationResult.failed("No existing OGG data found in companion files")

	var old_size := ogg_end - ogg_start

	# Try to update FByteBulkData header sitting before the audio data.
	# UE4 FByteBulkData layout (20 bytes total, little-endian):
	#   offset -20: BulkDataFlags   (uint32)
	#   offset -16: ElementCount    (int32)  — uncompressed size
	#   offset -12: SizeOnDisk      (int32)  — compressed size (= ElementCount for raw OGG)
	#   offset  -8: OffsetInFile    (int64)
	# Both size fields should equal old_size for uncompressed audio.
	if ogg_start >= 20:
		var size_on_disk := _read_int32(file_data, ogg_start - 12)
		var elem_count   := _read_int32(file_data, ogg_start - 16)
		if size_on_disk == old_size and elem_count == old_size:
			_write_int32(file_data, ogg_start - 12, new_ogg.size())
			_write_int32(file_data, ogg_start - 16, new_ogg.size())

	# Splice: everything before OGG + new OGG + everything after OGG
	var prefix := file_data.slice(0, ogg_start)
	var suffix := file_data.slice(ogg_end)
	var result_data := PackedByteArray()
	result_data.append_array(prefix)
	result_data.append_array(new_ogg)
	result_data.append_array(suffix)

	# Write back through the staged installer so the replaced companion remains
	# available as an explicit restore point after a successful injection.
	var write_result := FileUtils.write_bytes_atomic_with_result(
			target_file, result_data, true, "audio-backup")
	var write_error := int(write_result.get("error", ERR_BUG))
	if write_error != OK:
		return OperationResult.failed(
				"Failed to write %s (error %d)" % [target_file, write_error])

	var msg := "Injected %s into %s" % [ogg_path.get_file(), target_file.get_file()]
	if new_ogg.size() != old_size:
		msg += " (size changed: %d → %d bytes)" % [old_size, new_ogg.size()]
	var backup_summary := FileUtils.format_backup_summary(write_result.get("backups", []))
	if not backup_summary.is_empty():
		msg += ". " + backup_summary
	return OperationResult.succeeded(msg).with_backups(write_result.get("backups", []))


# ── Cache invalidation ───────────────────────────────────────────────────────


func _invalidate_cache(uasset_path: String) -> void:
	var cache_dir := _get_cache_dir()
	if not DirAccess.dir_exists_absolute(cache_dir):
		return
	var prefix := str(uasset_path.hash())
	var dir := DirAccess.open(cache_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with(prefix):
			DirAccess.remove_absolute(cache_dir.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


# ── Binary helpers ───────────────────────────────────────────────────────────


## Read a little-endian int32 from a byte array at the given offset.
func _read_int32(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)


## Write a little-endian int32 into a byte array at the given offset.
func _write_int32(data: PackedByteArray, offset: int, value: int) -> void:
	data[offset]     = value & 0xFF
	data[offset + 1] = (value >> 8) & 0xFF
	data[offset + 2] = (value >> 16) & 0xFF
	data[offset + 3] = (value >> 24) & 0xFF
