class_name ModFileWatcher extends RefCounted

## Background file watcher that detects changes in enabled mods and triggers auto-pack.
## Uses a polling thread with mtime+size hashing — same algorithm as watch.py.
##
## Usage:
##   watcher.setup(cfg, state_manager, packing_service)
##   watcher.start()   # begins polling
##   watcher.stop()    # signals thread to stop (call wait_to_finish() after)

const POLL_INTERVAL := 1.0  # seconds
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


func setup(cfg: ModConfigManager, state: ModStateManager, packer: PackingService) -> ModFileWatcher:
	_cfg    = cfg
	_state  = state
	_packer = packer
	return self


func is_watching() -> bool:
	return _active


func get_pack_count() -> int:
	return _pack_count


func start() -> void:
	_active_mtx.lock()
	if _active:
		_active_mtx.unlock()
		return
	_active = true
	_pack_count = 0
	_active_mtx.unlock()

	if _thread and _thread.is_alive():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_watch_loop)
	watch_status_changed.emit(true)


func stop() -> void:
	_active_mtx.lock()
	_active = false
	_active_mtx.unlock()
	# Thread will exit on its own next poll cycle
	watch_status_changed.emit(false)


func wait_to_finish() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


# ── Watch loop (runs in background thread) ────────────────────────────────────

func _watch_loop() -> void:
	var last_hash := _snapshot()

	while true:
		_active_mtx.lock()
		var still_active := _active
		_active_mtx.unlock()
		if not still_active:
			break

		OS.delay_msec(int(POLL_INTERVAL * 1000))

		_active_mtx.lock()
		still_active = _active
		_active_mtx.unlock()
		if not still_active:
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
		var enabled_mods := all_mods.filter(func(m): return m["name"] in enabled_names)
		if enabled_mods.is_empty():
			continue

		# PackingService runs its own thread; we call it from here and block until done
		# Since we're already in a thread, just pack directly (synchronous path)
		_pack_count += 1
		var n := _pack_count
		call_deferred("_emit_pack_triggered", n)

		# Wait for any in-progress pack to finish before starting another
		while _packer.is_packing():
			OS.delay_msec(200)
		_packer.call_deferred("pack", enabled_mods)


func _emit_pack_triggered(n: int) -> void:
	pack_triggered.emit(n)


# ── Snapshot ───────────────────────────────────────────────────────────────────

## Build a hash of mtime+size for all tracked asset files in enabled mods.
func _snapshot() -> int:
	var enabled_names := _state.get_enabled_names()
	if enabled_names.is_empty() or _cfg.mods_dir.is_empty():
		return 0

	var h: int = 0

	# Collect directories in sorted order for determinism
	var dir := DirAccess.open(_cfg.mods_dir)
	if not dir:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	var names: Array = []
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with(".") and entry in enabled_names:
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	names.sort()

	var content_root := _cfg.get_game_profile().content_root
	for mod_name in names:
		var mod_content := _cfg.mods_dir.path_join(mod_name).path_join(content_root)
		if not DirAccess.dir_exists_absolute(mod_content):
			continue
		h = _hash_dir(mod_content, h)  # accumulate returned hash — ints are pass-by-value in GDScript

	return h


# Returns the updated hash after folding in every tracked file under path.
func _hash_dir(path: String, h: int) -> int:
	var dir := DirAccess.open(path)
	if not dir:
		return h
	var entries: Array = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		entries.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	entries.sort()

	for e in entries:
		var full := path.path_join(e)
		if DirAccess.dir_exists_absolute(full) and not e.begins_with("."):
			h = _hash_dir(full, h)   # recurse and thread the hash back up
		elif not DirAccess.dir_exists_absolute(full):
			var watched := false
			for ext in WATCHED_EXTENSIONS:
				if e.ends_with(ext):
					watched = true
					break
			if not watched:
				continue
			var fa := FileAccess.open(full, FileAccess.READ)
			if fa:
				var sz := fa.get_length()
				fa.close()
				var mt := FileAccess.get_modified_time(full)
				h ^= hash(full) ^ hash(sz) ^ hash(mt)

	return h
