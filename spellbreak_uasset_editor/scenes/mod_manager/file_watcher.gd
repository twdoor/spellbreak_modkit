class_name ModFileWatcher extends RefCounted

## Background file watcher that detects changes in enabled mods and triggers auto-pack.
## Uses a polling thread with content signatures so same-size saves are detected.
##
## Usage:
##   watcher.setup(cfg, state_manager, packing_service)
##   watcher.start()   # begins polling
##   watcher.stop()    # signals thread to stop (call wait_to_finish() after)

const POLL_INTERVAL := 1.0  # seconds
const STOP_CHECK_INTERVAL_MS := 50
const HASH_CHUNK_SIZE := 1024 * 1024
const FINGERPRINT_CHUNK_SIZE := 64 * 1024
const WATCHED_EXTENSIONS := [".uasset", ".uexp", ".ubulk", ".umap"]

signal watch_status_changed(active: bool)
signal pack_triggered(pack_number: int)

var _cfg:     ModConfigManager
var _state:   ModStateManager
var _packer:  PackingService

var _thread:     Thread  = null
var _active:     bool    = false
var _active_mtx: Mutex   = Mutex.new()
var _pack_count: int     = 0
var _file_signatures: Dictionary = {}


func setup(cfg: ModConfigManager, state: ModStateManager, packer: PackingService) -> ModFileWatcher:
	_cfg    = cfg
	_state  = state
	_packer = packer
	return self


func is_watching() -> bool:
	return _is_active()


func _is_active() -> bool:
	_active_mtx.lock()
	var result := _active
	_active_mtx.unlock()
	return result


func get_pack_count() -> int:
	return _pack_count


func start() -> void:
	_active_mtx.lock()
	if _active:
		_active_mtx.unlock()
		return
	_active_mtx.unlock()

	_join_thread()

	_active_mtx.lock()
	if _active:
		_active_mtx.unlock()
		return
	_active = true
	_pack_count = 0
	_file_signatures.clear()
	_active_mtx.unlock()

	_thread = Thread.new()
	var error := _thread.start(_watch_loop)
	if error != OK:
		_thread = null
		_active_mtx.lock()
		_active = false
		_active_mtx.unlock()
		watch_status_changed.emit(false)
		return
	watch_status_changed.emit(true)


func stop() -> void:
	_active_mtx.lock()
	var changed := _active
	_active = false
	_active_mtx.unlock()
	# Thread will exit on its own next poll cycle
	if changed:
		watch_status_changed.emit(false)


func wait_to_finish() -> void:
	_join_thread()


func _join_thread() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


# ── Watch loop (runs in background thread) ────────────────────────────────────

func _watch_loop() -> void:
	var last_hash := _snapshot()

	while true:
		if not _is_active():
			break

		if not _sleep_until_next_poll():
			break

		var cur_hash := _snapshot()
		if cur_hash == last_hash:
			continue
		last_hash = cur_hash

		# Files changed — pack
		var enabled_names := _state.get_enabled_names()
		if enabled_names.is_empty():
			continue
		var all_mods := ModDiscovery.scan(_cfg.mods_dir, _cfg.get_game_profile().content_root)
		var enabled_mods := all_mods.filter(
				func(m: ModInfo): return m.name in enabled_names)
		if enabled_mods.is_empty():
			continue

		_pack_count += 1
		var n := _pack_count

		# PackingService owns its own worker thread, but starting it and emitting UI
		# signals must happen on the main thread.
		while _is_active() and _packer.is_packing():
			OS.delay_msec(200)
		if _is_active():
			call_deferred("_emit_pack_triggered_and_pack", n, enabled_mods.duplicate())


func _sleep_until_next_poll() -> bool:
	var remaining := int(POLL_INTERVAL * 1000)
	while remaining > 0:
		if not _is_active():
			return false
		var chunk = mini(remaining, STOP_CHECK_INTERVAL_MS)
		OS.delay_msec(chunk)
		remaining -= chunk
	return _is_active()


func _emit_pack_triggered(n: int) -> void:
	pack_triggered.emit(n)


func _emit_pack_triggered_and_pack(n: int, enabled_mods: Array) -> void:
	_emit_pack_triggered(n)
	if _packer == null:
		return
	_packer.pack(enabled_mods)


# ── Snapshot ───────────────────────────────────────────────────────────────────

## Build a hash of path, mtime, size, and content for tracked asset files in enabled mods.
func _snapshot() -> int:
	var enabled_names := _state.get_enabled_names()
	if enabled_names.is_empty() or _cfg.mods_dir.is_empty():
		return 0

	var h: int = 0
	var seen_files: Dictionary = {}

	# Collect directories in sorted order for determinism
	var dir := DirAccess.open(_cfg.mods_dir)
	if not dir:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	var names: Array = []
	while not entry.is_empty():
		if dir.current_is_dir() and not dir.is_link(entry) \
				and not entry.begins_with(".") and entry in enabled_names:
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	names.sort()

	var content_root := _cfg.get_game_profile().content_root
	for mod_name in names:
		var mod_root := _cfg.mods_dir.path_join(mod_name)
		var mod_content := mod_root.path_join(content_root)
		if not FileUtils.is_path_within(mod_content, mod_root):
			continue
		if not DirAccess.dir_exists_absolute(mod_content):
			continue
		h = _hash_dir(mod_content, h, seen_files)

	for cached_path in _file_signatures.keys():
		if cached_path not in seen_files:
			_file_signatures.erase(cached_path)

	return h


# Returns the updated hash after folding in every tracked file under path.
func _hash_dir(path: String, h: int, seen_files: Dictionary) -> int:
	var dir := DirAccess.open(path)
	if not dir:
		return h
	var entries: Array = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		entries.append({"name": entry, "is_link": dir.is_link(entry)})
		entry = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]) < str(b["name"]))

	for item: Dictionary in entries:
		if bool(item["is_link"]):
			continue
		var e := str(item["name"])
		var full := path.path_join(e)
		if DirAccess.dir_exists_absolute(full) and not e.begins_with("."):
			h = _hash_dir(full, h, seen_files)
		elif not DirAccess.dir_exists_absolute(full):
			var watched := false
			var lower_name: String = e.to_lower()
			for ext in WATCHED_EXTENSIONS:
				if lower_name.ends_with(ext):
					watched = true
					break
			if not watched:
				continue
			seen_files[full] = true
			var signature := _file_signature(full)
			h ^= hash(full) ^ hash(signature.get("size", 0)) \
					^ hash(signature.get("mtime", 0)) ^ hash(signature.get("digest", ""))

	return h


func _file_signature(path: String) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return {}
	var size := fa.get_length()
	fa.close()
	var mtime := FileAccess.get_modified_time(path)
	var fingerprint := _file_fingerprint(path, size)
	var previous: Dictionary = _file_signatures.get(path, {})
	var digest := str(previous.get("digest", ""))
	if previous.is_empty() or int(previous.get("size", -1)) != size \
			or int(previous.get("mtime", -1)) != mtime \
			or str(previous.get("fingerprint", "")) != fingerprint:
		digest = _file_content_digest(path)
	var signature := {
		"size": size,
		"mtime": mtime,
		"fingerprint": fingerprint,
		"digest": digest,
	}
	_file_signatures[path] = signature
	return signature


func _file_fingerprint(path: String, size: int) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_MD5) != OK:
		fa.close()
		return ""
	var offsets: Array[int] = [0]
	if size > FINGERPRINT_CHUNK_SIZE:
		offsets.append(maxi(0, (size >> 1) - (FINGERPRINT_CHUNK_SIZE >> 1)))
		offsets.append(maxi(0, size - FINGERPRINT_CHUNK_SIZE))
	for offset in offsets:
		fa.seek(offset)
		ctx.update(fa.get_buffer(mini(FINGERPRINT_CHUNK_SIZE, size - offset)))
	fa.close()
	return ctx.finish().hex_encode()


func _file_content_digest(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return ""
	var ctx := HashingContext.new()
	var error := ctx.start(HashingContext.HASH_MD5)
	if error != OK:
		fa.close()
		return ""
	while not fa.eof_reached():
		var chunk := fa.get_buffer(HASH_CHUNK_SIZE)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	fa.close()
	return ctx.finish().hex_encode()
